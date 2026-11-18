// The reader for a recording's live/transcript.jsonl, which the island follows while recording.
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
