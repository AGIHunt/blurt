// Files to the computer a window shows (docs/design/remote-1.1.md §6): Send Files… or dropped on the picture, each to the host's
// Downloads in order, a chunk at a time, never more than `window` ahead of what the host says it has written. The window shows each
// one on its file card (ViewerFileCard): the name, how much the host has written, and × to stop.
import AppKit
import BlurtCore
import BlurtRemoteKit
import UniformTypeIdentifiers

final class ViewerFileSender {
    /// What the card shows, on the main thread. `done` is nil until the other end first says how much it has written.
    enum Event: Equatable {
        case sending(name: String, size: Int, done: Int?, index: Int, count: Int, left: Double?)
        /// a file from the host, coming here (Get Copied Files)
        case receiving(name: String, size: Int, done: Int, index: Int, count: Int, left: Double?)
        /// the session dropped mid-file: it goes on when it's back
        case paused(name: String)
        /// at the host; `blurt`: in its Downloads/Blurt (hosts that resume), else its Downloads
        case saved(name: String, index: Int, count: Int, blurt: Bool)
        /// here, in Downloads/Blurt
        case received(url: URL, index: Int, count: Int)
        /// what was copied there is on this Mac's clipboard now
        case copied(image: Bool)
        /// Get Copied Files found nothing to send: "empty", "locked", "too_big", "unsupported"
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
    /// the host's id: the receiver keys its parts by it
    private var device: String { link.computer.id }

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
            let data = (try? Data(contentsOf: url)) ?? Data()
            let image = RemoteFiles.isImage(name)
            DispatchQueue.main.sync {
                let pb = NSPasteboard.general
                pb.clearContents()
                if image, let img = NSImage(data: data) { pb.writeObjects([img]) } else { pb.setString(String(decoding: data, as: UTF8.self), forType: .string) }
            }
            self?.post(.copied(image: image))
        }
    }

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
        out.connection(up: up)
        if !up { incoming.suspend(device: device) }
    }

    /// What the host said about files, either way.
    func heard(_ m: ToPhone) {
        if let a = m.fileAnswer { out.heard(a) }
        if let o = m.fileOut { incoming.heard(o, from: device) { [weak link] a in link?.send(ToMac(a)) } }
    }

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
                post(.sending(name: t.name, size: t.size, done: t.done > 0 ? t.done : nil, index: i, count: n, left: t.secondsLeft))
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
/// Dark in both appearances, as the window's other cards over the picture (system.md §3.1). Done: the ok check and where it is, 5 s;
/// not sent: the attention triangle and why, until closed or 8 s.
final class ViewerFileCard: NSView {
    static let width: CGFloat = 360
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let track = CALayer()
    private let fill = CALayer()
    private let close = NSButton()
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
        detail.font = .systemFont(ofSize: 11.5)
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
        for v in [icon, title, detail, close] as [NSView] {
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
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 62),
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
        CATransaction.commit()
        indeterminate(fraction == nil && showsBar)
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

    /// A file's own icon, as Finder shows it.
    private static func fileIcon(_ name: String) -> NSImage {
        let ext = (name as NSString).pathExtension
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }

    /// a received file: a click on the card shows it in Finder
    private var revealURL: URL?

    override func mouseUp(with event: NSEvent) {
        if let u = revealURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    /// " · 2 min left" once there's a rate to tell it from
    private static func left(_ s: Double?) -> String {
        guard let s, s.isFinite, s >= 1 else { return "" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .short
        f.allowedUnits = s >= 3600 ? [.hour, .minute] : s >= 60 ? [.minute] : [.second]
        var cal = Calendar.current
        cal.locale = Loc.locale
        f.calendar = cal
        guard let d = f.string(from: s.rounded(.up)) else { return "" }
        return " · " + T("viewer.file.left", d)
    }

    /// The state the card says; `to` is the computer's name.
    func show(_ e: ViewerFileSender.Event, to: String) {
        hideTimer?.invalidate()
        hideTimer = nil
        revealURL = nil
        toolTip = nil
        func over(_ seconds: TimeInterval) {
            sending = false
            isHidden = false
            showsBar = false
            close.toolTip = T("viewer.file.close")
            close.setAccessibilityLabel(T("viewer.file.close"))
            hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.hide() }
        }
        func going(_ name: String, _ size: Int, _ done: Int?) {
            sending = true
            isHidden = false
            icon.image = Self.fileIcon(name)
            setTitle(name)
            fraction = done.map { size > 0 ? CGFloat(min($0, size)) / CGFloat(size) : 1 }
            showsBar = true
            close.toolTip = T("viewer.file.stop")
            close.setAccessibilityLabel(T("viewer.file.stop"))
        }
        let bytes = { (n: Int) in Self.bytes.string(fromByteCount: Int64(n)) }
        switch e {
        case let .sending(name, size, done, index, count, left):
            going(name, size, done)
            let many = count > 1
            if let done {
                let d = bytes(min(done, size))
                detail.stringValue = (many ? T("viewer.file.to.many", index, count, to, d, bytes(size)) : T("viewer.file.to", to, d, bytes(size))) + Self.left(left)
            } else {
                detail.stringValue = many ? T("viewer.file.to.many.start", index, count, to, bytes(size)) : T("viewer.file.to.start", to, bytes(size))
            }
        case let .receiving(name, size, done, index, count, left):
            going(name, size, done)
            let d = bytes(min(done, size))
            detail.stringValue = (count > 1 ? T("viewer.file.from.many", index, count, to, d, bytes(size)) : T("viewer.file.from", to, d, bytes(size))) + Self.left(left)
        case let .paused(name):
            going(name, 1, nil)
            showsBar = false
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
            over(8)
        case let .copied(image):
            icon.image = Self.okMark
            setTitle(T(image ? "viewer.copied.image" : "viewer.copied.text"))
            detail.stringValue = ""
            over(4)
        case let .nothing(why):
            icon.image = Self.attnMark
            let key = ["locked": "viewer.copied.none.locked", "too_big": "viewer.copied.none.too_big", "unsupported": "viewer.copied.none.unsupported",
                       "update": "viewer.copied.none.update"][why] ?? "viewer.copied.none.empty"
            setTitle(T(key, to))
            detail.stringValue = ""
            over(6)
        case let .failed(name, why, incoming):
            icon.image = Self.attnMark
            let key: String
            if incoming {
                key = why == "space" ? "viewer.file.failed.in.space" : "viewer.file.failed.in.other"
            } else {
                key = ["space": "viewer.file.failed.space", "too_big": "viewer.file.failed.too_big", "locked": "viewer.file.failed.locked"][why]
                    ?? "viewer.file.failed.other"
            }
            if name.isEmpty { setTitle(T(key)); detail.stringValue = "" } else { setTitle(name); detail.stringValue = T(key) }
            over(8)
        case .stopped:
            hide()
        }
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

    /// not sent: the attention triangle
    private static let attnMark: NSImage = NSImage(size: NSSize(width: 32, height: 32), flipped: true) { r in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
        BlurtIcon.warning.draw(in: ctx, rect: r.insetBy(dx: 4, dy: 4), color: BrandColor.Island.attn.cgColor, flipped: true)
        return true
    }

    #if DEBUG || BLURT_TEST_HOOKS
    var testState: [String: Any] {
        ["shown": !isHidden, "title": title.stringValue, "detail": detail.stringValue, "frame": NSStringFromRect(frame),
         "fraction": fraction.map { Double($0) } ?? -1, "bar": showsBar]
    }
    #endif
}
