// The parts the hand-off panels share (Hand Off to Agent / New Session, Review Changes): one family with Settings
// (SettingsKit) — the same rounded box, rows over hairlines with one trailing control, the 16 pt status disc in a notice —
// so a panel reads like a page of Settings brought forward, not a form of its own. A panel is a titled window with no
// window buttons (Esc and Cancel close it), 480 pt wide, 24 pt insets, a 15 pt title; its one default button is the
// native filled one in the sheet accent (system.md §3.5: sheets and dialogs keep the native default). Its height
// follows its content with the top edge kept still, so a row that appears grows the panel downwards, never up.
import AppKit
import SwiftUI
import BlurtCore

enum PanelMetrics {
    static let width: CGFloat = 480
    static let side: CGFloat = 24
    static let top: CGFloat = 22
    static let bottom: CGFloat = 20
    static let titleSize: CGFloat = 15
    /// between the header, the boxes and the footer
    static let gap: CGFloat = 16
    static let rowPadding: CGFloat = 6
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// what a panel's content changes with: a short ease, none with Reduce Motion
    static var change: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }
}

/// A panel's window: titled (rounded corners, the shadow, a key window) with its buttons hidden, transparent title bar,
/// content under it. When SwiftUI asks for another height the top edge stays where it is.
final class HandoffWindow: NSPanel {
    init(width: CGFloat = PanelMetrics.width) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
    }

    override func setFrame(_ r: NSRect, display: Bool) {
        var f = r
        // a content change (not the user moving it, not a sheet's own placement): keep the top edge
        if isVisible, sheetParent == nil, abs(r.width - frame.width) < 0.5, abs(r.height - frame.height) >= 0.5 {
            f.origin.y = frame.maxY - r.height
            if let s = screen?.visibleFrame, f.minY < s.minY { f.origin.y = s.minY }
        }
        super.setFrame(f, display: display)
    }

    /// Esc where no button takes it: the panel's own way to close (a sheet ends on its parent).
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { if let c = onCancel { c() } else { close() } }
}

/// The panel's header: one 15 pt title and, under it, one secondary line; an optional trailing control on the title's
/// line (New Session's project).
struct PanelHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: PanelMetrics.titleSize, weight: .semibold)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let s = subtitle, !s.isEmpty {
                    Text(s).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(s)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, subtitle: String?) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

/// The rounded box of Settings (SettingsGroup's): rows over hairlines, the first row's hairline on the box's edge where
/// the clip takes it away. An optional heading above it, in Settings' heading style, with an accessory at its right.
struct PanelBox<Content: View, Accessory: View>: View {
    var heading: AnyView?
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let h = heading {
                HStack(spacing: 8) {
                    h.font(.system(size: SettingsMetrics.headerSize, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    accessory
                }
                .frame(minHeight: 16)
                .padding(.horizontal, SettingsMetrics.boxInset)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .environment(\.settingsBoxed, true)
                .padding(.horizontal, SettingsMetrics.boxInset)
                .padding(.top, -1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous))
                .background(RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous).fill(SettingsMetrics.boxFill))
                .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous)
                    .strokeBorder(SettingsMetrics.boxStroke, lineWidth: 0.5).allowsHitTesting(false))
        }
    }
}

extension PanelBox where Accessory == EmptyView {
    init(heading: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.init(heading: heading, content: content) { EmptyView() }
    }
}

/// A disclosure heading in Settings' Advanced style ("› Options"): the box under it shows only while it is open.
struct PanelDisclosure: View {
    var title: String
    @Binding var open: Bool
    var body: some View {
        Button {
            withAnimation(PanelMetrics.change) { open.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(title).font(.system(size: SettingsMetrics.headerSize, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SettingsMetrics.boxInset)
        .accessibilityLabel(title)
        .accessibilityValue(open ? "1" : "0")
    }
}

/// One item as the item list draws it (system.md §3.3): the kind icon in its colour, the id in a fixed column of
/// tabular secondary figures, the title on one line (its whole text in the tooltip).
struct HandoffItemLine: View {
    let item: DispatchItem
    var refWidth: CGFloat
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: Look.kindImage(item.kind, size: KindStyle.smallSize)).accessibilityLabel(Look.kindName(item.kind))
            Text(item.ref).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: refWidth, alignment: .leading)
            Text(item.title.isEmpty ? TL("dispatch.untitled") : item.title).font(.system(size: 13)).lineLimit(1)
                .foregroundStyle(item.title.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.title)
        }
    }

    /// The id column's width: the widest id of the list, so titles start on one line.
    static func refWidth(_ items: [DispatchItem]) -> CGFloat {
        let f = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let w = items.map { ($0.ref as NSString).size(withAttributes: [.font: f]).width }.max() ?? 0
        return max(28, ceil(w) + 2)
    }
}

/// A panel's filled default: the native button in the sheet accent (#0B735E in both appearances, white title ≥ 4.5 : 1).
struct PanelDefaultButton: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.borderedProminent).tint(Color.settingsDefault)
    }
}

extension View {
    func panelDefault() -> some View { modifier(PanelDefaultButton()) }
}

/// The footer's left slot: one quiet line (what happens, why Start waits) or, while something runs, the spinner and
/// what it is doing — the one place a panel says it is busy.
struct PanelFootnote: View {
    var text: String?
    var busy: String?
    var body: some View {
        Group {
            if let b = busy {
                HStack(spacing: 6) {
                    BrandSpinnerView(size: 10, label: b)
                    Text(b)
                }
                .transition(.opacity)
            } else if let t = text, !t.isEmpty {
                Text(t).transition(.opacity)
            } else {
                Color.clear.frame(height: 1)     // the slot keeps the buttons on the right
            }
        }
        .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
