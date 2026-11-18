// Debug builds only: `SIMCTL_CHILD_BLURT_DISPLAY_TEST=1` walks the display switcher against a real computer by itself, once connected,
// and says each step in the computer's log (`remote_screen_phone`, stage "display_test"), so screenshots can be taken at each one and
// the switch timed. With the test computer posting nothing (BLURT_TEST_COMMANDS=1), its pointer is a pretend one: following it across
// displays is tried without moving anybody's real pointer (docs/design/remote.md §Several displays).
#if DEBUG
import BlurtRemoteKit
import UIKit

enum DisplayTest {
    static var enabled: Bool { ProcessInfo.processInfo.environment["BLURT_DISPLAY_TEST"] == "1" }
    /// the pad, to turn the picture on and open the map as a finger would
    static weak var pad: PadViewController?
    private static var ran = false

    private static func say(_ step: String, _ extra: String = "") {
        Link.shared.send(.screenStats("{\"stage\":\"display_test\",\"step\":\"\(step)\"\(extra)}"))
    }

    static func run() {
        guard enabled, !ran, let pad else { return }
        ran = true
        let l = Link.shared
        var t = 0.0
        func at(_ wait: Double, _ f: @escaping () -> Void) {
            t += wait
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f)
        }
        at(1) { say("start", ",\"displays\":\(l.displays.count)"); pad.testShowing(true) }
        at(4) { say("following", ",\"shown\":\"\(l.shownDisplay ?? "")\"") }
        at(1) {
            pad.testMap(steps: nil)
            let m = pad.view.subviews.first { $0 is DisplayMap }
            say("map-held", ",\"map\":\"\(m.map { NSCoder.string(for: $0.frame) } ?? "none")\"")
        }
        at(3) { pad.testCloseMap() }
        // every display in turn, chosen
        for i in 1...max(1, l.displays.count) {
            at(1) {
                let next = l.displays.step(from: l.shownDisplay, by: 1)
                say("pick", ",\"to\":\"\(next?.id ?? "")\",\"n\":\(i)")
                if let n = next { l.showDisplay(n.id) }
            }
            at(4) { say("pinned", ",\"shown\":\"\(l.shownDisplay ?? "")\",\"n\":\(i)") }
        }
        // a slide one step along, as a thumb would, with the map up
        at(1) { pad.testMap(steps: 1); say("map-slide") }
        at(3) { pad.testCloseMap(commit: true); say("slid") }
        at(4) { say("pinned-after-slide", ",\"shown\":\"\(l.shownDisplay ?? "")\"") }
        // follow again: the pointer is in the middle of the one shown; strokes take it across to the next one
        at(1) { l.showDisplay(nil); say("follow") }
        at(2) { stroke(toward: l.displays.step(from: l.shownDisplay, by: 1)) }
        at(4) { say("crossed", ",\"shown\":\"\(l.shownDisplay ?? "")\"") }
        at(1) { stroke(toward: l.displays.step(from: l.shownDisplay, by: 1)) }
        at(4) { say("crossed-again", ",\"shown\":\"\(l.shownDisplay ?? "")\"") }
        at(1) { say("done") }
    }

    /// Pointer strokes from the middle of the display shown towards another's middle, until it's well onto it: 40 pt at a time, 60 a second.
    private static func stroke(toward d: RemoteDisplay?) {
        let l = Link.shared
        guard let d, let from = l.displays.first(where: { $0.id == l.shownDisplay }) else { return }
        let dx = d.middle.x - from.middle.x, dy = d.middle.y - from.middle.y
        let n = Int(max(abs(dx), abs(dy)) / 40) + 1
        say("stroke", ",\"to\":\"\(d.id)\",\"moves\":\(n)")
        for i in 0..<n {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / 60) {
                l.pointer(.move(dx: Float(dx) / Float(n), dy: Float(dy) / Float(n)))
                ScreenStream.shared.predict(dx: Float(dx) / Float(n), dy: Float(dy) / Float(n))
            }
        }
    }
}
#endif
