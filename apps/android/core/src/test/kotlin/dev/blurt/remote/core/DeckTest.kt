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
            assertEquals(KeyAction.Chord(RemoteChord(0, "Return")), d.dock.last().action, "return by the talk key")
            assertEquals(Deck.spaceBar.action, d.dock[5].action, "space after tab")
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
        assertEquals(listOf("Tab", "Space", "Escape", "Delete", "Return"), d.dock.drop(4).map { (it.action as KeyAction.Chord).chord.key })
        val last = d.sections[0].slots.drop(18).map { it.action }
        assertEquals(listOf(RemoteBlurtCommand.SNAP, RemoteBlurtCommand.COPY_TEXT, RemoteBlurtCommand.TRANSLATE, RemoteBlurtCommand.CARDS).map { KeyAction.Blurt(it) },
            last.take(4))
        assertEquals(listOf(KeyAction.Chord(RemoteChord(W, "R")), KeyAction.Chord(RemoteChord(S, "Tab"))), last.drop(4))
        assertEquals(listOf("sf:arrow.clockwise", "sf:arrow.left.to.line"), d.sections[0].slots.drop(22).map { it.face() })
        assertEquals(listOf(RemoteBlurtCommand.RECORD, RemoteBlurtCommand.VOICE_NOTE).map { KeyAction.Blurt(it) }, d.sections[3].slots.takeLast(2).map { it.action },
            "Record and Voice Note at the end of More")
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
        assertEquals(listOf("Tab", "Space", "Escape", "Delete", "Return"), d.dock.drop(4).map { (it.action as KeyAction.Chord).chord.key })
        assertEquals(listOf(KeyAction.Chord(RemoteChord(C, "R")), KeyAction.Chord(RemoteChord(S, "Tab"))), d.sections[0].slots.drop(22).map { it.action })
        val more = d.sections[3].slots.mapNotNull { (it.action as? KeyAction.Chord)?.chord }
        for (c in listOf(RemoteChord(W, "D"), RemoteChord(W, "E"), RemoteChord(W, "L"), RemoteChord(A, "F4"), RemoteChord(C or S, "Escape"),
            RemoteChord(0, "F1"), RemoteChord(0, "ForwardDelete"))) assertTrue(more.contains(c), c.label(h))
        val snip = KeyAction.Chord(RemoteChord(W or S, "S"))
        assertTrue(d.sections.flatMap { it.slots }.none { it.action == snip }, "Snip only in the picker: Snap does it")
        assertTrue(Deck.catalogue(h).flatMap { it.slots }.any { it.action == snip })
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

    // MARK: brought up to date

    /** A deck as stored by the version before: dock with space last, Record and Voice Note on Main, More without them. */
    private fun old(h: RemoteHost): Deck {
        val d = Deck.standard(h)
        val dock = d.dock.take(5) + d.dock.drop(6) + d.dock[5]
        val blurt = { c: RemoteBlurtCommand -> d.sections.flatMap { it.slots }.first { it.action == KeyAction.Blurt(c) } }
        val main = d.sections[0].slots.take(18) + listOf(RemoteBlurtCommand.SNAP, RemoteBlurtCommand.RECORD, RemoteBlurtCommand.VOICE_NOTE,
            RemoteBlurtCommand.COPY_TEXT, RemoteBlurtCommand.TRANSLATE, RemoteBlurtCommand.CARDS).map(blurt)
        // as it shipped: F-keys and the rest, then the host's system keys (Snip too on Windows)
        val system = Deck.catalogue(h).first { it.group == "Switch" }.slots.drop(5).let { if (h == RemoteHost.MAC) it else it.dropLast(4) }
        val more = d.sections[3].slots.take(17) + system
        return Deck(dock, listOf(d.sections[0].copy(slots = main), d.sections[1], d.sections[2], d.sections[3].copy(slots = more)))
    }

    @Test fun anUntouchedOldDeckGetsTheNewLayout() {
        for (h in hosts) {
            val o = old(h)
            val d = Deck.restore(o.toJson(), h)
            val n = Deck.standard(h)
            assertEquals(n.dock.map { it.action }, d.dock.map { it.action }, "the new dock order on $h")
            assertEquals(o.dock.map { it.id }.toSet(), d.dock.map { it.id }.toSet(), "the same keys, moved")
            assertEquals(n.sections.map { s -> s.slots.map { it.action } }, d.sections.map { s -> s.slots.map { it.action } }, "Main and More as they ship now on $h")
            val rec = o.sections[0].slots.first { it.action == KeyAction.Blurt(RemoteBlurtCommand.RECORD) }
            assertEquals(rec.id, d.sections[3].slots[d.sections[3].slots.size - 2].id, "Record itself moved to More")
            if (h == RemoteHost.WINDOWS) assertEquals(o.sections[3].slots.size - 1 + 2, d.sections[3].slots.size, "Snip off, Record and Voice Note on")
            assertEquals(d, Deck.restore(d.toJson(), h), "once")
        }
    }

    private fun n(h: RemoteHost) = Deck.standard(h)

    @Test fun anEditedDeckIsLeftAlone() {
        for (h in hosts) {
            val o = old(h)
            // the dock with two keys swapped, Main with a key taken off
            val dock = o.dock.toMutableList().also { val t = it[0]; it[0] = it[1]; it[1] = t }
            val edited = o.copy(dock = dock).let { it.remove(it.sections[0].slots[0].id) }
            val d = Deck.restore(edited.toJson(), h)
            assertEquals(edited.dock, d.dock, "a dock the user changed keeps its order")
            assertEquals(edited.sections[0], d.sections[0], "and so does a Main the user changed")
            assertEquals(edited.sections[3], d.sections[3], "with Main changed, More too stays: Record and Voice Note are still on Main")
        }
        // a More the user changed keeps what it has
        val o = old(RemoteHost.MAC)
        val more = o.sections[3].let { it.copy(slots = it.slots.drop(1)) }
        val d = Deck.restore(o.copy(sections = o.sections.mapIndexed { i, s -> if (i == 3) more else s }).toJson(), RemoteHost.MAC)
        assertEquals(more, d.sections[3])
        // a deck already as it ships now: nothing changes
        val now = Deck.standard(RemoteHost.LINUX)
        assertEquals(now, Deck.restore(now.toJson(), RemoteHost.LINUX))
    }

    @Test fun templates() {
        for (h in hosts) {
            assertTrue(Deck.template(SectionTemplate.EMPTY, h).isEmpty())
            for (t in SectionTemplate.entries.drop(1)) {
                val keys = Deck.template(t, h)
                assertTrue(keys.size in 6..Deck.COLUMNS * visibleRows, "$t on $h")
                assertEquals(keys.size, keys.map { it.action }.toSet().size, "no key twice in $t on $h")
                for (s in keys) {
                    val c = (s.action as KeyAction.Chord).chord
                    assertTrue(RemoteKey.named(c.key) != null, "${c.key} in $t on $h")
                    assertTrue(s.face(h).isNotEmpty(), s.title(h))
                }
            }
        }
        val mac = Deck.template(SectionTemplate.WRITING, RemoteHost.MAC).map { (it.action as KeyAction.Chord).chord }
        assertEquals(listOf(RemoteChord(W or S, "V"), RemoteChord(A, "Delete"), RemoteChord(W, "S"), RemoteChord(W, "B"), RemoteChord(W, "I"), RemoteChord(W, "U")), mac)
        val pc = Deck.template(SectionTemplate.WRITING, RemoteHost.LINUX).map { (it.action as KeyAction.Chord).chord }
        assertEquals(listOf(RemoteChord(C or S, "V"), RemoteChord(C, "Delete"), RemoteChord(C, "S"), RemoteChord(C, "B"), RemoteChord(C, "I"), RemoteChord(C, "U")), pc)
        assertEquals("⌘B", Deck.template(SectionTemplate.WRITING, RemoteHost.MAC)[3].face(), "no icon: the key's own name")
        val winP = KeyAction.Chord(RemoteChord(W, "P"))
        assertTrue(Deck.template(SectionTemplate.PRESENTING, RemoteHost.WINDOWS).any { it.action == winP }, "Project on Windows")
        assertTrue(Deck.template(SectionTemplate.PRESENTING, RemoteHost.LINUX).none { it.action == winP }, "not on Linux")
        assertEquals(KeyAction.Chord(RemoteChord(W or A, "P")), Deck.template(SectionTemplate.PRESENTING, RemoteHost.MAC)[0].action)
        assertEquals(listOf(RemoteChord(A, "Left"), RemoteChord(A, "Right"), RemoteChord(C, "Return")),
            Deck.template(SectionTemplate.SPREADSHEET, RemoteHost.MAC).drop(3).map { (it.action as KeyAction.Chord).chord })
        assertEquals(listOf(RemoteChord(C, "PageUp"), RemoteChord(C, "PageDown"), RemoteChord(C, "Return")),
            Deck.template(SectionTemplate.SPREADSHEET, RemoteHost.WINDOWS).drop(3).map { (it.action as KeyAction.Chord).chord })
    }

    @Test fun aSectionGoesAfterTheOneItWasAddedFrom() {
        val d = Deck.standard().addSection("Writing", Deck.template(SectionTemplate.WRITING), after = 0)
        assertEquals("Writing", d.sections[1].name)
        assertEquals(6, d.sections[1].slots.size)
        assertEquals("Letters", d.sections[2].name)
        assertEquals("Mine", d.addSection("Mine").sections.last().name, "no place: the end")
    }
}
