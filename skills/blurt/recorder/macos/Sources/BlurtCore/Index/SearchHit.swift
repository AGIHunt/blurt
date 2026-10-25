// A search result's snippet next to its title (the main list's rows, the ⌘K palette): shown only when it adds
// something. index.db marks the hit as "[word]" and cuts with "…"; a snippet that is just the title again, or a piece
// of it, is left out — a mechanical text check, nothing about meaning.
import Foundation

public enum SearchHit {
    /// One line for a one-line row: a snippet (or title) spanning lines — an item's steps, "Open /login⏎Click Sign in" —
    /// joins with " · " instead of wrapping into a clipped second line under the row.
    public static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The snippet as plain text: "…the [login] button…" → "the login button".
    public static func plain(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "…").union(.whitespacesAndNewlines))
    }

    /// Whether the snippet says something the title doesn't (nil / empty / inside the title: no).
    public static func adds(_ snippet: String?, to title: String) -> Bool {
        guard let s = snippet else { return false }
        let p = plain(s)
        return !p.isEmpty && !title.localizedCaseInsensitiveContains(p)
    }
}
