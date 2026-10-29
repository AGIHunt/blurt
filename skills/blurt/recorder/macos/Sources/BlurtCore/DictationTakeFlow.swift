// What happens to a dictation take between the stop and the text being in (docs/design/dictation.md §Takes in
// flight): the pure rules, unit-tested (Tests/BlurtCoreTests/DictationTakeFlowTests). The app (Capture/Dictation/
// Dictation.swift) acts on them.
//
//   DictationPasteQueue   a tap while the last take is still on its way starts the next one at once; the takes are
//                         pasted in the order they were said, one at a time, whichever finishes first
//   DictationRunaway      a hands-free take nobody stopped: a reminder after 20 s without speech, a countdown on the
//                         ear from 4:30, and the 5-minute limit said out loud when it ends the take
//   DictationTips         one quiet line after a take, for the first few: double-tap to send (chat apps, up to 5),
//                         ⇧ for a list, ⌥⇧L for another style (from the first take elsewhere, a different one each
//                         time) — each until it was shown enough or the user used it
//   DictationASRFailure   why a take's words couldn't be recognised, in the user's terms (no model, too slow, failed)
//   DictationSpeechModels what `transcribe.py dictation-models` says: can a take run with nothing downloaded, what a
//                         download would have to bring, whether a weaker model ran
//   DictationReformatAfterPaste  ⌥⇧L while a take is on its way: bound to that take, never run for another
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
        // elsewhere: from the first take, one each — ⇧ for a list, then ⌥⇧L (a chat app's takes teach sending first)
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

    /// How long a speech-server call may take for this much audio at most: a model load (cold, from disk) plus 1.5×
    /// the audio — a piece of 20 s gets 45 s. A hung server is told well before that (`hung`).
    public static func serverTimeout(audioSeconds: Double) -> Double { 15 + 1.5 * max(0, audioSeconds) }

    /// A request in flight is given up on as hung: no answer after `minWait` s while the server's CPU time hasn't
    /// moved for `stalledFor` s (v0.9 dogfood: a stopped server held a 3 s take 21.6 s, only dots on the island). The
    /// idle CPU decides, whatever the audio's length: a server that works (loading, decoding a long take, another
    /// request first) keeps its CPU moving — ~0.5 s of CPU per 0.5 s while decoding a 4-minute file — and is waited
    /// for, up to serverTimeout. (Waiting half the audio as well held a stopped server's 20 s take 9.5 s; review.)
    public static let stalledFor = 2.0
    public static let minWait = 3.0
    public static func hung(waited: Double, cpuIdle: Double) -> Bool {
        waited >= minWait && cpuIdle >= stalledFor
    }
}

/// `transcribe.py dictation-models` as the key-down needs it. A dictation never downloads anything, so the key listens
/// only when a take can run as things are: the selected model (local and on this Mac, or a cloud one with its key) and
/// the VAD every take goes through (`ready`). A model outside the Settings rows (a cloud one, the voice-note pick) is
/// judged by itself, never by being absent from them.
public struct DictationSpeechModels: Equatable {
    public var selected: String
    public var ready: Bool
    public var selectedInstalled: Bool
    public var recommended: String
    public var recommendedInstalled: Bool
    /// record.dictation.asr_model (nil: automatic), and whether it is on this Mac
    public var configured: String?
    public var configuredInstalled: Bool
    /// what a download would bring: "silero-vad" and/or the selected model's id
    public var missing: [String]
    /// the selected model is a cloud service (live text then comes from macOS's recogniser; no hearing again)
    public var selectedCloud = false

    public static let vad = "silero-vad"

    public init(selected: String, ready: Bool, selectedInstalled: Bool, recommended: String, recommendedInstalled: Bool,
                configured: String? = nil, configuredInstalled: Bool = false, missing: [String] = []) {
        self.selected = selected; self.ready = ready; self.selectedInstalled = selectedInstalled
        self.recommended = recommended; self.recommendedInstalled = recommendedInstalled
        self.configured = configured; self.configuredInstalled = configuredInstalled; self.missing = missing
    }

    /// The CLI's answer (or Settings' reload of it). An older answer without `ready` falls back to the rows.
    public init?(_ r: [String: Any]) {
        guard let selected = r["selected"] as? String else { return nil }
        let rows = r["models"] as? [[String: Any]] ?? []
        func row(_ id: String) -> Bool { rows.contains { $0["id"] as? String == id && $0["installed"] as? Bool == true } }
        let rec = r["recommended"] as? String ?? selected
        let selIn = r["selected_installed"] as? Bool ?? row(selected)
        let configured = r["configured"] as? String
        self.init(selected: selected, ready: r["ready"] as? Bool ?? selIn, selectedInstalled: selIn, recommended: rec,
                  recommendedInstalled: row(rec), configured: configured,
                  configuredInstalled: r["configured_installed"] as? Bool ?? configured.map(row) ?? false,
                  missing: r["missing"] as? [String] ?? (selIn ? [] : [selected]))
        selectedCloud = r["selected_cloud"] as? Bool ?? false
    }

    /// Only the VAD is missing (the model is there): the island says that, not "no speech model".
    public var onlyVADMissing: Bool { !ready && selectedInstalled && missing == [DictationSpeechModels.vad] }

    /// What "Download…" gets: the configured model when that is what's missing, else the recommended one; with the
    /// model there and only the VAD missing, the selected model's setup (which brings the VAD) without choosing it.
    public var toGet: (id: String, choose: Bool)? {
        if ready { return recommendedInstalled ? nil : (recommended, true) }
        if selectedInstalled { return (selected, false) }
        if let c = configured, !configuredInstalled { return (c, true) }
        return (recommended, true)
    }

    /// The once-a-day "a weaker model ran" notice after a take recognised by `used`: only when the user didn't pick
    /// that model themselves (a configured model on this Mac is their choice, not a fallback).
    public func weakerModelRan(_ used: String?) -> Bool {
        guard let used = used, !recommendedInstalled, used != recommended else { return false }
        if let c = configured, configuredInstalled, c == used { return false }
        return true
    }
}

/// ⌥⇧L pressed while a take is still on its way (being transcribed, polished or pasted): it means the take said
/// last, once it is in. Bound to that take's id: a take cancelled, failed or empty takes the request with it, and it
/// never runs for a later one.
public struct DictationReformatAfterPaste<ID: Hashable> {
    public private(set) var pending: (id: ID, via: String)?

    public init() {}

    /// The take it is for (the queue's last), or nil when nothing is on its way.
    @discardableResult
    public mutating func request(last: ID?, via: String) -> ID? {
        guard let id = last else { pending = nil; return nil }
        pending = (id, via)
        return id
    }

    /// `id` was pasted: the request's `via` when it was for this take (it is then used up).
    public mutating func delivered(_ id: ID) -> String? {
        guard let p = pending, p.id == id else { return nil }
        pending = nil
        return p.via
    }

    /// `id` left without a paste (cancelled, failed, nothing heard): a request for it goes too.
    public mutating func forget(_ id: ID) { if pending?.id == id { pending = nil } }
}

/// Dictation gave up on a speech server that didn't answer: still given up only while that same server (by pid) is
/// the one running — a fresh server is used at once.
/// What the island says once a take is in (or on the clipboard): one line, never two that replace each other in the
/// same frame (v0.9 dogfood: a send asked for, the app changed meanwhile — "Copied, ⌘V" showed, "not sent" never did).
public enum DictationDeliveredLine: Equatable {
    /// copied — `appChanged`: the user moved to another app meanwhile
    case copied(appChanged: Bool)
    /// a double tap asked to send, the text is only on the clipboard: Return was not pressed
    case copiedNotSent
    /// a double tap asked to send and nothing went in (why: not_pasted)
    case notSent
    /// pasted into a focus Accessibility couldn't confirm as text (WeChat & co.: no focused element could be read):
    /// "Copy again"
    case pastedUnsure
    /// pasted, but Accessibility read the focus and it isn't a text field (the desktop, a web page with no field
    /// focused, a list): the text most likely went nowhere, so the island keeps it, with Copy, until it is copied,
    /// closed or the next take starts
    case noField
    /// a password field had the focus: not typed, not copied — "Copy" is the user's call
    case held
    case none

    /// `result`: pasted | copied | held | none; `sendAsked`: a double tap queued Return for this take; `noField`: the
    /// focus was read and isn't a text field.
    public static func line(result: String, sendAsked: Bool, confirmed: Bool, appChanged: Bool,
                            noField: Bool = false) -> DictationDeliveredLine {
        switch result {
        case "held": return .held
        case "copied": return sendAsked ? .copiedNotSent : .copied(appChanged: appChanged)
        case "pasted": return confirmed ? .none : noField ? .noField : .pastedUnsure
        default: return sendAsked ? .notSent : .none
        }
    }

    /// The line's string key (Dictation.strings) when the text was left on the clipboard: copied, or copied and not
    /// sent — one line that says both. nil for the other lines (they have their own button or wording).
    public var copyKey: String? {
        switch self {
        case .copiedNotSent: return "dictation.toast.copied.not_sent"
        case .copied(let changed): return changed ? "dictation.toast.copied_app" : "dictation.toast.copied"
        default: return nil
        }
    }

    /// A plain copy is done (the ok check, as every done line); "not sent" isn't.
    public var checked: Bool { if case .copied = self { return true }; return false }

    /// How long a copied line stays: longer when there is more to read (the app changed, or it wasn't sent).
    public var copySeconds: Double {
        switch self {
        case .copied(false): return 2.4
        default: return 4
        }
    }
}

/// The text the island keeps after a paste that found no field: the start of it, at most `limit` characters (three
/// lines of the island), cut at a word or after punctuation when one is near the end; Copy copies all of it.
public enum DictationKeptText {
    public static let limit = 80

    public static func preview(_ text: String, limit: Int = limit) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard t.count > limit else { return t }
        let head = String(t.prefix(limit))
        // a break in the last fifth: a space (Latin) or a mark (CJK punctuation, commas)
        let marks: Set<Character> = [" ", "，", "。", "、", "；", "：", "！", "？", ",", ".", ";", ":", "!", "?"]
        if let i = head.lastIndex(where: { marks.contains($0) }), head.distance(from: i, to: head.endIndex) <= limit / 5 {
            return String(head[..<i]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return head + "…"
    }
}

public enum DictationServerGiveUp {
    public static func stillGivenUp(givenUp: Int32?, now: Int32?) -> Bool {
        guard let g = givenUp else { return true }      // no pid known: the minute holds
        return now == nil || now == g
    }
}

/// When the listening aura under the island comes up for a take: at once for push-to-talk, after the double-tap
/// window for a tap-started take when a double tap sends (that first tap may turn out to be a send's).
public enum DictationGlow {
    public static func delay(pushToTalk: Bool, doubleTapSend: Bool, window: Double) -> Double {
        pushToTalk || !doubleTapSend ? 0 : window
    }
}
