// The talk key is the computer's dictation key, in the corner by the thumb (port of Talk/TalkBar.swift). It behaves as the key does there:
// tap to start and tap to stop, hold to talk, double tap to send. Mint while it listens, the only mint on the screen.
package dev.blurt.remote.app.talk

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import dev.blurt.remote.app.Fonts
import dev.blurt.remote.app.Haptics
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import dev.blurt.remote.app.Theme
import dev.blurt.remote.app.dp
import dev.blurt.remote.app.keys.Icons
import dev.blurt.remote.core.RemoteDictationPhase
import dev.blurt.remote.core.ToMac

class TalkBar(c: Context) : View(c) {
    /** the microphone permission isn't there yet: ask, in context */
    var onAsk: (() -> Unit)? = null
    /** it was refused: say how to get it back, or use the computer's */
    var onDenied: (() -> Unit)? = null
    private var phase = RemoteDictationPhase.IDLE
    private var level = 0f
    private var down = false
    private val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private val rect = RectF()

    init {
        isClickable = true
        show(RemoteDictationPhase.IDLE)
    }

    fun show(ph: RemoteDictationPhase) {
        phase = ph
        if (ph != RemoteDictationPhase.LISTENING) level = 0f
        contentDescription = label()
        invalidate()
    }

    fun level(l: Float) {
        if (phase != RemoteDictationPhase.LISTENING) return
        level = l.coerceIn(0f, 1f)
        invalidate()
    }

    private fun label() = context.getString(when (phase) {
        RemoteDictationPhase.LISTENING -> R.string.talk_listening
        RemoteDictationPhase.TRANSCRIBING, RemoteDictationPhase.POLISHING -> R.string.talk_writing
        RemoteDictationPhase.UNAVAILABLE -> R.string.talk_off
        RemoteDictationPhase.IDLE -> R.string.talk
    })

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        val on = phase == RemoteDictationPhase.LISTENING
        rect.set(0f, 0f, w, h)
        val r = Theme.KEY_RADIUS.dp
        p.shader = null
        p.color = if (on) Theme.mint else if (down) Theme.slabPressed else Theme.talkRest
        canvas.drawRoundRect(rect, r, r, p)
        if (on && level > 0) {
            // the level moves the fill a little, from the middle outward, so a glance says the mic hears you
            val lw = w * level
            p.shader = LinearGradient((w - lw) / 2, 0f, (w + lw) / 2, 0f, intArrayOf(Color.TRANSPARENT, Color.argb(115, 255, 255, 255), Color.TRANSPARENT), null, Shader.TileMode.CLAMP)
            canvas.drawRect((w - lw) / 2, 0f, (w + lw) / 2, h, p)
            p.shader = null
        }
        // the mic and its word together in the middle, as on the keys beside it
        val top = (h - 37.dp) / 2
        val writing = phase == RemoteDictationPhase.TRANSCRIBING || phase == RemoteDictationPhase.POLISHING
        if (writing) {
            p.style = Paint.Style.STROKE
            p.strokeWidth = 2.dp
            p.strokeCap = Paint.Cap.ROUND
            p.color = Theme.mark
            val cx = w / 2
            val cy = top + 12.dp
            val a = (SystemClock.uptimeMillis() % 900) / 900f * 360f
            canvas.drawArc(cx - 8.dp, cy - 8.dp, cx + 8.dp, cy + 8.dp, a, 270f, false, p)
            p.style = Paint.Style.FILL
            postInvalidateOnAnimation()
        } else {
            p.typeface = Fonts.symbolsFilled(context)
            p.textSize = 22.dp
            p.color = if (on) Theme.onMint else Theme.mint
            val fm = p.fontMetrics
            canvas.drawText(Icons.char("mic"), w / 2, top + 12.dp - (fm.ascent + fm.descent) / 2, p)
        }
        p.typeface = Fonts.medium
        p.textSize = 10.dp
        p.color = when {
            on -> Theme.onMint
            phase == RemoteDictationPhase.UNAVAILABLE -> Theme.faint
            else -> Theme.mark
        }
        val text = label()
        var size = 10.dp
        while (p.measureText(text) > w - 4.dp && size > 7.dp) { size *= 0.93f; p.textSize = size }
        val fm = p.fontMetrics
        canvas.drawText(text, w / 2, top + 24.dp + 6.5f.dp - (fm.ascent + fm.descent) / 2, p)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> pressed()
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> up()
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        pressed()
        up()
        return true
    }

    private fun pressed() {
        down = true
        invalidate()
        Haptics.grab()
        val mic = Remote.mic
        if (Remote.prefs.micOnPhone) {
            if (!mic.granted) {
                // the system's question takes the touch away: the first press asks, the next one talks
                down = false
                invalidate()
                onAsk?.invoke()
                return
            }
            if (!mic.start()) {
                down = false
                invalidate()
                Remote.link.send(ToMac.Hud(context.getString(R.string.mic_unavailable)))
                return
            }
        }
        Remote.link.send(ToMac.DictationKey(true))
    }

    private fun up() {
        if (!down) return
        down = false
        invalidate()
        Haptics.release()
        Remote.link.send(ToMac.DictationKey(false))
        Remote.mic.released()
    }

    /** Taken away mid-press (the app left the screen): the key comes up. */
    fun letGo() = up()
}
