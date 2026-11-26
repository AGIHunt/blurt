// Share → Blurt (docs/design/remote-files.md §What the user does): the title names the computer last controlled, and Send is the act.
// Laid out as Apple's own extensions are: a navigation bar (Cancel, the computer, Send) over what's being sent in an inset group, in the
// phone's light or dark appearance. A share sheet extension can't make its sheet shorter.
// What's shared (up to 1,000 pictures, videos or files) is copied into the App Group's outbox for that computer; the app sends it the next
// time it's open and connected to it, and drops anything older than an hour. Nothing goes over the network from here.
import ImageIO
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let bar = UINavigationBar()
    private let item = UINavigationItem()
    /// what's being sent: the first item small, its name, and its size or how many
    private let group = UIView()
    private let thumb = UIImageView()
    private let name = UILabel()
    private let detail = UILabel()
    private let tick = UIImageView(image: UIImage(systemName: "checkmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)))
    /// under the group: nothing paired, or what happens next
    private let line = UILabel()
    private let mint = UIColor(red: 0.102, green: 0.643, blue: 0.529, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.tintColor = mint
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.setItems([item], animated: false)
        bar.standardAppearance.configureWithTransparentBackground()
        item.leftBarButtonItem = UIBarButtonItem(title: String(localized: "Cancel"), primaryAction: UIAction { [weak self] _ in self?.close(sent: false) })

        group.backgroundColor = .secondarySystemGroupedBackground
        group.layer.cornerRadius = 12
        group.layer.cornerCurve = .continuous
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 6
        thumb.layer.cornerCurve = .continuous
        thumb.backgroundColor = .tertiarySystemFill
        thumb.tintColor = .secondaryLabel
        thumb.image = UIImage(systemName: "doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17))
        thumb.contentMode = .center
        name.font = .preferredFont(forTextStyle: .body)
        name.lineBreakMode = .byTruncatingMiddle
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabel
        tick.tintColor = mint
        tick.isHidden = true
        tick.setContentHuggingPriority(.required, for: .horizontal)
        let words = UIStackView(arrangedSubviews: [name, detail])
        words.axis = .vertical
        words.spacing = 2
        let row = UIStackView(arrangedSubviews: [thumb, words, tick])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        group.addSubview(row)
        group.translatesAutoresizingMaskIntoConstraints = false
        line.font = .preferredFont(forTextStyle: .footnote)
        line.textColor = .secondaryLabel
        line.numberOfLines = 0
        line.translatesAutoresizingMaskIntoConstraints = false
        [bar, group, line].forEach(view.addSubview)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: g.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            group.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 16),
            group.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            group.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: group.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: group.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -16),
            thumb.widthAnchor.constraint(equalToConstant: 44),
            thumb.heightAnchor.constraint(equalToConstant: 44),
            line.topAnchor.constraint(equalTo: group.bottomAnchor, constant: 8),
            line.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -16),
        ])

        let list = providers
        name.text = list.first.flatMap(Self.shownName) ?? ""
        if list.count > 1 { detail.text = String(localized: "\(list.count) items") }
        else { detail.text = list.first.flatMap { Self.type(of: $0) }.flatMap { UTType($0)?.localizedDescription } }
        loadThumb()

        if let t = Outbox.target, Outbox.shared != nil {
            item.title = t.name
            let send = UIBarButtonItem(title: String(localized: "Send"), primaryAction: UIAction { [weak self] _ in self?.go() })
            send.style = .done
            item.rightBarButtonItem = send
        } else {
            item.title = "Blurt"
            line.text = String(localized: "Pair a computer in Blurt first.")
        }
    }

    /// An item's name as it was shared, if it has one; else its kind ("JPEG image").
    private static func shownName(_ p: NSItemProvider) -> String? {
        p.suggestedName ?? type(of: p).flatMap { UTType($0)?.localizedDescription }
    }

    /// The first item's picture, small, read without decoding the whole photo (an extension has little memory); else a document's mark.
    /// A single picture's file also gives its name and size.
    private func loadThumb() {
        let list = providers
        guard let p = list.first else { return }
        let show: (UIImage?) -> Void = { [weak self] i in
            guard let i else { return }
            DispatchQueue.main.async { self?.thumb.contentMode = .scaleAspectFill; self?.thumb.image = i }
        }
        if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            _ = p.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] u, _ in
                guard let u, let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return }
                let o = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                         kCGImageSourceThumbnailMaxPixelSize: 132] as CFDictionary
                show(CGImageSourceCreateThumbnailAtIndex(src, 0, o).map { UIImage(cgImage: $0) })
                let bytes = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
                let file = u.lastPathComponent
                DispatchQueue.main.async {
                    if p.suggestedName == nil { self?.name.text = file }
                    if list.count == 1, let bytes { self?.detail.text = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
                }
            }
        } else {
            p.loadPreviewImage(options: [NSItemProviderPreferredImageSizeKey: CGSize(width: 132, height: 132)]) { o, _ in show(o as? UIImage) }
        }
    }

    /// What an item is sent as: a video or a picture as it is, else whatever file it is.
    private static func type(of p: NSItemProvider) -> String? {
        let ids = p.registeredTypeIdentifiers
        return ids.first { UTType($0)?.conforms(to: .movie) == true }
            ?? ids.first { UTType($0)?.conforms(to: .image) == true }
            ?? ids.first { UTType($0).map { $0.conforms(to: .data) || $0.conforms(to: .package) } == true }
    }

    private var providers: [NSItemProvider] {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        return Array(items.flatMap { $0.attachments ?? [] }.prefix(Outbox.most))
    }

    /// Copies each item into a new share, then seals it for the computer named on the button.
    private func go() {
        guard let t = Outbox.target, let box = Outbox.shared, let folder = box.open() else { return close(sent: false) }
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        item.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        item.leftBarButtonItem?.isEnabled = false
        let list = providers
        var names = [String?](repeating: nil, count: list.count)
        let g = DispatchGroup()
        let lock = NSLock()
        for (n, p) in list.enumerated() {
            g.enter()
            Self.copy(p, into: folder, box: box) { name in
                lock.lock(); names[n] = name; lock.unlock()
                g.leave()
            }
        }
        g.notify(queue: .main) { [weak self] in
            let got = names.compactMap { $0 }
            box.seal(folder, for: t, files: got)
            self?.done(got.isEmpty)
        }
    }

    /// Copied: a ✓ on the item, what happens next under it, and Done where Send was.
    private func done(_ nothing: Bool) {
        guard !nothing else { return close(sent: false) }
        tick.isHidden = false
        line.text = String(localized: "Open Blurt within an hour to send.")
        item.leftBarButtonItem = nil
        let done = UIBarButtonItem(title: String(localized: "Done"), primaryAction: UIAction { [weak self] _ in self?.close(sent: true) })
        done.style = .done
        item.rightBarButtonItem = done
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.close(sent: true) }
    }

    private var closed = false
    private func close(sent: Bool) {
        guard !closed else { return }
        closed = true
        if sent { extensionContext?.completeRequest(returningItems: nil) } else {
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
    }

    /// One item as a file: a video or a picture as it is, else whatever file it is. Its name is the one it was shared with.
    private static func copy(_ p: NSItemProvider, into folder: URL, box: Outbox, done: @escaping (String?) -> Void) {
        let type = Self.type(of: p) ?? UTType.data.identifier
        let ext = UTType(type)?.preferredFilenameExtension
        func name(_ u: URL?) -> String? {
            let e = u?.pathExtension.isEmpty == false ? u!.pathExtension : ext
            guard let base = p.suggestedName ?? u?.deletingPathExtension().lastPathComponent else { return nil }
            guard let e, !e.isEmpty, !base.lowercased().hasSuffix("." + e.lowercased()) else { return base }
            return base + "." + e
        }
        _ = p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
            if let url { return done(box.add(url, as: name(url), to: folder)) }
            // only in memory (an edited screenshot): written out first
            _ = p.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data else { return done(nil) }
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + (ext.map { "." + $0 } ?? ""))
                guard (try? data.write(to: tmp)) != nil else { return done(nil) }
                defer { try? FileManager.default.removeItem(at: tmp) }
                done(box.add(tmp, as: name(nil) ?? ("Image" + (ext.map { "." + $0 } ?? "")), to: folder))
            }
        }
    }
}
