// The Remote Control page's reading of the facts (MainWindow/PhonePage.swift): the one headline, which notices about
// this Mac show at the top of the page (only what stands in a device's way — all well is one quiet line, never a wall
// of checks), and what to try when a phone won't connect. Pure: the page gathers the facts (RemoteServer's status, Accessibility, Screen Recording, the
// relay's answer) and draws what this says; the menu-bar menu and Home's tile read the same headline.
import Foundation

public struct PhoneFacts: Equatable, Sendable {
    public enum Relay: Equatable, Sendable {
        /// no relay address: phones connect on the local network only (or an overlay network's)
        case none
        case checking, ok, failed
        /// no relay of the owner's own, and the public connection service is on (docs/design/remote-go-between.md)
        case goBetween
    }

    /// Why coming in from another network doesn't work right now, as this Mac's own tries found it
    /// (RemoteServer.Status.away; Settings → Remote Control says the same).
    public enum Away: Equatable, Sendable {
        /// the public connection service turned this Mac away for today (its limit); it tries again by itself
        case busy
        /// the last phone met there but the direct path didn't open: a relay of one's own fixes it
        case noDirect
        /// the owner's relay doesn't answer this Mac's tries
        case relayDown
    }

    /// phones paired with this Mac
    public var paired: Int
    /// the connected phone's name ("" when it gave none); nil: none connected
    public var connected: String?
    /// it came in through the relay, not straight over the local network
    public var viaRelay: Bool
    /// macOS lets Blurt move the pointer and press keys (Accessibility)
    public var canControl: Bool
    /// Settings → Phone → "Show this Mac's screen on the phone" is on
    public var screenWanted: Bool
    /// macOS lets Blurt see the screen (Screen Recording)
    public var screenAllowed: Bool
    /// the port is open (it is only while a phone is paired or a code is showing)
    public var listening: Bool
    /// why it could not be opened, as the system said it
    public var listenFailure: String?
    /// a pairing code is on show
    public var pairing: Bool
    public var relay: Relay
    /// what this Mac's own tries found about another network; nil: nothing wrong that it knows of
    public var away: Away?

    public init(paired: Int = 0, connected: String? = nil, viaRelay: Bool = false, canControl: Bool = true, screenWanted: Bool = true,
                screenAllowed: Bool = true, listening: Bool = false, listenFailure: String? = nil, pairing: Bool = false, relay: Relay = .none,
                away: Away? = nil) {
        self.paired = paired
        self.connected = connected
        self.viaRelay = viaRelay
        self.canControl = canControl
        self.screenWanted = screenWanted
        self.screenAllowed = screenAllowed
        self.listening = listening
        self.listenFailure = listenFailure
        self.pairing = pairing
        self.relay = relay
        self.away = away
    }
}

public enum PhoneChecks {
    /// The page's one fact.
    public enum Headline: Equatable, Sendable {
        /// no phone is paired: the next thing is Add a Phone
        case nonePaired
        /// paired, none here now
        case notConnected
        case connected(name: String, viaRelay: Bool)
    }

    /// Something about this Mac that stands in a phone's way, each with one fix.
    public enum Problem: Equatable, Sendable {
        /// no Accessibility: a phone connects but can't move the pointer or press keys
        case accessibility
        /// the screen is to be shown on the phone and macOS doesn't let Blurt see it
        case screenRecording
        /// phones are paired (or a code is showing) and the port could not be opened
        case notListening(String)
        /// a relay is set and doesn't answer (the page's check, or this Mac's own tries): a device on another network
        /// can't get here through it
        case relayUnreachable
        /// no relay of one's own, and the public connection service turned this Mac away for today
        case goBetweenBusy
        /// no relay of one's own, and the last phone on another network couldn't connect directly
        case noDirect
    }

    /// What to try when a phone won't connect, in the order to try it.
    public enum Tip: Equatable, Sendable {
        case sameNetwork
        /// Blurt open on the phone, and this Mac awake (a sleeping Mac answers nothing)
        case appOpenMacAwake
        case vpnFirewall
        /// away from home with no relay set: there is no way in until one is
        case awayNeedsRelay
        /// away from home with a relay that answers: any network will do
        case awayUsesRelay
        /// away from home through the public connection service: most networks, not every one
        case awayGoBetween
    }

    public static func headline(_ f: PhoneFacts) -> Headline {
        if let name = f.connected { return .connected(name: name, viaRelay: f.viaRelay) }
        return f.paired == 0 ? .nonePaired : .notConnected
    }

    /// The notices at the top of the page, most in the way first. Empty: all is well, and the page says so in one line.
    /// Accessibility counts before any phone is paired (it is said before pairing, not after); the port only once it
    /// should be open, and only when the system gave a reason (it is closed for a moment whenever it starts). What this Mac's
    /// own tries found away from home is read as Settings → Remote Control reads it (RemotePane.away): only while no
    /// device is connected, an own relay's trouble only with one set, the public connection service's only when it is the
    /// way in.
    public static func problems(_ f: PhoneFacts) -> [Problem] {
        var out: [Problem] = []
        if !f.canControl { out.append(.accessibility) }
        if (f.paired > 0 || f.pairing), !f.listening, let why = f.listenFailure, !why.isEmpty { out.append(.notListening(why)) }
        if f.screenWanted, !f.screenAllowed { out.append(.screenRecording) }
        let idle = f.connected == nil
        switch f.relay {
        case .failed: out.append(.relayUnreachable)
        case .ok, .checking: if idle, f.away == .relayDown { out.append(.relayUnreachable) }
        case .goBetween:
            if idle, f.away == .busy { out.append(.goBetweenBusy) }
            if idle, f.away == .noDirect { out.append(.noDirect) }
        case .none: break
        }
        return out
    }

    /// A paired phone would connect and find it can do nothing here (Home's tile and the sidebar say so).
    public static func needsAttention(_ f: PhoneFacts) -> Bool {
        guard f.paired > 0 else { return false }
        return problems(f).contains { p in
            switch p {
            case .accessibility, .notListening: true
            case .screenRecording, .relayUnreachable, .goBetweenBusy, .noDirect: false     // the pointer and the keys still work
            }
        }
    }

    /// Shown while a phone should be connecting and isn't: one is paired and away, or a code is waiting to be scanned.
    /// Connected, or nothing paired and no code: nothing to try, no lines. A relay that doesn't answer is a problem
    /// line of its own (with its fix), so it isn't said a second time here; nor is a busy or closed way in from elsewhere.
    /// This Mac can't open its port: the cause is known and is here, so no tips (they'd send the owner to the phone).
    public static func tips(_ f: PhoneFacts) -> [Tip] {
        guard f.connected == nil, f.paired > 0 || f.pairing else { return [] }
        let p = problems(f)
        if p.contains(where: { if case .notListening = $0 { true } else { false } }) { return [] }
        let near: [Tip] = [.sameNetwork, .appOpenMacAwake, .vpnFirewall]
        if p.contains(.relayUnreachable) || p.contains(.goBetweenBusy) || p.contains(.noDirect) { return near }
        switch f.relay {
        case .none: return near + [.awayNeedsRelay]
        case .ok, .checking: return near + [.awayUsesRelay]
        case .goBetween: return near + [.awayGoBetween]
        case .failed: return near
        }
    }
}
