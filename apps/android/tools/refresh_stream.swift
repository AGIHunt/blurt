// Makes the streams RefreshDecodeTest decodes on a phone (app/src/androidTest/assets/refresh-*.bin): what a Mac host sends after a loss
// with `ltr` (docs/design/remote-realtime.md §2). VideoToolbox in low-latency mode, LTR on, synthetic terminal text scrolling 2 px a frame;
// the phone acknowledges what it decodes, frames 30…33 never arrive, frame 34 is a refresh from an acknowledged frame (ForceLTRRefresh).
// "skip" is the same without the refresh: what a decoder makes of frames whose references are gone, to show the test can tell.
//
//   swiftc -O tools/refresh_stream.swift -o /tmp/refresh_stream && /tmp/refresh_stream app/src/androidTest/assets
//
// File: per frame, u32 BE length of what follows the header, u8 flags (bit 0 keyframe, bit 1 refresh), u32 BE frame number, then the
// frame in Annex B (parameter sets first on a keyframe). The picture is a function of the frame number, so the test draws it too.
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

let W = 640, H = 400
let lost = 30...33, total = 60

func luma(_ x: Int, _ r: Int) -> UInt8 {
    let line = r / 18, inLine = r % 18
    let glyph = (x / 9 + line * 7) % 13
    return (inLine > 3 && inLine < 15 && glyph < 8 && ((x * 31 + r * 17 + line) % 5 != 0)) ? 220 : 24
}

func frame(_ i: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
    let p = pb!
    CVPixelBufferLockBaseAddress(p, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(p, 0)!.assumingMemoryBound(to: UInt8.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(p, 0)
    let off = (i * 2) % (H * 2)
    for r in 0..<H { for x in 0..<W { y[r * ys + x] = luma(x, r + off) } }
    memset(CVPixelBufferGetBaseAddressOfPlane(p, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(p, 1) * H / 2)
    CVPixelBufferUnlockBaseAddress(p, [])
    return p
}

func annexB(_ sb: CMSampleBuffer, key: Bool, hevc: Bool) -> Data {
    var out = Data()
    let start = Data([0, 0, 0, 1])
    if key, let f = CMSampleBufferGetFormatDescription(sb) {
        var n = 0
        if hevc { CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(f, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &n, nalUnitHeaderLengthOut: nil) }
        else { CMVideoFormatDescriptionGetH264ParameterSetAtIndex(f, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &n, nalUnitHeaderLengthOut: nil) }
        for i in 0..<n {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            if hevc { CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(f, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) }
            else { CMVideoFormatDescriptionGetH264ParameterSetAtIndex(f, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) }
            out += start + Data(bytes: ptr!, count: size)
        }
    }
    let block = CMSampleBufferGetDataBuffer(sb)!
    var length = 0
    var base: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &base)
    let d = Data(bytes: base!, count: length)
    var at = 0
    while at + 4 <= d.count {
        let n = d[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
        out += start + d[(at + 4)..<(at + 4 + n)]
        at += 4 + n
    }
    return out
}

func make(hevc: Bool, refresh: Bool) -> Data {
    var enc: VTCompressionSession?
    let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
    precondition(VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                            refcon: nil, compressionSessionOut: &enc) == noErr)
    let e = enc!
    VTSessionSetProperty(e, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(e, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(e, key: kVTCompressionPropertyKey_ProfileLevel, value: hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
    VTSessionSetProperty(e, key: kVTCompressionPropertyKey_AverageBitRate, value: 3_000_000 as CFNumber)
    VTSessionSetProperty(e, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
    VTSessionSetProperty(e, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 600 as CFNumber)
    precondition(VTSessionSetProperty(e, key: kVTCompressionPropertyKey_EnableLTR, value: kCFBooleanTrue) == noErr, "no LTR")
    var file = Data()
    var newlyAcked: [Int] = []
    var refreshes = 0
    for i in 0..<total {
        var props: [CFString: Any] = [:]
        if i == 0 { props[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        if !newlyAcked.isEmpty { props[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = newlyAcked; newlyAcked = [] }
        let recover = refresh && i == lost.upperBound + 1
        if recover { props[kVTEncodeFrameOptionKey_ForceLTRRefresh] = true; refreshes += 1 }
        let sem = DispatchSemaphore(value: 0)
        var out: CMSampleBuffer?
        VTCompressionSessionEncodeFrame(e, imageBuffer: frame(i), presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 60), duration: .invalid,
                                        frameProperties: props.isEmpty ? nil : props as CFDictionary, infoFlagsOut: nil) { _, _, sb in out = sb; sem.signal() }
        VTCompressionSessionCompleteFrames(e, untilPresentationTimeStamp: .invalid)
        sem.wait()
        guard let sb = out else { continue }
        let a = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?.first ?? [:]
        let key = !((a[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        if lost.contains(i) { continue }          // never arrived, never acknowledged
        // the phone decodes it and, if asked, acknowledges it
        if let token = a[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? Int { newlyAcked.append(token) }
        let body = annexB(sb, key: key, hevc: hevc)
        var head = Data()
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { head += $0 }
        head.append((key ? 1 : 0) | (recover ? 2 : 0))
        withUnsafeBytes(of: UInt32(i).bigEndian) { head += $0 }
        file += head + body
        if recover { print(hevc ? "hevc" : "h264", "refresh frame \(i): \(body.count) bytes, keyframe \(key)") }
    }
    VTCompressionSessionInvalidate(e)
    return file
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for hevc in [true, false] {
    for refresh in [true, false] {
        let name = "refresh-\(hevc ? "hevc" : "h264")-\(refresh ? "ltr" : "skip").bin"
        let d = make(hevc: hevc, refresh: refresh)
        try d.write(to: dir.appendingPathComponent(name))
        print(name, d.count, "bytes")
    }
}
