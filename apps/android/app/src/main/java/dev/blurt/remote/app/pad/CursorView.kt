// The pointer over the picture, drawn by the phone: it's never a frame late. The computer's own shape once it has sent one; until then an
// arrow, white with a dark edge, as a pointer looks on any desktop.
package dev.blurt.remote.app.pad

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.view.View
import dev.blurt.remote.app.dp

class CursorView(c: Context) : View(c) {
    private var bitmap: Bitmap? = null
    /** the shape's size in the computer's points, and its hot spot */
    private var shapeW = 12.0
    private var shapeH = 18.0
    private var hotX = 0.0
    private var hotY = 0.0
    private var k = 1.0
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val arrow = Path()
    private val dst = RectF()

    init {
        visibility = INVISIBLE
        setWillNotDraw(false)
    }

    fun shape(b: Bitmap, hx: Double, hy: Double, w: Double, h: Double) {
        bitmap = b
        hotX = hx
        hotY = hy
        shapeW = w
        shapeH = h
        invalidate()
    }

    fun hide() { visibility = INVISIBLE }

    /** `x`, `y`: the hot spot, in dp in the pad; `scale`: the computer's points to dp */
    fun place(x: Double, y: Double, scale: Double) {
        visibility = VISIBLE
        if (scale != k) { k = scale; invalidate() }
        translationX = ((x - hotX * k) * 1.dp).toFloat()
        translationY = ((y - hotY * k) * 1.dp).toFloat()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) = setMeasuredDimension((64.dp).toInt(), (64.dp).toInt())

    override fun onDraw(canvas: Canvas) {
        val w = (shapeW * k).toFloat().dp
        val h = (shapeH * k).toFloat().dp
        val b = bitmap
        if (b != null) {
            dst.set(0f, 0f, w, h)
            canvas.drawBitmap(b, null, dst, paint)
            return
        }
        // the arrow, 12 × 18 points with the tip at the hot spot
        val s = (k * 1.dp).toFloat()
        arrow.reset()
        arrow.moveTo(0f, 0f)
        arrow.lineTo(0f, 16f * s)
        arrow.lineTo(4.2f * s, 12.4f * s)
        arrow.lineTo(7f * s, 18f * s)
        arrow.lineTo(9.4f * s, 17f * s)
        arrow.lineTo(6.8f * s, 11.6f * s)
        arrow.lineTo(12f * s, 11.6f * s)
        arrow.close()
        paint.style = Paint.Style.FILL
        paint.color = Color.WHITE
        paint.setShadowLayer(1.5f.dp, 0f, 0f, Color.argb(128, 0, 0, 0))
        canvas.drawPath(arrow, paint)
        paint.clearShadowLayer()
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 1.1f * s
        paint.strokeJoin = Paint.Join.ROUND
        paint.color = Color.BLACK
        canvas.drawPath(arrow, paint)
    }
}
