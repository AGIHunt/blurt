// The Mac's screen, to the phone (docs/design/remote.md §Screen). ScreenCaptureKit → VideoToolbox HEVC, low latency, no frame
// reordering → datagrams. Off unless the phone asks, and nothing is captured while off. Nothing here is written to disk.
//
//  • the pointer isn't in the video. Its position goes separately, 60 times a second, and the phone draws it, so it's never a frame
//    late; its shape goes when it changes.
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
    var onInfo: ((ToPhone) -> Void)?
    /// capture ended by itself
    var onStopped: (() -> Void)?

    func start(_ r: RemoteScreenRequest, failed: @escaping (String) -> Void) {
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
                c.queueDepth = 3
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
                    self.makeEncoder(w, h, r.bitrate, fps: r.fps)
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
        guard cropsUnderWay == 0, let h = heldImage else { return }
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
        if p != lastCursor || tick % max(1, fps / 2) == 0 {
            lastCursor = p
            var v: [Float] = [Float(p.x / source.width), Float(p.y / source.height)]
            channel.sendDatagram(.cursor, Data(bytes: &v, count: 8))
        }
        if tick % max(1, fps / 4) == 0 { checkShape() }
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
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
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
        if channel.streamBusy { skipped += 1; return }      // before the frame gets a number: a gap in the numbers costs a keyframe
        lastImage = image
        lastPTS = pts
        lastFrameAt = CACurrentMediaTime()
        if cropsUnderWay > 0 {
            heldImage = (image, pts)
            return
        }
        lastImageCrop = frameCrop
        encode(image, pts: pts, captured: CMTimeGetSeconds(pts), crop: lastImageCrop)
    }

    private func encode(_ image: CVImageBuffer, pts: CMTime, captured: Double, crop: RemoteCrop) {
        guard let session else { return }
        let t0 = CACurrentMediaTime()
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
        for p in RemoteVideoPacket.split(body, frame: Self.frameID, keyframe: key, captured: captured, payload: whole ? max(body.count, 1) : RemoteVideoPacket.payloadSize) {
            channel.sendDatagram(.video, p.encoded())
        }
        encoded += 1
        bytes += body.count
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
            self.wantKey = true
            guard self.running, let i = self.lastImage, CACurrentMediaTime() - self.lastFrameAt > 0.1 else { return }
            self.lastPTS = CMTimeAdd(self.lastPTS, CMTime(value: 1, timescale: 600))
            self.encode(i, pts: self.lastPTS, captured: CACurrentMediaTime(), crop: self.lastImageCrop)
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
        Task { try? await s?.stopCapture() }
        emit(["event": "remote_screen", "state": "off"])
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        emit(["event": "remote_screen", "state": "stopped", "why": "\(error)"])
        onInfo?(.screenFailed("stopped"))
        onStopped?()
    }
}
