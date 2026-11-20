// The pad's one card for a connection that isn't simply there: connecting, coming back, can't be reached, needs pairing, taken by another
// phone, can't control (core/LinkStatus.kt has which state says what; the iPhone's is Pad/StatusCard.swift). It sits in the middle of the
// pad, where the thumb and the eye already are, at reading size: this is read at arm's length from a sofa, and a 12 sp line in the corner
// wasn't (the founder, 2026-11-16).
//
// A slab like the keys, so the words keep their contrast over the computer's picture too: the strong line is white 90 % on it (13 : 1),
// the second line white 78 % (10 : 1), the mark amber (8 : 1) and never alone, its shape says it too. The text follows the system's font
// size up to one and a half times, where the card still fits a phone's pad.
package dev.blurt.remote.app.pad

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.CornerPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.LinearLayout
import android.widget.TextView
import dev.blurt.remote.app.Fonts
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Theme
import dev.blurt.remote.app.dp
import dev.blurt.remote.app.keys.Icons
import dev.blurt.remote.core.LinkPath
import dev.blurt.remote.core.RemoteHost
import dev.blurt.remote.app.net.PairFailure
import dev.blurt.remote.core.StatusAction
import dev.blurt.remote.core.StatusLine
import dev.blurt.remote.core.StatusMark
import kotlin.math.min

@SuppressLint("ViewConstructor")
class StatusCard(c: Context, onAction: () -> Unit, onSecond: () -> Unit) : LinearLayout(c) {
    data class Words(val title: String, val detail: String? = null, val action: String? = null, val second: String? = null)

    private val mark = MarkView(c)
    private val title = TextView(c)
    private val detail = TextView(c)
    private val action = TextView(c)
    private val second = TextView(c)
    var words: Words? = null
        private set

    init {
        orientation = VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        val p = 20.dp.toInt()
        setPadding(p, p, p, p)
        background = GradientDrawable().apply {
            setColor(Theme.slab)
            cornerRadius = Theme.RADIUS.dp
            setStroke(1.dp.toInt(), Theme.edge)
        }
        visibility = GONE
        // TalkBack says the card when it changes
        accessibilityLiveRegion = ACCESSIBILITY_LIVE_REGION_POLITE

        mark.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        addView(mark, LayoutParams(30.dp.toInt(), 30.dp.toInt()))

        title.apply { setTextColor(Theme.mark); typeface = Fonts.medium; gravity = Gravity.CENTER }
        addView(title, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = 10.dp.toInt() })
        detail.apply { setTextColor(Color.argb(199, 255, 255, 255)); typeface = Fonts.text; gravity = Gravity.CENTER; setLineSpacing(0f, 1.15f) }
        addView(detail, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = 6.dp.toInt() })

        action.apply {
            setTextColor(Color.BLACK)
            typeface = Fonts.medium
            gravity = Gravity.CENTER
            minHeight = 46.dp.toInt()
            minWidth = 168.dp.toInt()
            setPadding(28.dp.toInt(), 10.dp.toInt(), 28.dp.toInt(), 10.dp.toInt())
            background = GradientDrawable().apply {
                color = ColorStateList(arrayOf(intArrayOf(android.R.attr.state_pressed), intArrayOf()), intArrayOf(Color.WHITE, Theme.slabLatched))
                cornerRadius = 100.dp
            }
            button(this)
            setOnClickListener { onAction() }
        }
        addView(action, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = 16.dp.toInt() })
        second.apply {
            setTextColor(ColorStateList(arrayOf(intArrayOf(android.R.attr.state_pressed), intArrayOf()), intArrayOf(Theme.caption, Theme.mark)))
            typeface = Fonts.medium
            gravity = Gravity.CENTER
            minHeight = 48.dp.toInt()
            setPadding(16.dp.toInt(), 10.dp.toInt(), 16.dp.toInt(), 10.dp.toInt())
            button(this)
            setOnClickListener { onSecond() }
        }
        addView(second, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = 2.dp.toInt() })
        sizes()
    }

    /** a line of text that acts: TalkBack calls it a button */
    private fun button(v: TextView) {
        v.isClickable = true
        v.isFocusable = true
        v.accessibilityDelegate = object : AccessibilityDelegate() {
            override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfo) {
                super.onInitializeAccessibilityNodeInfo(host, info)
                info.className = android.widget.Button::class.java.name
            }
        }
    }

    /** Reading size (17 and 15, as on the iPhone), growing with the system's font size up to one and a half times. */
    private fun sizes() {
        val scale = min(resources.configuration.fontScale, MAX_SCALE)
        title.setTextSize(TypedValue.COMPLEX_UNIT_DIP, TITLE_SIZE * scale)
        detail.setTextSize(TypedValue.COMPLEX_UNIT_DIP, DETAIL_SIZE * scale)
        action.setTextSize(TypedValue.COMPLEX_UNIT_DIP, 16f * scale)
        second.setTextSize(TypedValue.COMPLEX_UNIT_DIP, 15f * scale)
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        sizes()
    }

    /** null: nothing to say, the card goes. True when what it says has changed. */
    fun show(m: StatusMark?, w: Words?): Boolean {
        val changed = w != words
        words = w
        if (w == null || m == null) {
            animate().cancel()
            visibility = GONE
            return changed
        }
        mark.mark = m
        title.text = w.title
        detail.text = w.detail
        detail.visibility = if (w.detail == null) GONE else VISIBLE
        action.text = w.action
        action.visibility = if (w.action == null) GONE else VISIBLE
        second.text = w.second
        second.visibility = if (w.second == null) GONE else VISIBLE
        if (visibility != VISIBLE) {
            visibility = VISIBLE
            alpha = 0f
            animate().alpha(1f).setDuration(180).start()
        }
        return changed
    }

    companion object {
        const val MAX_WIDTH = 340f
        const val TITLE_SIZE = 17f
        const val DETAIL_SIZE = 15f
        const val MAX_SCALE = 1.5f

        /** The card's lines in words. `name`: the computer in hand; `check`: the digits a pairing shows on both; `failed`: Link's sentences
         *  for a pairing that didn't take (what went wrong, then what to do). */
        fun text(c: Context, line: StatusLine, host: RemoteHost, name: String?, check: String? = null, failed: PairFailure? = null): String {
            val n = name?.takeIf { it.isNotEmpty() } ?: c.getString(R.string.the_computer)
            return when (line) {
                StatusLine.CONNECTING -> c.getString(R.string.connecting_to, n)
                StatusLine.RECONNECTING -> c.getString(R.string.status_reconnecting, n)
                StatusLine.CANT_REACH -> c.getString(R.string.status_cant_reach, n)
                StatusLine.CHECK_NETWORK -> c.getString(R.string.status_check_network)
                StatusLine.CHECK_AWAKE -> c.getString(R.string.status_check_awake)
                StatusLine.NEEDS_PAIRING -> c.getString(R.string.s_forgotten)
                StatusLine.FORGOTTEN -> c.getString(R.string.status_forgotten, n)
                StatusLine.OTHER_PHONE -> c.getString(R.string.status_other_phone)
                StatusLine.TOUCH_TO_TAKE_OVER -> c.getString(R.string.status_take_over)
                StatusLine.ENDED_THERE -> c.getString(R.string.status_ended)
                StatusLine.TOUCH_TO_RECONNECT -> c.getString(R.string.status_reconnect)
                StatusLine.PAIR_FIRST -> c.getString(R.string.status_pair_first)
                StatusLine.WHERE_THE_CODE_IS -> c.getString(R.string.status_unpaired)
                StatusLine.WAITING -> c.getString(R.string.status_waiting_title)
                StatusLine.ALLOW_ON_COMPUTER -> c.getString(R.string.status_waiting, check ?: "")
                StatusLine.PAIRING_FAILED -> failed?.title ?: c.getString(R.string.status_pair_failed)
                StatusLine.WHY_PAIRING_FAILED -> failed?.help ?: ""
                StatusLine.CANT_CONTROL -> c.getString(R.string.status_cant_control, n)
                StatusLine.HOW_TO_ALLOW_CONTROL -> c.getString(if (host == RemoteHost.MAC) R.string.status_accessibility else R.string.status_control)
                StatusLine.CANT_SHOW_SCREEN -> c.getString(R.string.status_cant_show_screen)
                StatusLine.ALLOW_SCREEN -> c.getString(if (host == RemoteHost.MAC) R.string.status_screen_permission else R.string.status_screen_permission_pc)
                StatusLine.SCREEN_IS_OFF -> c.getString(R.string.status_screen_off)
                StatusLine.NO_DIRECT -> c.getString(R.string.status_no_direct)
                StatusLine.GO_BETWEEN_BUSY -> c.getString(R.string.status_go_between_busy)
                StatusLine.RELAY_DOWN -> c.getString(R.string.status_relay_down)
            }
        }

        fun text(c: Context, a: StatusAction): String = c.getString(when (a) {
            StatusAction.RETRY -> R.string.retry
            StatusAction.SCAN -> R.string.scan_code
            StatusAction.ANOTHER -> R.string.try_another
        })
    }
}

/** The way a session runs, as the connection label names it (remote-go-between.md §What each end shows). */
fun pathName(c: Context, p: LinkPath): String = c.getString(when (p) {
    LinkPath.SAME_NETWORK -> R.string.path_same_network
    LinkPath.TAILSCALE -> R.string.path_tailscale
    LinkPath.OVERLAY -> R.string.path_overlay
    LinkPath.DIRECT -> R.string.path_direct
    LinkPath.OWN_RELAY -> R.string.path_own_relay
    LinkPath.GO_BETWEEN -> R.string.path_go_between
})

/**
 * The mark above the words. The triangle and the phone are drawn here: the app's icon font is cut down to the keys' own symbols. Busy is
 * three quarters of a ring going round at one steady turn a second: the system's own spinner shrinks to a dot on every turn, which at a
 * glance reads as nothing happening.
 */
private class MarkView(c: Context) : View(c) {
    var mark = StatusMark.PROBLEM
        set(v) { field = v; invalidate() }
    private val p = Paint(Paint.ANTI_ALIAS_FLAG)
    private val path = Path()
    private val r = RectF()
    /** the triangle's corners, rounded: made when the size is known, not at every draw */
    private var corner: CornerPathEffect? = null

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        corner = CornerPathEffect(w / 10f)
    }

    override fun onDraw(canvas: Canvas) {
        val u = width / 30f
        p.pathEffect = null
        p.typeface = null
        when (mark) {
            StatusMark.PROBLEM -> {
                path.rewind()
                path.moveTo(15 * u, 3.5f * u); path.lineTo(28 * u, 26 * u); path.lineTo(2 * u, 26 * u); path.close()
                p.style = Paint.Style.FILL
                p.color = Theme.attn
                p.pathEffect = corner
                canvas.drawPath(path, p)
                p.pathEffect = null
                p.color = Theme.slab
                p.strokeWidth = 2.6f * u
                p.strokeCap = Paint.Cap.ROUND
                p.style = Paint.Style.STROKE
                canvas.drawLine(15 * u, 11.5f * u, 15 * u, 18 * u, p)
                p.style = Paint.Style.FILL
                canvas.drawCircle(15 * u, 22.2f * u, 1.6f * u, p)
            }
            StatusMark.PHONE -> {
                p.style = Paint.Style.STROKE
                p.strokeWidth = 2.2f * u
                p.color = Theme.mark
                r.set(8 * u, 2.5f * u, 22 * u, 27.5f * u)
                canvas.drawRoundRect(r, 3.5f * u, 3.5f * u, p)
                p.strokeCap = Paint.Cap.ROUND
                canvas.drawLine(13 * u, 6.5f * u, 17 * u, 6.5f * u, p)
            }
            StatusMark.CODE -> {
                p.style = Paint.Style.FILL
                p.color = Theme.mark
                p.typeface = Fonts.symbols(context)
                p.textAlign = Paint.Align.CENTER
                p.textSize = 28 * u
                val fm = p.fontMetrics
                canvas.drawText(Icons.char("qr_code_scanner"), width / 2f, height / 2f - (fm.ascent + fm.descent) / 2, p)
            }
            StatusMark.BUSY -> {
                p.style = Paint.Style.STROKE
                p.strokeWidth = 2.6f * u
                p.strokeCap = Paint.Cap.ROUND
                p.color = Theme.mark
                r.set(4 * u, 4 * u, 26 * u, 26 * u)
                // with the system's animations off it stands still, and the words say the rest
                val moving = ValueAnimator.areAnimatorsEnabled()
                canvas.drawArc(r, if (moving) (SystemClock.uptimeMillis() % 1000) * 0.36f else -90f, 270f, false, p)
                if (moving && isShown) postInvalidateOnAnimation()
            }
        }
    }
}
