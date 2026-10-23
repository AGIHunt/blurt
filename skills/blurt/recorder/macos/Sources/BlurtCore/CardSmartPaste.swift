// Picture *and* note into an app that takes one thing per paste or drop (v0.8.4). The report: in WeChat a card
// dragged in, or clicked (copied) and pasted with ⌘V, arrived as the picture alone — the note was lost — while the same
// rich item brought both into Feishu, Claude, Notes and our NSTextView / WKWebView stand-ins.
//
// What WeChat's bundle says (4.1.8, read-only `strings` over WeChat.app; nothing run, nothing pasted): WeChat 4 is a
// Qt 5 app, not AppKit. Its pasteboard goes through Qt's QMacPasteboardMime converters — public.tiff (the picture as
// application/x-qt-image), public.html and public.rtf (both → text/html), public.utf8-plain-text, public.file-url
// (text/uri-list) and com.trolltech.anymime.* (Qt's wrapper for any other MIME type). No public.png, no RTFD (only the
// docs editor in WeChatAppEx reads com.apple.flat-rtfd). Its own message copy is a QMimeData subclass
// (mmui::MessageMimeData / WechatCustomMimeData) whose format names are obfuscated in the binary — and a paste inside
// WeChat most likely hands that object over in-process, which no other app can reproduce. Its composer, offered a
// picture, takes the picture and nothing else. So no extra flavour on our rich item fixes it; Blurt pastes twice:
//
//   • smart paste (record.smart_paste, on): for 2 minutes after a card is copied (a click, a ⌘-click selection, Copy
//     All, Recently Taken), ⌘V in an app of the table below runs a short sequence instead of one paste: each picture,
//     then its note — img, text, img, text… — one single-flavour item on the clipboard per step, ⌘V each, the next
//     step once the app has read the last (or after a timeout); then the card copy goes back on the clipboard (and is
//     armed again), so ⌘V works again and every other app still gets the rich copy.
//   • a drag into one of these apps: the drop brings the picture; then Blurt types the note in after it — the app is
//     brought to the front at the window it was dropped on, the caret goes to the end (⌘↓), the note goes in as one
//     paste, and the clipboard comes back. Without Accessibility, with the setting off, or if it can't: the note goes
//     on the clipboard (the drag_copy_note safety net) and the toast says so.
// Both need Accessibility (the posted ⌘V). Test builds never post an event: the app routes each paste to a stand-in.

import Foundation

/// Apps whose composer takes one thing per paste or drop — a picture or text, never both (the picture wins).
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
    /// voice card after a note) goes in as one paste, a blank line between.
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
        return out
    }

    /// A sequence is only worth it with two things or more: a lone picture or a lone text pastes as it is.
    public static func needsSequence(_ steps: [PasteStep]) -> Bool { steps.count > 1 }
}

/// A copy armed for smart paste: the clipboard's change count right after it was written, and until when.
public struct SmartPasteArm: Equatable {
    /// how long after a copy ⌘V in a single-flavour app pastes picture and note (seconds)
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
        public init(enabled: Bool, arm: SmartPasteArm?, now: Double, changeCount: Int, frontBundle: String?,
                    accessibility: Bool, secureInput: Bool, running: Bool) {
            self.enabled = enabled; self.arm = arm; self.now = now; self.changeCount = changeCount
            self.frontBundle = frontBundle; self.accessibility = accessibility; self.secureInput = secureInput; self.running = running
        }
    }

    public static func decide(_ i: Input) -> Decision {
        guard i.enabled else { return .pass("off") }
        guard let arm = i.arm else { return .pass("not_armed") }
        guard i.now < arm.until else { return .pass("expired") }
        guard i.changeCount == arm.changeCount else { return .pass("clipboard_changed") }
        guard SingleFlavourApps.contains(i.frontBundle) else { return .pass("other_app") }
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

/// After a card was dropped into another app: whether Blurt types its note in after the picture.
public enum DragFollowUp {
    public enum Plan: Equatable {
        case none(String)
        /// the note, typed in as one paste after the dropped picture
        case typeNote(String)
    }

    /// `bundleID`: the app it landed in; `enabled`: record.smart_paste; `accessibility`: a posted ⌘V would arrive.
    public static func plan(bundleID: String?, card: CardPasteboard.Card, enabled: Bool, accessibility: Bool, secureInput: Bool) -> Plan {
        guard SingleFlavourApps.contains(bundleID) else { return .none("other_app") }
        guard card.image != nil, let note = CardNote.clean(card.note) else { return .none("nothing_more") }
        guard enabled else { return .none("off") }
        guard accessibility else { return .none("no_accessibility") }
        guard !secureInput else { return .none("secure_input") }
        return .typeNote(note)
    }
}
