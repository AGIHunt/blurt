// The setup assistant's own small pieces (Onboarding.swift, docs/design/system.md §3.4): one row language for every
// step — rows over a hairline like Settings' (SettingsLine), a fixed leading glyph column, the title and one line on
// the left, one trailing element on the shared right edge — plus keycaps for shortcuts, the quiet step dots in the
// footer and the notice that stands in for a step's content when something blocks it.
//
//   OnbMetrics            the column, the glyph slot, the row height
//   OnbRow                a row: glyph · title + one line · trailing (keycaps, a state, a button, a switch)
//   StepDots              the step count as four dots; the current one is a wider brand-ink capsule (a shape twin)
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
    static let sectionGap: CGFloat = 22
}

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
    @ViewBuilder var trailing: Trailing
    @Environment(\.displayScale) private var scale

    var body: some View {
        HStack(alignment: .center, spacing: OnbMetrics.rowGap) {
            if let i = image { GlyphTile(image: i) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let d = detail, !d.isEmpty {
                    Text(d).font(.system(size: 12)).foregroundStyle(detailColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .frame(minHeight: OnbMetrics.rowHeight)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1 / max(scale, 1)) }
        }
        .contentShape(Rectangle())
        .help(help ?? "")
    }
}

extension OnbRow where Trailing == EmptyView {
    init(image: NSImage?, title: String, detail: String?, first: Bool = false) {
        self.init(image: image, title: title, detail: detail, first: first) { EmptyView() }
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

/// A section heading inside a step: small and quiet (13 pt semibold, secondary), so the step's title stays the one
/// headline.
struct OnbHeading: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, 2)
    }
}
