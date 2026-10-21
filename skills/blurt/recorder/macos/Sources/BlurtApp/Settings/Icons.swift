// Every icon WP6 draws goes through here: SF Symbols for generic things (in the system's colours), the brand ones
// (bug, chicken) from vector art. No emoji or text glyphs as icons. When the BlurtIcon set lands
// (Icons/BlurtIcon.swift), `.bug` / `.chicken` switch to it here and nowhere else.
import AppKit
import SwiftUI
import BlurtCore

enum UIIcon {
    case ok, failed, warning, tool, edit, say, log, bug, chicken

    @ViewBuilder
    var view: some View {
        switch self {
        case .bug, .chicken: Image(nsImage: brandImage(self, size: 22))
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
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .failed: return .red
        case .warning: return .orange
        case .tool, .log: return .secondary
        case .edit: return .accentColor
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

/// Brand art as an NSImage (vector drawing at the screen's scale): the eggs' beetle, and the peck scene's hen at rest.
func brandImage(_ i: UIIcon, size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        switch i {
        case .bug: drawBug(ctx, at: CGPoint(x: r.midX, y: r.midY - r.height * 0.06), size: r.width * 0.95)
        default:
            ctx.scaleBy(x: r.width / 110, y: r.height / 110)
            PeckArt.draw(ctx, t: 0)
        }
        return true
    }
    img.accessibilityDescription = i == .bug ? "bug" : "chicken"
    return img
}
