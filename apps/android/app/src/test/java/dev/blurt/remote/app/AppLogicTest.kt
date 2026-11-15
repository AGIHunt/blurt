package dev.blurt.remote.app

import android.view.KeyEvent
import dev.blurt.remote.app.keys.Face
import dev.blurt.remote.app.keys.Icons
import dev.blurt.remote.app.keys.SymbolCodes
import dev.blurt.remote.app.pad.ScreenStream
import dev.blurt.remote.core.Deck
import dev.blurt.remote.core.RemoteHost
import dev.blurt.remote.core.RemoteModifiers
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppLogicTest {
    @Test fun lengthPrefixesBecomeStartCodes() {
        val two = byteArrayOf(0, 0, 0, 2, 0x65, 0x11, 0, 0, 0, 1, 0x41)
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x65, 0x11, 0, 0, 0, 1, 0x41), ScreenStream.startCodes(two))
    }

    @Test fun hardwareKeysKeepTheirNames() {
        assertEquals("C", HardwareKeys.name(KeyEvent.KEYCODE_C))
        assertEquals("Return", HardwareKeys.name(KeyEvent.KEYCODE_ENTER))
        assertEquals("F12", HardwareKeys.name(KeyEvent.KEYCODE_F12))
        assertEquals("Left", HardwareKeys.name(KeyEvent.KEYCODE_DPAD_LEFT))
        assertNull("the phone's own keys stay the phone's", HardwareKeys.name(KeyEvent.KEYCODE_VOLUME_UP))
        // Ctrl stays Ctrl, the Windows / Command key is the command bit
        assertEquals(RemoteModifiers.CONTROL or RemoteModifiers.SHIFT, HardwareKeys.mods(KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON))
        assertEquals(RemoteModifiers.COMMAND, HardwareKeys.mods(KeyEvent.META_META_ON))
        assertEquals(RemoteModifiers.OPTION, HardwareKeys.mods(KeyEvent.META_ALT_ON))
    }

    @Test fun everyFaceOfEveryDeckHasASymbol() {
        for (host in RemoteHost.entries) {
            val slots = Deck.standard(host).let { d -> d.dock + d.sections.flatMap { it.slots } } + Deck.catalogue(host).flatMap { it.slots }
            for (s in slots) {
                val f = s.face(host)
                if (f.startsWith("sf:")) assertNotNull("no symbol for $f (${s.title(host)} on $host)", Icons.glyph(f))
            }
        }
        for (n in Deck.icons) assertNotNull("no symbol for the picker's $n", Icons.glyph("sf:$n"))
        for (n in Icons.ui) assertTrue("not in the font: $n", n in SymbolCodes.codes)
    }

    @Test fun shortTextReadsLarger() {
        assertTrue(Face.textSize("F1") > Face.textSize("PgUp"))
        assertTrue(Face.textSize("PgUp") > Face.textSize("Inline"))
        // a PC's modifiers read as one row
        assertEquals(Face.textSize("Ctrl"), Face.textSize("Shift"))
        assertEquals(Face.textSize("Win"), Face.textSize("Alt"))
    }

    /** The pad's card (pad/StatusCard.kt): every line it can say is there in English and Chinese, plainly, with the name where it belongs. */
    @Test fun theCardsWordsAreInBothLanguages() {
        fun strings(dir: String) = Regex("<string name=\"([a-z_0-9]+)\">(.*?)</string>").findAll(java.io.File("src/main/res/$dir/strings.xml").readText())
            .associate { it.groupValues[1] to it.groupValues[2] }
        val en = strings("values")
        val zh = strings("values-b+zh+Hans")
        val named = setOf("connecting_to", "status_reconnecting", "status_cant_reach", "status_cant_control", "status_forgotten", "connected_to")
        val plain = setOf("status_check_network", "status_check_awake", "s_forgotten", "status_other_phone", "status_take_over", "status_pair_first",
            "status_unpaired", "status_waiting_title", "status_pair_failed", "status_accessibility", "status_control", "status_cant_show_screen",
            "status_screen_permission", "status_screen_permission_pc", "status_screen_off", "retry", "scan_code", "try_another", "the_computer")
        for (k in named + plain) for (t in listOf(en, zh)) {
            val v = t[k]
            assertNotNull(k, v)
            assertTrue(k, v!!.isNotBlank() && !v.contains('!') && !v.contains('！'))
            assertEquals(k, k in named, v.contains("%1\$s"))
        }
        // the same network is needed only without a relay: the line says both, the relay by its name
        assertTrue(en["status_check_network"]!!.contains("relay") && zh["status_check_network"]!!.contains("中转"))
    }
}
