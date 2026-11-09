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
    private var nextFrame: (CVPixelBuffer, RemoteCrop, Double)?
    private let frameLock = NSLock()
    /// the whole screen as last seen, under the video: a move past what the video covers shows this until the sharp part arrives
    private let backdrop = CALayer()
    private let q = DispatchQueue(label: "blurt.remote.screen", qos: .userInteractive)
    /// pieces to frames, in order, asking for what's missing (RemoteVideoRepair.swift). Until the computer names the repairs it uses in
    /// screenView it waits for nothing, as with a computer that has none.
    private var receiver = RemoteVideoReceiver(nack: false, ltr: false)
    private var repairs: Set<String> = []
    private var repairTimer: DispatchSourceTimer?
    /// what this phone offers; BLURT_SCREEN_REPAIR=0 offers none, for measuring before and after
    static let features: [String]? = ProcessInfo.processInfo.environment["BLURT_SCREEN_REPAIR"] == "0" ? nil : RemoteVideoFeature.all
    /// HEVC from a Mac, H.264 from most Windows and Linux computers
    private let decoder = ScreenDecoder()
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
    /// presentation: the display link asks for the panel's rate while frames come (120 Hz on ProMotion), and measures when a frame reaches the glass
    private var link: CADisplayLink?
    private var committed: (at: Double, captured: Double)?

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
    /// the Mac has said where the pointer is, since the picture started: it may be off the display shown (on another one), so no
    /// position means "unknown"
    private var pointerKnown = false
    /// where the Mac last said it was
    private var macPointer: CGPoint?
    private var settling = false
    private var dragWaiting: CGPoint?
    private var lastDragSent = 0.0
    private var lastPredicted = 0.0
    private var shapeSize = CGSize(width: 12, height: 18)
    private var hot = CGPoint.zero
    private static let target = ProcessInfo.processInfo.environment["BLURT_SCREEN_TARGET"] ?? "display"

    // several displays (docs/design/remote.md §Several displays)
    /// the display the picture shows
    private(set) var display: String?
    /// the last picture of the display just left, over the video until the new display's first frame is up: a cross-fade, not black
    private let leaving = CALayer()
    /// switched: frames of the old display may still be on their way; the new one's have its shape
    private var awaiting: (aspect: CGFloat, since: Double)?
    /// when the phone asked for another display, for measuring what a switch takes
    private var askedAt = 0.0

    // the Mac's clock: taken from the fastest ping seen
    private var offset: Double?
    private var bestRTT = Double.infinity

    // measurements for the stage in hand
    private var ages: [Double] = [], decodeMs: [Double] = [], probes: [Double] = []
    private var agesFirst: [Double] = [], agesWhole: [Double] = [], agesShown: [Double] = [], agesGlass: [Double] = [], vsyncWait: [Double] = []
    private var firstNacked = 0, firstRepaired = 0, firstRefreshes = 0
    /// between one new picture and the next, ms: a stall or a frozen picture shows here, not in the ages of the frames that made it
    private var gaps: [Double] = []
    /// the panel's frame, ms: 8.3 at 120 Hz
    private var panel: [Double] = []
    private var frames = 0, bytes = 0, keyRequests = 0, stageStart = CACurrentMediaTime(), firstDropped = 0
    private var probeTimer: DispatchSourceTimer?

    init() {
        video.contentsGravity = .resize
        stage.masksToBounds = true
        backdrop.contentsGravity = .resize
        backdrop.isHidden = true
        stage.addSublayer(backdrop)
        stage.addSublayer(video)
        leaving.contentsGravity = .resize
        leaving.isHidden = true
        stage.addSublayer(leaving)
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
        return ScreenPlan(Prefs.shared.quality, route: l.route, cellular: l.cellular, lowData: l.lowData, native: stagePixels ?? UIScreen.main.nativeBounds.size,
                          panel: UIScreen.main.maximumFramesPerSecond)
    }

    /// The most the Mac may send, for this path and what the user chose. Under that it follows what the network carries (RemoteRate).
    func start() {
        let p = plan
        planned = p
        let c = port.crop
        sentCrop = c
        idle = false
        start(RemoteScreenRequest(target: Self.target, crop: c, width: p.width, height: p.height, bitrate: p.bitrate, fps: p.fps,
                                  display: Link.shared.pinnedDisplay, features: Self.features))
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
    func source(_ s: CGSize, codec: String?, display d: String? = nil, features: [String]? = nil) {
        q.async {
            if self.decoder.told(codec) { self.reset() }
            self.repairs = Set(features ?? [])
            self.receiver.nack = self.repairs.contains(RemoteVideoFeature.nack)
            self.receiver.ltr = self.repairs.contains(RemoteVideoFeature.ltr)
        }
        DispatchQueue.main.async {
            let switched = d != nil && self.display != nil && d != self.display
            if s != self.source || switched {       // another display: the last sight of this one says nothing about it
                self.lastWhole = nil
                self.backdropStale = true
                self.backdrop.contents = nil
            }
            if switched { self.switchDisplay(to: s) }
            self.display = d
            self.source = s
            if s.height > 0 { Link.shared.setAspect(s.width / s.height) }     // the display in view, which may not be the main one
            self.reshape()
        }
    }

    /// The phone asked for another display: what a switch takes is measured from here.
    func displayAsked() { askedAt = CACurrentMediaTime() }

    /// Another display: another screen, so the view starts whole. The last picture stays over the video until the new one's first frame
    /// is up, then fades: the eye sees the change, never black.
    private func switchDisplay(to s: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leaving.removeAllAnimations()
        leaving.contents = video.contents
        leaving.frame = video.frame
        leaving.opacity = 1
        leaving.isHidden = video.contents == nil
        // under it, nothing of the old display stretched to the new one's shape
        video.contents = nil
        CATransaction.commit()
        let started = CACurrentMediaTime()
        awaiting = (s.height > 0 ? s.width / s.height : 0, started)
        pointerKnown = false
        cursorLayer.isHidden = true
        resetView()
        tell(.screenCrop(.whole))       // a crop still on its way was for the display left
        // the new display's first frame should be here long before this
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let a = self.awaiting, a.since == started else { return }
            self.arrived(in: nil)
        }
    }

    /// The first frame of the display switched to is up, or it's taking too long: the old picture fades.
    private func arrived(in ms: Double?) {
        awaiting = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.awaiting == nil else { return }
            self.leaving.isHidden = true
            self.leaving.contents = nil
        }
        leaving.opacity = 0
        CATransaction.commit()
        guard let ms else { return }
        let asked = askedAt > 0 ? (CACurrentMediaTime() - askedAt) * 1000 : -1
        askedAt = 0
        tell(.screenStats("{\"stage\":\"display_switch\",\"view_to_frame_ms\":\((ms * 10).rounded() / 10),\"asked_to_frame_ms\":\((asked * 10).rounded() / 10)}"))
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
        guard on, !port.isWhole, pointerKnown, pointer.x < v.minX || pointer.x > v.maxX || pointer.y < v.minY || pointer.y > v.maxY else { return }
        move(to: CGPoint(x: v.midX, y: v.midY))
    }

    func cursor(_ d: Data) {
        guard d.count == 8 else { return }
        let x = d.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }, y = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Float.self) }
        DispatchQueue.main.async {
            guard x.isFinite, y.isFinite else { return }
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
            pointerKnown = true
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
        pointerKnown = true
        lastPredicted = CACurrentMediaTime()
        Link.shared.send(.pointerTo(x: Float(at.x), y: Float(at.y)))     // on this thread: a click sent next must land after it
        placeCursor()
    }

    func predict(dx: Float, dy: Float) {
        guard on, source.width > 0, pointerKnown else { return }
        lastPredicted = CACurrentMediaTime()
        pointer = Self.moved(pointer, by: CGPoint(x: CGFloat(dx), y: CGFloat(dy)), on: source, display: display, displays: Link.shared.displays)
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

    /// Where a stroke takes the pointer, 0…1 of the display shown. With one display it stops at the edge. With several it goes where the
    /// computer would take it: across onto a neighbour (off this picture, until the computer follows), and stops only at the edge of them all.
    static func moved(_ p: CGPoint, by d: CGPoint, on size: CGSize, display: String?, displays: [RemoteDisplay]) -> CGPoint {
        guard displays.count > 1, let shown = displays.first(where: { $0.id == display }) else {
            return CGPoint(x: min(1, max(0, p.x + d.x / size.width)), y: min(1, max(0, p.y + d.y / size.height)))
        }
        let f = shown.frame
        let to = CGPoint(x: f.minX + p.x * f.width + d.x, y: f.minY + p.y * f.height + d.y)
        var best = to
        if displays.at(to) == nil {
            var far = CGFloat.infinity
            for o in displays.map(\.frame) {
                let q = CGPoint(x: min(max(to.x, o.minX), o.maxX - 1), y: min(max(to.y, o.minY), o.maxY - 1))
                let dist = hypot(q.x - to.x, q.y - to.y)
                if dist < far { far = dist; best = q }
            }
        }
        return CGPoint(x: (best.x - f.minX) / f.width, y: (best.y - f.minY) / f.height)
    }

    private func placeCursor() {
        guard on, source.width > 0, pointerKnown, bounds.width > 0 else { cursorLayer.isHidden = true; return }
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
            self.watchRepairs()
            self.watchRate()
        }
    }

    func stop() {
        q.async {
            guard self.on else { return }
            self.on = false
            self.repairTimer?.cancel()
            self.repairTimer = nil
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
                self.pointerKnown = false
                self.display = nil
                self.awaiting = nil
                self.leaving.isHidden = true
                self.leaving.contents = nil
                self.link?.invalidate()
                self.link = nil
            }
        }
    }

    private func reset() {
        receiver = RemoteVideoReceiver(nack: receiver.nack, ltr: receiver.ltr, now: CACurrentMediaTime())
        receiver.rtt = Link.rttNow
        reportDropped = 0
        decoder.reset()
    }

    func packet(_ d: Data) {
        q.async {
            guard self.on, let p = RemoteVideoPacket(d) else { return }
            #if DEBUG
            guard Self.weather.passes(d, now: CACurrentMediaTime(), later: { held in self.q.async { self.arrived(held) } }) else { return }
            #endif
            self.arrived(p, d.count)
        }
    }

    #if DEBUG
    /// A made-up bad network for measured runs (debug builds): BLURT_TEST_LOSS=rate[:mean burst] drops pieces, BLURT_TEST_STALL=ms:seconds holds
    /// everything for that long that often, as a Wi-Fi radio does when it dozes or the channel is busy.
    static var weather = TestWeather(ProcessInfo.processInfo.environment)

    private func arrived(_ d: Data) {
        guard on, let p = RemoteVideoPacket(d) else { return }
        arrived(p, d.count)
    }
    #endif

    private func arrived(_ p: RemoteVideoPacket, _ size: Int) {
        bytes += size
        reportBytes += size
        pictureBytes += p.payload.count
        #if DEBUG
        debugPackets += 1
        let t = CACurrentMediaTime()
        if t - debugAt > 2 {
            debugAt = t
            tell(.screenStats("{\"stage\":\"debug\",\"packets\":\(debugPackets),\"frames\":\(frames),\"waiting\":\(receiver.broken),\"dropped\":\(receiver.dropped),\"keyreq\":\(keyRequests),\"session\":\(decoder.ready),\"pcount\":\(p.count),\"pframe\":\(p.frame)}"))
        }
        #endif
        handle(receiver.add(p, now: CACurrentMediaTime()))
    }

    /// What the receiver wants done: frames decoded, the computer told what's missing or what arrived, a keyframe asked for.
    private func handle(_ out: [RemoteVideoReceiver.Output]) {
        for o in out {
            switch o {
            case let .frame(f): decode(f)
            case let .feedback(f):
                let d = f.encoded()
                DispatchQueue.main.async { Link.shared.datagram(.videoFeedback, d) }
            case .keyframe:
                keyRequests += 1
                tell(.requestKeyframe)
            }
        }
    }

    /// Every few ms: pieces asked for again, frames given up, a keyframe asked for when nothing arrives (a still screen, the first keyframe lost).
    private func watchRepairs() {
        repairTimer?.cancel()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: q)
        t.schedule(deadline: .now() + 0.004, repeating: 0.004, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self, self.on else { return }
            self.handle(self.receiver.tick(now: CACurrentMediaTime()))
        }
        t.resume()
        repairTimer = t
    }

    /// Every second the Mac hears what arrived, and Settings what it's costing.
    private func watchRate() {
        reportTimer?.cancel()
        reportDropped = receiver.dropped
        reportAt = CACurrentMediaTime()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.reportRate() }
        t.resume()
        reportTimer = t
    }

    private func reportRate() {
        let now = CACurrentMediaTime(), s = max(now - reportAt, 0.1)
        // a new receiver starts from nothing
        let lost = max(0, receiver.dropped - reportDropped), frames = reportFrames, sent = reportBytes, received = pictureBytes
        reportDropped = receiver.dropped
        reportFrames = 0
        reportBytes = 0
        reportAt = now
        use.add(bytes: sent, seconds: s, frames: frames)
        // nothing arriving, nothing to say; now and then regardless, so the Mac knows the phone's still looking
        quietReports = sent == 0 ? quietReports + 1 : 0
        guard quietReports == 0 || quietReports % 5 == 0 else { return }
        DispatchQueue.main.async {
            let rtt = Link.shared.rtt
            if let rtt { self.q.async { self.receiver.rtt = rtt } }
            Link.shared.send(.screenReport(RemoteScreenReport(frames: frames, lost: lost, rtt: rtt, received: received)))
        }
    }

    private func decode(_ f: RemoteVideoAssembler.Frame) {
        let t0 = CACurrentMediaTime()
        decoder.decode(f) { [weak self] st, image, crop in
            guard let self else { return }
            guard st == noErr, let image else {
                // nothing after this can be decoded: start again from a keyframe
                if st != noErr {
                    self.q.async {
                        self.decoder.reset()
                        self.receiver.decoderFailed(now: CACurrentMediaTime())
                    }
                }
                return
            }
            let now = CACurrentMediaTime()
            self.q.async {
                self.reportFrames += 1
                self.handle(self.receiver.decoded(f, now: now))
                if self.decodeMs.count < 20000 {       // for the measured runs: a long session keeps none of it
                    self.decodeMs.append((now - t0) * 1000)
                    if let o = self.offset {
                        self.ages.append((now + o - f.captured) * 1000)
                        if f.firstAt > 0 {
                            self.agesFirst.append((f.firstAt + o - f.captured) * 1000)
                            self.agesWhole.append((f.lastAt + o - f.captured) * 1000)
                        }
                    }
                }
            }
            self.frames += 1
            self.lastPixels = image
            self.show(image, crop: crop, captured: f.captured)
        }
    }

    private func show(_ image: CVImageBuffer, crop: RemoteCrop, captured: Double) {
        // only the latest: after a stall the frames that piled up are worth nothing
        frameLock.lock()
        let waiting = nextFrame != nil
        nextFrame = (image, crop, captured)
        frameLock.unlock()
        guard !waiting else { return }
        DispatchQueue.main.async { self.putUp() }
    }

    private func putUp() {
        frameLock.lock()
        let f = nextFrame
        nextFrame = nil
        frameLock.unlock()
        guard let (image, crop, captured) = f, on else { return }
        if let a = awaiting {
            // still the display left, by its shape: not shown. The first of the new one ends the cross-fade
            let w = CGFloat(CVPixelBufferGetWidth(image)), h = CGFloat(CVPixelBufferGetHeight(image))
            guard crop == .whole, h > 0, a.aspect <= 0 || abs(w / h - a.aspect) / a.aspect < 0.03 else { return }
            arrived(in: (CACurrentMediaTime() - a.since) * 1000)
        }
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
            if let t = cropAskedAt.removeValue(forKey: crop) {
                let ms = (CACurrentMediaTime() - t) * 1000
                q.async { self.cropLatency.append(ms) }
            }
        }
        CATransaction.commit()
        let now = CACurrentMediaTime()
        committed = (now, captured)
        if link == nil { startLink() }
        let gap = lastCommit > 0 ? (now - lastCommit) * 1000 : nil
        lastCommit = now
        q.async {
            if let o = self.offset, self.agesShown.count < 20000 { self.agesShown.append((now + o - captured) * 1000) }
            if let gap, self.gaps.count < 20000 { self.gaps.append(gap) }
        }
    }

    private var lastCommit = 0.0
    /// measured runs: when each crop was asked for (main thread), to time how long until a frame showing it is up (kept on q)
    private var cropAskedAt: [RemoteCrop: Double] = [:]
    private var cropLatency: [Double] = []

    func testCrop(_ c: RemoteCrop) {
        cropAskedAt[c] = CACurrentMediaTime()
        Link.shared.send(.screenCrop(c))
    }
    private var linkFresh = false

    /// While frames come: the panel at its own rate (ProMotion runs at 120 Hz only when asked to), and the time each frame reaches the glass.
    /// Content set on a layer shows at the next vsync after its commit; the display link's target is that vsync. A second of no frames lets it go.
    private func startLink() {
        let l = CADisplayLink(target: LinkTarget { [weak self] l in self?.vsync(l) }, selector: #selector(LinkTarget.fire(_:)))
        let top = Float(UIScreen.main.maximumFramesPerSecond)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, top), maximum: top, preferred: top)
        l.add(to: .main, forMode: .common)
        link = l
        linkFresh = true
    }

    private func vsync(_ l: CADisplayLink) {
        // a link just made fires late the first time: its first call says nothing about when the frame showed
        if linkFresh { linkFresh = false; committed = nil }
        if let c = committed {
            committed = nil
            let glass = l.targetTimestamp, frame = (l.targetTimestamp - l.timestamp) * 1000
            q.async {
                if self.panel.count < 20000 { self.panel.append(frame) }
                guard let o = self.offset, self.agesGlass.count < 20000 else { return }
                self.agesGlass.append((glass + o - c.captured) * 1000)
                self.vsyncWait.append((glass - c.at) * 1000)
            }
        }
        if CACurrentMediaTime() - lastCommit > 1 {
            l.invalidate()
            link = nil
        }
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
            self.agesFirst = []; self.agesWhole = []; self.agesShown = []; self.agesGlass = []; self.vsyncWait = []; self.gaps = []; self.panel = []; self.cropLatency = []
            self.firstNacked = self.receiver.nacked; self.firstRepaired = self.receiver.repaired; self.firstRefreshes = self.receiver.refreshes
            self.frames = 0; self.bytes = 0; self.keyRequests = 0
            self.stageStart = CACurrentMediaTime()
            self.firstDropped = self.receiver.dropped
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
            var d: [String: Any] = ["stage": stage, "seconds": Int(t), "fps": Int(Double(self.frames) / t), "mbps": (Double(self.bytes) * 8 / t / 1e5).rounded() / 10,
                                    "age_p50": Self.pct(self.ages, 0.5), "age_p95": Self.pct(self.ages, 0.95), "age_max": Self.pct(self.ages, 1),
                                    "decode_p50": Self.pct(self.decodeMs, 0.5), "rtt_p50": Self.pct(self.probes, 0.5), "rtt_p95": Self.pct(self.probes, 0.95),
                                    "rtt_p99": Self.pct(self.probes, 0.99), "rtt_max": Self.pct(self.probes, 1), "probes": self.probes.count,
                                    "dropped": self.receiver.dropped - self.firstDropped, "key_requests": self.keyRequests, "clock_rtt": (self.bestRTT * 1e4).rounded() / 10]
            // where the time goes: first piece in, last piece in, decoded (age_*), on the layer, at the vsync it shows
            for (k, a) in [("first", self.agesFirst), ("whole", self.agesWhole), ("shown", self.agesShown), ("glass", self.agesGlass), ("vsync_wait", self.vsyncWait)] {
                d[k + "_p50"] = Self.pct(a, 0.5); d[k + "_p95"] = Self.pct(a, 0.95); d[k + "_max"] = Self.pct(a, 1)
            }
            d["panel_ms"] = Self.pct(self.panel, 0.5)
            if !self.cropLatency.isEmpty {
                d["crop_shown_p50"] = Self.pct(self.cropLatency, 0.5); d["crop_shown_p95"] = Self.pct(self.cropLatency, 0.95)
                d["crop_shown_max"] = Self.pct(self.cropLatency, 1); d["crop_shown_n"] = self.cropLatency.count
            }
            d["gap_p50"] = Self.pct(self.gaps, 0.5); d["gap_p95"] = Self.pct(self.gaps, 0.95); d["gap_p99"] = Self.pct(self.gaps, 0.99); d["gap_max"] = Self.pct(self.gaps, 1)
            // time spent waiting more than two frames for the next picture, per second
            let frozen: Double = self.gaps.filter { $0 > 40 }.reduce(0.0) { $0 + $1 - 17 }
            d["frozen_ms_per_s"] = (frozen / max(t, 1) * 10).rounded() / 10
            d["nacked"] = self.receiver.nacked - self.firstNacked
            d["fec_repaired"] = self.receiver.repaired - self.firstRepaired
            d["refreshes"] = self.receiver.refreshes - self.firstRefreshes
            d["repairs"] = self.repairs.sorted().joined(separator: ",")
            #if DEBUG
            d["weather_dropped"] = Self.weather.dropped
            #endif
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
        let env = ProcessInfo.processInfo.environment
        // BLURT_SCREEN_SIZE=1800x1100: a tier's size (ScreenPlan); the phone's own pixels otherwise
        let size = (env["BLURT_SCREEN_SIZE"] ?? "").split(separator: "x").compactMap { Int($0) }
        let w = size.count == 2 ? size[0] : Int(max(UIScreen.main.nativeBounds.width, UIScreen.main.nativeBounds.height))
        let h = size.count == 2 ? size[1] : Int(min(UIScreen.main.nativeBounds.width, UIScreen.main.nativeBounds.height))
        let bitrate = Int(env["BLURT_SCREEN_BITRATE"] ?? "") ?? 12_000_000
        let fps = Int(env["BLURT_SCREEN_FPS"] ?? "") ?? 60
        let seconds = Double(env["BLURT_SCREEN_SECONDS"] ?? "") ?? 12
        let s = ScreenStream.shared
        // BLURT_SCREEN_STAGES=zoom1,zoom2 for a shorter run; "off" stages measure the pointer's path alone
        var stages: [(String, Float?)] = [("off", nil), ("zoom1", 1), ("zoom2", 2), ("zoom3", 3), ("off-again", nil)]
        if let list = env["BLURT_SCREEN_STAGES"] {
            // zoomN: that zoom, still; panN: that zoom with the view moving 7 times a second, as a finger pans it
            stages = list.split(separator: ",").map { n in (String(n), n.hasPrefix("zoom") || n.hasPrefix("pan") ? Float(n.drop { !$0.isNumber }) ?? 1 : nil) }
        }
        if ProcessInfo.processInfo.environment["BLURT_RELAY_ONLY"] == "1" { return s.start() }
        s.probing(true)
        func step(_ i: Int) {
            guard i < stages.count else {
                s.probing(false)
                Link.shared.send(.screenStats("{\"stage\":\"done\"}"))
                return
            }
            let (name, zoom) = stages[i]
            if let zoom {
                s.start(RemoteScreenRequest(target: target, crop: .centered(zoom: zoom), width: w, height: h, bitrate: bitrate, fps: fps, features: ScreenStream.features))
            } else { s.stop() }
            var panning: Timer?
            if let zoom, name.hasPrefix("pan") {
                var k = 0
                panning = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
                    k += 1
                    var c = RemoteCrop.centered(zoom: zoom)
                    c.x = c.x * Float(1 + sin(Double(k) / 4)) ; c.y = c.y * Float(1 + cos(Double(k) / 5))
                    ScreenStream.shared.testCrop(c.valid)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {       // past the start-up
                s.beginStage()
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    panning?.invalidate()
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

/// A display link holds its target strongly: this breaks the cycle.
private final class LinkTarget: NSObject {
    let f: (CADisplayLink) -> Void
    init(_ f: @escaping (CADisplayLink) -> Void) { self.f = f }
    @objc func fire(_ l: CADisplayLink) { f(l) }
}
