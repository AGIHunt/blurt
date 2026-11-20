// Where a running model download is said (docs/design/desktop-app.md §2.2 "Models"), its pure parts — the app side
// is BlurtApp/App/ModelDownloads.swift (the island), Onboarding.swift (the assistant's line), MainWindow/HomePage.swift
// (Home's Dictation row). Nothing downloads unasked (the founder, 2026-11-21): the setup assistant offers this Mac's
// recogniser with its size and the free space, and once a download runs it is said wherever the user is — with the
// same words and numbers ("Downloading speech models · 1.2 of 2.5 GB") and a Stop.
// Unit-tested in Tests/BlurtCoreTests/ModelDownloadNoticeTests.
//
//   free space  before any model download (the assistant, Settings, Home, the dictation key, a resume at launch):
//               what is still to fetch plus 2 GB must be free, else it doesn't start and says "4.5 GB needed,
//               3.1 GB free · Show Storage"; a setup that hit a full disk anyway (`disk_full`, ENOSPC) says the same
//   island      a batch nobody asked for (`install`, no longer started by the app) says once as it starts
//               "Downloading speech models in the background (2.5 GB) · Stop"; nothing more until it is in ("ready ·
//               tap Fn") or stopped on an error — closing the assistant mid-download no longer repeats it
//   assistant   every step but the models step (its own bar) and a Try-it step whose notice shows the recogniser's bar:
//               one quiet line under the step, "… · 1.2 of 5.9 GB · Stop"; what it is for ("more accurate, knows your
//               words; works now") only while macOS's recogniser really dictates on this Mac
//   Home        Dictation's row, while dictation works: the download with Stop instead of what the capability does;
//               after a Stop (or never fetched) one offer at a time, each with its own size: "Download a more accurate
//               speech model · 2.5 GB" while this Mac's recommended recogniser is missing and dictation picks its model
//               by itself, then — the recogniser in — "Download the polish model · 3.4 GB" while this Mac's polish
//               model is missing and polish picks its model by itself with no cloud key (the setup assistant brings
//               only the recogniser: the founder, 2026-11-21); a download that broke off: the assistant's "Model
//               download interrupted · Try Again"
import Foundation

public enum ModelDownloadNotice {
    // MARK: free space

    /// Room left for everything else once the models are in (the founder, 2026-11-21: remaining + 2 GB).
    public static let headroomMB: Double = 2048

    /// The download of `remainingMB` doesn't fit in `freeBytes`: what it needs (with the headroom) and what is free, in
    /// MB. nil: it fits, nothing is left to fetch, or the free space couldn't be read (never a refusal on a guess).
    public static func diskShort(remainingMB: Double, freeBytes: Int64?) -> (needMB: Double, freeMB: Double)? {
        guard let f = freeBytes, remainingMB >= 1 else { return nil }
        let free = Double(max(f, 0)) / 1_048_576, need = remainingMB + headroomMB
        return need > free ? (need, free) : nil
    }

    /// A setup's failure that is a full disk: the scripts' `disk_full`, or ENOSPC in what they printed.
    public static func diskFull(code: String?, error: String) -> Bool {
        code == "disk_full" || error.contains("No space left on device") || error.contains("[Errno 28]")
    }

    // MARK: the island

    /// The batch's start goes up on the island (once: it says the size and Stop) — only for the batch the user didn't
    /// ask for. One asked for on a surface (the models step, Settings, the dictation key) shows its progress there.
    public static func announcesStart(via: String) -> Bool { via == "install" }

    /// The assistant closed while the batch runs: "the models carry on" — unless its start already said so.
    public static func saysCarryOn(startSaid: Bool) -> Bool { !startSaid }

    // MARK: the setup assistant

    /// The quiet line under the step: while a download runs, except where the step already shows a bar for it (the
    /// models step; Try it while the recogniser itself is still coming).
    public static func assistantLine(downloading: Bool, modelsStep: Bool, tryShowsBar: Bool) -> Bool {
        downloading && !modelsStep && !tryShowsBar
    }

    /// "Once it's in, dictation is more accurate and knows your words; it works now": only while dictation works now
    /// on macOS's own recogniser (its language files in) — never a promise on a Mac that is waiting for the download.
    public static func saysPurpose(systemReady: Bool, dictationReady: Bool?) -> Bool {
        systemReady && dictationReady != false
    }

    // MARK: Home

    /// Dictation's line on Home while dictation itself can run (nothing stands in its way: SpeechSetup.menuRow nil).
    public enum HomeLine: Equatable {
        /// what the capability does
        case usual
        /// "Downloading more accurate speech models · 1.2 of 5.9 GB · Stop" (the batch's one bar)
        case downloading(done: Double, total: Double)
        /// "Unpacking speech models… · Stop"
        case unpacking
        /// "Model download interrupted · Try Again"
        case interrupted
        /// "Download a more accurate speech model · 2.5 GB" (the recogniser alone)
        case offer(mb: Double)
        /// "Download the polish model · 3.4 GB" (once the recogniser is in)
        case offerPolish(mb: Double)
    }

    /// `ready`: dictation has its recogniser. `automatic`: dictation picks its model by itself (nothing chosen by
    /// hand — one chosen by hand is the user's call, not an upsell). `betterMissing`: this Mac's recommended
    /// recogniser isn't here; `missingMB`: its size. `polishMB`: this Mac's polish model, when it is missing and
    /// polish picks by itself with no cloud key (0: nothing to offer). `failed`: the last download of what is
    /// offered broke off (in memory: a relaunch offers it again).
    public static func home(ready: Bool?, downloading: Bool, unpacking: Bool, progress: (done: Double, total: Double),
                            automatic: Bool, betterMissing: Bool, missingMB: Double, polishMB: Double = 0,
                            failed: Bool) -> HomeLine {
        guard ready == true else { return .usual }       // dictation waits for its model: the row's own words
        if downloading { return unpacking ? .unpacking : .downloading(done: progress.done, total: progress.total) }
        if automatic, betterMissing, missingMB >= 1 { return failed ? .interrupted : .offer(mb: missingMB) }
        if polishMB >= 1 { return failed ? .interrupted : .offerPolish(mb: polishMB) }
        return .usual
    }
}

extension ModelDownloadQueue {
    /// The queue as it stands once the user's Stop is done — written to model-downloads.json the moment Stop is
    /// pressed, so a quit or a crash before the setup has ended can't bring back at the next launch what the user
    /// stopped. (A quit or a crash without a Stop leaves the file as it is: the next launch carries on.)
    public func afterStop(_ stop: Stop, running: String?) -> ModelDownloadQueue {
        var q = self
        switch stop {
        case .none: break
        case .one(let id): q.remove(id)
        case .all(let waiting): waiting.union(running.map { [$0] } ?? []).forEach { q.remove($0) }
        }
        return q
    }
}
