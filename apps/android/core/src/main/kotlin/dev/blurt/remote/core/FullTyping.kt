// The computer keyboard's rules, without views: touches and time in, key presses out (port of Keys/FullTyping.swift).
//
//   a key acts as the finger lifts, so one that landed wrong can slide off and nothing happens. Another finger landing first sends it at
//   once and holds it until its own finger lifts: what two thumbs type fast keeps its order, and two keys held are two keys held
//   held still for HOLD_AFTER, it goes down on the computer and stays down, pressing on (FullKeys.repeats) as a real keyboard does
//   the arrows and ⌫ act as the finger lands
//   modifiers are Sticky's: tapped, for the next key; held while another is pressed, for that; held alone and lifted, on their own
//   fn the same, here: it's the phone's own
package dev.blurt.remote.core

sealed class FullOutput {
    data class Press(val name: String) : FullOutput()
    data class Hold(val name: String, val down: Boolean) : FullOutput()
    /** held, and down again: the computer's own repeat */
    data class Again(val name: String) : FullOutput()
    data class ModifierDown(val mods: Int) : FullOutput()
    data class ModifierUp(val mods: Int, val after: Double, val cancelled: Boolean) : FullOutput()
    data object AltGrDown : FullOutput()
    data class AltGrUp(val after: Double, val cancelled: Boolean) : FullOutput()
    data object Engage : FullOutput()
    /** the same for a key that landed then: what landed in the same instant, not what came after it */
    data class EngageWith(val began: Double) : FullOutput()
    data object Used : FullOutput()
    data object FnChanged : FullOutput()
    data object Tick : FullOutput()
    data object Grab : FullOutput()
}

class FullTyping {
    private enum class State { PENDING, HELD, ACTING, MODIFIER, FN, DONE }
    private data class Finger(val key: FullKey, val name: String?, val at: Double, var state: State, var next: Double? = null, var slid: Boolean = false)

    private val fingers = LinkedHashMap<Int, Finger>()
    private var newest: Int? = null
    /** what's held on the computer, as it is when asked */
    var mods: () -> Int = { 0 }

    var fnOnce = false
        private set
    var fnLocked = false
        private set
    private var fnUsed = false
    private var lastFnTap: Double? = null
    val fn: Boolean get() = fnOnce || fnLocked || fingers.values.any { it.state == State.FN }
    val isEmpty: Boolean get() = fingers.isEmpty()
    val needsTicks: Boolean get() = fingers.values.any { it.state == State.PENDING || it.next != null }
    val pressed: List<FullKey> get() = fingers.values.filter { !it.slid }.map { it.key }

    fun began(id: Int, key: FullKey, now: Double): List<FullOutput> {
        when (val k = key.kind) {
            is FullKind.Modifier -> { fingers[id] = Finger(key, null, now, State.MODIFIER); return listOf(FullOutput.ModifierDown(k.mods), FullOutput.Tick) }
            FullKind.AltGr -> { fingers[id] = Finger(key, null, now, State.MODIFIER); return listOf(FullOutput.AltGrDown, FullOutput.Tick) }
            FullKind.Fn -> { fnUsed = false; fingers[id] = Finger(key, null, now, State.FN); return listOf(FullOutput.FnChanged, FullOutput.Tick) }
            FullKind.Talk -> return emptyList()
            else -> {}
        }
        val out = mutableListOf<FullOutput>()
        out += flush()
        out += FullOutput.Engage
        for (f in fingers.values) f.next = null      // only the last key down repeats
        val on = fn
        val name = key.name?.let { if (on) key.fn ?: it else it }
        if (on) fnUsed = true
        newest = id
        if (name != null && FullKeys.atOnce(name)) {
            fingers[id] = Finger(key, name, now, State.ACTING, if (FullKeys.repeats(name, mods())) now + REPEAT_AFTER else null)
            out += listOf(FullOutput.Press(name), FullOutput.Tick)
            out += spent()
        } else {
            fingers[id] = Finger(key, name, now, State.PENDING)
            out += FullOutput.Tick
        }
        return out
    }

    /** Who is still down and hasn't acted goes now, and is held from here, in the order they landed: another key is landing, or the modifier
     *  that was held for it is letting go. */
    fun flush(): List<FullOutput> {
        val out = mutableListOf<FullOutput>()
        for (f in fingers.values) {
            if (f.state != State.PENDING || f.slid || f.name == null) continue
            out += listOf(FullOutput.EngageWith(f.at), FullOutput.Hold(f.name, true))
            out += spent()
            f.state = State.HELD
        }
        return out
    }

    /** The finger has slid off its key. */
    fun moved(id: Int, inside: Boolean): List<FullOutput> {
        val f = fingers[id] ?: return emptyList()
        if (inside || f.slid) return emptyList()
        f.slid = true
        f.next = null
        val out = if (f.state == State.HELD && f.name != null) listOf(FullOutput.Hold(f.name, false)) else emptyList()
        if (f.state == State.HELD || f.state == State.PENDING || f.state == State.ACTING) f.state = State.DONE
        return out
    }

    fun ended(id: Int, now: Double): List<FullOutput> {
        val f = fingers.remove(id) ?: return emptyList()
        return when (f.state) {
            State.PENDING -> listOf(FullOutput.EngageWith(f.at), FullOutput.Press(f.name ?: INPUT_SOURCE)) + spent()
            State.HELD -> f.name?.let { listOf(FullOutput.Hold(it, false)) } ?: emptyList()
            State.MODIFIER -> listOf(up(f, now - f.at, f.slid))
            State.FN -> {
                if (!f.slid && !fnUsed) {
                    val l = lastFnTap
                    if (fnLocked) fnLocked = false
                    else if (l != null && now - l < 0.4) { fnOnce = false; fnLocked = true }
                    else fnOnce = !fnOnce
                    lastFnTap = now
                }
                listOf(FullOutput.FnChanged)
            }
            else -> emptyList()
        }
    }

    private fun up(f: Finger, after: Double, cancelled: Boolean): FullOutput =
        (f.key.kind as? FullKind.Modifier)?.let { FullOutput.ModifierUp(it.mods, after, cancelled) } ?: FullOutput.AltGrUp(after, cancelled)

    /** Time passing, called while `needsTicks`. */
    fun tick(now: Double): List<FullOutput> {
        val out = mutableListOf<FullOutput>()
        for ((i, f) in fingers) {
            val n = f.name ?: continue
            val t = f.next
            if (f.state == State.PENDING && now - f.at >= HOLD_AFTER && FullKeys.repeats(n, mods())) {
                out += listOf(FullOutput.EngageWith(f.at), FullOutput.Hold(n, true), FullOutput.Grab)
                out += spent()
                f.state = State.HELD
                f.next = if (i == newest) now + REPEAT_EVERY else null
            } else if (t != null && now >= t) {
                out += if (f.state == State.HELD) FullOutput.Again(n) else FullOutput.Press(n)
                f.next = now + REPEAT_EVERY
            }
        }
        return out
    }

    /** Put away, turned, the app left: nothing stays down. */
    fun letGo(): List<FullOutput> {
        val out = fingers.values.mapNotNull { f ->
            when (f.state) {
                State.HELD -> f.name?.let { FullOutput.Hold(it, false) }
                State.MODIFIER -> up(f, 0.0, true)
                else -> null
            }
        }
        fingers.clear()
        fnOnce = false
        fnLocked = false
        return out + FullOutput.FnChanged
    }

    fun cancelled(id: Int): List<FullOutput> {
        val out = moved(id, false)
        val f = fingers.remove(id) ?: return out
        return if (f.state == State.MODIFIER) out + up(f, 0.0, true) else out
    }

    private fun spent(): List<FullOutput> {
        if (!fnOnce) return listOf(FullOutput.Used)
        fnOnce = false
        return listOf(FullOutput.Used, FullOutput.FnChanged)
    }

    companion object {
        const val HOLD_AFTER = 0.4
        const val REPEAT_EVERY = 0.05
        const val REPEAT_AFTER = 0.35
        const val TAP_TIME = 0.45
        /** stands for ⌃Space, the Mac's own way to the next input source */
        const val INPUT_SOURCE = "⌃Space"
    }
}
