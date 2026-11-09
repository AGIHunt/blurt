package dev.blurt.remote.app

import dev.blurt.remote.app.pad.TestWeather
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The made-up network the measured runs use (remote-realtime.md §Android): it loses what it says, in the bursts it says, and holds
 *  everything during a stall. */
class TestWeatherTest {
    @Test fun lossAndBurstsAreWhatWereAskedFor() {
        val w = TestWeather(rate = 0.03, burst = 3.0)
        var runs = 0
        var lostBefore = false
        val n = 200_000
        repeat(n) {
            val lost = !w.passes(0.0) { }
            if (lost && !lostBefore) runs++
            lostBefore = lost
        }
        assertEquals(0.03, w.dropped.toDouble() / n, 0.004)
        assertEquals(3.0, w.dropped.toDouble() / runs, 0.3)
    }

    @Test fun aStallHoldsEverythingThenLetsItGo() {
        val w = TestWeather(stall = 0.08, every = 2.0)
        var held = 0.0
        assertTrue(w.passes(0.0) { })                      // the first stall is due 2 s in
        assertTrue(!w.passes(2.01) { held = it })
        assertEquals(0.07, held, 1e-9)
        assertTrue(w.passes(2.09) { })
        assertTrue(!w.passes(4.0) { })
        assertTrue(w.calm.not())
        assertTrue(TestWeather().calm)
    }
}
