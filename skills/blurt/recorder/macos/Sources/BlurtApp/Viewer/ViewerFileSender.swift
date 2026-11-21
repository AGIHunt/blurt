// Files to the computer a window shows (docs/design/remote-1.1.md §6): Send Files… or dropped on the picture, each to the host's
// Downloads in order, a chunk at a time, never more than `window` ahead of what the host says it has written. The window shows each
// one on its file card (ViewerFileCard): the name, how much the host has written, and × to stop.
import AppKit
import BlurtRemoteKit
import UniformTypeIdentifiers

final class ViewerFileSender {
    static let chunk = 192 * 1024
    static let window = 4 << 20

    /// What the card shows, on the main thread. `done` is nil until the host first says how much it has written.
    enum Event: Equatable {
        case sending(name: String, size: Int, done: Int?, index: Int, count: Int)
        case saved(name: String, index: Int, count: Int)
        /// why: "space", "too_big", "locked", "read", "write", "other"
        case failed(name: String, why: String)
        /// × on the card: what was going and what waited behind it
        case stopped
    }

    private let link: RemoteViewerLink
    private let queue = DispatchQueue(label: "blurt.viewer.files")
    private let lock = NSLock()
    private var acked: [String: Int] = [:]
    /// the file going now (its id, name and size), for the host's counts
    private var current: (id: String, name: String, size: Int)?
    /// files asked for since the queue was last empty, and how many of them are through
    private var asked = 0
    private var through = 0
    /// × bumps it: everything asked for before stops
    private var generation = 0
    /// ids given up here: the host's answer to them (a part it deleted) isn't news
    private var dropped: Set<String> = []
    var onEvent: ((Event) -> Void)?

    init(link: RemoteViewerLink) { self.link = link }

    func send(_ urls: [URL]) {
        let gen = lock.withLock { () -> Int in
            asked += urls.count
            return generation
        }
        queue.async { urls.forEach { self.one($0, gen) } }
    }

    /// × on the card: the file going now ends here (the host deletes what it had of it) and the ones waiting don't go.
    func stop() {
        lock.withLock {
            generation += 1
            asked = 0
            through = 0
        }
        post(.stopped)
    }

    /// What the host said (ToPhone.file…), from the window.
    func heard(_ m: ToPhone) {
        switch m {
        case let .fileProgress(id, bytes):
            let ev: Event? = lock.withLock {
                guard acked[id] != nil else { return nil }
                acked[id] = bytes
                guard let c = current, c.id == id else { return nil }
                return .sending(name: c.name, size: c.size, done: bytes, index: through + 1, count: max(asked, through + 1))
            }
            if let ev { post(ev) }
        case let .fileSaved(id, name):
            let ev: Event? = lock.withLock {
                acked[id] = nil
                guard !dropped.contains(id) else { return nil }
                through += 1
                let e = Event.saved(name: name, index: through, count: max(asked, through))
                if through >= asked { asked = 0; through = 0 }
                return e
            }
            if let ev { post(ev) }
        case let .fileFailed(id, why):
            let ev: Event? = lock.withLock {
                acked[id] = nil
                // a part given up here, deleted there: nothing to say
                if dropped.remove(id) != nil { return nil }
                through += 1
                if through >= asked { asked = 0; through = 0 }
                return .failed(name: current?.id == id ? current?.name ?? "" : "", why: why)
            }
            if let ev { post(ev) }
        default: break
        }
    }

    private func post(_ e: Event) {
        DispatchQueue.main.async { self.onEvent?(e) }
    }

    private func live(_ gen: Int) -> Bool { lock.withLock { generation == gen } }

    private func one(_ url: URL, _ gen: Int) {
        guard live(gen) else { return }
        let name = url.lastPathComponent
        guard let h = try? FileHandle(forReadingFrom: url),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            lock.withLock { through += 1; if through >= asked { asked = 0; through = 0 } }
            return post(.failed(name: name, why: "read"))
        }
        defer { try? h.close() }
        let id = RemoteCrypto.newID()
        let first: Event = lock.withLock {
            acked[id] = 0
            current = (id, name, size)
            return .sending(name: name, size: size, done: nil, index: through + 1, count: max(asked, through + 1))
        }
        post(first)
        link.send(.fileBegin(id: id, name: name, size: size))
        var sent = 0
        /// ended early (× or the host stopped answering): the host deletes its part when the end comes short
        func giveUp(_ why: String?) {
            lock.withLock {
                acked[id] = nil
                dropped.insert(id)
                if why != nil { through += 1; if through >= asked { asked = 0; through = 0 } }
            }
            link.send(.fileEnd(id: id))
            if let why { post(.failed(name: name, why: why)) }
        }
        while true {
            // the host is at most `window` behind; a minute without it moving and this one is given up
            var waited = 0
            while let a = lock.withLock({ acked[id] }), sent - a > Self.window {
                if !live(gen) { return giveUp(nil) }
                if waited > 3000 { return giveUp("other") }
                Thread.sleep(forTimeInterval: 0.02)
                waited += 1
            }
            if !live(gen) { return giveUp(nil) }
            guard lock.withLock({ acked[id] }) != nil else { return }   // the host refused it and said why
            guard let d = try? h.read(upToCount: Self.chunk), !d.isEmpty else { break }
            link.send(.fileChunk(id: id, data: d))
            sent += d.count
        }
        link.send(.fileEnd(id: id))
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
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

    /// The state the card says; `to` is the computer's name.
    func show(_ e: ViewerFileSender.Event, to: String) {
        hideTimer?.invalidate()
        hideTimer = nil
        switch e {
        case let .sending(name, size, done, index, count):
            sending = true
            isHidden = false
            icon.image = Self.fileIcon(name)
            setTitle(name)
            let total = Self.bytes.string(fromByteCount: Int64(size))
            let many = count > 1
            if let done {
                let d = Self.bytes.string(fromByteCount: Int64(min(done, size)))
                detail.stringValue = many ? T("viewer.file.to.many", index, count, to, d, total) : T("viewer.file.to", to, d, total)
                fraction = size > 0 ? CGFloat(min(done, size)) / CGFloat(size) : 1
            } else {
                detail.stringValue = many ? T("viewer.file.to.many.start", index, count, to, total) : T("viewer.file.to.start", to, total)
                fraction = nil
            }
            showsBar = true
            close.toolTip = T("viewer.file.stop")
            close.setAccessibilityLabel(T("viewer.file.stop"))
        case let .saved(name, index, count):
            // the next file follows at once: only the last one's done moment stays
            guard index >= count else { return }
            sending = false
            isHidden = false
            icon.image = Self.okMark
            setTitle(count > 1 ? T("viewer.file.count", count) : name)
            detail.stringValue = T("viewer.file.saved.to", to)
            showsBar = false
            close.toolTip = T("viewer.file.close")
            close.setAccessibilityLabel(T("viewer.file.close"))
            hideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.hide() }
        case let .failed(name, why):
            sending = false
            isHidden = false
            icon.image = Self.attnMark
            if !name.isEmpty { setTitle(name) }
            let key = switch why {
            case "space": "viewer.file.failed.space"
            case "too_big": "viewer.file.failed.too_big"
            case "locked": "viewer.file.failed.locked"
            default: "viewer.file.failed.other"
            }
            if name.isEmpty { setTitle(T(key)); detail.stringValue = "" } else { detail.stringValue = T(key) }
            showsBar = false
            close.toolTip = T("viewer.file.close")
            close.setAccessibilityLabel(T("viewer.file.close"))
            hideTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in self?.hide() }
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
