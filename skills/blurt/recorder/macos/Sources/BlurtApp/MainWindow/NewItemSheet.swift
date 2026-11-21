// New Item (BA-21: the list had no way to add one by hand): the list heading's + (and ⌘N) opens this sheet over the
// main window. A kind (Issue / Idea / To-do / Note), a title, optional details; Create writes it with `items.py add`
// into the place on show — the project in view, else the current project, else the inbox — and the list selects it.
// Nothing else to fill in: the rest (severity, module, steps) is the detail pane's, as for any item.
// Pictures (BA-52): pasted (⌘V with a picture on the clipboard), dropped on the sheet, or chosen with Add Image…; they
// go in as the item's frames (`items.py add` copies them into the store). ⌘V in the list or a picture dropped on it
// opens the sheet already holding what came (MainWindowController.newItemHolding); a title is then optional.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BlurtCore

struct NewItemSheet: View {
    /// the app's one kind order (KindStyle.builtIn, the filters, the 1–4 keys): issue, idea, note, task
    enum Kind: String, CaseIterable, Identifiable { case issue, idea, note, task; var id: String { rawValue } }

    /// What ⌘V or a drop on the list brought: text (its first line the title) and pictures.
    struct Prefill {
        var title = "", details = "", images: [URL] = []
        /// other files (v1.0.23: a PDF, a video dropped on the list): referenced by the item, never copied (one in a
        /// temporary place is: FilePlace)
        var files: [URL] = []
        init(images: [URL]) { self.images = images }
        /// Text: its first line the title (cut at 60), the rest the details.
        init(text: String, images: [URL] = []) {
            self.images = images
            let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let first = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
            title = first.count > 60 ? String(first.prefix(59)) + "…" : first
            details = (first.count > 60 ? text : lines.dropFirst().joined()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// "inbox" or a project id, and the name the sheet says it goes to
    let target: String
    let targetName: String
    var close: (_ uid: String?) -> Void

    init(target: String, targetName: String, prefill: Prefill? = nil, close: @escaping (_ uid: String?) -> Void) {
        self.target = target
        self.targetName = targetName
        self.close = close
        _title = State(initialValue: prefill?.title ?? "")
        _details = State(initialValue: prefill?.details ?? "")
        _images = StateObject(wrappedValue: NewItemImages(prefill?.images ?? [], files: prefill?.files ?? []))
    }

    @State private var kind: Kind = .issue
    @State private var title = ""
    @State private var details = ""
    @StateObject private var images: NewItemImages
    @State private var dropping = false
    @State private var saving = false
    /// written by `items.py add` already (its files still to attach)
    @State private var madeItem: (ref: String, uid: String?)?
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(T("main.new_item.title")).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(T("main.new_item.into", targetName)).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { k in Text(T("kind.\(k.rawValue)")).tag(k) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.top, 14)
            TextField(T("main.new_item.title_placeholder"), text: $title)
                .textFieldStyle(.roundedBorder).focused($titleFocused).padding(.top, 12)
                .onSubmit(create)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $details).font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(4)
                if details.isEmpty {
                    Text(T("main.new_item.details_placeholder")).font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                }
            }
            .frame(height: 110)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .padding(.top, 10)
            pictures.padding(.top, 10)
            if !images.files.isEmpty { fileRows.padding(.top, 12) }
            HStack(spacing: 10) {
                if let e = error { Text(e).font(.system(size: 12)).foregroundStyle(Color.brandErr).lineLimit(2) }
                if saving { BrandSpinnerView(size: 12) }
                Spacer()
                Button(T("action.cancel")) { close(nil) }.keyboardShortcut(.cancelAction)
                Button(T("main.new_item.create"), action: create).keyboardShortcut(.defaultAction)
                    .disabled((title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.urls.isEmpty && images.files.isEmpty) || saving)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
        .frame(width: 460)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.brandInk, lineWidth: 2).padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in images.take(providers); return true }
        .onAppear { titleFocused = images.urls.isEmpty || !title.isEmpty; images.listenForPaste() }
        .onDisappear { images.stopListening() }
    }

    /// The files the item will refer to: the Finder's icon, the name, its × (v1.0.23).
    var fileRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(images.files, id: \.self) { u in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 18, height: 18)
                    Text(u.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button { images.files.removeAll { $0 == u } } label: {
                        Image(nsImage: BlurtIcon.x.symbolImage(pointSize: 7, weight: .bold)).frame(width: 15, height: 15)
                            .background(Circle().fill(.regularMaterial))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(T("main.new_item.remove_file", u.lastPathComponent))
                }
                .help(u.path)
            }
        }
    }

    /// The pictures so far (a row of thumbnails, each with its ×), then Add Image… and the ways in.
    var pictures: some View {
        HStack(spacing: 8) {
            ForEach(images.urls, id: \.self) { u in
                // the × straddles the thumbnail's corner inside the stack's own frame (the thumbnail is inset by
                // 6 pt), so it never reaches up into the Details box above
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: NSImage(contentsOf: u) ?? NSImage()).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                        .padding(.top, 6).padding(.trailing, 6)
                    Button { images.urls.removeAll { $0 == u } } label: {
                        Image(nsImage: BlurtIcon.x.symbolImage(pointSize: 7, weight: .bold)).frame(width: 15, height: 15)
                            .background(Circle().fill(.regularMaterial))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(T("main.new_item.remove_image"))
                }
            }
            Button(T("main.new_item.add_image")) { images.choose() }.controlSize(.small)
            if images.urls.isEmpty {
                Text(T("main.new_item.image_hint")).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
    }

    func create() {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // pictures alone: a title that says when (the user can rename it in the detail)
        if t.isEmpty, !images.urls.isEmpty { t = T("main.new_item.image_title", Date().formatted(date: .omitted, time: .shortened)) }
        if t.isEmpty, let f = images.files.first { t = f.deletingPathExtension().lastPathComponent }
        guard !t.isEmpty, !saving else { return }
        saving = true
        error = nil
        // typed in here: "Added by hand", never "Imported"
        var item: [String: Any] = ["kind": kind.rawValue, "title": t, "source": ["type": "manual"]]
        let d = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { item["details"] = d }          // the item's Details section (store.BODY)
        // copied into the store — from a copy of our own, so `items.py add` never hard-links the user's original
        if !images.urls.isEmpty { item["frames"] = NewItemImages.privateCopies(images.urls).map { ["path": $0.path] } }
        let json = (try? JSONSerialization.data(withJSONObject: item)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        emit(["event": "item_new", "kind": kind.rawValue, "target": target == "inbox" ? "inbox" : "project", "images": images.urls.count])
        let files = images.files
        // the item was written but its files failed: Create again only adds the files (never a second item)
        if let made = madeItem { return attachFiles(files, to: made.ref, uid: made.uid) }
        Scripts.call("items.py", ["add", "--project", target, "--json", json], timeout: 30) { r in
            switch r {
            case .success(let o):
                let uid = o["uid"] as? String ?? (o["item"] as? [String: Any])?["uid"] as? String
                let path = o["path"] as? String ?? (o["item"] as? [String: Any])?["path"] as? String
                guard !files.isEmpty, let ref = path ?? uid else { saving = false; return close(uid) }
                madeItem = (ref, uid)
                attachFiles(files, to: ref, uid: uid)
            case .failure(let f):
                saving = false
                error = f.localized
            }
        }
    }

    /// The files the new item refers to (a temporary one copied into its assets first).
    private func attachFiles(_ files: [URL], to ref: String, uid: String?) {
        saving = true
        var args = ["attach", ref]
        for u in files { args += [FilePlace.isTemporary(u) ? "--keep" : "--file", u.path] }
        Scripts.call("items.py", args, timeout: 60) { r in
            saving = false
            if case .failure(let f) = r { error = f.localized } else { close(uid) }
        }
    }
}

/// The sheet's pictures: files on disk (a pasted or dropped picture's data is written to a temporary PNG first), and
/// ⌘V while the sheet is up — a picture on the clipboard comes here instead of into the text field.
@MainActor
final class NewItemImages: ObservableObject {
    @Published var urls: [URL]
    @Published var files: [URL]
    private var monitor: Any?

    init(_ urls: [URL], files: [URL] = []) { self.urls = urls; self.files = files }

    /// Pictures on a pasteboard as files: image files as they are, image data as temporary PNGs.
    static func files(from pb: NSPasteboard) -> [URL] {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let files = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if !files.isEmpty { return files }
        guard urls.isEmpty, let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] else { return [] }
        return imgs.compactMap { img in
            guard let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            return temp(png)
        }
    }

    static func temp(_ png: Data) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-new-item", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(UUID().uuidString + ".png")
        return (try? png.write(to: u)) == nil ? nil : u
    }

    func add(_ new: [URL]) { urls += new.filter { !urls.contains($0) } }

    /// `urls` copied into a temporary folder of ours: what `items.py add` imports (it hard-links where it can, and a
    /// hard link to the user's own picture would change with it).
    static func privateCopies(_ urls: [URL]) -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-new-item/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return urls.enumerated().map { i, u in
            let dst = dir.appendingPathComponent("\(i)-\(u.lastPathComponent)")
            return (try? FileManager.default.copyItem(at: u, to: dst)) != nil ? dst : u
        }
    }

    func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { add(p.urls) }
    }

    /// Dropped on the sheet: files, else picture data (a browser's or a chat's).
    func take(_ providers: [NSItemProvider]) {
        for pr in providers {
            if pr.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = pr.loadObject(ofClass: URL.self) { u, _ in
                    guard let u else { return }
                    var dir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir), !dir.boolValue else { return }
                    let image = UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) == true
                    DispatchQueue.main.async {
                        if image { self.add([u]) } else if !self.files.contains(u) { self.files.append(u) }   // v1.0.23: any file
                    }
                }
            } else if pr.canLoadObject(ofClass: NSImage.self) {
                _ = pr.loadObject(ofClass: NSImage.self) { img, _ in
                    guard let img = img as? NSImage, let tiff = img.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    DispatchQueue.main.async { if let u = Self.temp(png) { self.add([u]) } }
                }
            }
        }
    }

    func listenForPaste() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  e.charactersIgnoringModifiers == "v" else { return e }
            let got = Self.files(from: .general)
            guard !got.isEmpty else { return e }        // text: the field pastes it as always
            self.add(got)
            return nil
        }
    }

    func stopListening() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}
