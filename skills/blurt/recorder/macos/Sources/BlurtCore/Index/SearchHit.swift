// A search result's snippet next to its title (the main list's rows, the ⌘K palette): shown only when it adds
// something. index.db marks the hit as "[word]" and cuts with "…"; a snippet that is just the title again, or a piece
// of it, is left out — a mechanical text check, nothing about meaning. Shown on one line (shown): the lines joined with
// " · ", index.db's "…" kept where it cut, and a last line cut down to a scrap ("Open /login · Cl…") ends at the cut
// instead ("Open /login …").
import Foundation

public enum SearchHit {
    /// One line for a one-line row: a snippet (or title) spanning lines — an item's steps, "Open /login⏎Click Sign in" —
    /// joins with " · " instead of wrapping into a clipped second line under the row.
    public static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// A snippet as a row shows it: one line (oneLine), the "…" where index.db cut it kept, the [hit] markers kept (the
    /// list bolds them; `unmarked` drops them). A last line cut to a scrap — under 4 characters, not the hit — goes, and
    /// the line ends at the cut: "Open /[login]⏎Cl…" → "Open /[login] …", never a dangling "· Cl…".
    public static func shown(_ snippet: String) -> String {
        var parts = oneLine(snippet).components(separatedBy: " · ")
        if parts.count > 1, let last = parts.last, last.hasSuffix("…"), !last.contains("["),
           last.filter({ $0 != "…" }).trimmingCharacters(in: .whitespaces).count < 4 {
            parts.removeLast()
            return parts.joined(separator: " · ") + " …"
        }
        return parts.joined(separator: " · ")
    }

    /// The [hit] markers dropped, nothing else: "…the [login] button…" → "…the login button…".
    public static func unmarked(_ s: String) -> String {
        s.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
    }

    /// The snippet as plain text, for comparing (adds): "…the [login] button…" → "the login button".
    public static func plain(_ snippet: String) -> String {
        unmarked(snippet).trimmingCharacters(in: CharacterSet(charactersIn: "…").union(.whitespacesAndNewlines))
    }

    /// Whether the snippet says something the title doesn't (nil / empty / inside the title: no).
    public static func adds(_ snippet: String?, to title: String) -> Bool {
        guard let s = snippet else { return false }
        let p = plain(s)
        return !p.isEmpty && !title.localizedCaseInsensitiveContains(p)
    }
}
