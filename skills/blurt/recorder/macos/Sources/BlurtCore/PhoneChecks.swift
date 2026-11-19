// The Phone page's reading of the facts (MainWindow/PhonePage.swift): the one headline, which lines about this Mac
// show (only what stands in a phone's way — all well is one line, never a wall of checks), and what to try when a
// phone won't connect. Pure: the page gathers the facts (RemoteServer's status, Accessibility, Screen Recording, the
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

    public init(paired: Int = 0, connected: String? = nil, viaRelay: Bool = false, canControl: Bool = true, screenWanted: Bool = true,
                screenAllowed: Bool = true, listening: Bool = false, listenFailure: String? = nil, pairing: Bool = false, relay: Relay = .none) {
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
        /// a relay is set and doesn't answer: a phone on another network can't get here
        case relayUnreachable
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

    /// The lines that show under "this Mac", most in the way first. Empty: all is well, and the page says so in one line.
    /// Accessibility counts before any phone is paired (it is said before pairing, not after); the port only once it
    /// should be open, and only when the system gave a reason (it is closed for a moment whenever it starts).
    public static func problems(_ f: PhoneFacts) -> [Problem] {
        var out: [Problem] = []
        if !f.canControl { out.append(.accessibility) }
        if (f.paired > 0 || f.pairing), !f.listening, let why = f.listenFailure, !why.isEmpty { out.append(.notListening(why)) }
        if f.screenWanted, !f.screenAllowed { out.append(.screenRecording) }
        if f.relay == .failed { out.append(.relayUnreachable) }
        return out
    }

    /// A paired phone would connect and find it can do nothing here (Home's tile and the sidebar say so).
    public static func needsAttention(_ f: PhoneFacts) -> Bool {
        guard f.paired > 0 else { return false }
        return problems(f).contains { p in
            switch p {
            case .accessibility, .notListening: true
            case .screenRecording, .relayUnreachable: false     // the pointer and the keys still work
            }
        }
    }

    /// Shown while a phone should be connecting and isn't: one is paired and away, or a code is waiting to be scanned.
    /// Connected, or nothing paired and no code: nothing to try, no lines. A relay that doesn't answer is a problem
    /// line of its own (with its fix), so it isn't said a second time here.
    public static func tips(_ f: PhoneFacts) -> [Tip] {
        guard f.connected == nil, f.paired > 0 || f.pairing else { return [] }
        let near: [Tip] = [.sameNetwork, .appOpenMacAwake, .vpnFirewall]
        switch f.relay {
        case .none: return near + [.awayNeedsRelay]
        case .ok, .checking: return near + [.awayUsesRelay]
        case .goBetween: return near + [.awayGoBetween]
        case .failed: return near
        }
    }
}
