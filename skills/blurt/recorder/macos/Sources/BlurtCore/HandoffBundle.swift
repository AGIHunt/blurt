// The hand-off bundle's file name, for the main window's Save panel (Export Hand-off Bundle…): the same
// "<project>-<date>-<n items>.zip" the skill gives it (scripts/export_local.py bundle_name / slug — keep the two in
// step). The bundle itself is made by `export_local.py bundle --items … -o <the chosen path>`.
// Unit-tested in Tests/BlurtCoreTests/HandoffBundleTests (the same cases as tests/test_bundle.py).
import Foundation

public enum HandoffBundle {
    /// A file-name-safe form of a name: letters (any script), digits, "_", "." and "-" kept, every other run "-",
    /// ASCII lowercased (export_local.slug).
    public static func slug(_ s: String, fallback: String = "blurt") -> String {
        var out = ""
        var gap = false
        for c in s.trimmingCharacters(in: .whitespacesAndNewlines) {
            if c.isLetter || c.isNumber || c == "_" || c == "." || c == "-" {
                if gap { out.append("-"); gap = false }
                out.append(c)
            } else {
                gap = true
            }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        let edge: Set<Character> = ["-", ".", "_"]
        func trim(_ x: String) -> String {
            var x = Substring(x)
            while let f = x.first, edge.contains(f) { x.removeFirst() }
            while let l = x.last, edge.contains(l) { x.removeLast() }
            return String(x)
        }
        let lowered = String(trim(out).map { $0.isASCII ? Character($0.lowercased()) : $0 })
        let r = trim(String(lowered.prefix(60)))
        return r.isEmpty ? fallback : r
    }

    /// "checkout-web-2026-10-25-12-items.zip" / "官网-2026-10-25-3条.zip". project nil (items from several
    /// projects): "blurt-…".
    public static func fileName(project: String?, count: Int, chinese: Bool, day: Date = Date(),
                                timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        let n = chinese ? "\(count)条" : (count == 1 ? "1-item" : "\(count)-items")
        return "\(slug(project ?? ""))-\(f.string(from: day))-\(n).zip"
    }
}
