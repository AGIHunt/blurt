import Foundation

/// Where dictated text sits in the field it went into, read back afterwards (the after-take learning and the style anchors).
public enum TypedTextFind {
    /// The UTF-16 offset of `typed` in `text`: at `location` (where the cursor was) when it's there, else the first match from 200
    /// characters before it (a field that trims or reflows what it was given); nil when it's gone. Any `location` is safe: a field
    /// can read back much shorter than where its cursor was (a web field that rewrote its value), and searching from past its end
    /// made a negative range that ended the app (1.0.26 crash, 2026-11-19).
    public static func find(_ typed: String, in text: String, near location: Int) -> Int? {
        let ns = text as NSString, len = (typed as NSString).length
        guard len <= ns.length else { return nil }
        if location >= 0, location <= ns.length - len, ns.substring(with: NSRange(location: location, length: len)) == typed {
            return location
        }
        let lo = min(max(0, location - 200), ns.length)
        let r = ns.range(of: typed, options: [], range: NSRange(location: lo, length: ns.length - lo))
        return r.location == NSNotFound ? nil : r.location
    }
}
