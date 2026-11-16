// The Cards page's views (CardsPage.swift): what the big preview reports to (CardPreviewHost), the board that lays the
// tiles (Capture/Island/CardTile.swift) out in two sections, and the AppKit pieces the SwiftUI page hosts.
import AppKit
import BlurtCore
import SwiftUI

/// Who the big preview (CardPreview.swift) asks for the card before / after, and tells that it was closed.
protocol CardPreviewHost: AnyObject {
    func previewStep(_ d: Int)
    func closePreview()
}

/// The page's own view: the SwiftUI page fills it, and it is what holds the keyboard for the grid (the main window
/// focuses a page's view when it goes there: MainWindowController.focusList) — the arrows, Space, ↩, ⌫ and Edit ▸ Copy
/// reach the page through it.
final class CardsPageView: NSView, NSMenuItemValidation {
    weak var page: CardsPage?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { page?.gridFocus(true); return true }
    override func resignFirstResponder() -> Bool { page?.gridFocus(false); return true }
    override func keyDown(with e: NSEvent) { if page?.key(e) != true { super.keyDown(with: e) } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); page?.windowChanged() }

    /// Edit ▸ Copy (⌘C) with the keyboard on a card: the selected cards.
    @objc func copy(_ sender: Any?) { page?.copyFocused() }
    /// Edit ▸ Select All (⌘A): every card of the focused card's section.
    @objc override func selectAll(_ sender: Any?) { page?.selectAllInSection() }
    /// Edit ▸ Delete: the selected cards.
    @objc func delete(_ sender: Any?) { page?.deleteFocused() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(delete(_:)): return page?.hasFocusedCard ?? false
        case #selector(selectAll(_:)): return page?.hasCards ?? false
        default: return true
        }
    }

    override func isAccessibilityElement() -> Bool { false }
}

/// Current and History, one under the other: each a heading with its count, then its tiles (CardTile) in rows of as
/// many as fit at 148 × 100, each widened so a row fills the column (BlurtCore CardsPageRules.tile), 12 pt apart. A
/// row is as tall as its tallest caption. Flipped; it says how
/// tall it is at a width (the page scrolls it).
final class CardsBoardView: NSView {
    /// room for a tile's wash on either side: the board is this much wider than the page's column, so the pictures'
    /// edges stay on the column's
    static let inset: CGFloat = 6
    static let headingH: CGFloat = 22
    static let headingGap: CGFloat = 12
    static let sectionGap: CGFloat = 28
    static let gap = CGFloat(CardsPageRules.gap)

    private struct Section {
        let heading: NSTextField
        /// a control at the end of the heading's row (Current's Show Under the Notch)
        let accessory: NSView?
        /// an empty section's one line (what will show here)
        let hint: NSTextField?
        let tiles: [CardTile]
    }
    private var sections: [Section] = []

    /// every tile, Current's then History's: the order the keyboard walks
    private(set) var tiles: [CardTile] = []
    /// how many tiles each section shows
    private(set) var counts: [Int] = [0, 0]
    /// the picture size the tiles showing were made at
    private(set) var builtTile = CardTile.panelSize
    /// Laid out at a width whose tiles are another size than the ones showing: they are to be made again.
    var onTileSize: (() -> Void)?

    /// The columns and the picture size of a tile at `width` (the board's, its insets included).
    static func metrics(for width: CGFloat) -> (columns: Int, tile: CGSize) {
        let m = CardsPageRules.tile(width: Double(max(0, width - inset * 2)))
        return (m.columns, CGSize(width: m.width, height: m.height))
    }
    /// The width it has, or — before the page has laid it out — the full column's (FullPageFrame's 760 pt).
    private var layoutWidth: CGFloat { bounds.width > 1 ? bounds.width : 760 + CardsBoardView.inset * 2 }
    /// tiles in a row at the width it has now
    var columns: Int { CardsBoardView.metrics(for: layoutWidth).columns }
    /// the picture size a tile is to be made at for the width it has now
    var tile: CGSize { CardsBoardView.metrics(for: layoutWidth).tile }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(T("cards.title"))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// What a section is, for `show`: its heading (the name, the count, a quiet note after it), its tiles, and the
    /// line that stands in for them when there are none (nil: the section is left out then).
    struct Content {
        var title: String
        var count: Int
        var note: String?
        var tiles: [CardTile]
        var empty: String?
        /// at the end of the heading's row, while the section shows a tile
        var accessory: NSView?
    }

    /// `tile`: the picture size the tiles were made at (`tile`, asked before making them).
    func show(_ contents: [Content], tile: CGSize) {
        for s in sections {
            s.heading.removeFromSuperview()
            s.hint?.removeFromSuperview()
            s.accessory?.removeFromSuperview()
            s.tiles.forEach { $0.removeFromSuperview() }
        }
        builtTile = tile
        counts = contents.map(\.tiles.count)
        sections = contents.compactMap { c in
            guard !c.tiles.isEmpty || c.empty != nil else { return nil }
            let heading = NSTextField(labelWithAttributedString: CardsBoardView.heading(c.title, count: c.count, note: c.note))
            heading.lineBreakMode = .byTruncatingTail
            addSubview(heading)
            var hint: NSTextField?
            if c.tiles.isEmpty, let e = c.empty {
                let h = NSTextField(wrappingLabelWithString: e)
                h.font = .systemFont(ofSize: 12)
                h.textColor = .secondaryLabelColor
                addSubview(h)
                hint = h
            }
            c.tiles.forEach(addSubview)
            let accessory = c.tiles.isEmpty ? nil : c.accessory
            if let a = accessory { addSubview(a) }
            return Section(heading: heading, accessory: accessory, hint: hint, tiles: c.tiles)
        }
        tiles = sections.flatMap(\.tiles)
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    /// "Current  6" · "History  3   Kept for 7 days": the name in the headings' weight, the count and the note quieter.
    static func heading(_ title: String, count: Int, note: String?) -> NSAttributedString {
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                                      .foregroundColor: NSColor.labelColor])
        s.append(NSAttributedString(string: "  " + Loc.number(count),
                                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                                                 .foregroundColor: NSColor.secondaryLabelColor]))
        if let n = note {
            s.append(NSAttributedString(string: "    " + n, attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                                          .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return s
    }

    /// Lays the sections out at `width` (placing the views when `place`) and says how tall that is.
    @discardableResult
    private func arrange(_ width: CGFloat, place: Bool) -> CGFloat {
        let inset = CardsBoardView.inset, gap = CardsBoardView.gap, sz = builtTile
        let inner = max(0, width - inset * 2)
        let cols = CardsBoardView.metrics(for: width).columns
        // a row's tiles from edge to edge: the last one ends where the column does (the gaps take the odd point)
        let step = cols > 1 ? max(sz.width + gap, (inner - sz.width) / CGFloat(cols - 1)) : 0
        var y: CGFloat = 0
        for (k, s) in sections.enumerated() {
            if k > 0 { y += CardsBoardView.sectionGap }
            if place {
                // the heading's text centred in its row; the accessory at the column's right edge
                let rowH = CardsBoardView.headingH, textH = ceil(s.heading.intrinsicContentSize.height)
                var textW = inner + 4
                if let a = s.accessory {
                    let fit = a.fittingSize
                    a.frame = NSRect(x: inset + max(inner, fit.width) - fit.width, y: y + ((rowH - fit.height) / 2).rounded(), width: fit.width, height: fit.height)
                    textW = max(40, a.frame.minX - 8 - (inset - 2))
                }
                s.heading.frame = NSRect(x: inset - 2, y: y + ((rowH - textH) / 2).rounded(), width: textW, height: textH)
            }
            y += CardsBoardView.headingH
            if let h = s.hint {
                y += 6
                let hh = ceil(h.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner + 4, height: 1000)).height ?? 16)
                if place { h.frame = NSRect(x: inset - 2, y: y, width: inner + 4, height: hh) }
                y += hh
                continue
            }
            y += CardsBoardView.headingGap
            let rows = (s.tiles.count + cols - 1) / cols
            for r in 0..<rows {
                let row = s.tiles[(r * cols)..<min(s.tiles.count, (r + 1) * cols)]
                let rowH = sz.height + (row.map(\.captionHeight).max() ?? 6)
                if place {
                    for (c, t) in row.enumerated() {
                        t.frame = NSRect(x: inset + (CGFloat(c) * step).rounded(), y: y, width: sz.width, height: rowH)
                    }
                }
                y += rowH + (r < rows - 1 ? gap : 0)
            }
        }
        return ceil(y)
    }

    func height(for width: CGFloat) -> CGFloat { arrange(width, place: false) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(for: layoutWidth)) }
    override func layout() {
        super.layout()
        arrange(bounds.width, place: true)
        if bounds.width > 1, CardsBoardView.metrics(for: bounds.width).tile != builtTile, !tiles.isEmpty { onTileSize?() }
    }
}

/// The board in the SwiftUI page: as wide as the column gives it, as tall as its rows need at that width.
struct CardsBoard: NSViewRepresentable {
    let page: CardsPage
    /// the cards showing changed (the page counts): SwiftUI measures the board again
    let revision: Int

    func makeNSView(context: Context) -> CardsBoardView { page.board }
    func updateNSView(_ v: CardsBoardView, context: Context) { v.needsLayout = true }
    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CardsBoardView, context: Context) -> CGSize? {
        var w = proposal.width ?? 640
        if !w.isFinite || w <= 0 { w = 640 }
        return CGSize(width: w, height: nsView.height(for: w))
    }
}

/// The page's search field (CardsPage.search, the one ⌘F and the tests reach) in its row: as wide as the row gives
/// it, as tall as the buttons at the row's other end.
struct CardsSearchField: NSViewRepresentable {
    let field: NSSearchField
    func makeNSView(context: Context) -> NSSearchField { field }
    func updateNSView(_ f: NSSearchField, context: Context) {}
    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: max(nsView.intrinsicContentSize.height, OutlinedPopUpButton.height))
    }
}

/// A button's title with its shortcut after it as keycaps ("Snap [⌥][A]") — the user's own keys, none while that
/// shortcut is off. `onBrand`: on the primary's gradient, where the caps are white on a white wash.
struct CardsKeyedLabel: View {
    let title: String
    let key: String
    var onBrand = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if !key.isEmpty {
                if onBrand {
                    HStack(spacing: Keycaps.gap) {
                        ForEach(Array(KeyCaps.split(key).enumerated()), id: \.offset) { _, k in
                            Text(k).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Color.white.opacity(0.95))
                                .padding(.horizontal, 4).frame(minWidth: 17, minHeight: 17)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.22)))
                        }
                    }
                    .fixedSize()
                    .accessibilityHidden(true)
                } else {
                    KeyCaps(KeyCaps.split(key), size: 11).accessibilityHidden(true)
                }
            }
        }
    }
}

/// "Show under the notch" at the end of Current's heading: the cards come down under the notch and stay until the
/// pointer has come and gone (HangingCards.reveal) — where they are dragged from while working in another app.
struct CardsNotchButton: View {
    @ObservedObject var page: CardsPage

    var body: some View {
        Button { page.showUnderNotch() } label: { Text(Look.menuCase(T("cards.action.show_notch"))) }
            .buttonStyle(SettingsOutlinedButtonStyle(compact: true))
            .help(T("cards.action.show_notch.tip"))
            .fixedSize()
    }
}
