// A snap's optional type, chosen in its note bubble (the founder, 2026-10-31): 问题 / 想法 / 笔记 / 待办 — the item kinds
// issue / idea / note / task, in that order (⌘1–⌘4; ⌘0 clears it). Not choosing is a valid state: undecided, and the
// organizing run (or captures.py's keyword guess, then AI fill-in) decides as before. Chosen, it is stored with the
// snap (shots.jsonl "kind") and the item made from it has that kind, kept as the user's (`_user`): items.py
// build_item, captures.py fields_for. Old snaps have no "kind" (or null): undecided.

import Foundation

public enum NoteKind: String, CaseIterable, Equatable {
    case issue, idea, note, task

    /// Its key with ⌘: 1…4 in the list's order (⌘0 is "none").
    public var digit: Int { (NoteKind.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// The kind ⌘`digit` sets: `.some(nil)` for ⌘0 (none), nil when that digit isn't one of the bubble's.
    public static func forDigit(_ digit: Int) -> NoteKind?? {
        if digit == 0 { return .some(nil) }
        return allCases.first { $0.digit == digit }.map { .some($0) }
    }

    /// A shots.jsonl value: one of the four, else nil (absent, null, anything else: undecided).
    public static func parse(_ raw: Any?) -> NoteKind? { (raw as? String).flatMap(NoteKind.init(rawValue:)) }
}
