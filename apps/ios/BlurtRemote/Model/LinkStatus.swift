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
    /// the user asked for the picture (the screen button); one that came on by itself says nothing when it can't
    var screenAsked = true
    /// the picture is showing
    var showing = false
    /// the computer's screen is locked, and it can't show that
    var locked = false
    /// on the public connection service, the direct path isn't open yet: nothing is carried until it is
    var meeting = false
    /// this phone has no network at all
    var offline = false
    /// iOS won't let Blurt look on the local network
    var localDenied = false
    /// what the computer's relay says of it while it can't be reached
    var presence: Presence?
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
    enum Presence: Equatable { case asleep, lastOnline }
}

struct StatusBanner: Equatable {
    /// what's drawn beside the words: a state is never told by colour alone
    enum Mark: Equatable { case busy, problem, phone, code }

    enum Line: Equatable {
        case connecting, reconnecting
        /// met on the public connection service; the direct path is being opened
        case connectingDirect
        case noNetwork, turnOnNetwork
        case cantReach, checkNetwork, checkAwake
        /// since when, or when it was last there: from its relay (the time is in the words)
        case asleepSince, lastOnline
        /// iOS's Local Network switch is off for Blurt
        case localNetworkOff
        /// the go-between: the direct path wouldn't open here / the free quota is spent for today
        case noDirect, goBetweenBusy, relayDown
        case needsPairing, forgotten
        case otherPhone
        case endedThere
        case pairFirst, whereTheCodeIs
        case waiting, allowOnComputer
        case pairingFailed, whyPairingFailed
        case cantControl, howToAllowControl
        case cantShowScreen, allowScreen, screenIsOff, pictureStopped
        case locked, unlockFirst
    }

    enum Action: Equatable { case retry, scan, another, takeOver, reconnect, dismiss, openSettings, showScreen }

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
        case .connecting where s.offline, .unreachable where s.offline:
            b = StatusBanner(mark: .problem, title: .noNetwork, detail: .turnOnNetwork)
        case .connecting:
            b = StatusBanner(mark: .busy, title: s.meeting ? .connectingDirect : s.dropped ? .reconnecting : .connecting)
        case .unreachable where s.localDenied && !s.hasRelay:
            b = StatusBanner(mark: .problem, title: .cantReach, detail: .localNetworkOff, action: .openSettings, second: .retry)
        case .unreachable:
            // the go-between's own reason, when that's why: it says what fixes it (a relay of one's own), not what to check
            let detail: Line = switch s.away {
            case .noDirect: .noDirect
            case .busy: .goBetweenBusy
            case .relayDown: .relayDown
            case nil:
                switch s.presence {
                case .asleep: .asleepSince
                case .lastOnline: .lastOnline
                case nil: s.hasRelay ? .checkAwake : .checkNetwork
                }
            }
            b = StatusBanner(mark: .problem, title: .cantReach, detail: detail, action: .retry, second: s.otherComputers ? .another : nil)
        case .forgotten:
            b = StatusBanner(mark: .problem, title: .needsPairing, detail: .forgotten, action: .scan)
        case .replaced:
            // a button, not any touch: a phone in a pocket, or a screen being wiped, mustn't take the computer from whoever has it
            b = StatusBanner(mark: .phone, title: .otherPhone, action: .takeOver)
        case .ended:
            b = StatusBanner(mark: .phone, title: .endedThere, action: .reconnect)
        case .connected:
            if !s.canControl { b = StatusBanner(mark: .problem, title: .cantControl, detail: .howToAllowControl) }
            if s.screenAsked, let e = s.screenError {
                let why: Line = e == "permission" ? .allowScreen : e == "off" ? .screenIsOff : .pictureStopped
                b = StatusBanner(mark: .problem, title: .cantShowScreen, detail: why, action: why == .pictureStopped ? .showScreen : nil)
            }
            // locked: why there's no picture, and why it may not take input either
            if s.locked, s.showing { b = StatusBanner(mark: .problem, title: .locked, detail: .unlockFirst) }
        }
        // a pairing under way is what the user is looking at: it's said over whatever the computer in hand is doing. The digits win:
        // once the computer asks, whatever went wrong before is past
        if s.waiting { return StatusBanner(mark: .busy, title: .waiting, detail: .allowOnComputer) }
        if s.pairFailed {
            // never a dead end: the same code once more where it can still work, else a new one; what there was to do about the
            // computer gone back to is still there to do
            b = s.pairRetry ? StatusBanner(mark: .problem, title: .pairingFailed, detail: .whyPairingFailed, action: .retry, second: .scan)
                // it stays until it's read: a tap on OK, or the next pairing
                : StatusBanner(mark: .problem, title: .pairingFailed, detail: .whyPairingFailed, action: .scan, second: .dismiss)
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
