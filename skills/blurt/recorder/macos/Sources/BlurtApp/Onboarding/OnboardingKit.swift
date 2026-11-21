// The setup assistant's own small pieces (Onboarding.swift, docs/design/system.md §3.4): one row language for every
// step — rows over a hairline like Settings' (SettingsLine), a fixed leading glyph column, the title and one line on
// the left, one trailing element on the shared right edge — plus keycaps for shortcuts, the quiet step dots in the
// footer and the notice that stands in for a step's content when something blocks it.
//
//   OnbMetrics            the column, the glyph slot, the row height, the trailing control's width
//   OnbRow                a row: glyph · title + one line · trailing (keycaps, a state, a button, a switch); `muted`
//                         for a capability switched off on the first step; `note`: a line of its own under the detail
//                         (the dictation key's globe-key line). Inside an OnbGroup: Settings' grid — no tile, a bare
//                         glyph in an 18 pt slot (lists of things only), the hairline inset to the text column
//                         `mark` puts a state (✓, a spinner) before the line, so a row that says how it stands
//                         still has one trailing control
//   OnbGroup              a section as in Settings: a heading outside (an accessory at its right end), the rows in one
//                         rounded box, a 12 pt footnote under it at the box's text inset
//   OnbListRow            the first step's capability row in an OnbGroup: an 18 pt glyph slot · the title (its keys
//                         after it, as quiet labelled hints) and one line · one switch
//   OnbKeyHint            a shortcut and what it does, "⌥ A Snap": keycaps (one per key, tight) and a secondary word
//   OnbBox                rows in one rounded box with no heading of its own (the models step): OnbGroup's look
//   OnbButtonLabel        a trailing button's title at the column's width, so pop-ups and buttons share both edges
//   OnbSplitButton        one outlined button with a chevron segment: its rarer way in lives in the chevron's menu
//   OnbStatus             the trailing status column: one width for every word, the disc at one x down the page
//   StepDots             the step count as dots (four; none when the assistant is one step); the current one is a
//                         wider brand-ink capsule (a shape twin)
//   StateLabel            one trailing state: a status dot and its word
//   OnbNotice             a blocked step: an icon, a title, one line, an optional bar — the action is the footer's
import AppKit
import SwiftUI
import BlurtCore

enum OnbMetrics {
    static let inset: CGFloat = 28            // the content column's side inset
    static let glyph: CGFloat = 28            // the leading glyph slot (a neutral tile)
    static let rowGap: CGFloat = 14           // glyph → title, title → trailing
    static let rowHeight: CGFloat = 54
    static let rowPad: CGFloat = 6             // above and below a row's text: never touching a hairline
    static let sectionGap: CGFloat = 22
    // a group's box (OnbGroup; Settings' SettingsGroup): the text inset inside it, its corners, a row's glyph slot and
    // the gap after it (the text column at boxInset + 28, as in Settings), the air above and below a row's text
    static let boxInset: CGFloat = 12
    static let boxRadius: CGFloat = 10
    static let boxGlyph: CGFloat = 18
    static let boxGlyphGap: CGFloat = 10
    static let listRow: CGFloat = 62           // the first step's rows: one height, the title line and one line under it
    static let boxRowPad: CGFloat = 13
    static let groupGap: CGFloat = 28
    /// the trailing column in a box: every pop-up and button one width (ChoicePopup's), so they share both edges
    static let control: CGFloat = SettingsMetrics.controlWidth
}

private struct OnbBoxedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// rows inside an OnbGroup's box: Settings' grid
    var onbBoxed: Bool {
        get { self[OnbBoxedKey.self] }
        set { self[OnbBoxedKey.self] = newValue }
    }
}

/// What a row's line says about how it stands, drawn before the line: done (the ok ✓ disc), or still working.
enum OnbMark { case state(Tone), working }

/// A neutral rounded tile with a glyph in it (a feature, a permission, a model): never brand colour.
struct GlyphTile: View {
    var image: NSImage
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(0.055))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .overlay(Image(nsImage: image).renderingMode(.template).foregroundStyle(.secondary))
            .frame(width: OnbMetrics.glyph, height: OnbMetrics.glyph)
            .accessibilityHidden(true)
    }

    /// Our line family (brand glyphs) or an SF Symbol, at the tile's size.
    static func brand(_ i: BlurtIcon) -> NSImage { i.image(size: 17) }
    static func symbol(_ name: String) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) ?? NSImage()
    }
}

/// One row: glyph tile, the title (13) and one line (12, secondary), then one trailing element. Over a hairline,
/// except the first row of a list (no line under a heading or the subtitle).
struct OnbRow<Trailing: View>: View {
    var image: NSImage?
    var title: String
    var detail: String?
    var detailColor: Color?
    var first = false
    var help: String?
    /// what the row is about is switched off (a capability on the first step): its glyph and name step back
    var muted = false
    /// a line of its own under the detail (the dictation key's globe-key line: a state of the key, not a row)
    var note: AnyView?
    /// a state before the line ("✓ Ready · …", a spinner while it is checked): the trailing slot stays the control's
    var mark: OnbMark?
    @ViewBuilder var trailing: Trailing
    @Environment(\.displayScale) private var scale
    @Environment(\.onbBoxed) private var boxed

    /// where the text starts: after the glyph (and its gap), or at the row's edge
    private var textInset: CGFloat {
        guard image != nil else { return 0 }
        return boxed ? OnbMetrics.boxGlyph + OnbMetrics.boxGlyphGap : OnbMetrics.glyph + OnbMetrics.rowGap
    }

    var body: some View {
        HStack(alignment: .center, spacing: OnbMetrics.rowGap) {
            HStack(alignment: .center, spacing: boxed ? OnbMetrics.boxGlyphGap : OnbMetrics.rowGap) {
                if let i = image {
                    if boxed {
                        // Settings' list glyph: bare, secondary, in one 18 pt slot (never a tile inside a box)
                        Image(nsImage: i).renderingMode(.template).foregroundStyle(.secondary)
                            .frame(width: OnbMetrics.boxGlyph, height: OnbMetrics.boxGlyph)
                            .opacity(muted ? 0.45 : 1)
                            .accessibilityHidden(true)
                    } else {
                        GlyphTile(image: i).opacity(muted ? 0.45 : 1)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(muted ? .secondary : .primary)
                    if let d = detail, !d.isEmpty {
                        HStack(alignment: .center, spacing: 5) {
                            switch mark {
                            case .state(let t)?: StatusDot(tone: t)
                            case .working?: BrandSpinnerView(size: StatusDot.size)
                            case nil: EmptyView()
                            }
                            Text(d).font(.system(size: 12)).foregroundStyle(detailColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let n = note { n.padding(.top, 4) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            trailing
        }
        // a two-line row keeps air above and below its hairlines (a one-line row is the row height anyway)
        .padding(.vertical, boxed ? OnbMetrics.boxRowPad : OnbMetrics.rowPad)
        .frame(minHeight: OnbMetrics.rowHeight)
        .overlay(alignment: .top) {
            // in a box the hairline starts at the text column (Settings, System Settings): never under a glyph
            if !first {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1 / max(scale, 1))
                    .padding(.leading, boxed ? textInset : 0)
            }
        }
        .contentShape(Rectangle())
        .help(help ?? "")
    }
}

/// The one hairline of the assistant: one device pixel of `separatorColor` (between rows, under the practice card's
/// words, over the footer).
struct OnbHairline: View {
    @Environment(\.displayScale) private var scale
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1 / max(scale, 1)).accessibilityHidden(true)
    }
}

extension OnbRow where Trailing == EmptyView {
    init(image: NSImage?, title: String, detail: String?, first: Bool = false) {
        self.init(image: image, title: title, detail: detail, first: first) { EmptyView() }
    }
}

/// A section, as Settings' (SettingsGroup): its heading outside the box at the box's text inset (an accessory at its
/// right end, never making the line taller), the rows in one rounded box (ink @ 3.5 %, a 0.5 pt ink @ 7 % edge) with
/// hairlines between them, and an optional 12 pt footnote under the box, at its text inset.
struct OnbGroup<Content: View, Accessory: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let t = title {
                HStack(spacing: 8) {
                    OnbHeading(text: t)
                    Spacer(minLength: 8)
                }
                .overlay(alignment: .trailing) { accessory }
                .padding(.horizontal, OnbMetrics.boxInset)
                .padding(.bottom, 6)
            }
            let shape = RoundedRectangle(cornerRadius: OnbMetrics.boxRadius, style: .continuous)
            VStack(alignment: .leading, spacing: 0) { content }
                .environment(\.onbBoxed, true)
                .padding(.horizontal, OnbMetrics.boxInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(Color.primary.opacity(0.035)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5).allowsHitTesting(false))
            if let f = footnote {
                Text(f).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, OnbMetrics.boxInset)
                    .padding(.top, 7)
            }
        }
    }
}

extension OnbGroup where Accessory == EmptyView {
    init(title: String?, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, footnote: footnote, content: content) { EmptyView() }
    }
}

/// The trailing status column: the state words of a list in one width (the longest of them), each word's disc first,
/// so the discs stand at one x down the list whatever the word ("Allowed", "Not allowed"). A button in its place
/// (Allow…) ends on the right edge.
enum OnbStatus {
    /// the slot for these words (StateLabel: a disc, 6 pt, the 12 pt word); none given: the longest word there is
    static func width(_ words: [String]) -> CGFloat {
        let all = words.isEmpty
            ? ["settings.kit.allowed", "onboarding.perm.missing", "settings.perm.not_needed", "onboarding.perm.waiting"].map { T($0) } : words
        let f = NSFont.systemFont(ofSize: 12)
        let w = all.map { ($0 as NSString).size(withAttributes: [.font: f]).width }.max() ?? 60
        return ceil(StatusDot.size + 6 + w + 1)
    }
}

/// Rows in one rounded box: the grouped form of System Settings and of Settings' panes (system.md §3.4) — r 10, ink @
/// 3.5 % with a 0.5 pt ink @ 7 % edge, the rows 12 pt in from its sides, hairlines between them (OnbRow: none above the
/// first). Its heading (OnbHeading) and footnote sit outside it, at the same 12 pt inset.
struct OnbBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .environment(\.onbBoxed, true)           // OnbGroup's grid: bare glyphs, hairlines at the text column
            .padding(.horizontal, OnbMetrics.boxInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color.primary.opacity(0.035)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5).allowsHitTesting(false))
            .accessibilityElement(children: .contain)
    }
}

/// A trailing button's title at the column's width (OnbMetrics.control, less the outlined style's 12 pt sides), so a
/// box's buttons and its pop-up share both edges; a longer title ("Resume (2.1 GB left)") still shows whole.
struct OnbButtonLabel: View {
    var title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).frame(minWidth: OnbMetrics.control - 24)
    }
}

/// ChoicePopup's chevron (9 pt semibold), for OnbSplitButton's menu half.
enum OnbChevron {
    @MainActor static let image: NSImage = {
        let i = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) ?? NSImage()
        i.isTemplate = true
        return i
    }()
}

/// One outlined button (SettingsOutlinedButtonStyle's look, at the column's width) with a chevron segment on its right:
/// the usual way in is the button, a rarer one (Set Up with Agent…) is in the chevron's menu — never a second button
/// at rest (system.md §3.4: rare actions in a split button's menu).
struct OnbSplitButton<Items: View>: View {
    var title: String
    /// the chevron's name for VoiceOver and its tooltip ("More ways to add a key")
    var more: String
    var action: () -> Void
    @ViewBuilder var items: Items
    @Environment(\.isEnabled) private var enabled
    /// the button half: the outlined style's hover and press washes, inside the shared outline
    private struct Half: ButtonStyle {
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.08 : hovering && enabled ? 0.04 : 0))
                .onHover { hovering = $0 }
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 0) {
            Button(action: action) {
                Text(title).font(.system(size: 13)).lineLimit(1)
                    .foregroundStyle(enabled ? Color.primary : Color(nsColor: .tertiaryLabelColor))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Half())
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1).padding(.vertical, 6)
                .accessibilityHidden(true)
            Menu { items } label: {
                // ChoicePopup's own chevron (9 pt semibold, secondary): the menu label draws an NSImage at its size
                Image(nsImage: OnbChevron.image).renderingMode(.template).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: 26)
            .help(more)
            .accessibilityLabel(more)
        }
        .frame(width: OnbMetrics.control, height: OutlinedPopUpButton.height)
        .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1).allowsHitTesting(false))
    }
}

/// The step count, quiet, in the footer: done and to-come are small neutral dots, the current one a wider brand-ink
/// capsule (shape and colour both say "here").
struct StepDots: View {
    var step: Int
    var count: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Color.brandInk : Color(nsColor: i < step ? .tertiaryLabelColor : .quaternaryLabelColor))
                    .frame(width: i == step ? 16 : 6, height: 6)
            }
        }
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.2), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(T("onboarding.step_of", step + 1, count))
    }
}

/// A row's one trailing state: the status dot and its word, together on the right edge.
struct StateLabel: View {
    var tone: Tone
    var text: String
    var color: Color?
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(tone: tone)
            Text(text).font(.system(size: 12)).foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// What stands in for a step's content while something blocks it: a glyph, a title and one line (and a bar while
/// something downloads). The way out is the footer's primary, never a second button here.
struct OnbNotice<Extra: View>: View {
    enum Kind { case attention, error, working, offline }
    var kind: Kind
    var title: String
    var detail: String?
    /// in a fixed area (the Try-it card's place): centred in it, the glyph above the words
    var centered = false
    @ViewBuilder var extra: Extra

    var body: some View {
        Group {
            if centered {
                VStack(spacing: 8) {
                    icon.frame(width: 18, height: 18)
                    VStack(spacing: 4) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        if let d = detail { Text(d).font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    extra.frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    icon.frame(width: 18, height: 18).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        if let d = detail {
                            Text(d).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        extra
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch kind {
        case .working: BrandSpinnerView(size: 14)
        case .attention: StatusDot(tone: .warn).scaleEffect(16 / StatusDot.size)
        case .error: StatusDot(tone: .bad).scaleEffect(16 / StatusDot.size)
        case .offline:
            Image(systemName: "wifi.slash").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.brandAttn)
        }
    }
}

extension OnbNotice where Extra == EmptyView {
    init(kind: Kind, title: String, detail: String?, centered: Bool = false) {
        self.init(kind: kind, title: title, detail: detail, centered: centered) { EmptyView() }
    }
}

/// A section heading inside a step: small and quiet (12 pt semibold, secondary) — a level apart from the 13 pt medium
/// row titles under it, so the step's title stays the one headline.
struct OnbHeading: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, 2)
    }
}

/// A row of an OnbGroup: a bare 18 pt glyph, the title with its accessory after it on the same line (the keys, as
/// OnbKeyHints), one line under it that never wraps, and one trailing control (the switch). Every row is one height; the
/// hairline above a row starts at the text column (not under the glyph) and ends at the box's inset.
struct OnbListRow<Accessory: View, Trailing: View>: View {
    var image: NSImage
    var title: String
    var detail: String
    var first = false
    var help: String?
    /// what the row is about is switched off: its glyph, its name and its keys step back, the line stays readable
    var muted = false
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var trailing: Trailing
    @Environment(\.displayScale) private var scale

    var body: some View {
        HStack(alignment: .center, spacing: OnbMetrics.boxGlyphGap) {
            Image(nsImage: image).renderingMode(.template).foregroundStyle(.secondary)
                .frame(width: OnbMetrics.boxGlyph, height: OnbMetrics.boxGlyph)
                .opacity(muted ? 0.45 : 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(muted ? .secondary : .primary)
                        .lineLimit(1).fixedSize()
                    accessory.opacity(muted ? 0.4 : 1)
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(help ?? "")
            trailing.padding(.leading, 6)
        }
        .frame(height: OnbMetrics.listRow)
        .overlay(alignment: .top) {
            if !first {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1 / max(scale, 1))
                    .padding(.leading, OnbMetrics.boxGlyph + OnbMetrics.boxGlyphGap)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
    }
}

extension OnbListRow where Accessory == EmptyView {
    init(image: NSImage, title: String, detail: String, first: Bool = false, help: String? = nil, muted: Bool = false,
         @ViewBuilder trailing: () -> Trailing) {
        self.init(image: image, title: title, detail: detail, first: first, help: help, muted: muted,
                  accessory: { EmptyView() }, trailing: trailing)
    }
}

/// One shortcut and what it does, as quiet metadata after a row's title: its keycaps (one per key, tight, §2.7a) and a
/// secondary word ("⌥ A Snap"). Several on a line are spaced apart, so two chords never read as one.
struct OnbKeyHint: View {
    var caps: [String]
    var label: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            KeyCaps(caps, size: 11)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(caps.joined(separator: " "))")
    }
}
