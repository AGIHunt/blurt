// How fingers become pointer movement (Swift: RemotePointer.swift). The glass is about a tenth of a trackpad and the screen it steers may be
// 4K: flat and precise below `slow`, rising smoothly to `fastGain` by `fast`, the way a desktop's pointer acceleration feels.
package dev.blurt.remote.core

import kotlin.math.sqrt

data class RemotePointerCurve(
    /** points on the host per point on the glass, for a slow finger */
    val slowGain: Float = 1.0f,
    /** the same, for a fast one */
    val fastGain: Float = 5.5f,
    /** finger speeds (points/s) between which the gain rises */
    val slow: Float = 60f,
    val fast: Float = 900f,
) {
    /** The user's one "speed" setting scales the whole curve, 1 = default. */
    fun scaled(s: Float): RemotePointerCurve = copy(slowGain = slowGain * s, fastGain = fastGain * s)

    fun gain(speed: Float): Float {
        val t = maxOf(0f, minOf(1f, (speed - slow) / (fast - slow)))
        val smooth = t * t * (3 - 2 * t)
        return slowGain + (fastGain - slowGain) * smooth
    }

    /** One step of the finger, in points, over `dt` seconds → the step for the host. */
    fun apply(dx: Float, dy: Float, dt: Float): Pair<Float, Float> {
        val g = gain(sqrt(dx * dx + dy * dy) / maxOf(dt, 0.001f))
        return dx * g to dy * g
    }
}

/** Keeps the fractions of a point that one-step rounding would lose: a slow drag must add up exactly. */
class RemoteSubpixel {
    private var x = 0f
    private var y = 0f

    fun whole(dx: Float, dy: Float): Pair<Int, Int> {
        x += dx
        y += dy
        val ix = truncate(x)
        val iy = truncate(y)
        x -= ix
        y -= iy
        return ix.toInt() to iy.toInt()
    }

    fun reset() {
        x = 0f
        y = 0f
    }

    private fun truncate(v: Float): Float = if (v < 0) kotlin.math.ceil(v) else kotlin.math.floor(v)
}
