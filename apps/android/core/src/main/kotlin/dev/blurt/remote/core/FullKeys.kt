// The computer keyboard (docs/design/remote.md §Computer keyboard; port of Model/FullKeys.swift): the keys of a real one, pressed as a real
// one's are. Which keys, in which rows and how wide, as plain data for the width there is. US positions, as the wire's key names are; what
// each is labelled can come from the computer (RemoteLegends).
package dev.blurt.remote.core

sealed class FullKind {
    /** a key by its wire name */
    data class Key(val name: String) : FullKind()
    data class Modifier(val mods: Int) : FullKind()
    /** the right Alt of a PC's keyboard, which types the third character on a key */
    data object AltGr : FullKind()
    /** the F-keys and what else has no key of its own */
    data object Fn : FullKind()
    /** the next input source, on a Mac (⌃Space) */
    data object InputSource : FullKind()
    /** where the talk key goes */
    data object Talk : FullKind()
}

/** `fn`: the wire name it presses with fn. */
data class FullKey(val kind: FullKind, val units: Float = 1f, val fn: String? = null) {
    constructor(name: String, units: Float = 1f, fn: String? = null) : this(FullKind.Key(name), units, fn)
    val name: String? get() = (kind as? FullKind.Key)?.name
}

/** How many keys across, by the room there is. */
enum class FullTier(val across: Int) {
    /** a phone upright: the dock below it has the modifiers, space and what ends things */
    TEN(10),
    /** a phone on its side: the thumb's column has esc, the arrows, ⌫ and ↩ */
    THIRTEEN(13),
    /** a small tablet: a whole keyboard, with Home and the like on fn */
    FIFTEEN(15),
    /** and with room, a column for them */
    SIXTEEN(16);

    companion object {
        const val GAP = 5f
        /** a whole keyboard's keys are at least this wide, or it has a column fewer */
        const val COMFORTABLE = 44f
        fun unit(width: Float, t: FullTier) = (width - GAP * (t.across - 1)) / t.across
        fun big(width: Float) = if (unit(width, SIXTEEN) >= COMFORTABLE) SIXTEEN else FIFTEEN
    }
}

data class FullRect(val left: Float, val top: Float, val right: Float, val bottom: Float) {
    val width get() = right - left
    val height get() = bottom - top
}

object FullKeys {
    /** what ⇧ makes of the keys that aren't letters, on a US keyboard */
    val shifted = mapOf("`" to "~", "1" to "!", "2" to "@", "3" to "#", "4" to "$", "5" to "%", "6" to "^", "7" to "&", "8" to "*", "9" to "(", "0" to ")",
        "-" to "_", "=" to "+", "[" to "{", "]" to "}", "\\" to "|", ";" to ":", "'" to "\"", "," to "<", "." to ">", "/" to "?")

    private val digits = mapOf("1" to "F1", "2" to "F2", "3" to "F3", "4" to "F4", "5" to "F5", "6" to "F6", "7" to "F7", "8" to "F8", "9" to "F9", "0" to "F10",
        "-" to "F11", "=" to "F12")
    /** with no column or arrows to put them on */
    private val near = mapOf("`" to "Insert", "[" to "Home", "]" to "End", ";" to "PageUp", "'" to "PageDown", "\\" to "ForwardDelete")

    private fun chars(s: String, fn: Map<String, String> = emptyMap()) = s.map { FullKey(it.toString(), fn = fn[it.toString()]) }
    private fun mod(m: Int, units: Float = 1f) = FullKey(FullKind.Modifier(m), units)

    fun rows(t: FullTier, h: RemoteHost): List<List<FullKey>> {
        val mac = h == RemoteHost.MAC
        val ctrl = RemoteModifiers.CONTROL
        val alt = RemoteModifiers.OPTION
        val cmd = RemoteModifiers.COMMAND
        val shift = RemoteModifiers.SHIFT
        val pc = if (mac) emptyMap() else mapOf("P" to "PrintScreen", "B" to "Pause", "M" to "Menu")
        val caps: FullKind = if (mac) FullKind.InputSource else FullKind.Key("CapsLock")
        val small = near + digits + pc
        return when (t) {
            // a PC's AltGr has no other place here; Caps Lock goes on fn
            FullTier.TEN -> (if (mac) small else small + ("C" to "CapsLock")).let { f ->
                listOf(listOf(FullKey(FullKind.Fn)) + chars("`-=[]\\'", f) + listOf(FullKey("ForwardDelete"), FullKey(if (mac) caps else FullKind.AltGr)),
                    chars("1234567890", f), chars("QWERTYUIOP", f), chars("ASDFGHJKL;", f), chars("ZXCVBNM,./", f))
            }
            FullTier.THIRTEEN -> {
                val left = if (mac) listOf(mod(ctrl), mod(alt), mod(cmd, 1.5f)) else listOf(mod(ctrl), mod(cmd), mod(alt, 1.5f))
                val right = if (mac) listOf(mod(cmd, 1.5f), mod(alt), FullKey(FullKind.InputSource))
                    else listOf(FullKey(FullKind.AltGr, 1.5f), mod(ctrl), FullKey("CapsLock"))
                listOf(chars("`1234567890-=", small), listOf(FullKey("Tab")) + chars("QWERTYUIOP[]", small),
                    listOf(FullKey(FullKind.Fn)) + chars("ASDFGHJKL;'\\", small),
                    listOf(mod(shift, 1.5f)) + chars("ZXCVBNM,./", small) + listOf(mod(shift, 1.5f)),
                    left + listOf(FullKey("Space", 6f)) + right)
            }
            FullTier.FIFTEEN, FullTier.SIXTEEN -> {
                val wide = t == FullTier.SIXTEEN
                fun nav(n: String) = if (wide) listOf(FullKey(n)) else emptyList()
                val f12 = (1..12).map { FullKey("F$it", fn = if (it <= 8) "F${it + 12}" else null) }
                val left = if (mac) listOf(mod(ctrl, 1.25f), mod(alt, 1.25f), mod(cmd, 1.5f)) else listOf(mod(ctrl, 1.25f), mod(cmd, 1.25f), mod(alt, 1.5f))
                val right = listOf(if (mac) mod(cmd, 1.5f) else FullKey(FullKind.AltGr, 1.5f), FullKey(FullKind.Fn, 1.5f))
                listOf(
                    listOf(FullKey("Escape")) + f12 + listOf(FullKey("ForwardDelete", fn = "Insert"), FullKey(FullKind.Talk, if (wide) 2f else 1f)),
                    chars("`1234567890-=") + listOf(FullKey("Delete", 2f, "ForwardDelete")) + nav("Home"),
                    listOf(FullKey("Tab", 1.5f)) + chars("QWERTYUIOP[]", pc) + listOf(FullKey("\\", 1.5f)) + nav("PageUp"),
                    listOf(FullKey(caps, 1.75f)) + chars("ASDFGHJKL;'") + listOf(FullKey("Return", 2.25f)) + nav("PageDown"),
                    listOf(mod(shift, 2.25f)) + chars("ZXCVBNM,./", pc) + listOf(mod(shift, 1.75f), FullKey("Up", fn = "PageUp")) + nav("End"),
                    left + listOf(FullKey("Space", if (wide) 6f else 5f)) + right +
                        listOf(FullKey("Left", fn = "Home"), FullKey("Down", fn = "PageDown"), FullKey("Right", fn = "End")),
                )
            }
        }
    }

    /** Where each key goes: `heights` for each row, dp. */
    fun place(rows: List<List<FullKey>>, frame: FullRect, tier: FullTier, heights: List<Float>): List<Pair<FullKey, FullRect>> {
        val gap = FullTier.GAP
        val unit = FullTier.unit(frame.width, tier)
        val out = mutableListOf<Pair<FullKey, FullRect>>()
        var y = frame.top
        rows.forEachIndexed { r, row ->
            val h = heights.getOrElse(r) { heights.lastOrNull() ?: 44f }
            var at = 0f
            for (k in row) {
                val x = frame.left + at * (unit + gap)
                out += k to FullRect(x, y, x + k.units * unit + (k.units - 1) * gap, y + h)
                at += k.units
            }
            y += h + gap
        }
        return out
    }

    fun height(heights: List<Float>) = heights.sum() + FullTier.GAP * maxOf(0, heights.size - 1)

    private val moves = setOf("Left", "Right", "Up", "Down", "Delete", "ForwardDelete", "PageUp", "PageDown")

    /** Keys held go on pressing. Nothing destructive, and nothing with ⌘ or Ctrl but zooming and moving (docs/design/remote.md §Keys). */
    fun repeats(name: String, mods: Int): Boolean {
        if (mods and (RemoteModifiers.COMMAND or RemoteModifiers.CONTROL) != 0) return name == "=" || name == "-" || (name in moves && !name.endsWith("Delete"))
        return name.length == 1 || name == "Space" || name in moves
    }

    /** These act as the finger lands, as on the pages. */
    fun atOnce(name: String) = name in setOf("Left", "Right", "Up", "Down", "Delete", "ForwardDelete")
}

/** What's printed on a key. */
data class FullLabel(val main: String, val second: String? = null, val faint: Boolean = false, val spoken: String = main) {
    companion object {
        fun of(k: FullKey, host: RemoteHost, fn: Boolean, shift: Boolean, altGr: Boolean, legends: RemoteLegends?): FullLabel = when (val kind = k.kind) {
            is FullKind.Modifier -> FullLabel(RemoteModifiers.glyphs(kind.mods, host))
            FullKind.AltGr -> FullLabel("AltGr")
            FullKind.Fn -> FullLabel("fn")
            FullKind.InputSource -> FullLabel("⌃␣")
            FullKind.Talk -> FullLabel("")
            is FullKind.Key -> if (!fn) named(kind.name, host, shift, altGr, legends, false)
                else k.fn?.let { named(it, host, false, false, null, false) } ?: named(kind.name, host, shift, altGr, legends, true)
        }

        private val moves = mapOf("Home" to "Home", "End" to "End", "PageUp" to "PgUp", "PageDown" to "PgDn")

        private fun named(name: String, host: RemoteHost, shift: Boolean, altGr: Boolean, legends: RemoteLegends?, faint: Boolean): FullLabel {
            if (name.length != 1) {
                val pc = host != RemoteHost.MAC
                val w = moves[name] ?: if (name == "Delete" && pc) "⌫" else if (name == "Return" && pc) "Enter" else if (name == "Space") ""
                    else RemoteKey.named(name)?.label(host) ?: name
                return FullLabel(w, faint = faint, spoken = name)
            }
            val l = legends?.get(name)
            val base = l?.base ?: name
            val up = l?.shift ?: shifted(name)
            if (altGr) l?.altGr?.let { return FullLabel(it, faint = faint) }
            // a letter is one character whichever way; anything else shows both
            if (base.length == 1 && base[0].isLetter() && up.lowercase() == base.lowercase()) {
                return FullLabel(if (base == "ß") base else base.uppercase(), l?.altGr, faint)
            }
            return if (shift) FullLabel(up, faint = faint) else FullLabel(base, up, faint)
        }

        private fun shifted(name: String) = FullKeys.shifted[name] ?: name
    }
}
