// How each computer writes its keys (docs/design/remote-protocol.md §Hosts). The wire is the same everywhere; only the names a person
// reads differ: ⌘C on a Mac, Ctrl+C on Windows and Linux. Not part of the wire: nothing here is sent.
import Foundation

extension RemoteHost {
    /// What the kind of computer is called, in a list of them.
    public var kindName: String {
        switch self {
        case .mac: "Mac"
        case .windows: "Windows"
        case .linux: "Linux"
        }
    }

    /// The four modifiers in the order this computer's own keyboard has them, left to right, which is also the order its shortcuts are written:
    /// ⌃⌥⇧⌘ on a Mac (as macOS writes them), Ctrl Win Alt Shift on Windows, Ctrl Super Alt Shift on Linux.
    public var modifierOrder: [RemoteModifiers] {
        switch self {
        case .mac: [.control, .option, .shift, .command]
        case .windows, .linux: [.control, .command, .option, .shift]
        }
    }

    /// One modifier's name on this computer's keyboard.
    public func name(_ m: RemoteModifiers) -> String {
        switch self {
        case .mac:
            return m.glyphs
        case .windows, .linux:
            switch m {
            case .command: return self == .windows ? "Win" : "Super"
            case .control: return "Ctrl"
            case .option: return "Alt"
            case .shift: return "Shift"
            case .function: return "Fn"
            default: return label(m)
            }
        }
    }

    /// Several modifiers, as this computer writes them: ⌃⇧ on a Mac, Ctrl+Shift elsewhere.
    public func label(_ m: RemoteModifiers) -> String {
        switch self {
        case .mac: m.glyphs
        case .windows, .linux: modifierOrder.filter { m.contains($0) }.map { name($0) }.joined(separator: "+")
        }
    }

    /// A key's name as it's printed on this computer's keyboard. A Mac's keys keep their glyphs (RemoteKey.glyph).
    public func keyName(_ key: String) -> String {
        guard self != .mac else { return RemoteKey.named(key)?.glyph ?? key }
        return switch key {
        case "Return": "Enter"
        case "Delete": "Backspace"
        case "ForwardDelete": "Del"
        case "Escape": "Esc"
        case "PageUp": "PgUp"
        case "PageDown": "PgDn"
        case "Home", "End", "Tab", "Space": key
        default: RemoteKey.named(key)?.glyph ?? key
        }
    }

    /// A shortcut as this computer writes it: ⇧⌘Z on a Mac, Ctrl+Shift+Z elsewhere. The modifiers alone when there's no key (Win).
    public func label(_ c: RemoteChord) -> String {
        guard self != .mac else { return c.label }
        let mods = label(c.mods), key = c.key.isEmpty ? "" : keyName(c.key)
        return [mods, key].filter { !$0.isEmpty }.joined(separator: "+")
    }
}

extension RemoteVideoCodec {
    /// What a keyframe's parameter sets say they are: HEVC starts with a VPS (NAL type 32), H.264 with an SPS (type 7). nil if neither.
    public static func of(parameterSets sets: [Data]) -> String? {
        guard let b = sets.first?.first else { return nil }
        if (b >> 1) & 0x3F == 32 { return hevc }
        if b & 0x1F == 7 { return h264 }
        return nil
    }
}
