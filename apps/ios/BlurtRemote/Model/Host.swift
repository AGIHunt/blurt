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
    static var whereTheCodeIs: String { String(localized: "On your computer, open Blurt’s Settings and choose Phone.") }

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
