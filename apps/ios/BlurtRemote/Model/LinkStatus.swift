// What the pad says about the connection, worked out apart from the views so it can be tested, and so both phones say the same thing in the
// same order (Android: core/LinkStatus.kt, the same table). docs/design/remote.md §Connection, "What the pad says".
//
// The rule: connected and working, the pad says nothing (the computer's name, small, in its corner). In every other state one card in the
// middle of the pad says it at reading size: a mark, a strong line that names the state, at most one line with the one thing to do, and at
// most one button for it.
import Foundation

/// The connection as the pad needs to know it. Nothing here comes from the wire that Link doesn't already publish.
struct LinkStatus: Equatable {
    enum Phase: Equatable { case unpaired, connecting, unreachable, connected, forgotten, replaced, ended }

    var phase: Phase
    /// a session was up and went while the app was in use: it's coming back, not starting (StatusFollower)
    var dropped = false
    /// the computer in hand has a relay: it can be anywhere, so "the same network" isn't the thing to check
    var hasRelay = false
    /// more than one computer is paired: there's another to try
    var otherComputers = false
    var canControl = true
    /// "permission", "off": why the computer won't show its screen
    var screenError: String?
    /// the computer is asking its owner about this phone's code
    var waiting = false
    /// a pairing just didn't take; Link has the sentences
    var pairFailed = false
    /// the code that didn't take can still work (it couldn't be reached, and is still being tried): Try Again
    var pairRetry = false
    /// Blurt's go-between couldn't carry the session (docs/design/remote-go-between.md): this network won't connect directly, or the
    /// go-between is busy today
    var away: Away?

    /// `relayDown`: the computer's own relay doesn't answer; the public connection service is tried meanwhile (2026-11-20, the office)
    enum Away: Equatable { case noDirect, busy, relayDown }
}

struct StatusBanner: Equatable {
    /// what's drawn beside the words: a state is never told by colour alone
    enum Mark: Equatable { case busy, problem, phone, code }

    enum Line: Equatable {
        case connecting, reconnecting
        case cantReach, checkNetwork, checkAwake
        /// the go-between: the direct path wouldn't open here / the free quota is spent for today
        case noDirect, goBetweenBusy, relayDown
        case needsPairing, forgotten
        case otherPhone, touchToTakeOver
        case endedThere, touchToReconnect
        case pairFirst, whereTheCodeIs
        case waiting, allowOnComputer
        case pairingFailed, whyPairingFailed
        case cantControl, howToAllowControl
        case cantShowScreen, allowScreen, screenIsOff
    }

    enum Action: Equatable { case retry, scan, another }

    var mark: Mark
    var title: Line
    var detail: Line?
    var action: Action?
    var second: Action?

    /// nil: connected and working, nothing to say.
    static func of(_ s: LinkStatus) -> StatusBanner? {
        var b: StatusBanner?
        switch s.phase {
        case .unpaired:
            b = StatusBanner(mark: .code, title: .pairFirst, detail: .whereTheCodeIs, action: .scan)
        case .connecting:
            b = StatusBanner(mark: .busy, title: s.dropped ? .reconnecting : .connecting)
        case .unreachable:
            // the go-between's own reason, when that's why: it says what fixes it (a relay of one's own), not what to check
            let detail: Line = switch s.away {
            case .noDirect: .noDirect
            case .busy: .goBetweenBusy
            case .relayDown: .relayDown
            case nil: s.hasRelay ? .checkAwake : .checkNetwork
            }
            b = StatusBanner(mark: .problem, title: .cantReach, detail: detail, action: .retry, second: s.otherComputers ? .another : nil)
        case .forgotten:
            b = StatusBanner(mark: .problem, title: .needsPairing, detail: .forgotten, action: .scan)
        case .replaced:
            b = StatusBanner(mark: .phone, title: .otherPhone, detail: .touchToTakeOver)
        case .ended:
            b = StatusBanner(mark: .phone, title: .endedThere, detail: .touchToReconnect)
        case .connected:
            if !s.canControl { b = StatusBanner(mark: .problem, title: .cantControl, detail: .howToAllowControl) }
            if s.screenError == "permission" { b = StatusBanner(mark: .problem, title: .cantShowScreen, detail: .allowScreen) }
            if s.screenError == "off" { b = StatusBanner(mark: .problem, title: .cantShowScreen, detail: .screenIsOff) }
        }
        // a pairing under way is what the user is looking at: it's said over whatever the computer in hand is doing. The digits win:
        // once the computer asks, whatever went wrong before is past
        if s.waiting { return StatusBanner(mark: .busy, title: .waiting, detail: .allowOnComputer) }
        if s.pairFailed {
            // never a dead end: the same code once more where it can still work, else a new one; what there was to do about the
            // computer gone back to is still there to do
            b = s.pairRetry ? StatusBanner(mark: .problem, title: .pairingFailed, detail: .whyPairingFailed, action: .retry, second: .scan)
                : StatusBanner(mark: .problem, title: .pairingFailed, detail: .whyPairingFailed, action: .scan,
                               second: b?.action == .scan ? nil : b?.action)
        }
        return b
    }
}

/// What the thumb should feel, and VoiceOver say, when the connection goes and comes back while the phone is in use.
enum StatusCue: Equatable { case dropped, back }

/// Follows the phases, to tell a drop from a first connection. Opening the app, coming back to it and choosing another computer are all
/// first connections: only a session that went while the app was in front is a drop.
struct StatusFollower {
    private(set) var dropped = false
    private var last: LinkStatus.Phase?
    private var computer: String?

    /// `computer`: the id of the one in hand. `inUse`: the app is in front.
    mutating func see(_ p: LinkStatus.Phase, computer c: String?, inUse: Bool) -> StatusCue? {
        defer { last = p; computer = c }
        guard inUse, c == computer else { dropped = false; return nil }
        let away = p == .connecting || p == .unreachable
        if last == .connected, away {
            dropped = true
            return .dropped
        }
        if p == .connected, dropped {
            dropped = false
            return .back
        }
        // forgotten, taken by another phone: no longer a drop that's coming back
        if !away { dropped = false }
        return nil
    }
}
