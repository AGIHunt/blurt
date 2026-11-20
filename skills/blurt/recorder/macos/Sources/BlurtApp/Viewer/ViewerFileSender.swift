// Files to the computer a window shows (docs/design/remote-1.1.md §6): Send Files… or dropped on the picture, each to the host's
// Downloads in order, a chunk at a time, never more than `window` ahead of what the host says it has written. The window says how
// each one went.
import Foundation
import BlurtRemoteKit

final class ViewerFileSender {
    static let chunk = 192 * 1024
    static let window = 4 << 20

    private let link: RemoteViewerLink
    private let queue = DispatchQueue(label: "blurt.viewer.files")
    private var acked: [String: Int] = [:]
    private let lock = NSLock()
    /// on the main thread: "sending", "saved", "failed" and the name or why
    var onState: ((String, String) -> Void)?

    init(link: RemoteViewerLink) { self.link = link }

    func send(_ urls: [URL]) {
        queue.async { urls.forEach { self.one($0) } }
    }

    /// What the host said (ToPhone.file…), from the window.
    func heard(_ m: ToPhone) {
        switch m {
        case let .fileProgress(id, bytes): lock.withLock { if acked[id] != nil { acked[id] = bytes } }
        case let .fileSaved(id, name):
            lock.withLock { acked[id] = nil }
            DispatchQueue.main.async { self.onState?("saved", name) }
        case let .fileFailed(id, why):
            lock.withLock { acked[id] = nil }
            DispatchQueue.main.async { self.onState?("failed", why) }
        default: break
        }
    }

    private func one(_ url: URL) {
        let name = url.lastPathComponent
        guard let h = try? FileHandle(forReadingFrom: url),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return DispatchQueue.main.async { self.onState?("failed", "read") }
        }
        defer { try? h.close() }
        let id = RemoteCrypto.newID()
        lock.withLock { acked[id] = 0 }
        DispatchQueue.main.async { self.onState?("sending", name) }
        link.send(.fileBegin(id: id, name: name, size: size))
        var sent = 0
        while true {
            // the host is at most `window` behind; a minute without it moving and this one is given up
            var waited = 0
            while let a = lock.withLock({ acked[id] }), sent - a > Self.window {
                if waited > 3000 { return }
                Thread.sleep(forTimeInterval: 0.02)
                waited += 1
            }
            guard lock.withLock({ acked[id] }) != nil else { return }   // the host refused it and said why
            guard let d = try? h.read(upToCount: Self.chunk), !d.isEmpty else { break }
            link.send(.fileChunk(id: id, data: d))
            sent += d.count
        }
        link.send(.fileEnd(id: id))
    }
}
