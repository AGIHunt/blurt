// Picture *then* note, as two pastes, into every app that takes one thing per paste or drop (v0.8.4 for WeChat / QQ;
// every chat app since v0.8.5). The reports: in WeChat a card dragged in, or clicked (copied) and pasted with ⌘V,
// arrived as the picture alone; in DeepSeek's web chat a dragged card arrived as the picture and a .md file.
//
// What WeChat's bundle says (4.1.8, read-only `strings` over WeChat.app; nothing run, nothing pasted): WeChat 4 is a
// Qt 5 app, not AppKit. Its pasteboard goes through Qt's QMacPasteboardMime converters — public.tiff (the picture as
// application/x-qt-image), public.html and public.rtf (both → text/html), public.utf8-plain-text, public.file-url
// (text/uri-list) and com.trolltech.anymime.* (Qt's wrapper for any other MIME type). No public.png, no RTFD. Its
// composer, offered a picture, takes the picture and nothing else. A web composer (DeepSeek, ChatGPT, Claude in a
// browser; Claude desktop, Feishu, Slack in Electron) does the same in its own way: a drop or a paste with a file or
// an image in it becomes an upload, and the text and the HTML next to it are ignored. So no flavour fixes it; Blurt
// pastes twice, in every app of the chat class (CardDropTarget.swift — everything but rich text apps, terminals and
// the Finder):
//
//   • smart paste (record.smart_paste, on): for 2 minutes after a card is copied (a click, a ⌘-click selection, Copy
//     All, Recently Taken), ⌘V in a chat app runs a short sequence instead of one paste: each picture, then its note
//     — img, text, img, text… — one single-flavour item on the clipboard per step, ⌘V each, the next step once the
//     app has read the last (or after a timeout); then the card copy goes back on the clipboard (and is armed again),
//     so ⌘V works again. Only while the clipboard still holds that copy (its change count). Rich apps (one RTFD paste
//     brings both), terminals and the Finder get the ⌘V untouched; so does Blurt itself.
//   • a drag into a chat app: the drop brings the picture as its only file; then Blurt pastes the note into the same
//     composer — the app is brought to the front at the window it was dropped on, the composer there gets the focus
//     if Accessibility can find it (FollowUpFocus, ComposerPick), the caret goes after the picture where that is
//     needed (CaretKey), the note goes in as one paste, and the clipboard comes back. It counts only if the app read
//     the note. Without Accessibility, with the setting off, or if it can't: the note goes on the clipboard (the
//     drag_copy_note safety net) and the toast says "⌘V to paste the note".
// Both need Accessibility (the posted ⌘V). Test builds never post an event: the app routes each key to a stand-in.

import Foundation

/// WeChat and QQ (Qt): their composer takes one thing per paste or drop — a picture or text, never both (the picture
/// wins) — and a dropped picture is left selected (ComposerKind.qt: ⌘↓ before the note).
public enum SingleFlavourApps {
    public static let bundles: Set<String> = ["com.tencent.xinWeChat", "com.tencent.qq"]
    public static func contains(_ bundleID: String?) -> Bool { bundleID.map(bundles.contains) ?? false }
}

/// One paste of a sequence: a picture alone, or text alone.
public enum PasteStep: Equatable {
    case image(URL)
    case text(String)
}

public enum CardPasteSequence {
    /// A copy's cards as single pastes, in order: each picture, then its note (line breaks kept). Text next to text (a
    /// voice card after a note) goes in as one paste, a blank line between; a note with more after it ends its line.
    public static func steps(_ cards: [CardPasteboard.Card]) -> [PasteStep] {
        var out: [PasteStep] = []
        func add(_ s: PasteStep) {
            if case .text(let b) = s, case .text(let a)? = out.last { out[out.count - 1] = .text(a + "\n\n" + b); return }
            out.append(s)
        }
        for c in cards {
            if let i = c.image { add(.image(i)) }
            if let n = CardNote.clean(c.note) { add(.text(n)) }
        }
        // a note with more after it ends its line: in a web composer the pictures become attachments and the notes
        // would run together; in WeChat the next picture starts a line of its own
        for i in out.indices.dropLast() {
            if case .text(let t) = out[i] { out[i] = .text(t + "\n") }
        }
        return out
    }

    /// A sequence is only worth it with two things or more: a lone picture or a lone text pastes as it is.
    public static func needsSequence(_ steps: [PasteStep]) -> Bool { steps.count > 1 }
}

/// A copy armed for smart paste: the clipboard's change count right after it was written, and until when.
public struct SmartPasteArm: Equatable {
    /// how long after a copy ⌘V in a chat app pastes picture and note (seconds)
    public static let window: Double = 120

    public var changeCount: Int
    public var steps: [PasteStep]
    public var until: Double

    public init(changeCount: Int, steps: [PasteStep], now: Double) {
        self.changeCount = changeCount; self.steps = steps; until = now + SmartPasteArm.window
    }

    /// Still ours and still in time: the clipboard holds this copy (nothing copied since) and the window hasn't passed.
    public func isLive(now: Double, changeCount: Int) -> Bool { now < until && changeCount == self.changeCount }

    /// After a sequence put the copy back: the new change count, and the window starts again.
    public func rearmed(changeCount: Int, now: Double) -> SmartPasteArm { SmartPasteArm(changeCount: changeCount, steps: steps, now: now) }
}

/// Is this key press ⌘V? ⌘ alone (⇧⌘V / ⌥⌘V / ⌃⌘V are other commands), not a key repeat, and the key that types "v"
/// in the current layout (the characters), or the V key when the event has none.
public enum PasteChord {
    public static let command: UInt64 = 0x10_0000, shift: UInt64 = 0x2_0000, control: UInt64 = 0x4_0000, option: UInt64 = 0x8_0000
    public static let vKeyCode = 9

    public static func isPaste(keyCode: Int, characters: String?, flags: UInt64, autorepeat: Bool) -> Bool {
        guard !autorepeat, flags & command != 0, flags & (shift | control | option) == 0 else { return false }
        if let c = characters, !c.isEmpty { return c.lowercased() == "v" }
        return keyCode == vKeyCode
    }
}

/// What a ⌘V in another app does while a copy is armed.
public enum SmartPastePolicy {
    public enum Decision: Equatable {
        /// the paste goes through as it is (why not)
        case pass(String)
        /// the sequence runs instead
        case sequence
    }

    public struct Input: Equatable {
        public var enabled: Bool
        public var arm: SmartPasteArm?
        public var now: Double
        public var changeCount: Int
        public var frontBundle: String?
        public var accessibility: Bool
        public var secureInput: Bool
        public var running: Bool
        /// Blurt itself is in front (its own text views paste the rich copy as it is)
        public var frontIsBlurt: Bool
        public init(enabled: Bool, arm: SmartPasteArm?, now: Double, changeCount: Int, frontBundle: String?,
                    accessibility: Bool, secureInput: Bool, running: Bool, frontIsBlurt: Bool = false) {
            self.enabled = enabled; self.arm = arm; self.now = now; self.changeCount = changeCount
            self.frontBundle = frontBundle; self.accessibility = accessibility; self.secureInput = secureInput; self.running = running
            self.frontIsBlurt = frontIsBlurt
        }
    }

    /// The apps a ⌘V runs the sequence in: a known app of the chat class (not a rich app, a terminal or the Finder).
    public static func sequences(frontBundle: String?) -> Bool {
        frontBundle != nil && DropTargets.classify(bundleID: frontBundle) == .chat
    }

    public static func decide(_ i: Input) -> Decision {
        guard i.enabled else { return .pass("off") }
        guard let arm = i.arm else { return .pass("not_armed") }
        guard i.now < arm.until else { return .pass("expired") }
        guard i.changeCount == arm.changeCount else { return .pass("clipboard_changed") }
        guard !i.frontIsBlurt else { return .pass("blurt") }
        guard i.frontBundle != nil else { return .pass("no_app") }
        switch DropTargets.classify(bundleID: i.frontBundle) {
        case .rich: return .pass("rich_app")
        case .terminal: return .pass("terminal")
        case .finder: return .pass("finder")
        case .chat: break
        }
        guard CardPasteSequence.needsSequence(arm.steps) else { return .pass("one_thing") }
        guard i.accessibility else { return .pass("no_accessibility") }
        guard !i.secureInput else { return .pass("secure_input") }
        guard !i.running else { return .pass("running") }
        return .sequence
    }
}

/// The sequence, step by step: put a step on the clipboard, ⌘V, wait until the app read it (or a timeout), the next;
/// after the last, give the clipboard back (the app waits a moment first: a slow reader still gets the last step).
/// Something else written to the clipboard meanwhile (the user copied) stops it, and nothing is put back over that.
public struct PasteRun: Equatable {
    public enum Action: Equatable {
        case put(PasteStep)
        case paste
        /// the clipboard as it was before the sequence (the card copy)
        case restore
    }
    public enum Event: Equatable {
        /// the app asked for the step's data
        case read
        /// it didn't, in time
        case timeout
        /// the clipboard was written by someone else
        case clobbered
        /// the restore delay passed
        case restoreDue
    }
    public enum State: Equatable {
        case idle
        case pasting(Int)
        case restoring
        case done
        case aborted
    }

    public let steps: [PasteStep]
    public private(set) var state: State = .idle
    /// steps the app read / steps whose read we didn't see
    public private(set) var read = 0
    public private(set) var unconfirmed = 0

    public init(steps: [PasteStep]) { self.steps = steps }

    public mutating func start() -> [Action] {
        guard state == .idle, let first = steps.first else { state = .done; return [] }
        state = .pasting(0)
        return [.put(first), .paste]
    }

    public mutating func handle(_ e: Event) -> [Action] {
        switch (state, e) {
        case (.pasting, .clobbered), (.restoring, .clobbered):
            state = .aborted
            return []
        case (.pasting(let i), .read), (.pasting(let i), .timeout):
            if e == .read { read += 1 } else { unconfirmed += 1 }
            guard i + 1 < steps.count else { state = .restoring; return [] }
            state = .pasting(i + 1)
            return [.put(steps[i + 1]), .paste]
        case (.restoring, .restoreDue):
            state = .done
            return [.restore]
        default:
            return []
        }
    }

    public var finished: Bool { state == .done || state == .aborted }
}

/// After a card was dropped into another app: whether Blurt pastes its note in after the picture.
public enum DragFollowUp {
    public enum Plan: Equatable {
        case none(String)
        /// the note, pasted as one paste after the dropped picture
        case pasteNote(String)
    }

    /// `delivered`: the class whose payload the app got (nil: not sure — it may have read another class's layout, the
    /// rich one with the note in it, so no second note); `enabled`: record.smart_paste; `accessibility`: a posted ⌘V
    /// would arrive.
    public static func plan(delivered: DropClass?, card: CardPasteboard.Card, enabled: Bool, accessibility: Bool, secureInput: Bool) -> Plan {
        guard let d = delivered else { return .none("not_sure") }
        guard d == .chat else { return .none(d == .rich ? "rich_app" : "other_app") }
        guard card.image != nil, let note = CardNote.clean(card.note) else { return .none("nothing_more") }
        guard enabled else { return .none("off") }
        guard accessibility else { return .none("no_accessibility") }
        guard !secureInput else { return .none("secure_input") }
        return .pasteNote(note)
    }
}

/// A key the follow-up presses before its paste, to put the caret after the dropped picture.
public enum CaretKey: String, Equatable {
    /// ⌘↓: the end of the composer
    case end
    /// →: a selection (the dropped picture, left selected) collapses to its end
    case right
}

/// Where the note's paste after a drop goes — the composer that received the drop, or nowhere. The app came to the
/// front at the window it was dropped on; then Accessibility says what has the focus (a composer under or near the
/// drop point got it if it hadn't: ComposerPick). Paste only when:
///  • the app it was dropped on is in front, and not Blurt; no secure input, no password field;
///  • the focus is in that window (when Accessibility can tell);
///  • web content and Qt: then always, like dictation (their editors often aren't an Accessibility text role, and
///    many pages route a paste to their composer) — the paste counts only if the app read the note;
///  • a native app we don't know: only into an editable text focus (an image editor would make a paste a text layer).
/// The caret: Qt → ⌘↓ (its dropped picture is selected, and Qt's Accessibility can't say); else a selection → →
/// (collapse it after the picture: a paste over it would replace the picture); a caret → nothing (the picture is an
/// attachment, the caret is where the user left it); can't tell → ⌘↓ (in a composer that is the end of what is typed;
/// in a long document the end of the document — the note lands late rather than over the picture).
public enum FollowUpFocus {
    public struct Facts: Equatable {
        public var kind: ComposerKind
        public var frontIsTarget: Bool
        public var frontIsBlurt: Bool
        public var secureInput: Bool
        public var focusSecure: Bool
        /// the focus is in the window the card was dropped on (nil: can't tell)
        public var sameWindow: Bool?
        /// the focus is editable text (nil: Accessibility couldn't say)
        public var editable: Bool?
        /// the focused text's selection length (nil: unknown)
        public var selection: Int?
        public init(kind: ComposerKind, frontIsTarget: Bool = true, frontIsBlurt: Bool = false, secureInput: Bool = false,
                    focusSecure: Bool = false, sameWindow: Bool? = nil, editable: Bool? = nil, selection: Int? = nil) {
            self.kind = kind; self.frontIsTarget = frontIsTarget; self.frontIsBlurt = frontIsBlurt; self.secureInput = secureInput
            self.focusSecure = focusSecure; self.sameWindow = sameWindow; self.editable = editable; self.selection = selection
        }
    }

    public enum Decision: Equatable {
        case paste(caret: [CaretKey])
        case skip(String)
    }

    public static func decide(_ f: Facts) -> Decision {
        if f.frontIsBlurt { return .skip("blurt_in_front") }
        guard f.frontIsTarget else { return .skip("not_front") }
        if f.secureInput || f.focusSecure { return .skip("secure_input") }
        if f.sameWindow == false { return .skip("other_window") }
        switch f.kind {
        case .qt: return .paste(caret: [.end])
        case .native where f.editable != true: return .skip("not_text")
        case .native, .web: break
        }
        guard let n = f.selection else { return .paste(caret: [.end]) }
        return .paste(caret: n > 0 ? [.right] : [])
    }
}
