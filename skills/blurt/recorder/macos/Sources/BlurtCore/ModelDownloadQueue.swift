// The app's one model download queue (docs/design/desktop-app.md §2.2 "Models"), its pure parts — the app side is
// BlurtApp/App/ModelDownloads.swift. Every surface that downloads a model goes through it: the setup assistant's
// "Download Recommended Models", Settings → Speech (dictation's models, the voice-note and recording models), and the
// dictation key's "no speech model yet · Download". Unit-tested in Tests/BlurtCoreTests/ModelDownloadQueueTests.
//
//   one at a time  the jobs run in the order they were asked for; a model already queued or running is never queued
//                  twice (asking again only adds "select it once it's in")
//   the batch      every job since the queue was last empty: one progress bar over all of them (ModelBundle.progress),
//                  "2.1 of 6.1 GB"; the batch ends when nothing is left to run
//   persistent     $BLURT_HOME/model-downloads.json while anything is left to run, so a quit, a relaunch or a crash
//                  carries on at the next launch (the scripts resume their partial files); removed when the batch ends
//                  or the user stops it
//   outcomes       exit 0 = in; Stop, SIGTERM (15) or `uv run` passing it on (143) = stopped, never "failed"
import Foundation

public struct ModelDownloadQueue: Codable, Equatable {
    public struct Job: Codable, Equatable {
        public var id: String
        public var kind: ModelBundle.Kind
        public var name: String
        public var sizeMB: Double
        /// once it is in, make it the one in use (dictation's record.dictation.asr_model; polish's `setup --use`)
        public var select: Bool

        public init(id: String, kind: ModelBundle.Kind, name: String, sizeMB: Double, select: Bool = false) {
            self.id = id; self.kind = kind; self.name = name; self.sizeMB = sizeMB; self.select = select
        }
        public var part: ModelBundle.Part { ModelBundle.Part(id: id, kind: kind, name: name, sizeMB: sizeMB, installed: false) }
    }

    /// the batch, in order
    public private(set) var jobs: [Job] = []
    /// the batch's jobs that are in
    public private(set) var finished: [String] = []
    /// when the batch started (epoch s)
    public private(set) var startedAt: Double = 0

    public init() {}

    /// What is still to run, in order (the one running first).
    public var pending: [Job] { jobs.filter { !finished.contains($0.id) } }
    /// Anything left to run.
    public var active: Bool { !pending.isEmpty }
    /// The job that runs now or next.
    public var next: Job? { pending.first }

    public func contains(_ id: String) -> Bool { pending.contains { $0.id == id } }

    /// Queues the jobs not already waiting or running (a finished one may be asked for again: a model removed since).
    /// Returns the ones added.
    @discardableResult
    public mutating func add(_ new: [Job], now: Double = Date().timeIntervalSince1970) -> [Job] {
        if !active { jobs = []; finished = []; startedAt = now }
        var added: [Job] = []
        for j in new {
            if let i = jobs.firstIndex(where: { $0.id == j.id }), !finished.contains(j.id) {
                if j.select { jobs[i].select = true }      // asked again, this time to use it
                continue
            }
            if let i = jobs.firstIndex(where: { $0.id == j.id }) { jobs.remove(at: i); finished.removeAll { $0 == j.id } }
            jobs.append(j)
            added.append(j)
        }
        return added
    }

    public mutating func finish(_ id: String) {
        if jobs.contains(where: { $0.id == id }), !finished.contains(id) { finished.append(id) }
        if !active { clear() }
    }

    /// Stop for one model: it leaves the batch (its share of the bar goes too).
    public mutating func remove(_ id: String) {
        jobs.removeAll { $0.id == id && !finished.contains(id) }
        if !active { clear() }
    }

    /// Stop for everything, or a failure: the batch ends.
    public mutating func clear() { jobs = []; finished = []; startedAt = 0 }

    /// One bar over the batch: the finished jobs whole, the running one (`current`) by its "N/M MB" line.
    public func progress(current: String?, line: (done: Double, total: Double)?) -> (done: Double, total: Double) {
        ModelBundle.progress(jobs.map(\.part), finished: Set(finished), current: current, line: line)
    }

    /// What is left to download, in MB (the running job counted whole).
    public var remainingMB: Double { pending.reduce(0) { $0 + $1.sizeMB } }

    // MARK: how a download ended

    public enum Outcome: String, Equatable { case done, stopped, failed }

    /// A setup script's exit: 0 = in (even when Stop came too late); the user's Stop (`stopping`), SIGTERM (15) or
    /// `uv run` reporting it (128 + 15) = stopped; anything else failed.
    public static func outcome(status: Int32, stopping: Bool) -> Outcome {
        if status == 0 { return .done }
        if stopping || status == 15 || status == 143 { return .stopped }
        return .failed
    }

    // MARK: on disk

    public static var url: URL { BlurtPaths.home.appendingPathComponent("model-downloads.json") }

    /// Written while anything is left to run; removed otherwise.
    public func save(to u: URL = ModelDownloadQueue.url) {
        guard active, let d = try? JSONEncoder().encode(self) else { try? FileManager.default.removeItem(at: u); return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: u, options: .atomic)
    }

    /// The queue a quit, a relaunch or a crash left (nil: none, or nothing left in it).
    public static func load(from u: URL = ModelDownloadQueue.url) -> ModelDownloadQueue? {
        guard let d = try? Data(contentsOf: u), let q = try? JSONDecoder().decode(ModelDownloadQueue.self, from: d), q.active else { return nil }
        return q
    }
}
