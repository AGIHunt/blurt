// Where everything goes, as plain numbers in dp (docs/design/remote.md §Layout; port of Pad/PadLayout.swift). No settings for any of it: the
// sizes are chosen, and a user who wants more keys adds them and scrolls.
//
//  Phone, portrait: the pad on top. Below it a top row with settings, the tabs, the screen controls and the arrow key, four rows of keys six
//  across, and the dock: the modifiers, the keys that end things, space, and the talk key in the corner by the thumb.
//
//  Phone, landscape: the end with the camera cutout holds what's rarely needed (settings, find the pointer, the screen, the system keyboard);
//  the other end holds what's always needed, for the thumb that's there: the keys' switch, ⌘Tab, esc, the arrow key, delete, return and the
//  talk key. Everything else comes out beside it when the keys open and goes when they're put away. Turn the phone round to change hands.
//
//  A big screen (a tablet, an unfolded foldable, a large window) gets a large stage for the picture and a panel of keys the size of a
//  phone's, never stretched keys: beside the stage when the screen is wide, under it when it's tall. The panel has a trackpad of its own
//  above or beside its keys, like a small laptop's.
//
//  A foldable half open: tabletop (the fold across) puts the picture on the upper half and the pad and keys on the lower one; book (the fold
//  down the middle) puts the picture on one side and the keys and pad on the other. Nothing is ever placed across the fold.
package dev.blurt.remote.app.pad

import dev.blurt.remote.core.Deck
import dev.blurt.remote.core.FullKeys
import dev.blurt.remote.core.FullKind
import dev.blurt.remote.core.FullRect
import dev.blurt.remote.core.FullTier
import dev.blurt.remote.core.RemoteHost
import dev.blurt.remote.core.KeyAction
import dev.blurt.remote.core.KeySlot
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** A rectangle in dp. Plain Kotlin, so the layout can be tested off the device. */
data class Frame(val left: Float = 0f, val top: Float = 0f, val right: Float = 0f, val bottom: Float = 0f) {
    val width get() = right - left
    val height get() = bottom - top
    val centerX get() = (left + right) / 2
    val isEmpty get() = width <= 0 || height <= 0
    fun intersects(o: Frame) = left < o.right && o.left < right && top < o.bottom && o.top < bottom
}

class PadLayout(
    w: Float, h: Float,
    /** the cutouts' safe insets, dp */
    safeLeft: Float, safeTop: Float, safeRight: Float, safeBottom: Float,
    val lefty: Boolean,
    drawerOpen: Boolean,
    /** a fold that separates the screen, in dp, and how it lies */
    fold: Fold? = null,
    /** the computer has more than one display and its picture is showing: the switcher gets a place */
    private val displays: Boolean = false,
    /** the dock slots that stay by the thumb in landscape: `thumbs(deck.dock)` */
    private val thumbs: Thumbs = Thumbs(),
    /** the computer keyboard is out */
    private val withBoard: Boolean = false,
    /** the computer's screen, width ÷ height */
    private val aspect: Float = 1.6f,
) {
    /** The computer keyboard: where, how many keys across, how tall each row. `bandsArePad`: the stage beside the picture is the trackpad.
     *  `quick`: a big screen's shortcuts, in the row of controls over it. */
    data class Board(val frame: Frame, val tier: FullTier, val heights: List<Float>, val bandsArePad: Boolean = false, val quick: List<Frame> = emptyList())

    var board: Board? = null; private set

    /** Dock slots by index: esc, delete and return. */
    data class Thumbs(val esc: Int = Deck.DOCK_COUNT - 3, val delete: Int = Deck.DOCK_COUNT - 2, val enter: Int = Deck.DOCK_COUNT - 1) {
        fun has(i: Int) = i == esc || i == delete || i == enter
    }

    data class Fold(val bounds: Frame, val vertical: Boolean, val halfOpened: Boolean)

    enum class Mode { PORTRAIT, LANDSCAPE, SPLIT, STACK }

    val mode: Mode
    val landscape: Boolean get() = mode == Mode.LANDSCAPE
    var pad = Frame(); private set
    /** the panel's own trackpad on a big screen */
    var pad2: Frame? = null; private set
    var talk = Frame(); private set
    var list = Frame(); private set
    var keyW = 0f; private set
    var keyH = 0f; private set
    var dock = List(Deck.DOCK_COUNT) { Frame() }; private set
    var arrowKey = Frame(); private set
    /** landscape: ⌘Tab, there even with the keys away */
    var appsKey = Frame(); private set
    var strip = Frame(); private set
    /** the tabs have a big screen's room: their names are set larger */
    var bigTabs = false; private set
    var keyboardButton = Frame(); private set
    var settingsButton = Frame(); private set
    var screenButton = Frame(); private set
    var findButton = Frame(); private set
    /** which of the computer's displays the picture is of; empty when there's only one */
    var displayButton = Frame(); private set
    /** landscape: the cutout's end */
    var rail: Frame? = null; private set
    /** landscape: puts the keys away and brings them back */
    var drawerButton = Frame(); private set
    /** the keys' block */
    var drawer = Frame(); private set
    /** where a picture smaller than the stage sits, top to bottom: near the thumb in portrait */
    var alignY = 0.5f; private set
    /** the system's gesture areas the keys need back (dp): Android allows 200 dp per side */
    val exclusions = mutableListOf<Frame>()

    init {
        val big = w >= 600 && h >= 480
        mode = when {
            // a fold that separates the screen decides, at any angle: across it, the picture above; down the middle, side by side
            fold != null && !fold.vertical -> Mode.STACK
            fold != null && fold.vertical -> Mode.SPLIT
            big && w >= h * 1.15f -> Mode.SPLIT
            big -> Mode.STACK
            w > h && w >= 560 -> Mode.LANDSCAPE      // a split-screen window wider than tall but phone-narrow keeps the portrait block
            else -> Mode.PORTRAIT
        }
        val whole = fold == null || !fold.vertical       // a fold down the middle: the panel's half keeps a phone's
        when (if (withBoard && whole && (mode == Mode.SPLIT || mode == Mode.STACK)) null else mode) {
            null -> bigBoard(w, h, safeLeft, safeTop, safeRight, safeBottom, fold)
            Mode.PORTRAIT -> {
                val bottom = max(safeBottom - 6, 12f)
                val top = max(safeTop - 6, 16f)
                val block = column(SIDE, w - SIDE * 2, h - bottom, maxHeight = h - bottom - top - MIN_PAD)
                pad = Frame(SIDE, top, w - SIDE, block.top - 2)
                alignY = 1f
            }
            Mode.LANDSCAPE -> landscape(w, h, safeLeft, safeRight, drawerOpen)
            Mode.SPLIT -> {
                // the panel on the thumb's side; across a fold, the half the thumb is on
                val panelW: Float
                val panelX: Float
                val stage: Frame
                if (fold != null) {
                    val leftW = fold.bounds.left
                    val rightX = fold.bounds.right
                    if (lefty) { panelX = 0f; panelW = leftW; stage = Frame(rightX, 0f, w, h) }
                    else { panelX = rightX; panelW = w - rightX; stage = Frame(0f, 0f, leftW, h) }
                } else {
                    panelW = min(PANEL_W, floor(w * 0.45f))
                    panelX = if (lefty) 0f else w - panelW
                    stage = if (lefty) Frame(panelW, 0f, w, h) else Frame(0f, 0f, w - panelW, h)
                }
                val top = max(safeTop - 6, 12f)
                val bottom = max(safeBottom - 6, 12f)
                // a panel wider than a phone keeps a phone's keys, at its thumb edge
                val colW = min(panelW - SIDE * 2, PANEL_W - SIDE * 2)
                val colX = if (lefty) panelX + SIDE else panelX + panelW - SIDE - colW
                val block = column(colX, colW, h - bottom, maxHeight = h - bottom - top - MIN_PAD, big = true)
                pad2 = Frame(colX, top, colX + colW, block.top - 2)
                // the panel's column keeps its own margin; across a fold each half keeps both
                pad = when {
                    fold != null -> Frame(stage.left + SIDE, top, stage.right - SIDE, h - bottom)
                    lefty -> Frame(stage.left, top, stage.right - SIDE, h - bottom)
                    else -> Frame(stage.left + SIDE, top, stage.right, h - bottom)
                }
            }
            Mode.STACK -> {
                val top = max(safeTop - 6, 12f)
                val bottom = max(safeBottom - 6, 12f)
                val lowerTop: Float
                val stageBottom: Float
                if (fold != null) {
                    stageBottom = fold.bounds.top
                    lowerTop = fold.bounds.bottom + 8
                } else {
                    lowerTop = h - bottom - BIG_BLOCK_H - 8
                    stageBottom = lowerTop - 8
                }
                val colW = min(w - SIDE * 2, PANEL_W - SIDE * 2)
                val colX = if (lefty) SIDE else w - SIDE - colW
                val block = column(colX, colW, h - bottom, maxHeight = h - bottom - lowerTop, big = true)
                pad = Frame(SIDE, top, w - SIDE, stageBottom - (if (fold != null) 8f else 0f))
                val room = w - SIDE * 3 - colW
                if (room >= 200) pad2 = if (lefty) Frame(colX + colW + SIDE, block.top, w - SIDE, block.bottom) else Frame(SIDE, block.top, SIDE + room, block.bottom)
                alignY = 1f
            }
        }
        exclude(w, h)
    }

    /**
     * The phone's portrait block: the top row, four rows six across, the dock with the talk key. Anchored at its bottom (`bottomY`), in
     * a column at `x` of `width`. Keys are 48 dp tall unless the room is less than that. `big`: a big screen's panel, whose top row is
     * taller where that costs the keys nothing, so the arrow key is 88 dp square and each edge 44 dp deep.
     */
    private fun column(x: Float, width: Float, bottomY: Float, maxHeight: Float, big: Boolean = false): Frame {
        if (withBoard) return boardColumn(x, width, bottomY, maxHeight)
        val gap = GAP
        val cols = Deck.COLUMNS
        val w = (width - gap * (cols - 1)) / cols
        val rows = VISIBLE_ROWS.toFloat()
        val drop = 6f
        val tall = big && maxHeight >= BIG_BLOCK_H
        val t = if (tall) BIG_STRIP_H else STRIP_H
        // the keys shrink before the block outgrows its room; never below what a thumb can hit
        val h = min(KEY_H, max(34f, floor((maxHeight - t - drop - gap * rows) / (rows + 1))))
        val listH = rows * h + (rows - 1) * gap
        val total = t + listH + drop + h
        val block = Frame(x, bottomY - total, x + width, bottomY)
        drawer = block
        keyW = w
        keyH = h
        appsKey = Frame()
        if (tall) topRowTall(block, t, width) else {
            // the top row: settings first, the arrow key by the thumb. Left-handed it comes in from the edge, past settings, so a slide to the
            // left has room
            val iconW = if (width < 390) 32f else 36f
            val arrowW = 82f
            settingsButton = Frame(block.left, block.top, block.left + iconW, block.top + t - 2)
            arrowKey = if (lefty) Frame(settingsButton.right + 4, block.top, settingsButton.right + 4 + arrowW, block.top + t - 2)
                else Frame(block.right - arrowW, block.top, block.right, block.top + t - 2)
            val rowEnd = if (lefty) block.right else arrowKey.left - 4
            keyboardButton = Frame(rowEnd - iconW, block.top, rowEnd, block.top + t - 2)
            screenButton = Frame(rowEnd - iconW * 2, block.top, rowEnd - iconW, block.top + t - 2)
            findButton = Frame(rowEnd - iconW * 3, block.top, rowEnd - iconW * 2, block.top + t - 2)
            displayButton = if (displays) Frame(rowEnd - iconW * 4, block.top, rowEnd - iconW * 3, block.top + t - 2) else Frame()
            val stripX = if (lefty) arrowKey.right else settingsButton.right
            strip = Frame(stripX, block.top, if (displays) displayButton.left else findButton.left, block.top + t - 2)
        }
        list = Frame(block.left, block.top + t, block.right, block.top + t + listH)
        // the dock: ten even parts, the last the talk key
        val dockY = block.bottom - h
        val n = Deck.DOCK_COUNT + 1
        val unit = (width - gap * (n - 1)) / n
        fun spot(c: Int) = Frame(block.left + c * (unit + gap), dockY, block.left + c * (unit + gap) + unit, dockY + h)
        talk = spot(if (lefty) 0 else n - 1)
        // left-handed it's a mirror, so the same keys are by the thumb
        dock = (0 until Deck.DOCK_COUNT).map { spot(if (lefty) Deck.DOCK_COUNT - it else it) }
        rail = null
        drawerButton = Frame()
        return block
    }

    /** The computer keyboard on a phone upright: five rows of ten in the pages' place, the dock and the top row as they are. */
    private fun boardColumn(x: Float, width: Float, bottomY: Float, maxHeight: Float): Frame {
        val gap = GAP
        val drop = 6f
        val t = STRIP_H
        val h = KEY_H
        val key = min(BOARD_KEY_H, max(34f, floor((maxHeight - t - drop - h - 4 * gap) / 5)))
        val heights = List(5) { key }
        val listH = FullKeys.height(heights)
        val block = Frame(x, bottomY - (t + listH + drop + h), x + width, bottomY)
        drawer = block
        keyW = (width - gap * (Deck.COLUMNS - 1)) / Deck.COLUMNS
        keyH = KEY_H
        appsKey = Frame()
        val iconW = if (width < 390) 32f else 36f
        val arrowW = 82f
        settingsButton = Frame(block.left, block.top, block.left + iconW, block.top + t - 2)
        arrowKey = if (lefty) Frame(settingsButton.right + 4, block.top, settingsButton.right + 4 + arrowW, block.top + t - 2)
            else Frame(block.right - arrowW, block.top, block.right, block.top + t - 2)
        val rowEnd = if (lefty) block.right else arrowKey.left - 4
        keyboardButton = Frame(rowEnd - iconW, block.top, rowEnd, block.top + t - 2)
        screenButton = Frame(rowEnd - iconW * 2, block.top, rowEnd - iconW, block.top + t - 2)
        findButton = Frame(rowEnd - iconW * 3, block.top, rowEnd - iconW * 2, block.top + t - 2)
        displayButton = if (displays) Frame(rowEnd - iconW * 4, block.top, rowEnd - iconW * 3, block.top + t - 2) else Frame()
        val stripX = if (lefty) arrowKey.right else settingsButton.right
        strip = Frame(stripX, block.top, if (displays) displayButton.left else findButton.left, block.top + t - 2)
        list = Frame(block.left, block.top + t, block.right, block.top + t + listH)
        board = Board(list, FullTier.TEN, heights)
        val dockY = block.bottom - h
        val n = Deck.DOCK_COUNT + 1
        val unit = (width - gap * (n - 1)) / n
        fun spot(c: Int) = Frame(block.left + c * (unit + gap), dockY, block.left + c * (unit + gap) + unit, dockY + h)
        talk = spot(if (lefty) 0 else n - 1)
        dock = (0 until Deck.DOCK_COUNT).map { spot(if (lefty) Deck.DOCK_COUNT - it else it) }
        rail = null
        drawerButton = Frame()
        return block
    }

    /** The computer keyboard on a big screen (as on the iPad): as wide as the screen under the stage, a row of controls over it. Where a whole
     *  picture leaves a band under it (upright), the band is a trackpad under the keys; where it leaves bands at its sides, those are. */
    private fun bigBoard(w: Float, h: Float, safeLeft: Float, safeTop: Float, safeRight: Float, safeBottom: Float, fold: Fold?) {
        val gap = GAP
        val left = safeLeft + SIDE
        val right = w - safeRight - SIDE
        val top = max(safeTop - 6, 12f)
        val bottom = h - max(safeBottom - 6, 12f)
        val width = right - left
        val height = bottom - top
        val laptop = fold != null && !fold.vertical
        val tier = FullTier.big(width)
        val stripH = 46f
        val drop = 6f
        val upright = height > width
        val below = if (laptop) bottom - fold!!.bounds.bottom - 4 else height
        val unit = FullTier.unit(width, tier)
        var key = if (upright) min(56f, max(44f, unit * 1.2f)) else 48f
        var f = if (upright) 40f else 36f
        fun tall() = stripH + drop + f + 5 * key + 5 * gap
        val room = if (laptop) below else min(height * 0.62f, height - 140)
        if (tall() > room) key = max(34f, floor((room - stripH - drop - f - 5 * gap) / 5))
        if (tall() > room) f = max(28f, f - (tall() - room))
        val heights = listOf(f) + List(5) { key }
        val boardH = FullKeys.height(heights)
        val deckH = stripH + drop + boardH
        val band = if (laptop) 0f else height - width / max(aspect, 0.5f) - 8 - deckH - 8
        val padH = if (band >= BOARD_PAD_H) band else 0f
        val deckY = if (laptop) fold!!.bounds.bottom + 4 else bottom - deckH - (if (padH > 0) padH + 8 else 0f)
        pad = Frame(left, top, right, (if (laptop) fold!!.bounds.top else deckY) - 8)
        alignY = if (laptop) 0.5f else 1f
        if (padH > 0) pad2 = Frame(left, bottom - padH, right, bottom)

        val c = 46f
        var x = left
        fun next(after: Float = 4f): Frame { val r = Frame(x, deckY, x + c, deckY + stripH); x += c + after; return r }
        settingsButton = next()
        findButton = next()
        screenButton = next()
        displayButton = if (displays) next() else Frame()
        keyboardButton = next(10f)
        val spare = right - x - 300 - 5 * gap
        val n = if (spare >= 44 * 6) 6 else 4
        val q = min(64f, max(44f, spare / 6))
        val qx = right - (n * q + (n - 1) * gap)
        strip = Frame(x, deckY, max(x, qx - 10), deckY + stripH)
        val quick = (0 until n).map { Frame(qx + it * (q + gap), deckY, qx + it * (q + gap) + q, deckY + stripH) }
        val frame = Frame(left, deckY + stripH + drop, right, deckY + deckH)
        board = Board(frame, tier, heights, bandsArePad = padH == 0f, quick = quick)
        drawer = Frame(left, deckY, right, deckY + deckH)
        rail = null
        drawerButton = Frame()
        keyW = 44f
        keyH = KEY_H
        val spots = FullKeys.place(FullKeys.rows(tier, RemoteHost.MAC), FullRect(frame.left, frame.top, frame.right, frame.bottom), tier, heights)
        spots.firstOrNull { it.first.kind == FullKind.Talk }?.second?.let { talk = Frame(it.left, it.top, it.right, it.bottom) }
    }

    /**
     * A big screen's top row, 88 dp tall: the arrow key square by the thumb, and beside it the controls above the tabs, each half the row.
     * Left-handed, settings comes first at the edge, so a slide to the left has room, as on a phone.
     */
    private fun topRowTall(block: Frame, t: Float, width: Float) {
        bigTabs = true
        val top = block.top
        val rowH = t - 2
        val side = rowH
        val iconW = if (width < 390) 32f else 36f
        val sub = (rowH - 4) / 2
        val restLeft: Float
        val restRight: Float
        if (lefty) {
            settingsButton = Frame(block.left, top, block.left + iconW, top + rowH)
            arrowKey = Frame(settingsButton.right + 4, top, settingsButton.right + 4 + side, top + rowH)
            restLeft = arrowKey.right + 4
            restRight = block.right
        } else {
            arrowKey = Frame(block.right - side, top, block.right, top + rowH)
            restLeft = block.left
            restRight = arrowKey.left - 4
        }
        // the controls along the upper half, from the far end in; the tabs under them, as wide
        val controls = mutableListOf<(Frame) -> Unit>()
        if (!lefty) controls += { f: Frame -> settingsButton = f }
        controls += { f: Frame -> findButton = f }
        controls += { f: Frame -> screenButton = f }
        controls += { f: Frame -> keyboardButton = f }
        if (displays) controls += { f: Frame -> displayButton = f } else displayButton = Frame()
        val cw = (restRight - restLeft) / controls.size
        controls.forEachIndexed { i, set -> set(Frame(restLeft + i * cw, top, restLeft + (i + 1) * cw, top + sub)) }
        strip = Frame(restLeft, top + rowH - sub, restRight, top + rowH)
    }

    private fun landscape(w: Float, h: Float, safeLeft: Float, safeRight: Float, drawerOpen: Boolean) {
        val gap = GAP
        val cols = Deck.COLUMNS
        fun keys(width: Float) = (width - gap * (cols - 1)) / cols
        // the cutout's end has the rarely needed; with no cutout, the end away from the thumb
        val railLeft = when {
            safeLeft > 0 -> true
            safeRight > 0 -> false
            else -> !lefty
        }
        val margin = if (railLeft) safeLeft else safeRight
        fun fromRail(inset: Float, ww: Float, y: Float, hh: Float) = if (railLeft) Frame(inset, y, inset + ww, y + hh) else Frame(w - inset - ww, y, w - inset, y + hh)
        fun fromFar(inset: Float, ww: Float, y: Float, hh: Float) = if (railLeft) Frame(w - inset - ww, y, w - inset, y + hh) else Frame(inset, y, inset + ww, y + hh)

        val ctrlW = 46f
        val btn = 42f
        val clear = 20f
        val ctrlIn = if (margin > ctrlW + 8) (margin - ctrlW) / 2 else 8f
        val ctrlEnd = max(margin, ctrlIn + ctrlW)
        settingsButton = fromRail(ctrlIn, ctrlW, clear, btn)
        findButton = fromRail(ctrlIn, ctrlW, clear + btn + gap, btn)
        screenButton = fromRail(ctrlIn, ctrlW, h - clear - btn * 2 - gap, btn)
        keyboardButton = fromRail(ctrlIn, ctrlW, h - clear - btn, btn)
        displayButton = if (displays) fromRail(ctrlIn, ctrlW, (h - btn) / 2, btn) else Frame()
        rail = fromRail(0f, ctrlEnd, 0f, h)

        // the thumb's end: clear of the round corners, the talk key where the thumb rests, a little taller than the keys above it
        val far = 12f
        val thumbW = 56f
        val top = 14f
        val tall = h - top * 2
        val arrow = 74f
        val toggle = 30f
        val talkExtra = 8f
        val unit = floor((tall - toggle - arrow - talkExtra - gap * 6) / 5)
        var y = top
        fun next(hh: Float): Frame { val r = fromFar(far, thumbW, y, hh); y += hh + gap; return r }
        drawerButton = next(toggle)
        appsKey = next(unit)
        val esc = next(unit)
        arrowKey = next(arrow)
        val delete = next(unit)
        val enter = next(unit)
        talk = fromFar(far, thumbW, y, top + tall - y)

        // the keys, beside that: pages, then the rest of the dock, as tall as the screen allows while a key stays key-shaped
        val inner = far + thumbW + 6
        val bw = min(WIDE_KEYS_W, floor((w - ctrlEnd - inner) * 0.5f))
        val tabs = 30f
        val drop = 6f
        val edge = 8f
        val rows = VISIBLE_ROWS.toFloat()
        val kh = min(WIDE_KEY_H, min(floor(keys(bw) * WIDE_KEY_SHAPE), floor((h - edge * 2 - tabs - drop - gap * rows) / (rows + 1))))
        val listH = rows * kh + (rows - 1) * gap
        val total = tabs + listH + drop + kh
        val blockY = (h - total) / 2
        val block = fromFar(inner, bw, blockY, total)
        drawer = block
        strip = Frame(block.left, blockY, block.right, blockY + tabs)
        list = Frame(block.left, blockY + tabs, block.right, blockY + tabs + listH)
        keyW = keys(bw)
        keyH = kh
        val rowY = block.bottom - kh
        var column = 0
        dock = (0 until Deck.DOCK_COUNT).map { i ->
            when (i) {
                thumbs.esc -> esc
                thumbs.delete -> delete
                thumbs.enter -> enter
                else -> Frame(block.left + column * (keyW + gap), rowY, block.left + column * (keyW + gap) + keyW, rowY + kh).also { column++ }
            }
        }
        val reach = inner + if (drawerOpen && !withBoard) bw + 6 else 0f
        pad = if (railLeft) Frame(ctrlEnd + 6, 6f, w - reach, h - 6) else Frame(reach, 6f, w - ctrlEnd - 6, h - 6)
        if (withBoard) {
            // five rows between the two columns, which stay; the stage over them keeps not much less than half the height
            val key = max(32f, min(40f, floor((h * 0.55f - 4 * gap) / 5)))
            val heights = List(5) { key }
            val f = Frame(pad.left, h - 6 - FullKeys.height(heights), pad.right, h - 6)
            board = Board(f, FullTier.THIRTEEN, heights)
            pad = Frame(pad.left, pad.top, pad.right, f.top - 8)
        }
        alignY = 0.5f
    }

    /** Back from the system's edge gestures: where a slide starts on a key at the screen's side (a cycle key, the arrow key, the dock's ends),
     *  the lower 200 dp of each side, where the thumb is. */
    private fun exclude(w: Float, h: Float) {
        exclusions.clear()
        val band = 28f
        val budget = 200f
        if (mode == Mode.LANDSCAPE) {
            val col = if (appsKey.left > w / 2) Frame(w - band, 0f, w, h) else Frame(0f, 0f, band, h)
            val from = appsKey.top
            exclusions += Frame(col.left, from, col.right, min(h, from + budget))
            return
        }
        val b = drawer
        val from = max(b.top, b.bottom - budget)
        if (b.left < band) exclusions += Frame(0f, from, band, b.bottom)
        if (b.right > w - band) exclusions += Frame(w - band, from, w, b.bottom)
    }

    /** a dock key that stays out in landscape with the keys put away */
    fun staysOut(i: Int) = thumbs.has(i)

    /** one finger scrolls along the pad's left side: the side by the thumb. On its side a phone's thumb is at the end across from the cutout,
     *  whichever hand */
    val scrollsLeft: Boolean get() = if (mode == Mode.LANDSCAPE) appsKey.centerX < pad.centerX else lefty

    /** where one finger scrolls on a pad, across it */
    fun scrollEdge(width: Float, left: Boolean = scrollsLeft): ClosedFloatingPointRange<Double> {
        val e = scrollEdgeWidth(width)
        return if (left) 0.0..e.toDouble() else (width - e).toDouble()..width.toDouble()
    }

    companion object {
        const val GAP = 5f
        const val SIDE = 8f
        /** tall enough for the arrow key's four edges */
        const val STRIP_H = 52f
        /** a big screen's: the arrow key 88 dp square, each edge 44 dp deep. On a phone ↑ and ↓ get 25 dp each, and in a terminal they're the
         *  arrows used most */
        const val BIG_STRIP_H = 90f
        const val VISIBLE_ROWS = 4
        /** the computer keyboard's keys, upright on a phone */
        const val BOARD_KEY_H = 44f
        /** a trackpad under it needs this much */
        const val BOARD_PAD_H = 96f
        /** a little over a phone keyboard's; the width comes from six across */
        const val KEY_H = 48f
        const val BLOCK_H = STRIP_H + VISIBLE_ROWS * KEY_H + (VISIBLE_ROWS - 1) * GAP + 6 + KEY_H
        const val BIG_BLOCK_H = BLOCK_H - STRIP_H + BIG_STRIP_H
        /** landscape keys grow to fill the height, up to this, and no taller than this much of their width */
        const val WIDE_KEY_H = 72f
        const val WIDE_KEY_SHAPE = 1.25f
        const val WIDE_KEYS_W = 340f
        /** wide enough to find with a thumb that isn't looked at (26 was the first value: a slide begun a little inside was the pointer) */
        fun scrollEdgeWidth(pad: Float) = min(44f, max(32f, pad * 0.09f))

        /** The edge's mark on a pad: half its height, so it reads as something to slide along, and clear of what stands in the corners. */
        fun edgeMark(width: Float, height: Float, left: Boolean): Frame {
            val h = max(0f, min(height - 24, max(96f, min(360f, height * 0.5f))))
            val x = if (left) 6f else width - 10
            return Frame(x, (height - h) / 2, x + 4, (height + h) / 2)
        }
        /** a big screen's key panel: as wide as an iPhone 17 Pro, keys and all */
        const val PANEL_W = 402f
        /** the pad never goes below this before the keys give way */
        const val MIN_PAD = 120f

        /**
         * Where the dock's esc, delete and return are, found by what they do: in landscape these stay out by the thumb with the keys put
         * away, wherever the user moved them. One that isn't in the dock leaves its place as shipped to whatever key is there.
         */
        fun thumbs(dock: List<KeySlot>): Thumbs {
            fun find(key: String) = dock.indexOfFirst { val a = it.action; a is KeyAction.Chord && !a.cycle && a.chord.mods == 0 && a.chord.key == key }
            val found = listOf("Escape", "Delete", "Return").map(::find)
            val taken = found.filter { it >= 0 }.toMutableSet()
            val n = Deck.DOCK_COUNT
            val at = found.mapIndexed { k, i ->
                if (i >= 0) i else (if (n - 3 + k !in taken) n - 3 + k else (n - 1 downTo 0).first { it !in taken }).also { taken += it }
            }
            return Thumbs(at[0], at[1], at[2])
        }
    }
}
