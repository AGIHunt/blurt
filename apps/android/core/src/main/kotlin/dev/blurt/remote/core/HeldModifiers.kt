// ⌘ ⇧ ⌥ ⌃ (Ctrl, Win, Alt, Shift) as keys: tapped for the next one, tapped twice locked, and held like on any keyboard while another key is
// pressed or the pad is touched (port of Keys/Sticky.swift). AltGr, which no modifier bit stands for, the same by name. What the computer
// is told goes out through `tell` and `tellAltGr`.
package dev.blurt.remote.core

class HeldModifiers(private val tell: (Int) -> Unit, private val tellAltGr: (Boolean) -> Unit, private val press: (Int) -> Unit) {
    var once = 0
        private set
    var locked = 0
        private set
    /** under a finger now; on the computer only once something else is pressed with it (`chord`) */
    private var down = 0
    var chord = 0
        private set
    var altGrOnce = false
        private set
    var altGrLocked = false
        private set
    private var altGrDown = false
    private var altGrAt = 0.0
    private val pressedAt = HashMap<Int, Double>()
    private var altGrChord = false
    private var altGrSent = false
    private var lastTap: Pair<Int, Double>? = null
    private var lastAltGrTap: Double? = null
    val listeners = mutableListOf<() -> Unit>()
    /** keys under a finger that act as it lifts: fingers rarely lift together, and Ctrl gone a moment before the C must not make it a plain C */
    private val waiting = LinkedHashMap<Any, () -> Unit>()
    fun wait(o: Any, act: () -> Unit) { waiting[o] = act }
    fun done(o: Any) { waiting.remove(o) }
    private fun beforeLetGo() = waiting.values.toList().forEach { it() }

    val held: Int get() = once or locked or chord
    val altGr: Boolean get() = altGrOnce || altGrLocked || altGrChord

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

    /** A finger is on the key. Nothing goes to the computer yet: it may be a tap. */
    fun press(m: Int, now: Double) { down = down or m; pressedAt[m] = now }

    /** A key that landed at `began` acts now. A modifier that landed with it, in the same instant but told of after, is held for it; one that
     *  came later is for what comes next: typing fast, the Shift for the next letter lands before this one lifts. */
    fun engage(began: Double) {
        val together = pressedAt.entries.fold(0) { a, (m, t) -> if (t <= began + TOGETHER) a or m else a } and down
        if (altGrDown && !altGrChord && altGrAt <= began + TOGETHER) { altGrChord = true; altGrChanged() }
        if ((chord and together) == together) return
        chord = chord or together
        changed()
    }

    /** Something else is being pressed or touched: what's under a finger is held for it. */
    fun engage() {
        if (altGrDown && !altGrChord) { altGrChord = true; altGrChanged() }
        if ((chord and down) == down) return
        chord = chord or down
        changed()
    }

    /** The finger left the key. True: it was held with something, so it's no tap and no press of its own. */
    fun lift(m: Int): Boolean {
        down = down and m.inv()
        if ((chord and m) == 0) return false
        beforeLetGo()
        chord = chord and m.inv()
        lastTap = null
        changed()
        return true
    }

    /** How a modifier's press ends: held with something, that was it; a tap is for the next key; held alone, it's pressed on its own. */
    fun finish(m: Int, after: Double, now: Double, cancelled: Boolean) {
        if (lift(m) || cancelled) return
        if (after < FullTyping.TAP_TIME) tap(m, now) else alone(m)
    }

    /** The modifier by itself, down and up, and not held for the next key. */
    fun alone(m: Int) {
        // already held on the computer: letting it go is the press on its own. Another down and up would switch the input method back
        val was = (held and m) == m
        release(m)
        if (!was) press.invoke(m)
    }

    fun pressAltGr(now: Double) { altGrDown = true; altGrAt = now }

    fun finishAltGr(after: Double, now: Double, cancelled: Boolean) {
        altGrDown = false
        if (altGrChord) { beforeLetGo(); altGrChord = false; return altGrChanged() }
        if (cancelled || after >= FullTyping.TAP_TIME) return
        val l = lastAltGrTap
        if (altGrLocked) altGrLocked = false
        else if (l != null && now - l < 0.4) { altGrOnce = false; altGrLocked = true }
        else altGrOnce = !altGrOnce
        lastAltGrTap = now
        altGrChanged()
    }

    private fun altGrChanged() {
        if (altGr != altGrSent) { altGrSent = altGr; tellAltGr(altGr) }
        listeners.forEach { it() }
    }

    /** Pressed on its own instead: not held any more, once or locked. */
    fun release(m: Int) {
        if ((held and m) == 0) return
        once = once and m.inv()
        locked = locked and m.inv()
        chord = chord and m.inv()
        changed()
    }

    /** A key or a click went through: what was held for it is done. */
    fun used() {
        if (altGrOnce) { altGrOnce = false; altGrChanged() }
        if (once == 0) return
        once = 0
        changed()
    }

    /** Everything held, let go of: the Clear button, the keyboard put away, a turn. */
    fun letGo() {
        down = 0
        altGrDown = false
        if (altGr) { altGrOnce = false; altGrLocked = false; altGrChord = false; altGrChanged() }
        if (held == 0) return
        once = 0
        locked = 0
        chord = 0
        changed()
    }

    /** The session is over: forgotten here, and the computer has let go by itself. */
    fun clear() {
        down = 0
        altGrOnce = false
        altGrLocked = false
        altGrChord = false
        altGrDown = false
        altGrSent = false
        if (held == 0) return
        once = 0
        locked = 0
        chord = 0
        listeners.forEach { it() }
    }

    private fun changed() {
        tell(held)
        listeners.forEach { it() }
    }

    private companion object { const val TOGETHER = 0.06 }
}
