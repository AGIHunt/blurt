// Where everything goes, as plain numbers (docs/design/remote.md §Layout). No settings for any of it: the sizes are chosen, and a user who wants
// more keys adds them and scrolls.
//
//  Portrait: the pad on top. Below it a top row with settings, the tabs, the screen controls and the arrow key, four rows of keys six
//  across, and the dock: the modifiers, the keys that end things, space, and the talk key in the corner by the thumb. One screen of keys,
//  big enough to hit without looking.
//
//  Landscape: the black edges the Dynamic Island leaves are put to use. The island's end holds what's rarely needed: settings, find the pointer,
//  the screen, the system keyboard, around the island. The other end holds what's always needed, for the thumb that's there, and it never
//  moves: the keys' switch, ⌘Tab, esc, the arrow key, return, space and the talk key. Everything else comes out beside it when the keys open,
//  as tall as the screen, and goes when they're put away, leaving the picture all the room. Turn the phone round to change hands.
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
    /// landscape: ⌘Tab, there even with the keys away
    let appsKey: CGRect
    let strip: CGRect
    let keyboardButton: CGRect
    let settingsButton: CGRect
    let screenButton: CGRect
    let findButton: CGRect
    /// landscape: the end with the island
    let rail: CGRect?
    /// landscape: puts the keys away and brings them back
    let drawerButton: CGRect
    /// the keys
    let drawer: CGRect
    /// where one finger scrolls on the pad, across it
    let scrollEdge: ClosedRange<CGFloat>

    static let gap: CGFloat = 5
    /// tall enough for the arrow key's four edges
    static let stripHeight: CGFloat = 52
    /// every page of keys has this many
    static let visibleRows = 4
    /// a little over the system keyboard's; the width comes from six across
    static let keyHeight: CGFloat = 48
    /// landscape keys grow to fill the height, up to this, and no taller than this much of their width: a key twice as tall as wide looks odd
    static let wideKeyHeight: CGFloat = 72
    static let wideKeyShape: CGFloat = 1.25
    static let scrollEdgeWidth: CGFloat = 26
    /// the keys beside the picture
    static let wideKeysWidth: CGFloat = 340
    /// the dock's esc, return and space, as it ships: in landscape these stay out by the thumb with the keys put away. The rest are for keys
    static let thumbSlots = (esc: Deck.dockCount - 4, enter: Deck.dockCount - 2, space: Deck.dockCount - 1)

    static func staysOut(_ i: Int) -> Bool { i == thumbSlots.esc || i == thumbSlots.enter || i == thumbSlots.space }

    /// `islandLeft`: which end has the Dynamic Island in landscape
    init(size: CGSize, safe: UIEdgeInsets, lefty: Bool, islandLeft: Bool = true, drawerOpen: Bool = true) {
        landscape = size.width > size.height
        let gap = Self.gap, cols = Deck.columns
        func keys(_ width: CGFloat) -> CGFloat { (width - gap * CGFloat(cols - 1)) / CGFloat(cols) }
        if landscape {
            let margin = islandLeft ? safe.left : safe.right
            func fromIsland(_ inset: CGFloat, _ w: CGFloat, _ y: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: islandLeft ? inset : size.width - inset - w, y: y, width: w, height: h)
            }
            func fromFar(_ inset: CGFloat, _ w: CGFloat, _ y: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: islandLeft ? size.width - inset - w : inset, y: y, width: w, height: h)
            }

            // the island's end: two above it, two below
            let ctrlW: CGFloat = 46, btn: CGFloat = 42, clear: CGFloat = 24
            let ctrlIn = margin > ctrlW + 8 ? (margin - ctrlW) / 2 : 8
            let ctrlEnd = max(margin, ctrlIn + ctrlW)
            settingsButton = fromIsland(ctrlIn, ctrlW, clear, btn)
            findButton = fromIsland(ctrlIn, ctrlW, clear + btn + gap, btn)
            screenButton = fromIsland(ctrlIn, ctrlW, size.height - clear - btn * 2 - gap, btn)
            keyboardButton = fromIsland(ctrlIn, ctrlW, size.height - clear - btn, btn)
            rail = fromIsland(0, ctrlEnd, 0, size.height)

            // the thumb's end: clear of the round corners, the talk key where the thumb rests, a little taller than the keys above it
            // (a phone with an island has round corners; one without has square ones and less height)
            let round = margin > 0
            let far: CGFloat = round ? 12 : 8, thumbW: CGFloat = 56, top: CGFloat = round ? 18 : 8
            let tall = size.height - top * 2
            let arrow: CGFloat = 74, toggle: CGFloat = 30, talkExtra: CGFloat = 8
            let unit = floor((tall - toggle - arrow - talkExtra - gap * 6) / 5)
            var y = top
            func next(_ h: CGFloat) -> CGRect {
                defer { y += h + gap }
                return fromFar(far, thumbW, y, h)
            }
            drawerButton = next(toggle)
            appsKey = next(unit)
            let esc = next(unit)
            arrowKey = next(arrow)
            let enter = next(unit)
            let space = next(unit)
            talk = fromFar(far, thumbW, y, top + tall - y)

            // the keys, beside that: pages, then the rest of the dock, as tall as the screen allows
            let inner = far + thumbW + 6
            let w = min(Self.wideKeysWidth, floor((size.width - ctrlEnd - inner) * 0.5))
            let tabs: CGFloat = 30, drop: CGFloat = 6, edge: CGFloat = 8
            let rows = CGFloat(Self.visibleRows)
            let h = min(Self.wideKeyHeight, floor(keys(w) * Self.wideKeyShape), floor((size.height - edge * 2 - tabs - drop - gap * rows) / (rows + 1)))
            let listH = rows * h + (rows - 1) * gap
            let total = tabs + listH + drop + h
            let blockY = (size.height - total) / 2
            let block = fromFar(inner, w, blockY, total)
            drawer = block
            strip = CGRect(x: block.minX, y: blockY, width: w, height: tabs)
            list = CGRect(x: block.minX, y: blockY + tabs, width: w, height: listH)
            let keyW = keys(w)
            keySize = CGSize(width: keyW, height: h)
            let rowY = block.maxY - h
            var column = 0
            dock = (0..<Deck.dockCount).map { i in
                if i == Self.thumbSlots.esc { return esc }
                if i == Self.thumbSlots.enter { return enter }
                if i == Self.thumbSlots.space { return space }
                defer { column += 1 }
                return CGRect(x: block.minX + CGFloat(column) * (keyW + gap), y: rowY, width: keyW, height: h)
            }

            let reach = inner + (drawerOpen ? w + 6 : 0)
            let padX = islandLeft ? ctrlEnd + 6 : reach
            pad = CGRect(x: padX, y: 6, width: size.width - ctrlEnd - 6 - reach, height: size.height - 12)
        } else {
            let side: CGFloat = 8
            let bottom = max(safe.bottom - 6, 12), top = max(safe.top - 6, 16)
            let width = size.width - side * 2, w = keys(width), h = Self.keyHeight
            let rows = CGFloat(Self.visibleRows)
            let listH = rows * h + (rows - 1) * gap
            let t = Self.stripHeight, drop: CGFloat = 6
            let total = t + listH + drop + h
            let block = CGRect(x: side, y: size.height - bottom - total, width: width, height: total)
            drawer = block
            pad = CGRect(x: side, y: top, width: width, height: block.minY - top - 2)
            keySize = CGSize(width: w, height: h)

            // the top row: settings first, the arrow key by the thumb. Left-handed it comes in from the edge, past settings, so a slide to
            // the left has room
            let iconW: CGFloat = size.width < 390 ? 32 : 36, arrowW: CGFloat = 82     // a narrow phone keeps the room for the tabs
            settingsButton = CGRect(x: block.minX, y: block.minY, width: iconW, height: t - 2)
            arrowKey = CGRect(x: lefty ? settingsButton.maxX + 4 : block.maxX - arrowW, y: block.minY, width: arrowW, height: t - 2)
            appsKey = .zero
            let rowEnd = lefty ? block.maxX : arrowKey.minX - 4
            keyboardButton = CGRect(x: rowEnd - iconW, y: block.minY, width: iconW, height: t - 2)
            screenButton = CGRect(x: rowEnd - iconW * 2, y: block.minY, width: iconW, height: t - 2)
            findButton = CGRect(x: rowEnd - iconW * 3, y: block.minY, width: iconW, height: t - 2)
            let stripX = lefty ? arrowKey.maxX : settingsButton.maxX
            strip = CGRect(x: stripX, y: block.minY, width: findButton.minX - stripX, height: t - 2)
            list = CGRect(x: block.minX, y: block.minY + t, width: width, height: listH)

            // the dock: ten even parts, the last the talk key
            let dockY = block.maxY - h, n = Deck.dockCount + 1
            let unit = (width - gap * CGFloat(n - 1)) / CGFloat(n)
            func spot(_ c: Int) -> CGRect { CGRect(x: block.minX + CGFloat(c) * (unit + gap), y: dockY, width: unit, height: h) }
            talk = spot(lefty ? 0 : n - 1)
            // left-handed it's a mirror, so the same keys are by the thumb
            dock = (0..<Deck.dockCount).map { spot(lefty ? Deck.dockCount - $0 : $0) }
            rail = nil
            drawerButton = .zero
        }
        scrollEdge = Self.scrollEdge(width: pad.width, lefty: lefty)
    }

    static func scrollEdge(width: CGFloat, lefty: Bool) -> ClosedRange<CGFloat> {
        lefty ? 0...scrollEdgeWidth : (width - scrollEdgeWidth)...width
    }
}
