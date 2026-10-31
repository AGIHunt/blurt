// A voice card dropped anywhere in a chat app's window (v0.8.6).
//
// The report: dragging a voice card into Claude Code / Claude desktop only worked when it landed exactly on the input
// box, while a shot card gets the whole window as its "drop here" zone. A voice card drags as text, and Electron (and
// a browser page) shows its drop overlay — and takes the drop — only for files: text let go of anywhere but the
// composer itself is refused, and the card springs back. So for a voice card the drop point decides, not the app's
// answer: let go of over a window of a chat app (the browsers, Electron apps, WeChat / QQ — DropTargets, the table
// the shot cards use), Blurt brings that window forward, gives its composer the focus (the editable text under the
// drop point, else the nearest one: ComposerPick) and pastes the words there — the shot cards' follow-up paste
// (DragNoteFollowUp), with the words instead of the note. The drag shows our own hint while it is over such a window
// ("松手粘贴到 Claude"): the app shows none for text.
//
//   over                                   let go                         what happens
//   a chat app (web / Qt composer)         refused (anywhere but the box) Blurt pastes the words into its composer
//                                          taken (the box itself)          the app's own text drop — nothing more
//   a rich app, a terminal, the Finder,    the app's own text drop, as before (a terminal types the one-line text at
//   an unknown native app, a code editor   the prompt where a text drop would — never a Return: nothing runs)
//   Blurt, nothing                         the card goes back to its thread
// Can't paste (smart paste off, no Accessibility, secure input, the app didn't come forward, the paste wasn't read):
// the words go on the clipboard and the island says "⌘V to paste" — the card counts as taken, with Undo.
//
// v0.9 — the report: a voice card dragged into Feishu did nothing (WeChat was fine). Feishu's chat area takes a
// text drop — the drag ends as taken — and puts nothing in, so "the app took it" left Blurt doing nothing at all.
// Feishu / Lark only (DropTargets.feishu, swallowsTextDrop): when Blurt can paste (withholdsWords), the drag carries
// no words over its windows (CardPasteboard.drag(into:): only the capture's tag) and Blurt pastes them into the
// composer, taken or not; when it can't, they go on the clipboard whatever Feishu answered. Every other app's "yes"
// stands: WeChat / QQ, the browsers, Claude, Slack… put a text drop on their composer in themselves.

import Foundation

public enum VoiceCardDrop {
    /// A window whose app gets the words pasted when a voice card is let go of over it: a chat app with a web or Qt
    /// composer. (A native app we don't know, and a code editor, keep the normal text drop: a paste there could go
    /// anywhere — in an editor, into source code.)
    public static func pastes(cls: DropClass, kind: ComposerKind) -> Bool { cls == .chat && (kind == .web || kind == .qt) }

    /// The app takes a text drop and may put nothing in (Feishu / Lark: v0.9 report): its "yes" doesn't count.
    public static func swallowsTextDrop(bundleID: String?) -> Bool { DropTargets.isFeishu(bundleID) }

    /// The drag leaves the words off over this window: an app that swallows a text drop (Feishu / Lark), and Blurt can
    /// paste (`canPaste`: smart paste on, Accessibility granted). Without that the words stay on the drag: a drop on the
    /// composer itself is then the only way they go in directly. Every other app keeps its own text drop.
    public static func withholdsWords(bundleID: String?, cls: DropClass, kind: ComposerKind, canPaste: Bool) -> Bool {
        canPaste && pastes(cls: cls, kind: kind) && swallowsTextDrop(bundleID: bundleID)
    }

    public enum Plan: Equatable {
        /// not ours to finish: the app took the drop (its own text drop), or it isn't a paste target
        case none(String)
        /// the follow-up: focus the composer, paste the words
        case paste(String)
        /// the follow-up can't run: the words on the clipboard ("⌘V to paste")
        case copy(String)
    }

    /// `accepted`: the app took the drop (the session ended with an operation); `words`: what the card says;
    /// `swallows`: the app may take a text drop and put nothing in (swallowsTextDrop: Feishu); `wordsWithheld`: the
    /// drag carried no words there when it was let go of (withholdsWords, as last written to the drag).
    ///  • taken, by an app whose "yes" stands (WeChat, QQ, browsers, Claude…): its own text drop — nothing more.
    ///  • taken by Feishu, or with no words to take, or refused: Blurt pastes when it can, else the words go on the
    ///    clipboard ("⌘V to paste").
    public static func plan(cls: DropClass?, kind: ComposerKind?, accepted: Bool, words: String?, enabled: Bool,
                            accessibility: Bool, secureInput: Bool, swallows: Bool = false, wordsWithheld: Bool = false) -> Plan {
        guard let c = cls, let k = kind, pastes(cls: c, kind: k) else { return .none("not_a_chat_app") }
        if accepted, !swallows, !wordsWithheld { return .none("app_took_it") }
        guard let w = CardNote.clean(words) else { return .none("no_words") }
        guard enabled, accessibility, !secureInput else { return .copy(w) }
        return .paste(w)
    }

    /// How the follow-up paste went: the app read it, the keys went (End, ⌘V) but the read wasn't seen (common in
    /// Electron apps: Claude, Slack, Discord), or it never got that far.
    public enum Pasted: String, Equatable { case confirmed, unconfirmed, notSent }

    /// What the island says after the drop, and whether the words go on the clipboard. Keys sent but unconfirmed is
    /// pasted, as smart paste reports it ("Pasted into Claude · Undo"); the words stay on the clipboard quietly as the
    /// safety net — the dogfood's "Copied — ⌘V to paste" there invited a second copy. "⌘V to paste" is only for a
    /// paste that never went.
    public static func outcome(_ p: Pasted) -> (toast: String, copyWords: Bool) {
        switch p {
        case .confirmed: return ("capture.voice_drop.pasted", false)
        case .unconfirmed: return ("capture.voice_drop.pasted", true)
        case .notSent: return ("capture.voice_drop.copied", true)
        }
    }

    /// The drag's hint over a window (nil: none — Blurt's own windows, nothing, an app that isn't a paste target).
    public enum Hint: Equatable {
        /// "松手粘贴到 Claude"
        case paste(app: String)
        /// "松手后 ⌘V 粘贴到 Claude" — the follow-up can't run (no Accessibility, smart paste off)
        case copy(app: String)
    }

    public static func hint(cls: DropClass?, kind: ComposerKind?, app: String?, enabled: Bool, accessibility: Bool) -> Hint? {
        guard let c = cls, let k = kind, pastes(cls: c, kind: k) else { return nil }
        let name = app.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "App"
        return enabled && accessibility ? .paste(app: name) : .copy(app: name)
    }
}
