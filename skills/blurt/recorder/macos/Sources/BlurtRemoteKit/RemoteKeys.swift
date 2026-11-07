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
        return t
    }()

    private static let byName: [String: RemoteKey] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    public static func named(_ name: String) -> RemoteKey? { byName[name] }
}

/// A key and its modifiers: ⌘C is {command, "C"}. An empty key is the modifiers alone (held, or tapped).
public struct RemoteChord: Codable, Hashable, Sendable {
    public var mods: RemoteModifiers
    public var key: String

    public init(_ mods: RemoteModifiers = [], _ key: String) { self.mods = mods; self.key = key }

    public var label: String { mods.glyphs + (RemoteKey.named(key)?.glyph ?? key) }
}
