// The trackpad's rules without a UI toolkit (Swift: apps/ios/BlurtRemote/Pad/PadEngine.swift): touches and time in, pointer actions out, so
// every gesture is a plain tested sequence. Time is seconds (Double), positions are points on the pad (dp on Android).
//
//   one finger   move · tap = click · tap, tap = double click · tap then press and move = drag; lifting during a drag leaves the button down
//                for `DRAG_GRACE`, so a long drag can take a new stroke
//   `touchMode`  with the host's screen showing, the glass is the screen: a tap or a press lands under the finger and a drag follows it.
//                Moving a finger is still the pointer, for what's too small to hit
//   `panView`    and zoomed in, the picture is a photo: one finger moves it, and a flick sends it coasting. What's too small to hit
//                is what the zoom is for; the pointer by itself is the pad between the thumbs, a mouse
//   hold still   `HOLD_TIME` (the phone taps back), then move = drag; or lift = right click
//   the edge     one finger along the side by the thumb = scroll
//   two fingers  move = scroll what's under the pointer, both ways; tap = right click; pinch = zoom the app on the host. With the screen
//                showing, a pinch zooms the view on the phone instead, and the scroll is under the fingers. A scroll stays a scroll until
//                the fingers clearly pinch. Away from the picture (the pad between the thumbs, Touch Mode off) the zoomed view follows
//                the pointer
//   three        swipe left/right = change desktop, up = all windows, down = this app's windows
//
// A touch that stops a coasting scroll is only that: no click. A thumb resting still never clicks (`TAP_TIME`).
package dev.blurt.remote.core

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max

data class PadTouch(val id: Int, val x: Double, val y: Double)

enum class PadHaptic { TAP, GRAB, RELEASE, STEP }

sealed class PadOutput {
    data class Move(val dx: Float, val dy: Float) : PadOutput()
    data class Click(val button: RemoteMouseButton) : PadOutput()
    data class Button(val button: RemoteMouseButton, val down: Boolean) : PadOutput()
    data class Scroll(val dx: Float, val dy: Float, val phase: RemoteScrollPhase) : PadOutput()
    data class Fling(val vx: Float, val vy: Float) : PadOutput()
    data object ScrollStop : PadOutput()
    data class System(val move: RemoteSystemMove) : PadOutput()
    data class Haptic(val haptic: PadHaptic) : PadOutput()
    /** the host's screen is showing: the view on the phone, this much closer and moved this far since the last one, about this point */
    data class View(val scale: Double, val dx: Double, val dy: Double, val at: PadPoint) : PadOutput()
    /** the pointer goes under this point on the pad, ready for what comes next */
    data class PointAt(val point: PadPoint) : PadOutput()
    /** and follows the finger, with the button down */
    data class DragTo(val point: PadPoint) : PadOutput()
    data object ViewEnd : PadOutput()
    /** the finger moving the picture left it at this speed (points a second): it coasts on */
    data class ViewCoast(val vx: Double, val vy: Double) : PadOutput()
}

class PadEngine {
    companion object {
        const val SLOP = 6.0
        const val TAP_TIME = 0.22
        const val DOUBLE_WINDOW = 0.30
        const val DOUBLE_REACH = 44.0
        const val HOLD_TIME = 0.40
        const val DRAG_GRACE = 0.45
        /** held longer than this and lifted, it was a resting thumb, not a right click */
        const val HOLD_LIMIT = 1.2
        const val COAST_TIME = 2.0
        const val PINCH_STEP = 36.0
        const val SWIPE_TRIP = 40.0
        /** how far fingers moving the view must come apart or together before it's a pinch */
        const val PINCH_RATIO = 0.14
    }

    private sealed class State {
        data object Idle : State()
        /** may yet be a tap */
        data class One(val start: PadPoint, val last: PadPoint, val at: Double) : State()
        data class Moving(val last: PadPoint) : State()
        /** pressed right after a tap: a double click or a drag */
        data class Second(val start: PadPoint, val at: Double) : State()
        data class Dragging(val last: PadPoint) : State()
        /** held still: right click or drag */
        data class Held(val start: PadPoint, val at: Double) : State()
        data class Scrolling(val last: PadPoint, val two: Boolean) : State()
        /** undecided */
        data class Two(val start: PadPoint, val spread: Double, val at: Double) : State()
        data class Pinch(val spread: Double) : State()
        /** fingers on the view; spread 0 with one of them lifted. Not zooming: only moving, until they've come apart from `from` */
        data class View(val spread: Double, val center: PadPoint, val from: Double, val zooming: Boolean) : State()
        /** one finger on the zoomed picture, moving it */
        data class Panning(val last: PadPoint) : State()
        data class Three(val start: PadPoint) : State()
        /** a gesture finished; wait for all fingers to lift */
        data object Spent : State()
    }

    private data class Sample(val t: Double, val dx: Double, val dy: Double)

    private var state: State = State.Idle
    private val touches = LinkedHashMap<Int, PadPoint>()
    private var lastTap: Pair<Double, PadPoint>? = null
    /** the host is coasting a scroll until about then */
    private var coastUntil: Double? = null
    private var dragLetGo: Double? = null
    private var lastMoveAt = 0.0
    private var samples = mutableListOf<Sample>()
    /** how far apart two scrolling fingers started */
    private var scrollSpread = 0.0

    var curve = RemotePointerCurve()
    var pinchZoomsView = false
    var touchMode = false
    /** the picture is zoomed in under the finger: one finger moves it (set as the touch lands) */
    var panView = false
    /** and it was coasting when this touch landed: the touch stops it, and may move it on, but is no click */
    var viewCoasting = false
    /** where one finger scrolls, across the pad (x); null = nowhere */
    var scrollEdge: ClosedFloatingPointRange<Double>? = null
    var scrollGain = 2.4

    private val centroid: PadPoint
        get() {
            val n = max(touches.size, 1).toDouble()
            var x = 0.0
            var y = 0.0
            for (p in touches.values) { x += p.x; y += p.y }
            return PadPoint(x / n, y / n)
        }

    private val spread: Double
        get() {
            if (touches.size < 2) return 0.0
            val it = touches.values.iterator()
            val a = it.next()
            val b = it.next()
            return hypot(a.x - b.x, a.y - b.y)
        }

    private fun dist(a: PadPoint, b: PadPoint) = hypot(a.x - b.x, a.y - b.y)

    fun began(ts: List<PadTouch>, now: Double): List<PadOutput> {
        if (ts.isEmpty()) return emptyList()    // a palm, filtered out by the view
        val out = mutableListOf<PadOutput>()
        for (t in ts) touches[t.id] = PadPoint(t.x, t.y)
        coastUntil?.let { c ->
            coastUntil = null
            if (now < c) { out += PadOutput.ScrollStop; state = State.Spent }
        }

        when (touches.size) {
            1 -> {
                if (state == State.Idle) {
                    val p = centroid
                    val g = dragLetGo
                    val l = lastTap
                    if (viewCoasting && panView) {
                        samples = mutableListOf()
                        state = State.Panning(p)
                    } else if (g != null && now - g < DRAG_GRACE) {
                        dragLetGo = null
                        state = State.Dragging(p)
                    } else if (l != null && now - l.first < DOUBLE_WINDOW && dist(l.second, p) < DOUBLE_REACH) {
                        state = State.Second(p, now)
                    } else {
                        state = State.One(p, p, now)
                    }
                }
            }
            2 -> when (val s = state) {
                State.Idle, is State.One, is State.Moving, is State.Second, is State.Held -> state = State.Two(centroid, spread, now)
                is State.Dragging -> state = State.Dragging(centroid)   // a second finger joining a drag changes nothing
                is State.Scrolling -> state = State.Scrolling(centroid, s.two)
                is State.View -> state = State.View(spread, centroid, spread, s.zooming)
                // a second finger on the picture being moved: both move it, and zoom it once they come apart
                is State.Panning -> state = State.View(spread, centroid, spread, false)
                else -> {}
            }
            else -> when (state) {
                is State.Dragging -> state = State.Dragging(centroid)
                State.Spent -> {}
                is State.Scrolling -> {
                    // the first two fingers moved a little before the third landed: it was three all along
                    out += PadOutput.Scroll(0f, 0f, RemoteScrollPhase.ENDED)
                    state = State.Three(centroid)
                }
                is State.View, is State.Panning -> {
                    out += PadOutput.ViewEnd
                    state = State.Three(centroid)
                }
                else -> state = State.Three(centroid)
            }
        }
        return out
    }

    fun moved(ts: List<PadTouch>, now: Double): List<PadOutput> {
        for (t in ts) if (touches.containsKey(t.id)) touches[t.id] = PadPoint(t.x, t.y)
        val p = centroid
        val out = mutableListOf<PadOutput>()
        when (val s = state) {
            is State.One -> if (dist(p, s.start) > SLOP) {
                val e = scrollEdge
                if (e != null && s.start.x in e && abs(p.y - s.start.y) > abs(p.x - s.start.x)) {
                    samples = mutableListOf()
                    out += PadOutput.Scroll(0f, 0f, RemoteScrollPhase.BEGAN)
                    state = State.Scrolling(p, false)
                } else if (panView) {
                    samples = mutableListOf()
                    state = State.Panning(p)
                } else {
                    lastMoveAt = now
                    state = State.Moving(p)
                }
            }
            is State.Panning -> {
                val dx = p.x - s.last.x
                val dy = p.y - s.last.y
                samples += Sample(now, dx, dy)
                samples.removeAll { now - it.t > 0.09 }
                out += PadOutput.View(1.0, dx, dy, p)
                state = State.Panning(p)
            }
            is State.Moving -> {
                out += pointer(s.last, p, now)
                state = State.Moving(p)
            }
            is State.Second -> if (dist(p, s.start) > SLOP) {
                lastTap = null
                lastMoveAt = now
                if (touchMode) out += PadOutput.PointAt(s.start)
                out += listOf(PadOutput.Button(RemoteMouseButton.LEFT, true), PadOutput.Haptic(PadHaptic.GRAB))
                state = State.Dragging(p)
            }
            is State.Dragging -> {
                if (touchMode) {
                    touches.keys.minOrNull()?.let { k -> touches[k]?.let { out += PadOutput.DragTo(it) } }    // the finger that started it
                } else {
                    out += pointer(s.last, p, now)
                }
                state = State.Dragging(p)
            }
            is State.Held -> if (dist(p, s.start) > SLOP) {
                lastTap = null
                lastMoveAt = now
                out += PadOutput.Button(RemoteMouseButton.LEFT, true)
                state = State.Dragging(p)
            }
            is State.Scrolling -> {
                // a scroll that turns into a clear pinch: the picture zooms from here, and the scroll ends without coasting
                // (by a third and 36 pt both, so fingers drifting over a long scroll don't count)
                if (s.two && pinchZoomsView && touches.size >= 2 && scrollSpread > 0 &&
                    abs(spread - scrollSpread) > max(PINCH_STEP, scrollSpread / 3)
                ) {
                    out += PadOutput.Scroll(0f, 0f, RemoteScrollPhase.ENDED)
                    state = State.View(spread, p, spread, true)
                } else {
                    val dx = p.x - s.last.x
                    val dy = p.y - s.last.y
                    samples += Sample(now, dx, dy)
                    samples.removeAll { now - it.t > 0.09 }
                    out += PadOutput.Scroll((dx * scrollGain).toFloat(), (dy * scrollGain).toFloat(), RemoteScrollPhase.CHANGED)
                    state = State.Scrolling(p, s.two)
                }
            }
            is State.Two -> if (touches.size >= 2) {
                if (pinchZoomsView && abs(spread - s.spread) > PINCH_STEP * 0.35) {
                    state = State.View(spread, p, spread, true)
                } else if (!pinchZoomsView && abs(spread - s.spread) > PINCH_STEP * 0.7) {
                    state = State.Pinch(spread)
                } else if (dist(p, s.start) > SLOP) {
                    // zoomed or not, two fingers scroll the host, as on its own trackpad: what's under the pointer scrolls. With the
                    // picture showing, that's what's under the fingers, the same as a tap
                    samples = mutableListOf()
                    scrollSpread = spread
                    if (touchMode) out += PadOutput.PointAt(s.start)
                    out += PadOutput.Scroll(0f, 0f, RemoteScrollPhase.BEGAN)
                    state = State.Scrolling(p, true)
                }
            }
            is State.Pinch -> if (touches.size >= 2 && abs(spread - s.spread) > PINCH_STEP) {
                out += listOf(PadOutput.System(if (spread > s.spread) RemoteSystemMove.ZOOM_IN else RemoteSystemMove.ZOOM_OUT), PadOutput.Haptic(PadHaptic.STEP))
                state = State.Pinch(spread)
            }
            is State.View -> if (touches.size >= 2 && s.spread > 0 && spread > 0) {
                val zoomingNow = s.zooming || abs(spread / s.from - 1) > PINCH_RATIO
                // the moment it becomes a pinch, it starts from here: nothing jumps
                out += PadOutput.View(if (s.zooming) spread / s.spread else 1.0, p.x - s.center.x, p.y - s.center.y, p)
                state = State.View(spread, p, s.from, zoomingNow)
            }
            is State.Three -> {
                val dx = p.x - s.start.x
                val dy = p.y - s.start.y
                if (touches.size >= 3 && max(abs(dx), abs(dy)) > SWIPE_TRIP) {
                    val m = if (abs(dx) > abs(dy)) {
                        if (dx > 0) RemoteSystemMove.SPACE_LEFT else RemoteSystemMove.SPACE_RIGHT
                    } else {
                        if (dy < 0) RemoteSystemMove.MISSION_CONTROL else RemoteSystemMove.APP_EXPOSE
                    }
                    out += listOf(PadOutput.System(m), PadOutput.Haptic(PadHaptic.GRAB))
                    state = State.Spent
                }
            }
            else -> {}
        }
        return out
    }

    private fun pointer(a: PadPoint, b: PadPoint, now: Double): List<PadOutput> {
        val dx = (b.x - a.x).toFloat()
        val dy = (b.y - a.y).toFloat()
        val dt = (now - lastMoveAt).toFloat()
        lastMoveAt = now
        if (dx == 0f && dy == 0f) return emptyList()
        val (x, y) = curve.apply(dx, dy, dt)
        return listOf(PadOutput.Move(x, y))
    }

    fun ended(ids: List<Int>, now: Double): List<PadOutput> {
        for (i in ids) touches.remove(i)
        val out = mutableListOf<PadOutput>()
        if (touches.isNotEmpty()) {
            // a finger of two lifted: what's left of the gesture stays with the fingers still down
            when (val s = state) {
                is State.Scrolling -> {
                    scrollSpread = 0.0
                    state = State.Scrolling(centroid, s.two)
                }
                is State.Dragging -> state = State.Dragging(centroid)
                is State.View -> {
                    // one finger left on the picture goes on moving it, as on a photo
                    if (panView && touches.size == 1) {
                        samples = mutableListOf()
                        state = State.Panning(centroid)
                    } else {
                        state = State.View(0.0, centroid, 1.0, s.zooming)
                    }
                }
                else -> {}
            }
            return out
        }
        when (val s = state) {
            is State.One -> if (now - s.at < TAP_TIME) {
                if (touchMode) out += PadOutput.PointAt(s.start)
                out += listOf(PadOutput.Click(RemoteMouseButton.LEFT), PadOutput.Haptic(PadHaptic.TAP))
                lastTap = now to s.start
            }
            is State.Second -> {
                out += listOf(PadOutput.Click(RemoteMouseButton.LEFT), PadOutput.Haptic(PadHaptic.TAP))
                lastTap = null
            }
            is State.Dragging -> if (touchMode) {
                out += listOf(PadOutput.Button(RemoteMouseButton.LEFT, false), PadOutput.Haptic(PadHaptic.RELEASE))  // nothing to wait for
            } else {
                dragLetGo = now
            }
            is State.Held -> if (now - s.at < HOLD_LIMIT) out += listOf(PadOutput.Click(RemoteMouseButton.RIGHT), PadOutput.Haptic(PadHaptic.TAP))
            is State.Scrolling -> {
                out += PadOutput.Scroll(0f, 0f, RemoteScrollPhase.ENDED)
                releaseVelocity()?.let { v ->
                    out += PadOutput.Fling((v.first * scrollGain).toFloat(), (v.second * scrollGain).toFloat())
                    coastUntil = now + COAST_TIME
                }
            }
            is State.Two -> if (now - s.at < TAP_TIME + 0.1) {
                if (touchMode) out += PadOutput.PointAt(s.start)
                out += listOf(PadOutput.Click(RemoteMouseButton.RIGHT), PadOutput.Haptic(PadHaptic.TAP))
            }
            is State.View -> out += PadOutput.ViewEnd
            is State.Panning -> {
                out += PadOutput.ViewEnd
                releaseVelocity()?.let { v -> out += PadOutput.ViewCoast(v.first, v.second) }
            }
            else -> {}
        }
        state = State.Idle
        return out
    }

    private fun releaseVelocity(): Pair<Double, Double>? {
        val first = samples.firstOrNull() ?: return null
        val last = samples.last()
        if (!(last.t > first.t) || samples.size < 2) return null
        val span = max(last.t - first.t, 0.016)
        val vx = samples.sumOf { it.dx } / span
        val vy = samples.sumOf { it.dy } / span
        return if (hypot(vx, vy) > 120) vx to vy else null
    }

    /** Time passing, called about ten times a second while anything is down or pending (`needsTicks`). */
    fun tick(now: Double): List<PadOutput> {
        val out = mutableListOf<PadOutput>()
        val s = state
        if (s is State.One && now - s.at >= HOLD_TIME) {
            state = State.Held(s.start, now)
            if (touchMode) out += PadOutput.PointAt(s.start)    // the pointer comes to the finger as the phone taps back
            out += PadOutput.Haptic(PadHaptic.GRAB)
        }
        dragLetGo?.let { g ->
            if (now - g >= DRAG_GRACE) {
                dragLetGo = null
                out += listOf(PadOutput.Button(RemoteMouseButton.LEFT, false), PadOutput.Haptic(PadHaptic.RELEASE))
            }
        }
        return out
    }

    val needsTicks: Boolean get() = dragLetGo != null || state is State.One

    /** Everything ends: the app left the screen, or the system took the touches. */
    fun cancel(): List<PadOutput> {
        val out = mutableListOf<PadOutput>()
        when (state) {
            is State.Dragging -> out += PadOutput.Button(RemoteMouseButton.LEFT, false)
            is State.Scrolling -> out += PadOutput.Scroll(0f, 0f, RemoteScrollPhase.ENDED)
            is State.View, is State.Panning -> out += PadOutput.ViewEnd
            else -> {}
        }
        if (dragLetGo != null) {
            out += PadOutput.Button(RemoteMouseButton.LEFT, false)
            dragLetGo = null
        }
        touches.clear()
        state = State.Idle
        lastTap = null
        return out
    }
}
