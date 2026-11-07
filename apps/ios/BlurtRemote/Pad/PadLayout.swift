// Where everything goes, as plain numbers (docs/design/remote.md §Layout).
//
//  Portrait: the pad on top, keys below for one thumb: a top row with the tabs and the arrow key, eight across for everything used daily,
//  and the dock under it with the talk key in the corner by the thumb.
//
//  Landscape: the phone's two ends do different work. The end with the Dynamic Island has a side strip: controls in the margin the island
//  leaves free above and below it, and next to that a column with the dock, the arrow key in the middle where it can slide every way, and the
//  talk key. The keys come out at the other end. Turn the phone round to change hands.
//
//  With the Mac's screen showing, the pad is the stage: all the room there is, and the picture sits in it like a photo, filling it as it's
//  zoomed. Opening the keys leaves the stage beside them, so all of the picture stays in view.
import UIKit

struct PadLayout {
    let landscape: Bool
    let pad: CGRect
    let talk: CGRect
    /// the list of keys, scrolling
    let list: CGRect
    let keySize: CGSize
    /// what stays put, in the deck's order
    let dock: [CGRect]
    /// one key for all four arrows, somewhere it can slide every way
    let arrowKey: CGRect
    let strip: CGRect
    let keyboardButton: CGRect
    let settingsButton: CGRect
    let screenButton: CGRect
    /// landscape: the side strip
    let rail: CGRect?
    let drawerButton: CGRect
    /// the keys
    let drawer: CGRect
    /// where one finger scrolls on the pad, across it
    let scrollEdge: ClosedRange<CGFloat>

    static let gap: CGFloat = 4
    static let stripHeight: CGFloat = 36
    /// the 48 keys of the first section, eight across
    static let visibleRows = 6
    /// a little over the system keyboard's; the width comes from eight across
    static let keyHeight: CGFloat = 46
    static let wideKeyHeight: CGFloat = 44
    static let scrollEdgeWidth: CGFloat = 26

    /// `islandLeft`: which end has the Dynamic Island in landscape
    init(size: CGSize, safe: UIEdgeInsets, lefty: Bool, islandLeft: Bool = true, screenAspect: CGFloat? = nil, drawerOpen: Bool = false) {
        landscape = size.width > size.height
        let gap = Self.gap, cols = Deck.columns
        func keys(_ width: CGFloat) -> CGFloat { (width - gap * CGFloat(cols - 1)) / CGFloat(cols) }
        if landscape {
            let margin = islandLeft ? safe.left : safe.right
            let ctrlW: CGFloat = 46, dockW: CGFloat = 46
            let ctrlIn = margin > ctrlW + 8 ? (margin - ctrlW) / 2 : 8
            let dockIn = max(margin, ctrlIn + ctrlW + gap)
            func fromEnd(_ inset: CGFloat, _ w: CGFloat, _ y: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: islandLeft ? inset : size.width - inset - w, y: y, width: w, height: h)
            }
            let edge: CGFloat = 8, far: CGFloat = 10
            let side = dockIn + dockW + 6
            let usable = size.width - side - far

            // the column: the dock, with the arrow key in the middle and the talk key last
            let unit = (size.height - edge * 2 - gap * CGFloat(Deck.dockCount + 1)) / (CGFloat(Deck.dockCount) + 1.5 + 1.2)
            let upper = (Deck.dockCount + 1) / 2
            var y = edge
            var spots: [CGRect] = []
            for i in 0..<Deck.dockCount {
                if i == upper { y += unit * 1.5 + gap }
                spots.append(fromEnd(dockIn, dockW, y, unit))
                y += unit + gap
            }
            dock = spots
            arrowKey = fromEnd(dockIn, dockW, spots[upper - 1].maxY + gap, unit * 1.5)
            talk = fromEnd(dockIn, dockW, y, size.height - edge - y)

            // the margin: two above the island, two below
            let cornerClear: CGFloat = 24, btn: CGFloat = 44
            settingsButton = fromEnd(ctrlIn, ctrlW, cornerClear, btn)
            screenButton = fromEnd(ctrlIn, ctrlW, cornerClear + btn + gap, btn)
            keyboardButton = fromEnd(ctrlIn, ctrlW, size.height - cornerClear - btn * 2 - gap, btn)
            drawerButton = fromEnd(ctrlIn, ctrlW, size.height - cornerClear - btn, btn)
            rail = fromEnd(0, side, 0, size.height)

            let w = min(340, floor(usable * 0.42)), blockH = size.height - edge * 2
            let block = CGRect(x: islandLeft ? size.width - far - w : far, y: edge, width: w, height: blockH)
            drawer = block
            strip = CGRect(x: block.minX, y: block.minY, width: w, height: 26)
            list = CGRect(x: block.minX, y: strip.maxY + 2, width: w, height: block.maxY - strip.maxY - 2)
            keySize = CGSize(width: keys(w), height: Self.wideKeyHeight)

            let keysOut = drawerOpen || screenAspect == nil
            let start = islandLeft ? side : (keysOut ? block.maxX + 6 : far)
            let end = islandLeft ? (keysOut ? block.minX - 6 : size.width - far) : size.width - side
            pad = CGRect(x: start, y: 6, width: end - start, height: size.height - 12)
        } else {
            let side: CGFloat = 8
            let bottom = max(safe.bottom - 6, 12), top = max(safe.top - 6, 16)
            let width = size.width - side * 2, w = keys(width), h = Self.keyHeight
            let rows = CGFloat(Self.visibleRows)
            let total = Self.stripHeight + rows * h + (rows - 1) * gap + gap + h
            let block = CGRect(x: side, y: size.height - bottom - total, width: width, height: total)
            drawer = block
            pad = CGRect(x: side, y: top, width: width, height: block.minY - top - 2)
            keySize = CGSize(width: w, height: h)

            // the top row: the arrow key at the end, with room to slide over the keys and the picture alike
            let t = Self.stripHeight, iconW: CGFloat = 38, arrowW: CGFloat = 78
            arrowKey = CGRect(x: lefty ? block.minX : block.maxX - arrowW, y: block.minY + 2, width: arrowW, height: t - 6)
            let rowX = lefty ? arrowKey.maxX + 4 : block.minX
            settingsButton = CGRect(x: rowX, y: block.minY, width: iconW, height: t)
            let rowEnd = lefty ? block.maxX : arrowKey.minX - 4
            keyboardButton = CGRect(x: rowEnd - iconW, y: block.minY, width: iconW, height: t)
            screenButton = CGRect(x: rowEnd - iconW * 2, y: block.minY, width: iconW, height: t)
            strip = CGRect(x: settingsButton.maxX, y: block.minY, width: screenButton.minX - settingsButton.maxX, height: t)
            list = CGRect(x: block.minX, y: block.minY + t, width: width, height: rows * h + (rows - 1) * gap)

            let dockY = block.maxY - h
            func spot(_ c: Int) -> CGRect { CGRect(x: block.minX + CGFloat(c) * (w + gap), y: dockY, width: w, height: h) }
            talk = spot(lefty ? 0 : cols - 1)
            dock = (0..<Deck.dockCount).map { spot(lefty ? $0 + 1 : $0) }
            rail = nil
            drawerButton = .zero
        }
        scrollEdge = Self.scrollEdge(width: pad.width, lefty: lefty)
    }

    static func scrollEdge(width: CGFloat, lefty: Bool) -> ClosedRange<CGFloat> {
        lefty ? 0...scrollEdgeWidth : (width - scrollEdgeWidth)...width
    }
}
