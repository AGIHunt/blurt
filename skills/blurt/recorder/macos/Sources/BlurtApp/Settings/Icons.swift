// Every icon WP6 draws goes through here: SF Symbols for generic things (in the system's colours), the brand ones
// (bug, chicken, peck) from the blurt icon family (Icons/BlurtIcon.swift, assets/icons/*.svg). No emoji or text glyphs.
import AppKit
import SwiftUI
import BlurtCore

enum UIIcon {
    case ok, failed, warning, tool, edit, say, log, bug, chicken, peck

    /// The brand glyph for .bug / .chicken / .peck (template: tints with the foreground style).
    var brand: BlurtIcon? {
        switch self {
        case .bug: return .bug
        case .chicken: return .chicken
        case .peck: return .peck
        default: return nil
        }
    }

    @ViewBuilder
    var view: some View {
        switch self {
        case .bug, .chicken, .peck: brandImage(self, size: 22).foregroundStyle(color)
        default: Image(systemName: symbol).foregroundStyle(color)
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .tool: return "gearshape"
        case .edit: return "pencil"
        case .say: return "text.bubble"
        case .log: return "text.alignleft"
        case .bug: return "ladybug"
        case .chicken: return "bird"
        case .peck: return "checkmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .failed: return .red
        case .warning: return .orange
        case .tool, .log: return .secondary
        case .edit: return .accentColor
        case .peck: return .green
        default: return .primary
        }
    }

    static func forProgress(_ k: ProgressLine.Kind) -> UIIcon {
        switch k {
        case .say: return .say
        case .tool: return .tool
        case .edit: return .edit
        case .done: return .ok
        case .error: return .failed
        case .log: return .log
        }
    }
}

/// A brand glyph as a SwiftUI template image (size in points).
func brandImage(_ i: UIIcon, size: CGFloat) -> Image {
    (i.brand ?? .chicken).swiftUIImage(size: size)
}

/// The same glyph for AppKit (template NSImage; set contentTintColor on the NSImageView).
func brandNSImage(_ i: UIIcon, size: CGFloat) -> NSImage {
    (i.brand ?? .chicken).image(size: size)
}
