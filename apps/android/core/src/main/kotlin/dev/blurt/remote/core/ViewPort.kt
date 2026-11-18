// What's in view of the host's screen, on the phone (Swift: apps/ios/BlurtRemote/Pad/ViewPort.swift). The phone owns this: fingers move it at
// once over the picture already here, and the host is asked for that part when it can send it. The stage is all the room the phone has and the
// picture sits in it like a photo: whole and letterboxed at first, filling the stage as it's zoomed. Everything is 0…1 of the screen.
package dev.blurt.remote.core

import kotlin.math.max
import kotlin.math.min

class ViewPort {
    companion object {
        const val CLOSEST = 8.0
        /** how far out a pinch stretches before it springs back */
        const val STRETCH = 0.8
        /** let go this close to the whole screen and it's the whole screen */
        const val SNAP = 1.08
        /** the pointer stays this far inside the view: past it, the view moves on */
        const val MARGIN = 0.12
    }

    var zoom = 1.0
        private set
    /** the stage in screen units: may stick out of 0…1 where the picture doesn't fill it */
    var rect = PadRect.UNIT
        private set
    /** the stage's shape over the picture's: above 1 it's wider than the picture, so that way has room to spare */
    private var shape = 1.0
    /** where a picture smaller than the stage sits, top to bottom, 0…1: near the thumb in portrait */
    private var alignY = 0.5

    val isWhole: Boolean get() = zoom <= 1

    /** The part of the screen in view. */
    val visible: PadRect get() = rect.intersection(PadRect.UNIT)

    /** The stage changed (its aspect over the picture's): the same middle stays in the middle. */
    fun reshape(s: Double, alignY: Double) {
        if (!(s > 0) || !s.isFinite() || (s == shape && alignY == this.alignY)) return
        val midX = rect.midX
        val midY = rect.midY
        shape = s
        this.alignY = alignY
        val size = size(zoom)
        set(zoom, midX - size.width / 2, midY - size.height / 2)
    }

    private fun size(z: Double) = PadSize(max(1.0, shape) / z, max(1.0, 1 / shape) / z)

    /** Scaled about `anchor` (0…1 of the stage), moved by `move` (a fraction of the stage). */
    fun change(scale: Double, move: PadPoint, anchor: PadPoint) {
        if (!(scale > 0) || !scale.isFinite()) return
        val z = max(STRETCH, min(CLOSEST, zoom * scale))
        val wx = rect.minX + anchor.x * rect.width
        val wy = rect.minY + anchor.y * rect.height
        val s = size(z)
        set(z, wx - (anchor.x + move.x) * s.width, wy - (anchor.y + move.y) * s.height)
    }

    /** The fingers lifted: past the whole screen it comes back. */
    fun settle() {
        if (zoom < SNAP) set(1.0, 0.0, 0.0)
    }

    /** The pointer (0…1 of the screen) near the edge of the view takes the view along. True if it moved. */
    fun follow(p: PadPoint): Boolean {
        if (isWhole) return false
        val v = visible
        val inner = v.insetBy(v.width * MARGIN, v.height * MARGIN)
        val dx = if (p.x < inner.minX) p.x - inner.minX else if (p.x > inner.maxX) p.x - inner.maxX else 0.0
        val dy = if (p.y < inner.minY) p.y - inner.minY else if (p.y > inner.maxY) p.y - inner.maxY else 0.0
        if (dx == 0.0 && dy == 0.0) return false
        val was = rect
        set(zoom, rect.minX + dx, rect.minY + dy)
        return rect != was
    }

    private fun set(z: Double, x: Double, y: Double) {
        zoom = z
        val s = size(z)
        // smaller than the screen it stays inside; larger, the picture sits still in it
        rect = PadRect(
            if (s.width < 1) min(1 - s.width, max(0.0, x)) else (1 - s.width) / 2,
            if (s.height < 1) min(1 - s.height, max(0.0, y)) else (1 - s.height) * alignY,
            s.width, s.height,
        )
    }

    /** What to ask the host for: the screen's shape, around what's in view. */
    val crop: RemoteCrop get() = crop(0.0, 0.0)

    /**
     * The same while the view is moving: around where it will be when the frame asked for now is on the glass, (`dx`, `dy`) ahead of
     * here in screen units, so the edge the picture is moving towards comes sharp instead of from the last sight of the whole screen.
     * No further ahead than a quarter of what's in view: past that it's a guess, and the other edge would pay for it.
     */
    fun crop(dx: Double, dy: Double): RemoteCrop {
        if (isWhole) return RemoteCrop.WHOLE
        val v = visible
        val side = min(1.0, max(v.width, v.height))
        if (side >= 1) return RemoteCrop.WHOLE
        val most = side / 4
        val x = v.midX + dx.coerceIn(-most, most)
        val y = v.midY + dy.coerceIn(-most, most)
        return RemoteCrop(min(1 - side, max(0.0, x - side / 2)).toFloat(), min(1 - side, max(0.0, y - side / 2)).toFloat(),
            side.toFloat(), side.toFloat())
    }
}
