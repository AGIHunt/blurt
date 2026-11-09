// Plain points, sizes and rectangles for the pad and the view (CGPoint, CGSize, CGRect on iOS), in points (dp on Android), as Doubles.
package dev.blurt.remote.core

import kotlin.math.max
import kotlin.math.min

data class PadPoint(val x: Double, val y: Double) {
    companion object { val ZERO = PadPoint(0.0, 0.0) }
}

data class PadSize(val width: Double, val height: Double)

data class PadRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    val minX: Double get() = x
    val minY: Double get() = y
    val maxX: Double get() = x + width
    val maxY: Double get() = y + height
    val midX: Double get() = x + width / 2
    val midY: Double get() = y + height / 2
    val isEmpty: Boolean get() = width <= 0 || height <= 0

    /** The overlap; an empty rect (0 size at the origin's side) if none. */
    fun intersection(o: PadRect): PadRect {
        val x0 = max(minX, o.minX)
        val y0 = max(minY, o.minY)
        val x1 = min(maxX, o.maxX)
        val y1 = min(maxY, o.maxY)
        return if (x1 <= x0 || y1 <= y0) PadRect(x0, y0, 0.0, 0.0) else PadRect(x0, y0, x1 - x0, y1 - y0)
    }

    fun insetBy(dx: Double, dy: Double): PadRect = PadRect(x + dx, y + dy, width - 2 * dx, height - 2 * dy)

    fun contains(p: PadPoint): Boolean = p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY

    companion object { val UNIT = PadRect(0.0, 0.0, 1.0, 1.0) }
}
