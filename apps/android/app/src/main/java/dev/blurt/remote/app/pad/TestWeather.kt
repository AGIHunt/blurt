// A made-up bad network for measured runs, debug builds only (iOS: Pad/TestWeather.swift; docs/design/remote-realtime.md §Phone). Set by
// extras on the launch intent, so a script can run the same stream through several kinds of weather:
//
//   adb shell am start -n dev.blurt.remote/.app.MainActivity --es blurt_test_loss 0.03:3 --es blurt_test_stall 80:2 \
//       --es blurt_screen_repair 0 --ei blurt_screen_test 12
//
//   blurt_test_loss      rate[:mean burst]   pieces dropped as they arrive, in bursts as Wi-Fi loses them
//   blurt_test_stall     ms:seconds          everything held that long, that often, as a dozing radio or a busy channel does
//   blurt_screen_repair  0                   offer no repairs (the "before" of a measurement)
//   blurt_screen_test    seconds             once connected, show the screen, wait 3 s, then measure this long and log a report
//                                            (logcat tag BlurtScreenTest; also sent to the computer as screenStats)
package dev.blurt.remote.app.pad

import android.content.Intent
import dev.blurt.remote.app.BuildConfig
import java.util.Random

class TestWeather(private val rate: Double = 0.0, burst: Double = 1.0, private val stall: Double = 0.0, private val every: Double = 1.0) {
    private val burst = maxOf(1.0, burst)
    private var bad = false
    private var stallStart = Double.NEGATIVE_INFINITY
    private var nextStall = 0.0
    private val rng = Random()
    var dropped = 0
        private set

    val calm: Boolean get() = rate <= 0 && stall <= 0

    /** True: it arrives now. False: dropped, or held (`later` is called with the delay in seconds, and it arrives then). */
    fun passes(now: Double, later: (Double) -> Unit): Boolean {
        if (stall > 0) {
            if (nextStall == 0.0) nextStall = now + every
            if (now >= nextStall) {
                stallStart = nextStall
                nextStall += every
            }
            if (now < stallStart + stall) {
                later(stallStart + stall - now)
                return false
            }
        }
        if (rate <= 0) return true
        // two states: in a bad run every piece is lost; a run ends with 1/burst, and starts so that the average loss is `rate`
        val end = 1 / burst
        val start = rate * end / maxOf(1e-9, 1 - rate)
        bad = if (bad) rng.nextDouble() >= end else rng.nextDouble() < start
        if (bad) dropped += 1
        return !bad
    }

    companion object {
        /** debug builds only; calm otherwise */
        @Volatile var current = TestWeather()
            private set
        /** false: offer no repairs */
        @Volatile var repairs = true
            private set
        /** seconds to measure once connected; 0 = no measured run */
        @Volatile var screenTest = 0

        fun from(i: Intent?) {
            if (!BuildConfig.DEBUG || i == null) return
            fun nums(k: String) = i.getStringExtra(k)?.split(":")?.mapNotNull { it.toDoubleOrNull() } ?: emptyList()
            val l = nums("blurt_test_loss")
            val s = nums("blurt_test_stall")
            if (i.hasExtra("blurt_test_loss") || i.hasExtra("blurt_test_stall")) {
                current = TestWeather(l.getOrElse(0) { 0.0 }, l.getOrElse(1) { 1.0 }, s.getOrElse(0) { 0.0 } / 1000, s.getOrElse(1) { 1.0 })
            }
            i.getStringExtra("blurt_screen_repair")?.let { repairs = it != "0" }
            if (i.hasExtra("blurt_screen_test")) screenTest = i.getIntExtra("blurt_screen_test", 0)
        }
    }
}
