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
                    if outdated { Text("Update \(name) to use this.") }
                }
                Section {
                    if t.rows.isEmpty {
                        Text("Files you send or get appear here.").foregroundStyle(.secondary)
                    }
                    ForEach(t.rows) { r in row(r) }
                }
            }
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
        .alert("Allow Blurt to add photos in Settings.", isPresented: $photosOff) {
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
            // a received file: a tap opens a menu, Open first
            Menu {
                Button { preview = u } label: { Label("Open", systemImage: "eye") }
                ShareLink(item: u) { Label("Share…", systemImage: "square.and.arrow.up") }
                if r.isMedia, !saved.contains(r.id) {
                    Button { save(u, video: r.isVideo, key: r.id) } label: { Label("Save to Photos", systemImage: "photo.badge.plus") }
                }
            } label: {
                TransferRowView(r: r, meeting: l.meeting, canContinue: false)
            }
            .foregroundStyle(.primary)
        } else {
            TransferRowView(r: r, meeting: l.meeting, canContinue: t.canContinue(r), stop: { t.stop(r) }, again: { t.again(r) })
        }
    }
}

struct TransferRowView: View {
    let r: TransferRow
    let meeting: Bool
    let canContinue: Bool
    var stop: () -> Void = {}
    var again: () -> Void = {}

    private var icon: String {
        switch r.phase {
        case .failed: return "exclamationmark.circle"
        case .done: return r.incoming ? (r.isMedia ? "photo" : "doc") : "checkmark.circle"
        case .compressing: return "doc.zipper"
        default: return r.incoming ? "arrow.down.circle" : "arrow.up.circle"
        }
    }

    /// A line wraps only between its parts: "148 MB / 412 MB" and 还剩 3 分钟 stay whole.
    static func breaksAtDots(_ line: String) -> String {
        line.components(separatedBy: " · ").map { part in
            part.map { $0 == " " ? "\u{00A0}" : String($0) }.joined(separator: "\u{2060}")
        }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(r.phase == .done ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.name).lineLimit(1).truncationMode(.middle)
                if r.phase == .going || r.phase == .paused {
                    ProgressView(value: r.fraction).tint(r.phase == .paused ? .secondary : .accentColor)
                }
                Text(Self.breaksAtDots(TransferWords.line(r, meeting: meeting)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if canContinue {
                Button(action: again) { Image(systemName: "arrow.clockwise.circle.fill").symbolRenderingMode(.hierarchical).font(.title2) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Continue"))
            }
            if !r.isOver, r.phase != .compressing {
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
