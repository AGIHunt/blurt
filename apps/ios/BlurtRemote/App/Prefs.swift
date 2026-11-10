import Foundation

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
    @Published var micOnPhone: Bool { didSet { d.set(micOnPhone, forKey: "micOnPhone") } }
    /// with the Mac's screen showing: a tap clicks what's under the finger. Off: a trackpad, clicking where the pointer is
    @Published var tapWhereTouched: Bool { didSet { d.set(tapWhereTouched, forKey: "tapWhereTouched") } }
    /// a keyboard on the iPad, with Windows or Linux: what its ⌘ key presses there
    @Published var hardwareCommand: CommandKeyRole { didSet { d.set(hardwareCommand.rawValue, forKey: "hardwareCommand") } }
    @Published var quality: ScreenQuality { didSet { d.set(quality.rawValue, forKey: "quality"); ScreenStream.shared.planChanged() } }
    /// the picture was on when last left: it comes back on with the computer. Off, the phone never starts showing a screen by itself
    var screenWanted: Bool { didSet { d.set(screenWanted, forKey: "screenWanted") } }
    /// the picture has been turned on once: the empty pad no longer needs to say where it is
    var screenFound: Bool { didSet { d.set(screenFound, forKey: "screenFound") } }

    private init() {
        pointerSpeed = d.object(forKey: "pointerSpeed") as? Double ?? 1
        scrollSpeed = d.object(forKey: "scrollSpeed") as? Double ?? 1
        reverseScroll = d.object(forKey: "reverseScroll") as? Bool ?? false
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        lefty = d.object(forKey: "lefty") as? Bool ?? false
        micOnPhone = d.object(forKey: "micOnPhone") as? Bool ?? true
        tapWhereTouched = d.object(forKey: "tapWhereTouched") as? Bool ?? true
        hardwareCommand = d.string(forKey: "hardwareCommand").flatMap(CommandKeyRole.init) ?? .control
        quality = d.string(forKey: "quality").flatMap(ScreenQuality.init) ?? .auto
        screenWanted = d.bool(forKey: "screenWanted")
        screenFound = d.bool(forKey: "screenFound")
    }
}
