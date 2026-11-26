// Share → Blurt (docs/design/remote-files.md §What the user does): the button names the computer last controlled, and that tap is the act.
// The content sits in the system's own sheet, in the phone's light or dark appearance.
// What's shared (up to 50 pictures, videos or files) is copied into the App Group's outbox for that computer; the app sends it the next time
// it's open and connected to it, and drops anything older than an hour. Nothing goes over the network from here.
import ImageIO
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let card = UIView()
    private let title_ = UILabel()
    /// what's being sent: the first item small, and how many beside the title
    private let thumb = UIImageView()
    private let count = UILabel()
    private let line = UILabel()
    private let send = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let mint = UIColor(red: 0.102, green: 0.643, blue: 0.529, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        // the system's sheet, light or dark as the phone is, with the content in it (not a card over a grey wash)
        view.backgroundColor = .systemBackground
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        title_.text = "Blurt"
        title_.font = .systemFont(ofSize: 17, weight: .semibold)
        title_.textColor = .label
        count.font = .systemFont(ofSize: 15)
        count.textColor = .secondaryLabel
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 8
        thumb.layer.cornerCurve = .continuous
        thumb.backgroundColor = .tertiarySystemFill
        thumb.tintColor = .secondaryLabel
        thumb.image = UIImage(systemName: "doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17))
        thumb.contentMode = .center
        NSLayoutConstraint.activate([thumb.widthAnchor.constraint(equalToConstant: 40), thumb.heightAnchor.constraint(equalToConstant: 40)])
        let names = UIStackView(arrangedSubviews: [title_, count])
        names.axis = .vertical
        names.spacing = 1
        let head = UIStackView(arrangedSubviews: [thumb, names])
        head.spacing = 12
        head.alignment = .center
        line.font = .systemFont(ofSize: 15)
        line.textColor = .secondaryLabel
        line.numberOfLines = 0
        line.isHidden = true

        var s = UIButton.Configuration.filled()
        s.baseBackgroundColor = mint
        s.baseForegroundColor = .white
        s.cornerStyle = .large
        s.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        s.titleLineBreakMode = .byTruncatingMiddle
        s.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = .systemFont(ofSize: 17, weight: .semibold)
            return a
        }
        send.configuration = s
        send.addAction(UIAction { [weak self] _ in self?.go() }, for: .touchUpInside)
        var c = UIButton.Configuration.plain()
        c.title = String(localized: "Cancel")
        c.baseForegroundColor = mint
        cancel.configuration = c
        cancel.addAction(UIAction { [weak self] _ in self?.close(sent: false) }, for: .touchUpInside)
        spinner.hidesWhenStopped = true

        let stack = UIStackView(arrangedSubviews: [head, line, send, spinner, cancel])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor),
            card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        // as wide as the sheet; no wider than a phone on an iPad or held wide
        let wide = card.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor)
        wide.priority = .required - 1
        wide.isActive = true

        let n = providers.count
        count.text = String(localized: "\(n) items")
        count.isHidden = n < 2
        loadThumb()

        if let t = Outbox.target, Outbox.shared != nil {
            send.configuration?.title = String(localized: "Send to \(t.name)")
        } else {
            line.text = String(localized: "Pair a computer in Blurt first.")
            line.isHidden = false
            send.isHidden = true
        }
    }

    /// The first item's picture, small, read without decoding the whole photo (an extension has little memory); else a document's mark.
    private func loadThumb() {
        guard let p = providers.first else { return }
        let show: (UIImage?) -> Void = { [weak self] i in
            guard let i else { return }
            DispatchQueue.main.async { self?.thumb.contentMode = .scaleAspectFill; self?.thumb.image = i }
        }
        if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            _ = p.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { u, _ in
                guard let u, let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return }
                let o = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                         kCGImageSourceThumbnailMaxPixelSize: 120] as CFDictionary
                show(CGImageSourceCreateThumbnailAtIndex(src, 0, o).map { UIImage(cgImage: $0) })
            }
        } else {
            p.loadPreviewImage(options: [NSItemProviderPreferredImageSizeKey: CGSize(width: 120, height: 120)]) { o, _ in show(o as? UIImage) }
        }
    }

    private var providers: [NSItemProvider] {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        return Array(items.flatMap { $0.attachments ?? [] }.prefix(Outbox.most))
    }

    /// Copies each item into a new share, then seals it for the computer named on the button.
    private func go() {
        guard let t = Outbox.target, let box = Outbox.shared, let folder = box.open() else { return close(sent: false) }
        send.isEnabled = false
        send.isHidden = true
        cancel.isHidden = true
        spinner.startAnimating()
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

    private func done(_ nothing: Bool) {
        spinner.stopAnimating()
        guard !nothing else { return close(sent: false) }
        line.text = String(localized: "Open Blurt within an hour to send.")
        line.isHidden = false
        var c = UIButton.Configuration.plain()
        c.title = String(localized: "Done")
        c.baseForegroundColor = mint
        cancel.configuration = c
        cancel.isHidden = false
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
        let ids = p.registeredTypeIdentifiers
        let type = ids.first { UTType($0)?.conforms(to: .movie) == true }
            ?? ids.first { UTType($0)?.conforms(to: .image) == true }
            ?? ids.first { UTType($0).map { $0.conforms(to: .data) || $0.conforms(to: .package) } == true }
            ?? UTType.data.identifier
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
