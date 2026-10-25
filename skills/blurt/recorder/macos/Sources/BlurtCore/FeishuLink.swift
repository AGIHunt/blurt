// Settings → Export's Feishu / Lark table link: whether a pasted link can be one (checked as it is typed; saved on
// Return, on leaving the field and on leaving the pane). Unit-tested in Tests/BlurtCoreTests/FeishuLinkTests.
import Foundation

public enum FeishuLink {
    /// The hosts Feishu and Lark serve tables from (and their tenant subdomains).
    public static let hosts = ["feishu.cn", "feishu.net", "larksuite.com", "larkoffice.com"]

    /// An http(s) link on one of `hosts`, or on any host with a table's path (/base/…: a private Feishu deployment on
    /// its own domain). Empty: nothing to check.
    public static func plausible(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        guard let u = URL(string: t), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              let h = u.host?.lowercased(), !h.isEmpty else { return false }
        if hosts.contains(where: { h == $0 || h.hasSuffix("." + $0) }) { return true }
        return u.path.lowercased().split(separator: "/").first == "base" && u.path.split(separator: "/").count >= 2
    }
}
