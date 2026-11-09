// How a key's face is drawn, on the keys and in the sheets alike: a Material Symbol, a mark drawn here, or text, which reads smaller the
// longer it is.
package dev.blurt.remote.app.keys

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import dev.blurt.remote.app.Fonts
import dev.blurt.remote.app.dp

object Face {
    /** The shorter the text, the larger: a key has little room, so a long name reads small and a short one is worth choosing. */
    /** a PC's modifiers written out: one size for all of them, so the dock reads as a row */
    private val modifierWords = setOf("Ctrl", "Win", "Super", "Alt", "Shift", "Cmd", "Option", "Control", "Command")

    fun textSize(f: String): Float {
        if (f in modifierWords) return 15f
        if (f.any { it in "⌘⌃⌥⇧" } || f.startsWith("Ctrl") || f.startsWith("Alt")) return if (f.length > 6) 13f else 16f   // a shortcut written out
        return when (f.codePointCount(0, f.length)) {
            in 0..2 -> 20f
            3 -> 15f
            4 -> 13f
            in 5..6 -> 11f
            else -> 9f
        }
    }

    /** Draws a face centred on (cx, cy). `iconDp`: the symbol's size. */
    fun draw(c: Canvas, ctx: Context, face: String, cx: Float, cy: Float, color: Int, paint: Paint, iconDp: Float = 22f, textScale: Float = 1f) {
        if (face.startsWith("mark:")) {
            val name = face.removePrefix("mark:")
            if (name in KeyMarks.names) { KeyMarks.draw(c, name, cx, cy, 1.dp * iconDp / 22f, color); return }
        }
        val g = if (face.startsWith("sf:")) Icons.glyph(face) else Icons.modifierFaces[face]?.let { Icons.glyph(it) }
        paint.color = color
        paint.textAlign = Paint.Align.CENTER
        if (g != null) {
            paint.typeface = if (g.filled) Fonts.symbolsFilled(ctx) else Fonts.symbols(ctx)
            paint.textSize = iconDp.dp
            val fm = paint.fontMetrics
            c.save()
            if (g.flip) c.scale(-1f, 1f, cx, cy)
            c.drawText(g.char, cx, cy - (fm.ascent + fm.descent) / 2, paint)
            c.restore()
            return
        }
        val text = if (face.startsWith("sf:") || face.startsWith("mark:")) "" else face
        paint.typeface = Fonts.text
        var size = textSize(text).dp * textScale
        paint.textSize = size
        val room = maxOf(1f, (c.clipBounds.width() - 6.dp))
        while (paint.measureText(text) > room && size > 7.dp) { size *= 0.92f; paint.textSize = size }
        val fm = paint.fontMetrics
        c.drawText(text, cx, cy - (fm.ascent + fm.descent) / 2, paint)
    }
}
