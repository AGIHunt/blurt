// What the embedded review page needs from the core: review.py's handshake addresses (ReviewLink) and the capped byte
// ranges its media is served with (ByteRange).
import Foundation

/// review.py's page, shown in the main window instead of the browser (SKILL.md §3–5): the app tells review.py it
/// has the batch (`api/attached`, so no browser opens) and that the user confirmed it (`api/done`, so review.py
/// prints its summary and the agent goes on). Only review.py's own address is ever called: a local http URL with
/// its per-run token path — a distributed notification can come from any process.
public enum ReviewLink {
    public static func endpoint(_ base: String, _ path: String) -> URL? {
        guard let u = URL(string: base), let c = URLComponents(url: u, resolvingAgainstBaseURL: false), c.scheme == "http",
              ["127.0.0.1", "localhost"].contains(c.host ?? ""), c.port != nil, c.path.hasPrefix("/r/"), c.path.hasSuffix("/"),
              c.path.count > 4, c.query == nil else { return nil }
        return URL(string: path, relativeTo: u)?.absoluteURL
    }
}

/// A Range request on a file of `size` bytes, answered with at most `cap` bytes (a player asks for the next part):
/// nil when it can't be satisfied (416).
public enum ByteRange {
    public static let cap = 8 << 20

    public static func plan(_ header: String, size: Int, cap: Int = ByteRange.cap) -> ClosedRange<Int>? {
        guard header.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        var start: Int, end: Int
        if parts[0].isEmpty {           // bytes=-N: the last N
            guard let n = Int(parts[1]), n > 0 else { return nil }
            start = max(0, size - n)
            end = size - 1
        } else {
            guard let s = Int(parts[0]) else { return nil }
            start = s
            end = parts[1].isEmpty ? size - 1 : Int(parts[1]) ?? size - 1
        }
        end = min(end, size - 1, start + cap - 1)
        guard start >= 0, start < size, end >= start else { return nil }
        return start...end
    }
}
