// The glass: raw MotionEvents into PadEngine, what it says to the computer (port of Pad/TrackpadView.swift). No GestureDetector: it waits
// to decide, and it can't share touches the way a trackpad needs. Touches come unbuffered (Android 11+), so a move goes out as the
// digitizer reports it, not at the next frame. A contact the size of a palm, or one the system calls a palm, is left out.
//
// A mouse on a tablet: its first click takes the pointer (pointer capture), and from then on it moves the computer's pointer, clicks and
// scrolls there. A touch anywhere gives it back.
package dev.blurt.remote.app.pad

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.widget.FrameLayout
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.Theme
import dev.blurt.remote.app.dp
import dev.blurt.remote.core.PadEngine
import dev.blurt.remote.core.PadHaptic
import dev.blurt.remote.core.PadOutput
import dev.blurt.remote.core.PadTouch
import dev.blurt.remote.core.RemoteMouseButton
import dev.blurt.remote.core.RemotePointerPacket
import dev.blurt.remote.core.RemoteScrollPhase
import dev.blurt.remote.core.ToMac

class TrackpadView(c: Context) : FrameLayout(c) {
    val engine = PadEngine()
    var onHaptic: ((PadHaptic) -> Unit)? = null
    var onViewEnd: (() -> Unit)? = null
    /** the phone's sticky modifiers were used by a click: one-shot ones clear */
    var onClick: (() -> Unit)? = null
    /** this pad shows the picture (the stage); a second pad beside the keys never does */
    var isStage = true
    /** what it looks like: the glass with a hairline, or the picture's black with small corners */
    var showing = false
        set(v) { field = v; invalidate() }

    private val main = Handler(Looper.getMainLooper())
    private val palms = mutableSetOf<Int>()
    private val known = mutableSetOf<Int>()
    private var ticking = false
    /** the touch landed off the picture, where there's nothing to click */
    private var offPicture = false
    private var dragOff = false
    /** this scroll began where the pointer was just put, and whether that was off the picture */
    private var scrollPlaced = false
    private var scrollOff = false
    private val density = resources.displayMetrics.density

    // a soft light under the finger: says the glass feels it
    private var glowX = -1f
    private var glowY = -1f
    private val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rect = RectF()

    init {
        setWillNotDraw(false)
        isMotionEventSplittingEnabled = false
        isFocusable = true
        contentDescription = context.getString(dev.blurt.remote.app.R.string.trackpad)
    }

    // what's inside (the picture, the pointer, the words) is placed by PadScreen
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), MeasureSpec.getSize(heightMeasureSpec))

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {}

    override fun onDraw(canvas: Canvas) {
        rect.set(0f, 0f, width.toFloat(), height.toFloat())
        val r = if (showing) 6.dp else 22.dp
        fill.style = Paint.Style.FILL
        fill.color = if (showing) Color.TRANSPARENT else Theme.glass
        canvas.drawRoundRect(rect, r, r, fill)
        if (!showing) {
            fill.style = Paint.Style.STROKE
            fill.strokeWidth = 1.dp
            fill.color = Theme.hairline
            rect.inset(0.5.toFloat().dp, 0.5.toFloat().dp)
            canvas.drawRoundRect(rect, r, r, fill)
            if (glowX >= 0) {
                glowPaint.shader = RadialGradient(glowX, glowY, 75.dp, Color.argb(33, 255, 255, 255), Color.TRANSPARENT, Shader.TileMode.CLAMP)
                canvas.drawCircle(glowX, glowY, 75.dp, glowPaint)
            }
        }
    }

    private fun light(e: MotionEvent?, i: Int = 0) {
        if (engine.pinchZoomsView) { if (glowX >= 0) { glowX = -1f; invalidate() }; return }
        if (e == null) { glowX = -1f } else { glowX = e.getX(i); glowY = e.getY(i) }
        invalidate()
    }

    private fun isPalm(e: MotionEvent, i: Int): Boolean {
        // a resting palm or the side of a thumb: the iPhone's 44 pt radius, as a diameter
        return e.getTouchMajor(i) > 88 * density
    }

    private fun touch(e: MotionEvent, i: Int) = PadTouch(e.getPointerId(i), e.getX(i) / density.toDouble(), e.getY(i) / density.toDouble())

    private fun time(e: MotionEvent) = e.eventTime / 1000.0
    private fun clock() = SystemClock.uptimeMillis() / 1000.0

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (e.isFromSource(InputDevice.SOURCE_MOUSE) && e.getToolType(0) == MotionEvent.TOOL_TYPE_MOUSE) return mouse(e)
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                if (e.actionMasked == MotionEvent.ACTION_DOWN) {
                    if (Build.VERSION.SDK_INT >= 30) requestUnbufferedDispatch(e)
                    parent?.requestDisallowInterceptTouchEvent(true)
                    palms.clear()
                    known.clear()
                }
                val i = e.actionIndex
                val id = e.getPointerId(i)
                if (isPalm(e, i)) { palms += id; return true }
                known += id
                light(e, i)
                // zoomed in, with the glass as the screen, the picture is a photo under one finger; a touch anywhere stops it coasting
                engine.panView = isStage && showing && engine.touchMode && !Remote.screen.port.isWhole
                engine.viewCoasting = Remote.screen.stopCoast() && isStage
                apply(engine.began(listOf(touch(e, i)), time(e)))
                startTicks()
            }
            MotionEvent.ACTION_MOVE -> {
                val ts = (0 until e.pointerCount).filter { e.getPointerId(it) in known }.map { touch(e, it) }
                if (ts.isEmpty()) return true
                light(e, (0 until e.pointerCount).first { e.getPointerId(it) in known })
                apply(engine.moved(ts, time(e)))
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                val i = e.actionIndex
                val id = e.getPointerId(i)
                palms -= id
                if (!known.remove(id)) return true
                // the system decided it was a palm after all (Android 13+): everything ends, nothing is clicked
                if (Build.VERSION.SDK_INT >= 33 && (e.flags and MotionEvent.FLAG_CANCELED) != 0) {
                    known.clear()
                    light(null)
                    apply(engine.cancel())
                    return true
                }
                if (known.isEmpty()) light(null)
                apply(engine.ended(listOf(id), time(e)))
                startTicks()
            }
            MotionEvent.ACTION_CANCEL -> {
                known.clear()
                palms.clear()
                light(null)
                apply(engine.cancel())
            }
        }
        return true
    }

    /** Everything ends: the app left the screen, or the system took the touches. */
    fun letGo() {
        known.clear()
        apply(engine.cancel())
    }

    private val tick = object : Runnable {
        override fun run() {
            apply(engine.tick(clock()))
            if (engine.needsTicks) main.postDelayed(this, 50) else ticking = false
        }
    }

    private fun startTicks() {
        if (ticking || !engine.needsTicks) return
        ticking = true
        main.postDelayed(tick, 50)
    }

    private fun apply(out: List<PadOutput>) {
        val link = Remote.link
        val screen = Remote.screen
        var placed = false
        val stage = isStage && screen.on
        for (o in out) {
            when (o) {
                is PadOutput.Move -> {
                    screen.bringPointerIntoView()
                    link.pointer(RemotePointerPacket.Move(o.dx, o.dy))
                    screen.predict(o.dx, o.dy)
                }
                is PadOutput.View -> if (stage) screen.change(o.scale, o.dx, o.dy, o.at)
                PadOutput.ViewEnd -> {
                    if (stage) screen.gestureEnded()
                    onViewEnd?.invoke()
                }
                is PadOutput.ViewCoast -> if (stage) screen.coastView(o.vx, o.vy)
                is PadOutput.PointAt -> {
                    offPicture = !(stage && screen.placePointer(o.point))
                    placed = true
                }
                is PadOutput.DragTo -> if (!dragOff && stage) screen.dragPointer(o.point)
                is PadOutput.Click -> {
                    if (offPicture && engine.touchMode) continue      // a double tap off the picture is two of nothing
                    screen.bringPointerIntoView()
                    link.send(ToMac.Button(o.button, true))
                    link.send(ToMac.Button(o.button, false))
                    onClick?.invoke()
                }
                is PadOutput.Button -> {
                    if (o.down) {
                        dragOff = offPicture && engine.touchMode
                        if (dragOff) continue
                        screen.bringPointerIntoView()
                    } else {
                        if (dragOff) { dragOff = false; continue }
                        screen.finishDrag()
                    }
                    link.send(if (o.down) ToMac.DragBegin else ToMac.Button(o.button, false))
                    if (!o.down) onClick?.invoke()
                }
                is PadOutput.Scroll -> {
                    if (o.phase == RemoteScrollPhase.BEGAN) {
                        // a scroll that starts where the pointer was just put: in order behind it, and not at all off the picture
                        scrollPlaced = placed
                        scrollOff = placed && offPicture && engine.touchMode
                    }
                    if (scrollOff) continue
                    val f = if (Remote.prefs.reverseScroll) -1f else 1f
                    link.pointer(RemotePointerPacket.Scroll(o.dx * f, o.dy * f, o.phase), scrollPlaced)
                }
                is PadOutput.Fling -> {
                    if (scrollOff) continue
                    val f = if (Remote.prefs.reverseScroll) -1f else 1f
                    link.pointer(RemotePointerPacket.ScrollFling(o.vx * f, o.vy * f), scrollPlaced)
                }
                PadOutput.ScrollStop -> link.pointer(RemotePointerPacket.ScrollStop)
                is PadOutput.System -> link.send(ToMac.System(o.move))
                is PadOutput.Haptic -> onHaptic?.invoke(o.haptic)
            }
        }
    }

    // MARK: a mouse

    private var wheelEnd: Runnable? = null
    private var wheeling = false

    private fun mouse(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_DOWN && !hasPointerCapture()) requestPointerCapture()
        return true
    }

    override fun onCapturedPointerEvent(e: MotionEvent): Boolean {
        val link = Remote.link
        when (e.actionMasked) {
            MotionEvent.ACTION_MOVE, MotionEvent.ACTION_HOVER_MOVE -> {
                val k = Remote.prefs.pointerSpeed
                var dx = 0f
                var dy = 0f
                for (h in 0 until e.historySize) { dx += e.getHistoricalX(h); dy += e.getHistoricalY(h) }
                dx += e.x
                dy += e.y
                if (dx != 0f || dy != 0f) {
                    link.pointer(RemotePointerPacket.Move(dx * k, dy * k))
                    Remote.screen.predict(dx * k, dy * k)
                }
            }
            MotionEvent.ACTION_BUTTON_PRESS, MotionEvent.ACTION_BUTTON_RELEASE -> {
                val b = when (e.actionButton) {
                    MotionEvent.BUTTON_SECONDARY -> RemoteMouseButton.RIGHT
                    MotionEvent.BUTTON_TERTIARY -> RemoteMouseButton.MIDDLE
                    else -> RemoteMouseButton.LEFT
                }
                val down = e.actionMasked == MotionEvent.ACTION_BUTTON_PRESS
                link.send(ToMac.Button(b, down))
                if (!down) onClick?.invoke()
            }
            MotionEvent.ACTION_SCROLL -> {
                // a wheel's notches as a short trackpad scroll, so apps scroll as they do for the computer's own wheel
                val f = if (Remote.prefs.reverseScroll) -1f else 1f
                val dy = e.getAxisValue(MotionEvent.AXIS_VSCROLL) * 40f * f
                val dx = -e.getAxisValue(MotionEvent.AXIS_HSCROLL) * 40f * f
                if (!wheeling) { wheeling = true; link.pointer(RemotePointerPacket.Scroll(0f, 0f, RemoteScrollPhase.BEGAN)) }
                link.pointer(RemotePointerPacket.Scroll(dx, dy, RemoteScrollPhase.CHANGED))
                wheelEnd?.let { main.removeCallbacks(it) }
                val r = Runnable { wheeling = false; link.pointer(RemotePointerPacket.Scroll(0f, 0f, RemoteScrollPhase.ENDED)) }
                wheelEnd = r
                main.postDelayed(r, 120)
            }
        }
        return true
    }
}
