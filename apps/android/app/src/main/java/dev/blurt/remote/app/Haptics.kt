// The phone taps back, so a thumb knows what happened without looking (App/Haptics.swift). The four kinds the iPhone uses: a key fired, a step
// of a cycle or an arrow, took hold of something, let go. Through the view's own haptics, which follow the system's touch-feedback setting and
// need no permission; Android 11+ has the constants that feel like the iPhone's.
package dev.blurt.remote.app

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View

object Haptics {
    /** the window's root: haptics go through whatever view is on screen */
    var view: View? = null
    var on = true

    private fun play(c: Int) {
        if (!on) return
        view?.performHapticFeedback(c)
    }

    /** a key fired, a click */
    fun tick() = play(HapticFeedbackConstants.KEYBOARD_TAP)

    /** a step of a cycle, an arrow */
    fun step() = play(if (Build.VERSION.SDK_INT >= 34) HapticFeedbackConstants.SEGMENT_FREQUENT_TICK else HapticFeedbackConstants.CLOCK_TICK)

    /** took hold of something: a drag, a latch */
    fun grab() = play(if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.GESTURE_START else HapticFeedbackConstants.LONG_PRESS)

    fun release() = play(if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.GESTURE_END else HapticFeedbackConstants.VIRTUAL_KEY_RELEASE)
}
