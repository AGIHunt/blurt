// What a remote key is, on both ends: modifiers and key names shared by the iPhone app (which stores and sends them)
// and Blurt on the Mac (which turns them into key events). Names, not key codes, so a stored layout stays readable and
// the table can grow without touching layouts. Codes are macOS virtual key codes (kVK_*), written out here because this
// module also builds for iOS, where Carbon doesn't exist.
import Foundation

public struct RemoteModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = RemoteModifiers(rawValue: 1)
    public static let shift = RemoteModifiers(rawValue: 2)
    public static let option = RemoteModifiers(rawValue: 4)
    public static let control = RemoteModifiers(rawValue: 8)
    public static let function = RemoteModifiers(rawValue: 16)

    /// In the order macOS writes them.
    public static let ordered: [(RemoteModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
    public var glyphs: String { Self.ordered.filter { contains($0.0) }.map(\.1).joined() }
}

public struct RemoteKey: Hashable, Sendable {
    public let name: String
    public let code: UInt16
    public let glyph: String

    private static func k(_ name: String, _ code: UInt16, _ glyph: String? = nil) -> RemoteKey {
        RemoteKey(name: name, code: code, glyph: glyph ?? name)
    }

    public static let all: [RemoteKey] = {
        var t: [RemoteKey] = []
        let letters: [(String, UInt16)] = [("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4), ("I", 34),
                                           ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31), ("P", 35), ("Q", 12), ("R", 15),
                                           ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6)]
        t += letters.map { k($0.0, $0.1) }
        let digits: [(String, UInt16)] = [("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25)]
        t += digits.map { k($0.0, $0.1) }
        let f: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        t += f.enumerated().map { k("F\($0.offset + 1)", $0.element) }
        t += [k("Return", 36, "↩\u{FE0E}"), k("Tab", 48, "⇥"), k("Space", 49, "␣"), k("Delete", 51, "⌫"), k("Escape", 53, "esc"),
              k("ForwardDelete", 117, "⌦"), k("Left", 123, "←"), k("Right", 124, "→"), k("Down", 125, "↓"), k("Up", 126, "↑"),
              k("Home", 115, "↖"), k("End", 119, "↘"), k("PageUp", 116, "⇞"), k("PageDown", 121, "⇟"),
              k("-", 27), k("=", 24), k("[", 33), k("]", 30), (k(";", 41)), k("'", 39), k(",", 43), k(".", 47), k("/", 44), k("\\", 42), k("`", 50)]
        // a full keyboard's, for a computer driving another (docs/design/remote-desktop-viewer.md): what a phone's deck never sends
        let more: [UInt16] = [105, 107, 113, 106, 64, 79, 80, 90]
        t += more.enumerated().map { k("F\($0.offset + 13)", $0.element) }
        let pad: [UInt16] = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        t += pad.enumerated().map { k("Keypad\($0.offset)", $0.element, "\($0.offset)") }
        t += [k("KeypadDecimal", 65, "."), k("KeypadMultiply", 67, "*"), k("KeypadPlus", 69, "+"), k("KeypadMinus", 78, "-"),
              k("KeypadDivide", 75, "/"), k("KeypadEnter", 76, "⌤"), k("KeypadEquals", 81, "="), k("KeypadComma", 95, ","),
              // the Mac's Clear sits where a PC keyboard has Num Lock, and Help where it has Insert
              k("NumLock", 71, "⌧"), k("Insert", 114, "Ins"), k("CapsLock", 57, "⇪"), k("Menu", 110, "≣"),
              // ISO and JIS keys: the extra one by the left Shift, ¥, ろ, 英数 and かな
              k("IntlBackslash", 10, "§"), k("IntlYen", 93, "¥"), k("IntlRo", 94, "_"), k("Lang2", 102, "英数"), k("Lang1", 104, "かな"),
              // the media keys in words, as PrtSc and Ins: a keycap is text, and an emoji would be a colour icon on it
              k("VolumeUp", 72, "Vol+"), k("VolumeDown", 73, "Vol\u{2212}"), k("Mute", 74, "Mute"),
              // a PC keyboard's: a Mac has F13–F15 in their place, so a Mac host presses those
              k("PrintScreen", 105, "PrtSc"), k("ScrollLock", 107, "ScrLk"), k("Pause", 113, "Pause")]
        return t
    }()

    private static let byName: [String: RemoteKey] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    public static func named(_ name: String) -> RemoteKey? { byName[name] }
    /// A Mac's key code to its name; where two names share a code (F13 and PrintScreen), the first.
    private static let byCode: [UInt16: RemoteKey] = Dictionary(all.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
    public static func named(code: UInt16) -> RemoteKey? { byCode[code] }
}

/// A key and its modifiers: ⌘C is {command, "C"}. An empty key is the modifiers alone (held, or tapped).
public struct RemoteChord: Codable, Hashable, Sendable {
    public var mods: RemoteModifiers
    public var key: String

    public init(_ mods: RemoteModifiers = [], _ key: String) { self.mods = mods; self.key = key }

    public var label: String { mods.glyphs + (RemoteKey.named(key)?.glyph ?? key) }
}
