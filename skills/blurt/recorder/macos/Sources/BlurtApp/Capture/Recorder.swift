import AppKit
import AVFoundation
import BlurtCore
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// MARK: - Recorder
//
// A take's failures carry a reason (BlurtCore RecordingFailure: disk_full, permission, display_gone, interrupted,
// writer, stopped, no_frames, unknown) next to the raw error: the app says the reason, the log and meta.json keep the
// error's domain, code and underlying errors (RecordingFailure.detail). The mp4 is written in 4 s fragments, so what was
// recorded before a failure still plays.
// v0.9-userfix (the 2026-10-26 10:28 take: "出了点问题，前 40 秒已保留"): at 50 s AVFoundation's mp4 fragment writer
// failed (MovieHeaderMaker err -16341 → AVFoundationErrorDomain -11800, "这项操作无法完成") and the take ended there,
// the rest of what was said lost and the cause kept only as that sentence. Now:
//  • a writer that fails mid-take is replaced (RecordingFailure.rollsOver: not for a full disk, at most 4 pieces): the
//    last frame, shown again at once, starts recording.part2.mp4 (the mic and system audio go straight on into it,
//    a still screen sends no new frame) and the take goes on; at the end the pieces are put back together on the
//    take's timeline (BlurtCore TakeStitch) — only what fell between the last fragment and the new file is missing;
//  • frames are encoded without reordering (no B-frames): every frame's decode time is its presentation time, so a
//    fragment carries no composition offsets (the variable frame rate of a screen made those large and uneven);
//  • a stream macOS stops (sleep, the screen locked, a display reconfigured, the capture service restarted —
//    RecordingFailure.restartable) is started again on the same display and the same file, up to 3 such stops a
//    take: it waits while the screen is locked or asleep, and a start that fails is tried again with backoff
//    (BlurtCore CaptureRestart, 4 tries); the user's own Stop in the menu bar ends the take as Finish does; a display
//    still gone after the last try ends it as display_gone.
//  • a saved take whose writer failed says what's missing, even when the new piece never started (Finish came first):
//    the kept file's playable length against the take's, as lost_seconds.

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
    // what a new writer (a new piece of the take) and a restarted stream are made from
    private var videoSettings: [String: Any] = [:]
    private var wantsMicTrack = false, wantsSystemTrack = false
    private var streamConfig: SCStreamConfiguration?
    private var displayID: CGDirectDisplayID = 0
    private var scMic = false
    /// the take's pieces: each file and its first moment (pause-adjusted source time); the first is recording.mp4
    private(set) var segments: [(url: URL, start: CMTime)] = []
    /// a new writer waits for the next frame to start its piece (capture queue)
    private var segmentPending = false
    /// what went wrong mid-take and was recovered from (a writer replaced, the capture restarted), for the log and meta
    private(set) var recovered: [[String: Any]] = []
    private var restarts = 0
    /// why the take ended before Finish, when it did (a stream that couldn't be restarted): the stopped event says so
    private var endedEarly: [String: Any]?

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
        videoSettings = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_500_000, Int(Double(W * H) * 2.2)),
                AVVideoExpectedSourceFrameRateKey: opts.fps,
                AVVideoMaxKeyFrameIntervalKey: opts.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // no B-frames: decode order = presentation order, so no fragment carries composition offsets
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        wantsMicTrack = opts.mic
        wantsSystemTrack = sys
        try makeWriter(url)
        segments = []
        streamConfig = cfg
        displayID = display.displayID
        self.scMic = scMic
        let s = try makeStream(SCContentFilter(display: display, excludingWindows: mine))
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

    /// A writer for `url` with the take's tracks (video; the mic; system audio) — the first piece, or the next one.
    private func makeWriter(_ url: URL) throws {
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        w.shouldOptimizeForNetworkUse = false  // true leaves .sb-* temp files if we exit right after
        // fragments: a piece whose writer fails partway still has a file that plays (and seeks) up to the last
        // fragment — the next piece takes over from there (or, as the last one, the app keeps it: App.failedTake)
        w.movieFragmentInterval = CMTime(seconds: 4, preferredTimescale: 600)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        v.expectsMediaDataInRealTime = true
        w.add(v)
        func audioInput() -> AVAssetWriterInput {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96000,
            ])
            a.expectsMediaDataInRealTime = true
            w.add(a)
            return a
        }
        aIn = wantsMicTrack ? audioInput() : nil
        // kept as its own track: transcripts can then tell "me" (mic) from "others" (system)
        sysIn = wantsSystemTrack ? audioInput() : nil
        writer = w
        vIn = v
    }

    /// The take's stream over `filter`, with its outputs (the same configuration every time it is started again).
    private func makeStream(_ filter: SCContentFilter) throws -> SCStream {
        guard let cfg = streamConfig else { throw NSError(domain: "blurt", code: 3, userInfo: [NSLocalizedDescriptionKey: "no stream configuration"]) }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        if scMic, #available(macOS 15.0, *) {
            try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: q)
        }
        if wantsSystemTrack, #available(macOS 13.0, *) {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
        }
        return s
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
                                     "reason": RecordingFailure.reason(code: "capture", error: err).rawValue]
                                    .merging(RecordingFailure.detail(err)) { a, _ in a })
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
        DispatchQueue.main.async { self.streamStopped(error, current: stream === self.stream) }
    }

    /// The stream stopped by itself (main thread): the user's Stop in macOS's capture menu finishes the take; a
    /// stop worth another try (RecordingFailure.restartable) restarts it; anything else ends the take with what
    /// was recorded, saying why.
    func streamStopped(_ error: Error, current: Bool = true) {
        guard !stopping, current else { return }
        let d = RecordingFailure.detail(error)
        if RecordingFailure.endedByUser(error) {
            emit(["event": "capture_stopped_by_user", "t": elapsed()].merging(d) { a, _ in a })
            log("stopped_by_user")
            return stop()
        }
        if RecordingFailure.restartable(error), restarts < RecordingFailure.maxRestarts {
            return restartCapture(after: error)
        }
        captureEnded(error, reason: RecordingFailure.reason(code: "stream_stopped", error: error))
    }

    /// The stream stopped and can't go on: the take ends with what was recorded (the writer is fine), and says why.
    private func captureEnded(_ error: Error?, reason: RecordingFailure) {
        guard !stopping else { return }
        let d = RecordingFailure.detail(error)
        endedEarly = ["code": "stream_stopped", "reason": reason.rawValue, "t": elapsed()].merging(d) { a, _ in a }
        emit(["event": "error", "code": "stream_stopped", "message": error?.localizedDescription ?? "the capture stopped",
              "reason": reason.rawValue, "mid_take": true].merging(d) { a, _ in a })
        log("capture_ended", ["reason": reason.rawValue].merging(d) { a, _ in a })
        stop()
    }

    /// macOS stopped the stream for a moment (RecordingFailure.restartable): the same display is captured again into
    /// the same file — the time in between is a still frame in the video. Nothing is tried while the screen is locked
    /// or asleep (the Recorder waits for the wake / unlock); a start that fails is tried again with backoff
    /// (BlurtCore CaptureRestart); the display gone after the last try ends the take as display_gone.
    private func restartCapture(after error: Error) {
        restarts += 1
        let d = RecordingFailure.detail(error)
        let t = elapsed()
        recovered.append(["kind": "capture", "t": t, "attempt": restarts].merging(d) { a, _ in a })
        emit(["event": "capture_restarting", "t": t, "attempt": restarts].merging(d) { a, _ in a })
        log("capture_restart", ["attempt": restarts].merging(d) { a, _ in a })
        tryRestart(outage: restarts, attempt: 1, after: error, in: CaptureRestart.delay(attempt: 1))
    }

    /// Try `attempt` of starting the capture again, `delay` s from now, once the screen can be captured.
    private func tryRestart(outage: Int, attempt: Int, after error: Error, in delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (Recorder.testRestartDelay ?? delay)) { [weak self] in
            guard let self = self, !self.stopping, outage == self.restarts else { return }
            self.whenScreenAwake(outage: outage, waited: 0, after: error) {
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, err in
                    DispatchQueue.main.async { self.restartWith(content, err, after: error, outage: outage, attempt: attempt) }
                }
            }
        }
    }

    /// `go` once the screen is unlocked and the display awake (checked every CaptureRestart.lockPoll s); after
    /// CaptureRestart.lockWaitMax s the take ends with what was recorded.
    private func whenScreenAwake(outage: Int, waited: Double, after error: Error, _ go: @escaping () -> Void) {
        guard !stopping, outage == restarts else { return }
        guard Recorder.screenAsleepOrLocked(displayID) else {
            if waited > 0 { emit(["event": "capture_screen_back", "waited": waited]); log("screen_back", ["waited": waited]) }
            return go()
        }
        if waited == 0 { emit(["event": "capture_waiting_for_screen", "t": elapsed()]); log("waiting_for_screen") }
        if waited >= CaptureRestart.lockWaitMax { return captureEnded(error, reason: .interrupted) }
        let step = Recorder.testRestartDelay ?? CaptureRestart.lockPoll
        DispatchQueue.main.asyncAfter(deadline: .now() + step) { [weak self] in
            self?.whenScreenAwake(outage: outage, waited: waited + CaptureRestart.lockPoll, after: error, go)
        }
    }

    /// The screen is locked (or another user's session is in front) or the recorded display is asleep: a capture
    /// started now fails. Tests: BLURT_TEST_SCREEN_LOCKED=1 (test commands only) — the screen counts as locked.
    static func screenAsleepOrLocked(_ display: CGDirectDisplayID) -> Bool {
        if testScreenLocked { return true }
        let d = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = d?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let onConsole = d?[kCGSessionOnConsoleKey as String] as? Bool ?? true
        return locked || !onConsole || (display != 0 && CGDisplayIsAsleep(display) != 0)
    }
    static var testScreenLocked: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["BLURT_TEST_COMMANDS"] == "1" && env["BLURT_TEST_SCREEN_LOCKED"] == "1"
    }

    private func restartWith(_ content: SCShareableContent?, _ err: Error?, after error: Error, outage: Int, attempt: Int) {
        guard !stopping, outage == restarts else { return }
        guard let content = content else { return restartFailed(err ?? error, after: error, outage: outage, attempt: attempt) }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            return restartFailed(nil, after: error, outage: outage, attempt: attempt, displayMissing: true)
        }
        let mine = content.windows.filter { $0.owningApplication?.processID == getpid() }
        do {
            let s = try makeStream(SCContentFilter(display: display, excludingWindows: mine))
            stream = s
            s.startCapture { e in
                DispatchQueue.main.async {
                    guard !self.stopping, outage == self.restarts else { return }
                    if let e = e { return self.restartFailed(e, after: error, outage: outage, attempt: attempt) }
                    emit(["event": "capture_restarted", "attempt": outage, "try": attempt, "t": self.elapsed()])
                    self.log("capture_restarted", ["attempt": outage, "try": attempt])
                }
            }
        } catch {
            restartFailed(error, after: error, outage: outage, attempt: attempt)
        }
    }

    /// A try at starting the capture again failed: another try after a backoff (CaptureRestart.next), or the take
    /// ends with what was recorded, saying why.
    private func restartFailed(_ e: Error?, after error: Error, outage: Int, attempt: Int, displayMissing: Bool = false) {
        let d = RecordingFailure.detail(e)
        switch CaptureRestart.next(attempt: attempt, error: e ?? error, displayMissing: displayMissing) {
        case .retry(let delay):
            emit(["event": "capture_restart_failed", "attempt": outage, "try": attempt, "retry_in": delay,
                  "display_missing": displayMissing].merging(d) { a, _ in a })
            log("capture_restart_failed", ["try": attempt, "display_missing": displayMissing].merging(d) { a, _ in a })
            tryRestart(outage: outage, attempt: attempt + 1, after: error, in: delay)
        case .give(up: let reason):
            captureEnded(e ?? error, reason: reason)
        }
    }
    /// tests: how long a restart waits (BLURT_TEST_RESTART_DELAY seconds)
    static let testRestartDelay: Double? = ProcessInfo.processInfo.environment["BLURT_TEST_RESTART_DELAY"].flatMap(Double.init)

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
            segments = [(writer.outputURL, pts)]
            started = true
            DispatchQueue.main.async { emit(["event": "recording"]) }
        }
        if isPaused { return }
        guard let s = adjusted(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(s)
        // never a frame at or before the last one: a timestamp going back fails the whole file
        if lastVideo.isValid, CMTimeCompare(pts, lastVideo) <= 0 { return }
        if testFailNext {
            testFailNext = false
            return writerFailed(NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
                NSLocalizedDescriptionKey: "The operation could not be completed",
                NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -16341)]))
        }
        if segmentPending {
            // the next piece starts with this frame (its encoder is new: a key frame)
            guard beginPendingPiece(at: pts) else { return }
        }
        guard vIn.isReadyForMoreMediaData else { return }
        lastFrame = CMSampleBufferGetImageBuffer(sb)
        if vIn.append(s) {
            frames += 1
            lastVideo = CMSampleBufferGetPresentationTimeStamp(s)
        } else if writer.status == .failed {
            writerFailed()
        }
    }

    /// The writer can't go on (capture queue). A new piece takes over when it may (RecordingFailure.rollsOver: not a
    /// full disk, at most 4 pieces) — the next frame starts it; else the take ends now and stop() reports it from the
    /// writer's status. Either way the error's domain, code and underlying errors go to the log. `simulated`: tests.
    private func writerFailed(_ simulated: Error? = nil) {
        let e = simulated ?? writer.error
        let d = RecordingFailure.detail(e)
        // counted by the writers made, not the pieces started: a new writer that can't even start counts too (it
        // fails again at once, and the new piece starts right here — without this it would go round for ever)
        let made = abandoned.count + 1
        if !stopping, started, RecordingFailure.rollsOver(e, segments: made) {
            let n = made + 1
            let next = URL(fileURLWithPath: opts.out).deletingPathExtension().path + ".part\(n).mp4"
            try? FileManager.default.removeItem(atPath: next)
            do {
                // the failed piece keeps what it wrote up to its last fragment (it can't be finished; cancelling
                // it would delete the file). A simulated failure leaves its writer the same way, unfinished.
                abandoned.append(writer)
                try makeWriter(URL(fileURLWithPath: next))
                segmentPending = true
                let t = elapsed()
                recovered.append(["kind": "writer", "t": t, "segment": n].merging(d) { a, _ in a })
                DispatchQueue.main.async {
                    emit(["event": "writer_replaced", "t": t, "segment": n,
                          "reason": RecordingFailure.reason(code: "writer", error: e).rawValue].merging(d) { a, _ in a })
                    self.log("writer_replaced", ["segment": n].merging(d) { a, _ in a })
                }
                startPendingPieceNow()
                return
            } catch {
                let x = RecordingFailure.detail(error)
                DispatchQueue.main.async { emit(["event": "writer_replace_failed"].merging(x) { a, _ in a }) }
            }
        }
        // a simulated failure leaves its writer working: stop() then ends the take on this error, as on a real one
        if simulated != nil { simulatedFailure = e }
        DispatchQueue.main.async {
            guard !self.stopping else { return }
            emit(["event": "error", "code": "writer", "message": e?.localizedDescription ?? "the writer failed", "mid_take": true,
                  "reason": RecordingFailure.reason(code: "writer", error: e).rawValue].merging(d) { a, _ in a })
            self.log("writer_failed", d)
            self.stop()
        }
    }

    /// The pending piece's writer starts at `pts` (capture queue). False: it couldn't (writerFailed has taken over).
    private func beginPendingPiece(at pts: CMTime) -> Bool {
        guard writer.startWriting() else { writerFailed(); return false }
        writer.startSession(atSourceTime: pts)
        segments.append((writer.outputURL, pts))
        segmentPending = false
        let n = segments.count, t = elapsed()
        DispatchQueue.main.async { emit(["event": "segment_started", "segment": n, "t": t]); self.log("segment", ["segment": n]) }
        return true
    }

    /// The new piece starts now with the last frame shown again (capture queue), so the mic and system audio go on
    /// into it at once: on a still screen SCStream sends no new frame, and waiting for one lost the user's voice from
    /// the video for as long as nothing on screen changed. Paused, or no frame to show: the next frame starts it.
    private func startPendingPieceNow() {
        guard segmentPending, !isPaused, let img = lastFrame else { return }
        var pts = CMTimeSubtract(hostNow(), offset)
        if lastVideo.isValid, CMTimeCompare(pts, lastVideo) <= 0 { pts = CMTimeAdd(lastVideo, CMTime(value: 1, timescale: 600)) }
        var fmt: CMVideoFormatDescription?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: img, formatDescriptionOut: &fmt) == noErr,
              let f = fmt,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: img, formatDescription: f,
                                                       sampleTiming: &timing, sampleBufferOut: &out) == noErr,
              let sb = out, beginPendingPiece(at: pts) else { return }
        if vIn.isReadyForMoreMediaData, vIn.append(sb) {
            frames += 1
            lastVideo = pts
        } else if writer.status == .failed {
            writerFailed()
        }
    }

    /// Tests (`recwriterfail`): the writer fails at the next frame as if the encoder gave up (AVFoundation -11800 over
    /// OSStatus -16341, the 2026-10-26 take's error) — the same recovery as a real failure.
    func testWriterFailure() { q.async { self.testFailNext = true } }
    private var testFailNext = false
    /// a simulated failure that ended the take (no new piece allowed): the take ends as failed with it
    private var simulatedFailure: Error?
    /// the writers of pieces that failed: held, never finished or cancelled (cancelling deletes the file)
    private var abandoned: [AVAssetWriter] = []

    func handleAudio(_ sb: CMSampleBuffer) {
        micLevel = rms(sb)
        guard started, !isPaused, let a = aIn else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTimeCompare(pts, sessionStart) >= 0, let s = adjusted(sb) else { return }
        live?.append(s, at: CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(s), sessionStart)))
        // a new piece starts with a frame: its audio from then on (the live transcript above keeps everything)
        guard !segmentPending, let first = segments.last?.start,
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(s), first) >= 0, a.isReadyForMoreMediaData else { return }
        if a.append(s) { audioBuffers += 1 } else if writer.status == .failed { writerFailed() }
    }

    func isSystemAudio(_ type: SCStreamOutputType) -> Bool {
        if #available(macOS 13.0, *) { return type == .audio }
        return false
    }

    func handleSystemAudio(_ sb: CMSampleBuffer) {
        guard started, !isPaused, let a = sysIn else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTimeCompare(pts, sessionStart) >= 0, let s = adjusted(sb), !segmentPending, let first = segments.last?.start,
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(s), first) >= 0, a.isReadyForMoreMediaData else { return }
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
                if self.segmentPending {
                    // a new piece was made but no frame came for it: nothing in it (it was never started)
                    try? FileManager.default.removeItem(at: self.writer.outputURL)
                    self.segmentPending = false
                    return DispatchQueue.main.async { self.wrapUp(endAt: endAt, discard: discard, restart: restart, failed: nil) }
                }
                // a writer that failed partway can't be finished (AVAssetWriter raises): what it wrote stays
                if self.writer.status == .failed {
                    let e = self.writer.error
                    return DispatchQueue.main.async { self.wrapUp(endAt: endAt, discard: discard, restart: restart, failed: e) }
                }
                self.vIn.markAsFinished()
                self.aIn?.markAsFinished()
                self.sysIn?.markAsFinished()
                // screen content may have been static at the end: extend to the real stop time
                self.writer.endSession(atSourceTime: CMTimeMaximum(endAt, self.lastVideo))
                let w = self.writer!
                w.finishWriting {
                    DispatchQueue.main.async {
                        self.wrapUp(endAt: endAt, discard: discard, restart: restart,
                                    failed: w.status == .failed ? (w.error ?? NSError(domain: "AVFoundationErrorDomain", code: -11800))
                                        : self.simulatedFailure)
                    }
                }
            }
        }
        if let s = stream { s.stopCapture { _ in finish() } } else { finish() }
    }

    /// The take's files are closed (main thread): discarded → gone; in pieces → put back together (TakeStitch);
    /// then the take ends — saved, or failed with what was kept (`failed`: the last writer's error).
    private func wrapUp(endAt: CMTime, discard: Bool, restart: Bool, failed: Error?) {
        let fm = FileManager.default
        let parts = segments.map(\.url)
        if discard {
            for u in parts { try? fm.removeItem(at: u) }
            try? fm.removeItem(atPath: opts.out)
            if let e = opts.events { try? fm.removeItem(atPath: e) }
            if restart { emit(["event": "restarting"]); onRestart?(); return }
            sessionEnded(2, ["event": "cancelled", "reason": "discarded"])
            return
        }
        let duration = CMTimeGetSeconds(CMTimeSubtract(endAt, sessionStart))
        let end = { (stitched: TakeStitch.Result?, stitchError: String?, lost: Double?) in
            var pieces: [String: Any] = ["segments": parts.count]
            if !self.recovered.isEmpty { pieces["recovered"] = self.recovered }
            if let r = stitched { pieces["lost_seconds"] = (r.lost * 10).rounded() / 10 }
            if let l = lost { pieces["lost_seconds"] = (l * 10).rounded() / 10 }
            if let e = stitchError {
                // the pieces stay next to recording.mp4 (the first one): nothing recorded is thrown away
                pieces["stitch_error"] = e
                pieces["parts"] = parts.dropFirst().map(\.lastPathComponent)
            }
            if let e = failed {
                let d = RecordingFailure.detail(e)
                self.log("writer_failed", d)
                sessionEnded(5, ["event": "error", "code": "writer", "message": e.localizedDescription,
                                 "reason": RecordingFailure.reason(code: "writer", error: e).rawValue]
                                .merging(d) { a, _ in a }.merging(pieces) { a, _ in a })
                return
            }
            NSSound(named: "Submarine")?.play()
            var ev: [String: Any] = ["event": "stopped", "file": opts.out, "duration": duration,
                                     "frames": self.frames, "audio_buffers": self.audioBuffers, "system_buffers": self.systemBuffers,
                                     "region": [self.region.minX, self.region.minY, self.region.width, self.region.height]]
            if parts.count > 1 || !self.recovered.isEmpty { ev.merge(pieces) { a, _ in a } }
            if let early = self.endedEarly { ev["ended_early"] = early }
            sessionEnded(0, ev)
        }
        guard parts.count > 1 else {
            // a writer failed and its replacement never started (no frame came before Finish): the one file kept
            // ends at the failed piece's last fragment — what's missing is said, not hidden behind the full length
            guard failed == nil, recovered.contains(where: { $0["kind"] as? String == "writer" }), let u = parts.first else {
                return end(nil, nil, nil)
            }
            Task {
                let playable = (try? await AVURLAsset(url: u).load(.duration)).map(CMTimeGetSeconds) ?? 0
                await MainActor.run { end(nil, nil, max(0, duration - playable)) }
            }
            return
        }
        let starts = segments.map { CMTimeGetSeconds(CMTimeSubtract($0.start, sessionStart)) }
        emit(["event": "stitching", "segments": parts.count, "starts": starts])
        Task {
            do {
                let r = try await TakeStitch.stitch(parts, starts: starts, into: URL(fileURLWithPath: opts.out))
                await MainActor.run {
                    emit(["event": "stitched", "segments": r.pieces, "duration": r.duration, "lost_seconds": r.lost])
                    end(r, nil, nil)
                }
            } catch {
                let s = "\(error)"
                await MainActor.run {
                    emit(["event": "stitch_failed", "error": s])
                    end(nil, s, nil)
                }
            }
        }
    }
}
