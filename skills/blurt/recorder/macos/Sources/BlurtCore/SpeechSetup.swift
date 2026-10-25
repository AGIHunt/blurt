// Where setting up speech stands, in one place (docs/design/desktop-app.md §2.2 "Models"): the setup assistant's
// models step and its Try-it step, the status menu's first row and the dictation key all read it, so an offline first
// run is told one thing everywhere. Unit-tested in Tests/BlurtCoreTests/SpeechSetupTests.
//
//   blocked   the speech tools (the scripts' Python packages, warmed up by `transcribe.py backends`) or the model
//             list couldn't be set up — offline, a proxy, a mirror that can't be reached. One sentence and one Try
//             Again (the warm-up, then the list, then the download), never two errors with two Retry buttons; the
//             step's Next becomes "Skip for Now"; Try it offers that same Try Again, never a Download button that
//             has nothing to download; the dictation key refuses before listening ("isn't set up yet · Set Up…").
//   failed    the tools are fine but a download stopped: its own sentence, Try Again and the small model alone.
//   cause     what the blocked sentence puts it down to (Cause): the network only when macOS says the Mac is offline
//             ("needs the internet once: connect, then Try Again"); online, the tools failed for another reason (a
//             proxy, a script error, an update half done): "couldn't set up its speech tools", no talk of connecting.
//   list      `dictation-models` that didn't answer (ListFailure): offline or an error — the dictation key refuses
//             before listening; a timeout (a cold `uv` sync after an update) is not a refusal: the take goes ahead.
//   retry     Try Again shows "Checking…" for at least `minimumCheck` (an offline retry fails in a blink and would look
//             like a button that does nothing), keeps the footer's Skip for Now, and a retry that still fails says
//             when it tried ("Tried again at 14:32: still offline").
//   network   a failure is retried by itself once the Mac comes back online (NetworkRetry: only on the change from
//             offline to online, never in a loop).
import Foundation

public enum SpeechSetup {
    /// The models step (the assistant's third).
    public enum Step: Equatable {
        /// uv (the scripts' runner) isn't there: Install uv
        case needsUV
        /// the tools warm up / the list is read
        case checking
        /// the tools or the list couldn't be set up: one sentence, one Try Again
        case blocked
        /// the set is downloading: one bar, Stop
        case downloading
        /// a download stopped on an error (the tools are fine): Try Again, or the small model alone
        case failed
        /// everything is on this Mac
        case ready
        /// the set is to download: Download Recommended Models
        case offer
    }

    /// `warm`: the warm-up's state (nil | "running" | "done" | "failed"). `listRead`: the model list could be read
    /// (meaningful once `loaded`). A warm-up that failed blocks even while a list read from an earlier run shows: the
    /// downloads need the same tools.
    public static func step(uv: Bool, warm: String?, loaded: Bool, listRead: Bool, downloading: Bool, failed: Bool,
                            ready: Bool) -> Step {
        guard uv else { return .needsUV }
        if downloading { return .downloading }
        if warm == "failed" || (loaded && !listRead) { return .blocked }
        guard loaded else { return .checking }
        if ready { return .ready }
        return failed ? .failed : .offer
    }

    /// The step's own action is still to do: the footer offers "Skip for Now" (plain) instead of the brand Next.
    /// `settled`: the user took the small model alone and it is in. `retrying`: Try Again runs ("Checking…") — the
    /// footer stays as it was rather than flashing to Next and back.
    public static func pending(_ s: Step, settled: Bool, retrying: Bool = false) -> Bool {
        if retrying { return true }
        switch s {
        case .needsUV, .blocked, .failed: return true
        case .offer: return !settled
        case .checking, .downloading, .ready: return false
        }
    }

    /// Try Again's "Checking…" lasts at least this long (seconds).
    public static let minimumCheck: TimeInterval = 1.0

    /// What a blocked setup is put down to.
    public enum Cause: Equatable {
        /// macOS says the Mac is offline: connect, then Try Again
        case offline
        /// online, and it still failed (a proxy, a script error): no talk of connecting
        case error
    }

    /// `online`: NetworkWatch's last answer (nil: none yet — not taken for offline).
    public static func cause(online: Bool?) -> Cause { online == false ? .offline : .error }

    /// Why `dictation-models` didn't answer.
    public enum ListFailure: String, Equatable {
        /// it ran out of time (a cold `uv` sync after an update): dictation still goes ahead
        case timeout
        /// the Mac is offline (the tools can't be fetched)
        case offline
        /// it failed while online (a script error, the skill missing): its detail goes to the log
        case error
    }

    public static func listFailure(timedOut: Bool, online: Bool?) -> ListFailure {
        timedOut ? .timeout : cause(online: online) == .offline ? .offline : .error
    }

    /// The dictation key refuses before listening ("isn't set up yet · Set Up…"): the tools can't run. Not on a
    /// timeout — the take goes ahead as it always did.
    public static func refusesDictation(_ f: ListFailure?) -> Bool { f == .offline || f == .error }

    /// The Try-it step, when dictation can't be tried yet and permissions are fine.
    public enum TryState: Equatable {
        /// dictation's recogniser is in: try it
        case works
        /// it is downloading: its own bar
        case downloading
        /// the tools or the list couldn't be set up: the same Try Again as the models step
        case blocked
        /// a model is missing and there is something to download: Download Recommended Models
        case download
    }

    /// `pendingDownloads`: the recommended set still has models to download (a Download button would do something).
    public static func tryState(dictationReady: Bool, dictationDownloading: Bool, step: Step, pendingDownloads: Bool) -> TryState {
        if dictationReady { return .works }
        if dictationDownloading { return .downloading }
        if step == .blocked || !pendingDownloads { return .blocked }
        return .download
    }

    /// The status menu's first row about dictation (nil: none), above Record. One row, the most urgent.
    public enum MenuRow: Equatable {
        /// the key isn't heard (permissions): Turn On Dictation…
        case turnOn
        /// the tools or the model list can't be read: Set Up Dictation… (the assistant's models step)
        case setUp
        /// no speech model on this Mac: Download Speech Model…
        case getModel
    }

    /// `ready`: dictation has its recogniser (nil = not read yet). `readable`: the model list could be read.
    /// `downloading`: a model download runs (its own row says how far — no second row).
    public static func menuRow(enabled: Bool, deferred: Bool, needsPermissions: Bool, ready: Bool?, readable: Bool,
                               downloading: Bool) -> MenuRow? {
        guard enabled, !deferred else { return nil }
        if needsPermissions { return .turnOn }
        if downloading { return nil }
        if !readable { return .setUp }
        return ready == false ? .getModel : nil
    }
}

/// Retry once the Mac is back online: fires only on the change from offline to online (NWPathMonitor's first answer
/// when it starts online is not a change), so a failure that isn't the network's never loops.
public struct NetworkRetry {
    private var online: Bool?
    public init() {}

    /// The path's new state. True: it just came back — retry what was waiting for it.
    public mutating func update(online now: Bool) -> Bool {
        defer { online = now }
        return online == false && now
    }
}
