// Ported from DeckTests in apps/ios/BlurtRemoteTests/PadEngineTests.swift, for every host, plus the per-host defaults of
// docs/design/remote-protocol.md §Default keys per host.
package dev.blurt.remote.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class DeckTest {
    private val hosts = RemoteHost.entries
    private val C = RemoteModifiers.CONTROL
    private val A = RemoteModifiers.OPTION
    private val S = RemoteModifiers.SHIFT
    private val W = RemoteModifiers.COMMAND
    /** PadLayout.visibleRows on iOS */
    private val visibleRows = 4

    private fun chords(d: Deck, row: Int) = d.sections[0].slots.subList(row * 6, row * 6 + 6).map { (it.action as KeyAction.Chord) }

    @Test fun standardDeckFits() {
        for (h in hosts) {
            val d = Deck.standard(h)
            assertEquals(Deck.DOCK_COUNT, d.dock.size)
            assertTrue(d.sections.size <= Deck.MAX_SECTIONS)
            assertTrue(d.sections[0].slots.size <= Deck.COLUMNS * visibleRows, "everything for every day, on one screen")
            for (s in d.sections) assertTrue(s.slots.sumOf { it.span ?: 1 } <= s.columns * visibleRows, "${s.name} fits a page on $h")
            val held = d.dock.mapNotNull { (it.action as? KeyAction.Sticky)?.mods }.toSet()
            assertEquals(setOf(W, A, C, S), held, "all four, side by side")
            assertTrue(d.dock.any { (it.action as? KeyAction.Chord)?.chord?.key == "Escape" }, "Esc wherever the list is")
            assertEquals(Deck.spaceBar.action, d.dock.last().action)
        }
    }

    @Test fun everyFaceIsSomething() {
        for (h in hosts) {
            val all = Deck.standard(h).dock + Deck.standard(h).sections.flatMap { it.slots } + Deck.catalogue(h).flatMap { it.slots }
            for (s in all) assertTrue(s.face(h).isNotEmpty(), s.title(h))
        }
    }

    @Test fun aKeyShowsWhatsPressedNotWhatItsFor() {
        val copy = Deck.standard().sections[0].slots[0]
        assertEquals("sf:doc.on.doc", copy.face())
        assertEquals("⌘C", copy.detail())
        assertEquals("Copy", copy.title(), "lists still say")
        val pc = Deck.standard(RemoteHost.WINDOWS).sections[0].slots[0]
        assertEquals("sf:doc.on.doc", pc.face(RemoteHost.WINDOWS))
        assertEquals("Ctrl+C", pc.detail(RemoteHost.WINDOWS))
    }

    @Test fun controlTabBothWays() {
        for (h in hosts) {
            val cs = Deck.standard(h).sections[0].slots.mapNotNull { (it.action as? KeyAction.Chord)?.takeIf { c -> c.cycle }?.chord }
            assertTrue(cs.contains(RemoteChord(C, "Tab")))
            assertTrue(cs.contains(RemoteChord(C or S, "Tab")))
        }
    }

    @Test fun theWholeKeyboardIsThere() {
        for (h in hosts) {
            val d = Deck.standard(h)
            val names = (d.dock + d.sections.flatMap { it.slots }).mapNotNull { (it.action as? KeyAction.Chord)?.chord?.takeIf { c -> c.mods == 0 }?.key }
            for (k in listOf("A", "Z", "0", "9", "F12", "Space", "/")) assertTrue(names.contains(k), k)
            val letters = d.sections.first { it.columns == 10 }
            assertEquals(40, letters.slots.sumOf { it.span ?: 1 }, "whole rows, as on a keyboard")
        }
    }

    @Test fun noKeyTwice() {
        for (h in hosts) {
            val seen = HashMap<KeyAction, String>()
            val d = Deck.standard(h)
            for (s in d.dock + d.sections.flatMap { it.slots }) {
                assertNull(seen[s.action], "${s.title(h)} is there twice on $h")
                seen[s.action] = s.title(h)
            }
        }
    }

    @Test fun movingKeys() {
        var d = Deck.standard()
        val a = d.sections[0].slots[0]
        val b = d.sections[0].slots[3]
        d = d.move(a.id, b.id)
        assertEquals(a.id, d.sections[0].slots[3].id)
        val esc = d.dock[0]
        val one = d.sections[0].slots[1]
        d = d.move(one.id, esc.id)
        assertEquals(one.id, d.dock[0].id)
        assertEquals(Deck.DOCK_COUNT, d.dock.size)
        assertEquals(esc.id, d.sections[0].slots[1].id, "the dock swaps")
        val far = d.sections[1].slots[0]
        val count = d.sections[0].slots.size
        d = d.move(far.id, d.sections[0].slots[2].id)
        assertEquals(count + 1, d.sections[0].slots.size, "across sections")
        assertEquals(far.id, d.sections[0].slots[2].id)
    }

    @Test fun editing() {
        var d = Deck.standard(RemoteHost.LINUX)
        val first = d.sections[0].slots[0]
        val text = KeySlot(KeyAction.Text("/compact", true), hint = "Compact")
        d = d.add(text, d.sections[0].id, 0)
        assertEquals(text, d.sections[0].slots[0])
        d = d.replace(text.id, text.copy(glyph = "🗜"))
        assertEquals("🗜", d.sections[0].slots[0].face(RemoteHost.LINUX))
        d = d.remove(text.id)
        assertEquals(first.id, d.sections[0].slots[0].id)
        d = d.remove(d.dock[0].id)
        assertEquals(Deck.DOCK_COUNT, d.dock.size, "the dock keeps its keys")
        d = d.addSection("Mine").addSection("Two")
        assertEquals(Deck.MAX_SECTIONS, d.sections.size)
        assertEquals(d, d.addSection("Too many"))
        d = d.renameSection(d.sections[4].id, "Yours")
        assertEquals("Yours", d.sections[4].name)
        d = d.removeSection(d.sections[5].id)
        assertEquals(5, d.sections.size)
    }

    @Test fun roundTrips() {
        for (h in hosts) {
            val d = Deck.standard(h).let { it.add(KeySlot(KeyAction.Sequence(listOf(RemoteStep.Text("x"), RemoteStep.Wait(5))), glyph = "x"), it.sections[3].id) }
            assertEquals(d, Deck.fromJson(d.toJson()))
            assertEquals(d, Deck.restore(d.toJson(), h))
        }
        assertEquals(Deck.standard(RemoteHost.WINDOWS).dock.map { it.action }, Deck.restore("{]", RemoteHost.WINDOWS).dock.map { it.action }, "damaged: the defaults")
        assertEquals(Deck.standard(RemoteHost.LINUX).dock.map { it.action }, Deck.restore(null, RemoteHost.LINUX).dock.map { it.action })
        assertTrue(Deck.storeKey(RemoteHost.MAC) != Deck.storeKey(RemoteHost.WINDOWS), "one layout per platform")
    }

    @Test fun readsTheSwiftShape() {
        val json = """{"dock":[],"sections":[{"id":"S","name":"Main","columns":6,"slots":[
            {"id":"A","action":{"chord":{"_0":{"mods":1,"key":"C"},"cycle":false}},"glyph":"sf:doc.on.doc","hint":"Copy"},
            {"id":"B","action":{"arrows":{}}},
            {"id":"C","action":{"sticky":{"_0":3}}},
            {"id":"D","action":{"text":{"_0":"hi","enter":true}},"span":2},
            {"id":"E","action":{"sequence":{"_0":[{"key":{"_0":{"mods":0,"key":"Escape"}}},{"wait":{"_0":90}}]}}},
            {"id":"F","action":{"nextTab":{}}},{"id":"G","action":{"blurt":{"_0":"cards"}}},{"id":"H","action":{"system":{"_0":"spaceLeft"}}}]}]}"""
        val d = assertNotNull(Deck.fromJson(json))
        val s = d.sections[0].slots
        assertEquals(KeyAction.Chord(RemoteChord(W, "C"), false), s[0].action)
        assertEquals(KeyAction.Arrows, s[1].action)
        assertEquals(KeyAction.Sticky(W or S), s[2].action)
        assertEquals(KeyAction.Text("hi", true), s[3].action)
        assertEquals(2, s[3].span)
        assertEquals(KeyAction.Sequence(listOf(RemoteStep.Key(RemoteChord(0, "Escape")), RemoteStep.Wait(90))), s[4].action)
        assertEquals(KeyAction.NextTab, s[5].action)
        assertEquals(KeyAction.Blurt(RemoteBlurtCommand.CARDS), s[6].action)
        assertEquals(KeyAction.System(RemoteSystemMove.SPACE_LEFT), s[7].action)
        assertEquals("⇧⌘", s[2].face())
        assertEquals("Win+Shift", s[2].face(RemoteHost.WINDOWS))
        assertEquals("Ctrl+Tab", s[5].keyName(RemoteHost.LINUX))
    }

    @Test fun everyChordIsAKeyTheHostKnows() {
        for (h in hosts) {
            val d = Deck.standard(h)
            for (s in Deck.catalogue(h).flatMap { it.slots } + d.dock + d.sections.flatMap { it.slots }) {
                val c = (s.action as? KeyAction.Chord)?.chord ?: continue
                assertTrue(c.key.isEmpty() && c.mods != 0 || RemoteKey.named(c.key) != null, "${c.key} on $h")
            }
        }
    }

    @Test fun macDefaults() {
        val d = Deck.standard(RemoteHost.MAC)
        assertEquals(listOf(RemoteChord(W, "C"), RemoteChord(W, "V"), RemoteChord(W, "X"), RemoteChord(W, "Z"), RemoteChord(W or S, "Z"), RemoteChord(W, "A")),
            chords(d, 0).map { it.chord })
        assertEquals(listOf(RemoteChord(W, "Tab") to true, RemoteChord(W, "`") to true, RemoteChord(W, "[") to false, RemoteChord(W, "]") to false,
            RemoteChord(C or S, "Tab") to true, RemoteChord(C, "Tab") to true), chords(d, 1).map { it.chord to it.cycle })
        assertEquals(listOf(RemoteChord(W, "F"), RemoteChord(W, "K"), RemoteChord(W, "Space"), RemoteChord(C, "C"), RemoteChord(W, "T"), RemoteChord(W, "W")),
            chords(d, 2).map { it.chord })
        assertEquals(listOf(C, A, W, S), d.dock.take(4).map { (it.action as KeyAction.Sticky).mods })
        assertEquals(listOf("⌃", "⌥", "⌘", "⇧"), d.dock.take(4).map { it.face(RemoteHost.MAC) })
        assertEquals(listOf("Tab", "Escape", "Delete", "Return", "Space"), d.dock.drop(4).map { (it.action as KeyAction.Chord).chord.key })
        assertEquals(RemoteBlurtCommand.entries.take(6), d.sections[0].slots.drop(18).map { (it.action as KeyAction.Blurt).command })
    }

    @Test fun windowsDefaults() {
        val h = RemoteHost.WINDOWS
        val d = Deck.standard(h)
        assertEquals(listOf(RemoteChord(C, "C"), RemoteChord(C, "V"), RemoteChord(C, "X"), RemoteChord(C, "Z"), RemoteChord(C, "Y"), RemoteChord(C, "A")),
            chords(d, 0).map { it.chord })
        assertEquals(listOf(RemoteChord(A, "Tab") to true, RemoteChord(W, "Tab") to false, RemoteChord(A, "Left") to false, RemoteChord(A, "Right") to false,
            RemoteChord(C or S, "Tab") to true, RemoteChord(C, "Tab") to true), chords(d, 1).map { it.chord to it.cycle })
        assertEquals(listOf(RemoteChord(C, "F"), RemoteChord(C, "K"), RemoteChord(W, ""), RemoteChord(C or S, "C"), RemoteChord(C, "T"), RemoteChord(C, "W")),
            chords(d, 2).map { it.chord })
        assertEquals("Start", d.sections[0].slots[14].hint)
        assertEquals(listOf("Ctrl", "Win", "Alt", "Shift"), d.dock.take(4).map { it.face(h) })
        val more = d.sections[3].slots.mapNotNull { (it.action as? KeyAction.Chord)?.chord }
        for (c in listOf(RemoteChord(W, "D"), RemoteChord(W, "E"), RemoteChord(W, "L"), RemoteChord(A, "F4"), RemoteChord(C or S, "Escape"), RemoteChord(W or S, "S"),
            RemoteChord(0, "F1"), RemoteChord(0, "ForwardDelete"))) assertTrue(more.contains(c), c.label(h))
        assertEquals(Deck.standard(RemoteHost.MAC).sections[1].slots.map { it.action }, d.sections[1].slots.map { it.action }, "字母 is the same everywhere")
        assertEquals(Deck.standard(RemoteHost.MAC).sections[2].slots.map { it.action }, d.sections[2].slots.map { it.action }, "and 符号")
    }

    @Test fun linuxDefaults() {
        val h = RemoteHost.LINUX
        val d = Deck.standard(h)
        assertEquals(RemoteChord(C or S, "Z"), chords(d, 0)[4].chord, "redo")
        assertEquals(listOf(RemoteChord(A, "Tab") to true, RemoteChord(A, "`") to true, RemoteChord(A, "Left") to false, RemoteChord(A, "Right") to false,
            RemoteChord(C or S, "Tab") to true, RemoteChord(C, "Tab") to true), chords(d, 1).map { it.chord to it.cycle })
        assertEquals(RemoteChord(W, ""), chords(d, 2)[2].chord)
        assertEquals("Activities", d.sections[0].slots[14].hint)
        assertEquals("Super", d.sections[0].slots[14].face(h))
        assertEquals(listOf("Ctrl", "Super", "Alt", "Shift"), d.dock.take(4).map { it.face(h) })
        val more = d.sections[3].slots.mapNotNull { (it.action as? KeyAction.Chord)?.chord }
        for (c in listOf(RemoteChord(W, "D"), RemoteChord(W, "L"), RemoteChord(A, "F4"))) assertTrue(more.contains(c), c.label(h))
        assertTrue(!more.contains(RemoteChord(C or S, "Escape")), "Task Manager is Windows'")
    }
}
