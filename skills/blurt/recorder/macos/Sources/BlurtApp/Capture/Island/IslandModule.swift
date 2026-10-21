// P5 (mac-capture) owns Capture/Island/: the notch island, the claw cards, voice input and the project switcher.
// install() sets AppEnvironment.island.
//
// G0 stub (docs/design/next-round.md "所有权、闸门和合并"): sets nothing yet.
import AppKit

enum IslandModule {
    static func install() {}
}
