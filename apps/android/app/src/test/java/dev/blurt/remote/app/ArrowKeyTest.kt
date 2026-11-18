package dev.blurt.remote.app

import dev.blurt.remote.app.keys.ArrowStroke
import dev.blurt.remote.app.pad.Frame
import dev.blurt.remote.app.pad.PadLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.ceil
import kotlin.math.hypot
import kotlin.math.max

/** The arrow key: what a touch sends (ArrowStroke), and how big it is where (PadLayout). Mirrors ArrowKeyTests.swift. */
class ArrowKeyTest {
    /** A drag from (x, y) through `points`, fed 2 dp at a time: every key it sends, in order (a repeat counts once each time it starts). */
    private fun drag(x: Float, y: Float, vararg points: Pair<Float, Float>): List<String> {
        val s = ArrowStroke(x, y)
        val out = mutableListOf<String>()
        var repeating: String? = null
        var ax = x
        var ay = y
        for ((tx, ty) in points) {
            val n = max(1, ceil(hypot(tx - ax, ty - ay) / 2).toInt())
            for (i in 1..n) {
                val t = i.toFloat() / n
                when (val m = s.move(ax + (tx - ax) * t, ay + (ty - ay) * t)) {
                    is ArrowStroke.Move.Step -> { out += m.key; repeating = null }
                    is ArrowStroke.Move.Repeating -> if (repeating != m.key) { out += "repeat " + m.key; repeating = m.key }
                    ArrowStroke.Move.None -> repeating = null
                }
            }
            ax = tx; ay = ty
        }
        return out
    }

    @Test fun aSlideRightWithDriftDownSendsOnlyRights() {
        val path = (1..20).map { val x = it * 10f; x to 30f * x / 200f }.toTypedArray()
        val keys = drag(0f, 0f, *path)
        assertTrue(keys.isNotEmpty())
        assertTrue(keys.toString(), keys.all { it.endsWith("Right") })
        assertEquals("repeat Right", keys.last())
    }

    @Test fun aThumbsArcStaysRight() {
        assertEquals(listOf("Right", "Right"), drag(0f, 0f, 20f to 10f, 40f to 20f, 60f to 28f, 70f to 30f))
    }

    @Test fun aClearTurnGoesTheNewWay() {
        assertEquals(listOf("Right", "Right", "Down", "Down"), drag(0f, 0f, 50f to 0f, 50f to 60f))
        assertEquals(listOf("Down", "Down", "Up", "Up"), drag(0f, 0f, 0f to 50f, 0f to 0f))
    }

    @Test fun driftDoesntFlipTheFarRepeat() {
        val keys = drag(0f, 0f, 100f to 0f, 160f to 40f)
        assertTrue(keys.toString(), keys.all { it.endsWith("Right") })
    }

    @Test fun aFarTurnStartsAgainFromTheTurn() {
        val keys = drag(0f, 0f, 100f to 0f, 100f to 60f)
        assertEquals(listOf("Right", "Right", "Right", "repeat Right", "Down", "Down"), keys)
    }

    @Test fun theScreenEdgeRepeats() {
        val s = ArrowStroke(0f, 0f)
        assertEquals(ArrowStroke.Move.Step("Right"), s.move(24f, 0f))
        assertTrue(s.move(30f, 0f, screenEdge = 1) is ArrowStroke.Move.Repeating)
        assertEquals(ArrowStroke.Move.None, s.move(32f, 0f, screenEdge = -1))
    }

    @Test fun theMiddleIsNobodys() {
        assertNull(ArrowStroke.tapKey(44f, 44f, 88f, 88f))
        assertNull(ArrowStroke.tapKey(52f, 37f, 88f, 88f))
        assertNull(ArrowStroke.tapKey(45f, 27f, 82f, 50f))
        assertEquals(listOf("Down", "Down"), drag(44f, 44f, 44f to 94f))
    }

    @Test fun edgesTapTheirArrow() {
        for ((w, h) in listOf(82f to 50f, 88f to 88f, 56f to 74f)) {
            assertEquals("Up", ArrowStroke.tapKey(w / 2, 4f, w, h))
            assertEquals("Down", ArrowStroke.tapKey(w / 2, h - 4, w, h))
            assertEquals("Left", ArrowStroke.tapKey(4f, h / 2, w, h))
            assertEquals("Right", ArrowStroke.tapKey(w - 4, h / 2, w, h))
            assertEquals("Up", ArrowStroke.tapKey(w / 2, h * 0.37f, w, h))
        }
    }

    @Test fun tapThenDragAddsShift() {
        assertTrue(ArrowStroke.shifted(10.2, 10.0))
        assertFalse(ArrowStroke.shifted(10.5, 10.0))
        assertFalse(ArrowStroke.shifted(10.1, 0.0))
    }

    // size

    private fun noOverlap(r: List<Frame>) {
        for (i in r.indices) for (j in i + 1 until r.size) assertFalse("${r[i]} ${r[j]}", r[i].intersects(r[j]))
    }

    @Test fun bigScreensGiveEveryEdge44() {
        for ((w, h) in listOf(1280f to 800f, 800f to 1280f, 1024f to 768f)) for (lefty in listOf(false, true)) for (displays in listOf(false, true)) {
            val l = PadLayout(w, h, 0f, 0f, 0f, 0f, lefty = lefty, drawerOpen = true, displays = displays)
            val a = l.arrowKey
            assertTrue("$w×$h $lefty: $a", a.width >= 88 && a.height >= 88)
            assertTrue("never at the edge", a.left > 20 && a.right < w)
            assertTrue("above the pages", a.bottom <= l.list.top)
            val row = listOf(a, l.settingsButton, l.findButton, l.screenButton, l.keyboardButton, l.strip) + (if (displays) listOf(l.displayButton) else emptyList())
            noOverlap(row)
            for (r in row) assertTrue("in the top row: $r", r.top >= a.top - 0.01f && r.bottom <= a.bottom + 0.01f)
            assertEquals("the tabs as tall as the controls", l.findButton.height, l.strip.height, 0.01f)
            assertTrue("room for the tabs", l.strip.width >= 200)
            if (lefty) assertTrue("past settings, so a slide left has room", a.left >= l.settingsButton.right)
        }
    }

    @Test fun thePhoneKeepsItsKey() {
        val l = PadLayout(412f, 915f, 0f, 40f, 0f, 24f, lefty = false, drawerOpen = true)
        assertEquals(82f, l.arrowKey.width)
        assertEquals(50f, l.arrowKey.height)
    }
}
