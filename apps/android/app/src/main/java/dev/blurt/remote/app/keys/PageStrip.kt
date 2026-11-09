// The list's sections by name (port of Keys/PageStrip.swift): one tap jumps there, and the mark follows as the list scrolls. Where the names
// can't all be read (half a foldable, with the display switcher in the row), it shows the page you're on and a dot for each, and a tap goes to
// the next page.
package dev.blurt.remote.app.keys

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.view.MotionEvent
import android.view.View
import dev.blurt.remote.app.Fonts
import dev.blurt.remote.app.Theme
import dev.blurt.remote.app.dp

class PageStrip(c: Context) : View(c) {
    var onSelect: ((Int) -> Unit)? = null
    private var names: List<String> = emptyList()
    private var current = 0
    private val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }

    fun show(names: List<String>, page: Int) {
        this.names = names
        current = page
        contentDescription = names.getOrNull(page)
        invalidate()
    }

    /** Where the list is now: no animation of its own, it's already moving under the thumb. */
    fun select(i: Int) {
        if (i == current || i !in names.indices) return
        current = i
        contentDescription = names[i]
        invalidate()
    }

    /** One size for every tab: the largest at which the longest name still fits; 0 when even the smallest readable size doesn't. */
    private fun fit(): Float {
        if (names.isEmpty() || width <= 0) return 0f
        val w = width.toFloat() / names.size
        p.typeface = Fonts.medium
        var size = 13.dp
        while (size >= 10.dp) {
            p.textSize = size
            if (names.all { p.measureText(it) <= w - 4.dp }) return size
            size *= 0.95f
        }
        return 0f
    }

    private val compact get() = fit() == 0f

    override fun onDraw(canvas: Canvas) {
        if (names.isEmpty()) return
        val size = fit()
        if (size == 0f) {
            // the page you're on, and a dot for each page under it
            p.typeface = Fonts.medium
            p.color = Theme.mark
            p.textSize = 13.dp
            val fm = p.fontMetrics
            canvas.drawText(names[current], width / 2f, height / 2f - 4.dp - (fm.ascent + fm.descent) / 2, p)
            val step = 7.dp
            val x0 = width / 2f - step * (names.size - 1) / 2
            for (i in names.indices) {
                p.color = if (i == current) Theme.mark else Theme.faint
                canvas.drawCircle(x0 + i * step, height / 2f + 11.dp, 2.dp, p)
            }
            return
        }
        val w = width.toFloat() / names.size
        p.textSize = size
        for ((i, n) in names.withIndex()) {
            val on = i == current
            p.typeface = if (on) Fonts.medium else Fonts.text
            p.color = if (on) Theme.mark else Theme.faint
            val fm = p.fontMetrics
            canvas.drawText(n, w * i + w / 2, height / 2f - (fm.ascent + fm.descent) / 2, p)
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_UP && names.isNotEmpty() && width > 0) {
            onSelect?.invoke(if (compact) (current + 1) % names.size else (e.x / (width.toFloat() / names.size)).toInt().coerceIn(0, names.size - 1))
        }
        return true
    }
}
