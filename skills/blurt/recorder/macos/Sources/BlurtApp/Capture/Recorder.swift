import AppKit
import AVFoundation
import BlurtCore
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// MARK: - Recorder
//
// A take's failures carry a reason (BlurtCore RecordingFailure: disk_full, permission, stopped, no_frames, unknown) next
// to the raw message: the app says the reason, the log and meta.json keep the message. A writer that fails mid-take
// (the disk filled up, the encoder gave up) ends the take at once — not at Finish, minutes of a clock running over
// nothing later — and the mp4 is written in 10 s fragments, so what was recorded before still plays.

func audioInputDevices() -> [AVCaptureDevice] {
    if #available(macOS 14.0, *) {
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified).devices
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let region: CGRect
    var stream: SCStream?
    var writer: AVAssetWriter!
    var vIn: AVAssetWriterInput!
    var aIn: AVAssetWriterInput?
    var sysIn: AVAssetWriterInput?
    let q = DispatchQueue(label: "blurt.capture")
    var started = false
    var sessionStart = CMTime.invalid
    var offset = CMTime.zero          // accumulated pause time
    var pausedAt: CMTime? = nil
    var lastVideo = CMTime.invalid
    var stopping = false
    var discard = false
    var micLevel: Float = 0
    var captureSession: AVCaptureSession?
    var testMic: TestMic?             // BLURT_TEST_MIC_WAV (tests): a file instead of the microphone
    var events: FileHandle?
    var live: LiveAudio?              // live/audio.pcm sidecar (capture queue only)
    var border: NSWindow?
    var borderView = BorderView()
    var ticker: Timer?
    var cursorTicker: Timer?
    var clickMonitor: Any?
    var inkWin: NSPanel?
    var inkView: InkView?
    var inkTicker: Timer?
    var penSticky = false             // toggled with ⌥⇧D
    var inkOn = false
    var penArm = PenArm()             // the pen key first, then ⇧ / ⌥ (a ⌃⌥ chord is the window manager's)
    var testFlags: CGEventFlags?      // scripted checks (recflags): the modifiers the poll sees instead of the keyboard's
    /// record.draw_key in ~/.blurt/config.json: "control" (default) | "option" | "fn" | "off"
    let penKey: (CGEventFlags, String)? = {
        switch recordConfig()["draw_key"] as? String ?? "control" {
        case "option": return (.maskAlternate, "⌥")
        case "fn": return (.maskSecondaryFn, "fn")
        case "off": return nil
        default: return (.maskControl, "⌃")
        }
    }()
    /// the same key as BlurtCore's (the pen's modifiers: ⇧ box, ⌥ ellipse — ⌃ when ⌥ is the pen key)
    var penKind: InkModifiers.PenKey? {
        switch penKey?.0 {
        case CGEventFlags.maskAlternate?: return .option
        case CGEventFlags.maskSecondaryFn?: return .fn
        case nil: return nil
        default: return .control
        }
    }
    var snaps: RecordingSnaps?       // ⌥⇧A stills (Snap.swift)
    var lastFrame: CVImageBuffer?     // latest video frame (capture queue): a snap's fallback
    var frames = 0
    var audioBuffers = 0
    var systemBuffers = 0
    var onRestart: (() -> Void)?

    init(region: CGRect) { self.region = region }

    var isPaused: Bool { pausedAt != nil }

    func elapsed() -> Double {
        guard sessionStart.isValid else { return 0 }
        let now = pausedAt ?? hostNow()
        return max(0, CMTimeGetSeconds(CMTimeSubtract(CMTimeSubtract(now, sessionStart), offset)))
    }

    func log(_ type: String, _ extra: [String: Any] = [:]) {
        guard let fh = events else { return }
        var o: [String: Any] = ["t": (elapsed() * 1000).rounded() / 1000, "type": type]
        extra.forEach { o[$0.key] = $0.value }
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) {
            fh.write(d)
            fh.write("\n".data(using: .utf8)!)
        }
    }

    // --- setup
    func prepare(completion: @escaping (Error?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, err in
            DispatchQueue.main.async {
                guard let content = content else { return completion(err ?? NSError(domain: "blurt", code: 1)) }
                do { try self.configure(content); completion(nil) } catch { completion(error) }
            }
        }
    }

    func configure(_ content: SCShareableContent) throws {
        let center = CGPoint(x: region.midX, y: region.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
            throw NSError(domain: "blurt", code: 2, userInfo: [NSLocalizedDescriptionKey: "no display"])
        }
        let clipped = region.intersection(display.frame)
        let mine = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: mine)
        let cfg = SCStreamConfiguration()
        let scale = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        })?.backingScaleFactor ?? 2
        var w = clipped.width * scale, h = clipped.height * scale
        if w > CGFloat(opts.maxWidth) { h = h * CGFloat(opts.maxWidth) / w; w = CGFloat(opts.maxWidth) }
        let W = Int(w) / 2 * 2, H = Int(h) / 2 * 2
        cfg.sourceRect = CGRect(x: clipped.minX - display.frame.minX, y: clipped.minY - display.frame.minY,
                                width: clipped.width, height: clipped.height)
        cfg.width = W
        cfg.height = H
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(opts.fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = true
        cfg.queueDepth = 8
        var scMic = false
        if opts.mic, let wav = TestMic.wanted {   // tests: a file instead of the microphone
            testMic = TestMic(url: wav)
            if testMic == nil { emit(["event": "error", "code": "test_mic", "message": "can't read \(wav.path)"]) }
        } else if opts.mic, #available(macOS 15.0, *) {
            cfg.captureMicrophone = true
            if let name = opts.micName,
               let dev = audioInputDevices()
                .first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) {
                cfg.microphoneCaptureDeviceID = dev.uniqueID
            }
            scMic = true
        }
        var sys = false
        if opts.systemAudio, #available(macOS 13.0, *) {
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 1
            sys = true
        }

        let url = URL(fileURLWithPath: opts.out)
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false  // true leaves .sb-* temp files if we exit right after
        // fragments: a take whose writer fails partway still has a playable file up to the last fragment
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_500_000, Int(Double(W * H) * 2.2)),
                AVVideoExpectedSourceFrameRateKey: opts.fps,
                AVVideoMaxKeyFrameIntervalKey: opts.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        vIn.expectsMediaDataInRealTime = true
        writer.add(vIn)
        if opts.mic {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96000,
            ])
            a.expectsMediaDataInRealTime = true
            writer.add(a)
            aIn = a
        }
        if sys {  // kept as its own track: transcripts can then tell "me" (mic) from "others" (system)
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96000,
            ])
            a.expectsMediaDataInRealTime = true
            writer.add(a)
            sysIn = a
        }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        if scMic, #available(macOS 15.0, *) {
            try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: q)
        }
        if sys, #available(macOS 13.0, *) {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
        }
        stream = s
        if opts.mic && !scMic && TestMic.wanted == nil { try setupLegacyMic() }
        if let e = opts.events {
            FileManager.default.createFile(atPath: e, contents: nil)
            events = FileHandle(forWritingAtPath: e)
        }
        if opts.mic && liveAudioWanted() {
            live = LiveAudio(dir: URL(fileURLWithPath: opts.out).deletingLastPathComponent().appendingPathComponent("live"))
        }
        emit(["event": "configured", "width": W, "height": H, "display": Int(display.displayID),
              "region": [clipped.minX, clipped.minY, clipped.width, clipped.height], "mic": opts.mic ? (testMic != nil ? "test-file" : scMic ? "screencapturekit" : "avcapture") : "none", "system_audio": sys])
    }

    func setupLegacyMic() throws {
        let devs = audioInputDevices()
        guard let dev = (opts.micName.flatMap { n in devs.first { $0.localizedName.localizedCaseInsensitiveContains(n) } })
                ?? AVCaptureDevice.default(for: .audio) else { return }
        let cs = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: dev)
        if cs.canAddInput(input) { cs.addInput(input) }
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: q)
        if cs.canAddOutput(out) { cs.addOutput(out) }
        captureSession = cs
    }

    // --- run
    func start() {
        stream?.startCapture { err in
            if let err = err {
                DispatchQueue.main.async {
                    sessionEnded(3, ["event": "error", "code": "capture", "message": err.localizedDescription,
                                     "reason": RecordingFailure.reason(code: "capture", error: err).rawValue])
                }
            }
        }
        captureSession?.startRunning()
        testMic?.start(self)
        DispatchQueue.main.async { self.showChrome() }
    }

    /// The frame around the recorded area: `rec` solid while it rolls, `attn` dashed while paused.
    func showFrame() {
        border = overlayWindow(toNS(region).insetBy(dx: -4, dy: -4), view: borderView)
        border?.orderFrontRegardless()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.borderView.color = self.isPaused ? BrandColor.Island.attn : BrandColor.Island.rec
            self.borderView.dashed = self.isPaused
        }
    }

    /// Tests only (`fakerecording stop` never calls stop()): the fake recording's frame goes away.
    func hideFrame() {
        ticker?.invalidate()
        border?.orderOut(nil)
    }

    func showChrome() {
        makeInk()
        showFrame()
        island.recordingStarted(self, on: NSScreen.screens.first(where: { $0.frame.intersects(toNS(region)) }))
        cursorTicker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, !self.isPaused, self.sessionStart.isValid else { return }
            self.logCursor()
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self = self, !self.isPaused, let p = self.relative(NSEvent.mouseLocation) else { return }
            self.log("click", ["x": p.x, "y": p.y, "button": e.type == .rightMouseDown ? "right" : "left"])
        }
    }

    /// The pen's window over the recorded area (and the snaps' batch).
    func makeInk() {
        let r = toNS(region)
        let iv = InkView(frame: NSRect(origin: .zero, size: r.size))
        iv.rec = self
        iv.lineWidth = inkWidth(for: NSScreen.screens.first(where: { $0.frame.intersects(r) }))
        let ip = NSPanel(contentRect: r, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        ip.level = .statusBar
        ip.isFloatingPanel = true
        ip.hidesOnDeactivate = false
        ip.isOpaque = false
        ip.backgroundColor = .clear
        ip.hasShadow = false
        ip.ignoresMouseEvents = true
        ip.acceptsMouseMovedEvents = true
        ip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ip.contentView = iv
        ip.orderFrontRegardless()                 // below the border and the island
        inkWin = ip
        inkView = iv
        snaps = RecordingSnaps(rec: self, session: URL(fileURLWithPath: opts.out).deletingLastPathComponent())
        inkTicker = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.syncInk() }
        RunLoop.main.add(inkTicker!, forMode: .common)
    }

    /// Tests (`recink`): a stroke through the pen, its key (the pen key) and `shift` / `option` held — the same tool
    /// rule a drag gets. The pen's window shows it; events.jsonl gets the "stroke" line.
    func testInk(_ phase: String, x: Double, y: Double, shift: Bool, option: Bool) {
        guard let iv = inkView else { return }
        var f: NSEvent.ModifierFlags = []
        switch penKind {
        case .option?: f.insert(.option)
        case .fn?: f.insert(.function)
        default: f.insert(.control)
        }
        if shift { f.insert(.shift) }
        if option { f.insert(penKind == .option ? .control : .option) }
        let p = CGPoint(x: iv.bounds.width * x, y: iv.bounds.height * y)
        switch phase {
        case "down": inkWin?.orderFrontRegardless(); iv.begin(at: p, tool: iv.tool(f))
        case "up": iv.end()
        default: iv.move(to: p, tool: iv.tool(f))
        }
    }

    func relative(_ ns: NSPoint) -> CGPoint? {
        let cg = CGPoint(x: ns.x, y: primaryHeight - ns.y)
        guard region.contains(cg) else { return nil }
        return CGPoint(x: ((cg.x - region.minX) / region.width * 1000).rounded() / 1000,
                       y: ((cg.y - region.minY) / region.height * 1000).rounded() / 1000)
    }

    var lastCursor: CGPoint?
    func logCursor() {
        guard let p = relative(NSEvent.mouseLocation), p != lastCursor else { return }
        lastCursor = p
        log("cursor", ["x": p.x, "y": p.y])
    }

    func togglePause() {
        q.async {
            if let p = self.pausedAt {
                self.offset = CMTimeAdd(self.offset, CMTimeSubtract(hostNow(), p))
                self.pausedAt = nil
                DispatchQueue.main.async { self.log("resume"); emit(["event": "resumed", "t": self.elapsed()]) }
            } else if self.sessionStart.isValid {
                DispatchQueue.main.async { self.log("pause") }
                self.pausedAt = hostNow()
                DispatchQueue.main.async { emit(["event": "paused", "t": self.elapsed()]) }
            }
        }
    }

    func togglePen() {
        penSticky.toggle()
        // while the pen is latched the recorded app can't be clicked, so give an obvious way out
        if penSticky { registerHotkey(.penEsc, key: kVK_Escape, mods: 0) } else { unregisterHotkey(.penEsc) }
        syncInk()
    }

    /// The pen is on while its key is held — alone, or with ⇧ (a box) or ⌥ (an ellipse; ⌃ when ⌥ is the pen key), the
    /// same modifiers as a snap's (BlurtCore InkModifiers) — polled: needs no Accessibility permission; or after a toggle.
    /// The pen key has to go down first (PenArm): a ⌃⌥ / ⌃⇧ chord pressed together stays the window manager's.
    func syncInk() {
        var held = false
        if let pen = penKind {
            let f = testFlags ?? CGEventSource.flagsState(.combinedSessionState)
            let tool = InkModifiers.recordingTool(pen: pen, control: f.contains(.maskControl), option: f.contains(.maskAlternate),
                                                  shift: f.contains(.maskShift), command: f.contains(.maskCommand),
                                                  fn: f.contains(.maskSecondaryFn))
            held = penArm.update(tool, now: ProcessInfo.processInfo.systemUptime) != nil
        }
        let on = !isPaused && !stopping && sessionStart.isValid && (penSticky || held)
        guard on != inkOn, inkView?.live == nil else { return }
        inkOn = on
        if testFlags != nil { emit(["event": "rec_pen", "on": on]) }
        inkView?.setOn(on)
        island.orderFront()
    }

    /// ⌥⇧M: still logged as a marker, and now also a snap of this exact moment. Silent — the mic is recording.
    func marker() {
        log("marker")
        emit(["event": "marker", "t": elapsed()])
        snap(via: "marker")
    }

    func snap(via: String, then: ((Shot) -> Void)? = nil) { snaps?.snap(via: via, then: then) }

    func latestFrame() -> CVImageBuffer? { q.sync { lastFrame } }

    func adjusted(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        if offset == .zero { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in 0..<count {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, !stopping else { return }
        if type == .screen {
            guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            handleVideo(sb)
        } else if isSystemAudio(type) {
            handleSystemAudio(sb)
        } else {
            handleAudio(sb)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        emit(["event": "error", "code": "stream_stopped", "message": error.localizedDescription,
              "reason": RecordingFailure.reason(code: "stream_stopped", error: error).rawValue])
        DispatchQueue.main.async { self.stop() }
    }

    // AVCapture (macOS < 15 mic)
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let cs = captureSession, let clock = cs.synchronizationClock else { handleAudio(sb); return }
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sb), from: clock, to: CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sb), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        if let o = out { handleAudio(o) }
    }

    func handleVideo(_ sb: CMSampleBuffer) {
        if !started {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            guard writer.startWriting() else { return writerFailed() }
            writer.startSession(atSourceTime: pts)
            sessionStart = pts
            started = true
            DispatchQueue.main.async { emit(["event": "recording"]) }
        }
        if isPaused { return }
        guard let s = adjusted(sb), vIn.isReadyForMoreMediaData else { return }
        lastFrame = CMSampleBufferGetImageBuffer(sb)
        if vIn.append(s) {
            frames += 1
            lastVideo = CMSampleBufferGetPresentationTimeStamp(s)
        } else if writer.status == .failed {
            writerFailed()
        }
    }

    /// The writer can't go on (capture queue): end the take now; stop() reports it from the writer's status.
    private func writerFailed() {
        let e = writer.error
        DispatchQueue.main.async {
            guard !self.stopping else { return }
            emit(["event": "error", "code": "writer", "message": e?.localizedDescription ?? "the writer failed", "mid_take": true,
                  "reason": RecordingFailure.reason(code: "writer", error: e).rawValue])
            self.stop()
        }
    }

    func handleAudio(_ sb: CMSampleBuffer) {
        micLevel = rms(sb)
        guard started, !isPaused, let a = aIn else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTimeCompare(pts, sessionStart) >= 0, let s = adjusted(sb) else { return }
        live?.append(s, at: CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(s), sessionStart)))
        guard a.isReadyForMoreMediaData else { return }
        if a.append(s) { audioBuffers += 1 } else if writer.status == .failed { writerFailed() }
    }

    func isSystemAudio(_ type: SCStreamOutputType) -> Bool {
        if #available(macOS 13.0, *) { return type == .audio }
        return false
    }

    func handleSystemAudio(_ sb: CMSampleBuffer) {
        guard started, !isPaused, let a = sysIn else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTimeCompare(pts, sessionStart) >= 0, let s = adjusted(sb), a.isReadyForMoreMediaData else { return }
        if a.append(s) { systemBuffers += 1 } else if writer.status == .failed { writerFailed() }
    }

    func rms(_ sb: CMSampleBuffer) -> Float {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sb) else { return 0 }
        var len = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr,
              let p = ptr, len > 0 else { return 0 }
        var sum: Float = 0
        var n = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            p.withMemoryRebound(to: Float.self, capacity: len / 4) { f in
                for i in stride(from: 0, to: len / 4, by: 4) { sum += f[i] * f[i]; n += 1 }
            }
        } else {
            p.withMemoryRebound(to: Int16.self, capacity: len / 2) { f in
                for i in stride(from: 0, to: len / 2, by: 4) { let v = Float(f[i]) / 32768; sum += v * v; n += 1 }
            }
        }
        guard n > 0 else { return 0 }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        return max(0, min(1, (db + 55) / 45))       // -55 dB … -10 dB → 0 … 1
    }

    func stop(discard: Bool = false, restart: Bool = false) {
        guard !stopping else { return }
        self.discard = discard
        let endAt = CMTimeSubtract(pausedAt ?? hostNow(), offset)
        stopping = true
        penSticky = false
        unregisterHotkey(.penEsc)
        ticker?.invalidate()
        cursorTicker?.invalidate()
        inkTicker?.invalidate()
        inkWin?.orderOut(nil)
        island.recordingStopping()
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        log("stop")
        try? events?.close()
        border?.orderOut(nil)
        captureSession?.stopRunning()
        testMic?.stop()
        let finish = {
            self.q.async {
                // the pcm is complete now: live.py can finish the transcript while the mp4 is still being written
                if discard || !self.started { self.live?.discard() } else {
                    self.live?.finish(duration: CMTimeGetSeconds(CMTimeSubtract(endAt, self.sessionStart)))
                }
                self.live = nil
                guard self.started else {
                    DispatchQueue.main.async {
                        if restart { emit(["event": "restarting"]); self.onRestart?(); return }
                        sessionEnded(discard ? 2 : 4, discard ? ["event": "cancelled"]
                                     : ["event": "error", "code": "no_frames", "message": "no video frames captured",
                                        "reason": RecordingFailure.noFrames.rawValue])
                    }
                    return
                }
                // a writer that failed partway can't be finished (AVAssetWriter raises): what it wrote stays
                if self.writer.status == .failed {
                    let e = self.writer.error
                    DispatchQueue.main.async {
                        if discard {
                            try? FileManager.default.removeItem(atPath: opts.out)
                            if let ev = opts.events { try? FileManager.default.removeItem(atPath: ev) }
                            if restart { emit(["event": "restarting"]); self.onRestart?(); return }
                            return sessionEnded(2, ["event": "cancelled", "reason": "discarded"])
                        }
                        sessionEnded(5, ["event": "error", "code": "writer", "message": e?.localizedDescription ?? "the writer failed",
                                         "reason": RecordingFailure.reason(code: "writer", error: e).rawValue])
                    }
                    return
                }
                self.vIn.markAsFinished()
                self.aIn?.markAsFinished()
                self.sysIn?.markAsFinished()
                // screen content may have been static at the end: extend to the real stop time
                self.writer.endSession(atSourceTime: CMTimeMaximum(endAt, self.lastVideo))
                self.writer.finishWriting {
                    DispatchQueue.main.async {
                        if discard {
                            try? FileManager.default.removeItem(atPath: opts.out)
                            if let e = opts.events { try? FileManager.default.removeItem(atPath: e) }
                            if restart { emit(["event": "restarting"]); self.onRestart?(); return }
                            sessionEnded(2, ["event": "cancelled", "reason": "discarded"])
                            return
                        }
                        if self.writer.status == .failed {
                            sessionEnded(5, ["event": "error", "code": "writer",
                                             "message": self.writer.error?.localizedDescription ?? "the writer failed",
                                             "reason": RecordingFailure.reason(code: "writer", error: self.writer.error).rawValue])
                            return
                        }
                        NSSound(named: "Submarine")?.play()
                        sessionEnded(0, ["event": "stopped", "file": opts.out, "duration": CMTimeGetSeconds(CMTimeSubtract(endAt, self.sessionStart)),
                                         "frames": self.frames, "audio_buffers": self.audioBuffers, "system_buffers": self.systemBuffers,
                                         "region": [self.region.minX, self.region.minY, self.region.width, self.region.height]])
                    }
                }
            }
        }
        if let s = stream { s.stopCapture { _ in finish() } } else { finish() }
    }
}
