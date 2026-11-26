// Where everything goes, as plain numbers (docs/design/remote.md §Layout, §iPad and iPhone Duo). No settings for any of it: the sizes are
// chosen, and a user who wants more keys adds them and scrolls. A pure function of the room there is (size, safe area, the fold and the
// cameras as UIKit reports them, the computer's screen shape), never of the device's name, so an iPad window resized by hand, the
// iPhone Duo opening and a phone turning all go through the same arithmetic, and the tests run it at every size.
//
//  Portrait (a phone, a narrow window): the pad on top. Below it a top row with settings, the tabs, the screen controls and the arrow
//  key, four rows of keys six across, and the dock: the modifiers, the keys that end things, space, and the talk key in the corner by
//  the thumb. One screen of keys, big enough to hit without looking. A wider window doesn't stretch them: the block stays phone-sized.
//
//  Landscape (a phone on its side, a short window): the black edges the Dynamic Island leaves are put to use. The island's end holds
//  what's rarely needed: settings, find the pointer, the screen, the system keyboard, around the island. The other end holds what's
//  always needed, for the thumb that's there, and it never moves: the keys' switch, ⌘Tab, esc, the arrow key, return, space and the
//  talk key. Everything else comes out beside it when the keys open, as tall as the screen, and goes when they're put away, leaving the
//  picture all the room. Turn the phone round to change hands.
//
//  Big (an iPad, the iPhone Duo open, any window with room both ways): the stage on top, as wide as the screen, and the keys under it
//  split in two, one half for each thumb at the lower corners, with a trackpad between them where the thumbs meet. A computer's screen
//  is wider than these displays, so the band under a whole picture is free: the keys go there. The halves are phone-sized: a page is
//  split three and three, the dock five and five. Where the keys would cost the picture, they're put away to two rows (the top row and
//  the dock) and come back from the tabs. With a fold the halves keep to their side of it; partly folded like a laptop, the picture
//  takes the upper half and the keys and trackpad the lower; like a book, the picture takes one page and the other is a phone's remote.
//
//  With the computer's screen showing, the pad is the stage: all the room there is, and the picture sits in it like a photo, filling it
//  as it's zoomed. Opening the keys leaves the stage beside them, so all of the picture stays in view. Nothing is ever placed over it.
import UIKit

/// What else shapes the room, besides the safe area: UIKit's reserved regions (iOS 27.1, `UIView.reservedRegions`), in the view's
/// coordinates. Empty on everything without a fold or a camera in the glass.
struct PadSurround: Equatable {
    /// the fold, active or not: the layout keeps its keys off it either way, so folding doesn't move them
    var fold: CGRect?
    /// partly folded: the two sides face different ways now
    var foldActive = false
    /// cameras and the like that cover the glass, active ones only
    var occlusions: [CGRect] = []

    static let none = PadSurround()

    /// laptop-like: the fold runs across, the lower half lies on the table
    var laptop: Bool { foldActive && (fold.map { $0.width > $0.height } ?? false) }
    /// book-like: the fold runs down the middle, a page each side
    var book: Bool { foldActive && (fold.map { $0.height > $0.width } ?? false) }
}

struct PadLayout {
    enum Mode { case portrait, landscape, big }
    let mode: Mode
    /// the phone on its side: the thumb's column and the island's rail
    var landscape: Bool { mode == .landscape }
    /// the stage: the trackpad, and the picture when it shows
    let pad: CGRect
    /// big: the trackpad between the thumbs (with a book fold, the remote's page)
    let thumbPad: CGRect?
    let talk: CGRect
    /// the list of keys, scrolling
    let list: CGRect
    /// big: the gap in the middle of the list, in its own coordinates: a page splits around it, half for each thumb
    let listSplit: (at: CGFloat, width: CGFloat)?
    let keySize: CGSize
    /// what stays put, in the deck's order
    let dock: [CGRect]
    /// one key for all four arrows, somewhere it can slide every way
    let arrowKey: CGRect
    /// landscape and big: ⌘Tab, there even with the keys away
    let appsKey: CGRect
    let strip: CGRect
    let keyboardButton: CGRect
    let settingsButton: CGRect
    let screenButton: CGRect
    /// the Transfer sheet: files and the clipboard, both ways (docs/design/remote-files.md), next to the screen button
    let transferButton: CGRect
    let findButton: CGRect
    /// landscape: the end with the island
    let rail: CGRect?
    /// landscape: puts the keys away and brings them back
    let drawerButton: CGRect
    /// the keys (big: both halves and what's between them)
    let drawer: CGRect
    /// big: the two thumbs' halves
    let halves: [CGRect]
    /// putting the keys away gives the picture room. Where it wouldn't, they stay out and there's no switch
    let drawerMatters: Bool
    /// the pages are showing
    let keysOut: Bool
    /// the computer keyboard, open: where it goes, how many keys across and how tall each row is. The list, and on a big screen the halves
    /// and the dock, give it their place
    let board: Board?
    /// where one finger scrolls on the pad, across it
    let scrollEdge: ClosedRange<CGFloat>
    /// that's the left side
    let scrollsLeft: Bool
    /// and down it: never across the fold
    let scrollEdgeY: ClosedRange<CGFloat>?
    /// the same on the thumb pad
    let thumbScrollEdge: ClosedRange<CGFloat>?
    /// where a picture smaller than the stage sits, 0 top … 1 bottom: near the keys
    let stageAlignY: CGFloat
    /// on the stage: where words, chips and a message go, clear of the fold, on the thumb's side
    let hintArea: CGRect
    let fold: CGRect?

    struct Board: Equatable {
        var frame: CGRect
        var tier: FullTier
        var heights: [CGFloat]
        /// the stage's bands beside the picture are a trackpad: there's no other by the keys
        var bandsArePad = false
        /// a row of its own over the keys, with the controls in it
        var quick: [CGRect] = []
    }

    static let gap: CGFloat = 5
    /// tall enough for the arrow key's four edges
    static let stripHeight: CGFloat = 52
    /// what a two-character tab needs in the portrait row at 13 pt, with room either side to tell it from the next
    static let tabRoom: CGFloat = 38
    /// big: the top row is taller, so the arrow key is 88 pt square and each of its four edges 44 pt deep. On a phone ↑ and ↓ get 25 pt
    /// each, and in a terminal they're the arrows used most
    static let bigStripHeight: CGFloat = 90
    /// every page of keys has this many
    static let visibleRows = 4
    /// a little over the system keyboard's; the width comes from six across
    static let keyHeight: CGFloat = 48
    /// landscape keys grow to fill the height, up to this, and no taller than this much of their width: a key twice as tall as wide looks odd
    static let wideKeyHeight: CGFloat = 72
    static let wideKeyShape: CGFloat = 1.25
    /// portrait with the picture: keys grow a little into the room it leaves, no more (taller, they look empty and toy-like)
    static let pictureKeyHeight: CGFloat = 56
    /// wide enough to find with a thumb that isn't looked at (26 was the first value: a slide begun a little inside was the pointer)
    static func scrollEdgeWidth(_ pad: CGFloat) -> CGFloat { min(44, max(32, pad * 0.09)) }
    /// the computer keyboard's keys, upright on a phone
    static let boardKeyHeight: CGFloat = 44
    /// a trackpad under it needs this much
    static let boardPadHeight: CGFloat = 96
    /// the keys beside the picture
    static let wideKeysWidth: CGFloat = 340
    /// portrait: the keys are a phone's, however wide the window
    static let blockWidth: CGFloat = 456
    /// big: one thumb's half, about what a thumb sweeps from the edge it holds
    static let halfWidth: CGFloat = 236
    /// big: the trackpad between the halves is at least this wide, or the halves get narrower
    static let thumbPadWidth: CGFloat = 140
    /// big: needs this much across (two halves whose dock keys stay key-shaped, and a trackpad between them) and this much down;
    /// less, and it's a phone's layout
    static let bigWidth: CGFloat = 616
    static let bigHeight: CGFloat = 520
    /// the dock's esc, ⌫ and ↩, wherever the deck has them: in landscape these stay out by the thumb with the keys put away. The rest are for
    /// keys. ⌫ took the space bar's place there (2026-11-18): writing by voice, a slip is mended with ⌫, and nobody pressed space
    static var thumbSlots = Deck.thumbSlots(Deck.standard.dock)
    /// big screens: the modifiers and ⇥ under one thumb, the rest of the dock and the talk key under the other
    static let bigSplit = 5

    static func staysOut(_ i: Int) -> Bool { i == thumbSlots.esc || i == thumbSlots.delete || i == thumbSlots.enter }

    static func mode(for size: CGSize) -> Mode {
        if size.width >= bigWidth && size.height >= bigHeight { return .big }
        return size.width > size.height ? .landscape : .portrait
    }

    /// `islandLeft`: which end has the camera in landscape. `aspect`: the computer's screen, width ÷ height. `showing`: the picture is on
    init(size: CGSize, safe: UIEdgeInsets, lefty: Bool, islandLeft: Bool = true, drawerOpen: Bool = true,
         surround: PadSurround = .none, aspect: CGFloat = 1.6, showing: Bool = false, board: Bool = false) {
        let mode = Self.mode(for: size)
        switch mode {
        case .landscape:
            // a camera in the island's end that isn't in its middle (the Duo's outer one, in a corner): the controls go clear of it
            let end = CGRect(x: islandLeft ? 0 : size.width - 80, y: 0, width: 80, height: size.height)
            // (UIKit reports the lens and, around it, the region kept clear: all of it)
            let camera = surround.occlusions.filter { $0.intersects(end) }.reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
            // a window's controls along the top (iPadOS): everything starts below them
            let top = safe.top
            var p = Parts.landscape(size: CGSize(width: size.width, height: size.height - top), safe: safe, islandLeft: islandLeft,
                                    drawerOpen: drawerOpen, camera: camera?.offsetBy(dx: 0, dy: -top), board: board)
            if top > 0 { p.shift(dy: top) }
            self.init(p, mode: mode, lefty: lefty, fold: surround.fold)
        case .portrait:
            // The camera may take a corner (the Duo's outer display): the pad starts below it. There the safe area also keeps a band
            // down one side, for the bars iOS puts there (84 pt); with the status bar hidden nothing's in it, and where UIKit says what
            // covers the glass that's all that's avoided: the keys get the whole width
            let known = !surround.occlusions.isEmpty
            var frame = CGRect(x: max(8, known ? 0 : safe.left), y: max(safe.top - 6, 16), width: 0, height: 0)
            frame.size = CGSize(width: size.width - frame.minX - max(8, known ? 0 : safe.right), height: size.height - frame.minY - max(safe.bottom - 6, 12))
            for o in surround.occlusions where o.intersects(frame) && o.minY <= frame.minY + 1 { frame = frame.divided(atDistance: o.maxY + 4 - frame.minY, from: .minYEdge).remainder }
            let p = Parts.portrait(in: frame, lefty: lefty, picture: showing ? aspect : nil, board: board)
            self.init(p, mode: mode, lefty: lefty, fold: surround.fold)
        case .big:
            let p = Parts.big(size: size, safe: safe, lefty: lefty, drawerOpen: drawerOpen, surround: surround, aspect: aspect, board: board)
            self.init(p, mode: mode, lefty: lefty, fold: surround.fold)
        }
    }

    private init(_ p: Parts, mode: Mode, lefty: Bool, fold: CGRect?) {
        self.mode = mode
        self.fold = fold
        pad = p.pad; thumbPad = p.thumbPad; talk = p.talk; list = p.list; listSplit = p.listSplit; keySize = p.keySize; dock = p.dock
        arrowKey = p.arrowKey; appsKey = p.appsKey; strip = p.strip; keyboardButton = p.keyboardButton; settingsButton = p.settingsButton
        screenButton = p.screenButton; transferButton = p.transferButton; findButton = p.findButton; rail = p.rail; drawerButton = p.drawerButton; drawer = p.drawer
        board = p.board
        halves = p.halves; drawerMatters = p.drawerMatters; keysOut = p.keysOut; stageAlignY = p.stageAlignY
        // one finger scrolls along the side by the thumb, unless the fold is there: then along the other
        // (on its side a phone's thumb is at the end without the island, whichever hand)
        var side = mode == .landscape ? p.appsKey.midX < p.pad.midX : lefty
        if let f = fold, f.height > f.width, abs(side ? f.maxX - p.pad.minX : p.pad.maxX - f.minX) < Self.scrollEdgeWidth(p.pad.width) * 2 { side.toggle() }
        scrollsLeft = side
        scrollEdge = Self.scrollEdge(width: p.pad.width, left: side)
        // across the fold the strip would straddle it: the part nearer the thumb, below it
        if let f = fold, f.width > f.height, f.minY > p.pad.minY, f.maxY < p.pad.maxY {
            scrollEdgeY = (f.maxY - p.pad.minY)...p.pad.height
        } else {
            scrollEdgeY = nil
        }
        thumbScrollEdge = p.thumbPad.map { Self.scrollEdge(width: $0.width, left: lefty) }
        hintArea = Self.clear(p.pad, of: fold, lefty: lefty)
    }

    /// `inset`: what's lost at that side to the island, with the pad under it (full screen)
    static func scrollEdge(width: CGFloat, left: Bool, inset: CGFloat = 0) -> ClosedRange<CGFloat> {
        let w = scrollEdgeWidth(width) + inset
        return left ? 0...w : (width - w)...width
    }

    /// The edge's mark, in the pad's coordinates: half the strip's height, so it reads as something to slide along, and clear of what
    /// stands in the corners.
    static func edgeMark(_ edge: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>, width: CGFloat, inset: CGFloat = 0) -> CGRect {
        let room = y.upperBound - y.lowerBound, w: CGFloat = 4, off: CGFloat = 6
        let h = max(0, min(room - 24, max(96, min(360, room * 0.5))))
        return CGRect(x: edge.lowerBound <= 0 ? inset + off : width - inset - off - w, y: (y.lowerBound + y.upperBound - h) / 2, width: w, height: h)
    }

    /// The part of the stage, in its own coordinates, that a fold doesn't cross: the side nearer the thumb (below, or towards the hand).
    static func clear(_ stage: CGRect, of fold: CGRect?, lefty: Bool) -> CGRect {
        let all = CGRect(origin: .zero, size: stage.size)
        guard let f = fold?.offsetBy(dx: -stage.minX, dy: -stage.minY), f.intersects(all) else { return all }
        if f.height > f.width {
            return lefty ? CGRect(x: 0, y: 0, width: max(0, f.minX), height: all.height)
                : CGRect(x: f.maxX, y: 0, width: max(0, all.width - f.maxX), height: all.height)
        }
        return CGRect(x: 0, y: f.maxY, width: all.width, height: max(0, all.height - f.maxY))
    }
}

/// The rectangles, before they're a PadLayout.
private struct Parts {
    var pad = CGRect.zero, thumbPad: CGRect?, talk = CGRect.zero, list = CGRect.zero, listSplit: (at: CGFloat, width: CGFloat)?
    var keySize = CGSize.zero, dock: [CGRect] = [], arrowKey = CGRect.zero, appsKey = CGRect.zero, strip = CGRect.zero
    var keyboardButton = CGRect.zero, settingsButton = CGRect.zero, screenButton = CGRect.zero, findButton = CGRect.zero
    var transferButton = CGRect.zero
    var rail: CGRect?, drawerButton = CGRect.zero, drawer = CGRect.zero, halves: [CGRect] = [], board: PadLayout.Board?
    var drawerMatters = false, keysOut = true, stageAlignY: CGFloat = 1

    static let gap = PadLayout.gap
    /// portrait: between the pad and the top row, whose arrow key is a raised box as tall as the row
    static let padGap: CGFloat = 8

    mutating func shift(dy: CGFloat) {
        func m(_ r: inout CGRect) { r = r.offsetBy(dx: 0, dy: dy) }
        for r in [\Parts.pad, \.talk, \.list, \.arrowKey, \.appsKey, \.strip, \.keyboardButton, \.settingsButton, \.screenButton,
                  \.transferButton, \.findButton, \.drawerButton, \.drawer] as [WritableKeyPath<Parts, CGRect>] { m(&self[keyPath: r]) }
        dock = dock.map { $0.offsetBy(dx: 0, dy: dy) }
        rail = rail?.offsetBy(dx: 0, dy: dy)
        thumbPad = thumbPad?.offsetBy(dx: 0, dy: dy)
        if var b = board {
            b.frame = b.frame.offsetBy(dx: 0, dy: dy)
            b.quick = b.quick.map { $0.offsetBy(dx: 0, dy: dy) }
            board = b
        }
    }
    static func keys(_ width: CGFloat, _ cols: Int = Deck.columns) -> CGFloat { (width - gap * CGFloat(cols - 1)) / CGFloat(cols) }

    // MARK: portrait

    /// `frame`: the room, margins taken off. The block of keys at its bottom, the pad above.
    /// `picture`: the computer's screen is showing, this wide for its height. Across a phone it's far shorter than the pad: the keys take
    /// a little of the room, as taller keys rather than more of them, and the picture sits in the middle of what's left, so the black
    /// is split above and below it instead of one band over it.
    static func portrait(in frame: CGRect, lefty: Bool, picture: CGFloat? = nil, board: Bool = false) -> Parts {
        var p = Parts()
        let width = min(frame.width, PadLayout.blockWidth)
        let rows = CGFloat(PadLayout.visibleRows)
        let t = PadLayout.stripHeight, drop: CGFloat = 6
        func total(_ h: CGFloat) -> CGFloat { t + rows * h + (rows - 1) * gap + drop + h }
        var h = PadLayout.keyHeight
        if let a = picture, a > 0 {
            let spare = frame.height - total(h) - Self.padGap - frame.width / a
            let most = min(PadLayout.pictureKeyHeight, keys(width) * PadLayout.wideKeyShape)
            if spare > 0 { h = max(h, min(most, h + spare / (rows + 1))) }
        }
        // the computer keyboard: five rows of ten in the list's place, the keys a little lower, the dock as it is
        var heights: [CGFloat] = []
        if board {
            h = PadLayout.keyHeight
            let rest = t + drop + h + 4 * gap
            let key = min(PadLayout.boardKeyHeight, max(36, floor((frame.height - rest - 140) / 5)))
            heights = Array(repeating: key, count: 5)
        }
        let listH = board ? FullKeys.height(heights) : rows * h + (rows - 1) * gap
        let total = t + listH + drop + h
        let block = CGRect(x: frame.midX - width / 2, y: frame.maxY - total, width: width, height: total)
        p.drawer = block
        p.pad = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: block.minY - frame.minY - Self.padGap)
        p.keySize = CGSize(width: keys(width), height: h)

        // the top row: settings first, the arrow key by the thumb. Left-handed it comes in from the edge, past settings, so a slide to
        // the left has room. Between them the tabs, then Transfer, the screen and the system keyboard. The tabs used to take all the room the icons didn't, so the four
        // tabs stood far apart while the icons touched, and the screen's lit patch (40 pt) ran over its neighbours (founder, 2026-11-27).
        // Now the icons get what four tabs at their size leave, up to 44 pt each, so tabs and icons stand about as far apart. Find Pointer
        // left the row then: it's a key on 更多 (Deck.findPointer)
        let settingsW: CGFloat = width < 374 ? 32 : 36, arrowW: CGFloat = 82
        let room = width - settingsW - arrowW - 4
        let iconW = min(44, max(32, floor((room - 4 * PadLayout.tabRoom) / 3)))
        p.settingsButton = CGRect(x: block.minX, y: block.minY, width: settingsW, height: t - 2)
        p.arrowKey = CGRect(x: lefty ? p.settingsButton.maxX + 4 : block.maxX - arrowW, y: block.minY, width: arrowW, height: t - 2)
        let rowEnd = lefty ? block.maxX : p.arrowKey.minX - 4
        p.keyboardButton = CGRect(x: rowEnd - iconW, y: block.minY, width: iconW, height: t - 2)
        p.screenButton = CGRect(x: rowEnd - iconW * 2, y: block.minY, width: iconW, height: t - 2)
        p.transferButton = CGRect(x: rowEnd - iconW * 3, y: block.minY, width: iconW, height: t - 2)
        let stripX = lefty ? p.arrowKey.maxX : p.settingsButton.maxX
        p.strip = CGRect(x: stripX, y: block.minY, width: p.transferButton.minX - stripX, height: t - 2)
        p.list = CGRect(x: block.minX, y: block.minY + t, width: width, height: listH)
        if board { p.board = PadLayout.Board(frame: p.list, tier: .ten, heights: heights) }

        // the dock: ten even parts, the last the talk key
        let dockY = block.maxY - h, n = Deck.dockCount + 1
        let unit = (width - gap * CGFloat(n - 1)) / CGFloat(n)
        func spot(_ c: Int) -> CGRect { CGRect(x: block.minX + CGFloat(c) * (unit + gap), y: dockY, width: unit, height: h) }
        p.talk = spot(lefty ? 0 : n - 1)
        // left-handed it's a mirror, so the same keys are by the thumb
        p.dock = (0..<Deck.dockCount).map { spot(lefty ? Deck.dockCount - $0 : $0) }
        p.stageAlignY = picture == nil ? 1 : 0.5
        return p
    }

    // MARK: landscape

    static func landscape(size: CGSize, safe: UIEdgeInsets, islandLeft: Bool, drawerOpen: Bool, camera: CGRect? = nil, board: Bool = false) -> Parts {
        var p = Parts()
        let margin = islandLeft ? safe.left : safe.right
        func fromIsland(_ inset: CGFloat, _ w: CGFloat, _ y: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: islandLeft ? inset : size.width - inset - w, y: y, width: w, height: h)
        }
        func fromFar(_ inset: CGFloat, _ w: CGFloat, _ y: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: islandLeft ? size.width - inset - w : inset, y: y, width: w, height: h)
        }

        // the island's end: two above it, three below. A camera in a corner instead: all five below it. Three 42 pt buttons don't fit
        // between a phone's island and its corner (2026-11-26, Transfer): there all five are as tall as three that do
        let ctrlW: CGFloat = 46, clear: CGFloat = 24, islandHalf: CGFloat = 66
        let btn: CGFloat = min(42, max(32, floor((size.height / 2 - islandHalf - clear - gap * 2) / 3)))
        let ctrlIn = margin > ctrlW + 8 ? (margin - ctrlW) / 2 : 8
        let ctrlEnd = max(margin, ctrlIn + ctrlW)
        if let c = camera, c.midY < size.height * 0.35 {
            let top = c.maxY + 8
            p.settingsButton = fromIsland(ctrlIn, ctrlW, top, btn)
            p.findButton = fromIsland(ctrlIn, ctrlW, top + btn + gap, btn)
            p.transferButton = fromIsland(ctrlIn, ctrlW, size.height - clear - btn * 3 - gap * 2, btn)
            p.screenButton = fromIsland(ctrlIn, ctrlW, size.height - clear - btn * 2 - gap, btn)
            p.keyboardButton = fromIsland(ctrlIn, ctrlW, size.height - clear - btn, btn)
        } else if let c = camera, c.midY > size.height * 0.65 {
            let bottom = c.minY - 8
            p.settingsButton = fromIsland(ctrlIn, ctrlW, clear, btn)
            p.findButton = fromIsland(ctrlIn, ctrlW, clear + btn + gap, btn)
            p.transferButton = fromIsland(ctrlIn, ctrlW, bottom - btn * 3 - gap * 2, btn)
            p.screenButton = fromIsland(ctrlIn, ctrlW, bottom - btn * 2 - gap, btn)
            p.keyboardButton = fromIsland(ctrlIn, ctrlW, bottom - btn, btn)
        } else {
            p.settingsButton = fromIsland(ctrlIn, ctrlW, clear, btn)
            p.findButton = fromIsland(ctrlIn, ctrlW, clear + btn + gap, btn)
            p.transferButton = fromIsland(ctrlIn, ctrlW, size.height - clear - btn * 3 - gap * 2, btn)
            p.screenButton = fromIsland(ctrlIn, ctrlW, size.height - clear - btn * 2 - gap, btn)
            p.keyboardButton = fromIsland(ctrlIn, ctrlW, size.height - clear - btn, btn)
        }
        p.rail = fromIsland(0, ctrlEnd, 0, size.height)

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
        p.drawerButton = next(toggle)
        p.appsKey = next(unit)
        let esc = next(unit)
        p.arrowKey = next(arrow)
        let delete = next(unit)
        let enter = next(unit)
        p.talk = fromFar(far, thumbW, y, top + tall - y)

        // the keys, beside that: pages, then the rest of the dock, as tall as the screen allows
        let inner = far + thumbW + 6
        let w = min(PadLayout.wideKeysWidth, floor((size.width - ctrlEnd - inner) * 0.5))
        let tabs: CGFloat = 30, drop: CGFloat = 6, edge: CGFloat = 8
        let rows = CGFloat(PadLayout.visibleRows)
        let h = min(PadLayout.wideKeyHeight, floor(keys(w) * PadLayout.wideKeyShape), floor((size.height - edge * 2 - tabs - drop - gap * rows) / (rows + 1)))
        let listH = rows * h + (rows - 1) * gap
        let total = tabs + listH + drop + h
        let blockY = (size.height - total) / 2
        let block = fromFar(inner, w, blockY, total)
        p.drawer = block
        p.strip = CGRect(x: block.minX, y: blockY, width: w, height: tabs)
        p.list = CGRect(x: block.minX, y: blockY + tabs, width: w, height: listH)
        let keyW = keys(w)
        p.keySize = CGSize(width: keyW, height: h)
        let rowY = block.maxY - h
        var column = 0
        p.dock = (0..<Deck.dockCount).map { i in
            if i == PadLayout.thumbSlots.esc { return esc }
            if i == PadLayout.thumbSlots.delete { return delete }
            if i == PadLayout.thumbSlots.enter { return enter }
            defer { column += 1 }
            return CGRect(x: block.minX + CGFloat(column) * (keyW + gap), y: rowY, width: keyW, height: h)
        }

        let reach = inner + (drawerOpen && !board ? w + 6 : 0)
        let padX = islandLeft ? ctrlEnd + 6 : reach
        p.pad = CGRect(x: padX, y: 6, width: size.width - ctrlEnd - 6 - reach, height: size.height - 12)
        p.drawerMatters = true
        p.keysOut = drawerOpen && !board
        if board {
            // five rows between the two columns, which stay; the stage over them keeps not much less than half the height
            let bottom = max(6, min(safe.bottom, 10)), key = max(32, min(40, floor((size.height * 0.55 - 4 * gap) / 5)))
            let heights = Array(repeating: key, count: 5), tall = FullKeys.height(heights)
            let f = CGRect(x: p.pad.minX, y: size.height - bottom - tall, width: p.pad.width, height: tall)
            p.board = PadLayout.Board(frame: f, tier: .thirteen, heights: heights)
            p.pad.size.height = f.minY - 8 - p.pad.minY
        }
        p.stageAlignY = 0.5
        return p
    }

    // MARK: big

    static func big(size: CGSize, safe: UIEdgeInsets, lefty: Bool, drawerOpen: Bool, surround s: PadSurround, aspect: CGFloat, board: Bool = false) -> Parts {
        let m: CGFloat = 10
        let inner = CGRect(x: safe.left + m, y: max(safe.top, m), width: size.width - safe.left - safe.right - m * 2,
                           height: size.height - max(safe.top, m) - max(safe.bottom - 4, m))
        let fold = s.fold

        // partly folded like a book: the picture on one page, a phone's remote on the other (by the hand that holds it)
        if s.book, let f = fold, f.minX > inner.minX + 200, f.maxX < inner.maxX - 200 {
            var p = Parts()
            let leftPage = CGRect(x: inner.minX, y: inner.minY, width: f.minX - 8 - inner.minX, height: inner.height)       // a little off the fold
            let rightPage = CGRect(x: f.maxX + 8, y: inner.minY, width: inner.maxX - f.maxX - 8, height: inner.height)
            let remote = lefty ? leftPage : rightPage
            p = portrait(in: remote, lefty: lefty, board: board)
            p.thumbPad = p.pad
            p.pad = lefty ? rightPage : leftPage
            p.stageAlignY = 0.5
            return p
        }

        if board { return bigBoard(inner: inner, lefty: lefty, surround: s, aspect: aspect) }
        var p = Parts()
        let h = PadLayout.keyHeight, drop: CGFloat = 6
        let rows = CGFloat(PadLayout.visibleRows)

        // the halves: a thumb's reach each, never over a fold that runs down the middle
        var half = min(PadLayout.halfWidth, floor((inner.width - PadLayout.thumbPadWidth - 16) / 2))
        if let f = fold, f.height > f.width, f.minX > inner.minX, f.maxX < inner.maxX {
            half = min(half, f.minX - 8 - inner.minX, inner.maxX - (f.maxX + 8))
        }

        // laptop-like: the stage above the fold, everything else below. Lying on a table it's typed on with fingers, and the half has
        // the height: the pages' keys grow into it, key-shaped, instead of leaving a gap under the fold
        let laptop = s.laptop && fold != nil
        let below = laptop ? inner.maxY - fold!.maxY - 4 : inner.height
        let pageKeyW = keys(half, Deck.columns / 2)
        // the tall top row, unless the keys wouldn't fit under a laptop-like fold with it: then the phone's
        let t = !laptop || below >= PadLayout.bigStripHeight + rows * h + (rows - 1) * gap + drop + h ? PadLayout.bigStripHeight : PadLayout.stripHeight
        var rowH = h
        if laptop {
            let spare = below - (t + rows * h + (rows - 1) * gap + drop + h)
            if spare > 0 { rowH = floor(min(PadLayout.wideKeyHeight, pageKeyW * PadLayout.wideKeyShape, h + spare / rows)) }
        }
        let listH = rows * rowH + (rows - 1) * gap
        let full = t + listH + drop + h, away = t + gap + h
        // keys put away only where that gives the picture room: the band a whole picture leaves under it is free
        let freeBand = inner.height - 8 - inner.width / max(aspect, 0.5)
        p.drawerMatters = !laptop && freeBand < full && below >= full
        p.keysOut = below >= full && (!p.drawerMatters || drawerOpen)
        let deckH = p.keysOut ? full : away
        let deck = CGRect(x: inner.minX, y: inner.maxY - deckH, width: inner.width, height: deckH)
        p.drawer = deck
        // right-handed; left-handed the same, mirrored
        func x(_ r: CGRect) -> CGRect { lefty ? CGRect(x: inner.minX + inner.maxX - r.maxX, y: r.minY, width: r.width, height: r.height) : r }
        let leftHalf = CGRect(x: deck.minX, y: deck.minY, width: half, height: deckH)
        let rightHalf = CGRect(x: deck.maxX - half, y: deck.minY, width: half, height: deckH)
        p.halves = [x(leftHalf), x(rightHalf)]

        let stageBottom = laptop ? fold!.minY : deck.minY - 8
        p.pad = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: stageBottom - inner.minY)
        p.stageAlignY = laptop ? 0.5 : 1
        let padTop = laptop ? fold!.maxY + 4 : deck.minY
        let between = CGRect(x: leftHalf.maxX + 8, y: padTop, width: rightHalf.minX - 8 - (leftHalf.maxX + 8), height: deck.maxY - padTop)
        p.thumbPad = between.width >= 100 ? x(between) : nil

        // the top row. The non-dominant thumb's half: what's rarely needed, from the edge in, and ⌘Tab nearest the middle, so a slide
        // has the trackpad to run over. The dominant thumb's: the arrow key nearest the middle, room every way, then the tabs
        let topH = t - 2
        if t > PadLayout.stripHeight {
            // tall: the arrow key square, each edge 44 pt deep, and ⌘Tab the same size across from it. The four controls two by two at
            // the edge, the tabs beside the arrow key
            let side = topH, rest = half - side - 4
            let cell = CGSize(width: floor((rest - 4) / 2), height: floor((topH - 4) / 2))
            func control(_ col: Int, _ row: Int) -> CGRect {
                CGRect(x: leftHalf.minX + CGFloat(col) * (rest - cell.width), y: deck.minY + CGFloat(row) * (topH - cell.height),
                       width: cell.width, height: cell.height)
            }
            p.settingsButton = x(control(0, 0))
            p.findButton = x(control(1, 0))
            // the lower row in thirds: the screen, Transfer beside it, the keyboard under find
            let third = floor((rest - 8) / 3), lowY = deck.minY + topH - cell.height
            func low(_ i: Int) -> CGRect {
                CGRect(x: leftHalf.minX + CGFloat(i) * (rest - third) / 2, y: lowY, width: third, height: cell.height)
            }
            p.screenButton = x(low(0))
            p.transferButton = x(low(1))
            p.keyboardButton = x(low(2))
            p.appsKey = x(CGRect(x: leftHalf.maxX - side, y: deck.minY, width: side, height: topH))
            p.arrowKey = x(CGRect(x: rightHalf.minX, y: deck.minY, width: side, height: topH))
            p.strip = x(CGRect(x: rightHalf.minX + side + 4, y: deck.minY, width: rest, height: topH))
        } else {
            let n: CGFloat = 6
            let item = floor((half - 4 * (n - 1)) / n)
            func slot(_ i: Int) -> CGRect { CGRect(x: leftHalf.minX + CGFloat(i) * (item + 4), y: deck.minY, width: item, height: topH) }
            p.settingsButton = x(slot(0))
            p.findButton = x(slot(1))
            p.screenButton = x(slot(2))
            p.transferButton = x(slot(3))
            p.keyboardButton = x(slot(4))
            p.appsKey = x(CGRect(x: slot(5).minX, y: deck.minY, width: leftHalf.maxX - slot(5).minX, height: topH))
            let arrowW: CGFloat = 82
            p.arrowKey = x(CGRect(x: rightHalf.minX, y: deck.minY, width: arrowW, height: topH))
            p.strip = x(CGRect(x: rightHalf.minX + arrowW + 4, y: deck.minY, width: half - arrowW - 4, height: topH))
        }

        // the pages: one list across the deck, each row split around the middle
        p.list = CGRect(x: deck.minX, y: deck.minY + t, width: deck.width, height: listH)
        p.listSplit = (at: half, width: deck.width - half * 2)
        p.keySize = CGSize(width: pageKeyW, height: rowH)

        // the dock: the modifiers and ⇥ under one thumb, what ends things and the talk key in the other's corner
        let dockY = deck.maxY - h
        let leftCount = PadLayout.bigSplit, rightCount = Deck.dockCount - leftCount + 1
        func spot(_ r: CGRect, _ c: Int, of count: Int) -> CGRect {
            let w = keys(r.width, count)
            return CGRect(x: r.minX + CGFloat(c) * (w + gap), y: dockY, width: w, height: h)
        }
        p.dock = (0..<Deck.dockCount).map { i in x(i < leftCount ? spot(leftHalf, i, of: leftCount) : spot(rightHalf, i - leftCount, of: rightCount)) }
        p.talk = x(spot(rightHalf, rightCount - 1, of: rightCount))
        return p
    }

    /// The computer keyboard on a big screen: as wide as the screen, under the stage, a row of controls over it. What the halves and the
    /// trackpad between them took is about its height, so the picture keeps its own. Where a whole picture leaves a band under it (upright),
    /// the band is a trackpad under the keys, as on a laptop; where it leaves bands at its sides, those are the trackpad.
    static func bigBoard(inner: CGRect, lefty: Bool, surround s: PadSurround, aspect: CGFloat) -> Parts {
        var p = Parts()
        let laptop = s.laptop && s.fold != nil
        // a fold that runs down the middle, lying flat: the keys go across it, as they do on any one screen
        let tier = FullTier.big(width: inner.width), strip: CGFloat = 44, drop: CGFloat = 6, padGap: CGFloat = 8
        let upright = inner.height > inner.width
        let below = laptop ? inner.maxY - s.fold!.maxY - 4 : inner.height
        let unit = FullTier.unit(inner.width, tier)
        var key: CGFloat = upright ? min(56, max(44, unit * 1.2)) : 48, f: CGFloat = upright ? 40 : 36
        func tall() -> CGFloat { strip + drop + f + 5 * key + 5 * gap }
        // never more than two thirds of a short window, and under a laptop's fold all it can
        let room = laptop ? below : min(inner.height * 0.62, inner.height - 140)
        if tall() > room { key = max(34, floor((room - strip - drop - f - 5 * gap) / 5)) }
        if tall() > room { f = max(28, f - (tall() - room)) }
        let heights = [f] + Array(repeating: key, count: 5), boardH = FullKeys.height(heights), deckH = strip + drop + boardH
        // a band under the whole picture
        let band = laptop ? 0 : inner.height - inner.width / max(aspect, 0.5) - padGap - deckH - padGap
        let pad = band >= PadLayout.boardPadHeight ? band : 0
        let deckY = laptop ? s.fold!.maxY + 4 : inner.maxY - deckH - (pad > 0 ? pad + padGap : 0)
        let stageBottom = laptop ? s.fold!.minY : deckY - padGap
        p.pad = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: stageBottom - inner.minY)
        p.stageAlignY = laptop ? 0.5 : 1
        if pad > 0 { p.thumbPad = CGRect(x: inner.minX, y: inner.maxY - pad, width: inner.width, height: pad) }

        // the controls, which keyboard and what's held, and the shortcuts: one row
        let c: CGFloat = 42
        var x = inner.minX
        func next(_ w: CGFloat, _ after: CGFloat = 4) -> CGRect {
            defer { x += w + after }
            return CGRect(x: x, y: deckY, width: w, height: strip)
        }
        p.settingsButton = next(c)
        p.findButton = next(c)
        p.screenButton = next(c)
        p.transferButton = next(c)
        p.keyboardButton = next(c, 10)
        let quickW: CGFloat = min(64, max(44, (inner.maxX - x - 320 - 5 * gap) / 6)), quicks = inner.maxX - x - 320 - 5 * gap >= 44 * 6 ? 6 : 4
        let quickTotal = CGFloat(quicks) * quickW + CGFloat(quicks - 1) * gap
        p.strip = CGRect(x: x, y: deckY, width: max(0, inner.maxX - quickTotal - 10 - x), height: strip)
        let qx = inner.maxX - quickTotal
        let quick = (0..<quicks).map { CGRect(x: qx + CGFloat($0) * (quickW + gap), y: deckY, width: quickW, height: strip) }
        let frame = CGRect(x: inner.minX, y: deckY + strip + drop, width: inner.width, height: boardH)
        p.board = PadLayout.Board(frame: frame, tier: tier, heights: heights, bandsArePad: pad == 0, quick: quick)
        p.drawer = CGRect(x: inner.minX, y: deckY, width: inner.width, height: deckH)
        p.drawerMatters = false
        p.keysOut = false
        // the talk key is one of the board's
        let spots = FullKeys.place(FullKeys.rows(tier, for: .mac), in: frame, tier: tier, heights: heights)
        p.talk = spots.first { $0.key.kind == .talk }?.rect ?? .zero
        return p
    }
}
