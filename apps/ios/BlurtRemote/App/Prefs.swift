import UIKit

/// The phone's settings.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    private func value<T>(_ k: String, _ fallback: T) -> T { d.object(forKey: k) as? T ?? fallback }

    /// 1 = default; both ends of the slider stay usable
    @Published var pointerSpeed: Double { didSet { d.set(pointerSpeed, forKey: "pointerSpeed") } }
    @Published var scrollSpeed: Double { didSet { d.set(scrollSpeed, forKey: "scrollSpeed") } }
    @Published var reverseScroll: Bool { didSet { d.set(reverseScroll, forKey: "reverseScroll") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    /// portrait: the talk key and the arrow key at the other end. Landscape turns with the phone
    @Published var lefty: Bool { didSet { d.set(lefty, forKey: "lefty") } }
    /// false: dictation listens through the Mac's microphone
    /// a session is kept a while after the app leaves the screen (Link.background)
    @Published var staysConnected: Bool { didSet { d.set(staysConnected, forKey: "staysConnected") } }
    @Published var micOnPhone: Bool { didSet { d.set(micOnPhone, forKey: "micOnPhone") } }
    /// with the Mac's screen showing: a tap clicks what's under the finger. Off: a trackpad, clicking where the pointer is
    @Published var tapWhereTouched: Bool { didSet { d.set(tapWhereTouched, forKey: "tapWhereTouched") } }
    /// a keyboard on the iPad, with Windows or Linux: what its ⌘ key presses there
    @Published var hardwareCommand: CommandKeyRole { didSet { d.set(hardwareCommand.rawValue, forKey: "hardwareCommand") } }
    @Published var quality: ScreenQuality { didSet { d.set(quality.rawValue, forKey: "quality"); ScreenStream.shared.planChanged() } }
    /// the picture comes on with the computer: from the first time, until the user turns it off (the founder, 2026-11-26)
    var screenWanted: Bool { didSet { d.set(screenWanted, forKey: "screenWanted") } }
    /// the picture has been turned on once: the empty pad no longer needs to say where it is
    var screenFound: Bool { didSet { d.set(screenFound, forKey: "screenFound") } }
    /// the picture takes the whole screen while it shows, with only the talk key and a way back over it
    var fullScreen: Bool { didSet { d.set(fullScreen, forKey: "fullScreen") } }
    /// the first picture's tip (two fingers scroll, the zoom key with a pinch) has been shown
    var pictureTipShown: Bool { didSet { d.set(pictureTipShown, forKey: "pictureTipShown") } }

    /// which keyboard the keyboard button opens: the one last used
    var keyboardKind: KeyboardKind { didSet { d.set(keyboardKind.rawValue, forKey: "keyboardKind") } }
    /// the computer keyboard was open when last left. On a big screen it's open again; a phone never starts with it
    var boardOpen: Bool { didSet { d.set(boardOpen, forKey: "boardOpen") } }
    /// which way the screen is turned
    @Published var turn: ScreenTurn { didSet { d.set(turn.rawValue, forKey: "turn") } }

    private init() {
        pointerSpeed = d.object(forKey: "pointerSpeed") as? Double ?? 1
        scrollSpeed = d.object(forKey: "scrollSpeed") as? Double ?? 1
        reverseScroll = d.object(forKey: "reverseScroll") as? Bool ?? false
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        lefty = d.object(forKey: "lefty") as? Bool ?? false
        staysConnected = d.object(forKey: "staysConnected") as? Bool ?? true
        micOnPhone = d.object(forKey: "micOnPhone") as? Bool ?? true
        tapWhereTouched = d.object(forKey: "tapWhereTouched") as? Bool ?? true
        hardwareCommand = d.string(forKey: "hardwareCommand").flatMap(CommandKeyRole.init) ?? .control
        quality = d.string(forKey: "quality").flatMap(ScreenQuality.init) ?? .auto
        screenWanted = d.object(forKey: "screenWanted") as? Bool ?? true
        screenFound = d.bool(forKey: "screenFound")
        fullScreen = d.bool(forKey: "fullScreen")
        pictureTipShown = d.bool(forKey: "pictureTipShown")
        keyboardKind = d.string(forKey: "keyboardKind").flatMap(KeyboardKind.init) ?? .text
        boardOpen = d.bool(forKey: "boardOpen")
        turn = d.string(forKey: "turn").flatMap(ScreenTurn.init) ?? .auto
    }
}

/// Which way the screen is turned. A phone only: an iPad's window is turned and sized by iPadOS, whatever an app says.
enum ScreenTurn: String, CaseIterable, Identifiable {
    case auto, portrait, landscape
    var id: String { rawValue }

    var applies: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    var mask: UIInterfaceOrientationMask {
        guard applies else { return .all }
        return switch self {
        case .auto: .all
        case .portrait: .portrait
        case .landscape: .landscape
        }
    }

    var name: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .portrait: String(localized: "Portrait")
        case .landscape: String(localized: "Landscape")
        }
    }

    var icon: String { self == .landscape ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate" }
}
