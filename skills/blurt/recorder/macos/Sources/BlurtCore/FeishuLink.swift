// Settings → Export's Feishu / Lark table link: whether a pasted link can be one (checked as it is typed; saved on
// Return, on leaving the field and on leaving the pane). Unit-tested in Tests/BlurtCoreTests/FeishuLinkTests.
import Foundation

public enum FeishuLink {
    /// The hosts Feishu and Lark serve tables from (and their tenant subdomains).
    public static let hosts = ["feishu.cn", "feishu.net", "larksuite.com", "larkoffice.com"]

    /// An http(s) link on one of `hosts` (empty: nothing to check).
    public static func plausible(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        guard let u = URL(string: t), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              let h = u.host?.lowercased() else { return false }
        return hosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }
}
