// What a remote key is, on both ends (Swift: RemoteKeys.swift). Names, not key codes, so a stored layout stays readable; codes are the Mac's
// virtual key codes (kVK_*), kept here so the table is the same everywhere. Key names and modifier bits mean the same on every host; each host
// presses its own keys for them: command is ⌘ on a Mac and the Windows / Super key elsewhere (docs/design/remote-protocol.md §Hosts).
package dev.blurt.remote.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** The computer on the other end, from `RemoteSessionInfo.platform`. */
enum class RemoteHost(val raw: String) {
    MAC("mac"), WINDOWS("windows"), LINUX("linux");

    companion object {
        /** nil or unknown: a Mac before 1.0.15. */
        fun from(raw: String?): RemoteHost = entries.firstOrNull { it.raw == raw } ?: MAC
    }
}

/** Bits, as on the wire: `RemoteChord.mods` and `ToMac.Mods` carry an Int of these. */
object RemoteModifiers {
    const val COMMAND = 1
    const val SHIFT = 2
    const val OPTION = 4
    const val CONTROL = 8
    const val FUNCTION = 16

    const val NONE = 0

    fun contains(mods: Int, bit: Int): Boolean = mods and bit == bit && bit != 0

    /** The four, in the order each platform writes them: ⌃⌥⇧⌘ on a Mac; Win/Super, Ctrl, Alt, Shift elsewhere (Win+Shift+S, Ctrl+Alt+T). */
    fun ordered(host: RemoteHost = RemoteHost.MAC): List<Pair<Int, String>> = when (host) {
        RemoteHost.MAC -> listOf(CONTROL to "⌃", OPTION to "⌥", SHIFT to "⇧", COMMAND to "⌘")
        else -> listOf(COMMAND to label(COMMAND, host), CONTROL to "Ctrl", OPTION to "Alt", SHIFT to "Shift")
    }

    /** One modifier's name on that platform: ⌘ / Win / Super, ⌥ / Alt, ⌃ / Ctrl, ⇧ / Shift. */
    fun label(bit: Int, host: RemoteHost = RemoteHost.MAC): String = when (host) {
        RemoteHost.MAC -> when (bit) { COMMAND -> "⌘"; SHIFT -> "⇧"; OPTION -> "⌥"; CONTROL -> "⌃"; FUNCTION -> "fn"; else -> "" }
        else -> when (bit) {
            COMMAND -> if (host == RemoteHost.WINDOWS) "Win" else "Super"
            SHIFT -> "Shift"; OPTION -> "Alt"; CONTROL -> "Ctrl"; FUNCTION -> "Fn"; else -> ""
        }
    }

    /** "⌃⇧" on a Mac, "Ctrl+Shift" elsewhere. */
    fun glyphs(mods: Int, host: RemoteHost = RemoteHost.MAC): String {
        val names = ordered(host).filter { contains(mods, it.first) }.map { it.second }
        return names.joinToString(if (host == RemoteHost.MAC) "" else "+")
    }
}

class RemoteKey private constructor(val name: String, val code: Int, val glyph: String, private val pc: String?) {
    /** How the key reads after a modifier: "Tab" in Ctrl+Tab on Windows and Linux, the glyph on a Mac (⌃⇥). */
    fun label(host: RemoteHost = RemoteHost.MAC): String = if (host == RemoteHost.MAC) glyph else pc ?: glyph

    override fun equals(other: Any?): Boolean = other is RemoteKey && other.name == name && other.code == code && other.glyph == glyph
    override fun hashCode(): Int = name.hashCode()
    override fun toString(): String = "RemoteKey($name)"

    companion object {
        private fun k(name: String, code: Int, glyph: String? = null, pc: String? = null) = RemoteKey(name, code, glyph ?: name, pc)

        val all: List<RemoteKey> = buildList {
            val letters = listOf("A" to 0, "B" to 11, "C" to 8, "D" to 2, "E" to 14, "F" to 3, "G" to 5, "H" to 4, "I" to 34, "J" to 38, "K" to 40,
                "L" to 37, "M" to 46, "N" to 45, "O" to 31, "P" to 35, "Q" to 12, "R" to 15, "S" to 1, "T" to 17, "U" to 32, "V" to 9, "W" to 13,
                "X" to 7, "Y" to 16, "Z" to 6)
            letters.forEach { add(k(it.first, it.second)) }
            val digits = listOf("0" to 29, "1" to 18, "2" to 19, "3" to 20, "4" to 21, "5" to 23, "6" to 22, "7" to 26, "8" to 28, "9" to 25)
            digits.forEach { add(k(it.first, it.second)) }
            listOf(122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111).forEachIndexed { i, c -> add(k("F${i + 1}", c)) }
            addAll(listOf(
                k("Return", 36, "↩︎", "Enter"), k("Tab", 48, "⇥", "Tab"), k("Space", 49, "␣", "Space"), k("Delete", 51, "⌫", "Backspace"),
                k("Escape", 53, "esc", "Esc"), k("ForwardDelete", 117, "⌦", "Del"), k("Left", 123, "←"), k("Right", 124, "→"), k("Down", 125, "↓"),
                k("Up", 126, "↑"), k("Home", 115, "↖", "Home"), k("End", 119, "↘", "End"), k("PageUp", 116, "⇞", "PgUp"),
                k("PageDown", 121, "⇟", "PgDn"),
                k("-", 27), k("=", 24), k("[", 33), k("]", 30), k(";", 41), k("'", 39), k(",", 43), k(".", 47), k("/", 44), k("\\", 42), k("`", 50),
            ))
        }

        private val byName: Map<String, RemoteKey> = all.associateBy { it.name }
        fun named(name: String): RemoteKey? = byName[name]
    }
}

/** A key and its modifiers: ⌘C is {command, "C"}. An empty key is the modifiers alone (held, or tapped). */
data class RemoteChord(val mods: Int = RemoteModifiers.NONE, val key: String) {
    /** ⌘C on a Mac; Ctrl+C on Windows and Linux; a key alone is its glyph everywhere (⇥, ⌫). */
    fun label(host: RemoteHost = RemoteHost.MAC): String {
        val k = RemoteKey.named(key)
        if (host == RemoteHost.MAC) return RemoteModifiers.glyphs(mods, host) + (k?.glyph ?: key)
        val m = RemoteModifiers.glyphs(mods, host)
        if (m.isEmpty()) return k?.glyph ?: key
        if (key.isEmpty()) return m
        return m + "+" + (k?.label(host) ?: key)
    }

    val label: String get() = label(RemoteHost.MAC)

    fun toJson(): JsonObject = J.obj("mods" to J.int(mods), "key" to J.str(key))

    companion object {
        fun fromJson(e: JsonElement?): RemoteChord? {
            val o = e as? JsonObject ?: return null
            val m = J.int(o, "mods")?.takeIf { it in 0..255 } ?: return null
            return RemoteChord(m, J.str(o, "key") ?: return null)
        }
    }
}
