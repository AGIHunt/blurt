// ⌘ ⇧ ⌥ ⌃ (Win, Shift, Alt, Ctrl elsewhere) as keys you tap, since one thumb can't hold a chord: one tap holds it for the next key or click,
// two lock it until it's tapped off. Held a moment, the key is pressed on its own (KeyCell), for a lone ⇧ that switches an input method.
// The computer really holds them down, so ⌘-click and ⇧-arrows work everywhere. Port of Keys/Sticky.swift.
package dev.blurt.remote.app.keys

import dev.blurt.remote.app.Remote
import dev.blurt.remote.core.ToMac

class Sticky {
    var once = 0
        private set
    var locked = 0
        private set
    private var lastTap: Pair<Int, Double>? = null
    val listeners = mutableListOf<() -> Unit>()

    val held: Int get() = once or locked

    fun tap(m: Int, now: Double) {
        val l = lastTap
        when {
            (locked and m) == m -> locked = locked and m.inv()
            l != null && l.first == m && now - l.second < 0.4 -> { once = once and m.inv(); locked = locked or m }
            (once and m) == m -> once = once and m.inv()
            else -> once = once or m
        }
        lastTap = m to now
        changed()
    }

    /** Pressed on its own instead: not held any more, once or locked. */
    fun release(m: Int) {
        if ((held and m) == 0) return
        once = once and m.inv()
        locked = locked and m.inv()
        changed()
    }

    /** A key or a click went through: what was held for it is done. */
    fun used() {
        if (once == 0) return
        once = 0
        changed()
    }

    fun clear() {
        if (held == 0) return
        once = 0
        locked = 0
        listeners.forEach { it() }
    }

    private fun changed() {
        Remote.link.send(ToMac.Mods(held))
        listeners.forEach { it() }
    }
}
