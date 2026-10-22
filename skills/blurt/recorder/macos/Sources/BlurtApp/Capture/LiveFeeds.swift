// The readers for a recording's live/*.jsonl (drafts, transcript) the island follows while recording.
import Foundation

/// Tolerant: a missing file, a partial last line, a file rewritten from scratch.
final class JSONLTail {
    let url: URL
    private var offset: UInt64 = 0
    private var carry = Data()
    init(_ url: URL) { self.url = url }

    func poll() -> [[String: Any]] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { offset = 0; carry = Data() }      // rewritten from scratch
        guard size > offset else { return [] }
        try? fh.seek(toOffset: offset)
        let data = (try? fh.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        var buf = carry + data
        var out: [[String: Any]] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf[buf.startIndex..<nl]
            buf = Data(buf[buf.index(after: nl)...])
            if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { out.append(o) }
        }
        carry = buf
        return out
    }
}

/// Follows `<session>/live/drafts.jsonl` (≈1 s polls) and keeps the current set of drafts; reports adds / drops.
final class DraftsWatcher {
    private let tail: JSONLTail
    private(set) var current: [String: [String: Any]] = [:]
    private(set) var order: [String] = []
    var onAdd: ((String, String?) -> Void)?
    var onDrop: ((String) -> Void)?

    init(session: URL) { tail = JSONLTail(session.appendingPathComponent("live/drafts.jsonl")) }

    func poll() {
        for o in tail.poll() {
            guard let id = (o["id"] as? String) ?? (o["id"] as? NSNumber)?.stringValue else { continue }
            let op = o["op"] as? String ?? "add"
            if op == "drop" {
                if current.removeValue(forKey: id) != nil { order.removeAll { $0 == id }; onDrop?(id) }
            } else if current[id] == nil {
                current[id] = o
                order.append(id)
                onAdd?(id, o["kind"] as? String)
            } else {
                current[id] = (current[id] ?? [:]).merging(o) { $1 }
            }
        }
    }

    var kinds: [String] { order.compactMap { current[$0] }.map { $0["kind"] as? String ?? "note" } }
}
