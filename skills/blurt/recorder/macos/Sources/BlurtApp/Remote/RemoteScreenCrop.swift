// The part of the screen the phone is looking at, cut out of the whole display here rather than by ScreenCaptureKit
// (docs/design/remote-realtime.md §Crops without waiting). ScreenCaptureKit takes a new `sourceRect` a frame or several later and doesn't
// say which frame has it, so frames waited out every change: 24 ms each, a third of the frames while panning. Zoomed in, the display now
// comes at its own pixels and each frame is cropped and scaled to the output size on the GPU (VTPixelTransferSession, about 1.4 ms for a
// 3024×1890 frame on an M5 Max): a new crop applies to the very next frame, or at once to the last one, and every frame says exactly which
// part it shows. The whole view still comes at the output size, scaled by ScreenCaptureKit, which costs nothing extra.
import BlurtRemoteKit
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class ScreenCropper {
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize = (w: 0, h: 0)

    /// `c` of `src`, scaled to w × h (the encoder's size), NV12 like the source. nil if the GPU couldn't.
    func crop(_ src: CVPixelBuffer, _ c: RemoteCrop, width w: Int, height h: Int) -> CVPixelBuffer? {
        if session == nil {
            var s: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s) == noErr, let s else { return nil }
            VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_CropSourceToCleanAperture)
            VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
            session = s
        }
        if pool == nil || poolSize != (w, h) {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                          kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h, kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary, attrs as CFDictionary, &p)
            pool = p
            poolSize = (w, h)
        }
        guard let session, let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == noErr, let out else { return nil }
        let W = Double(CVPixelBufferGetWidth(src)), H = Double(CVPixelBufferGetHeight(src))
        // whole pixels, even ones: 4:2:0 chroma comes in pairs
        func even(_ v: Double) -> Double { (v / 2).rounded() * 2 }
        let cw = max(2, even(Double(c.w) * W)), ch = max(2, even(Double(c.h) * H))
        let cx = min(W - cw, even(Double(c.x) * W)), cy = min(H - ch, even(Double(c.y) * H))
        let aperture: [CFString: Any] = [kCVImageBufferCleanApertureWidthKey: cw, kCVImageBufferCleanApertureHeightKey: ch,
                                         kCVImageBufferCleanApertureHorizontalOffsetKey: cx + cw / 2 - W / 2,
                                         kCVImageBufferCleanApertureVerticalOffsetKey: cy + ch / 2 - H / 2]
        CVBufferSetAttachment(src, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldNotPropagate)
        let st = VTPixelTransferSessionTransferImage(session, from: src, to: out)
        // the source may be encoded as it is later (whole view, same size): no crop may stick to it
        CVBufferRemoveAttachment(src, kCVImageBufferCleanApertureKey)
        guard st == noErr else { return nil }
        // the colour the encoder needs to know (matrix, primaries, transfer), never the crop
        for k in [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey] {
            if let v = CVBufferCopyAttachment(src, k, nil) { CVBufferSetAttachment(out, k, v, .shouldPropagate) }
        }
        return out
    }

    func reset() {
        if let s = session { VTPixelTransferSessionInvalidate(s) }
        session = nil
        pool = nil
    }
}
