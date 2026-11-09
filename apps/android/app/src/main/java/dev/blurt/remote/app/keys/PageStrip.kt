// The list's sections by name (port of Keys/PageStrip.swift): one tap jumps there, and the mark follows as the list scrolls.
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

    override fun onDraw(canvas: Canvas) {
        if (names.isEmpty()) return
        val w = width.toFloat() / names.size
        // one size for every tab: the largest at which the longest name still fits, so no tab reads smaller than its neighbours
        var size = 13.dp
        p.typeface = Fonts.medium
        while (size > 9.dp && names.any { p.textSize = size; p.measureText(it) > w - 4.dp }) size *= 0.95f
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
            onSelect?.invoke((e.x / (width.toFloat() / names.size)).toInt().coerceIn(0, names.size - 1))
        }
        return true
    }
}
