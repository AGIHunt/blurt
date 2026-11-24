// The computer keyboard (docs/design/remote.md §Computer keyboard): the keys of a real one, pressed as a real one's are. Which keys, in
// which rows and how wide, as plain data for the width there is; the view draws it (Keys/FullBoard.swift) and the rules of pressing it
// are Keys/FullTyping.swift. US positions, as the wire's key names are; what each is labelled can come from the computer (`legends`).
import BlurtRemoteKit
import CoreGraphics
import Foundation

struct FullKey: Hashable {
    enum Kind: Hashable {
        /// a key by its wire name
        case key(String)
        case modifier(RemoteModifiers)
        /// the right Alt of a PC's keyboard, which types the third character on a key
        case altGr
        /// the F-keys and what else has no key of its own
        case fn
        /// the next input source, on a Mac (⌃Space)
        case inputSource
        /// where the talk key goes
        case talk
    }

    var kind: Kind
    var units: CGFloat = 1
    /// the wire name it presses with fn
    var fn: String?

    init(_ kind: Kind, _ units: CGFloat = 1, fn: String? = nil) { self.kind = kind; self.units = units; self.fn = fn }
    init(_ name: String, _ units: CGFloat = 1, fn: String? = nil) { self.init(.key(name), units, fn: fn) }
}

/// How many keys across, by the room there is.
enum FullTier: Int, CaseIterable {
    /// a phone upright: the dock below it has the modifiers, space and what ends things
    case ten = 10
    /// a phone on its side: the thumb's column has esc, the arrows, ⌫ and ↩
    case thirteen = 13
    /// a small tablet: a whole keyboard, with Home and the like on fn
    case fifteen = 15
    /// and with room, a column for them
    case sixteen = 16

    static let gap: CGFloat = 5
    /// a whole keyboard's keys are at least this wide, or it has a column fewer
    static let comfortable: CGFloat = 44

    static func big(width: CGFloat) -> FullTier { unit(width, .sixteen) >= comfortable ? .sixteen : .fifteen }
    static func unit(_ width: CGFloat, _ t: FullTier) -> CGFloat { (width - gap * CGFloat(t.rawValue - 1)) / CGFloat(t.rawValue) }
}

enum FullKeys {
    /// What ⇧ makes of the keys that aren't letters, on a US keyboard.
    static let shifted: [String: String] = ["`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
                                            "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?"]

    private static func chars(_ s: String, fn: [String: String] = [:]) -> [FullKey] { s.map { FullKey(String($0), fn: fn[String($0)]) } }

    static func rows(_ t: FullTier, for h: RemoteHost) -> [[FullKey]] {
        let mac = h == .mac
        let digits: [String: String] = ["1": "F1", "2": "F2", "3": "F3", "4": "F4", "5": "F5", "6": "F6", "7": "F7", "8": "F8", "9": "F9", "0": "F10", "-": "F11", "=": "F12"]
        // with no column or arrows to put them on
        let near: [String: String] = ["`": "Insert", "[": "Home", "]": "End", ";": "PageUp", "'": "PageDown", "\\": "ForwardDelete"]
        let pc: [String: String] = mac ? [:] : ["P": "PrintScreen", "B": "Pause", "M": "Menu"]
        let caps = mac ? FullKey.Kind.inputSource : .key("CapsLock")
        switch t {
        case .ten:
            // a PC's AltGr has no other place here; Caps Lock goes on fn
            let f = digits.merging(near) { a, _ in a }.merging(pc) { a, _ in a }.merging(mac ? [:] : ["C": "CapsLock"]) { a, _ in a }
            return [[FullKey(.fn)] + chars("`-=[]\\'", fn: f) + [FullKey("ForwardDelete"), FullKey(mac ? caps : .altGr)],
                    chars("1234567890", fn: f), chars("QWERTYUIOP", fn: f), chars("ASDFGHJKL;", fn: f), chars("ZXCVBNM,./", fn: f)]
        case .thirteen:
            let f = digits.merging(near) { a, _ in a }.merging(pc) { a, _ in a }
            let left: [FullKey] = mac ? [FullKey(.modifier(.control)), FullKey(.modifier(.option)), FullKey(.modifier(.command), 1.5)]
                : [FullKey(.modifier(.control)), FullKey(.modifier(.command)), FullKey(.modifier(.option), 1.5)]
            let right: [FullKey] = mac ? [FullKey(.modifier(.command), 1.5), FullKey(.modifier(.option)), FullKey(.inputSource)]
                : [FullKey(.altGr, 1.5), FullKey(.modifier(.control)), FullKey("CapsLock")]
            return [chars("`1234567890-=", fn: f), [FullKey("Tab")] + chars("QWERTYUIOP[]", fn: f), [FullKey(.fn)] + chars("ASDFGHJKL;'\\", fn: f),
                    [FullKey(.modifier(.shift), 1.5)] + chars("ZXCVBNM,./", fn: f) + [FullKey(.modifier(.shift), 1.5)],
                    left + [FullKey("Space", 6)] + right]
        case .fifteen, .sixteen:
            let wide = t == .sixteen
            func nav(_ n: String) -> [FullKey] { wide ? [FullKey(n)] : [] }
            let f12 = (1...12).map { FullKey("F\($0)", fn: $0 <= 8 ? "F\($0 + 12)" : nil) }
            let left: [FullKey] = mac ? [FullKey(.modifier(.control), 1.25), FullKey(.modifier(.option), 1.25), FullKey(.modifier(.command), 1.5)]
                : [FullKey(.modifier(.control), 1.25), FullKey(.modifier(.command), 1.25), FullKey(.modifier(.option), 1.5)]
            let right: [FullKey] = [mac ? FullKey(.modifier(.command), 1.5) : FullKey(.altGr, 1.5), FullKey(.fn, 1.5)]
            let arrows = [FullKey("Left", fn: "Home"), FullKey("Down", fn: "PageDown"), FullKey("Right", fn: "End")]
            return [
                [FullKey("Escape")] + f12 + [FullKey("ForwardDelete", fn: "Insert"), FullKey(.talk, wide ? 2 : 1)],
                chars("`1234567890-=") + [FullKey("Delete", 2, fn: "ForwardDelete")] + nav("Home"),
                [FullKey("Tab", 1.5)] + chars("QWERTYUIOP[]", fn: pc) + [FullKey("\\", 1.5)] + nav("PageUp"),
                [FullKey(caps, 1.75)] + chars("ASDFGHJKL;'") + [FullKey("Return", 2.25)] + nav("PageDown"),
                [FullKey(.modifier(.shift), 2.25)] + chars("ZXCVBNM,./", fn: pc) + [FullKey(.modifier(.shift), 1.75), FullKey("Up", fn: "PageUp")] + nav("End"),
                left + [FullKey("Space", wide ? 6 : 5)] + right + arrows,
            ]
        }
    }

    /// Where each key goes: `heights` for each row, the keys' edges on half points.
    static func place(_ rows: [[FullKey]], in frame: CGRect, tier: FullTier, heights: [CGFloat]) -> [(key: FullKey, rect: CGRect)] {
        let gap = FullTier.gap, unit = FullTier.unit(frame.width, tier)
        var out: [(FullKey, CGRect)] = [], y = frame.minY
        for (r, row) in rows.enumerated() {
            let h = r < heights.count ? heights[r] : heights.last ?? 44
            var at: CGFloat = 0
            for k in row {
                let x = frame.minX + at * (unit + gap)
                let w = k.units * unit + (k.units - 1) * gap
                let l = (x * 2).rounded() / 2, right = ((x + w) * 2).rounded() / 2
                out.append((k, CGRect(x: l, y: y, width: right - l, height: h)))
                at += k.units
            }
            y += h + gap
        }
        return out
    }

    static func height(_ heights: [CGFloat]) -> CGFloat { heights.reduce(0, +) + FullTier.gap * CGFloat(max(0, heights.count - 1)) }

    /// Keys held go on pressing: letters, digits and marks, space, the arrows, ⌫. Nothing destructive, and nothing with ⌘ or Ctrl but zooming
    /// and moving (docs/design/remote.md §Keys): ⌘W held would close every window.
    static func repeats(_ name: String, mods: RemoteModifiers) -> Bool {
        let moves: Set<String> = ["Left", "Right", "Up", "Down", "Delete", "ForwardDelete", "PageUp", "PageDown"]
        if !mods.isDisjoint(with: [.command, .control]) { return name.hasPrefix("=") || name == "-" || (moves.contains(name) && !name.hasSuffix("Delete")) }
        return name.count == 1 || name == "Space" || moves.contains(name)
    }

    /// These act as the finger lands, as on the pages: waiting for the lift would make a run of them slow.
    static func atOnce(_ name: String) -> Bool { ["Left", "Right", "Up", "Down", "Delete", "ForwardDelete"].contains(name) }
}
