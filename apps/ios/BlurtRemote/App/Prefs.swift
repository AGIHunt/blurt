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
    /// the talk key in the other corner; landscape: keys under the right thumb
    @Published var lefty: Bool { didSet { d.set(lefty, forKey: "lefty") } }
    /// false: dictation listens through the Mac's microphone
    @Published var micOnPhone: Bool { didSet { d.set(micOnPhone, forKey: "micOnPhone") } }
    /// with the Mac's screen showing: a tap clicks what's under the finger. Off: a trackpad, clicking where the pointer is
    @Published var tapWhereTouched: Bool { didSet { d.set(tapWhereTouched, forKey: "tapWhereTouched") } }

    private init() {
        pointerSpeed = d.object(forKey: "pointerSpeed") as? Double ?? 1
        scrollSpeed = d.object(forKey: "scrollSpeed") as? Double ?? 1
        reverseScroll = d.object(forKey: "reverseScroll") as? Bool ?? false
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        lefty = d.object(forKey: "lefty") as? Bool ?? false
        micOnPhone = d.object(forKey: "micOnPhone") as? Bool ?? true
        tapWhereTouched = d.object(forKey: "tapWhereTouched") as? Bool ?? true
    }
}
