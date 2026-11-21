// Drops from other apps (v1.0.23, docs/design/drag-drop.md §3–4): what a drag brings — pictures, other files,
// text — read the same way by the main window (a new item, added to an item, into a project) and the island (cards).
//  • pictures: image files, a browser's file promise of an image, image data (Safari's TIFF) → copied in
//  • other files (PDF, video, documents…) → referenced by path; a file in a temporary place (a chat app's cache,
//    /var/folders, a download still being written) is copied instead: it would be gone in a minute
//  • text and links (a .webloc from Safari's address bar is its link) → text
//  • folders are not taken here (the sidebar opens them as projects)
// The label next to the pointer says what letting go will do, before it happens (DropHint); the system's badge says
// copy (+) for pictures and text, link for referenced files, move for Blurt's own cards and rows.

import AppKit
import BlurtCore
import UniformTypeIdentifiers

/// What a drag from another app carries.
struct DropIn {
    var images: [URL] = []
    var files: [URL] = []
    var text: String?
    var folders = 0
    var promises: [NSFilePromiseReceiver] = []
    /// image data on the pasteboard, not yet written to a file (validation doesn't decode it)
    var imageData = false

    var isEmpty: Bool { images.isEmpty && files.isEmpty && text == nil && promises.isEmpty && !imageData }
    /// how many pictures, counting promises and data as pictures until received
    var pictureCount: Int { images.count + promises.count + (imageData ? 1 : 0) }

    /// Every type a drop from another app may come in.
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .string, .URL, NSPasteboard.PasteboardType("public.jpeg"),
                                                       NSPasteboard.PasteboardType("public.heic")]
        + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }

    /// A drag of Blurt's own (cards, rows): not a drop from another app.
    static func isOurs(_ pb: NSPasteboard) -> Bool {
        let t = pb.types ?? []
        return t.contains(capturePasteboardType) || t.contains(.blurtItems)
    }

    /// What `pb` carries. `decode`: image data is written to a temporary PNG (a drop); else only noted (validation).
    static func read(_ pb: NSPasteboard, decode: Bool) -> DropIn {
        var d = DropIn()
        guard !isOurs(pb) else { return d }
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        for u in urls {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) else { continue }
            let type = UTType(filenameExtension: u.pathExtension)
            if dir.boolValue, type?.conforms(to: .package) != true { d.folders += 1; continue }
            if ["webloc", "inetloc"].contains(u.pathExtension.lowercased()) {
                if let link = webloc(u) { d.text = [d.text, link].compactMap { $0 }.joined(separator: "\n") }
                continue
            }
            if type?.conforms(to: .image) == true { d.images.append(u) } else { d.files.append(u) }
        }
        if urls.isEmpty {
            // a browser's image: a promise of its file (never the page's .webloc)
            let ps = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
            d.promises = ps.filter { p in !p.fileTypes.contains { $0.contains("webloc") || $0.contains("internet-location") || $0.contains("inetloc") } }
            if d.promises.isEmpty, NSImage.canInit(with: pb), pb.availableType(from: [.png, .tiff, .init("public.jpeg"), .init("public.heic")]) != nil {
                if decode {
                    d.images = (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []).compactMap(DropIn.tempPNG)
                } else {
                    d.imageData = true
                }
            }
        }
        // text only when nothing else came: never a folder's own file:// URL (folders are refused)
        if urls.isEmpty, d.images.isEmpty, d.files.isEmpty, d.promises.isEmpty, !d.imageData, d.text == nil {
            let s = pb.string(forType: .string) ?? (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString
            if let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { d.text = s }
        }
        return d
    }

    /// What ⌘V would bring from the clipboard: files and pictures copied in Finder or a browser, a screenshot, text.
    /// A document's copy (Word, Excel, Notes: rich text) also carries a picture of itself — its text is what was
    /// copied. Never rows or cards copied in Blurt itself (their files would only be duplicated): their text, if any.
    static func clipboard(_ pb: NSPasteboard = .general) -> DropIn {
        let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var d = DropIn()
        if !isOurs(pb) {
            let richText = !s.isEmpty && pb.availableType(from: [.rtf, .rtfd]) != nil
            d = read(pb, decode: !richText)
            d.imageData = false
        }
        let mine = { (u: URL) in u.path.contains("/.blurt/") || u.path.contains("/Blurt/inbox/") }
        d.images.removeAll(where: mine)
        d.files.removeAll(where: mine)
        d.promises = []
        if d.images.isEmpty, d.files.isEmpty { d.text = s.isEmpty ? nil : s }
        return d
    }

    /// The clipboard holds files or a picture (cheap: nothing is read or decoded).
    static func clipboardHasFiles(_ pb: NSPasteboard = .general) -> Bool {
        !isOurs(pb) && pb.availableType(from: [.fileURL, .png, .tiff, .init("public.jpeg"), .init("public.heic")]) != nil
    }

    /// The link a .webloc / .inetloc holds.
    static func webloc(_ u: URL) -> String? {
        guard let data = try? Data(contentsOf: u),
              let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return p["URL"] as? String
    }

    static func tempPNG(_ img: NSImage) -> URL? {
        guard let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-drop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(UUID().uuidString + ".png")
        return (try? png.write(to: u)) == nil ? nil : u
    }

    /// The promised files received (into a temporary folder), then sorted into pictures and files; at most 20 s.
    func resolved(_ done: @escaping (DropIn) -> Void) {
        guard !promises.isEmpty else { return done(self) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-drop/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let group = DispatchGroup()
        let lock = NSLock()
        var byIndex: [Int: URL] = [:]
        let queue = OperationQueue()
        for (i, r) in promises.enumerated() {
            group.enter()
            r.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: queue) { u, e in
                if e == nil { lock.lock(); if byIndex[i] == nil { byIndex[i] = u }; lock.unlock() }
                group.leave()
            }
        }
        // in the order they were dragged, not the order they finished arriving
        var got: [URL] { byIndex.sorted { $0.key < $1.key }.map(\.value) }
        var d = self
        d.promises = []
        let finish = { (urls: [URL]) in
            for u in urls {
                if UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) == true { d.images.append(u) } else { d.files.append(u) }
            }
            done(d)
        }
        var finished = false
        group.notify(queue: .main) { if !finished { finished = true; lock.lock(); let g = got; lock.unlock(); finish(g) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { if !finished { finished = true; lock.lock(); let g = got; lock.unlock(); finish(g) } }
    }

    /// "1 picture", "3 files", "text", "2 pictures, 1 file" — what the drawer's title and the labels say it is.
    var summary: String {
        var parts: [String] = []
        if pictureCount > 0 { parts.append(TP("main.drop.pictures", pictureCount)) }
        if !files.isEmpty { parts.append(TP("main.drop.files", files.count)) }
        if parts.isEmpty, text != nil { parts.append(T("main.drop.text")) }
        return parts.joined(separator: T("main.drop.and"))
    }
}

/// Where a dropped file lives: a temporary place (copied), or a place it stays (referenced).
enum FilePlace {
    /// A chat app's cache, the system's temporary folders, a download still being written, an app's container: a
    /// file there may be gone in a minute (Feishu's and WeChat's received files, ⌘⇧5's floating thumbnail).
    static func isTemporary(_ u: URL) -> Bool {
        let p = u.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tmp = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath
        if p.hasPrefix(tmp) || p.hasPrefix("/private/var/folders/") || p.hasPrefix("/var/folders/") || p.hasPrefix("/private/tmp/")
            || p.hasPrefix("/tmp/") { return true }
        if p.contains("/TemporaryItems/") || p.contains(".download/") || u.pathExtension == "crdownload" { return true }
        for dir in ["/Library/Caches/", "/Library/Containers/", "/Library/Group Containers/", "/Library/Application Support/"]
            where p.hasPrefix(home + dir) { return true }
        return false
    }
}

/// The label next to the pointer during a drop on the main window: what letting go will do ("Add to “Homepage
/// refs”", "New item", "File to Blurt", "Read-only item"). A small pill, refused ones in a quieter colour.
final class DropHint: NSView {
    private let label = NSTextField(labelWithString: "")
    private(set) var text: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Show `text` near `p` (in the superview's coordinates); `ok`: the drop will do it (else a refusal, quieter).
    func show(_ text: String, at p: NSPoint, ok: Bool) {
        guard let sv = superview else { return }
        if text != self.text {
            self.text = text
            label.stringValue = text
            if ok { NSAccessibility.post(element: sv, notification: .announcementRequested,
                                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue]) }
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (ok ? BrandColor.accent : NSColor.secondaryLabelColor).withAlphaComponent(ok ? 0.95 : 0.85).cgColor
        }
        label.textColor = .white
        let size = NSSize(width: ceil(label.intrinsicContentSize.width) + 20, height: 22)
        var o = NSPoint(x: p.x + 14, y: sv.isFlipped ? p.y + 18 : p.y - 18 - size.height)
        o.x = min(max(4, o.x), sv.bounds.width - size.width - 4)
        o.y = min(max(4, o.y), sv.bounds.height - size.height - 4)
        frame = NSRect(origin: o, size: size)
        isHidden = false
    }

    func hide() { isHidden = true; text = nil }
}

/// The band over the list's search field while something is dragged over the list: "Drop for a new item" — a full
/// list has no empty place, and every drop would otherwise land on a row ("add to it"). It sits above the rows, never
/// over one (first build: it covered the first row, and a drop on the top item made a new item instead). Always in
/// place and a drop target of its own, only seen during a drag: clicks go through it to the search field.
final class DropBand: NSView {
    static let height: CGFloat = 36
    private let label = NSTextField(labelWithString: "")
    var active = false { didSet { if active != oldValue { needsDisplay = true; style() } } }
    /// seen (a drag is over the list or the band)
    var shown = false { didSet { alphaValue = shown ? 1 : 0 } }
    /// the list's own handling of a drop here (a new item; cards into the project on show)
    var drops: (update: (NSDraggingInfo) -> NSDragOperation, perform: (NSDraggingInfo) -> Bool, gone: () -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
        alphaValue = 0
        setAccessibilityElement(false)
        style()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { drops?.update(s) ?? [] }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { drops?.update(s) ?? [] }
    override func draggingExited(_ s: NSDraggingInfo?) { drops?.gone() }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { drops?.perform(s) ?? false }
    override func draggingEnded(_ s: NSDraggingInfo) { drops?.gone() }

    func setText(_ s: String) { label.stringValue = s }

    private func style() {
        layer?.cornerRadius = 8
        layer?.borderWidth = active ? 2 : 1
        // a drop target in the brand (docs/design/system.md §2: the accent's edge, a mint wash, brand ink for the words)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (active ? BrandColor.accent : NSColor.separatorColor).cgColor
            // (opaque: what it covers — the search field — must not show through)
            let base = NSColor.windowBackgroundColor
            layer?.backgroundColor = (active ? (base.blended(withFraction: 0.12, of: BrandColor.accent) ?? base) : base).cgColor
        }
        label.textColor = active ? BrandColor.ink : .secondaryLabelColor
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); style() }
}
