import XCTest
import AVFoundation
import BlurtObjC

/// BlurtTry turns the Objective-C exceptions AVFoundation raises into an error instead of an abort (the 2026-10-26
/// crash: a mic tap whose format no longer matched the input hardware).
final class BlurtTryTests: XCTestCase {
    func testAnExceptionComesBackAsAnError() {
        var err: NSError?
        let ok = BlurtTry({ NSException(name: .invalidArgumentException, reason: "required condition is false", userInfo: nil).raise() }, &err)
        XCTAssertFalse(ok)
        XCTAssertEqual(err?.domain, "BlurtObjCException")
        XCTAssertEqual(err?.userInfo["reason"] as? String, "required condition is false")
    }

    func testABlockThatRunsIsYes() {
        var ran = false
        var err: NSError?
        XCTAssertTrue(BlurtTry({ ran = true }, &err))
        XCTAssertTrue(ran)
        XCTAssertNil(err)
    }

    /// The real case: a tap twice on one bus is refused by AVFoundation with an exception (no microphone is opened —
    /// the engine is never started).
    func testASecondTapOnTheSameBusIsCaught() {
        let player = AVAudioPlayerNode()
        let e = AVAudioEngine()
        e.attach(player)
        e.connect(player, to: e.mainMixerNode, format: nil)
        let f = e.mainMixerNode.outputFormat(forBus: 0)
        var err: NSError?
        XCTAssertTrue(BlurtTry({ e.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: f) { _, _ in } }, &err))
        XCTAssertFalse(BlurtTry({ e.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: f) { _, _ in } }, &err))
        XCTAssertNotNil(err)
        e.mainMixerNode.removeTap(onBus: 0)
    }
}
