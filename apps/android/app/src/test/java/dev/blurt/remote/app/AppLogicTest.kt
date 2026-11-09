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
    }
}
