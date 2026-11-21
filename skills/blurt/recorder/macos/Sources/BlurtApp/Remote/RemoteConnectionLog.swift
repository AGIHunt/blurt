// 连接记录 / Connection log (docs/design/remote-1.1.md §3): every session on this Mac (which device, from when to when, which way it
// came) and every new pairing, kept here only (~/.blurt/remote/connections.json, owner-only), the last 200. Shown on the Remote
// Control page, so whoever owns this Mac can see who was in it, and when.
import Foundation
import BlurtCore

struct RemoteConnection: Codable, Equatable, Identifiable {
    var id = UUID()
    var deviceID: String
    var name: String
    var start: Date
    var end: Date?
    /// RemoteServer.Path's raw value, as it came in
    var path: String?
    /// a new pairing, not a session
    var paired = false
}

enum RemoteConnectionLog {
    static let changed = Notification.Name("blurt.remote.connections_changed")
    private static let keep = 200
    private static var file: URL { BlurtPaths.home.appendingPathComponent("remote/connections.json") }
    private static let lock = NSLock()

    static func all() -> [RemoteConnection] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    /// A session began: its entry, to finish with `ended`.
    @discardableResult
    static func began(_ deviceID: String, name: String, path: String?) -> UUID {
        let e = RemoteConnection(deviceID: deviceID, name: name, start: Date(), path: path)
        change { $0.append(e) }
        return e.id
    }

    static func ended(_ id: UUID) {
        change { list in if let i = list.lastIndex(where: { $0.id == id }) { list[i].end = Date() } }
    }

    static func paired(_ deviceID: String, name: String) {
        change { $0.append(RemoteConnection(deviceID: deviceID, name: name, start: Date(), end: nil, path: nil, paired: true)) }
    }

    private static func change(_ f: (inout [RemoteConnection]) -> Void) {
        lock.lock()
        var list = read()
        f(&list)
        if list.count > keep { list.removeFirst(list.count - keep) }
        if let d = try? JSONEncoder().encode(list) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
    }

    private static func read() -> [RemoteConnection] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([RemoteConnection].self, from: $0) } ?? []
    }
}
