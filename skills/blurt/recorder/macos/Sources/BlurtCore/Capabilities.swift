// The five things Blurt does, as one list the whole app is arranged by (docs/design/capabilities.md): the main
// window's sidebar, the Home page's tiles, Settings' panes, the menu-bar menu, the onboarding and the shortcuts all
// follow it — and each can be turned off as a whole. Off means gone: its shortcuts are given back to the system, its
// menu rows, sidebar place, Settings pane, island buttons and onboarding rows are not shown, and nothing of it runs
// or downloads in the background. Home (and Settings → General) lists all five with their switches, so an off one is
// one click from back.
//
//   dictation    Fn → text at the cursor                                   record.dictation.enabled (as before)
//   cards        snap (⌥A) and voice note (⌥V) → cards under the notch      app.capabilities.cards
//   screen_text  copy / translate text from the screen (⌥C / ⌥T)            app.capabilities.screen_text
//   recording    screen recording (⌥R) → items, and the projects they are   app.capabilities.recording
//                filed in (⌥O); with it off there are no items and no projects anywhere
//   phone        the phone as trackpad, keys, mic and screen                app.capabilities.phone
//
// Every one is on unless config.json says false: an install from before the switches keeps everything it had.
import Foundation

public enum Capability: String, CaseIterable, Sendable {
    case dictation, cards, screenText = "screen_text", recording, phone

    /// Where its switch lives in config.json. Dictation keeps the key it always had.
    public var configKey: String {
        self == .dictation ? "record.dictation.enabled" : "app.capabilities.\(rawValue)"
    }

    public var isOn: Bool { Capability.isOn(self, in: Config.shared) }

    public static func isOn(_ c: Capability, in config: Config) -> Bool { config[c.configKey] as? Bool ?? true }

    /// The ones turned off, as the rules below take them.
    public static var off: Set<Capability> { Set(allCases.filter { !$0.isOn }) }

    /// Writes the switch (true is the default: stored as nothing) and tells the app (`didChange`, object: the
    /// capability's raw value). false: config.json refused the write.
    @discardableResult
    public static func set(_ c: Capability, on: Bool, in config: Config = .shared) -> Bool {
        guard config.set(c.configKey, on ? nil : false) else { return false }
        NotificationCenter.default.post(name: didChange, object: c.rawValue)
        return true
    }

    /// A capability was turned on or off (posted on the thread that changed it; the app's listeners hop to main).
    public static let didChange = Notification.Name("dev.blurt.capabilities-changed")

    /// The global shortcuts that are this capability's. Open Menu and Open Blurt are nobody's: always there.
    public var hotkeys: [HotkeyCenter.Action] {
        switch self {
        case .dictation: return [.reformat]
        case .cards: return [.snap, .voice, .cards]
        case .screenText: return [.text, .translateText]
        case .recording: return [.toggleRecord, .pause, .pen, .finish, .project]
        case .phone: return []
        }
    }

    public static func owner(of a: HotkeyCenter.Action) -> Capability? { allCases.first { $0.hotkeys.contains(a) } }

    /// The shortcuts that only mean something while a recording runs: held as global keys only then, so ⌥P, ⌥D and ⌥S
    /// stay the front app's the rest of the time.
    public static let whileRecording: Set<HotkeyCenter.Action> = [.pause, .pen, .finish]

    /// The shortcuts that are off with their capabilities (HotkeyCenter.disabled). While a recording runs ⌥A marks a
    /// moment in it, so Snap stays for its length even with Cards off.
    public static func disabledHotkeys(off: Set<Capability>, recording: Bool) -> Set<HotkeyCenter.Action> {
        var out = Set(off.flatMap(\.hotkeys))
        if recording, !off.contains(.recording) { out.remove(.snap) }
        return out
    }

    /// The shortcuts set but not held right now (HotkeyCenter.standby): the recording's own while nothing records.
    public static func standbyHotkeys(recording: Bool) -> Set<HotkeyCenter.Action> { recording ? [] : whileRecording }

    /// Whether a shortcut — pressed, or sent by a paired phone — may act now.
    public static func allows(_ a: HotkeyCenter.Action, off: Set<Capability> = Capability.off, recording: Bool) -> Bool {
        !disabledHotkeys(off: off, recording: recording).contains(a)
    }

    /// Projects exist for items: with Recording off nothing is filed anywhere, so no project chip, switcher or
    /// "Unassigned" shows on any surface.
    public static var projectsShown: Bool { Capability.recording.isOn }
}
