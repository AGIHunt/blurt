// A take recorded in pieces (v0.9-userfix): when the video writer fails mid-take the Recorder starts a new file and
// keeps recording (RecordingFailure.rollsOver) instead of ending the take there. At the end the pieces become one
// recording.mp4 again: each piece goes where it was on the take's timeline (TakeSegments.layout: what was lost while
// the writer was replaced stays a gap, so events.jsonl, the snaps and the live transcript keep their times), copied
// as they are (passthrough: no second encode). A piece that failed plays up to its last fragment and is used up to
// there. If the copy can't be made, the first piece stays recording.mp4 and the others stay next to it.
import AVFoundation
import Foundation

public enum TakeStitch {
    public struct Result: Equatable {
        /// seconds of the take on the new timeline, and the seconds lost between pieces
        public let duration: Double
        public let lost: Double
        public let pieces: Int
    }

    public enum Failure: Error { case nothingPlays, exportFailed(String) }

    /// `parts` (in order) placed at `starts` (seconds from the take's start) into `out` — written next to it first,
    /// then moved into place; the parts are removed once it is there.
    public static func stitch(_ parts: [URL], starts: [Double], into out: URL) async throws -> Result {
        var assets: [AVURLAsset] = [], lengths: [Double] = []
        for u in parts {
            let a = AVURLAsset(url: u)
            assets.append(a)
            let d = try? await a.load(.duration)
            lengths.append(d.map { $0.isNumeric ? $0.seconds : 0 } ?? 0)
        }
        let places = TakeSegments.layout(starts: starts, durations: lengths)
        guard !places.isEmpty else { throw Failure.nothingPlays }
        let comp = AVMutableComposition()
        var video: AVMutableCompositionTrack?
        var audio: [AVMutableCompositionTrack] = []
        let scale: CMTimeScale = 600
        for p in places {
            let a = assets[p.index]
            let want = CMTimeRange(start: .zero, duration: CMTime(seconds: p.length, preferredTimescale: scale))
            let at = CMTime(seconds: p.at, preferredTimescale: scale)
            if let t = try await a.loadTracks(withMediaType: .video).first {
                let have = try await t.load(.timeRange)
                let r = want.intersection(have)
                if r.duration > .zero {
                    if video == nil {
                        video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                        video?.preferredTransform = try await t.load(.preferredTransform)
                    }
                    try video?.insertTimeRange(r, of: t, at: CMTimeAdd(at, r.start))
                }
            }
            // the mic, then system audio (the order the Recorder adds them in): each keeps its own track
            for (i, t) in try await a.loadTracks(withMediaType: .audio).enumerated() {
                let have = try await t.load(.timeRange)
                let r = want.intersection(have)
                guard r.duration > .zero else { continue }
                while audio.count <= i {
                    guard let n = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { break }
                    audio.append(n)
                }
                if i < audio.count { try audio[i].insertTimeRange(r, of: t, at: CMTimeAdd(at, r.start)) }
            }
        }
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".stitching-" + out.lastPathComponent)
        try? FileManager.default.removeItem(at: tmp)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.exportFailed("no export session")
        }
        ex.outputURL = tmp
        ex.outputFileType = .mp4
        ex.shouldOptimizeForNetworkUse = false
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in ex.exportAsynchronously { c.resume() } }
        guard ex.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            let e = ex.error as NSError?
            throw Failure.exportFailed(e.map { "\($0.domain) \($0.code)" } ?? "status \(ex.status.rawValue)")
        }
        let fm = FileManager.default
        for u in parts where u != out { try? fm.removeItem(at: u) }
        try? fm.removeItem(at: out)
        try fm.moveItem(at: tmp, to: out)
        let last = places.last!
        return Result(duration: last.at + last.length, lost: TakeSegments.lost(places), pieces: places.count)
    }
}
