// One key (port of Keys/KeyCell.swift). Raw touches, because a key here does more than a button does:
//
//   a plain key fires when the thumb lifts, so a thumb that lands wrong can slide off and nothing happens; held still it does nothing.
//   a cycle key (⌘Tab, Alt+Tab) presses at once and keeps the modifier down: slide to step through, a detent every 22 dp, left to go back;
//   at the edge of the screen it keeps stepping, so twenty apps are as reachable as three. Lifting lets go. A quick tap is the quick ⌘Tab:
//   back to the last app. The other keys are out of play meanwhile: the thumb passes over them.
//   the arrow key is four keys in one, each edge marked with its arrow: tap towards an edge for that arrow, hold to repeat; a tap in the very
//   middle is nobody's. Or drag, one step per 24 dp, keeping to the way it set off until it clearly turns; past 72 dp, or at the screen's
//   edge, it repeats, faster with distance. Tap and then drag does the same with ⇧. (The arithmetic: ArrowStroke, below.)
//   a repeating key (⌫, an arrow) fires at once and repeats while held. Nothing destructive repeats: never Esc, ⌃C or Return.
//   a modifier tapped holds for the next key; held a moment, it's pressed on its own instead, the way a lone ⇧ switches a Chinese or
//   Japanese input method between its own letters and English.
//
//   In the list a thumb may land on any of these meaning to scroll. So there, the keys that act at once wait to be sure: a moment held, or a
//   slide sideways, or a lift. Until then the list may take the touch and nothing has happened. In the dock they act at once.
package dev.blurt.remote.app.keys

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import dev.blurt.remote.app.Fonts
import dev.blurt.remote.app.Haptics
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.Theme
import dev.blurt.remote.app.dp
import dev.blurt.remote.core.KeyAction
import dev.blurt.remote.core.KeySlot
import dev.blurt.remote.core.RemoteChord
import dev.blurt.remote.core.RemoteHost
import dev.blurt.remote.core.RemoteModifiers
import dev.blurt.remote.core.RemoteStep
import dev.blurt.remote.core.ToMac
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max

class KeyCell(c: Context) : View(c) {
    var slot: KeySlot? = null
        set(v) { field = v; refresh() }
    /** a cycle started or ended: the other keys sit out */
    var onCycle: ((Boolean) -> Unit)? = null
    /** on the scrolling list */
    var inList = false
    var host: RemoteHost = RemoteHost.MAC
        set(v) { if (field != v) { field = v; refresh() } }

    private val main = Handler(Looper.getMainLooper())
    /** something has been sent, or is about to be: a scroll can't take this touch any more */
    private var committed = true
    private val commitTimer = Runnable { commit() }
    private var pressed0 = false
    private var startX = 0f
    private var startY = 0f
    private var moved = false
    private var cancelled = false
    private var armed = false
    private var wentAlone = false
    private var lonePending = false
    private var flash = 0     // 1 latched flash while a modifier goes alone

    private data class Cycle(val hold: Int, val forward: RemoteChord, val back: RemoteChord, var steps: Int = 0, var carried: Int = 0)
    private var cycle: Cycle? = null
    private var edgeDirection = 0

    // arrows
    private var stroke = ArrowStroke(0f, 0f)
    private var arrowShift = false
    private var lastArrowEnd = 0.0
    private var arrowRepeated = false
    private var repeatKey: RemoteChord? = null
    private var repeatRate = 0.0
    private var repeater: Runnable? = null

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private val rect = RectF()

    init {
        isClickable = true
        isFocusable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
    }

    fun refresh() {
        contentDescription = slot?.let { DeckText.tr(it.title(host)) } ?: context.getString(dev.blurt.remote.app.R.string.empty)
        invalidate()
    }

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = android.widget.Button::class.java.name
    }

    private fun now() = SystemClock.uptimeMillis() / 1000.0

    // MARK: drawing

    override fun onDraw(canvas: Canvas) {
        val s = slot
        val w = width.toFloat()
        val h = height.toFloat()
        rect.set(0f, 0f, w, h)
        val r = Theme.KEY_RADIUS.dp
        if (s == null) {
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 1.dp
            paint.color = Theme.hairline
            rect.inset(0.5f.dp, 0.5f.dp)
            canvas.drawRoundRect(rect, r, r, paint)
            return
        }
        val held = Remote.sticky
        var latched = false
        var once = false
        val a = s.action
        if (a is KeyAction.Sticky) {
            latched = (held.locked and a.mods) == a.mods
            once = (held.once and a.mods) == a.mods && !latched
        }
        val strong = a is KeyAction.Chord && a.chord.mods == 0 && a.chord.key == "Return"
        paint.style = Paint.Style.FILL
        paint.color = when {
            flash == 1 || latched -> Theme.slabLatched
            pressed0 -> Theme.slabPressed
            strong -> Theme.slabStrong
            else -> Theme.slab
        }
        canvas.drawRoundRect(rect, r, r, paint)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = if (once) 1.5f.dp else 0.5f.dp
        paint.color = if (once) Theme.slabLatched else Theme.edge
        val inset = paint.strokeWidth / 2
        rect.inset(inset, inset)
        canvas.drawRoundRect(rect, r, r, paint)

        val dark = latched || flash == 1
        val markColor = if (dark) Color.BLACK else Theme.mark
        if (a is KeyAction.Arrows) {
            // four marked edges
            val mid = w / 2
            val midY = h / 2
            // a key with room both ways (a big screen's) has its marks further in, where each edge's zone is
            val roomy = w >= 80.dp && h >= 80.dp
            val inX = if (roomy) w * 0.2f else minOf(13.dp, w * 0.2f)
            val inY = if (roomy) h * 0.2f else minOf(11.dp, h * 0.22f)
            text.typeface = Fonts.symbols(context)
            text.textSize = 16.dp
            text.color = markColor
            val fm = text.fontMetrics
            val off = -(fm.ascent + fm.descent) / 2
            canvas.drawText(Icons.char("keyboard_arrow_up"), mid, inY + off, text)
            canvas.drawText(Icons.char("keyboard_arrow_down"), mid, h - inY + off, text)
            canvas.drawText(Icons.char("keyboard_arrow_left"), inX, midY + off, text)
            canvas.drawText(Icons.char("keyboard_arrow_right"), w - inX, midY + off, text)
            return
        }
        val face = s.face(host)
        val detail = s.detail(host)?.let { DeckText.tr(it) }
        val hasCaption = !detail.isNullOrEmpty()
        val top = if (hasCaption) (h - 36.dp) / 2 else (h - 22.dp) / 2
        val cy = top + 11.dp
        canvas.save()
        canvas.clipRect(1.dp, 0f, w - 1.dp, h)
        Face.draw(canvas, context, face, w / 2, cy, markColor, text)
        if (hasCaption) {
            text.typeface = Fonts.text
            text.textSize = 10.dp
            text.color = if (dark) Color.argb(153, 0, 0, 0) else Theme.caption
            var size = 10.dp
            while (text.measureText(detail) > w - 4.dp && size > 7.dp) { size *= 0.93f; text.textSize = size }
            val fm = text.fontMetrics
            canvas.drawText(detail!!, w / 2, top + 23.dp + 6.5f.dp - (fm.ascent + fm.descent) / 2, text)
        }
        canvas.restore()
    }

    private fun press(on: Boolean) {
        if (slot == null) return
        pressed0 = on
        invalidate()
    }

    // MARK: touches

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> began(e)
            MotionEvent.ACTION_MOVE -> movedTo(e)
            MotionEvent.ACTION_UP -> ended()
            MotionEvent.ACTION_CANCEL -> { letGo(); press(false) }
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        // TalkBack's double tap: as a plain tap
        slot?.let { tapped(it) }
        return true
    }

    private fun began(e: MotionEvent) {
        startX = e.x
        startY = e.y
        moved = false
        cancelled = false
        armed = true
        val s = slot ?: return
        if (android.os.Build.VERSION.SDK_INT >= 30) requestUnbufferedDispatch(e)
        press(true)
        committed = true
        wentAlone = false
        val a = s.action
        if (a is KeyAction.Sticky) {
            lonePending = true
            main.postDelayed(lone, (LONE_AFTER * 1000).toLong())
        }
        if (!(inList && actsAtOnce(s))) return act(s, e.x, e.y)
        committed = false
        main.postDelayed(commitTimer, (COMMIT_DELAY * 1000).toLong())
    }

    private fun actsAtOnce(s: KeySlot): Boolean = when (val r = resolved(s.action)) {
        is Resolved.Chord -> r.cycle || repeats(r.chord)
        is Resolved.NextTerminalTab, Resolved.Arrows -> true
        else -> false
    }

    /** May the list's scroll take this touch? Yes until the key has done something the scroll couldn't undo. */
    val givesWay: Boolean get() {
        val s = slot ?: return true
        return !committed || !actsAtOnce(s)
    }

    /** A cycle or an arrow drag is under way: nothing else may take the touch. */
    val holding: Boolean get() = cycle != null || (committed && slot?.action is KeyAction.Arrows && armed)

    private fun commit() {
        main.removeCallbacks(commitTimer)
        val s = slot ?: return
        if (committed) return
        committed = true
        parent?.requestDisallowInterceptTouchEvent(true)
        act(s, startX, startY)
    }

    private fun act(s: KeySlot, x: Float, y: Float) {
        when (val r = resolved(s.action)) {
            is Resolved.Chord -> {
                if (r.cycle) {
                    Haptics.tick()
                    beginCycle(r.chord)
                } else if (repeats(r.chord)) {
                    fire(r.chord)
                    startRepeat(r.chord, 0.35, 0.08)
                }
            }
            is Resolved.NextTerminalTab -> {
                Haptics.tick()
                cycle = Cycle(0, r.forward, r.back)
                parent?.requestDisallowInterceptTouchEvent(true)
                Remote.link.send(ToMac.Key(r.forward, null))
                onCycle?.invoke(true)
            }
            Resolved.Arrows -> {
                stroke = ArrowStroke(x / 1.dp, y / 1.dp)
                arrowShift = ArrowStroke.shifted(now(), lastArrowEnd)
                arrowRepeated = false
                parent?.requestDisallowInterceptTouchEvent(true)
                // the very middle: nothing until it moves
                val key = ArrowStroke.tapKey(x, y, width.toFloat(), height.toFloat()) ?: return
                Haptics.step()
                startRepeat(RemoteChord(0, key), 0.35, 0.08)
            }
            else -> {}
        }
    }

    private sealed class Resolved {
        data class Chord(val chord: RemoteChord, val cycle: Boolean) : Resolved()
        data class NextTerminalTab(val forward: RemoteChord, val back: RemoteChord) : Resolved()
        data object Arrows : Resolved()
        data class Other(val a: KeyAction) : Resolved()
    }

    private fun resolved(a: KeyAction): Resolved = when (a) {
        is KeyAction.Chord -> Resolved.Chord(a.chord, a.cycle)
        KeyAction.Arrows -> Resolved.Arrows
        KeyAction.NextTab -> {
            val front = Remote.link.front.value?.bundle
            when {
                front != null && front in TERMINALS && host == RemoteHost.MAC ->
                    Resolved.NextTerminalTab(RemoteChord(RemoteModifiers.COMMAND or RemoteModifiers.SHIFT, "]"), RemoteChord(RemoteModifiers.COMMAND or RemoteModifiers.SHIFT, "["))
                front != null && front in TERMINALS ->
                    Resolved.NextTerminalTab(RemoteChord(RemoteModifiers.CONTROL, "PageDown"), RemoteChord(RemoteModifiers.CONTROL, "PageUp"))
                else -> Resolved.Chord(RemoteChord(RemoteModifiers.CONTROL, "Tab"), true)
            }
        }
        else -> Resolved.Other(a)
    }

    private fun repeats(c: RemoteChord) = (c.mods and RemoteModifiers.COMMAND) == 0 && c.key in REPEATING   // ⌘⌫ deletes a line

    private fun beginCycle(c: RemoteChord) {
        val shift = RemoteModifiers.SHIFT
        val back = RemoteChord(c.mods xor shift, c.key)
        val hold = c.mods and shift.inv()
        cycle = Cycle(hold, c, back)
        parent?.requestDisallowInterceptTouchEvent(true)
        Remote.link.send(ToMac.Key(RemoteChord(hold, ""), true))
        Remote.link.send(ToMac.Key(c, null))
        onCycle?.invoke(true)
    }

    private fun movedTo(e: MotionEvent) {
        val dx = e.x - startX
        val dy = e.y - startY
        if (hypot(dx, dy) > 8.dp) moved = true
        if (!committed && abs(dx) > 8.dp && abs(dx) > abs(dy)) commit()
        if (cycle != null) {
            cycleTo((dx / CYCLE_STEP.dp).toInt())
            val x = inWindow(e.x)
            val w = rootView.width.toFloat()
            setEdge(if (x > w - EDGE.dp) 1 else if (x < EDGE.dp) -1 else 0)
            return
        }
        if (!armed) return
        if (slot?.action is KeyAction.Arrows) { if (committed && moved) arrows(e); return }
        // slid off the key: nothing happens, and what was repeating stops
        val inside = e.x >= -14.dp && e.y >= -14.dp && e.x <= width + 14.dp && e.y <= height + 14.dp
        cancelled = !inside
        if (!inside) { stopRepeat(); stopLone() }
        press(inside)
    }

    private fun ended() {
        commit()
        stopRepeat()
        stopLone()
        press(false)
        val s = slot ?: return
        if (wentAlone) { wentAlone = false; flash = 0; invalidate(); return }
        if (cycle != null) {
            endCycle()
            Remote.sticky.used()
            return
        }
        if (s.action is KeyAction.Arrows) {
            val key = if (!moved && !arrowRepeated) ArrowStroke.tapKey(startX, startY, width.toFloat(), height.toFloat()) else null
            if (key != null) {
                Remote.link.send(ToMac.Key(RemoteChord(0, key), null))
                Remote.sticky.used()
            }
            // only a tap that sent an arrow makes the next drag a ⇧ one
            lastArrowEnd = if (key != null) now() else 0.0
            armed = false
            return
        }
        val go = armed && !cancelled
        armed = false
        if (go) tapped(s)
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        letGo()     // taken away mid-press, with the deck reloaded under it: nothing stays held on the computer
    }

    fun letGo() {
        stopLone()
        wentAlone = false
        flash = 0
        main.removeCallbacks(commitTimer)
        committed = true
        armed = false
        stopRepeat()
        if (cycle != null) endCycle()
    }

    private val loc = IntArray(2)
    private fun inWindow(x: Float): Float { getLocationInWindow(loc); return loc[0] + x }

    private fun cycleTo(fingerSteps: Int) {
        val c = cycle ?: return
        val target = fingerSteps + c.carried
        while (c.steps != target) {
            val forward = target > c.steps
            c.steps += if (forward) 1 else -1
            Remote.link.send(ToMac.Key(if (forward) c.forward else c.back, null))
            Haptics.step()
        }
    }

    /** The thumb has run out of screen: holding it there keeps stepping. */
    private val edgeStep = object : Runnable {
        override fun run() {
            val c = cycle ?: return
            if (edgeDirection == 0) return
            c.carried += edgeDirection
            val fingerSteps = c.steps - (c.carried - edgeDirection)
            cycleTo(fingerSteps)
            main.postDelayed(this, (EDGE_EVERY * 1000).toLong())
        }
    }

    private fun setEdge(d: Int) {
        if (d == edgeDirection) return
        edgeDirection = d
        main.removeCallbacks(edgeStep)
        if (d != 0) main.postDelayed(edgeStep, (EDGE_EVERY * 1000).toLong())
    }

    private fun endCycle() {
        setEdge(0)
        cycle?.let { if (it.hold != 0) Remote.link.send(ToMac.Key(RemoteChord(it.hold, ""), false)) }
        cycle = null
        onCycle?.invoke(false)
    }

    private fun tapped(s: KeySlot) {
        val l = Remote.link
        when (val a = s.action) {
            is KeyAction.Chord -> if (!repeats(a.chord)) fire(a.chord)
            is KeyAction.Sequence -> { Haptics.tick(); l.send(ToMac.Run(a.steps)); Remote.sticky.used() }
            is KeyAction.Text -> {
                Haptics.tick()
                l.send(ToMac.Run(listOf(RemoteStep.Text(a.text)) + if (a.enter) listOf(RemoteStep.Wait(60), RemoteStep.Key(RemoteChord(0, "Return"))) else emptyList()))
                Remote.sticky.used()
            }
            is KeyAction.Sticky -> { Haptics.grab(); Remote.sticky.tap(a.mods, now()) }
            is KeyAction.Blurt -> { Haptics.tick(); l.send(ToMac.Blurt(a.command)) }
            is KeyAction.System -> { Haptics.tick(); l.send(ToMac.System(a.move)) }
            KeyAction.Arrows, KeyAction.NextTab -> {}
        }
    }

    /** Held: the modifier by itself, down and up, and not held for the next key. */
    private val lone = Runnable {
        lonePending = false
        val a = slot?.action as? KeyAction.Sticky ?: return@Runnable
        if (!armed || cancelled) return@Runnable
        wentAlone = true
        Haptics.grab()
        // already held on the computer: letting it go is the press on its own. Another down and up would switch the input method back
        if ((Remote.sticky.held and a.mods) == a.mods) {
            Remote.sticky.release(a.mods)
        } else {
            Remote.sticky.release(a.mods)
            Remote.link.send(ToMac.Key(RemoteChord(a.mods, ""), null))
        }
        flash = 1
        invalidate()
        main.postDelayed({ if (wentAlone) { flash = 0; invalidate() } }, 140)
    }

    private fun stopLone() {
        if (lonePending) main.removeCallbacks(lone)
        lonePending = false
    }

    private fun fire(c: RemoteChord) {
        // the two keys that matter most can be told apart in the thumb
        if (c.mods == 0 && (c.key == "Return" || c.key == "Escape")) Haptics.grab() else Haptics.tick()
        Remote.link.send(ToMac.Key(c, null))
        Remote.sticky.used()
    }

    // MARK: arrows

    private fun step(key: String) {
        Haptics.step()
        Remote.link.send(ToMac.Key(RemoteChord(if (arrowShift) RemoteModifiers.SHIFT else 0, key), null))
    }

    private fun arrows(e: MotionEvent) {
        // the thumb has run out of screen: at that edge, sliding towards it, it repeats as if it had gone on
        val band = EDGE * 0.6f
        val x = inWindow(e.x) / 1.dp
        val w = rootView.width / 1.dp
        val edge = if (x < band) -1 else if (x > w - band) 1 else 0
        when (val m = stroke.move(e.x / 1.dp, e.y / 1.dp, edge)) {
            is ArrowStroke.Move.Repeating -> if (repeatKey?.key != m.key || abs(repeatRate - m.every) > 0.01) {
                stopRepeat()
                startRepeat(RemoteChord(if (arrowShift) RemoteModifiers.SHIFT else 0, m.key), 0.0, m.every)
            }
            is ArrowStroke.Move.Step -> { stopRepeat(); step(m.key) }
            ArrowStroke.Move.None -> stopRepeat()
        }
    }

    private fun startRepeat(c: RemoteChord, after: Double, every: Double) {
        stopRepeat()
        repeatKey = c
        repeatRate = every
        val r = object : Runnable {
            override fun run() {
                arrowRepeated = true
                Haptics.step()
                Remote.link.send(ToMac.Key(c, null))
                main.postDelayed(this, (every * 1000).toLong())
            }
        }
        repeater = r
        main.postDelayed(r, (after * 1000).toLong())
    }

    private fun stopRepeat() {
        repeater?.let { main.removeCallbacks(it) }
        repeater = null
        repeatKey = null
    }

    companion object {
        const val COMMIT_DELAY = 0.12
        const val LONE_AFTER = 0.45
        const val CYCLE_STEP = 22f
        const val EDGE = 36f
        const val EDGE_EVERY = 0.14
        val REPEATING = setOf("Delete", "ForwardDelete", "Left", "Right", "Up", "Down")
        /** where "Tabs" means the terminal's own tabs: Mac bundle ids, Windows exe names, Linux desktop ids */
        val TERMINALS = setOf(
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty",
            "com.github.wez.wezterm", "co.zeit.hyper", "WindowsTerminal.exe", "wezterm-gui.exe", "alacritty.exe", "org.gnome.Terminal",
            "org.gnome.Ptyxis", "org.gnome.Console", "kitty", "Alacritty", "org.wezfurlong.wezterm", "org.kde.konsole", "com.mitchellh.ghostty.desktop",
        )
    }
}

/**
 * The arrow key's arithmetic, apart from the view, so it can be tested (port of ArrowStroke in KeyCell.swift; dp in, arrows out).
 *
 * A drag keeps to its way: once it has taken a step, steps come only along that axis, and the other one follows the finger at each step, so
 * a thumb's arc never adds up to an arrow of its own (sliding right, it fired a Down, which in a shell swaps the line for history). It
 * changes axis only on a clear turn: 36 dp across since the last step, and more across than along. Then it starts again from that step, as
 * a new drag would: steps every 24 dp, a repeat past 72.
 */
class ArrowStroke(x: Float, y: Float) {
    sealed class Move {
        data object None : Move()
        data class Step(val key: String) : Move()
        data class Repeating(val key: String, val every: Double) : Move()
    }

    /** the axis it keeps to, once it has stepped: true across, false up and down */
    var horizontal: Boolean? = null; private set
    /** where this run began: the touch, or the step a turn came from */
    private var originX = x
    private var originY = y
    /** the next step comes 24 dp from here */
    private var anchorX = x
    private var anchorY = y
    /** the finger at the last step */
    private var lastX = x
    private var lastY = y

    /** `screenEdge`: the finger is at the screen's left (-1) or right (1) edge. */
    fun move(x: Float, y: Float, screenEdge: Int = 0): Move {
        horizontal?.let { h ->
            val along = if (h) x - lastX else y - lastY
            val across = if (h) y - lastY else x - lastX
            if (abs(across) >= TURN && abs(across) > abs(along)) {
                horizontal = !h
                originX = lastX; originY = lastY
                anchorX = lastX; anchorY = lastY
            }
        }
        val dx = x - anchorX
        val dy = y - anchorY
        val h = horizontal ?: (abs(dx) > abs(dy))
        val d = if (h) dx else dy
        val run = if (h) x - originX else y - originY
        var far = if (horizontal == null) hypot(x - originX, y - originY) else abs(run)
        if (h && screenEdge != 0 && abs(run) >= STEP && (run > 0) == (screenEdge > 0)) far = max(far, 90f)
        if (far > FAR) {
            horizontal = h
            return Move.Repeating(key(h, if (d != 0f) d else run), max(0.03, 0.11 - (far - FAR) * 0.001))
        }
        if (abs(d) < STEP) return Move.None
        horizontal = h
        if (h) {
            anchorX += if (d > 0) STEP else -STEP
            anchorY = y
        } else {
            anchorY += if (d > 0) STEP else -STEP
            anchorX = x
        }
        lastX = x; lastY = y
        return Move.Step(key(h, d))
    }

    companion object {
        const val STEP = 24f
        /** past this along the way it goes (or at the screen's edge) the arrow repeats, faster with distance */
        const val FAR = 72f
        const val TURN = 36f
        /** a touch this near the middle both ways (a fraction of the key's width and height) taps nothing */
        const val MIDDLE = 0.12f
        /** a drag begun this soon after a tap adds ⇧ */
        const val SHIFT_WITHIN = 0.3

        private fun key(horizontal: Boolean, d: Float) = if (horizontal) (if (d > 0) "Right" else "Left") else (if (d > 0) "Down" else "Up")

        /** The arrow towards the edge of the key under the thumb; null in the very middle, where the four zones meet. Any one unit. */
        fun tapKey(px: Float, py: Float, w: Float, h: Float): String? {
            val x = (px - w / 2) / max(w, 1f)
            val y = (py - h / 2) / max(h, 1f)
            if (abs(x) < MIDDLE && abs(y) < MIDDLE) return null
            return key(abs(x) > abs(y), if (abs(x) > abs(y)) x else y)
        }

        fun shifted(now: Double, lastTap: Double) = now - lastTap < SHIFT_WITHIN
    }
}
