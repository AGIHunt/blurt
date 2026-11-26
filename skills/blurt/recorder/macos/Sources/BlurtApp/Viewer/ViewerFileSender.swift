// Files to the computer a window shows (docs/design/remote-1.1.md §6): Send Files… or dropped on the picture, each to the host's
// Downloads in order, a chunk at a time, never more than `window` ahead of what the host says it has written. The window shows each
// one on its file card (ViewerFileCard): the name, how much the host has written, and × to stop.
import AppKit
import BlurtCore
import BlurtRemoteKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

final class ViewerFileSender {
    /// What the card shows, on the main thread. `done` is nil until the other end first says how much it has written.
    enum Event: Equatable {
        /// `url`: the file here being sent (its Quick Look thumbnail is the card's icon)
        case sending(name: String, size: Int, done: Int?, index: Int, count: Int, left: Double?, url: URL? = nil)
        /// a file from the host, coming here (Get Copied Items)
        case receiving(name: String, size: Int, done: Int, index: Int, count: Int, left: Double?)
        /// the session dropped mid-file: it goes on when it's back
        case paused(name: String)
        /// at the host; `blurt`: in its Downloads/Blurt (hosts that resume), else its Downloads
        case saved(name: String, index: Int, count: Int, blurt: Bool)
        /// here, in Downloads/Blurt
        case received(url: URL, index: Int, count: Int)
        /// what was copied there is on this Mac's clipboard now
        case copied(image: Bool)
        /// Get Copied Items found nothing to send: "empty", "locked", "too_big" (over 1,000 files), "too_large" (a file over 4 GB),
        /// "unsupported", "update"
        case nothing(why: String)
        /// why: "space", "too_big", "locked", "read", "write", "other"; `incoming`: a file coming here
        case failed(name: String, why: String, incoming: Bool)
        /// × on the card: what was going and what waited behind it
        case stopped
    }

    static var downloads: URL { RemoteHostFiles.downloads }

    private let link: RemoteViewerLink
    let out: RemoteFileSender
    let incoming: RemoteFileReceiver
    var onEvent: ((Event) -> Void)?
    /// Get Copied Items was asked and not yet answered (main thread): only then does what the host sends go on this Mac's clipboard, a
    /// `clip` or text (a host can't put anything there on its own). The first answer uses it up: text, nothing, a clip, or the first
    /// file of a batch; so does a drop, or 30 s.
    private var askedAt: Date?
    func ask() { askedAt = Date() }
    /// The answer that came is the one asked for: true once.
    func takeAsked() -> Bool {
        defer { askedAt = nil }
        return askedAt.map { Date().timeIntervalSince($0) < 30 } ?? false
    }
    /// the host's id: the receiver keys its parts by it
    private var device: String { link.computer.id }

    /// A window's own parts folder in `root` (another window of the same computer has its own): folders a crashed run left go after an hour.
    static func partsFolder(in root: URL) -> URL {
        let old = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for u in old where ((try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            < Date().addingTimeInterval(-RemoteFiles.keepParts) {
            try? FileManager.default.removeItem(at: u)
        }
        return root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    init(link: RemoteViewerLink, parts: URL) {
        self.link = link
        out = RemoteFileSender(send: { [weak link] o in
                                   guard let link, link.state == .connected else { return false }
                                   link.send(ToMac(o))
                                   return true
                               },
                               ready: { [weak link] in link?.filesReady ?? false },
                               peerResumes: { [weak link] in link?.session?.features?.contains(RemoteFeature.resume) == true })
        incoming = RemoteFileReceiver(parts: parts, folder: { Self.downloads })
        out.onChange = { [weak self] t in self?.changed(t) }
        incoming.onChange = { [weak self] t, _ in self?.changed(t) }
        incoming.onSaved = { url, _ in
            // never opened or run by itself: the flag a browser's download gets
            let q: [String: Any] = [kLSQuarantineAgentNameKey as String: "Blurt", kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
            try? (url as NSURL).setResourceValue(q, forKey: .quarantinePropertiesKey)
        }
        incoming.onClip = { [weak self] url, name, _ in
            // the window hands the host's messages over on the main thread
            guard let self, Self.onMain({ () -> Bool in
                self.takeAsked()
            }) else { return }
            let data = (try? Data(contentsOf: url)) ?? Data()
            let image = RemoteFiles.isImage(name)
            Self.onMain {
                let pb = NSPasteboard.general
                pb.clearContents()
                if image, let img = NSImage(data: data) { pb.writeObjects([img]) } else { pb.setString(String(decoding: data, as: UTF8.self), forType: .string) }
            }
            self.post(.copied(image: image))
        }
    }

    private static func onMain<T>(_ f: () -> T) -> T { Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f) }

    func send(_ urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let ready = RemoteFiles.prepare(urls)
            if ready.isEmpty { return post(.failed(name: urls.first?.lastPathComponent ?? "", why: "read", incoming: false)) }
            out.add(ready, made: RemoteFiles.made(ready))
        }
    }

    /// × on the card: everything going either way stops.
    func stop() {
        out.stop()
        for t in incoming.current { incoming.stop(t.id, from: device) { [weak link] a in link?.send(ToMac(a)) } }
        post(.stopped)
    }

    /// The session is up (true) or dropped: files pause and go on.
    func connection(up: Bool) {
        if !up { askedAt = nil }
        out.connection(up: up)
        if !up { incoming.suspend(device: device) }
    }

    /// What the host said about files, either way.
    func heard(_ m: ToPhone) {
        if let a = m.fileAnswer { out.heard(a) }
        // a batch of files answers Get Copied Items: nothing for the clipboard follows
        if case let .fileBegin(_, _, _, clip, _, _, _) = m, clip != true { askedAt = nil }
        // written off the main thread, in order
        if let o = m.fileOut {
            let device = device
            writes.async { [weak self] in self?.incoming.heard(o, from: device) { [weak self] a in self?.link.send(ToMac(a)) } }
        }
    }
    private let writes = DispatchQueue(label: "blurt.viewer.files.in")

    private func post(_ e: Event) {
        DispatchQueue.main.async { self.onEvent?(e) }
    }

    private func changed(_ t: RemoteTransfer) {
        let i = t.index ?? 1, n = t.count ?? 1
        switch t.state {
        case .waiting:
            return
        case .going:
            guard !t.clip else { return }
            if t.incoming {
                post(.receiving(name: t.name, size: t.size, done: t.done, index: i, count: n, left: t.secondsLeft))
            } else {
                post(.sending(name: t.name, size: t.size, done: t.done > 0 ? t.done : nil, index: i, count: n, left: t.secondsLeft, url: t.url))
            }
        case .paused:
            post(.paused(name: t.name))
        case .done:
            if t.clip { return }
            if t.incoming, let u = t.url { post(.received(url: u, index: i, count: n)) }
            else if !t.incoming { post(.saved(name: t.name, index: i, count: n, blurt: link.session?.features?.contains(RemoteFeature.resume) == true)) }
        case let .failed(why):
            if why == "stopped" { return }
            post(.failed(name: t.name, why: why, incoming: t.incoming))
        }
    }
}

// MARK: - the card

/// The file going to the computer, on the picture's bottom-left corner above the band where the host keeps its taskbar or Dock: the
/// file's own icon, its name (cut in the middle, so the extension stays), where it goes and how much is there, a thin bar, and × to stop.
/// Dark in both appearances, as the window's other cards over the picture (system.md §3.1). Done: the ok check and where it is, 5 s
/// (received here: Show in Finder, 8 s); not sent: the attention triangle and why, until closed or 8 s. Nothing copied there: the info
/// mark. Two lines keep one width and height (420 × 62 pt: "To Office PC · 2 of 3 · 5.1 MB of 8.4 MB · 40 sec left" fits); one line
/// (Copied) is 44 pt tall with a 26 pt mark and hugs its text, 150–460 pt, wrapping to a second line (62 pt tall) past that.
final class ViewerFileCard: NSView {
    static let width: CGFloat = 420
    static let height: CGFloat = 62
    static let oneLineHeight: CGFloat = 44
    static let oneLine: ClosedRange<CGFloat> = 150...460
    /// left of the text (inset, icon, gap) and right of it (gap, ×, inset), one line (26 pt mark) or two (32 pt icon)
    private static func chrome(icon: CGFloat) -> CGFloat { 12 + icon + 10 + 8 + 22 + 10 }
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let track = CALayer()
    private let fill = CALayer()
    private let close = NSButton()
    private let reveal = NSButton(title: "", target: nil, action: nil)
    private lazy var wide: NSLayoutConstraint = {
        let c = widthAnchor.constraint(equalToConstant: Self.width)
        c.priority = .defaultHigh       // a narrow window wins
        return c
    }()
    private lazy var titleToClose = title.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8)
    private lazy var titleToReveal = title.trailingAnchor.constraint(equalTo: reveal.leadingAnchor, constant: -10)
    /// paused: the bar stays where it got to, dimmed
    private var paused = false
    private lazy var tall = heightAnchor.constraint(equalToConstant: Self.height)
    private lazy var iconWide = icon.widthAnchor.constraint(equalToConstant: 32)
    /// the file whose thumbnail the icon is (or is being made for)
    private var thumbFor: URL?
    private var hideTimer: Timer?
    private var fraction: CGFloat?
    private var showsBar = true
    private var hovering = false { didSet { close.alphaValue = hovering ? 1 : 0.55 } }
    /// × while sending (stop) or once it's over (close)
    var onStop: (() -> Void)?
    private var sending = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.35)
            s.shadowBlurRadius = 16
            s.shadowOffset = NSSize(width: 0, height: -4)
            return s
        }()
        isHidden = true

        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = NSColor.white.withAlphaComponent(0.92)
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        title.cell?.truncatesLastVisibleLine = true
        title.allowsExpansionToolTips = true
        detail.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)     // the counts don't jitter
        detail.textColor = NSColor.white.withAlphaComponent(0.6)
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        detail.allowsExpansionToolTips = true
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: T("viewer.file.stop"))?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular).applying(.init(paletteColors: [.black, NSColor.white.withAlphaComponent(0.5)])))
        close.imagePosition = .imageOnly
        close.target = self
        close.action = #selector(stopTapped)
        close.alphaValue = 0.55
        reveal.title = T("viewer.file.reveal")
        reveal.bezelStyle = .push
        reveal.controlSize = .small
        reveal.font = .systemFont(ofSize: 12)
        reveal.target = self
        reveal.action = #selector(revealTapped)
        reveal.isHidden = true
        reveal.bezelColor = NSColor.white.withAlphaComponent(0.22)     // a button on the near-black card, as on a notification
        reveal.setContentCompressionResistancePriority(.required, for: .horizontal)
        reveal.setContentHuggingPriority(.required, for: .horizontal)
        for v in [icon, title, detail, close, reveal] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        track.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        track.cornerRadius = 1.5
        fill.backgroundColor = BrandColor.Island.ink.cgColor
        fill.cornerRadius = 1.5
        layer?.addSublayer(track)
        track.addSublayer(fill)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWide, icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleToClose,
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),
            reveal.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            reveal.centerYAnchor.constraint(equalTo: centerYAnchor),
            tall,
            wide,
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // the bar under the detail, as wide as the text column
        let x = title.frame.minX
        track.frame = CGRect(x: x, y: 11, width: max(0, title.frame.maxX - x), height: 3)
        track.isHidden = !showsBar
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * (fraction ?? 0), height: 3)
        fill.opacity = paused ? 0.4 : 1
        CATransaction.commit()
        indeterminate(fraction == nil && showsBar && !paused)
    }

    /// Before the host's first count: a short piece of the bar slides along (still under Reduce Motion).
    private func indeterminate(_ on: Bool) {
        let key = "slide"
        guard on else { fill.removeAnimation(forKey: key); return }
        let w = track.bounds.width * 0.3
        fill.frame = CGRect(x: 0, y: 0, width: w, height: 3)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, fill.animation(forKey: key) == nil else { return }
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = -w / 2
        a.toValue = track.bounds.width + w / 2
        a.duration = 1.4
        a.repeatCount = .infinity
        fill.add(a, forKey: key)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: revealURL == nil ? .arrow : .pointingHand) }
    // the card is its own surface: clicks on it don't reach the picture under it
    override func mouseDown(with event: NSEvent) {}

    @objc private func revealTapped() {
        if let u = revealURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        hide()
    }

    @objc private func stopTapped() {
        if sending { onStop?() }
        hide()
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        isHidden = true
        sending = false
    }

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// A file's type icon, as Finder shows one it has no picture of (the default app's document icon: Chrome's page for a PDF on a Mac
    /// where Chrome opens them).
    private static func fileIcon(_ name: String) -> NSImage {
        let ext = (name as NSString).pathExtension
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }

    /// The file's icon: its Quick Look thumbnail when the file is here (a PDF's first page, a picture), as Finder draws it; the type's
    /// icon until that comes, or for a file still coming from the other end.
    private func setIcon(_ name: String, _ url: URL?) {
        guard let url else { thumbFor = nil; icon.image = Self.fileIcon(name); return }
        guard url != thumbFor else { return }
        thumbFor = url
        icon.image = Self.fileIcon(name)
        let scale = window?.backingScaleFactor ?? 2
        let ask = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 32, height: 32), scale: scale, representationTypes: .thumbnail)
        ask.iconMode = true     // the page with its fold and shadow, as Finder's icon view
        QLThumbnailGenerator.shared.generateBestRepresentation(for: ask) { [weak self] rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, self.thumbFor == url else { return }
                self.icon.image = img
            }
        }
    }

    /// a received file: a click on the card shows it in Finder
    private var revealURL: URL?
    /// two lines (a name over how far it is) or one, centred (Copied, Nothing is copied…)
    private lazy var titleTop = title.topAnchor.constraint(equalTo: topAnchor, constant: 11)
    private lazy var titleMiddle = title.centerYAnchor.constraint(equalTo: centerYAnchor)

    override func mouseUp(with event: NSEvent) {
        if let u = revealURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    /// " · 40 sec left" / " · 还剩 40 秒" once there's a rate to tell it from: one unit, seconds up to a minute, then whole minutes
    /// ("2 min", "95 min"), as on every platform. By hand: DateComponentsFormatter wrote 40秒 and 1分钟 in Chinese, with no space.
    static func left(_ s: Double?) -> String {
        guard let s, s.isFinite, s >= 1 else { return "" }
        let secs = Int(min(s, 1e7).rounded(.up))
        let d = secs <= 60 ? T("viewer.file.left.sec", secs) : T("viewer.file.left.min", (secs + 59) / 60)
        return " · " + T("viewer.file.left", d)
    }

    /// "To Office PC · 2 of 3 · 5.1 MB of 8.4 MB": where it goes (or comes from), which one, how much
    private static func line(out: Bool, _ who: String, _ done: String, _ size: String, _ i: Int, _ n: Int) -> String {
        if n > 1 { return out ? T("viewer.file.to.many", who, i, n, done, size) : T("viewer.file.from.many", who, i, n, done, size) }
        return out ? T("viewer.file.to", who, done, size) : T("viewer.file.from", who, done, size)
    }

    /// The state the card says; `to` is the computer's name.
    func show(_ e: ViewerFileSender.Event, to: String) {
        hideTimer?.invalidate()
        hideTimer = nil
        revealURL = nil
        toolTip = nil
        reveal.isHidden = true
        func over(_ seconds: TimeInterval) {
            sending = false
            paused = false
            isHidden = false
            showsBar = false
            close.toolTip = T("viewer.file.close")
            close.setAccessibilityLabel(T("viewer.file.close"))
            hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.hide() }
        }
        func going(_ name: String, _ size: Int, _ done: Int?, _ url: URL? = nil) {
            sending = true
            paused = false
            isHidden = false
            if url != nil || title.stringValue != name || thumbFor == nil { setIcon(name, url) }
            setTitle(name)
            fraction = done.map { size > 0 ? CGFloat(min($0, size)) / CGFloat(size) : 1 }
            showsBar = true
            close.toolTip = T("viewer.file.stop")
            close.setAccessibilityLabel(T("viewer.file.stop"))
        }
        let bytes = { (n: Int) in Self.bytes.string(fromByteCount: Int64(n)) }
        switch e {
        case let .sending(name, size, done, index, count, left, url):
            going(name, size, done, url)
            if let done {
                // the direction stays when time left shows: going out and coming in never read the same
                detail.stringValue = Self.line(out: true, to, bytes(min(done, size)), bytes(size), index, count) + Self.left(left)
            } else {
                detail.stringValue = count > 1 ? T("viewer.file.to.many.start", index, count, to, bytes(size)) : T("viewer.file.to.start", to, bytes(size))
            }
        case let .receiving(name, size, done, index, count, left):
            going(name, size, done)
            detail.stringValue = Self.line(out: false, to, bytes(min(done, size)), bytes(size), index, count) + Self.left(left)
        case let .paused(name):
            // the same file: its bar stays where it got to, dimmed; one not seen going here: no bar
            let got = !isHidden && sending && title.stringValue == name ? fraction : nil
            going(name, 1, nil)
            fraction = got
            paused = got != nil
            showsBar = got != nil
            detail.stringValue = T("remote.file.paused")
        case let .saved(name, index, count, blurt):
            // the next file follows at once: only the last one's done moment stays
            guard index >= count else { return }
            icon.image = Self.okMark
            setTitle(count > 1 ? T("viewer.file.count", count) : name)
            detail.stringValue = T(blurt ? "viewer.file.saved.to.blurt" : "viewer.file.saved.to", to)
            over(5)
        case let .received(url, index, count):
            guard index >= count else { return }
            icon.image = Self.okMark
            setTitle(count > 1 ? T("viewer.file.count", count) : url.lastPathComponent)
            detail.stringValue = T("viewer.file.received")
            revealURL = url
            toolTip = T("viewer.file.reveal")
            reveal.isHidden = false
            over(8)
        case let .copied(image):
            icon.image = Self.okMark
            setTitle(T(image ? "viewer.copied.image" : "viewer.copied.text"))
            detail.stringValue = ""
            over(4)
        case let .nothing(why):
            // nothing there, or locked, is a state: the info mark. What can't come is a failure: the triangle
            icon.image = why == "empty" || why == "locked" || why.isEmpty ? Self.infoMark : Self.attnMark
            let key = ["locked": "viewer.copied.none.locked", "too_big": "viewer.copied.none.too_big", "too_large": "viewer.copied.none.too_large",
                       "unsupported": "viewer.copied.none.unsupported", "update": "viewer.copied.none.update",
                       "limit": "remote.public.files.over"][why] ?? "viewer.copied.none.empty"
            setTitle(T(key, to))
            detail.stringValue = ""
            over(6)
        case let .failed(name, why, incoming):
            icon.image = Self.attnMark
            let key: String
            if incoming {
                key = why == "space" ? "viewer.file.failed.in.space" : "viewer.file.failed.in.other"
            } else {
                key = ["space": "viewer.file.failed.space", "too_big": "viewer.file.failed.too_big", "locked": "viewer.file.failed.locked",
                       "public_limit": "remote.public.files.over"][why]
                    ?? "viewer.file.failed.other"
            }
            if name.isEmpty { setTitle(T(key)); detail.stringValue = "" } else { setTitle(name); detail.stringValue = T(key) }
            over(8)
        case .stopped:
            hide()
        }
        let one = detail.stringValue.isEmpty
        if case .sending = e {} else if case .receiving = e {} else if case .paused = e {} else { thumbFor = nil }
        titleTop.isActive = !one
        titleMiddle.isActive = one
        titleToClose.isActive = reveal.isHidden
        titleToReveal.isActive = !reveal.isHidden
        // one line hugs its text (wrapping past the widest); two keep one width, the block centred when there's no bar under it
        title.lineBreakMode = one ? .byWordWrapping : .byTruncatingMiddle
        title.maximumNumberOfLines = one ? 2 : 1
        if one {
            let chrome = Self.chrome(icon: 26)
            let text = ceil(title.attributedStringValue.size().width) + 4
            wide.constant = min(Self.oneLine.upperBound, max(Self.oneLine.lowerBound, text + chrome))
            title.preferredMaxLayoutWidth = wide.constant - chrome
            iconWide.constant = 26
            tall.constant = text + chrome > Self.oneLine.upperBound ? Self.height : Self.oneLineHeight     // wrapped: two lines' room
        } else {
            wide.constant = Self.width
            iconWide.constant = 32
            tall.constant = Self.height
            title.preferredMaxLayoutWidth = 0
            let block = title.intrinsicContentSize.height + 1 + detail.intrinsicContentSize.height
            titleTop.constant = showsBar ? 11 : ((Self.height - block) / 2).rounded()
        }
        detail.toolTip = detail.stringValue
        setAccessibilityLabel([title.stringValue, detail.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
        needsLayout = true
    }

    private func setTitle(_ s: String) {
        title.stringValue = s
        // cut in the middle: the whole name on hover
        title.toolTip = s
    }

    /// done: the ok disc with its check (system.md §2.3: done always has the check shape)
    private static let okMark: NSImage = NSImage(size: NSSize(width: 32, height: 32), flipped: true) { r in
        let d = r.insetBy(dx: 5, dy: 5)
        BrandColor.Island.ok.setFill()
        NSBezierPath(ovalIn: d).fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
        BlurtIcon.check.draw(in: ctx, rect: d.insetBy(dx: 4.5, dy: 4.5), color: BrandColor.srgb(0x13250A).cgColor, flipped: true, weight: 1.35)
        return true
    }

    /// nothing there to get: the info mark, in the card's secondary white
    private static let infoMark: NSImage = NSImage(size: NSSize(width: 32, height: 32), flipped: true) { r in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
        BlurtIcon.info.draw(in: ctx, rect: r.insetBy(dx: 4, dy: 4), color: NSColor.white.withAlphaComponent(0.7).cgColor, flipped: true)
        return true
    }

    /// not sent: the attention triangle
    private static let attnMark: NSImage = NSImage(size: NSSize(width: 32, height: 32), flipped: true) { r in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
        BlurtIcon.warning.draw(in: ctx, rect: r.insetBy(dx: 4, dy: 4), color: BrandColor.Island.attn.cgColor, flipped: true)
        return true
    }

    #if DEBUG || BLURT_TEST_HOOKS
    var testState: [String: Any] {
        ["shown": !isHidden, "title": title.stringValue, "detail": detail.stringValue, "frame": NSStringFromRect(frame),
         "fraction": fraction.map { Double($0) } ?? -1, "bar": showsBar, "paused": paused, "reveal": !reveal.isHidden,
         "title_frame": NSStringFromRect(title.frame), "detail_frame": NSStringFromRect(detail.frame)]
    }
    #endif
}
