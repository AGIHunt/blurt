// The computer keyboard, drawn and touched as one view (port of Keys/FullBoard.swift): two thumbs land on it at once, and whose touch came
// first decides the order (core's FullTyping). Labels follow what's held: ⇧ shows what ⇧ types, fn what fn presses.
package dev.blurt.remote.app.keys

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeProvider
import dev.blurt.remote.app.Fonts
import dev.blurt.remote.app.Haptics
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.Theme
import dev.blurt.remote.app.dp
import dev.blurt.remote.core.FullKey
import dev.blurt.remote.core.FullKeys
import dev.blurt.remote.core.FullKind
import dev.blurt.remote.core.FullLabel
import dev.blurt.remote.core.FullOutput
import dev.blurt.remote.core.FullRect
import dev.blurt.remote.core.FullTier
import dev.blurt.remote.core.FullTyping
import dev.blurt.remote.core.RemoteChord
import dev.blurt.remote.core.RemoteHost
import dev.blurt.remote.core.RemoteModifiers
import dev.blurt.remote.core.ToMac
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

class FullBoard(c: Context) : View(c) {
    /** something was typed here: the phone's still in use */
    var onKey: (() -> Unit)? = null
    private var host = RemoteHost.MAC
    private var tier = FullTier.TEN
    private var keys: List<Pair<FullKey, FullRect>> = emptyList()
    private var heights: List<Float> = emptyList()
    private var atW = 0f
    private val typing = FullTyping().apply { mods = { Remote.sticky.held } }
    /** a finger's key, by index */
    private val fingers = HashMap<Int, Pair<Int, Int>>()
    private var nextID = 0
    private var ticking = false
    private val p = Paint(Paint.ANTI_ALIAS_FLAG)
    private val t = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        Remote.sticky.wait(this) { apply(typing.flush()) }
    }

    /** `w`: dp */
    fun arrange(w: Float, tier: FullTier, heights: List<Float>, host: RemoteHost) {
        if (w == atW && tier == this.tier && heights == this.heights && host == this.host && keys.isNotEmpty()) return
        if (host != this.host || tier != this.tier) letGo()
        atW = w
        this.tier = tier
        this.heights = heights
        this.host = host
        keys = FullKeys.place(FullKeys.rows(tier, host), FullRect(0f, 0f, w, FullKeys.height(heights)), tier, heights)
        invalidate()
        sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
    }

    private fun label(k: FullKey) =
        FullLabel.of(k, host, typing.fn, Remote.sticky.held and RemoteModifiers.SHIFT != 0, Remote.sticky.altGr, Remote.link.legends.value)

    private fun state(k: FullKey): Pair<Boolean, Boolean> {
        val s = Remote.sticky
        return when (val kind = k.kind) {
            is FullKind.Modifier -> { val l = (s.locked and kind.mods) == kind.mods; ((s.held and kind.mods) == kind.mods && !l) to l }
            FullKind.AltGr -> (s.altGr && !s.altGrLocked) to s.altGrLocked
            FullKind.Fn -> (typing.fn && !typing.fnLocked) to typing.fnLocked
            else -> false to false
        }
    }

    // MARK: how it looks

    override fun onDraw(canvas: Canvas) {
        val down = typing.pressed
        for ((k, r) in keys) {
            if (k.kind == FullKind.Talk) continue
            val l = r.left.dp
            val top = r.top.dp
            val right = r.right.dp
            val bottom = r.bottom.dp
            val (held, locked) = state(k)
            p.style = Paint.Style.FILL
            p.color = when { locked -> Theme.slabLatched; k in down -> Theme.slabPressed; k.name == "Return" -> Theme.slabStrong; else -> Theme.slab }
            canvas.drawRoundRect(l, top, right, bottom, 8.dp, 8.dp, p)
            p.style = Paint.Style.STROKE
            p.strokeWidth = if (held) 2.dp else 0.5f.dp
            p.color = if (held) Theme.slabLatched else Theme.edge
            val i = p.strokeWidth / 2
            canvas.drawRoundRect(l + i, top + i, right - i, bottom - i, 8.dp, 8.dp, p)
            val words = label(k)
            val w = right - l
            val h = bottom - top
            val ink = if (locked) Color.BLACK else if (words.faint) Theme.faint else Theme.mark
            val size = size(words.main, r)
            val second = words.second?.takeIf { r.height >= 34 }
            if (second == null) text(canvas, words.main, l + w / 2, top + h / 2, w - 4.dp, size, ink)
            else {
                val small = max(10f, min(13f, size * 0.6f))
                val ink2 = if (locked) Color.argb(153, 0, 0, 0) else Theme.caption
                if (r.width > r.height * 1.25f) {
                    text(canvas, words.main, l + w * 0.42f, top + h / 2, w * 0.4f, size, ink)
                    text(canvas, second, l + w * 0.74f, top + h / 2, w * 0.28f, small, ink2)
                } else {
                    text(canvas, second, l + w / 2, top + h * 0.26f, w - 2.dp, small, ink2)
                    text(canvas, words.main, l + w / 2, top + h * 0.66f, w - 2.dp, size, ink)
                }
            }
        }
    }

    private fun text(canvas: Canvas, s: String, x: Float, y: Float, room: Float, size: Float, ink: Int) {
        if (s.isEmpty()) return
        t.typeface = Fonts.text
        t.color = ink
        t.textSize = size.dp
        val w = t.measureText(s)
        if (w > room && w > 0) t.textSize = size.dp * max(0.5f, room / w)
        val fm = t.fontMetrics
        canvas.drawText(s, x, y - (fm.ascent + fm.descent) / 2, t)
    }

    private fun size(s: String, r: FullRect): Float {
        val most = min(22f, r.height * 0.5f)
        if (s == "⇥" || s.startsWith("↩")) return min(26f, r.height * 0.6f)
        return when { s.length <= 1 -> most; s.length <= 2 -> min(16f, most); s.length <= 4 -> min(14f, most); else -> min(12f, most) }
    }

    // MARK: touches

    /** The key under the finger (px), the gaps shared out between their neighbours. */
    private fun index(x: Float, y: Float): Int? {
        val d = resources.displayMetrics.density
        val px = x / d
        val py = y / d
        fun away(r: FullRect) = hypot(max(max(r.left - px, 0f), px - r.right), max(max(r.top - py, 0f), py - r.bottom))
        val i = keys.indices.minByOrNull { away(keys[it].second) } ?: return null
        return i.takeIf { away(keys[i].second) <= 8 && keys[i].first.kind != FullKind.Talk }
    }

    private fun inside(i: Int, x: Float, y: Float): Boolean {
        val d = resources.displayMetrics.density
        val r = keys.getOrNull(i)?.second ?: return false
        return x / d in r.left - 14..r.right + 14 && y / d in r.top - 14..r.bottom + 14
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        val now = SystemClock.uptimeMillis() / 1000.0
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                val n = e.actionIndex
                index(e.getX(n), e.getY(n))?.let { i ->
                    nextID += 1
                    fingers[e.getPointerId(n)] = nextID to i
                    apply(typing.began(nextID, keys[i].first, now))
                }
                onKey?.invoke()
                startTicks()
            }
            MotionEvent.ACTION_MOVE -> for (n in 0 until e.pointerCount) {
                val (id, i) = fingers[e.getPointerId(n)] ?: continue
                apply(typing.moved(id, inside(i, e.getX(n), e.getY(n))))
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP ->
                fingers.remove(e.getPointerId(e.actionIndex))?.let { (id, _) -> apply(typing.ended(id, now)) }
            MotionEvent.ACTION_CANCEL -> {
                for ((id, _) in fingers.values) apply(typing.cancelled(id))
                fingers.clear()
            }
        }
        invalidate()
        return true
    }

    private fun tapped(i: Int) {
        val k = keys.getOrNull(i) ?: return
        val now = SystemClock.uptimeMillis() / 1000.0
        nextID += 1
        apply(typing.began(nextID, k.first, now))
        apply(typing.ended(nextID, now + 0.05))
        invalidate()
    }

    fun letGo() {
        fingers.clear()
        apply(typing.letGo())
        invalidate()
    }

    private val tick = object : Runnable {
        override fun run() {
            val out = typing.tick(SystemClock.uptimeMillis() / 1000.0)
            if (out.isNotEmpty()) { apply(out); invalidate() }
            if (typing.needsTicks) postDelayed(this, 25) else ticking = false
        }
    }

    private fun startTicks() {
        if (ticking || !typing.needsTicks) return
        ticking = true
        postDelayed(tick, 25)
    }

    private fun apply(out: List<FullOutput>) {
        val l = Remote.link
        val s = Remote.sticky
        val now = SystemClock.uptimeMillis() / 1000.0
        for (o in out) when (o) {
            is FullOutput.Press -> l.send(ToMac.Key(if (o.name == FullTyping.INPUT_SOURCE) RemoteChord(RemoteModifiers.CONTROL, "Space") else RemoteChord(0, o.name), null))
            is FullOutput.Hold -> l.send(ToMac.Key(RemoteChord(0, o.name), o.down))
            is FullOutput.Again -> l.send(ToMac.Key(RemoteChord(0, o.name), true))
            is FullOutput.ModifierDown -> s.press(o.mods, now)
            is FullOutput.ModifierUp -> s.finish(o.mods, o.after, now, o.cancelled)
            FullOutput.AltGrDown -> s.pressAltGr(now)
            is FullOutput.AltGrUp -> s.finishAltGr(o.after, now, o.cancelled)
            FullOutput.Engage -> s.engage()
            is FullOutput.EngageWith -> s.engage(o.began)
            FullOutput.Used -> s.used()
            FullOutput.FnChanged -> {}
            FullOutput.Tick -> Haptics.tick()
            FullOutput.Grab -> Haptics.grab()
        }
    }

    // MARK: TalkBack: each key on its own

    private val provider = object : AccessibilityNodeProvider() {
        override fun createAccessibilityNodeInfo(id: Int): AccessibilityNodeInfo? {
            if (id == HOST_VIEW_ID) return AccessibilityNodeInfo.obtain(this@FullBoard).also { n ->
                onInitializeAccessibilityNodeInfo(n)
                keys.forEachIndexed { i, k -> if (k.first.kind != FullKind.Talk) n.addChild(this@FullBoard, i) }
            }
            val (k, r) = keys.getOrNull(id) ?: return null
            val words = label(k)
            val (held, locked) = state(k)
            val at = IntArray(2).also { getLocationOnScreen(it) }
            @Suppress("DEPRECATION")
            return AccessibilityNodeInfo.obtain(this@FullBoard, id).apply {
                packageName = context.packageName
                className = "android.widget.Button"
                contentDescription = words.spoken + when { locked -> ", " + context.getString(R.string.key_locked); held -> ", " + context.getString(R.string.key_held); else -> "" }
                setParent(this@FullBoard)
                val b = Rect(r.left.dp.toInt(), r.top.dp.toInt(), r.right.dp.toInt(), r.bottom.dp.toInt())
                setBoundsInParent(b)
                setBoundsInScreen(Rect(b).apply { offset(at[0], at[1]) })
                isEnabled = true
                isClickable = true
                isVisibleToUser = true
                addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_CLICK)
            }
        }

        override fun performAction(id: Int, action: Int, args: Bundle?): Boolean {
            if (id != HOST_VIEW_ID && action == AccessibilityNodeInfo.ACTION_CLICK) { tapped(id); return true }
            return id == HOST_VIEW_ID && this@FullBoard.performAccessibilityAction(action, args)
        }
    }

    override fun getAccessibilityNodeProvider(): AccessibilityNodeProvider = provider
}
