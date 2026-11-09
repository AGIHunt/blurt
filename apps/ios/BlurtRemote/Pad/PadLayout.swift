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
    /// where one finger scrolls on the pad, across it
    let scrollEdge: ClosedRange<CGFloat>
    /// and down it: never across the fold
    let scrollEdgeY: ClosedRange<CGFloat>?
    /// the same on the thumb pad
    let thumbScrollEdge: ClosedRange<CGFloat>?
    /// where a picture smaller than the stage sits, 0 top … 1 bottom: near the keys
    let stageAlignY: CGFloat
    /// on the stage: where words, chips and a message go, clear of the fold, on the thumb's side
    let hintArea: CGRect
    let fold: CGRect?

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
    /// the dock's esc, return and space, as it ships: in landscape these stay out by the thumb with the keys put away. The rest are for keys
    static let thumbSlots = (esc: Deck.dockCount - 4, enter: Deck.dockCount - 2, space: Deck.dockCount - 1)

    static func staysOut(_ i: Int) -> Bool { i == thumbSlots.esc || i == thumbSlots.enter || i == thumbSlots.space }

    static func mode(for size: CGSize) -> Mode {
        if size.width >= bigWidth && size.height >= bigHeight { return .big }
        return size.width > size.height ? .landscape : .portrait
    }

    /// `islandLeft`: which end has the camera in landscape. `aspect`: the computer's screen, width ÷ height
    init(size: CGSize, safe: UIEdgeInsets, lefty: Bool, islandLeft: Bool = true, drawerOpen: Bool = true,
         surround: PadSurround = .none, aspect: CGFloat = 1.6) {
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
                                    drawerOpen: drawerOpen, camera: camera?.offsetBy(dx: 0, dy: -top))
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
            let p = Parts.portrait(in: frame, lefty: lefty)
            self.init(p, mode: mode, lefty: lefty, fold: surround.fold)
        case .big:
            let p = Parts.big(size: size, safe: safe, lefty: lefty, drawerOpen: drawerOpen, surround: surround, aspect: aspect)
            self.init(p, mode: mode, lefty: lefty, fold: surround.fold)
        }
    }

    private init(_ p: Parts, mode: Mode, lefty: Bool, fold: CGRect?) {
        self.mode = mode
        self.fold = fold
        pad = p.pad; thumbPad = p.thumbPad; talk = p.talk; list = p.list; listSplit = p.listSplit; keySize = p.keySize; dock = p.dock
        arrowKey = p.arrowKey; appsKey = p.appsKey; strip = p.strip; keyboardButton = p.keyboardButton; settingsButton = p.settingsButton
        screenButton = p.screenButton; findButton = p.findButton; rail = p.rail; drawerButton = p.drawerButton; drawer = p.drawer
        halves = p.halves; drawerMatters = p.drawerMatters; keysOut = p.keysOut; stageAlignY = p.stageAlignY
        // one finger scrolls along the side by the thumb, unless the fold is there: then along the other
        var side = lefty
        if let f = fold, f.height > f.width, abs(lefty ? f.maxX - p.pad.minX : p.pad.maxX - f.minX) < Self.scrollEdgeWidth * 2 { side.toggle() }
        scrollEdge = Self.scrollEdge(width: p.pad.width, lefty: side)
        // across the fold the strip would straddle it: the part nearer the thumb, below it
        if let f = fold, f.width > f.height, f.minY > p.pad.minY, f.maxY < p.pad.maxY {
            scrollEdgeY = (f.maxY - p.pad.minY)...p.pad.height
        } else {
            scrollEdgeY = nil
        }
        thumbScrollEdge = p.thumbPad.map { Self.scrollEdge(width: $0.width, lefty: lefty) }
        hintArea = Self.clear(p.pad, of: fold, lefty: lefty)
    }

    static func scrollEdge(width: CGFloat, lefty: Bool) -> ClosedRange<CGFloat> {
        lefty ? 0...scrollEdgeWidth : (width - scrollEdgeWidth)...width
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
    var rail: CGRect?, drawerButton = CGRect.zero, drawer = CGRect.zero, halves: [CGRect] = []
    var drawerMatters = false, keysOut = true, stageAlignY: CGFloat = 1

    static let gap = PadLayout.gap

    mutating func shift(dy: CGFloat) {
        func m(_ r: inout CGRect) { r = r.offsetBy(dx: 0, dy: dy) }
        for r in [\Parts.pad, \.talk, \.list, \.arrowKey, \.appsKey, \.strip, \.keyboardButton, \.settingsButton, \.screenButton,
                  \.findButton, \.drawerButton, \.drawer] as [WritableKeyPath<Parts, CGRect>] { m(&self[keyPath: r]) }
        dock = dock.map { $0.offsetBy(dx: 0, dy: dy) }
        rail = rail?.offsetBy(dx: 0, dy: dy)
        thumbPad = thumbPad?.offsetBy(dx: 0, dy: dy)
    }
    static func keys(_ width: CGFloat, _ cols: Int = Deck.columns) -> CGFloat { (width - gap * CGFloat(cols - 1)) / CGFloat(cols) }

    // MARK: portrait

    /// `frame`: the room, margins taken off. The block of keys at its bottom, the pad above.
    static func portrait(in frame: CGRect, lefty: Bool) -> Parts {
        var p = Parts()
        let width = min(frame.width, PadLayout.blockWidth), h = PadLayout.keyHeight
        let rows = CGFloat(PadLayout.visibleRows)
        let listH = rows * h + (rows - 1) * gap
        let t = PadLayout.stripHeight, drop: CGFloat = 6
        let total = t + listH + drop + h
        let block = CGRect(x: frame.midX - width / 2, y: frame.maxY - total, width: width, height: total)
        p.drawer = block
        p.pad = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: block.minY - frame.minY - 2)
        p.keySize = CGSize(width: keys(width), height: h)

        // the top row: settings first, the arrow key by the thumb. Left-handed it comes in from the edge, past settings, so a slide to
        // the left has room
        let iconW: CGFloat = width < 374 ? 32 : 36, arrowW: CGFloat = 82     // a narrow phone keeps the room for the tabs
        p.settingsButton = CGRect(x: block.minX, y: block.minY, width: iconW, height: t - 2)
        p.arrowKey = CGRect(x: lefty ? p.settingsButton.maxX + 4 : block.maxX - arrowW, y: block.minY, width: arrowW, height: t - 2)
        let rowEnd = lefty ? block.maxX : p.arrowKey.minX - 4
        p.keyboardButton = CGRect(x: rowEnd - iconW, y: block.minY, width: iconW, height: t - 2)
        p.screenButton = CGRect(x: rowEnd - iconW * 2, y: block.minY, width: iconW, height: t - 2)
        p.findButton = CGRect(x: rowEnd - iconW * 3, y: block.minY, width: iconW, height: t - 2)
        let stripX = lefty ? p.arrowKey.maxX : p.settingsButton.maxX
        p.strip = CGRect(x: stripX, y: block.minY, width: p.findButton.minX - stripX, height: t - 2)
        p.list = CGRect(x: block.minX, y: block.minY + t, width: width, height: listH)

        // the dock: ten even parts, the last the talk key
        let dockY = block.maxY - h, n = Deck.dockCount + 1
        let unit = (width - gap * CGFloat(n - 1)) / CGFloat(n)
        func spot(_ c: Int) -> CGRect { CGRect(x: block.minX + CGFloat(c) * (unit + gap), y: dockY, width: unit, height: h) }
        p.talk = spot(lefty ? 0 : n - 1)
        // left-handed it's a mirror, so the same keys are by the thumb
        p.dock = (0..<Deck.dockCount).map { spot(lefty ? Deck.dockCount - $0 : $0) }
        p.stageAlignY = 1
        return p
    }

    // MARK: landscape

    static func landscape(size: CGSize, safe: UIEdgeInsets, islandLeft: Bool, drawerOpen: Bool, camera: CGRect? = nil) -> Parts {
        var p = Parts()
        let margin = islandLeft ? safe.left : safe.right
        func fromIsland(_ inset: CGFloat, _ w: CGFloat, _ y: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: islandLeft ? inset : size.width - inset - w, y: y, width: w, height: h)
        }
        func fromFar(_ inset: CGFloat, _ w: CGFloat, _ y: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: islandLeft ? size.width - inset - w : inset, y: y, width: w, height: h)
        }

        // the island's end: two above it, two below. A camera in a corner instead: all four below it
        let ctrlW: CGFloat = 46, btn: CGFloat = 42, clear: CGFloat = 24
        let ctrlIn = margin > ctrlW + 8 ? (margin - ctrlW) / 2 : 8
        let ctrlEnd = max(margin, ctrlIn + ctrlW)
        if let c = camera, c.midY < size.height * 0.35 {
            let top = c.maxY + 8
            p.settingsButton = fromIsland(ctrlIn, ctrlW, top, btn)
            p.findButton = fromIsland(ctrlIn, ctrlW, top + btn + gap, btn)
            p.screenButton = fromIsland(ctrlIn, ctrlW, size.height - clear - btn * 2 - gap, btn)
            p.keyboardButton = fromIsland(ctrlIn, ctrlW, size.height - clear - btn, btn)
        } else if let c = camera, c.midY > size.height * 0.65 {
            let bottom = c.minY - 8
            p.settingsButton = fromIsland(ctrlIn, ctrlW, clear, btn)
            p.findButton = fromIsland(ctrlIn, ctrlW, clear + btn + gap, btn)
            p.screenButton = fromIsland(ctrlIn, ctrlW, bottom - btn * 2 - gap, btn)
            p.keyboardButton = fromIsland(ctrlIn, ctrlW, bottom - btn, btn)
        } else {
            p.settingsButton = fromIsland(ctrlIn, ctrlW, clear, btn)
            p.findButton = fromIsland(ctrlIn, ctrlW, clear + btn + gap, btn)
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
        let enter = next(unit)
        let space = next(unit)
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
            if i == PadLayout.thumbSlots.enter { return enter }
            if i == PadLayout.thumbSlots.space { return space }
            defer { column += 1 }
            return CGRect(x: block.minX + CGFloat(column) * (keyW + gap), y: rowY, width: keyW, height: h)
        }

        let reach = inner + (drawerOpen ? w + 6 : 0)
        let padX = islandLeft ? ctrlEnd + 6 : reach
        p.pad = CGRect(x: padX, y: 6, width: size.width - ctrlEnd - 6 - reach, height: size.height - 12)
        p.drawerMatters = true
        p.keysOut = drawerOpen
        p.stageAlignY = 0.5
        return p
    }

    // MARK: big

    static func big(size: CGSize, safe: UIEdgeInsets, lefty: Bool, drawerOpen: Bool, surround s: PadSurround, aspect: CGFloat) -> Parts {
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
            p = portrait(in: remote, lefty: lefty)
            p.thumbPad = p.pad
            p.pad = lefty ? rightPage : leftPage
            p.stageAlignY = 0.5
            return p
        }

        var p = Parts()
        let h = PadLayout.keyHeight, t = PadLayout.stripHeight, drop: CGFloat = 6
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
        let topH = t - 2, n: CGFloat = 5
        let item = floor((half - 4 * (n - 1)) / n)
        func slot(_ i: Int) -> CGRect { CGRect(x: leftHalf.minX + CGFloat(i) * (item + 4), y: deck.minY, width: item, height: topH) }
        p.settingsButton = x(slot(0))
        p.findButton = x(slot(1))
        p.screenButton = x(slot(2))
        p.keyboardButton = x(slot(3))
        p.appsKey = x(CGRect(x: slot(4).minX, y: deck.minY, width: leftHalf.maxX - slot(4).minX, height: topH))
        let arrowW: CGFloat = 82
        p.arrowKey = x(CGRect(x: rightHalf.minX, y: deck.minY, width: arrowW, height: topH))
        p.strip = x(CGRect(x: rightHalf.minX + arrowW + 4, y: deck.minY, width: half - arrowW - 4, height: topH))

        // the pages: one list across the deck, each row split around the middle
        p.list = CGRect(x: deck.minX, y: deck.minY + t, width: deck.width, height: listH)
        p.listSplit = (at: half, width: deck.width - half * 2)
        p.keySize = CGSize(width: pageKeyW, height: rowH)

        // the dock: the modifiers and ⇥ under one thumb, what ends things and the talk key in the other's corner
        let dockY = deck.maxY - h
        let leftCount = PadLayout.thumbSlots.esc, rightCount = Deck.dockCount - leftCount + 1
        func spot(_ r: CGRect, _ c: Int, of count: Int) -> CGRect {
            let w = keys(r.width, count)
            return CGRect(x: r.minX + CGFloat(c) * (w + gap), y: dockY, width: w, height: h)
        }
        p.dock = (0..<Deck.dockCount).map { i in x(i < leftCount ? spot(leftHalf, i, of: leftCount) : spot(rightHalf, i - leftCount, of: rightCount)) }
        p.talk = x(spot(rightHalf, rightCount - 1, of: rightCount))
        return p
    }
}
