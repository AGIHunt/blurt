import BlurtRemoteKit
import CoreVideo
import XCTest
@testable import BlurtRemote

/// Real streams from ffmpeg (Fixtures/testsrc.*, 320×180, 12 frames, a keyframe every 6, no B-frames), turned into what a host sends: NAL units
/// with 4-byte lengths, a keyframe's parameter sets beside its picture, cut into datagrams. Made with
///   ffmpeg -f lavfi -i testsrc=size=320x180:rate=30 -frames:v 12 -c:v libx264 -preset veryfast -tune zerolatency -bf 0 -g 6 -pix_fmt yuv420p \
///     -bsf:v h264_mp4toannexb -f h264 testsrc.h264
///   ffmpeg -f lavfi -i testsrc=size=320x180:rate=30 -frames:v 12 -c:v libx265 -x265-params bframes=0:keyint=6:min-keyint=6 -pix_fmt yuv420p \
///     -bsf:v hevc_mp4toannexb -f hevc testsrc.hevc
final class ScreenDecoderTests: XCTestCase {
    private struct Picture { var sets: [Data]; var nals: [Data]; var key: Bool }

    /// Annex B (00 00 01 start codes) to NAL units.
    private func nals(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var starts: [(at: Int, code: Int)] = []
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { starts.append((i + 3, i > 0 && b[i - 1] == 0 ? 4 : 3)); i += 3 } else { i += 1 }
        }
        return starts.enumerated().map { n, s in
            let end = n + 1 < starts.count ? starts[n + 1].at - starts[n + 1].code : b.count
            return Data(b[s.at..<end])
        }
    }

    /// NAL units to pictures, the way a host groups them: parameter sets kept for the keyframe, SEI and delimiters left out, a picture's slices together.
    private func pictures(_ file: String, h264: Bool) throws -> [Picture] {
        var out: [Picture] = [], sets: [Data] = []
        for n in nals(try Data(contentsOf: fixtures.appendingPathComponent(file))) {
            let type = h264 ? Int(n[0] & 0x1F) : Int(n[0] >> 1 & 0x3F)
            let isSet = h264 ? type == 7 || type == 8 : (32...34).contains(type)
            let isSlice = h264 ? type == 1 || type == 5 : type < 32
            if isSet { sets.append(n); continue }
            guard isSlice else { continue }
            let key = h264 ? type == 5 : (16...21).contains(type)
            // first_mb_in_slice == 0 (H.264), first_slice_segment_in_pic_flag (HEVC): the first bit after the header
            let first = (h264 ? n[1] : n[2]) & 0x80 != 0
            if first || out.isEmpty {
                out.append(Picture(sets: key ? sets : [], nals: [n], key: key))
                if key { sets = [] }
            } else {
                out[out.count - 1].nals.append(n)
            }
        }
        return out
    }

    private func lengthPrefixed(_ nals: [Data]) -> Data {
        var d = Data()
        for n in nals { withUnsafeBytes(of: UInt32(n.count).bigEndian) { d.append(contentsOf: $0) }; d.append(n) }
        return d
    }

    /// Each picture as datagrams through the assembler, then the decoder, as ScreenStream does. The sizes of what came out, in order.
    private func run(_ pics: [Picture], through decoder: ScreenDecoder, from frame: UInt32 = 1, skip: Set<Int> = []) -> [CGSize] {
        var assembler = RemoteVideoAssembler()
        var sizes: [CGSize] = []
        let lock = NSLock()
        for (i, p) in pics.enumerated() where !skip.contains(i) {
            let payload = RemoteVideoPayload.pack(crop: .whole, parameterSets: p.sets, picture: lengthPrefixed(p.nals))
            for piece in RemoteVideoPacket.split(payload, frame: frame + UInt32(i), keyframe: p.key, captured: 0) {
                guard let f = assembler.add(RemoteVideoPacket(piece.encoded())!) else { continue }
                decoder.decode(f) { st, image, _ in
                    guard st == noErr, let image else { return }
                    lock.lock(); sizes.append(CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))); lock.unlock()
                }
            }
        }
        // a real-time session may hand pictures back a moment later
        let until = Date().addingTimeInterval(3)
        while Date() < until { lock.lock(); let n = sizes.count; lock.unlock(); if n >= pics.count - skip.count { break }; RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        lock.lock(); defer { lock.unlock() }
        return sizes
    }

    func testFixturesAreWhatTheySay() throws {
        let h = try pictures("testsrc.h264", h264: true), e = try pictures("testsrc.hevc", h264: false)
        XCTAssertEqual(h.count, 12)
        XCTAssertEqual(e.count, 12)
        XCTAssertEqual(h.filter(\.key).count, 2)
        XCTAssertEqual(h[0].sets.count, 2)
        XCTAssertEqual(e[0].sets.count, 3)
        XCTAssertEqual(RemoteVideoCodec.of(parameterSets: h[0].sets), RemoteVideoCodec.h264)
        XCTAssertEqual(RemoteVideoCodec.of(parameterSets: e[0].sets), RemoteVideoCodec.hevc)
    }

    /// A Windows or Linux host: it says h264, and every frame decodes.
    func testH264Decodes() throws {
        let d = ScreenDecoder()
        XCTAssertTrue(d.told(RemoteVideoCodec.h264))
        let out = run(try pictures("testsrc.h264", h264: true), through: d)
        XCTAssertEqual(out.count, 12)
        XCTAssertTrue(out.allSatisfy { $0 == CGSize(width: 320, height: 180) }, "\(out)")
    }

    /// A Mac, before 1.0.15 or since: HEVC, as it always was.
    func testHEVCStillDecodes() throws {
        let d = ScreenDecoder()
        XCTAssertFalse(d.told(nil))
        let out = run(try pictures("testsrc.hevc", h264: false), through: d)
        XCTAssertEqual(out.count, 12)
        XCTAssertTrue(out.allSatisfy { $0 == CGSize(width: 320, height: 180) }, "\(out)")
    }

    /// The word on the codec came late, or never: the keyframe's own parameter sets say it's H.264.
    func testH264DecodesBeforeTheHostSaysSo() throws {
        let d = ScreenDecoder()
        let out = run(try pictures("testsrc.h264", h264: true), through: d)
        XCTAssertEqual(out.count, 12)
        XCTAssertEqual(d.codec, RemoteVideoCodec.h264)
        XCTAssertFalse(d.told(RemoteVideoCodec.h264), "the word that follows changes nothing")
    }

    /// One stream after another of another kind, as switching from a Mac to a PC: the decoder starts over, nothing of the first is used.
    func testCodecSwitchStartsOver() throws {
        let d = ScreenDecoder()
        XCTAssertEqual(run(try pictures("testsrc.hevc", h264: false), through: d).count, 12)
        XCTAssertTrue(d.told(RemoteVideoCodec.h264))
        XCTAssertFalse(d.ready, "the HEVC decoder is gone")
        let h = try pictures("testsrc.h264", h264: true)
        // frames before a keyframe have nothing to decode with
        var a = RemoteVideoAssembler()
        let lone = RemoteVideoPayload.pack(crop: .whole, parameterSets: [], picture: lengthPrefixed(h[1].nals))
        let f = try XCTUnwrap(RemoteVideoPacket.split(lone, frame: 1, keyframe: true, captured: 0).compactMap { a.add($0) }.first)
        XCTAssertFalse(d.decode(f) { _, _, _ in XCTFail("decoded with the old decoder") })
        XCTAssertEqual(run(h, through: d, from: 100).count, 12)
        XCTAssertTrue(d.told(RemoteVideoCodec.hevc))
        XCTAssertEqual(run(try pictures("testsrc.hevc", h264: false), through: d, from: 200).count, 12)
    }

    /// A lost piece: the assembler holds everything back until the next keyframe, as before, so the decoder only sees what it can use.
    func testLostFrameWaitsForTheNextKeyframe() throws {
        let d = ScreenDecoder()
        _ = d.told(RemoteVideoCodec.h264)
        let out = run(try pictures("testsrc.h264", h264: true), through: d, skip: [2])
        XCTAssertEqual(out.count, 8, "frames 0, 1, then 6…11 after the keyframe")
    }
}
