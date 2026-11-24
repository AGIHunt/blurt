// The line where one finger scrolls (docs/design/remote.md §Trackpad; port of Pad/EdgeMark.swift). Always there, and lit while it scrolls.
// Over the picture it's see-through with a dark rim, so it reads on a white page and a black one.
package dev.blurt.remote.app.pad

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.View
import dev.blurt.remote.app.dp

@SuppressLint("ViewConstructor")
class EdgeMark(c: Context) : View(c) {
    /** the computer's screen is under it */
    var overPicture = false
        set(v) { field = v; invalidate() }
    /** a finger is scrolling along it now */
    var lit = false
        set(v) { field = v; invalidate() }
    private val p = Paint(Paint.ANTI_ALIAS_FLAG)

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        val r = w / 2
        p.style = Paint.Style.FILL
        p.color = Color.argb(if (lit) 230 else if (overPicture) 128 else 72, 255, 255, 255)
        canvas.drawRoundRect(0f, 0f, w, h, r, r, p)
        if (!overPicture) return
        p.style = Paint.Style.STROKE
        p.strokeWidth = 0.5f.dp
        p.color = Color.argb(115, 0, 0, 0)
        canvas.drawRoundRect(0.25f.dp, 0.25f.dp, w - 0.25f.dp, h - 0.25f.dp, r, r, p)
    }
}
