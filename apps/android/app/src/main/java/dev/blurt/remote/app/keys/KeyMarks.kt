// Icons no symbol set has, drawn here as on the iPhone (Keys/KeyMarks.swift). Each is what the key looks like on the computer: ⌘Tab's row of
// apps with one picked out, a tab bar with the tab you'd land on filled in, selected text with a phone's handles. Line weights match the
// Material Symbols around them.
package dev.blurt.remote.app.keys

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF

object KeyMarks {
    val names = setOf("apps", "tabNext", "tabPrevious", "tabNew", "tabClose", "selectAll")

    /** The mark's own size, in dp (it's drawn at `scale` dp per unit). */
    fun size(name: String): Pair<Float, Float> = when (name) {
        "apps" -> 36f to 18f
        "selectAll" -> 26f to 20f
        else -> 24f to 18f
    }

    /** Draws `name` centred on (cx, cy), `s` px per unit, in `color`. */
    fun draw(c: Canvas, name: String, cx: Float, cy: Float, s: Float, color: Int) {
        val (w, h) = size(name)
        c.save()
        c.translate(cx - w * s / 2, cy - h * s / 2)
        c.scale(s, s)
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND }
        when (name) {
            "apps" -> apps(c, p)
            "tabNext" -> tabs(c, p, next = true)
            "tabPrevious" -> tabs(c, p, next = false)
            "tabNew" -> { window(c, p); line(c, p, 12f, 9f, 12f, 14.4f); line(c, p, 9.3f, 11.7f, 14.7f, 11.7f) }
            "tabClose" -> { window(c, p); line(c, p, 9.9f, 9.6f, 14.1f, 13.8f); line(c, p, 14.1f, 9.6f, 9.9f, 13.8f) }
            "selectAll" -> selectAll(c, p)
        }
        c.restore()
    }

    private fun line(c: Canvas, p: Paint, x0: Float, y0: Float, x1: Float, y1: Float) {
        p.style = Paint.Style.STROKE
        p.strokeWidth = 1.5f
        c.drawLine(x0, y0, x1, y1, p)
    }

    /** The switcher: a row of apps, one of them picked out. */
    private fun apps(c: Canvas, p: Paint) {
        p.style = Paint.Style.FILL
        for (x in floatArrayOf(0.5f, 12.5f, 22.5f, 30f)) c.drawRoundRect(RectF(x, 6f, x + 5.5f, 12f), 1.6f, 1.6f, p)
        p.style = Paint.Style.STROKE
        p.strokeWidth = 1.5f
        c.drawRoundRect(RectF(8.75f, 2.75f, 21.75f, 15.25f), 3.4f, 3.4f, p)
    }

    /** A window with a tab bar: all the keys about tabs look like one family. */
    private fun window(c: Canvas, p: Paint) {
        p.style = Paint.Style.STROKE
        p.strokeWidth = 1.4f
        c.drawRoundRect(RectF(1.2f, 1.2f, 22.8f, 16.8f), 3f, 3f, p)
        c.drawLine(1f, 6.5f, 23f, 6.5f, p)
    }

    private fun tabs(c: Canvas, p: Paint, next: Boolean) {
        c.save()
        val clip = Path().apply { addRoundRect(RectF(1.2f, 1.2f, 22.8f, 16.8f), 3f, 3f, Path.Direction.CW) }
        c.clipPath(clip)
        p.style = Paint.Style.FILL
        c.drawRect(if (next) 12f else 0f, 0f, if (next) 24f else 12f, 6.5f, p)
        c.restore()
        window(c, p)
        // which way, in the page under the tabs
        val x = 12f
        val y = 11.6f
        val d = if (next) 1f else -1f
        p.strokeWidth = 1.5f
        val chevron = Path().apply { moveTo(x - 1.5f * d, y - 2.6f); lineTo(x + 1.5f * d, y); lineTo(x - 1.5f * d, y + 2.6f) }
        c.drawPath(chevron, p)
    }

    /** Text selected: the lines between the two handles a phone shows. */
    private fun selectAll(c: Canvas, p: Paint) {
        p.style = Paint.Style.STROKE
        p.strokeWidth = 1.6f
        for ((y, x0, x1) in listOf(Triple(5f, 7f, 21f), Triple(10f, 5f, 21f), Triple(15f, 5f, 16f))) c.drawLine(x0, y, x1, y, p)
        p.strokeWidth = 1.3f
        c.drawLine(3.2f, 4f, 3.2f, 12f, p)
        c.drawLine(22.8f, 8f, 22.8f, 16f, p)
        p.style = Paint.Style.FILL
        c.drawCircle(3.2f, 3f, 2.2f, p)
        c.drawCircle(22.8f, 17f, 2.2f, p)
    }
}
