// Files and the clipboard between this phone and the computer in hand (docs/design/remote-files.md): the Transfer sheet's list, what
// Get Copied Items brought, the question before a big file on mobile data, and the share extension's outbox. The engine is
// BlurtRemoteKit's RemoteFiles, one sender and one receiver in Link; this is what the user sees of it. Nothing moves by itself: every
// transfer starts from a tap here or at the computer.
import BlurtRemoteKit
import Combine
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// One line of the Transfer sheet's list, either way: this run's, or one of the last 50 before.
struct TransferRow: Identifiable, Codable, Equatable {
    enum Phase: Codable, Equatable {
        /// a folder being zipped before it goes
        case compressing
        /// photos coming out of the photo library before they go
        case preparing
        case waiting
        case going
        case paused
        case done
        /// RemoteTransfer's reasons: "space", "too_big", "write", "locked", "read", "stopped", "other"
        case failed(String)
    }

    var id: String
    /// the transfer's id on the wire
    var wire: String
    var name: String
    var size: Int
    var done: Int = 0
    var incoming: Bool
    var phase: Phase
    var index: Int?
    var count: Int?
    /// the computer, as it was called then
    var peer: String
    /// received: the file's name in Documents (the container's path changes with every install)
    var file: String?
    var at: Date
    var secondsLeft: Double?
    /// shared to Blurt and not sent yet: its folder in the outbox
    var outbox: String?
    /// sent to a computer whose Blurt saves in Downloads itself, not Downloads/Blurt (one without `resume`, as the Mac viewer tells them)
    var toDownloads: Bool?

    var fraction: Double { size > 0 ? min(1, Double(done) / Double(size)) : (phase == .done ? 1 : 0) }
    var isOver: Bool { if case .failed = phase { return true }; return phase == .done }
    var isMedia: Bool { RemoteFiles.isMedia(file ?? name) }
    var isVideo: Bool { RemoteFiles.videoExtensions.contains(((file ?? name) as NSString).pathExtension.lowercased()) }
    /// a received file, where it is now
    var savedURL: URL? { incoming && phase == .done ? file.map { Link.documents.appendingPathComponent($0) } : nil }
}

/// What the rows and the clipboard's answers say (the Copy table in remote-files.md). Kept apart from the views for the tests.
enum TransferWords {
    static func size(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    /// the system's own short duration in English ("2 min", "42 sec"); in Chinese by hand, as the Mac writes it, with a space between number
    /// and unit (the formatter writes 3分钟): seconds up to a minute, then minutes
    static func duration(_ s: Double, chinese: Bool = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true) -> String {
        if chinese {
            let n = max(1, Int(s.rounded()))
            return n < 60 ? "\(n) 秒" : "\(Int((Double(n) / 60).rounded())) 分钟"
        }
        let f = DateComponentsFormatter()
        f.unitsStyle = .short
        f.maximumUnitCount = 1
        f.allowedUnits = s >= 3600 ? [.hour, .minute] : s >= 60 ? [.minute] : [.second]
        return f.string(from: max(1, s.rounded())) ?? ""
    }

    /// The line under a row's name. `meeting`: the public connection service hasn't opened the direct path yet. `canContinue`: the row
    /// has Continue, so a paused one needn't say how it resumes.
    static func line(_ r: TransferRow, meeting: Bool = false, canContinue: Bool = false, away: Bool = false) -> String {
        switch r.phase {
        case .compressing: return String(localized: "Compressing…")
        case .preparing: return String(localized: "Preparing…")
        case .waiting: return meeting ? String(localized: "Connecting directly…") : String(localized: "Waiting")
        case .paused:
            // the session ended out of sight (iOS lets it run on ~25 s): it goes on when the app is back
            if away { return String(localized: "Resumes when Blurt is open.") }
            return canContinue ? String(localized: "Paused") : String(localized: "Paused. Resumes when reconnected.")
        case .going:
            return going(r).joined(separator: " · ")
        case .done:
            let peer = r.peer
            if r.incoming { return String(localized: "Saved to Files › Blurt") }
            return r.toDownloads == true ? String(localized: "Saved to Downloads on \(peer)") : String(localized: "Saved to Downloads/Blurt on \(peer)")
        case let .failed(why):
            if why == "stopped" { return String(localized: "Stopped") }
            if r.incoming { return why == "space" ? String(localized: "Not received: not enough space on this device.") : String(localized: "Not received.") }
            switch why {
            case "space": return String(localized: "Not sent: not enough space on that computer.")
            case "too_big": return String(localized: "Not sent: larger than 4 GB.")
            case "locked": return String(localized: "Not sent: that computer is locked.")
            default: return String(localized: "Not sent.")
            }
        }
    }

    /// A file on its way, in two lines the same both ways: where (and its place in a batch), then how far and the time left.
    static func going(_ r: TransferRow) -> [String] {
        let done = size(r.done), all = size(r.size), peer = r.peer
        // "To %@ · %@ of %@" is one string, so each language keeps its order; it splits at its dot
        let both = (r.incoming ? String(localized: "From \(peer) · \(done) of \(all)") : String(localized: "To \(peer) · \(done) of \(all)"))
            .components(separatedBy: " · ")
        var first: [String] = [], second = Array(both.dropFirst())
        if let i = r.index, let n = r.count, n > 1 { first.append(String(localized: "\(i) of \(n)", comment: "a file's place in its batch")) }
        first.append(both.first ?? "")
        if let s = r.secondsLeft { second.append(String(localized: "\(duration(s)) left")) }
        return [first.joined(separator: " · "), second.joined(separator: " · ")]
    }

    /// clipboardNone's reasons, for the computer `name`
    static func nothing(_ why: String, name: String) -> String {
        switch why {
        case "empty": String(localized: "Nothing is copied on \(name).")
        case "locked": String(localized: "\(name) is locked.")
        case "too_large": String(localized: "A file copied on \(name) is larger than 4 GB.")
        case "too_big": String(localized: "Too many files are copied on \(name). Copy up to 1,000 at a time.")
        default: String(localized: "Can’t get this kind of item from \(name).")
        }
    }

    /// the first words of copied text, on one line
    static func firstWords(_ t: String) -> String {
        let one = t.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return one.count > 60 ? String(one.prefix(60)) + "…" : one
    }
}

final class Transfers: ObservableObject {
    static let shared = Transfers()

    /// What the clipboard's answer, or a paste from here, came to: on the sheet, and on the pad when the sheet is away.
    struct Said: Identifiable, Equatable {
        enum Kind: Equatable {
            /// text onto this phone's clipboard
            case copied
            /// an image onto it: Save to Photos is offered (the file is kept for that)
            case image(URL)
            /// nothing came, or it couldn't go
            case note
        }
        let id = UUID()
        var kind: Kind
        var title: String
        var detail: String?
    }

    /// A big transfer on mobile data, asked about first.
    struct Ask: Identifiable, Equatable {
        let id = UUID()
        var incoming: Bool
        var bytes: Int
        var title: String {
            let s = TransferWords.size(bytes)
            return incoming ? String(localized: "Get \(s) over mobile data?") : String(localized: "Send \(s) over mobile data?")
        }
    }

    enum Admit { case go, hold, refuse }

    /// What the model needs of the app around it: Link's, in the app; stand-ins in the tests.
    struct Env {
        /// the computer in hand: its id and what this phone calls it
        var peer: () -> (id: String, name: String)?
        var mobileData: () -> Bool
        var meeting: () -> Bool
        /// files may go now (a session is up)
        var ready: () -> Bool
        /// send getClipboard
        var askClipboard: () -> Void
        /// queue files on the sender: (files, clip, temporary, zips made)
        var queue: ([URL], Bool, Bool, Set<URL>) -> Void
        /// a file coming in whose progress waited for the mobile-data answer goes on
        var release: (String) -> Void
        /// files going out wait (true) for the mobile-data answer, or go on (false)
        var holdOut: (Bool) -> Void
        /// the computer in hand keeps what it gets in Downloads/Blurt (it resumes); an older one, in Downloads
        var peerResumes: () -> Bool
        var stopOut: (String) -> Void
        var stopIn: (String) -> Void
        var again: (String) -> Void
        var active: () -> Bool

        static let app = Env(
            peer: { Link.shared.current.map { ($0.id, $0.title) } },
            mobileData: { Link.shared.mobileData },
            meeting: { Link.shared.meeting },
            ready: { Link.shared.ready },
            askClipboard: { Link.shared.getCopied() },
            queue: { urls, clip, temporary, made in Link.shared.files.add(urls, clip: clip, temporary: temporary, made: made) },
            release: { Link.shared.releaseIncoming($0) },
            holdOut: { Link.shared.holdOutgoing($0) },
            peerResumes: { Link.shared.hostFeatures.contains(RemoteFeature.resume) },
            stopOut: { Link.shared.files.stop($0) },
            stopIn: { Link.shared.stopIncoming($0) },
            again: { Link.shared.files.again($0) },
            // in sight: sceneDidBecomeActive comes while the app still says inactive
            active: { UIApplication.shared.applicationState != .background })
    }

    /// newest first: what waits in the outbox, this run's, then the last 50 before
    @Published private(set) var rows: [TransferRow] = []
    @Published private(set) var said: Said?
    @Published var asking: Ask?
    /// Get Copied Items was tapped and the computer hasn't answered yet
    @Published private(set) var getting = false
    /// the session ended while the app was out of sight: paused rows go on once it's open
    @Published private(set) var away = false

    private var now: [TransferRow] = []
    private var earlier: [TransferRow] = []
    private var waiting: [TransferRow] = []
    private let store: URL?
    let outbox: Outbox?
    var env: Env
    /// test hook
    var clock: () -> Date = Date.init
    /// files from the computer whose progress waits for the mobile-data question, by wire id
    private var held: [String: RemoteFileInfo] = [:]
    /// what's going out waits for the mobile-data question: it resumed on mobile data with more than 100 MB left
    private var heldResume = false
    /// a yes to the mobile-data question for files going out: not asked again until then
    private var allowedOut: Date?
    /// files to send held for it
    private var heldOut: (urls: [URL], temporary: Bool, made: Set<URL>, scoped: [URL])?
    /// a batch from the computer the user said yes or no to, as (count, total), so its other files aren't asked about again
    private var allowedIn: (key: String, until: Date)?
    private var refusedIn: (key: String, until: Date)?
    /// Preparing… rows × took away: what they load is dropped
    private var cancelled: Set<String> = []
    /// files picked in Files: their access lasts until they're sent
    private var scoped: Set<URL> = []
    private var gettingDue: DispatchWorkItem?

    static let keepRows = 50

    init(store: URL? = Transfers.defaultStore, outbox: Outbox? = Outbox.shared, env: Env = .app) {
        self.store = store
        self.outbox = outbox
        self.env = env
        if let s = store, let d = try? Data(contentsOf: s), let r = try? JSONDecoder().decode([TransferRow].self, from: d) {
            earlier = Array(r.filter(\.isOver).prefix(Self.keepRows))
        }
        publish()
    }

    static var defaultStore: URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transfers.json")
    }

    /// Before more than 100 MB goes either way on mobile data, ask.
    static func asksFirst(bytes: Int, mobileData: Bool) -> Bool { mobileData && bytes > RemoteFiles.askOnCellular }

    private func publish() { rows = waiting + now + earlier }

    private func save() {
        guard let s = store else { return }
        let keep = Array((now.filter(\.isOver) + earlier).prefix(Self.keepRows))
        if let d = try? JSONEncoder().encode(keep) { try? d.write(to: s, options: .atomic) }
    }

    // MARK: the engine's changes

    /// A transfer changed, from the sender or the receiver.
    func changed(_ t: RemoteTransfer) {
        if t.clip { return clipChanged(t) }
        let id = (t.incoming ? "in-" : "out-") + t.id
        let phase: TransferRow.Phase = switch t.state {
        case .waiting: .waiting
        // written but not said to the computer until the mobile-data answer
        case .going where t.incoming && held[t.id] != nil: .waiting
        case .going: .going
        case .paused: .paused
        case .done: .done
        case let .failed(w): .failed(w)
        }
        if let i = now.firstIndex(where: { $0.id == id }) {
            var r = now[i]
            r.name = t.name
            r.size = t.size
            r.done = t.done
            r.phase = phase
            r.secondsLeft = t.secondsLeft
            if t.incoming, t.state == .done { r.file = t.url?.lastPathComponent ?? t.name }
            if !t.incoming, t.state == .done { r.toDownloads = !env.peerResumes() }
            now[i] = r
        } else {
            let r = TransferRow(id: id, wire: t.id, name: t.name, size: t.size, done: t.done, incoming: t.incoming, phase: phase, index: t.index,
                                count: t.count, peer: env.peer()?.name ?? "", file: t.incoming && t.state == .done ? t.url?.lastPathComponent : nil,
                                at: clock(), secondsLeft: t.secondsLeft)
            insert(r)
        }
        if t.isOver {
            if !t.incoming, let u = t.url, scoped.remove(u) != nil { u.stopAccessingSecurityScopedResource() }
            save()
        }
        publish()
    }

    /// A batch stays in its own order, under the newest: the next file of one goes right after the one before it.
    private func insert(_ r: TransferRow) {
        if let i = r.index, i > 1, let before = now.firstIndex(where: { $0.incoming == r.incoming && $0.count == r.count && $0.index == i - 1 }) {
            now.insert(r, at: before + 1)
        } else {
            now.insert(r, at: 0)
        }
    }

    /// The clipboard's content going either way isn't a file in the list: only what it came to is said.
    private func clipChanged(_ t: RemoteTransfer) {
        guard case let .failed(why) = t.state else { return }
        // a clip nobody asked for says nothing
        if t.incoming {
            guard getting else { return }
            getting = false
        }
        let name = env.peer()?.name ?? ""
        say(Said(kind: .note, title: why == "locked" ? String(localized: "\(name) is locked.") : t.incoming ? String(localized: "Not received.") : String(localized: "Not sent.")))
    }

    func sessionUp() {
        away = false
        pickUp()
    }

    func sessionDown() {
        getting = false
        gettingDue?.cancel()
        if !env.active() { away = true }
        // what was asked about is asked again when its file begins again
        if !held.isEmpty {
            held = [:]
            if asking?.incoming == true { asking = nil }
        }
    }

    /// The session is up on mobile data, or a session went over to it: what's left to send, over 100 MB, waits for a yes.
    func onMobileData() {
        guard env.mobileData(), !heldResume, heldOut == nil, asking == nil, (allowedOut ?? .distantPast) < clock() else { return }
        let left = now.filter { !$0.incoming && $0.outbox == nil && [.waiting, .going, .paused].contains($0.phase) }
            .reduce(0) { $0 + max(0, $1.size - $1.done) }
        guard Self.asksFirst(bytes: left, mobileData: true) else { return }
        heldResume = true
        env.holdOut(true)
        asking = Ask(incoming: false, bytes: left)
    }

    /// Files began coming from the computer: the answer to Get Copied Items, if it was asked.
    func filesAnswered() { getting = false }

    // MARK: from the computer

    /// A file begins from the computer: on mobile data, a big one (what's left of its batch) waits for a yes. Held, it's taken but its
    /// progress isn't said, so the computer stops a window in and waits (a minute) instead of giving up after 10 s.
    func admit(_ i: RemoteFileInfo) -> Admit {
        let key = "\(i.count ?? 1)/\(i.total ?? i.size)", t = clock()
        if let r = refusedIn, r.key == key, r.until > t { return .refuse }
        if let a = allowedIn, a.key == key, a.until > t { return .go }
        // a file going on after a drop: only what's left of it counts
        let had = now.first { $0.id == "in-" + i.id }?.done ?? 0
        guard Self.asksFirst(bytes: max(0, (i.total ?? i.size) - had), mobileData: env.mobileData()) else { return .go }
        held[i.id] = i
        getting = false
        if asking == nil {
            let a = Ask(incoming: true, bytes: max(0, (i.total ?? i.size) - had))
            asking = a
            // the computer waits a minute for the file to move: not answered by then, it's no
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.answerWithin) { [weak self] in
                if self?.asking?.id == a.id { self?.answer(a, yes: false) }
            }
        }
        return .hold
    }

    static let answerWithin: TimeInterval = 50

    /// The computer gave up on a file while it was asked about, or stopped it: with nothing else held, the question goes.
    @discardableResult func heldEnded(_ id: String) -> Bool {
        guard held.removeValue(forKey: id) != nil else { return false }
        if held.isEmpty, asking?.incoming == true { asking = nil }
        return true
    }

    /// The mobile-data question's answer.
    func answer(_ a: Ask, yes: Bool) {
        if asking?.id == a.id { asking = nil }
        if a.incoming {
            let wait = held.values
            held = [:]
            for i in wait {
                let key = "\(i.count ?? 1)/\(i.total ?? i.size)", until = clock().addingTimeInterval(RemoteFiles.keepParts)
                if yes {
                    allowedIn = (key, until)
                    env.release(i.id)
                } else {
                    refusedIn = (key, clock().addingTimeInterval(120))
                    env.stopIn(i.id)
                }
            }
        } else if heldResume {
            heldResume = false
            if yes {
                allowedOut = clock().addingTimeInterval(Self.allowedFor)
            } else {
                now.filter { !$0.incoming && $0.outbox == nil && [.waiting, .going, .paused].contains($0.phase) }.forEach { env.stopOut($0.wire) }
            }
            env.holdOut(false)
        } else if let h = heldOut {
            heldOut = nil
            if yes {
                allowedOut = clock().addingTimeInterval(Self.allowedFor)
                env.queue(h.urls, false, h.temporary, h.made)
            } else {
                h.made.forEach { try? FileManager.default.removeItem(at: $0) }
                if h.temporary { h.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
                h.scoped.forEach { if scoped.remove($0) != nil { $0.stopAccessingSecurityScopedResource() } }
            }
        }
    }

    /// a yes for files going out holds this long: a drop and a reconnect on the same mobile data don't ask again
    static let allowedFor: TimeInterval = 600

    /// Get Copied Items.
    func getCopied() {
        guard env.ready() else { return }
        said = nil
        // asked: the first answer that completes it uses this up (text, nothing, a clip file, or files beginning); a session that drops or
        // 30 s without one clears it. Nothing the computer sends unasked reaches this phone's clipboard
        getting = true
        env.askClipboard()
        gettingDue?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.getting = false }
        gettingDue = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.askedFor, execute: w)
    }

    static let askedFor: TimeInterval = 30

    func clipText(_ t: String) {
        guard getting else { return }
        getting = false
        UIPasteboard.general.string = t
        say(Said(kind: .copied, title: String(localized: "Copied"), detail: TransferWords.firstWords(t)))
    }

    func clipNone(_ why: String) {
        guard getting else { return }
        getting = false
        say(Said(kind: .note, title: TransferWords.nothing(why, name: env.peer()?.name ?? "")))
    }

    /// A `clip` file's content: an image onto the clipboard as it came (kept for Save to Photos), anything else as text. Unasked, it's dropped.
    func clipData(_ data: Data, name: String) {
        guard getting else { return }
        getting = false
        if RemoteFiles.isImage(name), UIImage(data: data) != nil {
            let type = UTType(filenameExtension: (name as NSString).pathExtension)?.identifier ?? UTType.png.identifier
            UIPasteboard.general.setItems([[type: data]])
            let dir = Link.caches.appendingPathComponent("clip", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let keep = dir.appendingPathComponent(RemoteFiles.clean(name))
            try? data.write(to: keep)
            say(Said(kind: .image(keep), title: String(localized: "Image Copied")))
        } else {
            let t = String(decoding: data, as: UTF8.self)
            UIPasteboard.general.string = t
            say(Said(kind: .copied, title: String(localized: "Copied"), detail: TransferWords.firstWords(t)))
        }
    }

    func say(_ s: Said) { said = s }
    func dismissSaid() { said = nil }

    // MARK: to the computer

    /// Files to send, folders already zipped. On mobile data, more than 100 MB asks first. `scoped`: picked in Files, their access held
    /// until each is sent.
    func send(_ urls: [URL], temporary: Bool = false, made: Set<URL> = [], scoped picked: [URL] = []) {
        guard !urls.isEmpty else { return }
        picked.forEach { scoped.insert($0) }
        let total = urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        if Self.asksFirst(bytes: total, mobileData: env.mobileData()), (allowedOut ?? .distantPast) < clock() {
            heldOut = (urls, temporary, made, picked)
            asking = Ask(incoming: false, bytes: total)
            return
        }
        env.queue(urls, false, temporary, made)
    }

    /// Files picked in Files: folders are zipped first (off the main thread), each with a Compressing… row meanwhile.
    func sendPicked(_ urls: [URL]) {
        let open = urls.filter { $0.startAccessingSecurityScopedResource() }
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let zipping = folders.map { f in
            TransferRow(id: "zip-" + UUID().uuidString, wire: "", name: f.lastPathComponent + ".zip", size: 0, incoming: false, phase: .compressing,
                        peer: env.peer()?.name ?? "", at: clock())
        }
        now.insert(contentsOf: zipping, at: 0)
        publish()
        DispatchQueue.global(qos: .userInitiated).async {
            // a file still in iCloud comes down first
            for u in urls where !folders.contains(u) {
                var e: NSError?
                NSFileCoordinator().coordinate(readingItemAt: u, options: .withoutChanges, error: &e) { _ in }
            }
            let ready = RemoteFiles.prepare(urls)
            let made = RemoteFiles.made(ready)
            DispatchQueue.main.async {
                self.now.removeAll { r in zipping.contains { $0.id == r.id } }
                self.publish()
                // a zipped folder needs its access no longer
                for f in folders where open.contains(f) { f.stopAccessingSecurityScopedResource() }
                let files = open.filter { !folders.contains($0) }
                self.send(ready, made: made, scoped: files)
            }
        }
    }

    /// Photos from the system picker (no permission asked): each copied out as it is, then sent and deleted once over. A Preparing… row
    /// while they come out of the library (an iCloud one downloads first); any that couldn't are counted.
    func sendPhotos(_ items: [NSItemProvider]) {
        guard !items.isEmpty else { return }
        let preparing = TransferRow(id: "prep-" + UUID().uuidString, wire: "", name: String(localized: "\(items.count) items"), size: 0, incoming: false,
                                    phase: .preparing, peer: env.peer()?.name ?? "", at: clock())
        now.insert(preparing, at: 0)
        publish()
        let dir = Link.caches.appendingPathComponent("outgoing/" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var got = [URL?](repeating: nil, count: items.count)
        let g = DispatchGroup()
        for (n, p) in items.enumerated() {
            let type = p.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .movie) == true }
                ?? p.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
                ?? UTType.data.identifier
            g.enter()
            _ = p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                defer { g.leave() }
                guard let url else { return }
                let ext = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "") : url.pathExtension
                let base = p.suggestedName.map(RemoteFiles.clean) ?? url.deletingPathExtension().lastPathComponent
                let dest = RemoteFiles.unique(dir.appendingPathComponent(ext.isEmpty || base.lowercased().hasSuffix("." + ext.lowercased()) ? base : base + "." + ext))
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { got[n] = dest }
            }
        }
        g.notify(queue: .main) {
            if self.cancelled.remove(preparing.id) != nil { try? FileManager.default.removeItem(at: dir); return }
            self.now.removeAll { $0.id == preparing.id }
            self.publish()
            let ready = got.compactMap { $0 }
            if ready.count < items.count {
                self.say(Said(kind: .note, title: String(localized: "Couldn’t load \(items.count - ready.count) items.")))
            }
            self.send(ready, temporary: true)
        }
    }

    /// Paste from This Device with an image copied here: it goes as the clipboard's content (a `clip` PNG or JPEG), and the computer pastes
    /// it. False: not an image, or a computer that can't take one; the key types the text as always.
    func pasteImage() -> Bool {
        let pb = UIPasteboard.general
        guard pb.hasImages, Link.shared.hostFeatures.contains(RemoteFeature.clipboard), env.ready() else { return false }
        var data: Data?, ext = "png"
        if let d = pb.data(forPasteboardType: UTType.png.identifier) { data = d }
        else if let d = pb.data(forPasteboardType: UTType.jpeg.identifier) { data = d; ext = "jpg" }
        else if let i = pb.image { data = i.pngData() }
        guard let data else { return false }
        guard data.count <= RemoteFiles.maxClipImage else {
            say(Said(kind: .note, title: String(localized: "Can’t paste images larger than 20 MB.")))
            return true
        }
        let dir = Link.caches.appendingPathComponent("outgoing/" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("Image." + ext)
        guard (try? data.write(to: u)) != nil else { return false }
        env.queue([u], true, true, [])
        return true
    }

    // MARK: a row's buttons

    func stop(_ r: TransferRow) {
        // photos still coming out of the library: they don't go
        if r.phase == .preparing {
            cancelled.insert(r.id)
            now.removeAll { $0.id == r.id }
            return publish()
        }
        if let o = r.outbox, let box = outbox {
            box.remove(r.name, in: box.root.appendingPathComponent(o, isDirectory: true))
            return refreshOutbox()
        }
        if r.incoming { env.stopIn(r.wire) } else { env.stopOut(r.wire) }
    }

    /// Continue: a file of this run that paused or failed on the way goes again, from where the computer has it.
    func canContinue(_ r: TransferRow) -> Bool {
        guard !r.incoming, r.outbox == nil, !r.wire.isEmpty, now.contains(where: { $0.id == r.id }) else { return false }
        switch r.phase {
        case .paused: return true
        case let .failed(w): return !["stopped", "too_big", "space", "read"].contains(w)
        default: return false
        }
    }

    func again(_ r: TransferRow) { env.again(r.wire) }

    #if DEBUG
    /// Pretend.fillTransfers: rows with no computer, and what Get Copied Items would have said
    func pretend(_ r: [TransferRow]) {
        now = r
        publish()
    }
    #endif

    // MARK: the share extension's outbox

    /// What waits there, as rows (× takes a file out), for the computer each was shared to.
    func refreshOutbox() {
        guard let box = outbox else { return }
        waiting = box.waiting(now: clock()).reversed().flatMap { e, folder in
            e.files.map { f in
                TransferRow(id: "box-" + folder.lastPathComponent + "/" + f, wire: "", name: f,
                            size: (try? folder.appendingPathComponent(f).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                            incoming: false, phase: .waiting, peer: e.name, at: e.at, outbox: folder.lastPathComponent)
            }
        }
        publish()
    }

    /// Open and connected to the computer they were shared to: they go now (one batch for each share).
    func pickUp() {
        defer { refreshOutbox() }
        if env.active() { away = false }
        guard let box = outbox, env.active(), env.ready(), let peer = env.peer() else { return }
        let dir = Link.caches.appendingPathComponent("outgoing", isDirectory: true)
        for files in box.take(for: peer.id, into: dir, now: clock()) { send(files, temporary: true) }
    }
}

// MARK: Photos

enum PhotoSave {
    enum Result { case saved, denied, failed }

    /// Save to Photos: the add-only permission is asked here, the first time the button is used, and never before.
    static func save(_ url: URL, video: Bool, done: @escaping (Result) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
            guard s == .authorized || s == .limited else { return DispatchQueue.main.async { done(.denied) } }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: video ? .video : .photo, fileURL: url, options: nil)
            }) { ok, _ in DispatchQueue.main.async { done(ok ? .saved : .failed) } }
        }
    }
}
