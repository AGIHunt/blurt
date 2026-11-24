// Over the computer keyboard: which of the two keyboards this is, and what's held, with one tap that lets go of all of it.
package dev.blurt.remote.app.keys

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.MotionEvent
import android.view.View
import dev.blurt.remote.app.Fonts
import dev.blurt.remote.app.Haptics
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.Theme
import dev.blurt.remote.app.dp
import dev.blurt.remote.core.RemoteHost
import dev.blurt.remote.core.RemoteModifiers
import kotlin.math.min

class KeyboardSwitch(c: Context) : View(c) {
    /** the phone's own keyboard instead */
    var onText: (() -> Unit)? = null
    var host = RemoteHost.MAC
    private val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private val names = listOf(c.getString(R.string.keyboard_text), c.getString(R.string.keyboard_computer))
    /** room for both at once; otherwise what's held takes the choice's place while it is */
    private val roomy get() = width >= 300.dp
    private val choiceW get() = min(width - 8.dp, 190.dp)

    private fun held(): String {
        val s = Remote.sticky
        val m = s.once or s.locked
        val list = (if (m == 0) emptyList() else listOf(RemoteModifiers.glyphs(m, host))) + if (s.altGrOnce || s.altGrLocked) listOf("AltGr") else emptyList()
        return list.joinToString(" ")
    }

    init { isClickable = true }

    fun refresh() {
        val h = held()
        contentDescription = if (h.isEmpty()) names[0] else context.getString(R.string.let_go_of, h)
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val h = min(height.toFloat(), 36.dp)
        val top = (height - h) / 2
        val words = held()
        if (words.isEmpty() || roomy) {
            val l = 4.dp
            p.color = Theme.slab
            canvas.drawRoundRect(l, top, l + choiceW, top + h, h / 2, h / 2, p)
            p.color = Theme.slabPressed
            canvas.drawRoundRect(l + choiceW / 2, top + 2.dp, l + choiceW - 2.dp, top + h - 2.dp, h / 2, h / 2, p)
            names.forEachIndexed { i, n -> text(canvas, n, l + choiceW * (0.25f + 0.5f * i), choiceW / 2 - 10.dp, Theme.mark, if (i == 1) Fonts.medium else Fonts.text) }
        }
        if (words.isNotEmpty()) {
            p.typeface = Fonts.medium
            p.textSize = 16.dp
            val w = min(p.measureText(words) + 44.dp, if (roomy) width - choiceW - 12.dp else width - 8.dp)
            val l = if (roomy) width - w - 4.dp else 4.dp
            p.color = Theme.slabLatched
            canvas.drawRoundRect(l, top, l + w, top + h, h / 2, h / 2, p)
            text(canvas, "$words  ✕", l + w / 2, w - 16.dp, Color.BLACK, Fonts.medium, 16f)
        }
    }

    private fun text(canvas: Canvas, s: String, x: Float, room: Float, ink: Int, face: android.graphics.Typeface, size: Float = 13f) {
        p.typeface = face
        p.color = ink
        p.textSize = size.dp
        val w = p.measureText(s)
        if (w > room && w > 0) p.textSize = size.dp * room / w
        val fm = p.fontMetrics
        canvas.drawText(s, x, height / 2f - (fm.ascent + fm.descent) / 2, p)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_UP) act(e.x)
        return true
    }

    private fun act(x: Float) {
        Haptics.tick()
        val any = held().isNotEmpty()
        if (any && (!roomy || x > choiceW + 8.dp)) Remote.sticky.letGo()
        else if (x < 4.dp + choiceW / 2) onText?.invoke()
    }

    override fun performClick(): Boolean {
        super.performClick()
        if (held().isNotEmpty()) Remote.sticky.letGo() else onText?.invoke()
        return true
    }
}
