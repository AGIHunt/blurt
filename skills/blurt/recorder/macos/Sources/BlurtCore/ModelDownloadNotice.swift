// Where a running model download is said (docs/design/desktop-app.md §2.2 "Models"), its pure parts — the app side
// is BlurtApp/App/ModelDownloads.swift (the island), Onboarding.swift (the assistant's line), MainWindow/HomePage.swift
// (Home's Dictation row). The first run starts this Mac's recommended models in the background without asking
// (docs/design/first-minute-speech.md: macOS's recogniser dictates meanwhile), so wherever the user is, it is said —
// with the same words and numbers ("Downloading speech models · 1.2 of 5.9 GB") and a Stop — never asked.
// Unit-tested in Tests/BlurtCoreTests/ModelDownloadNoticeTests.
//
//   island      a batch nobody asked for (the first run's: `install`) says once as it starts "Downloading speech
//               models in the background (5.9 GB) · Stop"; nothing more until it is in ("ready · tap Fn") or stopped
//               on an error — closing the assistant mid-download no longer repeats it
//   assistant   every step but the models step (its own bar) and a Try-it step whose notice shows the recogniser's bar:
//               one quiet line under the step, "… · 1.2 of 5.9 GB · Stop"; what it is for ("more accurate, knows your
//               words; works now") only while macOS's recogniser really dictates on this Mac
//   Home        Dictation's row, while dictation works: the download with Stop instead of what the capability does;
//               after a Stop (or never fetched) the offer "Download more accurate speech models · 5.9 GB" while this
//               Mac's recommended recogniser is missing and dictation picks its model by itself; a download that broke
//               off: the assistant's "Model download interrupted · Try Again"
import Foundation

public enum ModelDownloadNotice {
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
        /// "Download more accurate speech models · 5.9 GB"
        case offer(mb: Double)
    }

    /// `ready`: dictation has its recogniser. `automatic`: dictation picks its model by itself (nothing chosen by
    /// hand — one chosen by hand is the user's call, not an upsell). `betterMissing`: this Mac's recommended
    /// recogniser isn't here; `missingMB`: what the recommended set still has to fetch. `failed`: its last download
    /// broke off (in memory: a relaunch offers it again).
    public static func home(ready: Bool?, downloading: Bool, unpacking: Bool, progress: (done: Double, total: Double),
                            automatic: Bool, betterMissing: Bool, missingMB: Double, failed: Bool) -> HomeLine {
        guard ready == true else { return .usual }       // dictation waits for its model: the row's own words
        if downloading { return unpacking ? .unpacking : .downloading(done: progress.done, total: progress.total) }
        guard automatic, betterMissing, missingMB >= 1 else { return .usual }
        return failed ? .interrupted : .offer(mb: missingMB)
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
