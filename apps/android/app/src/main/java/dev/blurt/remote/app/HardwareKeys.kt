// A keyboard on the tablet (or a phone) is the computer's keyboard: every key down and up goes across as that key, held for as long as it's
// held, so shortcuts, key repeat and a held Shift behave as on the computer's own keyboard. Keys keep their own names: Ctrl stays Ctrl (and
// ⌃ on a Mac), Alt is ⌥, the Windows / Command key is ⌘ on a Mac and Win / Super elsewhere. The phone's own keys (volume, back) stay the
// phone's.
package dev.blurt.remote.app

import android.view.InputDevice
import android.view.KeyEvent
import dev.blurt.remote.core.RemoteChord
import dev.blurt.remote.core.RemoteModifiers
import dev.blurt.remote.core.ToMac

object HardwareKeys {
    private val names: Map<Int, String> = buildMap {
        for (c in 'A'..'Z') put(KeyEvent.KEYCODE_A + (c - 'A'), c.toString())
        for (d in 0..9) put(KeyEvent.KEYCODE_0 + d, d.toString())
        for (f in 1..12) put(KeyEvent.KEYCODE_F1 + f - 1, "F$f")
        put(KeyEvent.KEYCODE_ENTER, "Return"); put(KeyEvent.KEYCODE_NUMPAD_ENTER, "Return")
        put(KeyEvent.KEYCODE_TAB, "Tab"); put(KeyEvent.KEYCODE_SPACE, "Space"); put(KeyEvent.KEYCODE_DEL, "Delete")
        put(KeyEvent.KEYCODE_FORWARD_DEL, "ForwardDelete"); put(KeyEvent.KEYCODE_ESCAPE, "Escape")
        put(KeyEvent.KEYCODE_DPAD_LEFT, "Left"); put(KeyEvent.KEYCODE_DPAD_RIGHT, "Right"); put(KeyEvent.KEYCODE_DPAD_UP, "Up"); put(KeyEvent.KEYCODE_DPAD_DOWN, "Down")
        put(KeyEvent.KEYCODE_MOVE_HOME, "Home"); put(KeyEvent.KEYCODE_MOVE_END, "End"); put(KeyEvent.KEYCODE_PAGE_UP, "PageUp"); put(KeyEvent.KEYCODE_PAGE_DOWN, "PageDown")
        put(KeyEvent.KEYCODE_MINUS, "-"); put(KeyEvent.KEYCODE_EQUALS, "="); put(KeyEvent.KEYCODE_LEFT_BRACKET, "["); put(KeyEvent.KEYCODE_RIGHT_BRACKET, "]")
        put(KeyEvent.KEYCODE_SEMICOLON, ";"); put(KeyEvent.KEYCODE_APOSTROPHE, "'"); put(KeyEvent.KEYCODE_COMMA, ","); put(KeyEvent.KEYCODE_PERIOD, ".")
        put(KeyEvent.KEYCODE_SLASH, "/"); put(KeyEvent.KEYCODE_BACKSLASH, "\\"); put(KeyEvent.KEYCODE_GRAVE, "`")
    }

    private val modifiers: Map<Int, Int> = mapOf(
        KeyEvent.KEYCODE_SHIFT_LEFT to RemoteModifiers.SHIFT, KeyEvent.KEYCODE_SHIFT_RIGHT to RemoteModifiers.SHIFT,
        KeyEvent.KEYCODE_CTRL_LEFT to RemoteModifiers.CONTROL, KeyEvent.KEYCODE_CTRL_RIGHT to RemoteModifiers.CONTROL,
        KeyEvent.KEYCODE_ALT_LEFT to RemoteModifiers.OPTION, KeyEvent.KEYCODE_ALT_RIGHT to RemoteModifiers.OPTION,
        KeyEvent.KEYCODE_META_LEFT to RemoteModifiers.COMMAND, KeyEvent.KEYCODE_META_RIGHT to RemoteModifiers.COMMAND,
    )

    /** The key name for a key code, or null for one that stays the phone's. */
    fun name(code: Int): String? = names[code]

    fun mods(meta: Int): Int {
        var m = 0
        if ((meta and KeyEvent.META_SHIFT_ON) != 0) m = m or RemoteModifiers.SHIFT
        if ((meta and KeyEvent.META_CTRL_ON) != 0) m = m or RemoteModifiers.CONTROL
        if ((meta and KeyEvent.META_ALT_ON) != 0) m = m or RemoteModifiers.OPTION
        if ((meta and KeyEvent.META_META_ON) != 0) m = m or RemoteModifiers.COMMAND
        return m
    }

    private fun physical(e: KeyEvent): Boolean {
        val d = e.device ?: return false
        return !d.isVirtual && (d.sources and InputDevice.SOURCE_KEYBOARD) == InputDevice.SOURCE_KEYBOARD && d.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC
    }

    /** True if it went to the computer. */
    fun handle(e: KeyEvent): Boolean {
        if (!physical(e)) return false
        val down = e.action == KeyEvent.ACTION_DOWN
        if (e.action != KeyEvent.ACTION_DOWN && e.action != KeyEvent.ACTION_UP) return false
        modifiers[e.keyCode]?.let { bit ->
            if (down && e.repeatCount > 0) return true
            Remote.link.send(ToMac.Key(RemoteChord(bit, ""), down))
            return true
        }
        val name = names[e.keyCode] ?: return false
        // the other modifiers held with it; the key's own bit isn't one of them
        Remote.link.send(ToMac.Key(RemoteChord(mods(e.metaState), name), down))
        return true
    }
}
