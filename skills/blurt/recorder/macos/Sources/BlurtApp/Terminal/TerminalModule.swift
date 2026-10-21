// P3 (mac-terminal) owns Terminal/: the embedded SwiftTerm terminal, the session list, the dispatch panel and the
// finish actions. install() sets AppEnvironment.terminal and AppEnvironment.dispatch.
//
// G0 stub (docs/design/next-round.md "所有权、闸门和合并"): sets nothing yet.
import AppKit

enum TerminalModule {
    static func install() {}
}
