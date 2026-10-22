// Strings (K10 table "Terminal", plus the shared `session.*` words from "Common") and the visual language of agent
// sessions: the status colours, the status mark, the terminal's light / dark palettes.
import AppKit
import SwiftUI
import BlurtCore

/// Terminal-table lookup. Arguments are passed through Loc.t's own variadic signature (≤ 3).
func TL(_ key: String, _ a: CVarArg...) -> String {
    switch a.count {
    case 0: return Loc.t(key, table: "Terminal")
    case 1: return Loc.t(key, table: "Terminal", a[0])
    case 2: return Loc.t(key, table: "Terminal", a[0], a[1])
    default: return Loc.t(key, table: "Terminal", a[0], a[1], a[2])
    }
}

/// A sessions.py error code → a sentence for people.
func sessionsErrorText(_ e: Error) -> String {
    if let s = e as? SessionsError {
        let key = "error.\(s.code)"
        let t = TL(key)
        return t == key ? TL("error.unknown", s.code) : t
    }
    return TL("error.unknown", "\(e)")
}

extension AgentSessionStatus {
    /// K10 common words: Working / Needs your input / Turn finished / Exited / Error
    var title: String { Loc.t("session.\(rawValue)") }

    var nsColor: NSColor {
        switch self {
        case .running: return .controlAccentColor
        case .waitingInput: return NSColor(name: nil) { $0.isDark ? NSColor(hex: 0xFFC53D) : NSColor(hex: 0xE5A000) }
        case .turnDone: return NSColor(name: nil) { $0.isDark ? NSColor(hex: 0x3DD68C) : NSColor(hex: 0x218358) }
        case .exited: return .tertiaryLabelColor
        case .error: return NSColor(name: nil) { $0.isDark ? NSColor(hex: 0xFF6B6B) : NSColor(hex: 0xD93D42) }
        }
    }
    var color: Color { Color(nsColor: nsColor) }

    /// The state a person has to act on first sorts first.
    var urgency: Int {
        switch self {
        case .waitingInput: return 0
        case .error: return 1
        case .turnDone: return 2
        case .running: return 3
        case .exited: return 4
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// The status mark of a session: a turning arc while the agent works, a filled dot that breathes once when it needs
/// you, a quiet dot when the turn is done, a hollow ring once it has exited. Reduced motion: no turning, no breathing.
struct SessionStatusMark: View {
    var status: AgentSessionStatus
    var size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            switch status {
            case .running:
                Circle().stroke(status.color.opacity(0.22), lineWidth: 1.6)
                Circle().trim(from: 0, to: 0.28)
                    .stroke(status.color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
            case .waitingInput:
                Circle().fill(status.color.opacity(0.28)).scaleEffect(pulse ? 1.9 : 1).opacity(pulse ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.9).repeatCount(2, autoreverses: false), value: pulse)
                Circle().fill(status.color)
            case .turnDone, .error:
                Circle().fill(status.color)
            case .exited:
                Circle().strokeBorder(status.color, lineWidth: 1.4)
            }
        }
        .frame(width: size, height: size)
        .onAppear { spin = true; pulse = status == .waitingInput }
        .onChange(of: status) { s in pulse = false; DispatchQueue.main.async { pulse = s == .waitingInput } }
        .accessibilityElement()
        .accessibilityLabel(status.title)
    }
}

/// The terminal's colours. Light: ink on paper; dark: the window's own dark surface. ANSI colours tuned for both so
/// agent UIs (Claude Code, Codex) keep their meaning and stay readable (≥ 4.5:1 for the normal colours on the
/// background, except black / white which are the surface's own extremes).
enum TerminalTheme {
    struct Palette {
        let foreground, background, caret, selection: NSColor
        let ansi: [UInt32]          // 16 colours
    }

    static let light = Palette(
        foreground: NSColor(hex: 0x1D1D1F), background: NSColor(hex: 0xFFFFFF),
        caret: NSColor(hex: 0x1D1D1F), selection: NSColor(hex: 0x0A84FF, alpha: 0.22),
        ansi: [0x1D1D1F, 0xC4282D, 0x1E7A3C, 0x8A6100, 0x2154C9, 0x8E3CB4, 0x0E7490, 0x6E6E73,
               0x515154, 0xD93D42, 0x218358, 0xA16E00, 0x3E63DD, 0xA24FC9, 0x0F8AA8, 0x1D1D1F])
    static let dark = Palette(
        foreground: NSColor(hex: 0xE8E8ED), background: NSColor(hex: 0x1C1C1E),
        caret: NSColor(hex: 0xF5F5F7), selection: NSColor(hex: 0x0A84FF, alpha: 0.36),
        ansi: [0x3A3A3C, 0xFF6B6B, 0x3DD68C, 0xFFC53D, 0x6E9BFF, 0xD08CFF, 0x5CD4E8, 0xC7C7CC,
               0x636366, 0xFF8A85, 0x6BE6A6, 0xFFD666, 0x8DB2FF, 0xDDA6FF, 0x84E1F0, 0xF5F5F7])

    static func palette(for a: NSAppearance) -> Palette { a.isDark ? dark : light }

    static func swiftTermColors(_ p: Palette) -> [SwiftTermColor] {
        p.ansi.map { h in
            SwiftTermColor(red: UInt16((h >> 16) & 0xFF) * 257, green: UInt16((h >> 8) & 0xFF) * 257, blue: UInt16(h & 0xFF) * 257)
        }
    }

    /// SF Mono at the user's text size (12.5 pt by default), falling back to the system monospace.
    static var font: NSFont {
        let size = CGFloat((Config.shared["terminal.font_size"] as? Double) ?? 12.5)
        return NSFont(name: "SFMono-Regular", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
