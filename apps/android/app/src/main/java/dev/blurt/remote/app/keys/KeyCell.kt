// One key (port of Keys/KeyCell.swift). Raw touches, because a key here does more than a button does:
//
//   a plain key fires when the thumb lifts, so a thumb that lands wrong can slide off and nothing happens; held still it does nothing.
//   a cycle key (⌘Tab, Alt+Tab) presses at once and keeps the modifier down: slide to step through, a detent every 22 dp, left to go back;
//   at the edge of the screen it keeps stepping, so twenty apps are as reachable as three. Lifting lets go. A quick tap is the quick ⌘Tab:
//   back to the last app. The other keys are out of play meanwhile: the thumb passes over them.
//   the arrow key is four keys in one, each edge marked with its arrow: tap towards an edge for that arrow, hold to repeat. Or drag, one step
//   per 24 dp; past 72 dp, or at the screen's edge, it repeats, faster with distance. Tap and then drag does the same with ⇧.
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
    private var anchorX = 0f
    private var anchorY = 0f
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
            val inX = minOf(13.dp, w * 0.2f)
            val inY = minOf(11.dp, h * 0.22f)
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
                anchorX = x
                anchorY = y
                arrowShift = now() - lastArrowEnd < 0.3
                arrowRepeated = false
                parent?.requestDisallowInterceptTouchEvent(true)
                Haptics.step()
                startRepeat(arrowChord(x, y), 0.35, 0.08)
            }
            else -> {}
        }
    }

    /** The arrow towards the edge of the key under the thumb. */
    private fun arrowChord(px: Float, py: Float): RemoteChord {
        val x = (px - width / 2f) / max(width, 1)
        val y = (py - height / 2f) / max(height, 1)
        val key = if (abs(x) > abs(y)) (if (x > 0) "Right" else "Left") else (if (y > 0) "Down" else "Up")
        return RemoteChord(0, key)
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
            if (!moved && !arrowRepeated) {
                Remote.link.send(ToMac.Key(arrowChord(startX, startY), null))
                Remote.sticky.used()
            }
            lastArrowEnd = if (moved || arrowRepeated) 0.0 else now()
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
        val dx = e.x - anchorX
        val dy = e.y - anchorY
        val horizontal = abs(dx) > abs(dy)
        val d = if (horizontal) dx else dy
        val key = if (horizontal) (if (dx > 0) "Right" else "Left") else (if (dy > 0) "Down" else "Up")
        var far = hypot(e.x - startX, e.y - startY) / 1.dp
        // the thumb has run out of screen, sliding towards that edge: it repeats as if it had gone on
        val slid = (e.x - startX) / 1.dp
        if (horizontal && abs(slid) >= 24) {
            val band = EDGE * 0.6f
            val x = inWindow(e.x) / 1.dp
            val w = rootView.width / 1.dp
            if (slid < 0 && x < band || slid > 0 && x > w - band) far = max(far, 90f)
        }
        if (far > 72) {
            val rate = max(0.03, 0.11 - (far - 72) * 0.001)
            if (repeatKey?.key != key || abs(repeatRate - rate) > 0.01) {
                stopRepeat()
                startRepeat(RemoteChord(if (arrowShift) RemoteModifiers.SHIFT else 0, key), 0.0, rate)
            }
            return
        }
        stopRepeat()
        if (abs(d) >= 24.dp) {
            step(key)
            if (horizontal) anchorX += if (dx > 0) 24.dp else -24.dp else anchorY += if (dy > 0) 24.dp else -24.dp
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
