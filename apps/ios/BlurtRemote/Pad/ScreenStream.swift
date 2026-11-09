// The computer's screen on the phone (docs/design/remote.md §Screen): pieces to frames, frames through the hardware decoder (HEVC or H.264), onto a
// display layer behind the pad. Its age on arrival is measured against the Mac's clock. Off unless asked for: while off nothing
// is sent, received or decoded.
import AVFoundation
import BlurtRemoteKit
import CoreImage
import UIKit
import VideoToolbox

final class ScreenStream {
    static let shared = ScreenStream()
    /// the picture's place in the pad, with the screen's shape
    let stage = CALayer()
    /// Frames go straight onto this layer, not through a sample-buffer layer: a frame and where it belongs must land in one commit, or a new
    /// crop shows in the old place for a moment and the picture twitches.
    private let video = CALayer()
    /// a layer keeps what it shows until the next commit: these stay ours until then
    private var onScreen: [CVPixelBuffer] = []
    private var nextFrame: (CVPixelBuffer, RemoteCrop)?
    private let frameLock = NSLock()
    /// the whole screen as last seen, under the video: a move past what the video covers shows this until the sharp part arrives
    private let backdrop = CALayer()
    private let q = DispatchQueue(label: "blurt.remote.screen", qos: .userInteractive)
    private var assembler = RemoteVideoAssembler()
    /// HEVC from a Mac, H.264 from most Windows and Linux computers
    private let decoder = ScreenDecoder()
    private var lastKeyRequest = 0.0
    private var lastPixels: CVPixelBuffer?
    private var debugPackets = 0, debugAt = 0.0
    private(set) var on = false
    private var request: RemoteScreenRequest?
    private var planned: ScreenPlan?
    private var planWait: DispatchWorkItem?
    private var quietReports = 0
    private var idle = false
    /// what Settings shows
    let use = ScreenUse()
    private var reportTimer: DispatchSourceTimer?
    private var reportFrames = 0, reportBytes = 0, reportDropped = 0, pictureBytes = 0
    private var reportAt = CACurrentMediaTime()
    private var keyTimer: DispatchSourceTimer?

    // what's in view, and the pointer, which is drawn here: it's never a frame late
    private let cursorLayer = CALayer()
    private var bounds = CGRect.zero
    private var alignY: CGFloat = 0.5
    private var source = CGSize.zero
    /// what's in view: fingers move it here, at once
    private(set) var port = ViewPort()
    /// what the frame on screen shows
    private var shown = RemoteCrop.whole
    private var sentCrop = RemoteCrop.whole
    private var lastCropSent = 0.0
    private var cropQueued = false
    private var lastWhole: CVPixelBuffer?
    private var backdropStale = true
    private let ci = CIContext()
    private var pointer = CGPoint(x: -1, y: -1)
    /// where the Mac last said it was
    private var macPointer: CGPoint?
    private var settling = false
    private var dragWaiting: CGPoint?
    private var lastDragSent = 0.0
    private var lastPredicted = 0.0
    private var shapeSize = CGSize(width: 12, height: 18)
    private var hot = CGPoint.zero
    private static let target = ProcessInfo.processInfo.environment["BLURT_SCREEN_TARGET"] ?? "display"

    // the Mac's clock: taken from the fastest ping seen
    private var offset: Double?
    private var bestRTT = Double.infinity

    // measurements for the stage in hand
    private var ages: [Double] = [], decodeMs: [Double] = [], probes: [Double] = []
    private var frames = 0, bytes = 0, keyRequests = 0, stageStart = CACurrentMediaTime(), firstDropped = 0
    private var probeTimer: DispatchSourceTimer?

    init() {
        video.contentsGravity = .resize
        stage.masksToBounds = true
        backdrop.contentsGravity = .resize
        backdrop.isHidden = true
        stage.addSublayer(backdrop)
        stage.addSublayer(video)
        cursorLayer.contents = UIImage(systemName: "cursorarrow", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18))?
            .withTintColor(.white, renderingMode: .alwaysOriginal).cgImage
        cursorLayer.contentsGravity = .resizeAspect
        cursorLayer.isHidden = true
        cursorLayer.shadowOpacity = 0.5
        cursorLayer.shadowRadius = 1.5
        cursorLayer.shadowOffset = .zero
        stage.addSublayer(cursorLayer)
    }

    /// The stage is the whole pad; the picture sits in it.
    func layout(_ b: CGRect, alignY: CGFloat) {
        bounds = b
        let inside = CGRect(origin: .zero, size: b.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = b
        for l in [video, backdrop] {        // not `frame`: they have transforms on them
            l.bounds = inside
            l.position = CGPoint(x: inside.midX, y: inside.midY)
        }
        CATransaction.commit()
        self.alignY = alignY
        reshape()
    }

    private func reshape() {
        let a = source.width > 0 ? source.width / source.height : Link.shared.displayAspect
        if bounds.height > 0, a > 0 { port.reshape(bounds.width / bounds.height / a, alignY: alignY) }
        place()
    }

    /// The stage in pixels, as much as a zoomed picture can fill (PadLayout.outputPixels): the output follows the stage, so an iPad window
    /// or the Duo opening asks for what it now shows. nil: the screen's own size.
    var stagePixels: CGSize? {
        didSet { if stagePixels != oldValue { planChanged() } }
    }

    private var plan: ScreenPlan {
        let l = Link.shared
        return ScreenPlan(Prefs.shared.quality, route: l.route, cellular: l.cellular, lowData: l.lowData, native: stagePixels ?? UIScreen.main.nativeBounds.size)
    }

    /// The most the Mac may send, for this path and what the user chose. Under that it follows what the network carries (RemoteRate).
    func start() {
        let p = plan
        planned = p
        let c = port.crop
        sentCrop = c
        idle = false
        start(RemoteScreenRequest(target: Self.target, crop: c, width: p.width, height: p.height, bitrate: p.bitrate, fps: p.fps))
    }

    func routeChanged() { planChanged() }

    /// The route, the phone's network, or the user's choice changed. A network that flickers restarts nothing.
    func planChanged() {
        planWait?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.on, self.plan != self.planned else { return }
            self.start()
        }
        planWait = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    /// Nobody touching the phone, away from home: the Mac slows down. Home has nothing to save.
    func setIdle(_ on: Bool) {
        let want = on && Link.shared.route != .local
        guard self.on, want != idle else { return }
        idle = want
        Link.shared.send(.screenPace(idle: want))
    }

    /// A new session: the Mac stopped the stream with the old one.
    func resume() {
        guard on else { return }
        start()
    }

    func connectionLost() { q.async { self.reset() } }

    /// Link belongs to the main thread.
    private func tell(_ m: ToMac) { DispatchQueue.main.async { Link.shared.send(m) } }

    // MARK: the view and the pointer

    /// What the computer is showing, and in which codec. Another codec than the frames so far: nothing decoded so far helps, start from a keyframe.
    func source(_ s: CGSize, codec: String?) {
        q.async { if self.decoder.told(codec) { self.reset() } }
        DispatchQueue.main.async {
            if s != self.source {       // another display: the last sight of this one says nothing about it
                self.lastWhole = nil
                self.backdropStale = true
                self.backdrop.contents = nil
            }
            self.source = s
            if s.height > 0 { Link.shared.setAspect(s.width / s.height) }     // the display in view, which may not be the main one
            self.reshape()
        }
    }

    /// Fingers on the view. The picture moves now; the Mac catches up.
    func change(scale: CGFloat, dx: CGFloat, dy: CGFloat, at p: CGPoint) {
        guard bounds.width > 0 else { return }
        wholeUnderneath()
        port.change(scale: scale, move: CGPoint(x: dx / bounds.width, y: dy / bounds.height),
                    anchor: CGPoint(x: p.x / bounds.width, y: p.y / bounds.height))
        place()
        askForView()
    }

    func gestureEnded() {
        port.settle()
        place(animated: true)
        askForView(now: true)
    }

    /// The view back to the whole screen and nothing left of the last one.
    func resetView() {
        port = ViewPort()
        reshape()
        shown = .whole
        sentCrop = .whole
        backdrop.isHidden = true
        place()
    }

    /// At most a few times a second while it moves: each change costs the encoder a little, and there's a picture to look at meanwhile.
    private func askForView(now: Bool = false) {
        let c = port.crop
        guard on, c != sentCrop else { return }
        let gap = Link.shared.route == .relay ? 0.33 : 0.15
        let wait = gap - (CACurrentMediaTime() - lastCropSent)
        if now || wait <= 0 {
            sentCrop = c
            lastCropSent = CACurrentMediaTime()
            tell(.screenCrop(c))
        } else if !cropQueued {
            cropQueued = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                self.cropQueued = false
                self.askForView()
            }
        }
    }

    /// The last sight of the whole screen, ready before the view leaves it.
    private func wholeUnderneath() {
        guard backdropStale, let p = lastWhole else { return }
        backdropStale = false
        q.async {
            guard let i = self.ci.createCGImage(CIImage(cvPixelBuffer: p), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(p), height: CVPixelBufferGetHeight(p))) else { return }
            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.backdrop.contents = i
                CATransaction.commit()
            }
        }
    }

    /// Both pictures where they belong for what's in view. `shown` is what the video layer holds, so nothing jumps when a new part arrives.
    private func place(animated: Bool = false) {
        guard bounds.width > 0 else { return }
        let v = port.rect
        func transform(_ f: CGRect) -> CGAffineTransform {
            let sx = f.width / v.width, sy = f.height / v.height
            return CGAffineTransform(translationX: (f.midX - v.midX) / v.width * bounds.width, y: (f.midY - v.midY) / v.height * bounds.height).scaledBy(x: sx, y: sy)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.2) }
        video.setAffineTransform(transform(CGRect(x: CGFloat(shown.x), y: CGFloat(shown.y), width: CGFloat(shown.w), height: CGFloat(shown.h))))
        backdrop.setAffineTransform(transform(CGRect(x: 0, y: 0, width: 1, height: 1)))
        backdrop.isHidden = port.isWhole && shown == .whole
        CATransaction.commit()
        placeCursor()
    }

    /// The view has moved off the pointer and the finger is about to use it: it comes into view, where the eyes are.
    func bringPointerIntoView() {
        let v = port.visible
        // its edges count as inside: the pointer stops on the very edge of the screen
        guard on, !port.isWhole, pointer.x >= 0, pointer.x < v.minX || pointer.x > v.maxX || pointer.y < v.minY || pointer.y > v.maxY else { return }
        move(to: CGPoint(x: v.midX, y: v.midY))
    }

    func cursor(_ d: Data) {
        guard d.count == 8 else { return }
        let x = d.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }, y = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Float.self) }
        DispatchQueue.main.async {
            self.macPointer = CGPoint(x: CGFloat(x), y: CGFloat(y))
            self.settle()
        }
    }

    /// The phone's own guess leads while the finger moves, and the Mac has the last word when it stops. The word may well have come while the
    /// finger was still moving, and nothing more comes after it: it's kept, not dropped, or the two drift apart stroke by stroke.
    private func settle() {
        let wait = max(0.12, (Link.shared.rtt ?? 0) * 1.5) - (CACurrentMediaTime() - lastPredicted)
        if wait <= 0 {
            guard let m = macPointer else { return }
            pointer = m
            placeCursor()
        } else if !settling {
            settling = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.01) {
                self.settling = false
                self.settle()
            }
        }
    }

    /// Where a point on the pad is on the Mac's screen; nil off the picture.
    private func onScreenPoint(_ p: CGPoint) -> CGPoint? {
        guard bounds.width > 0 else { return nil }
        let v = port.rect
        let x = v.minX + p.x / bounds.width * v.width, y = v.minY + p.y / bounds.height * v.height
        return x >= 0 && x <= 1 && y >= 0 && y <= 1 ? CGPoint(x: x, y: y) : nil
    }

    /// The Mac's pointer under the finger, now, ahead of whatever comes next. False off the picture.
    func placePointer(at p: CGPoint) -> Bool {
        guard on, let at = onScreenPoint(p) else { return false }
        move(to: at)
        return true
    }

    /// With the button down: it follows the finger, and stops at the picture's edge. Over the relay no more often than the pointer goes.
    func dragPointer(to p: CGPoint) {
        guard on, bounds.width > 0 else { return }
        let v = port.visible, r = port.rect
        let at = CGPoint(x: min(v.maxX, max(v.minX, r.minX + p.x / bounds.width * r.width)), y: min(v.maxY, max(v.minY, r.minY + p.y / bounds.height * r.height)))
        pointer = at
        lastPredicted = CACurrentMediaTime()
        placeCursor()
        guard Link.shared.route == .relay else { return Link.shared.send(.pointerTo(x: Float(at.x), y: Float(at.y))) }
        let due = CACurrentMediaTime() - lastDragSent >= 1.0 / 30
        dragWaiting = at
        if due { finishDrag() }
    }

    /// What's left of a drag goes before the button comes up.
    func finishDrag() {
        guard let at = dragWaiting else { return }
        dragWaiting = nil
        lastDragSent = CACurrentMediaTime()
        Link.shared.send(.pointerTo(x: Float(at.x), y: Float(at.y)))
    }

    private func move(to at: CGPoint) {
        pointer = at
        lastPredicted = CACurrentMediaTime()
        Link.shared.send(.pointerTo(x: Float(at.x), y: Float(at.y)))     // on this thread: a click sent next must land after it
        placeCursor()
    }

    func predict(dx: Float, dy: Float) {
        guard on, source.width > 0, pointer.x >= 0 else { return }
        lastPredicted = CACurrentMediaTime()
        pointer.x = min(1, max(0, pointer.x + CGFloat(dx) / source.width))
        pointer.y = min(1, max(0, pointer.y + CGFloat(dy) / source.height))
        if port.follow(pointer) {
            place()
            askForView()
        } else {
            placeCursor()
        }
    }

    func shape(_ png: Data, hot h: CGPoint, size: CGSize) {
        guard let i = UIImage(data: png) else { return }
        DispatchQueue.main.async {
            self.cursorLayer.contents = i.cgImage
            self.shapeSize = size
            self.hot = h
            self.placeCursor()
        }
    }

    private func placeCursor() {
        guard on, source.width > 0, pointer.x >= 0, bounds.width > 0 else { cursorLayer.isHidden = true; return }
        let v = port.rect
        let x = (pointer.x - v.minX) / v.width, y = (pointer.y - v.minY) / v.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = x < 0 || x > 1 || y < 0 || y > 1
        // its true scale, but never too small to find
        let k = max(0.75, bounds.width / (source.width * v.width))
        let w = shapeSize.width * k, h = shapeSize.height * k
        cursorLayer.frame = CGRect(x: x * bounds.width - hot.x * k, y: y * bounds.height - hot.y * k, width: w, height: h)
        CATransaction.commit()
    }

    func clock(phone: Double, mac: Double) {
        q.async {
            let rtt = CACurrentMediaTime() - phone
            // the fastest exchange says the most; older ones count for less as the clocks drift
            self.bestRTT *= 1.002
            if rtt < self.bestRTT {
                self.bestRTT = rtt
                self.offset = mac - (phone + rtt / 2)
            }
        }
    }

    func start(_ r: RemoteScreenRequest) {
        q.async {
            self.reset()
            self.on = true
            self.request = r
            self.pictureBytes = 0
            self.tell(.screen(r))
            self.watchKeyframes()
            self.watchRate()
        }
    }

    func stop() {
        q.async {
            guard self.on else { return }
            self.on = false
            self.keyTimer?.cancel()
            self.keyTimer = nil
            self.reportTimer?.cancel()
            self.reportTimer = nil
            self.use.stopped()
            self.tell(.screen(nil))
            self.reset()
            DispatchQueue.main.async {
                self.video.contents = nil
                self.onScreen = []
                self.backdrop.contents = nil
                self.backdropStale = true
                self.lastWhole = nil
                self.resetView()
                self.cursorLayer.isHidden = true
            }
        }
    }

    private func reset() {
        assembler = RemoteVideoAssembler()
        reportDropped = 0
        decoder.reset()
    }

    func packet(_ d: Data) {
        q.async {
            guard self.on, let p = RemoteVideoPacket(d) else { return }
            self.bytes += d.count
            self.reportBytes += d.count
            self.pictureBytes += p.payload.count
            #if DEBUG
            self.debugPackets += 1
            let t = CACurrentMediaTime()
            if t - self.debugAt > 2 {
                self.debugAt = t
                self.tell(.screenStats("{\"stage\":\"debug\",\"packets\":\(self.debugPackets),\"frames\":\(self.frames),\"waiting\":\(self.assembler.waitingForKey),\"dropped\":\(self.assembler.dropped),\"keyreq\":\(self.keyRequests),\"session\":\(self.decoder.ready),\"pcount\":\(p.count),\"pframe\":\(p.frame),\"pointer\":[\(self.pointer.x),\(self.pointer.y)]}"))
            }
            #endif
            if let f = self.assembler.add(p) { self.decode(f) }
            self.askForKey()
        }
    }

    private func askForKey() {
        guard assembler.waitingForKey else { return }
        let now = CACurrentMediaTime()
        guard now - lastKeyRequest > 0.25 else { return }
        lastKeyRequest = now
        keyRequests += 1
        tell(.requestKeyframe)
    }

    /// With no packets arriving (a still screen, the first keyframe lost) nothing else would ask.
    private func watchKeyframes() {
        keyTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1.5, repeating: 1)
        t.setEventHandler { [weak self] in self?.askForKey() }
        t.resume()
        keyTimer = t
    }

    /// Every second the Mac hears what arrived, and Settings what it's costing.
    private func watchRate() {
        reportTimer?.cancel()
        reportDropped = assembler.dropped
        reportAt = CACurrentMediaTime()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.reportRate() }
        t.resume()
        reportTimer = t
    }

    private func reportRate() {
        let now = CACurrentMediaTime(), s = max(now - reportAt, 0.1)
        // a new assembler starts from nothing
        let lost = max(0, assembler.dropped - reportDropped), frames = reportFrames, sent = reportBytes, received = pictureBytes
        reportDropped = assembler.dropped
        reportFrames = 0
        reportBytes = 0
        reportAt = now
        use.add(bytes: sent, seconds: s, frames: frames)
        // nothing arriving, nothing to say; now and then regardless, so the Mac knows the phone's still looking
        quietReports = sent == 0 ? quietReports + 1 : 0
        guard quietReports == 0 || quietReports % 5 == 0 else { return }
        DispatchQueue.main.async { Link.shared.send(.screenReport(RemoteScreenReport(frames: frames, lost: lost, rtt: Link.shared.rtt, received: received))) }
    }

    private func decode(_ f: RemoteVideoAssembler.Frame) {
        let t0 = CACurrentMediaTime()
        decoder.decode(f) { [weak self] st, image, crop in
            guard let self else { return }
            guard st == noErr, let image else {
                // nothing after this can be decoded: start again from a keyframe
                if st != noErr { self.q.async { self.reset() } }
                return
            }
            let now = CACurrentMediaTime()
            if self.decodeMs.count < 20000 {       // for the measured runs: a long session keeps none of it
                self.decodeMs.append((now - t0) * 1000)
                if let o = self.offset { self.ages.append((now + o - f.captured) * 1000) }
            }
            self.frames += 1
            self.q.async { self.reportFrames += 1 }
            self.lastPixels = image
            self.show(image, crop: crop)
        }
    }

    private func show(_ image: CVImageBuffer, crop: RemoteCrop) {
        // only the latest: after a stall the frames that piled up are worth nothing
        frameLock.lock()
        let waiting = nextFrame != nil
        nextFrame = (image, crop)
        frameLock.unlock()
        guard !waiting else { return }
        DispatchQueue.main.async { self.putUp() }
    }

    private func putUp() {
        frameLock.lock()
        let f = nextFrame
        nextFrame = nil
        frameLock.unlock()
        guard let (image, crop) = f, on else { return }
        if crop == .whole {
            lastWhole = image
            if port.isWhole { backdropStale = true }
        }
        onScreen.append(image)
        if onScreen.count > 3 { onScreen.removeFirst() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.contents = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue()
        if crop != shown {
            shown = crop
            place()
        }
        CATransaction.commit()
    }

    // MARK: measuring

    /// Round trips over the pointer's path, 100 a second: what the video does to the pointer.
    func probing(_ on: Bool) {
        q.async {
            self.probeTimer?.cancel()
            self.probeTimer = nil
            guard on else { return }
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now(), repeating: 0.01)
            t.setEventHandler {
                var v = CACurrentMediaTime().bitPattern
                let d = Data(bytes: &v, count: 8); DispatchQueue.main.async { Link.shared.datagram(.probe, d) }
            }
            t.resume()
            self.probeTimer = t
        }
    }

    func probeBack(_ d: Data) {
        guard d.count == 8 else { return }
        let bits = d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        q.async { self.probes.append((CACurrentMediaTime() - Double(bitPattern: bits)) * 1000) }
    }

    func beginStage() {
        q.async {
            self.ages = []; self.decodeMs = []; self.probes = []
            self.frames = 0; self.bytes = 0; self.keyRequests = 0
            self.stageStart = CACurrentMediaTime()
            self.firstDropped = self.assembler.dropped
            self.tell(.screenStats("{\"stage\":\"mark\"}"))     // the Mac's arrival gaps start here too
        }
    }

    private static func pct(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return -1 }
        let s = a.sorted()
        return (s[min(s.count - 1, Int(Double(s.count) * p))] * 10).rounded() / 10
    }

    func report(_ stage: String) {
        q.async {
            let t = CACurrentMediaTime() - self.stageStart
            let d: [String: Any] = ["stage": stage, "seconds": Int(t), "fps": Int(Double(self.frames) / t), "mbps": (Double(self.bytes) * 8 / t / 1e5).rounded() / 10,
                                    "age_p50": Self.pct(self.ages, 0.5), "age_p95": Self.pct(self.ages, 0.95), "age_max": Self.pct(self.ages, 1),
                                    "decode_p50": Self.pct(self.decodeMs, 0.5), "rtt_p50": Self.pct(self.probes, 0.5), "rtt_p95": Self.pct(self.probes, 0.95),
                                    "rtt_p99": Self.pct(self.probes, 0.99), "rtt_max": Self.pct(self.probes, 1), "probes": self.probes.count,
                                    "dropped": self.assembler.dropped - self.firstDropped, "key_requests": self.keyRequests, "clock_rtt": (self.bestRTT * 1e4).rounded() / 10]
            if let j = try? JSONSerialization.data(withJSONObject: d), let s = String(data: j, encoding: .utf8) { self.tell(.screenStats(s)) }
        }
    }

    /// The frame on screen now, as it was decoded: for judging how sharp the text is.
    func snapshot(_ name: String) {
        q.async {
            guard let p = self.lastPixels else { return }
            let c = CIContext()
            guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return }
            for q: CGFloat in [0.92, 0.8, 0.6] {
                let o = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: q]
                if let j = c.jpegRepresentation(of: CIImage(cvPixelBuffer: p), colorSpace: cs, options: o), j.count < 700_000 {
                    self.tell(.screenSnapshot(name: name, jpeg: j))
                    return
                }
            }
        }
    }
}

/// The measured run: a launch with BLURT_SCREEN_TEST=window|display goes through the stages by itself and reports each.
enum ScreenTest {
    static func run(target: String) {
        let w = Int(max(UIScreen.main.nativeBounds.width, UIScreen.main.nativeBounds.height))
        let h = Int(min(UIScreen.main.nativeBounds.width, UIScreen.main.nativeBounds.height))
        let bitrate = Int(ProcessInfo.processInfo.environment["BLURT_SCREEN_BITRATE"] ?? "") ?? 12_000_000
        let s = ScreenStream.shared
        let stages: [(String, Float?)] = [("off", nil), ("zoom1", 1), ("zoom2", 2), ("zoom3", 3), ("off-again", nil)]
        if ProcessInfo.processInfo.environment["BLURT_RELAY_ONLY"] == "1" { return s.start() }
        s.probing(true)
        func step(_ i: Int) {
            guard i < stages.count else {
                s.probing(false)
                Link.shared.send(.screenStats("{\"stage\":\"done\"}"))
                return
            }
            let (name, zoom) = stages[i]
            if let zoom { s.start(RemoteScreenRequest(target: target, crop: .centered(zoom: zoom), width: w, height: h, bitrate: bitrate)) } else { s.stop() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {       // past the start-up
                s.beginStage()
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                    s.report(name)
                    if zoom != nil { s.snapshot(name) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step(i + 1) }
                }
            }
        }
        step(0)
    }
}

/// Whole frames in, pictures out, through the hardware decoder. A keyframe's parameter sets make the decoder (HEVC: VPS, SPS, PPS; H.264: SPS,
/// PPS), and say which codec they are, so a frame that comes before the word on which codec it is still decodes.
final class ScreenDecoder {
    /// what the computer said it sends (screenView.codec)
    private(set) var codec = RemoteVideoCodec.hevc
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    var ready: Bool { session != nil && format != nil }

    func reset() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        format = nil
    }

    /// The codec the computer says comes next (nil: HEVC, as from Macs before 1.0.15). True when it's another one than before: the decoder
    /// has gone, and the frames on their way can't be decoded until a keyframe.
    @discardableResult func told(_ c: String?) -> Bool {
        let c = c ?? RemoteVideoCodec.hevc
        guard c != codec else { return false }
        codec = c
        reset()
        return true
    }

    /// One whole frame. `out` gets the picture and the part of the screen it shows, from VideoToolbox's thread; a status other than noErr
    /// means nothing after it decodes until a keyframe. False: nothing to decode it with yet (no keyframe so far).
    @discardableResult func decode(_ f: RemoteVideoAssembler.Frame, out: @escaping (OSStatus, CVImageBuffer?, RemoteCrop) -> Void) -> Bool {
        guard let u = RemoteVideoPayload.unpack(f.data) else { return false }
        if !u.parameterSets.isEmpty { prepare(u.parameterSets) }
        guard let session, let format else { return false }
        var block: CMBlockBuffer?
        let n = u.picture.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: n, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return false }
        _ = u.picture.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: n) }
        var sample: CMSampleBuffer?
        var size = n
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return false }
        let crop = u.crop
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { st, _, image, _, _ in out(st, image, crop) }
        return st == noErr
    }

    private func prepare(_ sets: [Data]) {
        // the sets know what they are; the computer's word is for sets that don't say
        let kind = RemoteVideoCodec.of(parameterSets: sets) ?? codec
        codec = kind
        let copies = sets.map { [UInt8]($0) }
        var fd: CMFormatDescription?
        let st: OSStatus = copies.withUnsafePointers { ptrs, sizes in
            kind == RemoteVideoCodec.h264
                ? CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: ptrs.count, parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                      nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
                : CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: ptrs.count, parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                      nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
        }
        guard st == noErr, let fd else { return }
        if let f = format, CMFormatDescriptionEqual(f, otherFormatDescription: fd), session != nil { return }
        if let s = session { VTDecompressionSessionInvalidate(s) }
        format = fd
        var s: VTDecompressionSession?
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                     kCVPixelBufferMetalCompatibilityKey: true] as [CFString: Any]
        VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                                     outputCallback: nil, decompressionSessionOut: &s)
        if let s { VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
        session = s
    }
}

private extension Array where Element == [UInt8] {
    func withUnsafePointers<R>(_ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        let copies = map { b -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: b.count)
            p.initialize(from: b, count: b.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        return body(copies.map { UnsafePointer($0) }, map(\.count))
    }
}
