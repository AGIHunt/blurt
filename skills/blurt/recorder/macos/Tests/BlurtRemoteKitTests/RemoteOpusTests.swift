// Voice as Opus for the public relay (RemoteOpus): what goes in comes back out close to it, at about 32 kbps.
import XCTest
@testable import BlurtRemoteKit

final class RemoteOpusTests: XCTestCase {
    /// one second of a 440 Hz tone with a little speech-like wobble, PCM16 at 16 kHz
    private func tone(_ seconds: Double = 1) -> Data {
        var d = Data()
        for i in 0..<Int(16000 * seconds) {
            let t = Double(i) / 16000
            let v = 0.4 * sin(2 * .pi * 440 * t) * (0.6 + 0.4 * sin(2 * .pi * 3 * t))
            withUnsafeBytes(of: Int16(v * 32767).littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }

    func testRoundTripAtAbout32kbps() throws {
        guard let enc = RemoteOpusEncoder(), let dec = RemoteOpusDecoder() else { throw XCTSkip("no Opus on this OS") }
        let pcm = tone()
        // in uneven pieces, as the microphone gives them
        var packets: [Data] = []
        var i = 0
        for n in [1000, 77, 4096, 640, 10000] + Array(repeating: 2000, count: 20) where i < pcm.count {
            packets += enc.encode(pcm.subdata(in: i..<min(pcm.count, i + n)))
            i += n
        }
        XCTAssertEqual(packets.count, pcm.count / (RemoteOpus.frame * 2), "one packet per 20 ms")
        let bytes = packets.reduce(0) { $0 + $1.count }
        XCTAssertLessThan(Double(bytes * 8), 40000, "about 32 kbps: \(bytes * 8) bits for 1 s")
        var out = Data()
        for p in packets { out += try XCTUnwrap(dec.decode(p)) }
        // the first packet gives back a little less (the codec's look-ahead)
        XCTAssertEqual(Double(out.count), Double(pcm.count), accuracy: Double(RemoteOpus.frame * 2))
        // the tone's energy comes back (Opus delays a few ms: compare loudness, not samples)
        func rms(_ d: Data) -> Double {
            d.withUnsafeBytes { b in let s = b.bindMemory(to: Int16.self); return sqrt(s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(s.count)) }
        }
        XCTAssertEqual(rms(out.suffix(16000)) / rms(pcm.suffix(16000)), 1, accuracy: 0.25)
    }

    func testGarbageIsNotAPacket() {
        guard let dec = RemoteOpusDecoder() else { return }
        XCTAssertNil(dec.decode(Data()))
        XCTAssertNil(dec.decode(Data(count: 4000)))
    }
}
