// Which computer the phone is for: a Mac, or a Windows or Linux PC (docs/design/remote-protocol.md §Hosts). The keys, their names and what the
// app says follow it. Before a computer has said what it is (an old Mac, or one not reached yet) it's a Mac.
import BlurtRemoteKit
import Foundation

extension RemoteHost {
    /// the computer whose keys are on screen. Link keeps it; the keys read it to name themselves
    static var shown: RemoteHost = .mac
}

/// What the app says about the computer. A Mac is called a Mac, as before; anything else is called by its name, or "computer".
/// Where it isn't known yet (a code being scanned, a list of several), the words fit any computer.
enum Words {
    static func cantControl(_ h: RemoteHost, _ name: String) -> String {
        switch h {
        case .mac: String(localized: "On your Mac, allow Accessibility for Blurt.")
        case .windows: String(localized: "The window in front on \(name) runs as administrator. Blurt can’t type into it.")
        case .linux: String(localized: "On \(name), allow Blurt to control the computer when it asks (Remote Desktop).")
        }
    }

    static func noScreenPermission(_ h: RemoteHost, _ name: String) -> String {
        h == .mac ? String(localized: "On your Mac, allow Screen Recording for Blurt.") : String(localized: "On \(name), allow Blurt to share the screen when it asks.")
    }

    static func screenOff(_ h: RemoteHost, _ name: String) -> String {
        h == .mac ? String(localized: "Showing the screen is off in Blurt’s Settings on your Mac.") : String(localized: "Showing the screen is off in Blurt’s Settings on \(name).")
    }

    static func useComputerMic(_ h: RemoteHost) -> String {
        h == .mac ? String(localized: "Use Mac Microphone") : String(localized: "Use Computer’s Microphone")
    }

    static func micDenied(_ h: RemoteHost) -> String {
        h == .mac ? String(localized: "Turn it on in Settings, or dictate through your Mac’s microphone.")
            : String(localized: "Turn it on in Settings, or dictate through your computer’s microphone.")
    }

    /// Before any computer: where its code is. Blurt calls the pane iPhone on a Mac, Phone on Windows and Linux.
    static var whereTheCodeIs: String { String(localized: "On your computer, open Blurt’s Remote Control page and choose Add Device.") }

    /// The pad's card, line by line (LinkStatus.swift has which lines a state gets). `name`: the computer in hand; `check`: the digits a
    /// pairing shows on both; `failed`: Link's sentences for a pairing that didn't take.
    static func status(_ line: StatusBanner.Line, host h: RemoteHost, name: String?, check: String? = nil, failed: PairFailure? = nil) -> String {
        let n = name ?? String(localized: "the computer")
        switch line {
        case .connecting: return String(localized: "Connecting to \(n)…")
        case .reconnecting: return String(localized: "Reconnecting to \(n)…")
        case .cantReach: return String(localized: "Can’t reach \(n)")
        case .checkNetwork: return String(localized: "Check that Blurt is running and both are on the same network. To connect from anywhere, set a relay in Blurt’s Settings → Remote Control on the computer.")
        case .checkAwake: return String(localized: "Check that the computer isn’t asleep and Blurt is running.")
        case .noDirect: return String(localized: "Can’t connect directly. Set up your own relay on the computer.")
        case .goBetweenBusy: return String(localized: "The public connection service has reached today’s limit. Try again later, or use your own relay.")
        case .relayDown: return String(localized: "Its own relay isn’t responding. Trying the public connection service…")
        case .needsPairing: return String(localized: "Needs pairing again")
        case .forgotten: return String(localized: "\(name ?? String(localized: "This computer")) removed this iPhone.")
        case .otherPhone: return String(localized: "Another phone is connected")
        case .touchToTakeOver: return String(localized: "Touch to take over.")
        case .endedThere: return String(localized: "Someone at \(n) ended the connection.")
        case .touchToReconnect: return String(localized: "Touch to reconnect.")
        case .pairFirst: return String(localized: "Pair with your computer")
        case .whereTheCodeIs: return whereTheCodeIs
        case .waiting: return String(localized: "Waiting for your computer")
        case .allowOnComputer: return String(format: String(localized: "Allow this iPhone in Blurt’s Settings on your computer. Check that it shows %@."), check ?? "")
        case .pairingFailed: return failed?.title ?? String(localized: "Pairing didn’t work")
        case .whyPairingFailed: return failed?.help ?? ""
        case .cantControl: return String(localized: "Can’t control \(n)")
        case .howToAllowControl: return cantControl(h, n)
        case .cantShowScreen: return String(localized: "Can’t show the screen")
        case .allowScreen: return noScreenPermission(h, n)
        case .screenIsOff: return screenOff(h, n)
        }
    }

    static func status(_ a: StatusBanner.Action) -> String {
        switch a {
        case .retry: String(localized: "Retry")
        case .scan: String(localized: "Scan Code")
        case .another: String(localized: "Try Another Computer")
        }
    }

    /// The cycle keys, as the settings' list of gestures names them.
    static func cycleKeys(_ h: RemoteHost) -> String {
        switch h {
        case .mac: "⌘Tab, ⌃Tab, ⌘`"
        case .windows: "Alt+Tab, Ctrl+Tab"
        case .linux: "Alt+Tab, Ctrl+Tab, Alt+`"
        }
    }

    /// The four modifiers as the settings' list of gestures names them: ⇧ ⌘ ⌥ ⌃ as before, Ctrl Win Alt Shift elsewhere.
    static func modifiers(_ h: RemoteHost) -> String {
        h == .mac ? "⇧ ⌘ ⌥ ⌃" : h.modifierOrder.map { h.name($0) }.joined(separator: " ")
    }
}
