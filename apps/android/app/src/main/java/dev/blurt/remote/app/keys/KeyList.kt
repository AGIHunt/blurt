// The keys as pages of one list, like the emoji keyboard (port of Keys/KeyList.swift): one section after another, each coming to rest at its
// top, so a key has the same place each time. The tabs jump to the sections and follow the list. A section that outgrows the view scrolls a
// row at a time; one shorter than the view is followed straight away by the next, never by a blank. Keys here are ordinary KeyCells; what's
// special is who gets a touch: a key that has acted keeps it, any other gives way to the scroll (KeyCell.givesWay).
package dev.blurt.remote.app.keys

import android.annotation.SuppressLint
import android.content.Context
import android.view.Gravity
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.animation.DecelerateInterpolator
import android.widget.OverScroller
import android.widget.TextView
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Theme
import dev.blurt.remote.core.KeySection
import dev.blurt.remote.core.RemoteHost
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class KeyList(c: Context) : ViewGroup(c) {
    val cells = mutableListOf<KeyCell>()
    private var sections: List<KeySection> = emptyList()
    private var sectionTops = mutableListOf<Int>()
    private var rowTops = mutableListOf<Int>()
    private val editButton = TextView(c).apply {
        text = c.getString(R.string.edit_keys)
        setTextColor(Theme.caption)
        textSize = 14f
        gravity = Gravity.CENTER
        setOnClickListener { onEdit?.invoke() }
    }
    private var keyW = 0f
    private var keyH = 0f
    private var gap = 0f
    private var tallest: Float? = null
    private var contentHeight = 0
    private var frames = listOf<IntArray>()
    var onSection: ((Int) -> Unit)? = null
    var onEdit: (() -> Unit)? = null
    var onCycle: ((Boolean, KeyCell) -> Unit)? = null
    var section = 0
        private set
    var host = RemoteHost.MAC
        set(v) { field = v; cells.forEach { it.host = v } }

    private val scroller = OverScroller(c, DecelerateInterpolator(1.6f))
    private val slop = ViewConfiguration.get(c).scaledTouchSlop
    private var velocity: VelocityTracker? = null
    private var downY = 0f
    private var lastY = 0f
    private var dragging = false
    private var scrollEnabled = true

    init {
        addView(editButton)
        clipChildren = true
        isMotionEventSplittingEnabled = true
    }

    fun show(list: List<KeySection>) {
        if (list == sections) return
        sections = list
        section = min(section, max(0, list.size - 1))
        cells.forEach { removeView(it) }
        cells.clear()
        for (s in list) for (slot in s.slots) {
            val k = KeyCell(context)
            k.inList = true
            k.host = host
            k.slot = slot
            k.onCycle = { on -> cycling(on, k) }
            addView(k)
            cells += k
        }
        keyW = 0f
        requestLayout()
    }

    private fun cycling(on: Boolean, k: KeyCell) {
        scrollEnabled = !on
        onCycle?.invoke(on, k)
    }

    /** Key sizes come from PadLayout, so every page has the same rows. A section can ask for more across (the letters, the size of a phone's
     *  own). `tallest`: in landscape, no key taller than this times its width. */
    fun arrange(w: Float, h: Float, gap: Float, tallest: Float?) {
        if (w == keyW && h == keyH && gap == this.gap && tallest == this.tallest) return
        keyW = w
        keyH = h
        this.gap = gap
        this.tallest = tallest
        requestLayout()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), MeasureSpec.getSize(heightMeasureSpec))
        compute()
        for ((i, k) in cells.withIndex()) {
            val f = frames.getOrNull(i) ?: continue
            k.measure(MeasureSpec.makeMeasureSpec(f[2], MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(f[3], MeasureSpec.EXACTLY))
        }
        editButton.measure(MeasureSpec.makeMeasureSpec(measuredWidth, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec((44 * resources.displayMetrics.density).toInt(), MeasureSpec.EXACTLY))
    }

    private fun compute() {
        val width = measuredWidth.toFloat()
        if (keyW <= 0 || width <= 0) { frames = emptyList(); return }
        val page = max(keyH, measuredHeight.toFloat())
        var y = 0f
        var n = 0
        sectionTops = mutableListOf()
        rowTops = mutableListOf()
        val out = ArrayList<IntArray>(cells.size)
        for (s in sections) {
            val top = y
            sectionTops += top.roundToInt()
            rowTops += top.roundToInt()
            val across = max(1, s.columns)
            val w = (width - gap * (across - 1)) / across
            val h = tallest?.let { min(keyH, floor(w * it)) } ?: keyH
            var column = 0
            val rows = mutableListOf<Int>()
            for (slot in s.slots) {
                val span = min(across, max(1, slot.span ?: 1))
                if (column + span > across) { column = 0; y += h + gap }
                if (column == 0 && y > top) rows += y.roundToInt()
                val x = column * (w + gap)
                out += intArrayOf(x.roundToInt(), y.roundToInt(), (w * span + gap * (span - 1)).roundToInt(), h.roundToInt())
                n += 1
                column += span
            }
            if (s.slots.isNotEmpty()) y += h + gap
            // a section longer than the view: every row of it is a stop, so it scrolls a row at a time
            if (y - gap - top > page) rowTops += rows
            y = max(y, top + gap)
        }
        frames = out
        val editY = y.roundToInt()
        out.add(intArrayOf(0, editY, width.roundToInt(), (44 * resources.displayMetrics.density).roundToInt()))
        y += 44 * resources.displayMetrics.density
        // every section can come to the top
        val last = sectionTops.lastOrNull() ?: 0
        contentHeight = max(y.roundToInt(), last + measuredHeight)
        // turned the phone, or opened the keys: keys changed size, and the same section stays in view
        sectionTops.getOrNull(section)?.let { scrollTo(0, min(it, maxScroll())) }
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        for ((i, k) in cells.withIndex()) {
            val f = frames.getOrNull(i) ?: continue
            k.layout(f[0], f[1], f[0] + f[2], f[1] + f[3])
        }
        frames.lastOrNull()?.takeIf { frames.size == cells.size + 1 }?.let { editButton.layout(it[0], it[1], it[0] + it[2], it[1] + it[3]) }
    }

    private fun maxScroll() = max(0, contentHeight - height.coerceAtLeast(measuredHeight))

    fun scrollToSection(i: Int) {
        val top = sectionTops.getOrNull(i) ?: return
        scroller.forceFinished(true)
        val target = min(top, maxScroll())
        scroller.startScroll(0, scrollY, 0, target - scrollY, 260)
        postInvalidateOnAnimation()
    }

    override fun computeScroll() {
        if (scroller.computeScrollOffset()) {
            scrollTo(0, scroller.currY)
            postInvalidateOnAnimation()
        }
    }

    override fun onScrollChanged(l: Int, t: Int, oldl: Int, oldt: Int) {
        super.onScrollChanged(l, t, oldl, oldt)
        // the section at the top of the list; the last ones may never reach it, so the bottom counts too
        val y = scrollY + 1
        var now = sectionTops.indexOfLast { it <= y }.coerceAtLeast(0)
        if (scrollY >= maxScroll() - 1 && sectionTops.isNotEmpty()) now = max(now, sectionTops.size - 1)
        if (now != section) {
            section = now
            onSection?.invoke(now)
        }
    }

    private fun cellAt(x: Float, y: Float): KeyCell? {
        val cy = y + scrollY
        return cells.firstOrNull { x >= it.left && x < it.right && cy >= it.top && cy < it.bottom }
    }

    private var downCell: KeyCell? = null

    override fun onInterceptTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downY = e.y
                lastY = e.y
                dragging = false
                downCell = cellAt(e.x, e.y)
                if (!scroller.isFinished) {
                    // a touch on a list still moving stops it, and is only that
                    scroller.forceFinished(true)
                    dragging = true
                    startVelocity(e)
                    return true
                }
                startVelocity(e)
            }
            MotionEvent.ACTION_MOVE -> {
                velocity?.addMovement(e)
                if (!scrollEnabled) return false
                if (abs(e.y - downY) > slop && (downCell?.givesWay != false)) {
                    dragging = true
                    lastY = e.y
                    parent?.requestDisallowInterceptTouchEvent(true)
                    return true
                }
            }
        }
        return false
    }

    private fun startVelocity(e: MotionEvent) {
        velocity?.recycle()
        velocity = VelocityTracker.obtain().apply { addMovement(e) }
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        velocity?.addMovement(e)
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> return true
            MotionEvent.ACTION_MOVE -> {
                if (!dragging) {
                    if (abs(e.y - downY) <= slop) return true
                    dragging = true
                    lastY = e.y
                }
                val dy = (lastY - e.y).toInt()
                lastY = e.y
                // a little give past either end, as any list has
                val y = scrollY + dy
                val over = if (y < 0) -y else if (y > maxScroll()) y - maxScroll() else 0
                scrollTo(0, scrollY + if (over > 0) dy / 3 else dy)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                velocity?.computeCurrentVelocity(1000)
                val v = velocity?.yVelocity ?: 0f
                velocity?.recycle()
                velocity = null
                dragging = false
                settle(v)
            }
        }
        return true
    }

    /** Comes to rest on a section's top or a row of a long one, the nearest to where the throw would have taken it. */
    private fun settle(v: Float) {
        val limit = maxScroll()
        val projected = (scrollY - v * 0.22f).roundToInt().coerceIn(0, limit)
        val target = if (projected >= limit - 1) limit
            else (rowTops.minByOrNull { abs(it - projected) } ?: projected).coerceIn(0, limit)
        scroller.forceFinished(true)
        scroller.startScroll(0, scrollY, 0, target - scrollY, (180 + abs(target - scrollY) / 4).coerceAtMost(420))
        postInvalidateOnAnimation()
    }
}
