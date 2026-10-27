// The parts the hand-off panels share (Hand Off to Agent / New Session, Review Changes): one family with Settings
// (SettingsKit) — the same rounded box, rows over hairlines with one trailing control, the 16 pt status disc in a notice —
// so a panel reads like a page of Settings brought forward, not a form of its own. A panel is a titled window with no
// window buttons (Esc and Cancel close it), 480 pt wide, 24 pt insets, a 15 pt title; its one default button is the
// native filled one in the sheet accent (system.md §3.5: sheets and dialogs keep the native default), the system's grey
// one while disabled; its switches take the same green. Why Start can't go is one PanelNotice under the items, with the
// way out as the default. Its height follows its content with the top edge kept still, so a row that appears grows the
// panel downwards, never up.
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

/// A disclosure heading in Settings' Advanced style ("› Options"): the box under it shows only while it is open. `inset`:
/// the box's text inset (Options) or none (the items line under the panel's title); `trailing`: what it holds, said
/// small after the title (each kind's icon and count).
struct PanelDisclosure<Trailing: View>: View {
    var title: String
    @Binding var open: Bool
    var inset: CGFloat = SettingsMetrics.boxInset
    var size: CGFloat = SettingsMetrics.headerSize
    @ViewBuilder var trailing: Trailing
    var body: some View {
        Button {
            withAnimation(PanelMetrics.change) { open.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(title).font(.system(size: size, weight: .semibold))
                trailing.padding(.leading, 4)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, inset)
        .accessibilityLabel(title)
        .accessibilityValue(open ? "1" : "0")
    }
}

extension PanelDisclosure where Trailing == EmptyView {
    init(title: String, open: Binding<Bool>) { self.init(title: title, open: open) { EmptyView() } }
}

/// What a list of items holds, as SelectionView says it: each kind's 14 pt icon and its count.
struct KindSummary: View {
    let items: [DispatchItem]
    var body: some View {
        let kinds = KindStyle.builtIn.filter { k in items.contains { $0.kind == k } }
            + Set(items.map(\.kind)).subtracting(KindStyle.builtIn).sorted()
        HStack(spacing: 8) {
            ForEach(kinds, id: \.self) { k in
                HStack(spacing: 3) {
                    Image(nsImage: Look.kindImage(k, size: 14))
                    Text("\(items.filter { $0.kind == k }.count)").font(.system(size: SettingsMetrics.detailSize).monospacedDigit())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(items.filter { $0.kind == k }.count) \(Look.kindName(k))")
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// One item as the item list draws it (system.md §3.3): the kind icon in its colour, the id in a fixed column of
/// tabular secondary figures (one width in every panel, so titles share an edge across them), the title on one line
/// (its whole text in the tooltip).
struct HandoffItemLine: View {
    let item: DispatchItem
    var refWidth: CGFloat = HandoffItemLine.idColumn
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

    /// The id column: wide enough for "IOS-123" — the same in every panel.
    static let idColumn: CGFloat = 40

    /// The id column's width for a list: the fixed column, wider only for an id that doesn't fit it.
    static func refWidth(_ items: [DispatchItem]) -> CGFloat {
        let f = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let w = items.map { ($0.ref as NSString).size(withAttributes: [.font: f]).width }.max() ?? 0
        return max(idColumn, ceil(w) + 2)
    }
}

/// A panel's filled default: the native button in the sheet accent (#0B735E in both appearances, white title ≥ 4.5 : 1).
/// Disabled, it is the system's grey default (a plain bordered button with grey text), never a washed-out accent.
struct PanelDefaultButton: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        if enabled { content.buttonStyle(.borderedProminent).tint(Color.settingsDefault) }
        else { content.buttonStyle(.bordered) }
    }
}

extension View {
    func panelDefault() -> some View { modifier(PanelDefaultButton()) }
    /// A panel's switch: the sheet accent, the same green as the default button beside it in both appearances.
    func panelSwitch() -> some View { toggleStyle(.switch).controlSize(.small).tint(Color.settingsDefault) }
}

/// Why Start can't go, or what must be read before it: one line under the items, above the settings (Settings puts
/// its notice above the first section). The 16 pt disc (its shape twin, §1.5), one regular 13 pt sentence, and at most
/// one small action — a way out that isn't the footer's default. A faint wash and a hairline in the tone; no bold body.
struct PanelNotice<Action: View>: View {
    var text: String
    var tone: Tone = .warn
    @ViewBuilder var action: Action
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous)
        let tint: Color = tone == .off ? .primary : tone == .bad ? .brandErr : .brandAttn
        HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
            StatusDot(tone: tone, diameter: 16).frame(width: SettingsMetrics.iconSlot)
            Text(text).font(.system(size: SettingsMetrics.titleSize)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            action
        }
        .padding(.horizontal, SettingsMetrics.boxInset).padding(.vertical, 9)
        .background(shape.fill(tint.opacity(tone == .off ? 0.05 : 0.08)))
        .overlay(shape.strokeBorder(tint.opacity(tone == .off ? 0.12 : 0.3), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

extension PanelNotice where Action == EmptyView {
    init(text: String, tone: Tone = .warn) { self.init(text: text, tone: tone) { EmptyView() } }
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
