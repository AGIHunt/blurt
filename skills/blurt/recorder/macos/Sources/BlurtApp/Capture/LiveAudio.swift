// LiveAudio — the mic as <session>/live/audio.pcm (16 kHz mono s16le) for scripts/live.py, which transcribes and
// drafts items while the recording runs (docs/design/snap-and-live.md §4, file contracts).
//
// Only unpaused audio is written, and every buffer is placed by its pause-adjusted timestamp (gaps → silence,
// overlaps trimmed), so byte offset / 32000 == video time. Flushed about every 100 ms. When the take ends `stop` is
// created next to it; a discarded take removes live/. All calls come from the recorder's capture queue.

import AVFoundation
import BlurtCore
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
          case let skill = BlurtPaths.skillDir.path,       // also when config.json doesn't parse (Paths.skillDir)
          FileManager.default.fileExists(atPath: "\(skill)/scripts/live.py"), let uv = findExecutable("uv") else { return }
    let live = session.appendingPathComponent("live")
    guard FileManager.default.fileExists(atPath: live.path) else { return }   // no mic → no sidecar
    liveLaunched.insert(session.path)
    shell("\(shq(uv)) run -q \(shq("\(skill)/scripts/live.py")) run \(shq(session.path)) --watch-pid \(getpid())",
          cwd: session, log: session.appendingPathComponent("live.log")) { _ in }   // outside live/: survives a restart
}

/// After a saved take: a sidecar nobody consumes is just litter.
func cleanupLive(_ session: URL) {
    if !liveLaunched.contains(session.path) {
        try? FileManager.default.removeItem(at: session.appendingPathComponent("live"))
    }
    liveLaunched.remove(session.path)
}

/// Tests only — BLURT_TEST_MIC_WAV=<audio file> stands in for the microphone: the file plays in real time as 20 ms
/// buffers stamped with the host clock (like a real mic's) into Recorder.handleAudio, i.e. the same path to the mp4
/// audio track, the level meter and live/audio.pcm. It advances only while recording and unpaused (nobody talks
/// into a paused take), then sends silence. No microphone is opened.
final class TestMic {
    static let step = 960                     // 20 ms at 48 kHz
    static var wanted: URL? { ProcessInfo.processInfo.environment["BLURT_TEST_MIC_WAV"].map { URL(fileURLWithPath: $0) } }
    let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)!
    private var samples: [Int16] = []
    private var pos = 0
    private var next: CMTime?
    private var timer: DispatchSourceTimer?

    init?(url: URL) {
        guard let f = try? AVAudioFile(forReading: url), let conv = AVAudioConverter(from: f.processingFormat, to: fmt),
              let all = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
        try? f.read(into: all)
        let cap = AVAudioFrameCount(Double(all.frameLength) * 48000 / f.processingFormat.sampleRate) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var fed = false
        conv.convert(to: out, error: nil) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true; st.pointee = .haveData; return all
        }
        samples = Array(UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength)))
    }

    func start(_ rec: Recorder) {
        let t = DispatchSource.makeTimerSource(queue: rec.q)
        let dt = CMTime(value: CMTimeValue(TestMic.step), timescale: 48000)
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        t.setEventHandler { [weak self, weak rec] in
            guard let self = self, let rec = rec, rec.started, !rec.stopping else { return }
            let now = hostNow()
            var n = self.next ?? CMTimeSubtract(now, dt)
            while CMTimeCompare(CMTimeAdd(n, dt), now) <= 0 {
                if !rec.isPaused, let sb = self.buffer(at: n) { rec.handleAudio(sb) }
                n = CMTimeAdd(n, dt)
            }
            self.next = n
        }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func buffer(at pts: CMTime) -> CMSampleBuffer? {
        let count = TestMic.step
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: fmt.formatDescription, sampleCount: count, sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb) == noErr,
              let s = sb, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(count)
        let dst = pcm.int16ChannelData![0]
        for i in 0..<count { dst[i] = pos + i < samples.count ? samples[pos + i] : 0 }
        pos += count
        guard CMSampleBufferSetDataBufferFromAudioBufferList(s, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                                                             bufferList: pcm.audioBufferList) == noErr else { return nil }
        return s
    }
}
