// Strings (K10 table "Terminal", plus the shared `session.*` words from "Common") and the visual language of agent
// sessions: the status colours, the status mark (one shape per state; an outward arrow for a session in the agent's
// desktop app, never the spinner), the terminal's light / dark palettes. sessionsErrorText: codes in words, never raw.
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

/// A sessions.py error code → a sentence for people, never the code or the script's own message (those go to the
/// log). auth names the agent and its fix; already_dispatched names the item.
func sessionsErrorText(_ e: Error) -> String {
    NSLog("blurt sessions: %@", "\(e)")
    guard let s = e as? SessionsError else { return TL("error.unknown") }
    switch s.code {
    case "auth":
        let name = s.agent.map(AgentNames.name) ?? "Agent"
        return s.fix.map { TL("error.auth.fix", name, $0) } ?? TL("error.auth", name)
    case "outdated" where s.version != nil && s.need != nil:
        // "Codex 0.157.0 is too old for hand-offs (needs 0.164 or later)…" and the command that updates it
        let name = s.agent.map(AgentNames.name) ?? "Agent"
        let need = s.need!.hasSuffix(".0") ? String(s.need!.dropLast(2)) : s.need!
        return TL("handoff.block.outdated", name, s.version!, need) + (s.fix.map { " " + $0 } ?? "")
    case "already_dispatched" where s.itemID != nil:
        return TL("error.already_dispatched.named", s.itemID!)
    default:
        let key = "error.\(s.code)"
        let t = TL(key)
        return t == key ? TL("error.unknown") : t
    }
}

extension AgentSessionStatus {
    /// K10 common words: Working / Needs your input / Turn finished / Exited / Error
    var title: String { Loc.t("session.\(rawValue)") }

    /// Running brand ink; waiting for you — a question or a finished turn waiting for the next prompt — attention;
    /// error err (docs/design/system.md A.1). The ok colour is for merged / done only, never a turn that waits on you.
    var nsColor: NSColor {
        switch self {
        case .running: return BrandColor.ink
        case .waitingInput, .turnDone: return BrandColor.attn
        case .exited: return .tertiaryLabelColor
        case .error: return BrandColor.err
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

/// The status mark of a session, one shape per state (SessionMark; readable without colour): a turning arc while the
/// agent works, an attention ring with a dot whenever it is the user's move (it breathes once when it becomes so), an ok
/// disc with a check once merged or a pull request is open, an error disc with "×" when it failed (never a bare red
/// dot), a hollow ring once it is over with nothing to do, an outward arrow when it goes on in the agent's desktop
/// app. Reduced motion: no turning, no breathing.
struct SessionStatusMark: View {
    var mark: SessionMark
    var size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            switch mark {
            case .elsewhere:
                // out of here, to the agent's app: an outward arrow, never the spinner
                Image(systemName: "arrow.up.right.circle").resizable().scaledToFit().fontWeight(.medium)
                    .foregroundStyle(Color.brandInk)
            case .working:
                Circle().stroke(Color.brandInk.opacity(0.22), lineWidth: max(1.6, size / 8))
                Circle().trim(from: 0, to: 0.28)
                    .stroke(Color.brandInk, style: StrokeStyle(lineWidth: max(1.6, size / 8), lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
            case .waiting:
                // its own shape: an attention ring around a dot — never the filled "!" disc an item waiting to be
                // verified wears a few rows away
                Circle().fill(Color.brandAttn.opacity(0.28)).scaleEffect(pulse ? 1.9 : 1).opacity(pulse ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.9).repeatCount(2, autoreverses: false), value: pulse)
                Circle().strokeBorder(Color.brandAttn, lineWidth: max(1.5, size / 7))
                Circle().fill(Color.brandAttn).frame(width: size * 0.4, height: size * 0.4)
            case .done:
                StatusDot(tone: .good, diameter: size)
            case .failed:
                // never a bare red dot: that is the recording dot (system.md §2.3)
                StatusDot(tone: .bad, diameter: size)
            case .idle:
                Circle().strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: max(1.4, size / 9))
            }
        }
        .frame(width: size, height: size)
        .onAppear { spin = true; pulse = mark == .waiting }
        .onChange(of: mark) { s in pulse = false; DispatchQueue.main.async { pulse = s == .waiting } }
        .accessibilityElement()
        .accessibilityLabel(TL("mark.\(Self.name(mark))"))
    }

    static func name(_ m: SessionMark) -> String {
        switch m {
        case .working: return "working"
        case .waiting: return "waiting"
        case .done: return "done"
        case .failed: return "failed"
        case .idle: return "idle"
        case .elsewhere: return "elsewhere"
        }
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
