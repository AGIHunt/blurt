// Files a viewer sends (docs/design/remote-1.1.md §6): written to ~/Downloads as "<name>.part" while they arrive, then renamed (a
// number added when the name is taken) and given the quarantine flag, so they're never opened or run by themselves. Refused while
// the screen is locked. A session that ends mid-file leaves nothing behind.
import Foundation
import BlurtCore
import BlurtRemoteKit

final class RemoteFileReceiver {
    static let maxSize = 4 << 30           // 4 GB a file
    static let progressEvery = 1 << 20     // the sender keeps RemoteFiles.window ahead of what's acknowledged

    private struct Incoming {
        let id: String
        let name: String
        let size: Int
        let part: URL
        let handle: FileHandle
        var written = 0
        var told = 0
    }
    private var file: Incoming?
    private let from: String
    private let send: (ToPhone) -> Void

    init(from: String, send: @escaping (ToPhone) -> Void) {
        self.from = from
        self.send = send
    }

    private var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    func begin(id: String, name: String, size: Int) {
        drop()
        if RemoteServer.screenLocked { return send(.fileFailed(id: id, why: "locked")) }
        guard size >= 0, size <= Self.maxSize else { return send(.fileFailed(id: id, why: "too_big")) }
        let free = (try? downloads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard Int64(size) < free - (256 << 20) else { return send(.fileFailed(id: id, why: "space")) }
        let clean = Self.clean(name)
        let part = downloads.appendingPathComponent(clean + ".part")
        guard FileManager.default.createFile(atPath: part.path, contents: nil), let h = try? FileHandle(forWritingTo: part) else {
            return send(.fileFailed(id: id, why: "write"))
        }
        file = Incoming(id: id, name: clean, size: size, part: part, handle: h)
        emit(["event": "remote_file", "state": "begin", "size": size])
    }

    func chunk(id: String, data: Data) {
        guard var f = file, f.id == id else { return }
        guard f.written + data.count <= f.size, (try? f.handle.write(contentsOf: data)) != nil else {
            drop()
            return send(.fileFailed(id: id, why: "write"))
        }
        f.written += data.count
        if f.written - f.told >= Self.progressEvery {
            f.told = f.written
            send(.fileProgress(id: id, bytes: f.written))
        }
        file = f
    }

    func end(id: String) {
        guard let f = file, f.id == id else { return }
        file = nil
        try? f.handle.close()
        guard f.written == f.size else {
            try? FileManager.default.removeItem(at: f.part)
            return send(.fileFailed(id: id, why: "write"))
        }
        let dest = Self.unique(downloads.appendingPathComponent(f.name))
        do { try FileManager.default.moveItem(at: f.part, to: dest) } catch {
            try? FileManager.default.removeItem(at: f.part)
            return send(.fileFailed(id: id, why: "write"))
        }
        // never opened or run by itself: the same flag a browser's download gets
        let q: [String: Any] = [kLSQuarantineAgentNameKey as String: "Blurt", kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        try? (dest as NSURL).setResourceValue(q, forKey: .quarantinePropertiesKey)
        send(.fileSaved(id: id, name: dest.lastPathComponent))
        emit(["event": "remote_file", "state": "saved", "size": f.size])
        Notify.post(title: T("remote.file.received.title", PhoneStatus.name(from)), body: dest.lastPathComponent, uid: "remote-file")
    }

    /// The session ended, or another file began: a file not finished goes.
    func drop() {
        guard let f = file else { return }
        file = nil
        try? f.handle.close()
        try? FileManager.default.removeItem(at: f.part)
    }

    /// A name to write under: no folders, no hidden or empty names.
    static func clean(_ name: String) -> String {
        var n = (name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        while n.hasPrefix(".") { n.removeFirst() }
        return n.isEmpty ? "file" : String(n.prefix(200))
    }

    static func unique(_ u: URL) -> URL {
        guard FileManager.default.fileExists(atPath: u.path) else { return u }
        let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension, dir = u.deletingLastPathComponent()
        for i in 2... {
            let c = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            if !FileManager.default.fileExists(atPath: c.path) { return c }
        }
        return u
    }
}
