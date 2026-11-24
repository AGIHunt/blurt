package dev.blurt.remote.core

import dev.blurt.remote.core.FullOutput.*
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** The computer keyboard: what's pressed, in which order and for how long (port of FullKeyboardTests.swift). */
class FullTypingTest {
    private val a = FullKey("A")
    private val b = FullKey("B")
    private val left = FullKey("Left", fn = "Home")
    private val one = FullKey("1", fn = "F1")
    private val fn = FullKey(FullKind.Fn)

    @Test fun aKeyActsAsItLifts() {
        val e = FullTyping()
        assertEquals(listOf(Engage, Tick), e.began(1, a, 0.0))
        assertEquals(listOf(EngageWith(0.0), Press("A"), Used), e.ended(1, 0.1))
    }

    @Test fun slidOffNothingHappens() {
        val e = FullTyping()
        e.began(1, a, 0.0)
        assertEquals(listOf(), e.moved(1, false))
        assertEquals(listOf(), e.moved(1, true))
        assertEquals(listOf(), e.ended(1, 0.2))
    }

    @Test fun rolloverKeepsTheOrder() {
        val e = FullTyping()
        e.began(1, a, 0.0)
        assertEquals(listOf(EngageWith(0.0), Hold("A", true), Used, Engage, Tick), e.began(2, b, 0.05))
        assertEquals(listOf(EngageWith(0.05), Press("B"), Used), e.ended(2, 0.09))
        assertEquals(listOf<FullOutput>(Hold("A", false)), e.ended(1, 0.12))
    }

    @Test fun heldItGoesDownAndRepeats() {
        val e = FullTyping()
        e.began(1, a, 0.0)
        assertEquals(listOf(), e.tick(0.3))
        assertEquals(listOf(EngageWith(0.0), Hold("A", true), Grab, Used), e.tick(0.41))
        assertEquals(listOf<FullOutput>(Again("A")), e.tick(0.47))
        assertEquals(listOf<FullOutput>(Hold("A", false)), e.ended(1, 0.5))
    }

    @Test fun twoHeldTogetherAndOnlyTheLastRepeats() {
        val e = FullTyping()
        e.began(1, a, 0.0); e.tick(0.41)
        e.began(2, b, 0.5)
        val o = e.tick(0.95) + e.tick(1.02)
        assertTrue(Hold("B", true) in o && Again("B") in o && Again("A") !in o, "$o")
        assertEquals(listOf<FullOutput>(Hold("A", false)), e.ended(1, 1.1))
        assertEquals(listOf<FullOutput>(Hold("B", false)), e.ended(2, 1.2))
    }

    @Test fun nothingDestructiveRepeats() {
        val cmd = RemoteModifiers.COMMAND
        val ctrl = RemoteModifiers.CONTROL
        for ((n, m) in listOf("Escape" to 0, "Return" to 0, "C" to ctrl, "W" to cmd, "Delete" to cmd, "F5" to 0, "Tab" to 0)) assertFalse(FullKeys.repeats(n, m), n)
        for ((n, m) in listOf("A" to 0, "Left" to cmd, "=" to cmd, "-" to ctrl, "Delete" to 0, "Space" to 0)) assertTrue(FullKeys.repeats(n, m), n)
    }

    @Test fun theArrowsActAtOnce() {
        val e = FullTyping()
        assertEquals(listOf(Engage, Press("Left"), Tick, Used), e.began(1, left, 0.0))
        assertEquals(listOf<FullOutput>(Press("Left")), e.tick(0.36))
        assertEquals(listOf(), e.ended(1, 0.4))
    }

    @Test fun fnTappedHeldAndLocked() {
        val e = FullTyping()
        e.began(1, fn, 0.0); e.ended(1, 0.1)
        e.began(2, one, 1.0)
        assertEquals(listOf(EngageWith(1.0), Press("F1"), Used, FnChanged), e.ended(2, 1.1))
        assertFalse(e.fn)
        e.began(3, fn, 2.0)
        e.began(4, left, 2.2)
        assertEquals(listOf(EngageWith(2.2), Press("Home"), Used), e.ended(4, 2.3))
        e.ended(3, 2.4)
        assertFalse(e.fn, "used, so it's no tap")
        e.began(5, fn, 3.0); e.ended(5, 3.1); e.began(6, fn, 3.2); e.ended(6, 3.3)
        assertTrue(e.fnLocked)
    }

    @Test fun lettingGoLeavesNothingDown() {
        val e = FullTyping()
        e.began(1, a, 0.0); e.tick(0.5)
        e.began(2, FullKey(FullKind.Modifier(RemoteModifiers.SHIFT)), 0.6)
        val o = e.letGo()
        assertTrue(Hold("A", false) in o && ModifierUp(RemoteModifiers.SHIFT, 0.0, true) in o, "$o")
        assertTrue(e.isEmpty && !e.needsTicks)
    }
}

class HeldModifiersTest {
    private val said = mutableListOf<Int>()
    private val alt = mutableListOf<Boolean>()
    private val alone = mutableListOf<Int>()
    private val s = HeldModifiers({ said += it }, { alt += it }, { alone += it })
    private val cmd = RemoteModifiers.COMMAND
    private val shift = RemoteModifiers.SHIFT

    @Test fun heldWithAnotherKey() {
        s.press(cmd, 0.0)
        assertEquals(listOf(), said, "it may yet be a tap")
        s.engage()
        s.used()
        assertEquals(cmd, s.held, "still under the thumb")
        s.finish(cmd, 1.2, 1.2, false)
        assertEquals(listOf(cmd, 0), said)
        assertEquals(listOf(), alone, "no press of its own")
    }

    @Test fun togetherAndAfter() {
        s.press(cmd, 10.02); s.engage(10.0)
        assertEquals(cmd, s.held)
        s.lift(cmd)
        s.press(shift, 20.1); s.engage(20.0)
        assertEquals(0, s.held, "the Shift of the next letter")
        s.engage()
        assertEquals(shift, s.held)
    }

    @Test fun aTapIsForTheNextKeyAndHeldAloneItsOwn() {
        s.press(shift, 0.0); s.finish(shift, 0.1, 0.1, false)
        assertEquals(shift, s.once)
        s.used()
        assertEquals(listOf(shift, 0), said)
        s.press(shift, 1.2); s.finish(shift, 0.8, 2.0, false)
        assertEquals(listOf(shift), alone)
    }

    @Test fun altGrIsAKeyOfItsOwn() {
        s.pressAltGr(0.0); s.engage(); s.finishAltGr(0.9, 0.9, false)
        s.pressAltGr(1.9); s.finishAltGr(0.1, 2.0, false)
        assertTrue(s.altGrOnce)
        s.used()
        assertEquals(listOf(true, false, true, false), alt)
        assertEquals(listOf(), said)
    }

    @Test fun clearLetsGoOfEverything() {
        s.tap(cmd, 0.0); s.tap(cmd, 0.1); s.tap(shift, 1.0)
        s.pressAltGr(1.9); s.finishAltGr(0.1, 2.0, false)
        s.letGo()
        assertEquals(0, s.held)
        assertEquals(0, said.last())
        assertEquals(false, alt.last())
    }
}

class FullKeysTest {
    @Test fun everyRowIsFullAndEveryKeyIsThere() {
        for (t in FullTier.entries) for (h in RemoteHost.entries) {
            val rows = FullKeys.rows(t, h)
            rows.forEachIndexed { i, r -> assertEquals(t.across.toFloat(), r.sumOf { it.units.toDouble() }.toFloat(), 0.001f, "$t $h row $i") }
            val names = rows.flatten().mapNotNull { it.name }
            assertEquals(names.size, names.toSet().size, "$t $h: no key twice")
            val reach = names + rows.flatten().mapNotNull { it.fn }
            for (n in reach) assertNotNull(RemoteKey.named(n), n)
            for (c in RemoteLegends.names) assertTrue(c in names, "$t $h: $c")
            for (n in (1..12).map { "F$it" } + listOf("Home", "End", "PageUp", "PageDown", "ForwardDelete")) assertTrue(n in reach, "$t $h: $n")
            if (h != RemoteHost.MAC) for (n in listOf("Insert", "PrintScreen", "Pause", "Menu", "CapsLock")) assertTrue(n in reach, "$t $h: $n")
        }
    }

    @Test fun whatTheKeysSay() {
        val german = RemoteLegends("German", mapOf("Y" to RemoteLegend("z", "Z"), "Q" to RemoteLegend("q", "Q", "@"), "-" to RemoteLegend("ß", "?", "\\")))
        fun main(n: String, shift: Boolean = false, l: RemoteLegends? = null, altGr: Boolean = false) = FullLabel.of(FullKey(n), RemoteHost.WINDOWS, false, shift, altGr, l).main
        assertEquals("1", main("1")); assertEquals("!", main("1", shift = true)); assertEquals("A", main("A"))
        assertEquals("Z", main("Y", l = german)); assertEquals("ß", main("-", l = german)); assertEquals("?", main("-", shift = true, l = german))
        assertEquals("@", main("Q", l = german, altGr = true))
    }
}
