import Accelerate
import AVFoundation
import AppKit
import CoreAudio
import CoreMotion
import SwiftUI

// Active sonar test bench. Plays a quiet band-limited periodic chirp (17.5-23 kHz) from both speakers, records the
// built-in mic sample-locked to it in one aggregate-device callback, shows live echo change, runs prompted test
// blocks from tests.json, and records the camera with host-clock timestamps so sonar and video line up afterwards.
// Everything stays on this Mac.

struct Trial: Codable { let label: String; let prompt: String; var secs: Double?; var rate: Double?; var beats: Int?; var wait: Bool? }
struct Block: Codable, Identifiable {
    let id: String, title: String, intro: String
    var rounds: Int?, lead: Double?, secs: Double?, rest: Double?, shuffle: Bool?
    let trials: [Trial]
}

let fs = 48000.0, period = 960, f0 = 17500.0, f1 = 23000.0
let rxShift = period/2           // right speaker: same probe half a period later, so echoes land in their own delay window
let rows = 140, cols = 500       // waterfall: 2 cm of extra path per row (2 samples), 10 s across
let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Blurt VSR Pilot/acoustic/sessions")

func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func device(_ uid: String) -> AudioObjectID {
    var a = addr(kAudioHardwarePropertyTranslateUIDToDevice), cf = uid as CFString, id = AudioObjectID(0), n = UInt32(4)
    _ = withUnsafePointer(to: &cf) { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), $0, &n, &id) }
    return id
}
func rateOf(_ id: AudioObjectID) -> Double { var a = addr(kAudioDevicePropertyNominalSampleRate), v = 0.0, n = UInt32(8); AudioObjectGetPropertyData(id, &a, 0, nil, &n, &v); return v }
func setRate(_ id: AudioObjectID, _ r: Double) {
    var a = addr(kAudioDevicePropertyNominalSampleRate), v = r
    AudioObjectSetPropertyData(id, &a, 0, nil, 8, &v)
    for _ in 0..<100 where rateOf(id) != r { usleep(20_000) }
}
func outVolume(_ id: AudioObjectID) -> Float32 { var a = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput), v: Float32 = 0, n = UInt32(4); AudioObjectGetPropertyData(id, &a, 0, nil, &n, &v); return v }
func setOutVolume(_ id: AudioObjectID, _ x: Float32) { var a = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput), v = x; AudioObjectSetPropertyData(id, &a, 0, nil, 4, &v) }

// Probe: only FFT bins inside the band with chirp phase, so it repeats without a click and has a near-constant envelope.
func makeProbe(amp: Double) -> (x: [Float], re: [Float], im: [Float]) {
    var bins: [Int] = []
    for k in 0...(period/2) { let f = Double(k)*fs/Double(period); if f >= f0 && f <= f1 { bins.append(k) } }
    let n = Double(bins.count)
    var x = [Double](repeating: 0, count: period), re = [Float](repeating: 0, count: period), im = re
    for (j, k) in bins.enumerated() {
        let ph = -Double.pi*Double(j*j)/n; re[k] = Float(cos(ph)); im[k] = Float(sin(ph))
        for t in 0..<period { x[t] += 2*cos(2*Double.pi*Double(k*t)/Double(period)+ph)/Double(period) }
    }
    let s = amp/(x.map { abs($0) }.max() ?? 1)
    return (x.map { Float($0*s) }, re, im)
}

final class Lock { private var l = os_unfair_lock(); func run<T>(_ f: () -> T) -> T { os_unfair_lock_lock(&l); defer { os_unfair_lock_unlock(&l) }; return f() } }

final class Sonar: @unchecked Sendable {
    let amp: Float, fixedVolume: Float32?
    let probeL: [Float], probeR: [Float], Xr: [Float], Xi: [Float], nBins: Int
    private var agg = AudioObjectID(0), proc: AudioDeviceIOProcID?
    private let mic = device("BuiltInMicrophoneDevice"), spk = device("BuiltInSpeakerDevice")
    private var oldMic = 48000.0, oldSpk = 48000.0, oldVol: Float32 = 0
    // ring from the audio callback to the worker
    private let ringSize = 1 << 20, ring: UnsafeMutablePointer<Float>
    private var writeIdx = 0, readIdx = 0, played = 0
    private let lock = Lock()
    private var fade: Float = 0, fadeTarget: Float = 0
    private var lastSampleTime = -1.0
    private(set) var gaps = 0
    private(set) var volumeResets = 0, volumeSeenMax: Float32 = 0
    private(set) var anchor: (sample: Int, ns: UInt64) = (0, 0)
    private var worker: Thread?, running = false
    // recording
    private var file: FileHandle?, anchorsFile: FileHandle?, recSamples = 0, lastAnchorWritten = -48000
    let dftF: vDSP_DFT_Setup, dftI: vDSP_DFT_Setup
    // live view
    let viewLock = Lock()
    var imageL = [UInt32](repeating: 0xff000000, count: rows*cols), imageR = [UInt32](repeating: 0xff000000, count: rows*cols)
    var col = 0
    var traceL = [Float](repeating: -130, count: cols), traceR = [Float](repeating: -130, count: cols)
    var d0 = -1, directDB: Float = 0, floorDB: Float = 0
    private var emaRe = [Float](repeating: 0, count: period), emaIm = [Float](repeating: 0, count: period), frames = 0
    private var fr = [Float](repeating: 0, count: period), fi = [Float](repeating: 0, count: period), gr = [Float](repeating: 0, count: period), gi = [Float](repeating: 0, count: period), hr = [Float](repeating: 0, count: period), hi = [Float](repeating: 0, count: period)
    private var zero = [Float](repeating: 0, count: period)
    private static let lut: [UInt32] = (0..<256).map { i in
        let t = Double(i)/255, r = min(1, max(0, 1.6*t-0.45)), g = min(1, max(0, 1.5*t-0.1)*0.95), b = min(1, 0.15+0.8*sin(min(1, t*1.5)*Double.pi)*(1-t*0.6))
        return 0xff000000 | UInt32(b*255)<<16 | UInt32(g*255)<<8 | UInt32(r*255)
    }

    init(amp: Float, volume: Float32?) {
        self.amp = amp; fixedVolume = volume
        let p = makeProbe(amp: Double(amp)); probeL = p.x; Xr = p.re; Xi = p.im
        probeR = (0..<period).map { p.x[($0+period-rxShift)%period] }
        nBins = p.re.filter { $0 != 0 || false }.count
        ring = .allocate(capacity: ringSize); ring.initialize(repeating: 0, count: ringSize)
        dftF = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(period), .FORWARD)!
        dftI = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(period), .INVERSE)!
    }

    func start() -> String? {
        oldMic = rateOf(mic); oldSpk = rateOf(spk); oldVol = outVolume(spk)
        if let v = fixedVolume { setOutVolume(spk, v); volumeSeenMax = v }
        setRate(mic, fs); setRate(spk, fs)
        let d: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Blurt Sonar", kAudioAggregateDeviceUIDKey: "local.blurt.sonar.\(getpid())",
            kAudioAggregateDeviceIsPrivateKey: 1, kAudioAggregateDeviceMainSubDeviceKey: "BuiltInSpeakerDevice",
            kAudioAggregateDeviceClockDeviceKey: "BuiltInSpeakerDevice",
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: "BuiltInMicrophoneDevice"], [kAudioSubDeviceUIDKey: "BuiltInSpeakerDevice"]],
        ]
        var st = AudioHardwareCreateAggregateDevice(d as CFDictionary, &agg)
        if st != 0 { return "aggregate \(st)" }
        usleep(200_000); setRate(agg, fs)
        st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { [unowned self] _, inData, inTime, outData, _ in
            self.callback(inData, inTime, outData)
        }
        if st != 0 { return "ioproc \(st)" }
        fade = 0; fadeTarget = 1
        st = AudioDeviceStart(agg, proc)
        if st != 0 { return "start \(st)" }
        running = true
        let t = Thread { [unowned self] in self.workerLoop() }; t.qualityOfService = .userInteractive; t.start(); worker = t
        return nil
    }

    func stop() {
        guard running else { return }
        fadeTarget = 0; usleep(300_000)
        running = false; usleep(50_000)
        AudioDeviceStop(agg, proc); if let proc { AudioDeviceDestroyIOProcID(agg, proc) }; AudioHardwareDestroyAggregateDevice(agg)
        setRate(mic, oldMic); setRate(spk, oldSpk); setOutVolume(spk, oldVol)
    }

    private func callback(_ inData: UnsafePointer<AudioBufferList>, _ inTime: UnsafePointer<AudioTimeStamp>, _ outData: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        if let b = ins.first, let p = b.mData {
            let ch = Int(b.mNumberChannels), n = Int(b.mDataByteSize)/4/ch, f = p.assumingMemoryBound(to: Float.self)
            let st = inTime.pointee.mSampleTime
            if lastSampleTime >= 0, abs(st-lastSampleTime-Double(n)) > 0.5 { gaps += 1 }
            lastSampleTime = st
            var w = lock.run { writeIdx }
            let first = w
            for i in 0..<n { ring[w & (ringSize-1)] = f[i*ch]; w += 1 }
            let ns = AudioConvertHostTimeToNanos(inTime.pointee.mHostTime)
            lock.run { writeIdx = w; anchor = (first, ns) }
        }
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        if let b = outs.first, let p = b.mData {
            let ch = Int(b.mNumberChannels), n = Int(b.mDataByteSize)/4/ch, f = p.assumingMemoryBound(to: Float.self)
            for i in 0..<n {
                let k = played % period
                fade += (fadeTarget-fade)*0.0002       // ~100 ms ramp, no click at start or stop
                f[i*ch] = probeL[k]*fade
                if ch > 1 { f[i*ch+1] = probeR[k]*fade }
                if ch > 2 { for c in 2..<ch { f[i*ch+c] = 0 } }
                played += 1
            }
        }
    }

    var position: Int { lock.run { writeIdx } - recBase }
    private var recBase = 0

    func beginRecording(_ folder: URL) {
        FileManager.default.createFile(atPath: folder.appendingPathComponent("mic.f32").path, contents: nil)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("anchors.csv").path, contents: Data("sample,host_ns\n".utf8))
        let f = try? FileHandle(forWritingTo: folder.appendingPathComponent("mic.f32"))
        let a = try? FileHandle(forWritingTo: folder.appendingPathComponent("anchors.csv")); _ = try? a?.seekToEnd()
        lock.run { recBase = readIdx; recSamples = 0; lastAnchorWritten = -48000; anchorsFile = a; file = f }
    }
    func endRecording() -> (samples: Int, gaps: Int) {
        usleep(80_000)
        let (f, a, n): (FileHandle?, FileHandle?, Int) = lock.run { let r = (file, anchorsFile, recSamples); file = nil; anchorsFile = nil; return r }
        try? f?.close(); try? a?.close()
        return (n, gaps)
    }

    private func workerLoop() {
        var frame = [Float](repeating: 0, count: period), fill = 0
        var chunk = [Float](repeating: 0, count: 4096)
        var lastVolumeCheck = Date()
        while running {
            // Hold the planned level: volume keys or another app would otherwise change the probe level mid-test
            if let fixed = fixedVolume, Date().timeIntervalSince(lastVolumeCheck) > 0.5 {
                lastVolumeCheck = Date()
                let v = outVolume(spk); volumeSeenMax = max(volumeSeenMax, v)
                if abs(v-fixed) > 0.005 { setOutVolume(spk, fixed); volumeResets += 1 }
            }
            let (r, w) = lock.run { (readIdx, writeIdx) }
            let n = min(w-r, 4096)
            if n == 0 { usleep(3000); continue }
            for i in 0..<n { chunk[i] = ring[(r+i) & (ringSize-1)] }
            let (fh, ah, a): (FileHandle?, FileHandle?, (sample: Int, ns: UInt64)) = lock.run { readIdx = r+n; return (file, anchorsFile, anchor) }
            if let fh {
                chunk.withUnsafeBytes { try? fh.write(contentsOf: Data(bytes: $0.baseAddress!, count: n*4)) }
                let (base, last): (Int, Int) = lock.run { recSamples += n; return (recBase, lastAnchorWritten) }
                let s = a.sample-base
                if s-last >= 24000, s >= 0 { try? ah?.write(contentsOf: Data("\(s),\(a.ns)\n".utf8)); lock.run { lastAnchorWritten = s } }
            }
            var i = 0
            while i < n {
                let m = min(n-i, period-fill)
                for j in 0..<m { frame[fill+j] = chunk[i+j] }
                fill += m; i += m
                if fill == period { process(frame); fill = 0 }
            }
        }
    }

    private func process(_ x: [Float]) {
        vDSP_DFT_Execute(dftF, x, zero, &fr, &fi)
        // Y * conj(X), positive-frequency bins only, gives the analytic echo profile
        let half = period/2
        for k in 0...half { gr[k] = fr[k]*Xr[k]+fi[k]*Xi[k]; gi[k] = fi[k]*Xr[k]-fr[k]*Xi[k] }
        for k in (half+1)..<period { gr[k] = 0; gi[k] = 0 }
        vDSP_DFT_Execute(dftI, gr, gi, &hr, &hi)
        var s = 2/Float(nBins)/Float(period); vDSP_vsmul(hr, 1, &s, &hr, 1, vDSP_Length(period)); vDSP_vsmul(hi, 1, &s, &hi, 1, vDSP_Length(period))
        frames += 1
        let alpha: Float = frames < 25 ? 1/Float(frames) : 0.04     // about 0.5 s clutter memory
        var resR = hr, resI = hi
        for k in 0..<period { resR[k] -= emaRe[k]; resI[k] -= emaIm[k]; emaRe[k] += alpha*resR[k]; emaIm[k] += alpha*resI[k] }
        if frames < 30 { return }
        var peak = d0
        if d0 < 0 || frames % 200 == 0 {
            var best: Float = 0
            for k in 0..<period { let m = emaRe[k]*emaRe[k]+emaIm[k]*emaIm[k]; if m > best { best = m; peak = k } }
            viewLock.run { d0 = peak; directDB = 10*log10(best+1e-20) }
        }
        let sL = peak, sR = (peak+rxShift)%period
        var eL: Float = 0, eR: Float = 0
        viewLock.run {
            for r in 0..<rows {
                var mL: Float = 0, mR: Float = 0
                for q in 0..<2 {
                    let a = (sL+r*2+q)%period, b = (sR+r*2+q)%period
                    mL = max(mL, resR[a]*resR[a]+resI[a]*resI[a]); mR = max(mR, resR[b]*resR[b]+resI[b]*resI[b])
                }
                if r >= 10 && r <= 85 { eL += mL; eR += mR }
                let dbL = 10*log10(mL+1e-20), dbR = 10*log10(mR+1e-20)
                let iL = Int(max(0, min(255, (dbL-directDB+36)/30*255))), iR = Int(max(0, min(255, (dbR-directDB+36)/30*255)))
                imageL[(rows-1-r)*cols+col] = Sonar.lut[iL]; imageR[(rows-1-r)*cols+col] = Sonar.lut[iR]
            }
            traceL[col] = 10*log10(eL+1e-20); traceR[col] = 10*log10(eR+1e-20)
            col = (col+1)%cols
        }
    }
}

@MainActor final class Camera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated(unsafe) let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput(), queue = DispatchQueue(label: "sonar.camera")
    nonisolated(unsafe) private var writer: AVAssetWriter?, input: AVAssetWriterInput?, framesFile: FileHandle?, started = false, count = 0, dropped = 0
    var deviceName = ""
    func configure() {
        AVCaptureDevice.centerStageControlMode = .app; AVCaptureDevice.isCenterStageEnabled = false
        session.beginConfiguration()
        let cams = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        if let cam = cams.first(where: { $0.transportType == kAudioDeviceTransportTypeBuiltIn }) ?? cams.first, let i = try? AVCaptureDeviceInput(device: cam), session.canAddInput(i) {
            session.addInput(i); deviceName = cam.localizedName
            if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        }
        output.alwaysDiscardsLateVideoFrames = false
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        // Lock 30 fps: in dim rooms auto exposure would otherwise drop to about 17 fps
        if let cam = (session.inputs.first as? AVCaptureDeviceInput)?.device, (try? cam.lockForConfiguration()) != nil {
            cam.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30); cam.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            cam.unlockForConfiguration()
        }
        let s = session; DispatchQueue.global().async { s.startRunning() }
    }
    func begin(_ folder: URL) {
        let url = folder.appendingPathComponent("camera.mov")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("frames.csv").path, contents: Data("frame,host_ns\n".utf8))
        let fh = try? FileHandle(forWritingTo: folder.appendingPathComponent("frames.csv")); _ = try? fh?.seekToEnd()
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000, AVVideoMaxKeyFrameIntervalKey: 30]])
        i.expectsMediaDataInRealTime = true; w.add(i); w.startWriting()
        queue.async { self.started = false; self.count = 0; self.dropped = 0; self.framesFile = fh; self.input = i; self.writer = w }
    }
    func end() async -> (Int, Int) {
        await withCheckedContinuation { (c: CheckedContinuation<(Int, Int), Never>) in
            queue.async {
                guard let w = self.writer else { c.resume(returning: (0, 0)); return }
                let n = self.count, d = self.dropped
                self.writer = nil; let i = self.input; self.input = nil; try? self.framesFile?.close(); self.framesFile = nil
                i?.markAsFinished(); w.finishWriting { c.resume(returning: (n, d)) }
            }
        }
    }
    nonisolated func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let w = writer, let i = input else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !started { w.startSession(atSourceTime: pts); started = true }
        let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        if i.isReadyForMoreMediaData, i.append(sb) {
            try? framesFile?.write(contentsOf: Data("\(count),\(UInt64(host.seconds*1e9))\n".utf8)); count += 1
        } else { dropped += 1 }
    }
}

// AirPods head motion (CMHeadphoneMotionManager, about 50 Hz), logged on the same uptime clock as the camera frames.
final class HeadMotion: @unchecked Sendable {
    private let m = CMHeadphoneMotionManager(), q = OperationQueue(), lock = Lock()
    private var fh: FileHandle?; private(set) var written = 0, seen = 0
    var available: Bool { m.isDeviceMotionAvailable }
    func start() {
        guard m.isDeviceMotionAvailable else { return }
        q.maxConcurrentOperationCount = 1
        m.startDeviceMotionUpdates(to: q) { [self] d, _ in
            guard let d else { return }
            let a = d.attitude.quaternion, r = d.rotationRate, u = d.userAcceleration
            let line = String(format: "%lld,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.5f,%.5f,%.5f\n", Int64(d.timestamp * 1e9),
                              a.w, a.x, a.y, a.z, r.x, r.y, r.z, u.x, u.y, u.z, d.attitude.pitch, d.attitude.roll, d.attitude.yaw)
            lock.run { seen += 1; if let fh { fh.write(Data(line.utf8)); written += 1 } }
        }
    }
    func begin(_ folder: URL) {
        let u = folder.appendingPathComponent("headmotion.csv")
        FileManager.default.createFile(atPath: u.path, contents: Data("uptime_ns,qw,qx,qy,qz,rx,ry,rz,ax,ay,az,pitch,roll,yaw\n".utf8))
        let h = try? FileHandle(forWritingTo: u); _ = try? h?.seekToEnd()
        lock.run { fh = h; written = 0 }
    }
    func end() -> Int { lock.run { try? fh?.close(); fh = nil; return written } }
    var count: Int { lock.run { seen } }
}

enum Stage { case idle, ready, go, rest, wait, saving }

@MainActor final class Lab: ObservableObject {
    @Published var blocks: [Block] = []
    @Published var stage = Stage.idle
    @Published var prompt = "选一个测试，按空格开始"
    @Published var detail = ""
    @Published var progress = ""
    @Published var running = false
    @Published var imgL: CGImage?
    @Published var imgR: CGImage?
    @Published var traceL: [Float] = []
    @Published var traceR: [Float] = []
    @Published var status = ""
    @Published var selected = 0
    @Published var goStart = 0.0
    @Published var beatRate = 0.0
    @Published var beatsLimit = 0
    let sonar: Sonar, camera = Camera(), head = HeadMotion(), useCamera: Bool
    private var abort = false, spaceWait: CheckedContinuation<Void, Never>?
    private var timer: Timer?
    private var marks: FileHandle?, folder: URL?

    init(amp: Float, volume: Float32?, useCamera: Bool) {
        sonar = Sonar(amp: amp, volume: volume); self.useCamera = useCamera
        if let u = Bundle.main.url(forResource: "tests", withExtension: "json"), let d = try? Data(contentsOf: u) {
            do { blocks = try JSONDecoder().decode([Block].self, from: d) } catch { prompt = "tests.json 有错：\(error)" }
        }
    }
    func boot() {
        let go = { [self] in
            if useCamera { camera.configure() }
            head.start()
            if let e = sonar.start() { prompt = "音频启动失败 \(e)"; return }
            timer = Timer.scheduledTimer(withTimeInterval: 1/25, repeats: true) { _ in Task { @MainActor in self.tick() } }
        }
        AVCaptureDevice.requestAccess(for: .audio) { a in
            let finish: @Sendable (Bool) -> Void = { v in Task { @MainActor in
                if a && (v || !self.useCamera) { go() } else { self.prompt = "需要麦克风和摄像头权限" }
            } }
            if self.useCamera { AVCaptureDevice.requestAccess(for: .video, completionHandler: finish) } else { finish(true) }
        }
    }
    private func tick() {
        let s = sonar
        s.viewLock.run {
            imgL = image(s.imageL, s.col); imgR = image(s.imageR, s.col)
            traceL = Array(s.traceL[s.col...]+s.traceL[..<s.col]); traceR = Array(s.traceR[s.col...]+s.traceR[..<s.col])
            status = "直达声 \(Int(s.directDB)) dB · 位置 \(s.d0) · 掉帧 \(s.gaps)" + (s.volumeResets > 0 ? " · 音量被改动 \(s.volumeResets) 次，已改回" : "") + (head.available ? " · AirPods 头动 \(head.count)" : " · 无 AirPods")
        }
    }
    private func image(_ px: [UInt32], _ col: Int) -> CGImage? {
        var o = [UInt32](repeating: 0, count: rows*cols)
        o.withUnsafeMutableBufferPointer { d in px.withUnsafeBufferPointer { p in
            for r in 0..<rows { let base = r*cols
                memcpy(d.baseAddress!+base, p.baseAddress!+base+col, (cols-col)*4)
                memcpy(d.baseAddress!+base+cols-col, p.baseAddress!+base, col*4) } } }
        let data = o.withUnsafeBytes { Data($0) } as CFData
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue), provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    private func mark(_ row: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: row) else { return }
        marks?.write(d); marks?.write(Data("\n".utf8))
    }
    // Keys during a block: Space pauses after the current trial, Backspace redoes, Esc aborts the whole block.
    private var redo = false, pauseRequested = false
    @Published var paused = false
    func space() {
        if let c = spaceWait { spaceWait = nil; c.resume(); return }
        if running { pauseRequested.toggle(); detail = pauseRequested ? "这一条做完后暂停" : ""; return }
        if blocks.indices.contains(selected) { Task { await run(blocks[selected]) } }
    }
    func escape() {
        abort = true
        if let c = spaceWait { spaceWait = nil; c.resume() }
    }
    func backspace() { if running { redo = true } }
    enum Wait { case ok, abort, redo }
    private func pause(_ s: Double) async -> Wait {
        let end = Date().addingTimeInterval(s)
        while Date() < end {
            if abort { return .abort }
            if redo { redo = false; return .redo }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return abort ? .abort : .ok
    }
    func run(_ b: Block) async {
        running = true; abort = false; redo = false; pauseRequested = false
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = root.appendingPathComponent("\(b.id)-\(stamp)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        folder = dir
        FileManager.default.createFile(atPath: dir.appendingPathComponent("marks.jsonl").path, contents: nil)
        marks = try? FileHandle(forWritingTo: dir.appendingPathComponent("marks.jsonl"))
        sonar.probeL.withUnsafeBytes { try? Data($0).write(to: dir.appendingPathComponent("probe.f32")) }
        var order: [Trial] = []
        for _ in 0..<(b.rounds ?? 1) { order += (b.shuffle ?? true) ? b.trials.shuffled() : b.trials }
        let total = order.count
        prompt = b.title; detail = b.intro; stage = .wait; progress = "空格开始"
        await withCheckedContinuation { spaceWait = $0 }
        if abort { await finish(b, completed: false); return }
        sonar.beginRecording(dir)
        if useCamera { camera.begin(dir) }
        head.begin(dir)
        detail = ""; prompt = "保持坐姿"; stage = .ready; progress = ""
        _ = await pause(1.5); redo = false
        var done = 0, k = 0, nextId = 0
        var last: (id: Int, trial: Trial)? = nil      // most recent kept trial, the one Backspace voids between trials
        func voidLast() {
            guard let l = last else { return }
            mark(["kind": "void", "id": l.id]); done -= 1
            order.insert(l.trial, at: k); last = nil
            detail = "上一条作废，重录"
        }
        trials: while k < order.count {
            if abort { break }
            if pauseRequested {
                pauseRequested = false; stage = .wait; prompt = "已暂停"; detail = "空格继续 · ⌫ 重录上一条 · Esc 中止整段"
                await withCheckedContinuation { spaceWait = $0 }
                if abort { break }
                if redo { redo = false; voidLast() } else { detail = "" }
            }
            let t = order[k]
            progress = "\(done+1) / \(total)"
            prompt = t.prompt
            if t.wait == true {
                stage = .wait; detail = "好了按空格"
                await withCheckedContinuation { spaceWait = $0 }
                if abort { break }
                detail = ""
            }
            stage = .ready
            switch await pause(b.lead ?? 1.5) {
            case .abort: break trials
            case .redo: voidLast(); continue trials
            case .ok: break
            }
            let s0 = sonar.position, h0 = DispatchTime.now().uptimeNanoseconds
            stage = .go; goStart = Date().timeIntervalSinceReferenceDate; beatRate = t.rate ?? 0; beatsLimit = t.beats ?? 0
            let secs = t.secs ?? b.secs ?? 4
            switch await pause(secs) {
            case .abort: break trials
            case .redo: beatRate = 0; stage = .rest; prompt = "这一条作废，重来"; detail = ""; _ = await pause(1.0); redo = false; continue trials
            case .ok: break
            }
            let id = nextId; nextId += 1
            mark(["kind": "trial", "id": id, "i": k, "label": t.label, "prompt": t.prompt, "start": s0, "end": sonar.position, "secs": secs, "rate": t.rate ?? 0, "beats": t.beats ?? 0, "uptime_ns": h0])
            done += 1; last = (id, t); k += 1
            stage = .rest; beatRate = 0; prompt = "放松"; detail = ""
            if await pause(b.rest ?? 1.8) == .redo { voidLast() }
            if abort { break }
        }
        await finish(b, completed: !abort, done: done, total: total)
    }
    private func finish(_ b: Block, completed: Bool, done: Int = 0, total: Int = 0) async {
        stage = .saving; prompt = "正在保存"; detail = ""; beatRate = 0
        let (cam, dropped) = useCamera ? await camera.end() : (0, 0)
        let (n, gaps) = sonar.endRecording()
        let headN = head.end()
        try? marks?.close(); marks = nil
        if let folder {
            let meta: [String: Any] = ["block": b.id, "fs": fs, "period": period, "f0": f0, "f1": f1, "amp": sonar.amp, "volume": sonar.fixedVolume ?? -1, "right_shift": rxShift,
                "samples": n, "gaps": gaps, "volume_resets": sonar.volumeResets, "volume_seen_max": sonar.volumeSeenMax, "frames_written": cam, "frames_dropped": dropped, "trials_done": done, "trials_total": total, "completed": completed, "d0": sonar.d0, "camera": camera.deviceName, "headmotion_samples": headN]
            if let d = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) { try? d.write(to: folder.appendingPathComponent("meta.json")) }
            if n == 0 { try? FileManager.default.removeItem(at: folder) }
            else if !completed { try? FileManager.default.moveItem(at: folder, to: folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent+"-aborted")) }
        }
        stage = .idle; running = false; selected = min(selected+(completed ? 1 : 0), blocks.count-1)
        prompt = completed ? "这一段完成（\(done)/\(total)），可以告诉 Claude 了" : "已中止（这次录的会作废）。按空格重新开始这一段"; progress = ""
        print("BLOCK_DONE \(b.id) completed=\(completed) samples=\(n) gaps=\(gaps) frames=\(cam) dropped=\(dropped)")
        if CommandLine.arguments.contains("--selftest") { sonar.stop(); NSApp.terminate(nil) }
    }
    func quit() { sonar.stop() }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.wantsLayer = true
        let l = AVCaptureVideoPreviewLayer(session: session); l.videoGravity = .resizeAspectFill
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]; v.layer = l
        return v
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct Beat: View {
    @ObservedObject var lab: Lab
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate-lab.goStart
            let n = lab.beatsLimit
            let live = lab.stage == .go && lab.beatRate > 0 && (n == 0 || t*lab.beatRate < Double(n))
            let ph = live ? (t*lab.beatRate).truncatingRemainder(dividingBy: 1) : 1
            let s = live ? 1+0.8*exp(-ph*5) : 1
            Circle().fill(lab.stage == .go ? Color.green : Color.gray.opacity(0.35)).frame(width: 40, height: 40).scaleEffect(s).frame(width: 80, height: 80)
        }
    }
}

struct Waterfall: View {
    let title: String, image: CGImage?, trace: [Float]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ZStack {
                Rectangle().fill(.black)
                if let image { Image(decorative: image, scale: 1).resizable().interpolation(.none) }
            }
            Canvas { c, size in
                guard trace.count > 1 else { return }
                let lo = trace.min() ?? -130, span = max(15, (trace.max() ?? lo)-lo)
                var p = Path()
                for (i, v) in trace.enumerated() {
                    let x = size.width*CGFloat(i)/CGFloat(trace.count-1), y = size.height*(1-CGFloat(max(0, min(1, (v-lo)/span))))
                    if i == 0 { p.move(to: .init(x: x, y: y)) } else { p.addLine(to: .init(x: x, y: y)) }
                }
                c.stroke(p, with: .color(.orange), lineWidth: 1)
            }.frame(height: 44).background(Color.black.opacity(0.85))
        }
    }
}

struct Root: View {
    @ObservedObject var lab: Lab
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Beat(lab: lab)
                VStack(alignment: .leading, spacing: 6) {
                    Text(lab.prompt).font(.system(size: 34, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.5)
                    Text(lab.detail.isEmpty ? " " : lab.detail).font(.title3).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer()
                Text(lab.progress).font(.title3.monospacedDigit()).foregroundStyle(.secondary)
            }.frame(minHeight: 110)
            HStack(spacing: 12) {
                VStack(spacing: 8) {
                    if lab.useCamera { CameraPreview(session: lab.camera.session).aspectRatio(16/9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8)).scaleEffect(x: -1) }
                    List(selection: Binding(get: { lab.selected }, set: { if let v = $0, !lab.running { lab.selected = v } })) {
                        ForEach(Array(lab.blocks.enumerated()), id: \.offset) { i, b in Text(b.title).tag(i) }
                    }.frame(minHeight: 150)
                    Text("做的时候：空格 暂停 · ⌫ 重录这一条或上一条 · Esc 中止整段").font(.callout).foregroundStyle(.secondary)
                    Text(lab.status).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.frame(width: 380)
                VStack(spacing: 8) {
                    Waterfall(title: "左扬声器回波变化（纵轴：额外路程 0–200 cm，横轴：最近 10 s）", image: lab.imgL, trace: lab.traceL)
                    Waterfall(title: "右扬声器回波变化", image: lab.imgR, trace: lab.traceR)
                }
            }
            .frame(maxHeight: .infinity)
        }.padding(16).frame(minWidth: 1080, minHeight: 720)
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var lab: Lab?
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { MainActor.assumeIsolated { lab?.quit() } }
}

nonisolated(unsafe) var termSource: DispatchSourceSignal?

@main struct SonarLabApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var del
    @StateObject var lab: Lab
    init() {
        let a = CommandLine.arguments
        func v(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0+1 < a.count ? a[$0+1] : nil } }
        _lab = StateObject(wrappedValue: Lab(amp: Float(v("--amp") ?? "0.1")!, volume: v("--volume").map { Float32($0)! } ?? 0.5, useCamera: !a.contains("--no-camera")))
    }
    var body: some Scene {
        WindowGroup("Sonar Lab") {
            Root(lab: lab).onAppear {
                del.lab = lab
                lab.boot()
                if let i = CommandLine.arguments.firstIndex(of: "--block"), i+1 < CommandLine.arguments.count,
                   let k = lab.blocks.firstIndex(where: { $0.id == CommandLine.arguments[i+1] }) { lab.selected = k }
                // pkill or logout: still put the sample rates and volume back
                signal(SIGTERM, SIG_IGN)
                let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
                src.setEventHandler { lab.quit(); exit(0) }
                src.resume(); termSource = src
                NSApp.activate(ignoringOtherApps: true)
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                    if e.keyCode == 49 { lab.space(); return nil }
                    if e.keyCode == 53 { lab.escape(); return nil }
                    if e.keyCode == 51 { lab.backspace(); return nil }
                    return e
                }
                if CommandLine.arguments.contains("--selftest") {
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        lab.selected = lab.blocks.firstIndex { $0.id == "selftest" } ?? 0
                        lab.space(); try? await Task.sleep(nanoseconds: 500_000_000); lab.space()
                    }
                }
            }
        }
    }
}
