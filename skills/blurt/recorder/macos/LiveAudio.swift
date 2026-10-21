// LiveAudio — the mic as <session>/live/audio.pcm (16 kHz mono s16le) for scripts/live.py, which transcribes and
// drafts items while the recording runs (docs/design/snap-and-live.md §4, file contracts).
//
// Only unpaused audio is written, and every buffer is placed by its pause-adjusted timestamp (gaps → silence,
// overlaps trimmed), so byte offset / 32000 == video time. Flushed about every 100 ms. When the take ends `stop` is
// created next to it; a discarded take removes live/. All calls come from the recorder's capture queue.

import AVFoundation
import CoreMedia
import Foundation

/// record.live in config.json (default on); the CLI recorder gets --no-live when record.py won't run live.py.
func liveAudioWanted() -> Bool { opts.live && (recordConfig()["live"] as? Bool ?? true) }

final class LiveAudio {
    static let rate = 16000.0
    let dir: URL
    private var fh: FileHandle?
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: LiveAudio.rate, channels: 1, interleaved: true)!
    private var pending = Data()
    private var written: Int64 = 0           // samples in the file + pending
    private var lastFlush = Date()
    private let tolerance: Int64 = 800       // 50 ms: correct timestamp drift beyond this (resampler latency is far less)

    init?(dir: URL) {
        self.dir = dir
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: dir.appendingPathComponent("stop"))
        let pcm = dir.appendingPathComponent("audio.pcm")
        try? fm.removeItem(at: pcm)            // a new file (new inode) tells live.py a new take began
        guard fm.createFile(atPath: pcm.path, contents: nil), let h = try? FileHandle(forWritingTo: pcm) else { return nil }
        fh = h
    }

    /// `at`: video time (s) of the buffer's first sample.
    func append(_ sb: CMSampleBuffer, at t: Double) {
        guard fh != nil, let desc = CMSampleBufferGetFormatDescription(sb) else { return }
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0 else { return }
        let fmt = AVAudioFormat(cmAudioFormatDescription: desc)
        if converter == nil || inFormat != fmt {   // first buffer, or the device changed
            converter = AVAudioConverter(from: fmt, to: outFormat)
            converter?.downmix = true
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            inFormat = fmt
        }
        guard let conv = converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return }
        inBuf.frameLength = AVAudioFrameCount(n)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n),
                                                           into: inBuf.mutableAudioBufferList) == noErr else { return }
        let cap = AVAudioFrameCount(Double(n) * LiveAudio.rate / fmt.sampleRate) + 256
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var given = false
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, st in
            if given { st.pointee = .noDataNow; return nil }
            given = true
            st.pointee = .haveData
            return inBuf
        }
        guard status != .error, let p = outBuf.int16ChannelData?[0] else { return }
        var data = Data(bytes: p, count: Int(outBuf.frameLength) * 2)

        // keep the file on the video timeline: silence for gaps (and before the first buffer), trim overlaps
        let target = Int64((max(0, t) * LiveAudio.rate).rounded())
        let drift = target - written
        if written == 0 && drift > 0 || drift > tolerance {
            pad(Int(drift))
        } else if drift < -tolerance {
            let cut = min(Int(-drift) * 2, data.count)
            data.removeFirst(cut)
        }
        pending.append(data)
        written += Int64(data.count / 2)
        if Date().timeIntervalSince(lastFlush) >= 0.1 { flush() }
    }

    private func pad(_ samples: Int) {
        guard samples > 0 else { return }
        pending.append(Data(count: samples * 2))
        written += Int64(samples)
    }

    private func flush() {
        guard let h = fh, !pending.isEmpty else { return }
        h.write(pending)
        pending.removeAll(keepingCapacity: true)
        lastFlush = Date()
    }

    /// The take is over: pad to the video's length (≤ 1 s), flush, close, create `stop`.
    func finish(duration: Double) {
        guard fh != nil else { return }
        let end = Int64((duration * LiveAudio.rate).rounded())
        if end > written { pad(Int(min(end - written, Int64(LiveAudio.rate)))) }
        flush()
        try? fh?.close()
        fh = nil
        FileManager.default.createFile(atPath: dir.appendingPathComponent("stop").path, contents: nil)
    }

    func discard() {
        try? fh?.close()
        fh = nil
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Menu-bar app: start live.py once per session when its recording begins (the CLI recorder is driven by record.py,
/// which does this itself). Through shell(), so it runs with the user's login env. Quietly does nothing without uv /
/// the skill; then the sidecar is removed when the take ends.
var liveLaunched: Set<String> = []

func launchLive(_ session: URL) {
    guard liveAudioWanted(), !liveLaunched.contains(session.path),
          let skill = readConfig()["skill_dir"] as? String,
          FileManager.default.fileExists(atPath: "\(skill)/scripts/live.py"), let uv = findExecutable("uv") else { return }
    let live = session.appendingPathComponent("live")
    guard FileManager.default.fileExists(atPath: live.path) else { return }   // no mic → no sidecar
    liveLaunched.insert(session.path)
    shell("\(shq(uv)) run -q \(shq("\(skill)/scripts/live.py")) run \(shq(session.path)) --watch-pid \(getpid())",
          cwd: session, log: live.appendingPathComponent("live.log")) { _ in }
}

/// After a saved take: a sidecar nobody consumes is just litter.
func cleanupLive(_ session: URL) {
    if !liveLaunched.contains(session.path) {
        try? FileManager.default.removeItem(at: session.appendingPathComponent("live"))
    }
    liveLaunched.remove(session.path)
}
