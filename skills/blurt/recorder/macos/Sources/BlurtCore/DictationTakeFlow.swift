// What happens to a dictation take between the stop and the text being in (docs/design/dictation.md §Takes in
// flight): the pure rules, unit-tested (Tests/BlurtCoreTests/DictationTakeFlowTests). The app (Capture/Dictation/
// Dictation.swift) acts on them.
//
//   DictationPasteQueue   a tap while the last take is still on its way starts the next one at once; the takes are
//                         pasted in the order they were said, one at a time, whichever finishes first
//   DictationRunaway      a hands-free take nobody stopped: a reminder after 20 s without speech, a countdown on the
//                         ear from 4:30, and the 5-minute limit said out loud when it ends the take
//   DictationTips         one quiet line after a take, for the first few: double-tap to send (chat apps), ⇧ for a
//                         list, ⌥⇧L for another style — each until it was shown enough or the user used it
//   DictationASRFailure   why a take's words couldn't be recognised, in the user's terms (no model, too slow, failed)
import Foundation

/// The takes that stopped and wait for their text, in the order they were said. Each is pasted only once the one
/// before it is in (or gone): two quick takes never swap places, and only one paste runs at a time.
public struct DictationPasteQueue<ID: Hashable> {
    private var order: [ID] = []
    private var ready: Set<ID> = []
    /// the take being pasted now
    public private(set) var delivering: ID?

    public init() {}

    public var isEmpty: Bool { order.isEmpty }
    public var count: Int { order.count }
    public var ids: [ID] { order }
    /// the take said last (a double tap's Return goes after it)
    public var last: ID? { order.last }
    public func contains(_ id: ID) -> Bool { order.contains(id) }

    /// A take stopped: it waits behind the ones before it.
    public mutating func add(_ id: ID) { if !order.contains(id) { order.append(id) } }

    /// Its text is in: it is pasted as soon as it is its turn.
    public mutating func markReady(_ id: ID) { if order.contains(id) { ready.insert(id) } }

    /// Out of the line without a paste (cancelled, nothing heard, recognition failed).
    public mutating func drop(_ id: ID) {
        order.removeAll { $0 == id }
        ready.remove(id)
        if delivering == id { delivering = nil }
    }

    /// The take to paste now — the first in line, its text in, nothing else being pasted — marked as being pasted;
    /// nil when it isn't time for one.
    public mutating func next() -> ID? {
        guard delivering == nil, let head = order.first, ready.contains(head) else { return nil }
        delivering = head
        return head
    }

    /// Its paste finished: the next one may go.
    public mutating func delivered(_ id: ID) { drop(id) }
}

/// A hands-free take that goes on without anyone talking — started by mistake, or the stop tap missed. While it listens
/// the app feeds it the take's time and whether speech is heard; it says when to remind and when to warn.
public struct DictationRunaway {
    /// dictation stops by itself here (seconds)
    public static let limit = 300.0
    /// the ear counts down from here
    public static let countdownFrom = 270.0
    /// this long without speech: "Still listening"
    public static let quietAfter = 20.0

    public enum Notice: Equatable {
        /// 20 s without speech: still listening · Fn to finish · Esc to cancel
        case stillListening
        /// 4:30: the countdown starts on the ear
        case endsSoon
    }

    private var lastSpeech = 0.0
    private var reminded = false
    private var warned = false

    public init() {}

    /// Each stretch of audio: `elapsed` (s), whether speech is heard now, and whether the take is hands-free (push-to-talk
    /// ends when the key comes up: no reminder). One notice at most per quiet stretch, one warning per take.
    public mutating func feed(elapsed: Double, speaking: Bool, handsFree: Bool) -> Notice? {
        if speaking {
            lastSpeech = elapsed
            reminded = false
        }
        if elapsed >= DictationRunaway.countdownFrom, !warned {
            warned = true
            return .endsSoon
        }
        if handsFree, !reminded, elapsed - lastSpeech >= DictationRunaway.quietAfter {
            reminded = true
            return .stillListening
        }
        return nil
    }

    /// The right ear's clock: the time so far, then — from 4:30 — the time left, with a minus ("−0:29").
    public static func clock(elapsed: Double) -> (text: String, countdown: Bool) {
        func mmss(_ t: Int) -> String { String(format: "%d:%02d", t / 60, t % 60) }
        guard elapsed >= countdownFrom else { return (mmss(Int(elapsed)), false) }
        return ("\u{2212}" + mmss(Int(ceil(max(0, limit - elapsed)))), true)
    }
}

/// The quiet line after a take, for the first few (record.dictation.tips counts each one shown).
public enum DictationTip: String, CaseIterable {
    /// "Double-tap Fn to send" — chat apps, the first five takes there
    case send
    /// "Press ⇧ while you talk for a list"
    case list
    /// "⌥⇧L tries another style"
    case reformat

    /// how many times each is shown at most
    public var times: Int { self == .send ? 5 : 1 }

    /// The tip for a take that just went in, or nil. `chat`: it went into a chat app; `sendOn`: double-tap to send is
    /// on; `sent`: this take was sent already (the user knows); `shown`: how often each was shown (a tip the user has
    /// used counts as shown out).
    public static func next(chat: Bool, sendOn: Bool, sent: Bool, shown: [String: Int]) -> DictationTip? {
        func left(_ t: DictationTip) -> Bool { (shown[t.rawValue] ?? 0) < t.times }
        if chat {
            return sendOn && !sent && left(.send) ? .send : nil
        }
        // the other two start after the first take (that one is about getting the words in at all)
        guard shown["takes"] ?? 0 >= 1 else { return nil }
        return [.list, .reformat].first(where: left)
    }
}

/// Why a take's words couldn't be recognised (the speech model's error code, or the call timing out).
public enum DictationASRFailure: Equatable {
    /// no speech model on this Mac (transcribe.py's model_missing): download one
    case noModel
    /// the model didn't answer in time
    case timedOut
    /// anything else (the code, for the history)
    case failed(String)

    public init(code: String?) {
        switch code {
        case "model_missing"?: self = .noModel
        case "timeout"?: self = .timedOut
        default: self = .failed(code ?? "error")
        }
    }

    /// For the history's reason ("asr_failed:model_missing").
    public var code: String {
        switch self {
        case .noModel: return "model_missing"
        case .timedOut: return "timeout"
        case .failed(let c): return c
        }
    }

    /// How long a speech-server call may take for this much audio: a model load (cold, from disk) plus 1.5× the
    /// audio — a piece of 20 s gets 45 s, not a flat minute, and a hung server is given up on in proportion.
    public static func serverTimeout(audioSeconds: Double) -> Double { 15 + 1.5 * max(0, audioSeconds) }
}
