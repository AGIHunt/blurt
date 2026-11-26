// Voice as Opus on Blurt's public relay (frame kind 9, docs/design/remote-go-between.md §The public relay): 20 ms packets of 16 kHz mono
// at about 32 kbps, instead of 256 kbps of PCM. Apple's own codec (AVAudioConverter), on the phone to encode and on the Mac to decode.
// The rest of the app keeps speaking PCM16: an encoder takes the same bytes the phone would send as kind 1, a decoder gives them back.
import AVFoundation

public enum RemoteOpus {
    public static let sampleRate: Double = 16000
    /// samples in one packet: 20 ms
    public static let frame = 320
    public static let bitRate = 32000

    static let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    static let opus: AVAudioFormat = {
        var d = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                            mFramesPerPacket: UInt32(frame), mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &d)!
    }()

    /// This device can encode and decode it (both are in the OS on iOS 17 / macOS 14 and later).
    public static var available: Bool { RemoteOpusEncoder() != nil && RemoteOpusDecoder() != nil }
}

/// PCM16 in, whole 20 ms Opus packets out; what's left over waits for the next call.
public final class RemoteOpusEncoder {
    private let converter: AVAudioConverter
    private var pending = Data()

    public init?() {
        guard let c = AVAudioConverter(from: RemoteOpus.pcm, to: RemoteOpus.opus) else { return nil }
        c.bitRate = RemoteOpus.bitRate
        converter = c
    }

    /// `pcm`: 16 kHz mono PCM16 little-endian, any length. Returns the packets it completes.
    public func encode(_ pcm: Data) -> [Data] {
        pending.append(pcm)
        var out: [Data] = []
        let bytes = RemoteOpus.frame * 2
        while pending.count >= bytes {
            let chunk = pending.prefix(bytes)
            pending.removeFirst(bytes)
            if let p = one(Data(chunk)) { out.append(p) }
        }
        return out
    }

    private func one(_ chunk: Data) -> Data? {
        guard let input = AVAudioPCMBuffer(pcmFormat: RemoteOpus.pcm, frameCapacity: AVAudioFrameCount(RemoteOpus.frame)) else { return nil }
        input.frameLength = AVAudioFrameCount(RemoteOpus.frame)
        chunk.withUnsafeBytes { src in _ = memcpy(input.int16ChannelData![0], src.baseAddress!, chunk.count) }
        let output = AVAudioCompressedBuffer(format: RemoteOpus.opus, packetCapacity: 1, maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
        var given = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, output.packetCount > 0, output.byteLength > 0 else { return nil }
        return Data(bytes: output.data, count: Int(output.byteLength))
    }
}

/// One Opus packet in, its 20 ms of PCM16 out.
public final class RemoteOpusDecoder {
    private let converter: AVAudioConverter

    public init?() {
        guard let c = AVAudioConverter(from: RemoteOpus.opus, to: RemoteOpus.pcm) else { return nil }
        converter = c
    }

    public func decode(_ packet: Data) -> Data? {
        guard !packet.isEmpty, packet.count < 1500 else { return nil }
        let input = AVAudioCompressedBuffer(format: RemoteOpus.opus, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { src in _ = memcpy(input.data, src.baseAddress!, packet.count) }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        guard let output = AVAudioPCMBuffer(pcmFormat: RemoteOpus.pcm, frameCapacity: AVAudioFrameCount(RemoteOpus.frame * 2)) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return Data(bytes: output.int16ChannelData![0], count: Int(output.frameLength) * 2)
    }
}
