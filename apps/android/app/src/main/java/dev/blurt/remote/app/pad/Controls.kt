// The small controls around the keys: an icon button (settings, find the pointer, the screen, the keyboard, the keys' switch), the chips
// over the picture while talking, and the row above the phone's keyboard.
package dev.blurt.remote.app.pad

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.widget.LinearLayout
import dev.blurt.remote.app.Fonts
import dev.blurt.remote.app.Haptics
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.Theme
import dev.blurt.remote.app.dp
import dev.blurt.remote.app.keys.Icons
import dev.blurt.remote.core.RemoteChord
import dev.blurt.remote.core.RemoteModifiers
import dev.blurt.remote.core.ToMac

/** A symbol on a slab or on nothing; lit (a pale slab, a dark mark) while what it controls is on, as a held modifier is. */
class IconButton(c: Context, var icon: String, label: String) : View(c) {
    var slab = false
        set(v) { field = v; invalidate() }
    var lit = false
        set(v) { field = v; invalidate() }
    var tint = Theme.caption
        set(v) { field = v; invalidate() }
    var onTap: (() -> Unit)? = null
    var onHold: (() -> Unit)? = null
    private var down = false
    private var heldFired = false
    private val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private val r = RectF()
    private val hold = Runnable { if (down && onHold != null) { heldFired = true; Haptics.grab(); onHold?.invoke() } }

    init {
        contentDescription = label
        isClickable = true
    }

    override fun onDraw(canvas: Canvas) {
        r.set(0f, 0f, width.toFloat(), height.toFloat())
        if (slab || lit || down) {
            p.color = when { lit -> Theme.slabLatched; down -> Theme.slabPressed; else -> Theme.slab }
            canvas.drawRoundRect(r, Theme.KEY_RADIUS.dp, Theme.KEY_RADIUS.dp, p)
        }
        p.typeface = Fonts.symbols(context)
        p.textSize = 21.dp
        p.color = if (lit) Color.BLACK else tint
        val fm = p.fontMetrics
        canvas.drawText(Icons.char(icon), width / 2f, height / 2f - (fm.ascent + fm.descent) / 2, p)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> { down = true; heldFired = false; invalidate(); postDelayed(hold, 450) }
            MotionEvent.ACTION_UP -> {
                removeCallbacks(hold)
                val inside = e.x in 0f..width.toFloat() && e.y in 0f..height.toFloat()
                if (down && inside && !heldFired) performClick()
                down = false
                invalidate()
            }
            MotionEvent.ACTION_CANCEL -> { removeCallbacks(hold); down = false; invalidate() }
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        onTap?.invoke()
        return true
    }
}

/** A pill: mint words on black, over the picture. */
class Chip(c: Context, val text: String, private val act: () -> Unit) : View(c) {
    private val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private var down = false

    init {
        contentDescription = text
        isClickable = true
    }

    override fun onDraw(canvas: Canvas) {
        p.color = if (down) Color.argb(230, 40, 40, 40) else Color.argb(184, 0, 0, 0)
        canvas.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), height / 2f, height / 2f, p)
        p.color = Theme.mint
        p.typeface = Fonts.medium
        p.textSize = 13.dp
        val fm = p.fontMetrics
        canvas.drawText(text, width / 2f, height / 2f - (fm.ascent + fm.descent) / 2, p)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> { down = true; invalidate() }
            MotionEvent.ACTION_UP -> { if (down) performClick(); down = false; invalidate() }
            MotionEvent.ACTION_CANCEL -> { down = false; invalidate() }
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        Haptics.tick()
        act()
        return true
    }
}

/** The row above the phone's keyboard: what a phone keyboard doesn't have. */
class ModifierRow(c: Context, private val onClose: () -> Unit) : LinearLayout(c) {
    private val mods = mutableListOf<Pair<Key, Int>>()

    inner class Key(val label: String, val icon: String?, val act: () -> Unit) : View(context) {
        var lit = false
            set(v) { field = v; invalidate() }
        private var down = false
        private val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }

        init {
            contentDescription = label
            isClickable = true
        }

        override fun onDraw(canvas: Canvas) {
            p.color = if (lit) Theme.slabLatched else if (down) Theme.slabPressed else Theme.slab
            canvas.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), 8.dp, 8.dp, p)
            p.color = if (lit) Color.BLACK else Theme.mark
            if (icon != null) { p.typeface = Fonts.symbols(context); p.textSize = 20.dp } else { p.typeface = Fonts.text; p.textSize = if (label.length > 2) 14.dp else 17.dp }
            val fm = p.fontMetrics
            canvas.drawText(if (icon != null) Icons.char(icon) else label, width / 2f, height / 2f - (fm.ascent + fm.descent) / 2, p)
        }

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> { down = true; invalidate() }
                MotionEvent.ACTION_UP -> { if (down) performClick(); down = false; invalidate() }
                MotionEvent.ACTION_CANCEL -> { down = false; invalidate() }
            }
            return true
        }

        override fun performClick(): Boolean { super.performClick(); act(); return true }
    }

    init {
        orientation = HORIZONTAL
        setBackgroundColor(Color.rgb(18, 18, 18))
        val pad = 6.dp.toInt()
        setPadding(pad, 4.dp.toInt(), pad, 4.dp.toInt())
        rebuild()
    }

    fun rebuild() {
        removeAllViews()
        mods.clear()
        val host = Remote.link.host.value
        fun add(k: Key) {
            addView(k, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f).apply { marginStart = 3.dp.toInt(); marginEnd = 3.dp.toInt() })
        }
        for ((m, g) in RemoteModifiers.ordered(host)) {
            val k = Key(g, dev.blurt.remote.app.keys.Icons.modifierFaces[g]) { Remote.sticky.tap(m, SystemClock.uptimeMillis() / 1000.0); Haptics.grab() }
            mods += k to m
            add(k)
        }
        add(Key("esc", null) { Remote.link.send(ToMac.Key(RemoteChord(0, "Escape"), null)); Haptics.tick() })
        add(Key("⇥", "keyboard_tab") { Remote.link.send(ToMac.Key(RemoteChord(0, "Tab"), null)); Haptics.tick() })
        add(Key("↑", "keyboard_arrow_up") { Remote.link.send(ToMac.Key(RemoteChord(0, "Up"), null)); Haptics.step() })
        add(Key("↓", "keyboard_arrow_down") { Remote.link.send(ToMac.Key(RemoteChord(0, "Down"), null)); Haptics.step() })
        add(Key(context.getString(dev.blurt.remote.app.R.string.hide_keyboard), "keyboard_hide") { onClose() })
        refresh()
    }

    fun refresh() {
        val held = Remote.sticky.held
        for ((k, m) in mods) k.lit = (held and m) == m
    }
}


/** Which of the computer's displays the picture is of: a screen with its number, numbered left to right as the displays are arranged.
 *  A tap steps to the next one to the right; a hold opens the map. Only there when the computer has more than one. */
class DisplayButton(c: Context) : View(c) {
    var number = 0
        set(v) { field = v; invalidate() }
    var slab = false
        set(v) { field = v; invalidate() }
    var onTap: (() -> Unit)? = null
    var onHold: (() -> Unit)? = null
    private var down = false
    private var held = false
    private val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private val r = RectF()
    private val hold = Runnable { if (down) { held = true; Haptics.grab(); onHold?.invoke() } }

    init {
        isClickable = true
        contentDescription = c.getString(dev.blurt.remote.app.R.string.displays)
    }

    override fun onDraw(canvas: Canvas) {
        if (slab || down) {
            p.style = Paint.Style.FILL
            p.color = if (down) Theme.slabPressed else Theme.slab
            r.set(0f, 0f, width.toFloat(), height.toFloat())
            canvas.drawRoundRect(r, Theme.KEY_RADIUS.dp, Theme.KEY_RADIUS.dp, p)
        }
        val cx = width / 2f
        val cy = height / 2f - 1.dp
        // the screen and its stand, the weight of the symbols beside it
        p.style = Paint.Style.STROKE
        p.strokeWidth = 1.5f.dp
        p.color = if (slab) Theme.mark else Theme.caption
        r.set(cx - 10.dp, cy - 7.5f.dp, cx + 10.dp, cy + 6.5f.dp)
        canvas.drawRoundRect(r, 2.5f.dp, 2.5f.dp, p)
        canvas.drawLine(cx - 4.dp, cy + 10.dp, cx + 4.dp, cy + 10.dp, p)
        p.style = Paint.Style.FILL
        p.typeface = Fonts.medium
        p.textSize = 10.dp
        val fm = p.fontMetrics
        canvas.drawText(if (number > 0) "$number" else "·", cx, cy - 0.5f.dp - (fm.ascent + fm.descent) / 2, p)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> { down = true; held = false; invalidate(); postDelayed(hold, 450) }
            MotionEvent.ACTION_UP -> {
                removeCallbacks(hold)
                if (down && !held) performClick()
                down = false
                invalidate()
            }
            MotionEvent.ACTION_CANCEL -> { removeCallbacks(hold); down = false; invalidate() }
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        Haptics.tick()
        onTap?.invoke()
        return true
    }
}
