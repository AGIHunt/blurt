// Ported one for one from apps/ios/BlurtRemoteTests/PadEngineTests.swift (PadEngineTests, ScreenPlanTests, ViewPortTests).
package dev.blurt.remote.core

import dev.blurt.remote.core.PadOutput.Button
import dev.blurt.remote.core.PadOutput.Click
import dev.blurt.remote.core.PadOutput.DragTo
import dev.blurt.remote.core.PadOutput.Haptic
import dev.blurt.remote.core.PadOutput.PointAt
import dev.blurt.remote.core.PadOutput.Scroll
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlin.test.fail

class PadEngineTest {
    private fun t(id: Int, x: Double, y: Double) = PadTouch(id, x, y)
    private fun t(id: Int, x: Int, y: Int) = PadTouch(id, x.toDouble(), y.toDouble())
    private val left = RemoteMouseButton.LEFT
    private val right = RemoteMouseButton.RIGHT
    private val tap = Haptic(PadHaptic.TAP)
    private val grab = Haptic(PadHaptic.GRAB)
    private val release = Haptic(PadHaptic.RELEASE)
    private fun pt(x: Int, y: Int) = PadPoint(x.toDouble(), y.toDouble())
    private fun scroll(phase: RemoteScrollPhase) = Scroll(0f, 0f, phase)
    private val began = RemoteScrollPhase.BEGAN
    private val ended = RemoteScrollPhase.ENDED

    @Test fun tapClicks() {
        val e = PadEngine()
        assertEquals(listOf(), e.began(listOf(t(1, 100, 100)), 0.0))
        assertEquals(listOf(Click(left), tap), e.ended(listOf(1), 0.1))
    }

    @Test fun restingThumbNeverClicks() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 100)), 0.0)
        assertEquals(listOf(), e.ended(listOf(1), 0.3))
    }

    @Test fun moveHasNoClick() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 100)), 0.0)
        e.moved(listOf(t(1, 110, 100)), 0.05)
        val o = e.moved(listOf(t(1, 120, 100)), 0.06)
        assertIs<PadOutput.Move>(o.firstOrNull(), "$o")
        assertEquals(listOf(), e.ended(listOf(1), 0.1))
    }

    @Test fun doubleTapIsTwoClicks() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 100)), 0.0)
        e.ended(listOf(1), 0.08)
        e.began(listOf(t(1, 102, 100)), 0.2)
        assertEquals(listOf(Click(left), tap), e.ended(listOf(1), 0.26))
    }

    @Test fun tapThenMoveDragsAndSurvivesALift() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 100)), 0.0)
        e.ended(listOf(1), 0.08)
        e.began(listOf(t(1, 100, 100)), 0.2)
        assertEquals(listOf(Button(left, true), grab), e.moved(listOf(t(1, 120, 100)), 0.25))
        assertEquals(listOf(), e.ended(listOf(1), 0.4))
        e.began(listOf(t(1, 50, 50)), 0.6)    // a new stroke, still dragging
        assertIs<PadOutput.Move>(e.moved(listOf(t(1, 60, 50)), 0.62).firstOrNull())
        assertEquals(listOf(), e.ended(listOf(1), 0.7))
        assertEquals(listOf(Button(left, false), release), e.tick(1.2))
    }

    @Test fun holdThenLiftIsRightClick() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 100)), 0.0)
        assertEquals(listOf(grab), e.tick(0.45))
        assertEquals(listOf(Click(right), tap), e.ended(listOf(1), 0.6))
    }

    @Test fun aPalmStartsNothing() {
        val e = PadEngine()
        assertEquals(listOf(), e.began(listOf(), 0.0))
        e.began(listOf(t(1, 100, 100)), 0.1)
        assertEquals(listOf(), e.moved(listOf(t(1, 200, 100)), 0.2), "no three-finger swipe from nowhere")
    }

    @Test fun liftingOneOfThreeFingersSwipesNothing() {
        val e = PadEngine()
        e.began(listOf(t(1, 0, 300), t(2, 100, 300), t(3, 300, 300)), 0.0)
        e.ended(listOf(3), 0.1)
        assertEquals(listOf(), e.moved(listOf(t(1, 0, 300), t(2, 100, 300)), 0.2))
    }

    @Test fun restingThumbNeverRightClicks() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 100)), 0.0)
        e.tick(0.45)
        assertEquals(listOf(), e.ended(listOf(1), 2.0))
    }

    @Test fun aTouchLongAfterAFlingClicks() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 300), t(2, 160, 300)), 0.0)
        var y = 300.0
        for (i in 0..6) {
            y -= 20
            e.moved(listOf(t(1, 100.0, y), t(2, 160.0, y)), 0.02 + i * 0.016)
        }
        e.ended(listOf(1, 2), 0.13)
        assertEquals(listOf(), e.began(listOf(t(1, 100, 100)), 5.0))
        assertEquals(listOf(Click(left), tap), e.ended(listOf(1), 5.05))
    }

    @Test fun holdThenMoveDrags() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 100)), 0.0)
        assertEquals(listOf(grab), e.tick(0.45))
        assertEquals(listOf(Button(left, true)), e.moved(listOf(t(1, 100, 120)), 0.5))
        assertIs<PadOutput.Move>(e.moved(listOf(t(1, 100, 130)), 0.52).firstOrNull())
        assertEquals(listOf(), e.ended(listOf(1), 0.6))
        assertEquals(listOf(Button(left, false), release), e.tick(1.1), "a long drag can take a new stroke first")
    }

    @Test fun oneFingerAlongTheEdgeScrolls() {
        val e = PadEngine()
        e.scrollEdge = 374.0..400.0
        e.began(listOf(t(1, 390, 100)), 0.0)
        assertEquals(listOf(scroll(began)), e.moved(listOf(t(1, 390, 120)), 0.05))
        val o = e.moved(listOf(t(1, 390, 130)), 0.07).firstOrNull()
        assertTrue(o is Scroll && o.phase == RemoteScrollPhase.CHANGED, "$o")
    }

    @Test fun acrossTheEdgeIsThePointer() {
        val e = PadEngine()
        e.scrollEdge = 374.0..400.0
        e.began(listOf(t(1, 390, 100)), 0.0)
        e.moved(listOf(t(1, 370, 102)), 0.05)
        assertIs<PadOutput.Move>(e.moved(listOf(t(1, 360, 104)), 0.07).firstOrNull())
    }

    @Test fun aTapOnTheEdgeStillClicks() {
        val e = PadEngine()
        e.scrollEdge = 374.0..400.0
        e.began(listOf(t(1, 390, 100)), 0.0)
        assertEquals(listOf(Click(left), tap), e.ended(listOf(1), 0.08))
    }

    @Test fun twoFingerTapRightClicks() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 100), t(2, 160, 100)), 0.0)
        e.ended(listOf(1), 0.08)
        assertEquals(listOf(Click(right), tap), e.ended(listOf(2), 0.1))
    }

    @Test fun twoFingerScrollFlingsAndATouchStopsIt() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 300), t(2, 160, 300)), 0.0)
        assertEquals(listOf(scroll(began)), e.moved(listOf(t(1, 100, 290), t(2, 160, 290)), 0.02))
        var y = 290.0
        for (i in 1..6) {
            y -= 20
            e.moved(listOf(t(1, 100.0, y), t(2, 160.0, y)), 0.02 + i * 0.016)
        }
        val o = e.ended(listOf(1, 2), 0.13)
        assertEquals(scroll(ended), o.first())
        assertIs<PadOutput.Fling>(o.last(), "$o")
        assertEquals(listOf(PadOutput.ScrollStop), e.began(listOf(t(1, 100, 100)), 0.3))
        assertEquals(listOf(), e.ended(listOf(1), 0.35), "the touch that stopped it isn't a click")
    }

    @Test fun threeFingerSwipes() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 300), t(2, 150, 300), t(3, 200, 300)), 0.0)
        val o = e.moved(listOf(t(1, 100, 200), t(2, 150, 200), t(3, 200, 200)), 0.1)
        assertEquals(listOf(PadOutput.System(RemoteSystemMove.MISSION_CONTROL), grab), o)
        assertEquals(listOf(), e.moved(listOf(t(1, 100, 100), t(2, 150, 100), t(3, 200, 100)), 0.2), "once per swipe")
    }

    @Test fun thirdFingerLandingLateStillSwipes() {
        for (wobble in listOf(10.0, 40.0)) {   // two fingers that scrolled, or spread, a little first
            val e = PadEngine()
            e.began(listOf(t(1, 100, 300), t(2, 160, 300)), 0.0)
            e.moved(listOf(t(1, 100 - wobble, 300.0), t(2, 160 + wobble, 300 + wobble)), 0.02)
            e.began(listOf(t(3, 220, 300)), 0.04)
            val o = e.moved(listOf(t(1, 40, 300), t(2, 100, 300), t(3, 160, 300)), 0.1)
            assertEquals(PadOutput.System(RemoteSystemMove.SPACE_RIGHT), o.firstOrNull(), "$o")
        }
    }

    @Test fun pinchZooms() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 300), t(2, 200, 300)), 0.0)
        e.moved(listOf(t(1, 70, 300), t(2, 230, 300)), 0.05)
        assertEquals(listOf(PadOutput.System(RemoteSystemMove.ZOOM_IN), Haptic(PadHaptic.STEP)), e.moved(listOf(t(1, 40, 300), t(2, 260, 300)), 0.1))
    }

    private fun view(o: List<PadOutput>): PadOutput.View = o.firstOrNull() as? PadOutput.View ?: fail("$o")

    @Test fun withTheScreenShowingAPinchZoomsTheView() {
        val e = PadEngine()
        e.pinchZoomsView = true
        e.began(listOf(t(1, 100, 300), t(2, 200, 300)), 0.0)
        e.moved(listOf(t(1, 80, 300), t(2, 220, 300)), 0.05)     // 100 → 140 apart: past the threshold
        val v = view(e.moved(listOf(t(1, 60, 300), t(2, 240, 300)), 0.1))
        assertEquals(180.0 / 140, v.scale, 0.001)
        assertEquals(0.0, v.dx)
        assertEquals(0.0, v.dy)
        assertEquals(pt(150, 300), v.at)
        assertEquals(listOf(PadOutput.ViewEnd), e.ended(listOf(1, 2), 0.2))
    }

    @Test fun withThePictureTwoFingersScrollTheMacUnderThem() {
        val e = PadEngine()
        e.pinchZoomsView = true
        e.touchMode = true
        e.began(listOf(t(1, 100, 300), t(2, 200, 300)), 0.0)
        assertEquals(listOf(PointAt(pt(150, 300)), scroll(began)), e.moved(listOf(t(1, 100, 320), t(2, 200, 320)), 0.05))
        val o = e.moved(listOf(t(1, 100, 340), t(2, 200, 340)), 0.08).firstOrNull()
        assertTrue(o is Scroll && o.phase == RemoteScrollPhase.CHANGED && o.dy > 0, "$o")
    }

    @Test fun sideways() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 300), t(2, 200, 300)), 0.0)
        e.moved(listOf(t(1, 120, 300), t(2, 220, 300)), 0.05)
        val o = e.moved(listOf(t(1, 140, 300), t(2, 240, 300)), 0.08).firstOrNull()
        assertTrue(o is Scroll && o.phase == RemoteScrollPhase.CHANGED && o.dx > 0 && o.dy == 0f, "$o")
    }

    @Test fun aScrollThatClearlyPinchesZoomsThePicture() {
        val e = PadEngine()
        e.pinchZoomsView = true
        e.began(listOf(t(1, 100, 300), t(2, 200, 300)), 0.0)
        e.moved(listOf(t(1, 100, 320), t(2, 200, 320)), 0.05)
        assertEquals(listOf(scroll(ended)), e.moved(listOf(t(1, 70, 330), t(2, 230, 330)), 0.1))
        assertEquals(180.0 / 160, view(e.moved(listOf(t(1, 60, 330), t(2, 240, 330)), 0.12)).scale, 0.001)
    }

    @Test fun notZoomedTwoFingersStillScroll() {
        val e = PadEngine()
        e.pinchZoomsView = true
        e.began(listOf(t(1, 100, 300), t(2, 200, 300)), 0.0)
        assertEquals(listOf(scroll(began)), e.moved(listOf(t(1, 100, 320), t(2, 200, 320)), 0.05))
    }

    @Test fun aFingerLiftedMidPinchDoesntJump() {
        val e = PadEngine()
        e.pinchZoomsView = true
        e.began(listOf(t(1, 100, 300), t(2, 200, 300)), 0.0)
        e.moved(listOf(t(1, 60, 300), t(2, 240, 300)), 0.05)
        assertEquals(listOf(), e.ended(listOf(2), 0.1))
        assertEquals(listOf(), e.moved(listOf(t(1, 50, 300)), 0.12))
        e.began(listOf(t(3, 300, 300)), 0.2)
        assertEquals(260.0 / 250, view(e.moved(listOf(t(3, 310, 300)), 0.22)).scale, 0.001)
    }

    @Test fun zoomedATwoFingerTapStillRightClicks() {
        val e = PadEngine()
        e.pinchZoomsView = true
        e.began(listOf(t(1, 100, 300), t(2, 200, 300)), 0.0)
        assertEquals(listOf(Click(right), tap), e.ended(listOf(1, 2), 0.1))
    }

    @Test fun aSecondFingerDoesntJumpADrag() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 100)), 0.0)
        e.tick(0.45)
        e.moved(listOf(t(1, 100, 120)), 0.5)
        e.began(listOf(t(2, 300, 120)), 0.55)
        val m = e.moved(listOf(t(1, 101, 120), t(2, 301, 120)), 0.6).firstOrNull() as? PadOutput.Move ?: fail()
        assertTrue(abs(m.dx) < 6)
        assertEquals(listOf(), e.ended(listOf(2), 0.65))
        assertEquals(listOf(), e.moved(listOf(t(1, 101, 120)), 0.7), "no jump back when it lifts")
    }

    @Test fun unevenFingersScrollingDontZoom() {
        val e = PadEngine()
        e.pinchZoomsView = true
        e.began(listOf(t(1, 100, 300), t(2, 200, 300)), 0.0)
        e.moved(listOf(t(1, 110, 310), t(2, 212, 306)), 0.05)
        for (i in 1..6) {
            val y = 310.0 + i * 12
            assertIs<Scroll>(e.moved(listOf(t(1, 110.0, y), t(2, 212.0 + (i % 2) * 6, y + 3)), 0.05 + i * 0.02).firstOrNull())
        }
    }

    @Test fun fingersClearlyPinchingWhileZoomedDoZoom() {
        val e = PadEngine()
        e.pinchZoomsView = true
        e.began(listOf(t(1, 100, 300), t(2, 200, 300)), 0.0)
        e.moved(listOf(t(1, 95, 300), t(2, 205, 300)), 0.05)
        e.moved(listOf(t(1, 85, 300), t(2, 215, 300)), 0.1)      // past the line: nothing jumps
        assertEquals(150.0 / 130, view(e.moved(listOf(t(1, 75, 300), t(2, 225, 300)), 0.15)).scale, 0.001)
    }

    @Test fun withTouchModeATapLandsUnderTheFinger() {
        val e = PadEngine()
        e.touchMode = true
        e.began(listOf(t(1, 100, 200)), 0.0)
        assertEquals(listOf(PointAt(pt(100, 200)), Click(left), tap), e.ended(listOf(1), 0.08))
        e.began(listOf(t(1, 102, 203)), 0.2)
        assertEquals(listOf(Click(left), tap), e.ended(listOf(1), 0.26), "the second of a double click stays put")
    }

    @Test fun withTouchModeMovingAFingerIsStillThePointer() {
        val e = PadEngine()
        e.touchMode = true
        e.began(listOf(t(1, 100, 200)), 0.0)
        e.moved(listOf(t(1, 110, 200)), 0.05)
        assertIs<PadOutput.Move>(e.moved(listOf(t(1, 120, 200)), 0.07).firstOrNull())
        assertEquals(listOf(), e.ended(listOf(1), 0.2))
    }

    @Test fun withTouchModeADragFollowsTheFinger() {
        val e = PadEngine()
        e.touchMode = true
        e.began(listOf(t(1, 100, 200)), 0.0)
        assertEquals(listOf(PointAt(pt(100, 200)), grab), e.tick(0.45))
        assertEquals(listOf(Button(left, true)), e.moved(listOf(t(1, 100, 220)), 0.5))
        assertEquals(listOf(DragTo(pt(130, 260))), e.moved(listOf(t(1, 130, 260)), 0.55))
        e.began(listOf(t(2, 300, 300)), 0.6)
        assertEquals(listOf(DragTo(pt(135, 262))), e.moved(listOf(t(1, 135, 262), t(2, 310, 300)), 0.65), "the finger that started it")
        e.ended(listOf(2), 0.7)
        assertEquals(listOf(Button(left, false), release), e.ended(listOf(1), 0.75), "up at once: nothing to wait for")
    }

    @Test fun withTouchModeHoldAndLiftRightClicksThere() {
        val e = PadEngine()
        e.touchMode = true
        e.began(listOf(t(1, 100, 200)), 0.0)
        e.tick(0.45)
        assertEquals(listOf(Click(right), tap), e.ended(listOf(1), 0.6))
    }

    @Test fun cancelLetsGoOfADrag() {
        val e = PadEngine()
        e.began(listOf(t(1, 100, 100)), 0.0)
        e.ended(listOf(1), 0.08)
        e.began(listOf(t(1, 100, 100)), 0.2)
        e.moved(listOf(t(1, 120, 100)), 0.25)
        assertEquals(listOf(Button(left, false)), e.cancel())
    }

    @Test fun needsTicksWhileSomethingCanStillHappen() {
        val e = PadEngine()
        assertFalse(e.needsTicks)
        e.began(listOf(t(1, 100, 100)), 0.0)
        assertTrue(e.needsTicks, "may become a hold")
        e.moved(listOf(t(1, 130, 100)), 0.05)
        assertFalse(e.needsTicks)
    }
}

class ScreenPlanTest {
    private val native = PadSize(1320.0, 2868.0)
    private fun plan(q: ScreenQuality, r: LinkRoute, cellular: Boolean = false, lowData: Boolean = false) = ScreenPlan(q, r, cellular, lowData, native)

    @Test fun autoSpendsWhereItsFree() {
        assertEquals(12_000_000, plan(ScreenQuality.AUTO, LinkRoute.LOCAL).bitrate)
        assertEquals(2868, plan(ScreenQuality.AUTO, LinkRoute.LOCAL).width)
        assertEquals(60, plan(ScreenQuality.AUTO, LinkRoute.LOCAL).fps)
        assertTrue(plan(ScreenQuality.AUTO, LinkRoute.LOCAL, cellular = true).bitrate < 12_000_000, "a public address on mobile data isn't home")
        assertTrue(plan(ScreenQuality.AUTO, LinkRoute.RELAY, cellular = true).bitrate < plan(ScreenQuality.AUTO, LinkRoute.RELAY).bitrate, "mobile data costs money")
        assertTrue(plan(ScreenQuality.AUTO, LinkRoute.RELAY, cellular = true, lowData = true).bitrate < plan(ScreenQuality.AUTO, LinkRoute.RELAY, cellular = true).bitrate, "and the user said so")
    }

    @Test fun atHomeFramesComeAtThePanelsRate() {
        val pro = ScreenPlan(ScreenQuality.AUTO, LinkRoute.LOCAL, false, false, native, panel = 120)
        assertEquals(120, pro.fps, "a 120 Hz panel")
        assertEquals(12_000_000, pro.bitrate, "no more data for it")
        assertEquals(90, ScreenPlan(ScreenQuality.AUTO, LinkRoute.LOCAL, false, false, native, panel = 90).fps)
        assertEquals(30, ScreenPlan(ScreenQuality.AUTO, LinkRoute.RELAY, false, false, native, panel = 120).fps, "away, motion is what gives")
        assertEquals(120, ScreenPlan(ScreenQuality.AUTO, LinkRoute.LOCAL, false, false, native, panel = 240).fps)
    }

    @Test fun theTableInRemoteMd() {
        assertEquals(ScreenPlan(1800, 1100, 4_000_000, 30), plan(ScreenQuality.AUTO, LinkRoute.DIRECT), "Wi-Fi elsewhere")
        assertEquals(ScreenPlan(1440, 900, 2_000_000, 24), plan(ScreenQuality.AUTO, LinkRoute.RELAY, cellular = true), "mobile data")
        assertEquals(ScreenPlan(1280, 800, 1_000_000, 15), plan(ScreenQuality.AUTO, LinkRoute.LOCAL, lowData = true), "Data Saver, even at home")
        assertEquals(ScreenPlan(2868, 1320, 8_000_000, 30), plan(ScreenQuality.SHARP, LinkRoute.RELAY))
        assertEquals(ScreenPlan(1800, 1100, 4_000_000, 30), plan(ScreenQuality.BALANCED, LinkRoute.LOCAL))
    }

    @Test fun aChoiceIsKept() {
        assertEquals(1_000_000, plan(ScreenQuality.SAVER, LinkRoute.LOCAL).bitrate, "even at home")
        assertEquals(2868, plan(ScreenQuality.SHARP, LinkRoute.RELAY, cellular = true).width)
        assertTrue(plan(ScreenQuality.SHARP, LinkRoute.RELAY, cellular = true).bitrate > plan(ScreenQuality.BALANCED, LinkRoute.RELAY).bitrate)
        for (q in ScreenQuality.entries) for (r in LinkRoute.entries) {
            val p = plan(q, r)
            assertEquals(0, p.width % 2 + p.height % 2)
            assertTrue(p.width <= 2868)
        }
    }
}

class ViewPortTest {
    private fun close(a: PadRect, b: PadRect) {
        for ((x, y) in listOf(a.minX to b.minX, a.minY to b.minY, a.width to b.width, a.height to b.height)) assertEquals(y, x, 0.0001, "$a vs $b")
    }
    private fun p(x: Double, y: Double) = PadPoint(x, y)

    @Test fun thePointBetweenTheFingersStaysPut() {
        val v = ViewPort()
        v.change(2.0, PadPoint.ZERO, p(0.25, 0.5))
        close(v.rect, PadRect(0.125, 0.25, 0.5, 0.5))
        v.change(2.0, PadPoint.ZERO, p(0.5, 0.5))
        close(v.rect, PadRect(0.25, 0.375, 0.25, 0.25))
    }

    @Test fun aMoveStopsAtTheEdge() {
        val v = ViewPort()
        v.change(2.0, PadPoint.ZERO, p(0.5, 0.5))
        v.change(1.0, p(0.25, 0.0), PadPoint.ZERO)     // the picture goes right: the view goes left
        close(v.rect, PadRect(0.125, 0.25, 0.5, 0.5))
        v.change(1.0, p(5.0, -5.0), PadPoint.ZERO)
        close(v.rect, PadRect(0.0, 0.5, 0.5, 0.5))
    }

    @Test fun aPinchOutStretchesThenSpringsBack() {
        val v = ViewPort()
        v.change(0.5, PadPoint.ZERO, p(0.5, 0.5))
        assertEquals(ViewPort.STRETCH, v.zoom)
        close(v.rect, PadRect(-0.125, -0.125, 1.25, 1.25))
        v.settle()
        assertEquals(1.0, v.zoom)
        close(v.rect, PadRect(0.0, 0.0, 1.0, 1.0))
    }

    @Test fun onATallerStageThePictureSitsAtTheBottomAndFillsItAsItZooms() {
        val v = ViewPort()
        v.reshape(0.5, alignY = 1.0)       // twice the picture's height
        close(v.rect, PadRect(0.0, -1.0, 1.0, 2.0))
        assertEquals(RemoteCrop.WHOLE, v.crop)
        v.change(2.0, PadPoint.ZERO, p(0.5, 0.75))
        close(v.rect, PadRect(0.25, 0.0, 0.5, 1.0))
        assertEquals(RemoteCrop.WHOLE, v.crop, "all of the height is in view: the picture must be whole top to bottom")
        v.change(2.0, PadPoint.ZERO, p(0.5, 0.5))
        assertEquals(0.5, v.crop.w.toDouble(), 0.0001, "the screen's shape, around a taller view")
        assertEquals(0.5, v.crop.h.toDouble(), 0.0001)
    }

    @Test fun aTallStageMovesAroundBothWays() {
        val v = ViewPort()
        v.reshape(0.5, alignY = 1.0)
        v.change(4.0, PadPoint.ZERO, p(0.5, 0.75))
        val was = v.rect
        v.change(1.0, p(0.1, 0.1), PadPoint.ZERO)
        assertTrue(v.rect.minX < was.minX)
        assertTrue(v.rect.minY < was.minY)
    }

    @Test fun notQuiteZoomedIsTheWholeScreen() {
        val v = ViewPort()
        v.change(1.05, PadPoint.ZERO, PadPoint.ZERO)
        v.settle()
        assertTrue(v.isWhole)
        assertEquals(RemoteCrop.WHOLE, v.crop)
    }

    @Test fun thePointerPushesTheView() {
        val v = ViewPort()
        v.change(2.0, PadPoint.ZERO, p(0.5, 0.5))
        assertFalse(v.follow(p(0.5, 0.5)))
        assertTrue(v.follow(p(0.76, 0.5)))
        assertEquals(0.82, v.rect.maxX, 0.001)
    }

    @Test fun noFurtherThanEight() {
        val v = ViewPort()
        v.change(100.0, PadPoint.ZERO, PadPoint.ZERO)
        assertEquals(ViewPort.CLOSEST, v.zoom)
    }
}

class PointerCurveTest {
    @Test fun slowIsPreciseFastCrosses() {
        val c = RemotePointerCurve()
        assertEquals(1f, c.gain(10f))
        assertEquals(5.5f, c.gain(5000f))
        assertTrue(c.gain(480f) > 1f && c.gain(480f) < 5.5f)
        assertEquals(2f to 0f, c.apply(2f, 0f, 1f), "2 pt in a second is slow")
        assertEquals(2f, c.scaled(2f).gain(10f))
    }

    @Test fun subpixelsAddUp() {
        val s = RemoteSubpixel()
        var x = 0
        var y = 0
        repeat(10) { val (a, b) = s.whole(0.25f, -0.25f); x += a; y += b }
        assertEquals(2, x)
        assertEquals(-2, y)
        s.reset()
        assertEquals(0 to 0, s.whole(0.5f, 0.5f))
    }
}
