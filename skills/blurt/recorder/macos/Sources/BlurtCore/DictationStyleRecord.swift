// What a take's style was and why, and reformat-last's rules (docs/design/dictation-styles.md §3.2 E, §3.4).
// Pure: DictationStyleLearnTests.
//
//  • DictationStyleRecord: the history's `style`, `style_source`, `style_router` (the router's inputs and decision:
//    category, the app's own style, ⇧ / the island, toggles, rendered, the category variant's changes) and
//    `reformats` (reformat-last, its undo, a list the user took apart in the field, the island's list suggestion).
//  • DictationReformat: the pasted text is replaced only while it is exactly as it was typed, between the same
//    anchors (the user's own edits are never overwritten); otherwise the new version goes to the clipboard.
import Foundation

public struct DictationReformatRecord: Hashable {
    /// reformat | undo | revert (the list was taken apart in the field) | suggest (the island offered a list: the
    /// structuring pass found one in a take typed as prose)
    public var action: String
    public var from: String
    public var to: String
    /// the field's text was replaced (false: the new version went to the clipboard)
    public var replaced: Bool
    public var time: Date
    /// what the field holds now (replaced), and what it held before: the history shows the text as it stands
    public var text: String?
    public var before: String?

    public init(action: String, from: String, to: String, replaced: Bool, time: Date = Date(), text: String? = nil,
                before: String? = nil) {
        self.action = action; self.from = from; self.to = to; self.replaced = replaced; self.time = time
        self.text = text; self.before = before
    }

    public var json: [String: Any] {
        var o: [String: Any] = ["action": action, "from": from, "to": to, "replaced": replaced, "t": DictationEntry.iso.string(from: time)]
        if let t = text { o["text"] = t }
        if let b = before { o["before"] = b }
        return o
    }

    public init?(json o: [String: Any]) {
        guard let a = o["action"] as? String else { return nil }
        action = a
        from = o["from"] as? String ?? ""
        to = o["to"] as? String ?? ""
        replaced = o["replaced"] as? Bool ?? false
        time = (o["t"] as? String).flatMap { DictationEntry.iso.date(from: $0) } ?? Date(timeIntervalSince1970: 0)
        text = o["text"] as? String
        before = o["before"] as? String
    }
}

public struct DictationStyleRecord: Hashable {
    public var style: String
    public var source: String
    public var category: String
    /// what the app / category / default alone gave
    public var base: String
    /// ⇧ / the island during this take (its last choice)
    public var explicit: String?
    public var toggles: Int
    /// ordered list markers the old rule-based renderer found (entries before the model-first styles; 0 now)
    public var markers: Int
    public var rendered: Bool
    /// the category variant's changes (final_stop, blank_lines, one_line)
    public var variant: [String]
    public var reformats: [DictationReformatRecord] = []

    /// the take sounded like a list: the island offered one (the structuring pass found it), or — older entries — the
    /// old renderer counted ≥ 2 markers
    public var listLikely: Bool { markers >= 2 || reformats.contains { $0.action == "suggest" } }

    public init(style: String, source: String, category: String, base: String, explicit: String? = nil,
                toggles: Int = 0, markers: Int = 0, rendered: Bool = false, variant: [String] = []) {
        self.style = style; self.source = source; self.category = category; self.base = base; self.explicit = explicit
        self.toggles = toggles; self.markers = markers; self.rendered = rendered; self.variant = variant
    }

    /// Keys written into the entry's line.
    public func write(into o: inout [String: Any]) {
        o["style"] = style
        o["style_source"] = source
        var r: [String: Any] = ["category": category, "base": base, "toggles": toggles, "list_likely": listLikely,
                                "rendered": rendered]
        if markers > 0 { r["markers"] = markers }
        if let e = explicit { r["explicit"] = e }
        if !variant.isEmpty { r["variant"] = variant }
        o["style_router"] = r
        if !reformats.isEmpty { o["reformats"] = reformats.map(\.json) }
    }

    public init?(json o: [String: Any]) {
        guard let s = o["style"] as? String else { return nil }
        let r = o["style_router"] as? [String: Any] ?? [:]
        style = s
        source = o["style_source"] as? String ?? "default"
        category = r["category"] as? String ?? "other"
        base = r["base"] as? String ?? s
        explicit = r["explicit"] as? String
        toggles = r["toggles"] as? Int ?? 0
        markers = r["markers"] as? Int ?? 0
        rendered = r["rendered"] as? Bool ?? false
        variant = r["variant"] as? [String] ?? []
        reformats = (o["reformats"] as? [[String: Any]] ?? []).compactMap(DictationReformatRecord.init(json:))
    }
}

public enum DictationReformat {
    /// how long after the paste reformat-last may still replace the text in the field (later: the clipboard)
    public static let window: Double = 300

    /// Where the pasted text still is, untouched: `inserted` with the same text before and after it as when it went
    /// in (`prefix` / `suffix`, up to 40 characters each), the occurrence nearest `near` (UTF-16). nil: the user has
    /// edited it (or around it), or it is gone.
    public static func span(in text: String, inserted: String, prefix: String, suffix: String, near: Int) -> NSRange? {
        let ns = text as NSString
        let needle = prefix + inserted + suffix
        guard !inserted.isEmpty, (needle as NSString).length <= ns.length else { return nil }
        var best: NSRange?
        var from = 0
        while from < ns.length {
            let r = ns.range(of: needle, options: [.literal], range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound else { break }
            let at = NSRange(location: r.location + (prefix as NSString).length, length: (inserted as NSString).length)
            if best == nil || abs(at.location - near) < abs(best!.location - near) { best = at }
            from = r.location + 1
        }
        return best
    }

    /// The numbered lines of a rendered list ("1. …" at a line start).
    static func listLines(_ s: String) -> Int {
        s.components(separatedBy: "\n").filter { $0.range(of: #"^\s*[0-9]{1,2}\. \S"#, options: .regularExpression) != nil }.count
    }

    /// The user took the list apart in the field (the watch saw it): the typed text had ≥ 2 numbered lines, the
    /// edited one has fewer, and most of the words are still there (a deleted paragraph is not a revert).
    public static func reverted(typed: String, edited: String) -> Bool {
        guard listLines(typed) >= 2, listLines(edited) < 2 else { return false }
        let a = DictationStitch.units(typed).map(\.value).filter { !$0.allSatisfy(\.isNumber) }
        var b = DictationStitch.units(edited).map(\.value)
        var kept = 0
        for u in a { if let i = b.firstIndex(of: u) { b.remove(at: i); kept += 1 } }
        return !a.isEmpty && Double(kept) / Double(a.count) >= 0.7
    }
}
