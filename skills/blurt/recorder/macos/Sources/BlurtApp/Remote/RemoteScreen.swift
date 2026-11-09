// The Mac's screen, to the phone (docs/design/remote.md §Screen). ScreenCaptureKit → VideoToolbox HEVC, low latency, no frame
// reordering → datagrams. Off unless the phone asks, and nothing is captured while off. Nothing here is written to disk.
//
//  • the pointer isn't in the video. Its position goes separately, 60 times a second, and the phone draws it, so it's never a frame
//    late; its shape goes when it changes.
//  • it spends only what the network carries (RemoteRate), and when the picture stops moving it sends the same frame a few more times: the
//    encoder spends what it saved on sharpening it. So text is crisp while it's read, at a rate a phone's data plan can stand, and a still
//    screen then costs nothing at all.
//  • the phone owns the view. It moves the picture it already has at once, and asks for that part of the screen when it can; the output
//    stays the same size, so the closer the view, the sharper. Each frame says which part it shows, so the phone can place it exactly
//    and the picture never jumps. Nothing on the Mac changes.
//  • one display at a time (docs/design/remote.md §Several displays): the one the pointer is on, following it across once it has
//    really crossed (RemoteDisplayFollow), or the one the phone pinned. A switch changes the running stream's filter rather than
//    starting another, with an encoder of the new display's shape and a keyframe.
import AppKit
import BlurtCore
import BlurtRemoteKit
import CoreMedia
import CryptoKit
import ScreenCaptureKit
import VideoToolbox

final class RemoteScreen: NSObject, SCStreamOutput, SCStreamDelegate {
    private let q = DispatchQueue(label: "blurt.remote.screen", qos: .userInteractive)
    private let channel: RemoteChannel
    private var stream: SCStream?
    private var session: VTCompressionSession?
    /// across restarts of the stream, so a late piece of the last one can't pass for a frame of this one
    private static var frameID: UInt32 = 0
    private var wantKey = true
    private var parameterSets: [Data] = []
    private var running = false

    // measurements
    private var encoded = 0, bytes = 0, encodeMs = 0.0, statsSince = CACurrentMediaTime(), keyframes = 0, skipped = 0

    init(channel: RemoteChannel) { self.channel = channel }

    private var source = CGRect.zero        // on the desktop, in points
    private var crop = RemoteCrop.whole
    /// what frames show. ScreenCaptureKit doesn't say which frame a change landed on: while one is under way frames can't be labelled, so
    /// they wait, and the latest goes when it's done, with the new label. On a still screen that's the only frame there is.
    private var frameCrop = RemoteCrop.whole
    private var cropsUnderWay = 0
    private var heldImage: (image: CVImageBuffer, pts: CMTime)?
    private var config: SCStreamConfiguration?
    private var ticker: DispatchSourceTimer?
    private var lastCursor = CGPoint(x: -1, y: -1)
    private var lastShape: Int?
    private var tick = 0
    private var relayed = false
    private var stopped = false
    private var requestedCrop: RemoteCrop?
    private var lastImage: CVImageBuffer?
    private var lastImageCrop = RemoteCrop.whole
    private var lastPTS = CMTime.zero
    private var lastFrameAt = 0.0
    private var lastEncodedAt = 0.0
    private var rate = RemoteRate(bitrate: 12_000_000, fps: 60)
    /// frames skipped because the socket was full, and bytes sent, since the phone's last report
    private var busySkips = 0, reportBytes = 0, reportSince = CACurrentMediaTime()
    /// bytes of picture sent, and the phone's last word on what it has. In a TCP stream the gap is what's queued somewhere on the way
    private var sentTotal = 0, receivedTotal = 0, lastReportAt = 0.0
    /// times the still frame has been sent again
    private var refines = 0
    private var idlePace = false
    /// the last frame's size: when a resend comes out this small, there's nothing left to sharpen
    private var lastFrameBytes = 0, lastKeyAt = 0.0, lastKeyAnswered = 0.0
    /// `sentTotal` at the end of the last keyframe: until the phone has that much it's still arriving
    private var keyThrough = 0
    /// the last frame went in the relay's stream
    private var wasWhole = false
    /// holding frames back since then; no progress for a while means what's missing isn't coming
    private var heldSince = 0.0
    /// the direct path's pieces are still going out
    private var pacedUntil = 0.0
    private static let refinesPerStill = 8
    /// NACK, LTR refresh, parity (RemoteScreenRepair.swift, docs/design/remote-realtime.md)
    private let repair = ScreenRepair()
    private var timing = ScreenTiming()
    private static let settled = 1500
    var onInfo: ((ToPhone) -> Void)?
    /// capture ended by itself
    var onStopped: (() -> Void)?

    // several displays
    /// what the phone asked for, within reason: a switch makes the new display's stream from it
    private var asked: RemoteScreenRequest?
    /// the display being shown (0: a window, in the measured run)
    private var shownDisplay: CGDirectDisplayID = 0
    /// the phone chose this one; nil follows the pointer
    private var pinned: CGDirectDisplayID?
    private var follow = RemoteDisplayFollow()
    private var displays = RemoteDisplayList.all()
    private var scDisplays: [SCDisplay] = []
    /// a switch under way, and one asked for meanwhile
    private var switching = false
    private var nextSwitch: CGDirectDisplayID?
    /// when the last switch began, until its first frame has gone: what it took is measured
    private var switchBegan = 0.0
    private var switchWhy = ""
    private var encoderSize = (w: 0, h: 0)
    /// Zoomed in, the display comes at its own pixels and each frame is cropped here on the GPU (RemoteScreenCrop.swift); the whole view
    /// comes at the output size, scaled by ScreenCaptureKit. Frames say which by their size, so a change needs no waiting.
    private var nativeSize = (w: 0, h: 0)
    private var native = false
    private let cropper = ScreenCropper()
    /// the last frame as captured, to crop again when only the view moves; and the crop it was last sent with
    private var lastRaw: CVImageBuffer?
    private var lastRawCrop = RemoteCrop.whole

    /// Where the pointer is on the desktop. Tests that post nothing move a pretend one (RemoteInput.pretendPointer), so following it
    /// from display to display is tried without touching the real one.
    private static func pointerNow() -> CGPoint { RemoteInput.shared.pretendPointer ?? CGEvent(source: nil)?.location ?? .zero }

    /// The stream for a display: its shape, as large as the phone asked for and no larger than the display has pixels.
    private static func configure(_ src: CGRect, scale: CGFloat, _ r: RemoteScreenRequest) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let k = min(CGFloat(r.width) / src.width, CGFloat(r.height) / src.height, scale)
        c.width = Int(src.width * k) / 2 * 2
        c.height = Int(src.height * k) / 2 * 2
        c.scalesToFit = true
        // at 60 frames a second or more, capture at 120 whatever the phone's panel: a change is picked up within 8 ms of the Mac drawing it
        // instead of 17. What's sent stays at the phone's rate (frameGap; a frame captured early waits for its turn)
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(r.fps >= 60 ? 120 : max(1, r.fps)))
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.queueDepth = 5    // one is kept as the last image
        c.showsCursor = false
        c.capturesAudio = false
        return c
    }

    func start(_ asked: RemoteScreenRequest, failed: @escaping (String) -> Void) {
        // what the phone asks for, within reason: a number out of range mustn't trap
        var r = asked
        r.fps = min(max(r.fps, 1), 120)
        r.width = min(max(r.width, 64), 8192)
        r.height = min(max(r.height, 64), 8192)
        r.bitrate = min(max(r.bitrate, 100_000), 50_000_000)
        q.sync {
            self.asked = r
            self.repair.negotiate(r.features)
            self.pinned = RemoteDisplayList.id(r.display)
            self.failedHandler = failed
        }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let filter: SCContentFilter, src: CGRect, scale: CGFloat
                var shown: CGDirectDisplayID = 0
                if r.target == "window" {
                    guard let w = content.windows.first(where: { $0.title == "Blurt Screen Test" }) else { return failed("no_test_window") }
                    filter = SCContentFilter(desktopIndependentWindow: w)
                    src = w.frame
                    scale = 2
                } else {
                    // the one the phone chose, or the one the pointer is on
                    let want = q.sync { self.pinned } ?? RemoteDisplayList.at(Self.pointerNow())
                    guard let d = content.displays.first(where: { $0.displayID == want }) ?? content.displays.first else { return failed("no_display") }
                    filter = SCContentFilter(display: d, excludingWindows: [])
                    src = CGDisplayBounds(d.displayID)
                    scale = RemoteDisplayList.scale(d.displayID)
                    shown = d.displayID
                }
                let c = Self.configure(src, scale: scale, r)
                let w = c.width, h = c.height
                let nativeSize = (w: Int(src.width * scale) / 2 * 2, h: Int(src.height * scale) / 2 * 2)
                relayed = channel.isRelay
                if q.sync(execute: { stopped }) { return }      // turned off while this was starting
                q.sync {
                    self.source = src
                    self.shownDisplay = shown
                    self.scDisplays = content.displays
                    self.displays = RemoteDisplayList.all()
                    self.crop = (self.requestedCrop ?? r.crop).valid
                    self.frameCrop = .whole
                    self.config = c
                    // always the whole of it: a part is cropped here (setCrop)
                    c.sourceRect = CGRect(origin: .zero, size: src.size)
                    self.nativeSize = nativeSize
                    self.native = false
                    if self.crop != .whole, (nativeSize.w, nativeSize.h) != (w, h) {
                        self.native = true
                        c.width = nativeSize.w
                        c.height = nativeSize.h
                    }
                }
                let s = SCStream(filter: filter, configuration: c, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
                q.sync {
                    self.rate = RemoteRate(bitrate: r.bitrate, fps: r.fps, away: self.relayed)
                    self.makeEncoder(w, h, self.rate.bitrate, fps: self.rate.fps)
                    self.stream = s
                    self.running = true
                    self.statsSince = CACurrentMediaTime()
                }
                try await s.startCapture()
                if q.sync(execute: { stopped }) {
                    try? await s.stopCapture()
                    return
                }
                q.async {
                    self.tellView()
                    self.startTicker(fps: self.channel.isRelay ? 15 : 60)
                    // chosen while this was starting
                    if shown != 0, let p = self.pinned, p != self.shownDisplay { self.retarget(p, why: "pinned") }
                }
                emit(["event": "remote_screen", "state": "on", "target": r.target, "crop": Double(r.crop.w), "width": w, "height": h, "bitrate": r.bitrate])
            } catch {
                emit(["event": "remote_screen", "state": "failed", "why": "\(error)"])
                // the one the user can do something about
                failed((error as NSError).code == -3801 ? "permission" : "\(error)")
            }
        }
    }

    /// Relative to the display shown: outside it, the phone knows the pointer is elsewhere.
    private func pointer() -> CGPoint {
        let p = Self.pointerNow()
        return CGPoint(x: p.x - source.minX, y: p.y - source.minY)
    }

    // MARK: several displays

    /// The phone chose a display (nil: follow the pointer again).
    func show(_ id: CGDirectDisplayID?) {
        q.async {
            self.pinned = id
            self.follow.reset()
            guard self.running, self.shownDisplay != 0 else { return }
            if let id { return self.retarget(id, why: "pinned") }
            if let d = RemoteDisplayList.at(Self.pointerNow()), d != self.shownDisplay { self.retarget(d, why: "follow") }
        }
    }

    /// The arrangement changed: plugged in, unplugged, moved, another resolution.
    func displaysChanged() {
        q.async {
            self.displays = RemoteDisplayList.all()
            guard self.running, self.shownDisplay != 0 else { return }
            let ids = RemoteDisplayList.ids()
            if let p = self.pinned, !ids.contains(p) { self.pinned = nil }
            if !ids.contains(self.shownDisplay) {
                // the one in view went: back to following
                if let d = RemoteDisplayList.at(Self.pointerNow()) { self.retarget(d, why: "gone", force: true) }
            } else if CGDisplayBounds(self.shownDisplay) != self.source {
                self.retarget(self.shownDisplay, why: "changed", force: true)
            }
        }
    }

    /// Each tick while following: the pointer has really crossed onto another display.
    private func followPointer() {
        guard pinned == nil, !switching, shownDisplay != 0 else { return }
        if let id = follow.update(shown: String(shownDisplay), pointer: Self.pointerNow(), displays: displays, now: CACurrentMediaTime()),
           let d = UInt32(id) { retarget(d, why: "follow") }
    }

    /// On `q`. The same stream, another display: its filter and configuration change while it runs, which costs much less than a new
    /// stream; frames wait meanwhile, as they do for a crop. An encoder of the new shape, the phone told before the first frame, a keyframe.
    private func retarget(_ id: CGDirectDisplayID, why: String, force: Bool = false) {
        guard running, let s = stream, let r = asked, force || id != shownDisplay else { return }
        guard !switching else { nextSwitch = id; return }
        switching = true
        cropsUnderWay += 1
        let began = CACurrentMediaTime()
        let known = scDisplays
        Task {
            var list = known
            if !list.contains(where: { $0.displayID == id }) {
                list = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false))?.displays ?? []
            }
            guard let d = list.first(where: { $0.displayID == id }) else {
                return self.q.async { self.switchDone(nil, began: began, why: why, restart: nil) }
            }
            let src = CGDisplayBounds(id)
            let c = Self.configure(src, scale: RemoteDisplayList.scale(id), r)
            c.sourceRect = CGRect(origin: .zero, size: src.size)
            var ok = true
            if #available(macOS 14.0, *) {
                do {
                    try await s.updateContentFilter(SCContentFilter(display: d, excludingWindows: []))
                    try await s.updateConfiguration(c)
                } catch {
                    ok = false
                    emit(["event": "remote_display_switch", "state": "failed", "why": "\(error)"])
                }
            } else {
                ok = false
            }
            let filterMs = (CACurrentMediaTime() - began) * 1000
            self.q.async {
                self.scDisplays = list
                self.switchDone(ok ? (id, src, c) : nil, began: began, why: why, filterMs: filterMs, restart: ok ? nil : id)
            }
        }
    }

    private func switchDone(_ to: (id: CGDirectDisplayID, src: CGRect, config: SCStreamConfiguration)?, began: Double, why: String, filterMs: Double = 0,
                            restart: CGDirectDisplayID? = nil) {
        cropsUnderWay -= 1
        switching = false
        guard running else { return }
        guard let to else {
            // macOS 13 can't change a running stream's display, or this one wouldn't: a new stream, on that display
            if let restart { return self.restart(on: restart) }
            flushHeld()
            if let n = nextSwitch { nextSwitch = nil; retarget(n, why: why) }
            return
        }
        let old = encoderSize
        config = to.config
        let k = RemoteDisplayList.scale(to.id)
        nativeSize = (Int(to.src.width * k) / 2 * 2, Int(to.src.height * k) / 2 * 2)
        native = false
        lastRaw = nil
        source = to.src
        shownDisplay = to.id
        crop = .whole
        frameCrop = .whole
        requestedCrop = nil
        lastImage = nil
        refines = 0
        follow.reset()
        makeEncoder(to.config.width, to.config.height, rate.bitrate, fps: rate.fps)
        // a frame held while the change was under way may still be the old display's; when both are the same shape, nothing tells them apart
        if let held = heldImage, CVPixelBufferGetWidth(held.image) != to.config.width || CVPixelBufferGetHeight(held.image) != to.config.height
            || (old.w == to.config.width && old.h == to.config.height) { heldImage = nil }
        switchBegan = began
        switchWhy = why
        tellView()
        lastCursor = CGPoint(x: -1, y: -1)     // where the pointer is on this one, at once
        emit(["event": "remote_display_switch", "state": "switched", "why": why, "display": Int(to.id), "filter_ms": (filterMs * 10).rounded() / 10,
              "width": to.config.width, "height": to.config.height])
        flushHeld()
        if let n = nextSwitch {
            nextSwitch = nil
            if n != to.id { retarget(n, why: why) }
        }
    }

    private var failedHandler: ((String) -> Void)?

    /// On `q`: the stream stopped and started again on another display, keeping who chose it.
    private func restart(on id: CGDirectDisplayID) {
        guard var r = asked, let f = failedHandler else { return }
        let keep = pinned, s = stream
        stream = nil
        running = false
        ticker?.cancel()
        ticker = nil
        if let e = session { VTCompressionSessionInvalidate(e) }
        session = nil
        heldImage = nil
        lastImage = nil
        r.display = String(id)
        switchBegan = CACurrentMediaTime()
        switchWhy = "restart"
        Task {
            try? await s?.stopCapture()
            self.start(r, failed: f)
            self.q.async { self.pinned = keep }
        }
    }

    private func rect(_ c: RemoteCrop) -> CGRect {
        CGRect(x: CGFloat(c.x) * source.width, y: CGFloat(c.y) * source.height, width: CGFloat(c.w) * source.width, height: CGFloat(c.h) * source.height)
    }

    /// The part of the screen the phone looks at. Applied here to the next frame, and at once to the last one: nothing waits. Only between
    /// the whole view and a zoomed one does the stream change size, and frames say which they are by that size.
    func setCrop(_ c: RemoteCrop) {
        q.async {
            let c = c.valid
            guard self.running, let config = self.config, let s = self.stream else { self.requestedCrop = c; return }
            // a crop of the display being left: the phone starts the next one whole
            guard !self.switching, c != self.crop else { return }
            self.crop = c
            let zoomed = c != .whole
            if zoomed != self.native, (self.nativeSize.w, self.nativeSize.h) != (self.encoderSize.w, self.encoderSize.h) {
                self.native = zoomed
                config.width = zoomed ? self.nativeSize.w : self.encoderSize.w
                config.height = zoomed ? self.nativeSize.h : self.encoderSize.h
                config.sourceRect = CGRect(origin: .zero, size: self.source.size)
                let asked = CACurrentMediaTime()
                s.updateConfiguration(config) { [weak self] error in
                    self?.q.async {
                        self?.timing.held((CACurrentMediaTime() - asked) * 1000)
                        if let error { emit(["event": "remote_screen", "state": "resize_failed", "why": "\(error)"]) }
                    }
                }
            }
            self.cropAgain()
        }
    }

    /// The view moved: the last frame, cropped anew, now. On a still screen nothing else would show the new part.
    private func cropAgain() {
        let now = CACurrentMediaTime()
        guard let raw = lastRaw, CVPixelBufferGetWidth(raw) == nativeSize.w, CVPixelBufferGetHeight(raw) == nativeSize.h, crop != lastRawCrop,
              let out = cropped(raw, crop) else { return }
        lastRawCrop = crop
        take(out, pts: nextPTS(), captured: now, crop: crop, cut: false)
    }

    /// One frame of the display at its own pixels, cropped and scaled to the output on the GPU.
    private func cropped(_ raw: CVImageBuffer, _ c: RemoteCrop) -> CVImageBuffer? {
        let t0 = CACurrentMediaTime()
        let out = cropper.crop(raw, c, width: encoderSize.w, height: encoderSize.h)
        timing.cropped((CACurrentMediaTime() - t0) * 1000)
        return out
    }

    private func cropDone(_ c: RemoteCrop, failed: Bool) {
        cropsUnderWay -= 1
        if !failed { frameCrop = c }
        flushHeld()
    }

    private func flushHeld() {
        guard cropsUnderWay == 0, let h = heldImage else { return }
        let wait = pacedUntil - CACurrentMediaTime()
        guard wait <= 0 else {      // a frame's pieces can't mix with another's
            q.asyncAfter(deadline: .now() + wait) { [weak self] in self?.flushHeld() }
            return
        }
        heldImage = nil
        lastImageCrop = frameCrop
        encode(h.image, pts: h.pts, captured: CMTimeGetSeconds(h.pts), crop: lastImageCrop)
    }

    /// The pointer, on the part of the screen the phone is looking at.
    func pointerTo(x: Float, y: Float) -> CGPoint? {
        q.sync {
            guard source.width > 0, x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: source.minX + CGFloat(min(1, max(0, x))) * source.width, y: source.minY + CGFloat(min(1, max(0, y))) * source.height)
        }
    }

    private func tellView() {
        onInfo?(.screenView(width: source.width, height: source.height, codec: RemoteVideoCodec.hevc, display: shownDisplay == 0 ? nil : String(shownDisplay),
                            features: repair.features.isEmpty ? nil : repair.features.sorted()))
    }

    private func startTicker(fps: Int) {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        t.setEventHandler { [weak self] in self?.tickNow(fps) }
        t.resume()
        ticker = t
    }

    private func tickNow(_ fps: Int) {
        guard running, source.width > 0 else { return }
        let p = pointer()
        tick += 1
        // and now and then regardless: these can be lost, and the phone draws the pointer from them
        // in the relay's stream nothing is lost, so now and then is rarely
        if p != lastCursor || tick % max(1, inOneStream ? fps * 5 : fps / 2) == 0 {
            lastCursor = p
            var v: [Float] = [Float(p.x / source.width), Float(p.y / source.height)]
            channel.sendDatagram(.cursor, Data(bytes: &v, count: 8))
        }
        if tick % max(1, fps / 4) == 0 { checkShape() }
        followPointer()
        refine()
    }

    /// The picture has stopped: the same frame again, for the encoder to sharpen. Also what gets the last frame out if pacing skipped it.
    private func refine() {
        guard refines < Self.refinesPerStill, cropsUnderWay == 0, !channel.streamBusy, !holdingBack(), let i = lastImage else { return }
        let now = CACurrentMediaTime()
        guard now - lastFrameAt > 0.2, now - lastEncodedAt > 0.2, now >= pacedUntil else { return }
        // after the first, a resend this small means the picture is as good as it gets
        if refines > 0, lastFrameBytes < Self.settled { refines = Self.refinesPerStill; return }
        refines += 1
        encode(i, pts: nextPTS(), captured: now, crop: lastImageCrop)
    }

    /// The encoder's rate control goes by these: real time, or a resend looks like part of the burst before it.
    private func nextPTS() -> CMTime {
        lastPTS = CMTimeMaximum(CMClockGetTime(CMClockGetHostTimeClock()), CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 600)))
        return lastPTS
    }

    /// What arrived at the phone: the rate follows it.
    func report(_ asked: RemoteScreenReport) {
        // from the phone: no number may trap the arithmetic below
        var r = asked
        r.frames = min(max(r.frames, 0), 10_000)
        r.lost = min(max(r.lost, 0), r.frames)
        r.received = min(max(r.received, 0), 1 << 50)
        r.rtt = r.rtt.map { min(max($0.isFinite ? $0 : 0, 0), 60) }
        q.async {
            let now = CACurrentMediaTime()
            let seconds = max(now - self.reportSince, 0.1)
            let sent = Int(Double(self.reportBytes) * 8 / seconds)
            let delivered = Int(Double(max(0, r.received - self.receivedTotal)) * 8 / seconds)
            if r.received > self.receivedTotal { self.heldSince = 0 }
            self.receivedTotal = r.received
            self.lastReportAt = now
            // a keyframe is a lump, not a queue
            let backedUp = self.inOneStream && now - self.lastKeyAt > 2 && self.sentTotal - r.received > max(64_000, self.rate.bitrate / 8 * 3 / 4)
            let changed = self.rate.update(frames: r.frames, lost: r.lost, busy: self.busySkips, backedUp: backedUp, rtt: r.rtt, sent: sent, delivered: delivered)
            self.busySkips = 0
            self.reportBytes = 0
            self.reportSince = now
            self.repair.adapt(rtt: r.rtt)
            guard changed else { return }
            if let s = self.session { Self.setRate(s, self.rate.bitrate, fps: self.rate.fps) }
            emit(["event": "remote_screen_rate", "bitrate": self.rate.bitrate, "fps": self.rate.fps, "lost": r.lost, "sent": sent])
        }
    }

    /// Over the relay's stream: keys and everything else go the same way as the picture, and must not wait behind seconds of it.
    private var inOneStream: Bool { relayed && !channel.hasDatagrams }

    /// Ahead of the phone by more than a moment's worth: nothing more goes until it catches up. If its reports stop, so does this. If it's
    /// getting nothing at all, the gap isn't a queue: those bytes went down a path that died, and the picture starts over from a keyframe.
    private func holdingBack() -> Bool {
        let now = CACurrentMediaTime()
        guard inOneStream, sentTotal - receivedTotal > max(48_000, rate.bitrate / 8 * 3 / 2) else {
            heldSince = 0
            return false
        }
        if heldSince == 0 { heldSince = now }
        // a keyframe counts as received only when all of it is in
        if now - heldSince > 6 {
            heldSince = 0
            sentTotal = receivedTotal
            wantKey = true
            return false
        }
        return now - lastReportAt < 3
    }

    /// Nobody's touching the phone: a long job scrolling by doesn't need every frame.
    func pace(idle: Bool) { q.async { self.idlePace = idle } }

    private var frameGap: Double { 1 / Double(idlePace ? min(5, rate.fps) : rate.fps) }

    private static func setRate(_ s: VTCompressionSession, _ bitrate: Int, fps: Int) {
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        // no second may go far over: on a thin link a burst is what queues up and makes everything late
        let limit = [bitrate / 8 * 2, 1] as CFArray
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
    }

    /// The pointer's shape, when it changes: an arrow, an I-beam over text.
    private func checkShape() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let c = NSCursor.currentSystem, let tiff = c.image.tiffRepresentation else { return }
            let id = SHA256.hash(data: tiff).hashValue
            guard id != self.lastShape else { return }
            self.lastShape = id
            guard let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
            self.onInfo?(.cursorShape(png: png, hotX: c.hotSpot.x, hotY: c.hotSpot.y, width: c.image.size.width, height: c.image.size.height))
        }
    }

    private func makeEncoder(_ w: Int, _ h: Int, _ bitrate: Int, fps: Int) {
        if let old = session { VTCompressionSessionInvalidate(old) }
        session = nil
        encoderSize = (w, h)
        var s: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        var lowLatency = true
        if st != noErr || s == nil {
            lowLatency = false
            st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        }
        guard st == noErr, let s else { return emit(["event": "remote_screen", "state": "no_encoder", "status": Int(st)]) }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        Self.setRate(s, bitrate, fps: fps)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 600 as CFNumber)
        repair.configure(s)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        wantKey = true
        emit(["event": "remote_screen", "state": "encoder", "low_latency": lowLatency])
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer b: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, running, session != nil, b.isValid, let image = CMSampleBufferGetImageBuffer(b) else { return }
        let size = (w: CVPixelBufferGetWidth(image), h: CVPixelBufferGetHeight(image))
        let whole = size == encoderSize, full = size == nativeSize
        // the display before a switch, at its own size: nothing the encoder can take
        guard cropsUnderWay > 0 || whole || full else { skipped += 1; return }
        // a frame with nothing new: skipped by SCK, which is why a still screen costs nothing
        if let a = CMSampleBufferGetSampleAttachmentsArray(b, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = a.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete { skipped += 1; return }
        let pts = CMSampleBufferGetPresentationTimeStamp(b)
        // ScreenCaptureKit doesn't always say so: a window that isn't changing still comes as complete frames, at full rate
        if let l = lastRaw, Self.same(l, image), lastRawCrop == (full ? crop : .whole) { skipped += 1; return }
        lastRaw = image
        lastPTS = pts
        if cropsUnderWay > 0 {
            lastImage = image
            lastFrameAt = CACurrentMediaTime()
            heldImage = (image, pts)
            return
        }
        // at the output size it is the whole view (ScreenCaptureKit scaled it); at the display's own size, the part in view is cut out here.
        // Both the same size: the display has no more pixels than the phone asked for, and is cropped here whenever the view isn't whole
        let label: RemoteCrop = full && (crop != .whole || !whole) ? crop : .whole
        lastRawCrop = label
        take(image, pts: pts, captured: CMTimeGetSeconds(pts), crop: label, cut: !(label == .whole && whole))
    }

    /// A picture for the encoder, and which part of the screen it shows: sent now, held for its turn, or skipped. `cut`: still the
    /// display's own pixels, cropped on the GPU only when it's really sent (captured at 120 for a 60 Hz phone, half never are).
    private func take(_ image: CVImageBuffer, pts: CMTime, captured: Double, crop label: RemoteCrop, cut: Bool) {
        let now = CACurrentMediaTime()
        lastFrameAt = now
        refines = 0
        // before the frame gets a number: a gap in the numbers costs a keyframe
        if channel.streamBusy || holdingBack() {
            busySkips += 1
            skipped += 1
            // what a resend later sharpens is this one
            if let out = cut ? cropped(image, label) : image { lastImage = out; lastImageCrop = label }
            return
        }
        if !turn(now) || now < pacedUntil {
            // too soon: it waits for its turn rather than being dropped, unless a newer one comes first
            skipped += 1
            early = (image, pts, captured, label, cut)
            let due = max(now + (Self.early - turns) * frameGap, pacedUntil) - now
            if !earlyQueued {
                earlyQueued = true
                q.asyncAfter(deadline: .now() + max(0.001, due)) { [weak self] in self?.sendEarly() }
            }
            return
        }
        early = nil
        sendFrame(image, cut: cut, pts: pts, captured: captured, crop: label)
    }

    private func sendFrame(_ image: CVImageBuffer, cut: Bool, pts: CMTime, captured: Double, crop label: RemoteCrop) {
        guard let out = cut ? cropped(image, label) : image else { return }
        lastImage = out
        lastImageCrop = label
        encode(out, pts: pts, captured: captured, crop: label)
    }

    private var early: (image: CVImageBuffer, pts: CMTime, captured: Double, crop: RemoteCrop, cut: Bool)?
    private var earlyQueued = false
    /// Frames may go at the phone's rate on average, not at fixed intervals: captured at 120, a 60 Hz scroll's frames come 8 and 25 ms
    /// apart, and a fixed gap dropped one in seven or made them wait. One frame's credit a frame time, at most 1.5 saved; a frame may go
    /// up to half a frame early, which the next one pays for.
    private var turns = 1.0, turnsAt = 0.0
    private static let early = 0.45

    private func turn(_ now: Double) -> Bool {
        turns = min(1.5, turns + (now - turnsAt) / frameGap)
        turnsAt = now
        return turns >= Self.early
    }

    private func sendEarly() {
        earlyQueued = false
        guard running, let e = early, cropsUnderWay == 0, !channel.streamBusy else { return }
        let now = CACurrentMediaTime()
        guard turn(now), now >= pacedUntil else {
            earlyQueued = true
            q.asyncAfter(deadline: .now() + 0.002) { [weak self] in self?.sendEarly() }
            return
        }
        early = nil
        sendFrame(e.image, cut: e.cut, pts: e.pts, captured: e.captured, crop: e.crop)
    }

    /// Every byte the same. Stops at the first difference, and a screen's worth takes well under a millisecond when there is none.
    private static func same(_ a: CVImageBuffer, _ b: CVImageBuffer) -> Bool {
        guard a !== b, CVPixelBufferGetPlaneCount(a) == CVPixelBufferGetPlaneCount(b), CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b),
              CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b) else { return false }
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        for i in 0..<CVPixelBufferGetPlaneCount(a) {
            let row = CVPixelBufferGetBytesPerRowOfPlane(a, i), rows = CVPixelBufferGetHeightOfPlane(a, i)
            guard row == CVPixelBufferGetBytesPerRowOfPlane(b, i), let x = CVPixelBufferGetBaseAddressOfPlane(a, i), let y = CVPixelBufferGetBaseAddressOfPlane(b, i),
                  memcmp(x, y, row * rows) == 0 else { return false }
        }
        return true
    }

    private func encode(_ image: CVImageBuffer, pts: CMTime, captured: Double, crop: RemoteCrop) {
        guard let session else { return }
        let t0 = CACurrentMediaTime()
        lastEncodedAt = t0
        _ = turn(t0)
        turns = max(-1, turns - 1)
        let (props, refresh) = repair.options(key: wantKey)
        wantKey = false
        VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: .invalid, frameProperties: props,
                                        infoFlagsOut: nil) { [weak self] st, _, sample in
            guard st == noErr, let sample, let self else { return }
            let done = CACurrentMediaTime()
            self.q.async { self.send(sample, captured: captured, crop: crop, encodeStart: t0, encoded: done, refresh: refresh) }
        }
    }

    /// What the phone said about the picture: pieces sent again at once, or a refresh made now (on a still screen nothing else would make one).
    func feedback(_ d: Data) {
        q.async {
            guard self.running else { return }
            switch self.repair.feedback(d, rate: self.rate.bitrate, now: CACurrentMediaTime()) {
            case let .resend(pieces)?:
                pieces.forEach { self.channel.sendDatagram(.video, $0) }
            case .refresh?:
                self.refines = 0
                if self.cropsUnderWay == 0, let i = self.lastImage, CACurrentMediaTime() - self.lastFrameAt > 0.05 {
                    self.encode(i, pts: self.nextPTS(), captured: CACurrentMediaTime(), crop: self.lastImageCrop)
                }
            case .keyframe?:
                self.keyframe()
            case nil: break
            }
        }
    }

    private func send(_ b: CMSampleBuffer, captured: Double, crop: RemoteCrop, encodeStart: Double, encoded doneAt: Double = 0, refresh: Bool = false) {
        guard running, let block = CMSampleBufferGetDataBuffer(b) else { return }
        var key = true
        if let a = CMSampleBufferGetSampleAttachmentsArray(b, createIfNecessary: false) as? [[CFString: Any]], a.first?[kCMSampleAttachmentKey_NotSync] as? Bool == true { key = false }
        if key, let f = CMSampleBufferGetFormatDescription(b) { parameterSets = Self.sets(f) }
        var len = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr, let ptr else { return }
        let picture = Data(bytes: ptr, count: len)
        Self.frameID &+= 1
        let body = RemoteVideoPayload.pack(crop: crop, parameterSets: key ? parameterSets : [], picture: picture)
        // in the relay's stream a frame goes whole: each message counts against the free plan
        let whole = relayed && !channel.hasDatagrams
        if whole != wasWhole {      // a change of path: what went the other way says nothing about this one
            wasWhole = whole
            sentTotal = receivedTotal
        }
        let token = ScreenRepair.token(b)
        var pieces = RemoteVideoPacket.split(body, frame: Self.frameID, keyframe: key, refresh: refresh && !key, ackRequested: token != nil && repair.ltr,
                                             captured: captured, payload: whole ? max(body.count, 1) : RemoteVideoPacket.payloadSize)
        let encodedPieces = pieces.map { $0.encoded() }
        pieces += repair.sent(Self.frameID, token: token, pieces: pieces, encoded: encodedPieces, datagrams: !whole, now: CACurrentMediaTime())
        if relayed, !whole, pieces.count > Self.burst {
            // a keyframe all at once is what a thin link's queue drops, and one lost piece costs the whole frame: spread out over twice the rate
            let gap = Double(Self.burst * RemoteVideoPacket.payloadSize) * 8 / Double(rate.bitrate * 2)
            let batches = stride(from: 0, to: pieces.count, by: Self.burst).map { Array(pieces[$0..<min($0 + Self.burst, pieces.count)]) }
            pacedUntil = CACurrentMediaTime() + gap * Double(batches.count - 1)
            for (i, batch) in batches.enumerated() {
                q.asyncAfter(deadline: .now() + gap * Double(i)) { [weak self] in
                    guard let self, self.running else { return }
                    batch.forEach { self.channel.sendDatagram(.video, $0.encoded()) }
                }
            }
        } else {
            for (i, p) in pieces.enumerated() { channel.sendDatagram(.video, i < encodedPieces.count ? encodedPieces[i] : p.encoded()) }
        }
        timing.add(captured: captured, encodeStart: encodeStart, encoded: doneAt > 0 ? doneAt : CACurrentMediaTime(), sent: CACurrentMediaTime())
        lastFrameBytes = body.count
        if switchBegan > 0 {
            emit(["event": "remote_display_switch", "state": "first_frame", "why": switchWhy, "ms": ((CACurrentMediaTime() - switchBegan) * 10000).rounded() / 10,
                  "keyframe": key, "bytes": body.count])
            switchBegan = 0
        }
        encoded += 1
        bytes += body.count
        reportBytes += body.count
        if whole { sentTotal += body.count }
        if key {
            lastKeyAt = CACurrentMediaTime()
            keyThrough = sentTotal
        }
        encodeMs += (CACurrentMediaTime() - encodeStart) * 1000
        if key { keyframes += 1 }
        let now = CACurrentMediaTime()
        if now - statsSince >= 2 {
            let s = now - statsSince
            var line: [String: Any] = ["event": "remote_screen_mac", "fps": Int(Double(encoded) / s), "kbps": Int(Double(bytes) * 8 / s / 1000),
                                       "encode_ms": encoded > 0 ? (encodeMs / Double(encoded) * 10).rounded() / 10 : 0, "keyframes": keyframes, "idle_frames": skipped]
            line.merge(timing.take()) { a, _ in a }
            line.merge(repair.take()) { a, _ in a }
            emit(line)
            encoded = 0; bytes = 0; encodeMs = 0; keyframes = 0; skipped = 0; statsSince = now
        }
    }

    private static let burst = 16

    private static func sets(_ f: CMFormatDescription) -> [Data] {
        var count = 0
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(f, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                           parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        return (0..<count).compactMap { i in
            var p: UnsafePointer<UInt8>?
            var n = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(f, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n,
                                                                     parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p else { return nil }
            return Data(bytes: p, count: n)
        }
    }

    /// On a still screen no new frame is coming: the last one is encoded again, so a lost keyframe doesn't leave the phone black.
    func keyframe() {
        q.async {
            // the phone asks four times a second until one lands: a keyframe that's on its way needs a moment to arrive, or they'd pile up
            let now = CACurrentMediaTime()
            // the one asked for is still arriving, and on a thin link another would only bury it; nor can pieces of two frames mix
            if self.inOneStream, self.receivedTotal < self.keyThrough, now - self.lastKeyAt < 6 { return }
            guard now >= self.pacedUntil, now - self.lastKeyAnswered > 0.7 else { return }
            self.lastKeyAnswered = now
            self.wantKey = true
            self.refines = 0
            guard self.running, self.cropsUnderWay == 0, let i = self.lastImage, now - self.lastFrameAt > 0.1 else { return }
            self.encode(i, pts: self.nextPTS(), captured: now, crop: self.lastImageCrop)
        }
    }

    func stop() {
        q.sync {
            running = false
            stopped = true
            lastImage = nil
            heldImage = nil
            lastRaw = nil
            early = nil
            cropper.reset()
            ticker?.cancel()
            ticker = nil
            if let s = session { VTCompressionSessionInvalidate(s) }
            session = nil
        }
        let s = stream
        stream = nil
        Task {
            do { try await s?.stopCapture() } catch { emit(["event": "remote_screen", "state": "stop_failed", "error": "\(error)"]) }
        }
        emit(["event": "remote_screen", "state": "off"])
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        emit(["event": "remote_screen", "state": "stopped", "why": "\(error)"])
        onInfo?(.screenFailed("stopped"))
        onStopped?()
    }
}
