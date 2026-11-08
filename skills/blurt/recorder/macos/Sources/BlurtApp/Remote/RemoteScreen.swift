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
    private static let settled = 1500
    var onInfo: ((ToPhone) -> Void)?
    /// capture ended by itself
    var onStopped: (() -> Void)?

    func start(_ asked: RemoteScreenRequest, failed: @escaping (String) -> Void) {
        // what the phone asks for, within reason: a number out of range mustn't trap
        var r = asked
        r.fps = min(max(r.fps, 1), 120)
        r.width = min(max(r.width, 64), 8192)
        r.height = min(max(r.height, 64), 8192)
        r.bitrate = min(max(r.bitrate, 100_000), 50_000_000)
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let filter: SCContentFilter, src: CGRect, scale: CGFloat
                if r.target == "window" {
                    guard let w = content.windows.first(where: { $0.title == "Blurt Screen Test" }) else { return failed("no_test_window") }
                    filter = SCContentFilter(desktopIndependentWindow: w)
                    src = w.frame
                    scale = 2
                } else {
                    let m = CGEvent(source: nil)?.location ?? .zero
                    guard let d = content.displays.first(where: { $0.frame.contains(m) }) ?? content.displays.first else { return failed("no_display") }
                    filter = SCContentFilter(display: d, excludingWindows: [])
                    src = d.frame
                    scale = NSScreen.screens.first { $0.frame.width == d.frame.width }?.backingScaleFactor ?? 2
                }
                let c = SCStreamConfiguration()
                // the source's shape, as large as the phone asked for and no larger than the source has pixels
                let k = min(CGFloat(r.width) / src.width, CGFloat(r.height) / src.height, scale)
                let w = Int(src.width * k) / 2 * 2, h = Int(src.height * k) / 2 * 2
                c.width = w
                c.height = h
                c.scalesToFit = true
                c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, r.fps)))
                c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                c.queueDepth = 5    // one is kept as the last image
                c.showsCursor = false
                c.capturesAudio = false
                relayed = channel.isRelay
                if q.sync(execute: { stopped }) { return }      // turned off while this was starting
                q.sync {
                    self.source = src
                    self.crop = (self.requestedCrop ?? r.crop).valid
                    self.frameCrop = self.crop
                    self.config = c
                    c.sourceRect = self.rect(self.crop)
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
                }
                emit(["event": "remote_screen", "state": "on", "target": r.target, "crop": Double(r.crop.w), "width": w, "height": h, "bitrate": r.bitrate])
            } catch {
                emit(["event": "remote_screen", "state": "failed", "why": "\(error)"])
                // the one the user can do something about
                failed((error as NSError).code == -3801 ? "permission" : "\(error)")
            }
        }
    }

    private func pointer() -> CGPoint {
        let p = CGEvent(source: nil)?.location ?? .zero
        return CGPoint(x: p.x - source.minX, y: p.y - source.minY)
    }

    private func rect(_ c: RemoteCrop) -> CGRect {
        CGRect(x: CGFloat(c.x) * source.width, y: CGFloat(c.y) * source.height, width: CGFloat(c.w) * source.width, height: CGFloat(c.h) * source.height)
    }

    func setCrop(_ c: RemoteCrop) {
        q.async {
            let c = c.valid
            guard self.running, let config = self.config, let s = self.stream else { self.requestedCrop = c; return }
            guard c != self.crop else { return }
            self.crop = c
            config.sourceRect = self.rect(c)
            self.cropsUnderWay += 1
            s.updateConfiguration(config) { [weak self] error in
                self?.q.async { self?.cropDone(c, failed: error != nil) }
            }
        }
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
        onInfo?(.screenView(width: source.width, height: source.height))
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
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        wantKey = true
        emit(["event": "remote_screen", "state": "encoder", "low_latency": lowLatency])
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer b: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, running, let session, b.isValid, let image = CMSampleBufferGetImageBuffer(b) else { return }
        // a frame with nothing new: skipped by SCK, which is why a still screen costs nothing
        if let a = CMSampleBufferGetSampleAttachmentsArray(b, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = a.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete { skipped += 1; return }
        let pts = CMSampleBufferGetPresentationTimeStamp(b)
        // ScreenCaptureKit doesn't always say so: a window that isn't changing still comes as complete frames, at full rate
        if let l = lastImage, Self.same(l, image) { skipped += 1; return }
        let now = CACurrentMediaTime()
        lastImage = image
        lastPTS = pts
        lastFrameAt = now
        refines = 0
        if cropsUnderWay > 0 {
            heldImage = (image, pts)
            return
        }
        lastImageCrop = frameCrop
        // before the frame gets a number: a gap in the numbers costs a keyframe
        if channel.streamBusy || holdingBack() { busySkips += 1; skipped += 1; return }
        if now - lastEncodedAt < frameGap - 0.003 || now < pacedUntil { skipped += 1; return }
        encode(image, pts: pts, captured: CMTimeGetSeconds(pts), crop: lastImageCrop)
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
        var props: CFDictionary?
        if wantKey {
            wantKey = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: .invalid, frameProperties: props,
                                        infoFlagsOut: nil) { [weak self] st, _, sample in
            guard st == noErr, let sample, let self else { return }
            self.q.async { self.send(sample, captured: captured, crop: crop, encodeStart: t0) }
        }
    }

    private func send(_ b: CMSampleBuffer, captured: Double, crop: RemoteCrop, encodeStart: Double) {
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
        let pieces = RemoteVideoPacket.split(body, frame: Self.frameID, keyframe: key, captured: captured, payload: whole ? max(body.count, 1) : RemoteVideoPacket.payloadSize)
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
            for p in pieces { channel.sendDatagram(.video, p.encoded()) }
        }
        lastFrameBytes = body.count
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
            emit(["event": "remote_screen_mac", "fps": Int(Double(encoded) / s), "kbps": Int(Double(bytes) * 8 / s / 1000),
                  "encode_ms": encoded > 0 ? (encodeMs / Double(encoded) * 10).rounded() / 10 : 0, "keyframes": keyframes, "idle_frames": skipped])
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
