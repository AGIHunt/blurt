// A keyboard on the iPad (Magic Keyboard, Smart Keyboard, any Bluetooth one): its keys are the computer's. Keys go by position (the HID
// usage), as the computer's own keyboard would send them, so any layout the computer uses comes out right. Modifiers are held exactly as
// long as they're held here, so ⌘-click on the pad and ⌘ held through Tab Tab Tab work. Other keys are pressed, and repeat while held,
// on this side: a lost "up" can't leave a key stuck down on the computer.
//
// On Windows and Linux the ⌘ key presses Ctrl, as a Mac user's fingers expect (⌘C copies), unless Settings says it's the Windows key;
// Control is Ctrl too, Option is Alt. iPadOS keeps a few keys for itself and never passes them to apps: ⌘Tab, ⌘Space, ⌘H, the Globe
// key and its shortcuts, and holding ⌘ alone may show its shortcut list.
import BlurtRemoteKit
import UIKit

/// What the physical ⌘ is on a computer that isn't a Mac.
enum CommandKeyRole: String, CaseIterable, Identifiable {
    /// Ctrl: ⌘C copies, ⌘V pastes
    case control
    /// the Windows or Super key
    case system
    var id: String { rawValue }
}

final class HardwareKeys {
    static let shared = HardwareKeys()

    /// physical modifier keys down now, by HID usage
    private var heldPhysical = Set<Int>()
    /// what the computer has been told is held
    private var sent: RemoteModifiers = []
    private var repeatTimer: Timer?
    private var repeating: Int?

    static let repeatDelay = 0.42
    static let repeatEvery = 0.05

    // MARK: the table

    static func name(hid u: Int) -> String? {
        switch u {
        case 0x04...0x1D: return String(UnicodeScalar(UInt8(u - 0x04) + 65))     // A…Z
        case 0x1E...0x26: return String(u - 0x1E + 1)                              // 1…9
        case 0x27: return "0"
        case 0x28, 0x58: return "Return"                                            // and the keypad's Enter
        case 0x29: return "Escape"
        case 0x2A: return "Delete"
        case 0x2B: return "Tab"
        case 0x2C: return "Space"
        case 0x2D: return "-"
        case 0x2E: return "="
        case 0x2F: return "["
        case 0x30: return "]"
        case 0x31, 0x32: return "\\"
        case 0x33: return ";"
        case 0x34: return "'"
        case 0x35: return "`"
        case 0x36: return ","
        case 0x37: return "."
        case 0x38: return "/"
        case 0x3A...0x45: return "F\(u - 0x3A + 1)"
        case 0x4A: return "Home"
        case 0x4B: return "PageUp"
        case 0x4C: return "ForwardDelete"
        case 0x4D: return "End"
        case 0x4E: return "PageDown"
        case 0x4F: return "Right"
        case 0x50: return "Left"
        case 0x51: return "Down"
        case 0x52: return "Up"
        case 0x64: return "`"                                                       // the ISO key by the left Shift
        default: return nil
        }
    }

    /// A modifier key, as the computer should see it. nil: not a modifier.
    static func modifier(hid u: Int, host: RemoteHost, command: CommandKeyRole) -> RemoteModifiers? {
        switch u {
        case 0xE0, 0xE4: return .control
        case 0xE1, 0xE5: return .shift
        case 0xE2, 0xE6: return .option
        case 0xE3, 0xE7: return host == .mac || command == .system ? .command : .control
        default: return nil
        }
    }

    /// Nothing destructive repeats (docs/design/remote.md §Keys): never Esc, Return, or ⌃C.
    static func repeats(_ key: String, held: RemoteModifiers) -> Bool {
        !(key == "Escape" || key == "Return" || (key == "C" && held.contains(.control)))
    }

    // MARK: presses

    var host: RemoteHost { Link.shared.host }
    var command: CommandKeyRole { Prefs.shared.hardwareCommand }

    /// True if the press was the computer's; false leaves it to iPadOS.
    func began(_ p: UIPress) -> Bool {
        guard let k = p.key else { return false }
        let u = k.keyCode.rawValue
        if Self.modifier(hid: u, host: host, command: command) != nil {
            heldPhysical.insert(u)
            sync()
            return true
        }
        guard let name = Self.name(hid: u) else { return false }
        Link.shared.send(.key(RemoteChord([], name), down: nil))
        Sticky.shared.used()
        stopRepeat()
        if Self.repeats(name, held: sent.union(Sticky.shared.held)) {
            repeating = u
            repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatDelay, repeats: false) { [weak self] _ in
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatEvery, repeats: true) { _ in
                    Link.shared.send(.key(RemoteChord([], name), down: nil))
                }
            }
        }
        return true
    }

    func ended(_ p: UIPress) -> Bool {
        guard let k = p.key else { return false }
        let u = k.keyCode.rawValue
        if heldPhysical.remove(u) != nil {
            sync()
            return true
        }
        if repeating == u { stopRepeat() }
        return Self.name(hid: u) != nil
    }

    /// Keys iPadOS would otherwise take for moving focus or dismissing (Tab, the arrows, Esc): claimed first, with every combination of
    /// modifiers, since a key command matches its modifiers exactly. The modifiers are already held on the computer (`sync`), so the key
    /// goes alone. iPadOS repeats them while held.
    static let claimed: [(input: String, name: String)] = [("\t", "Tab"), (UIKeyCommand.inputUpArrow, "Up"), (UIKeyCommand.inputDownArrow, "Down"),
                                                           (UIKeyCommand.inputLeftArrow, "Left"), (UIKeyCommand.inputRightArrow, "Right"),
                                                           (UIKeyCommand.inputEscape, "Escape")]

    static func commands(action: Selector) -> [UIKeyCommand] {
        let mods: [UIKeyModifierFlags] = [.command, .shift, .alternate, .control]
        let combos = (0..<16).map { n in mods.enumerated().reduce(into: UIKeyModifierFlags()) { f, m in if n & (1 << m.offset) != 0 { f.insert(m.element) } } }
        return claimed.flatMap { k in combos.map { f in
            let c = UIKeyCommand(input: k.input, modifierFlags: f, action: action)
            c.wantsPriorityOverSystemBehavior = true
            return c
        } }
    }

    func command(_ c: UIKeyCommand) {
        guard let name = Self.claimed.first(where: { $0.input == c.input })?.name else { return }
        Link.shared.send(.key(RemoteChord([], name), down: nil))
        Sticky.shared.used()
    }

    /// The app left the screen, or the keyboard went: nothing stays held.
    func letGo() {
        stopRepeat()
        heldPhysical = []
        sync()
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeating = nil
    }

    /// Two keys can be one modifier (⌘ and Control are both Ctrl on Windows): the computer hears it go down with the first and up with the last.
    private func sync() {
        let want = heldPhysical.reduce(into: RemoteModifiers()) { m, u in m.formUnion(Self.modifier(hid: u, host: host, command: command) ?? []) }
        for (m, _) in RemoteModifiers.ordered {
            if want.contains(m), !sent.contains(m) { Link.shared.send(.key(RemoteChord(m, ""), down: true)) }
            if !want.contains(m), sent.contains(m) { Link.shared.send(.key(RemoteChord(m, ""), down: false)) }
        }
        sent = want
    }
}
