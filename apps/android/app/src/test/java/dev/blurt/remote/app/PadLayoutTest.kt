package dev.blurt.remote.app

import dev.blurt.remote.app.pad.Frame
import dev.blurt.remote.app.pad.PadLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The layout's promises, at the sizes Android hands out: phones both ways, tablets, a foldable folded, flat, in tabletop and as a book,
 *  and small windows. */
class PadLayoutTest {
    private fun keys(l: PadLayout): List<Frame> = l.dock + listOf(l.talk, l.arrowKey) + (if (l.landscape) listOf(l.appsKey, l.drawerButton) else emptyList())

    private fun check(l: PadLayout, w: Float, h: Float) {
        val all = keys(l) + listOf(l.list, l.strip, l.settingsButton, l.keyboardButton, l.screenButton, l.findButton, l.pad) + listOfNotNull(l.pad2)
        for (r in all) {
            assertTrue("inside the window: $r in ${w}x$h", r.left >= -0.01f && r.top >= -0.01f && r.right <= w + 0.01f && r.bottom <= h + 0.01f)
            assertFalse("not empty: $r", r.isEmpty)
        }
        // no two keys on top of each other, and none over a pad
        val k = keys(l)
        for (i in k.indices) for (j in i + 1 until k.size) assertFalse("keys $i and $j overlap: ${k[i]} ${k[j]}", k[i].intersects(k[j]))
        for (r in k + listOf(l.list)) {
            assertFalse("a key over the stage: $r", r.intersects(l.pad))
            l.pad2?.let { assertFalse("a key over the second pad: $r", r.intersects(it)) }
        }
        assertTrue("keys a thumb can hit", l.keyH >= 34f)
    }

    @Test fun phonePortraitIsTheIPhones() {
        val l = PadLayout(412f, 915f, 0f, 40f, 0f, 24f, lefty = false, drawerOpen = true)
        assertEquals(PadLayout.Mode.PORTRAIT, l.mode)
        check(l, 412f, 915f)
        assertEquals(48f, l.keyH)
        // six across, the dock ten even parts with the talk key last, by the thumb
        assertTrue(l.talk.left > l.dock.last().right)
        assertTrue(l.pad.height > 450)
    }

    @Test fun leftHandedMirrorsTheDock() {
        val l = PadLayout(412f, 915f, 0f, 40f, 0f, 24f, lefty = true, drawerOpen = true)
        check(l, 412f, 915f)
        assertTrue(l.talk.right < l.dock.first().left)
        assertTrue(l.arrowKey.left > l.settingsButton.right)
    }

    @Test fun phoneLandscapeHasTheThumbColumn() {
        val l = PadLayout(915f, 412f, 40f, 0f, 0f, 0f, lefty = false, drawerOpen = true)
        assertEquals(PadLayout.Mode.LANDSCAPE, l.mode)
        check(l, 915f, 412f)
        // the cutout's end has the rarely needed, the thumb's end the talk key
        assertTrue(l.settingsButton.left < 100 && l.talk.left > 800)
        // keys key-shaped: no taller than 1.25 times their width
        assertTrue(l.keyH <= l.keyW * 1.25f + 0.5f)
        val away = PadLayout(915f, 412f, 40f, 0f, 0f, 0f, lefty = false, drawerOpen = false)
        assertTrue("put away, the picture gets the room", away.pad.width > l.pad.width + 300)
    }

    @Test fun tabletGetsAStageAndAPhoneSizedPanel() {
        val l = PadLayout(1280f, 800f, 0f, 0f, 0f, 0f, lefty = false, drawerOpen = true)
        assertEquals(PadLayout.Mode.SPLIT, l.mode)
        check(l, 1280f, 800f)
        assertTrue("never stretched keys", l.drawer.width <= PadLayout.PANEL_W)
        assertEquals(48f, l.keyH)
        assertTrue(l.pad.width > 800 && l.pad2 != null)
    }

    @Test fun tabletPortraitStacks() {
        val l = PadLayout(800f, 1280f, 0f, 0f, 0f, 0f, lefty = false, drawerOpen = true)
        assertEquals(PadLayout.Mode.STACK, l.mode)
        check(l, 800f, 1280f)
        assertTrue(l.drawer.width <= PadLayout.PANEL_W)
        assertTrue(l.pad.bottom <= l.drawer.top)
    }

    @Test fun nothingCrossesTheFold() {
        // book: the fold down the middle
        val book = PadLayout.Fold(Frame(420f, 0f, 421f, 841f), vertical = true, halfOpened = true)
        val b = PadLayout(841f, 841f, 0f, 0f, 0f, 0f, lefty = false, drawerOpen = true, fold = book)
        check(b, 841f, 841f)
        for (r in keys(b) + listOf(b.list, b.pad) + listOfNotNull(b.pad2)) assertFalse("across the fold: $r", r.intersects(book.bounds))
        // tabletop: the fold across, the picture above it
        val table = PadLayout.Fold(Frame(0f, 420f, 841f, 421f), vertical = false, halfOpened = true)
        val t = PadLayout(841f, 841f, 0f, 0f, 0f, 0f, lefty = false, drawerOpen = true, fold = table)
        assertEquals(PadLayout.Mode.STACK, t.mode)
        check(t, 841f, 841f)
        assertTrue("the picture on the upper half", t.pad.bottom <= 420f)
        for (r in keys(t) + listOf(t.list) + listOfNotNull(t.pad2)) {
            assertFalse("across the fold: $r", r.intersects(table.bounds))
            assertTrue("keys and pad on the lower half: $r", r.top >= 421f)
        }
    }

    @Test fun smallWindowsStillFit() {
        for ((w, h) in listOf(412f to 400f, 360f to 640f, 500f to 300f, 600f to 500f, 320f to 560f)) check(PadLayout(w, h, 0f, 0f, 0f, 0f, false, true), w, h)
    }

    @Test fun edgeStripsStayInTheBudget() {
        for (l in listOf(PadLayout(412f, 915f, 0f, 0f, 0f, 0f, false, true), PadLayout(915f, 412f, 0f, 0f, 0f, 0f, false, true))) {
            for (r in l.exclusions) assertTrue("200 dp a side at most", r.height <= 200.01f)
        }
    }
}
