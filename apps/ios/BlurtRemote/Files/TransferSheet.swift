// The Transfer sheet, from the button next to the screen button (docs/design/remote-files.md §What the user does): send photos or files
// to the computer in hand, get what's copied there, and the list of transfers, this run's and the last 50 before. A received file opens
// on a tap, with Share… and, for pictures and videos, Save to Photos.
import BlurtRemoteKit
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct TransferSheet: View {
    @ObservedObject private var t = Transfers.shared
    @ObservedObject private var l = Link.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pickingPhotos = false
    @State private var pickingFiles = false
    @State private var preview: URL?
    @State private var photosOff = false
    /// rows (and the copied image) already saved to Photos this time
    @State private var saved: Set<String> = []

    private var name: String { l.current?.title ?? "" }
    /// the computer takes files: as it said in its last session (they wait if it isn't back yet)
    private var takesFiles: Bool { l.current != nil && l.hostFeatures.contains(RemoteFeature.files) }
    private var givesClipboard: Bool { l.hostFeatures.contains(RemoteFeature.clipboard) }
    /// a computer whose Blurt is older than this: it says so
    private var outdated: Bool { !l.hostFeatures.isEmpty && !(takesFiles && givesClipboard) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { pickingPhotos = true } label: { Label("Send Photos…", systemImage: "photo.on.rectangle") }
                        .disabled(!takesFiles)
                    Button { pickingFiles = true } label: { Label("Send Files…", systemImage: "folder") }
                        .disabled(!takesFiles)
                    Button { t.getCopied() } label: {
                        HStack {
                            Label("Get Copied Items from \(name)", systemImage: "doc.on.clipboard")
                            Spacer()
                            if t.getting { ProgressView() }
                        }
                    }
                    .disabled(!givesClipboard || !l.ready || t.getting)
                    if let s = t.said { saidRow(s) }
                } footer: {
                    if outdated { Text("To use this, update Blurt on \(name).") }
                }
                Section {
                    if t.rows.isEmpty {
                        Text("Files you send or get appear here.").foregroundStyle(.secondary)
                    }
                    ForEach(t.rows) { r in row(r) }
                }
            }
            // the first section ~20 pt under the title, as in Settings (the default left ~44 pt)
            .listSectionSpacing(.compact)
            .contentMargins(.top, 11, for: .scrollContent)
            .navigationTitle("Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheet(isPresented: $pickingPhotos) {
            PhotoPicker { t.sendPhotos($0) }.ignoresSafeArea()
        }
        .sheet(isPresented: $pickingFiles) {
            DocumentPicker { t.sendPicked($0) }.ignoresSafeArea()
        }
        .quickLookPreview($preview)
        .onAppear { t.refreshOutbox() }
        .alert("To save to Photos, allow access in Settings.", isPresented: $photosOff) {
            Button("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// What Get Copied Items came to, under its button.
    @ViewBuilder private func saidRow(_ s: Transfers.Said) -> some View {
        HStack(spacing: 12) {
            Image(systemName: s.kind == .note ? "info.circle" : "checkmark.circle.fill")
                .foregroundStyle(s.kind == .note ? Color.secondary : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title)
                if let d = s.detail { Text(d).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            if case let .image(u) = s.kind {
                photosButton(key: "said-\(s.id)", url: u, video: false)
            }
        }
    }

    @ViewBuilder private func photosButton(key: String, url: URL, video: Bool) -> some View {
        if saved.contains(key) {
            Image(systemName: "checkmark").foregroundStyle(.secondary).accessibilityLabel(Text("Save to Photos"))
        } else {
            Button("Save to Photos") { save(url, video: video, key: key) }
                .buttonStyle(.bordered)
                .font(.footnote)
        }
    }

    private func save(_ url: URL, video: Bool, key: String) {
        PhotoSave.save(url, video: video) { r in
            switch r {
            case .saved:
                saved.insert(key)
                Haptics.tick()
            case .denied: photosOff = true
            case .failed: break
            }
        }
    }

    @ViewBuilder private func row(_ r: TransferRow) -> some View {
        if let u = r.savedURL, FileManager.default.fileExists(atPath: u.path) {
            // a received file, as in Files: a tap opens it, a touch and hold has the rest. A Menu here popped over the row and the one above
            Button { preview = u } label: {
                TransferRowView(r: r, meeting: l.meeting, canContinue: false)
            }
            .foregroundStyle(.primary)
            .contextMenu {
                ShareLink(item: u) { Label("Share…", systemImage: "square.and.arrow.up") }
                if r.isMedia, !saved.contains(r.id) {
                    Button { save(u, video: r.isVideo, key: r.id) } label: { Label("Save to Photos", systemImage: "photo.badge.plus") }
                }
            }
            .accessibilityAction(named: Text("Share…")) { share(u) }
        } else {
            TransferRowView(r: r, meeting: l.meeting, canContinue: t.canContinue(r), away: t.away, stop: { t.stop(r) }, again: { t.again(r) })
        }
    }

    /// VoiceOver's way to Share…, which a context menu hides
    private func share(_ u: URL) {
        guard let w = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              var top = w.rootViewController else { return }
        while let p = top.presentedViewController { top = p }
        let c = UIActivityViewController(activityItems: [u], applicationActivities: nil)
        c.popoverPresentationController?.sourceView = top.view
        top.present(c, animated: true)
    }
}

struct TransferRowView: View {
    let r: TransferRow
    let meeting: Bool
    let canContinue: Bool
    var away = false
    var stop: () -> Void = {}
    var again: () -> Void = {}

    /// While it moves, which way; once over, what kind of file it is (or what went wrong)
    private var icon: String {
        switch r.phase {
        case .failed("stopped"): return Self.kind(r.file ?? r.name)
        case .failed: return "exclamationmark.circle"
        case .done: return Self.kind(r.file ?? r.name)
        case .compressing: return "doc.zipper"
        case .preparing: return "photo.on.rectangle"
        default: return r.incoming ? "arrow.down.circle" : "arrow.up.circle"
        }
    }

    private var iconColor: Color {
        if case let .failed(w) = r.phase, w != "stopped" { return .red }
        return .secondary
    }

    /// A file's kind as a symbol, as Files draws it small
    static func kind(_ name: String) -> String {
        guard let t = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
        if t.conforms(to: .image) { return "photo" }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return "film" }
        if t.conforms(to: .audio) { return "waveform" }
        if t.conforms(to: .archive) { return "doc.zipper" }
        if t.conforms(to: .pdf) { return "doc.richtext" }
        if t.conforms(to: .spreadsheet) { return "tablecells" }
        if t.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        return "doc"
    }

    /// The line as it may wrap: whole, else in two at one of its " · ", the later the better. "148 MB of 412 MB", "3 min left" and
    /// 还剩 3 分钟 stay whole, and no line starts or ends with "·" (the dot at the break goes).
    static func breaksAtDots(_ line: String) -> [String] {
        let parts = line.components(separatedBy: " · ").map { part in
            part.map { $0 == " " ? "\u{00A0}" : String($0) }.joined(separator: "\u{2060}")
        }
        func join(_ p: ArraySlice<String>) -> String { p.joined(separator: "\u{00A0}·\u{00A0}") }
        return [join(parts[...])] + stride(from: parts.count - 1, through: 1, by: -1).map { k in
            join(parts[..<k]) + "\n" + join(parts[k...])
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.name).lineLimit(1).truncationMode(.middle)
                if r.phase == .going || r.phase == .paused {
                    ProgressView(value: r.fraction).tint(r.phase == .paused ? .secondary : .accentColor)
                }
                HStack(alignment: .firstTextBaseline) {
                    ViewThatFits(in: .horizontal) {
                        ForEach(Self.breaksAtDots(TransferWords.line(r, meeting: meeting, canContinue: canContinue, away: away)), id: \.self) { t in
                            Text(t).lineLimit(2)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    // Continue under the bar's end, so every bar ends at the same place
                    if canContinue {
                        Spacer(minLength: 8)
                        Button("Continue", action: again)
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderless)
                    }
                }
            }
            Spacer(minLength: 0)
            if !r.isOver, r.phase != .compressing, r.phase != .preparing {
                Button(action: stop) {
                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical).font(.title2).foregroundStyle(Color.secondary)
                }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Stop"))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// The system's photo picker: what's picked is all the app sees, so no permission is asked.
struct PhotoPicker: UIViewControllerRepresentable {
    let picked: ([NSItemProvider]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var c = PHPickerConfiguration()
        c.selectionLimit = 0
        c.preferredAssetRepresentationMode = .current      // as it is: a HEIC stays HEIC, a video isn't re-encoded
        let p = PHPickerViewController(configuration: c)
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ v: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(picked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let picked: ([NSItemProvider]) -> Void
        init(_ p: @escaping ([NSItemProvider]) -> Void) { picked = p }
        func picker(_ p: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            p.dismiss(animated: true)
            picked(results.map(\.itemProvider))
        }
    }
}

/// Files' picker: files and folders, several at once. Opened in place, not copied: a folder is zipped where it is.
struct DocumentPicker: UIViewControllerRepresentable {
    let picked: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .folder], asCopy: false)
        p.allowsMultipleSelection = true
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ v: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(picked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let picked: ([URL]) -> Void
        init(_ p: @escaping ([URL]) -> Void) { picked = p }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { picked(urls) }
    }
}
