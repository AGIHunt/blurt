// The picture's decoder, shared by the iPhone / iPad app and the Mac viewer (docs/design/remote-desktop-viewer.md): whole frames in, pictures
// out through VideoToolbox, HEVC or H.264 as the host sends. Moved here from apps/ios ScreenStream.swift unchanged.
import CoreMedia
import Foundation
import VideoToolbox

/// Whole frames in, pictures out, through the hardware decoder. A keyframe's parameter sets make the decoder (HEVC: VPS, SPS, PPS; H.264: SPS,
/// PPS), and say which codec they are, so a frame that comes before the word on which codec it is still decodes.
public final class RemoteScreenDecoder {
    public init() {}
    /// what the computer said it sends (screenView.codec)
    public private(set) var codec = RemoteVideoCodec.hevc
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    public var ready: Bool { session != nil && format != nil }

    public func reset() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        format = nil
    }

    /// The codec the computer says comes next (nil: HEVC, as from Macs before 1.0.15). True when it's another one than before: the decoder
    /// has gone, and the frames on their way can't be decoded until a keyframe.
    @discardableResult public func told(_ c: String?) -> Bool {
        let c = c ?? RemoteVideoCodec.hevc
        guard c != codec else { return false }
        codec = c
        reset()
        return true
    }

    /// One whole frame. `out` gets the picture and the part of the screen it shows, from VideoToolbox's thread; a status other than noErr
    /// means nothing after it decodes until a keyframe. False: nothing to decode it with yet (no keyframe so far).
    @discardableResult public func decode(_ f: RemoteVideoAssembler.Frame, out: @escaping (OSStatus, CVImageBuffer?, RemoteCrop) -> Void) -> Bool {
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
