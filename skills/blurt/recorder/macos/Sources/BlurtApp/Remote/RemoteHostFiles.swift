// Files and the clipboard between this Mac (the host) and the device controlling it (docs/design/remote-files.md): files a phone or
// viewer sends land in ~/Downloads/Blurt, quarantined, and a dropped one waits an hour to go on; what's copied here goes to the device
// only when it asks (Get Copied Items), and the bar says so; Send Files… on the bar sends to it. The engine is BlurtRemoteKit's
// RemoteFiles; this is the Mac around it: the pasteboard, the quarantine flag, ⌘V, the bar and the log.
import AppKit
import BlurtCore
import BlurtRemoteKit
import UniformTypeIdentifiers

final class RemoteHostFiles {
    /// What the server lends: a device's live session to send on (false: none, or it takes no files), whether files may go to it now
    /// (its stream has moved, on the go-between), whether it resumes, and what this Mac calls it.
    struct Session {
        let send: (ToPhone) -> Bool
        let ready: () -> Bool
        let resumes: () -> Bool
        let takesFiles: Bool
        /// over Blurt's public relay: what goes is counted (PublicRelayFiles)
        var publicRelay = false
    }

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Blurt", isDirectory: true)
    }

    let receiver: RemoteFileReceiver
    private var senders: [String: RemoteFileSender] = [:]
    private var sessions: [String: Session] = [:]
    private let lock = NSLock()
    /// a device's id → what this Mac calls it
    var label: (String) -> String = { $0 }
    /// a file saved, a clipboard read, files sent: for the connection log
    var noted: ((String, RemoteConnectionLog.Event) -> Void)?
    /// a line for the device (`ToPhone.notice`), if it's still the one connected
    var notice: ((String, String) -> Void)?
    /// files from one device in a row, for one notification
    private var arrived: [String: (count: Int, last: String, at: Date)] = [:]

    init(parts: URL) {
        receiver = RemoteFileReceiver(parts: parts, folder: { Self.downloads })
        receiver.locked = { RemoteServer.screenLocked }
        receiver.onSaved = { [weak self] url, device in self?.saved(url, from: device) }
        receiver.onClip = { [weak self] url, name, device in self?.clip(url, name: name, from: device) }
    }

    // MARK: sessions

    /// A device's session is up (or replaced): its sender goes on.
    func opened(_ device: String, _ s: Session) {
        let sender: RemoteFileSender = lock.withLock {
            sessions[device] = s
            if let x = senders[device] { return x }
            let x = RemoteFileSender(send: { [weak self] o in self?.lock.withLock { self?.sessions[device] }?.send(ToPhone(o)) ?? false },
                                     ready: { [weak self] in self?.lock.withLock { self?.sessions[device] }.map { $0.takesFiles && $0.ready() } ?? false },
                                     peerResumes: { [weak self] in self?.lock.withLock { self?.sessions[device] }?.resumes() ?? false })
            x.onChange = { [weak self] t in self?.changed(t, device) }
            senders[device] = x
            return x
        }
        sender.connection(up: true)
    }

    /// Its session ended: what it was sending waits an hour; what was going to it pauses.
    func closed(_ device: String) {
        let sender: RemoteFileSender? = lock.withLock {
            sessions[device] = nil
            return senders[device]
        }
        sender?.connection(up: false)
        receiver.suspend(device: device)
    }

    // MARK: from the device

    /// ToMac.fileBegin / fileChunk / fileEnd, and the device's answers to files going to it.
    func heard(_ m: ToMac, from device: String, reply: @escaping (ToPhone) -> Void) {
        if let o = m.fileOut {
            receiver.heard(o, from: device) { reply(ToPhone($0)) }
        } else if let a = m.fileAnswer {
            lock.withLock { senders[device] }?.heard(a)
        }
    }

    /// Get Copied Items: what's on this Mac's pasteboard, once. Files go as a batch (folders zipped), an image as a PNG clip, text in a
    /// message (or as Text.txt past 64 KiB). The bar says the clipboard was sent; the log keeps the time, never the content.
    func getClipboard(from device: String, reply: @escaping (ToPhone) -> Void) {
        if RemoteServer.screenLocked { return reply(.clipboardNone(why: "locked")) }
        let takes = takesFiles(device)
        // the pasteboard is read on the main thread, without holding the server's queue (which the main thread may be waiting on)
        DispatchQueue.main.async { [self] in
            let read = Self.read(NSPasteboard.general)
            DispatchQueue.global(qos: .userInitiated).async { [self] in answer(read, takes: takes, device: device, reply: reply) }
        }
    }

    private func answer(_ read: Copied, takes: Bool, device: String, reply: @escaping (ToPhone) -> Void) {
            // over the public relay, files count against the day's 50 MB, asked for or not
            let counted = lock.withLock { sessions[device]?.publicRelay ?? false }
            func fits(_ size: Int) -> Bool {
                guard counted else { return true }
                guard PublicRelayFiles.decide(size, device: device) != .over else { return false }
                PublicRelayFiles.spend(size, device: device)
                return true
            }
            // a device that takes no files gets text in a message and nothing else
            switch read {
            case .image, .files: if !takes { return reply(.clipboardNone(why: "unsupported")) }
            case let .text(t): if !takes && !RemoteClipboard.fits(t) { return reply(.clipboardNone(why: "too_big")) }
            case .nothing: break
            }
            switch read {
            case .nothing:
                reply(.clipboardNone(why: "empty"))
                return
            case let .text(t):
                if RemoteClipboard.fits(t) {
                    reply(.clipboard(t))
                } else {
                    guard fits(t.utf8.count) else { return reply(.clipboardNone(why: "limit")) }
                    guard let u = Self.temporary("Text.txt", Data(t.utf8)) else { return reply(.clipboardNone(why: "unsupported")) }
                    sender(device)?.add([u], clip: true, temporary: true)
                }
            case let .image(png):
                guard fits(png.count) else { return reply(.clipboardNone(why: "limit")) }
                guard let u = Self.temporary("Image.png", png) else { return reply(.clipboardNone(why: "unsupported")) }
                sender(device)?.add([u], clip: true, temporary: true)
            case let .files(urls):
                if let why = RemoteFiles.refusal(count: urls.count, sizes: []) { return reply(.clipboardNone(why: why)) }
                let ready = RemoteFiles.prepare(urls)
                let sizes = ready.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
                guard !ready.isEmpty else { return reply(.clipboardNone(why: "empty")) }
                // a file (or a folder's zip) over 4 GB: none of them go, and the zips made for them are deleted now
                if let why = RemoteFiles.refusal(count: ready.count, sizes: sizes) {
                    RemoteFiles.discard(RemoteFiles.made(ready))
                    return reply(.clipboardNone(why: why))
                }
                guard fits(sizes.reduce(0, +)) else {
                    RemoteFiles.discard(RemoteFiles.made(ready))
                    return reply(.clipboardNone(why: "limit"))
                }
                // zips made here are deleted once over; the user's own files never are
                sender(device)?.add(ready, made: RemoteFiles.made(ready))
            }
            noted?(device, .clipboard)
            DispatchQueue.main.async { RemoteBanner.flash(T("remote.banner.clipboard_sent", PhoneStatus.name(self.label(device)))) }
            emit(["event": "remote_clipboard", "state": "sent"])
    }

    /// Send Files… on the bar (or files dropped on it): to the device connected now.
    func send(_ urls: [URL], to device: String) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let ready = RemoteFiles.prepare(urls)
            guard !ready.isEmpty else { return }
            sender(device)?.add(ready, made: RemoteFiles.made(ready))
            noted?(device, .filesOut(ready.count))
        }
    }

    func takesFiles(_ device: String) -> Bool { lock.withLock { sessions[device]?.takesFiles ?? false } }

    private func sender(_ device: String) -> RemoteFileSender? { lock.withLock { senders[device] } }

    // MARK: what the pasteboard holds

    enum Copied: Equatable {
        case nothing
        case text(String)
        case image(Data)
        case files([URL])
    }

    /// Files first (Finder puts their names and icons on the pasteboard too), then an image, then text.
    static func read(_ pb: NSPasteboard) -> Copied {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        let types = pb.types ?? []
        if types.contains(.png), let d = pb.data(forType: .png) { return .image(d) }
        if types.contains(.tiff) || types.contains(NSPasteboard.PasteboardType("public.jpeg")),
           let img = NSImage(pasteboard: pb), let png = png(img) {
            return .image(png)
        }
        if let s = pb.string(forType: .string), !s.isEmpty { return .text(s) }
        return .nothing
    }

    static func png(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func temporary(_ name: String, _ d: Data) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-clip-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(name)
        return (try? d.write(to: u)) != nil ? u : nil
    }

    // MARK: what arrives

    private func saved(_ url: URL, from device: String) {
        // never opened or run by itself: the flag a browser's download gets
        let q: [String: Any] = [kLSQuarantineAgentNameKey as String: "Blurt", kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        try? (url as NSURL).setResourceValue(q, forKey: .quarantinePropertiesKey)
        emit(["event": "remote_file", "state": "saved"])
        noted?(device, .filesIn(1))
        // a batch: one notification, saying how many
        let n: Int = lock.withLock {
            var a = arrived[device] ?? (0, "", .distantPast)
            if Date().timeIntervalSince(a.at) > 10 { a.count = 0 }
            a.count += 1
            a.last = url.lastPathComponent
            a.at = Date()
            arrived[device] = a
            return a.count
        }
        let who = PhoneStatus.name(label(device))
        if n == 1 {
            Notify.post(title: T("remote.file.received.title", who), body: url.lastPathComponent, uid: "remote-file")
        } else {
            Notify.post(title: T("remote.file.received.many", n, who), body: url.lastPathComponent, uid: "remote-file")
        }
    }

    /// The device's clipboard (an image, or long text) for this Mac's: onto the pasteboard, then ⌘V into the app in front, as its text is
    /// typed there.
    private func clip(_ url: URL, name: String, from device: String) {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let image = RemoteFiles.isImage(name)
        // never into a password field or at the lock screen: there it only goes on the pasteboard (as `ToMac.text` refuses to type).
        // The field is asked off the server's queue (a hung app answers slowly), the pasteboard is written on the main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let field: RemoteServer.FocusedField = RemoteServer.screenLocked ? .password : RemoteServer.focusedField()
            let paste = field == .plain
            // the device is told it wasn't pasted, as for its text: it's on this Mac's clipboard
            if field == .password { self?.notice?(device, T("remote.clip.refused")) }
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                if image, let img = NSImage(data: data) {
                    pb.writeObjects([img])
                } else {
                    pb.setString(String(decoding: data, as: UTF8.self), forType: .string)
                }
                if paste {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { RemoteInput.shared.press(RemoteChord([.command], "V")) }
                }
                emit(["event": "remote_clipboard", "state": paste ? "pasted" : "copied", "image": image])
            }
        }
    }

    private func changed(_ t: RemoteTransfer, _ device: String) {
        DispatchQueue.main.async { RemoteBanner.transfer(t, to: PhoneStatus.name(self.label(device))) }
    }
}

/// Files over Blurt's public relay, counted here as the sender, by the host to each device and by a viewer to each computer: 50 MB a UTC
/// day, and a send over 20 MB asked about first (docs/design/remote-go-between.md §What the devices do on this path). Kept in the config
/// so a restart doesn't reset the day.
enum PublicRelayFiles {
    private static let key = "record.remote.public_files"
    private static let lock = NSLock()

    private static func load() -> RemotePublicFiles {
        (Config.shared[key] as? String).flatMap { try? JSONDecoder().decode(RemotePublicFiles.self, from: Data($0.utf8)) } ?? RemotePublicFiles()
    }

    static func decide(_ size: Int, device: String) -> RemotePublicFiles.Decision { lock.withLock { load().decide(size, device: device) } }

    static func spend(_ size: Int, device: String) {
        lock.withLock {
            var f = load()
            f.spend(size, device: device)
            if let d = try? JSONEncoder().encode(f) { Config.shared.set(key, String(decoding: d, as: UTF8.self)) }
        }
    }

    /// "Send 35 MB over the public connection service?"
    static func askText(_ size: Int) -> String { T("remote.public.files.ask", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
    static var overText: String { T("remote.public.files.over") }

    /// Main thread: whether these files may go over the public relay now. Past today's 50 MB it says so (`over`) and they don't; over 20 MB
    /// it asks first, as a sheet on `window` or on its own. Counted once they're let go.
    @MainActor static func check(_ urls: [URL], device: String, window: NSWindow?, over: (String) -> Void, go: @escaping () -> Void) {
        let size = RemotePublicFiles.size(of: urls)
        let send = {
            spend(size, device: device)
            go()
        }
        switch decide(size, device: device) {
        case .over:
            emit(["event": "remote_public_files", "state": "over", "size": size])
            over(overText)
        case .send:
            send()
        case .ask:
            let a = NSAlert()
            a.messageText = askText(size)
            a.addButton(withTitle: T("remote.banner.send"))
            a.addButton(withTitle: T("action.cancel"))
            if let window {
                a.beginSheetModal(for: window) { r in if r == .alertFirstButtonReturn { send() } }
            } else {
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { send() }
            }
        }
    }
}
