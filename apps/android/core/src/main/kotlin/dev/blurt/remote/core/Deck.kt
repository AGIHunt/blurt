// The keys (Swift: apps/ios/BlurtRemote/Model/Deck.swift; docs/design/remote.md §Keys, remote-protocol.md §Default keys per host). Pages of
// one shape with tabs, a dock that stays put below them, and the talk key beside it. A key shows an icon and the key's own name, never what
// it's for: the same shortcut does different things in different apps. The phone keeps one layout per platform, because the defaults differ
// (Ctrl+C on Windows and Linux, ⌘C on a Mac) and so do the modifiers' names. Stored as JSON in Swift's Codable shape, so a deck reads the
// same on both phones.
//
// Faces are "sf:<SF Symbol name>" for an icon, "mark:<name>" for one drawn by the app (apps, tabNext, tabPrevious, tabNew, tabClose,
// selectAll), or any text or emoji. The Android app maps the icon names to its own. Hints and section names are English: the app localises.
package dev.blurt.remote.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.UUID

/** How a key behaves on the phone. */
sealed class KeyAction {
    /** A tap presses it. With `cycle`, holding keeps `chord.mods` down and sliding steps through (⌘Tab, Alt+Tab, Ctrl+Tab). */
    data class Chord(val chord: RemoteChord, val cycle: Boolean = false) : KeyAction()
    /** Run on the host in one go, so the timing holds whatever the Wi-Fi does. */
    data class Sequence(val steps: List<RemoteStep>) : KeyAction()
    /** Text typed at the cursor, Return after it if asked. */
    data class Text(val text: String, val enter: Boolean) : KeyAction()
    /** The arrow pad: drag for ←↑→↓, tap then drag for the same with ⇧. */
    data object Arrows : KeyAction()
    /** Tap: for the next key or click. Double tap: until tapped again. RemoteModifiers bits. */
    data class Sticky(val mods: Int) : KeyAction()
    /** The next tab where the app in front keeps its tabs: ⌃Tab, or ⌘⇧] in a terminal (the host decides). */
    data object NextTab : KeyAction()
    data class Blurt(val command: RemoteBlurtCommand) : KeyAction()
    data class System(val move: RemoteSystemMove) : KeyAction()

    fun toJson(): JsonObject = when (this) {
        is Chord -> J.case("chord", "_0" to chord.toJson(), "cycle" to J.bool(cycle))
        is Sequence -> J.case("sequence", "_0" to J.list(steps) { it.toJson() })
        is Text -> J.case("text", "_0" to J.str(text), "enter" to J.bool(enter))
        Arrows -> J.case("arrows")
        is Sticky -> J.case("sticky", "_0" to J.int(mods))
        NextTab -> J.case("nextTab")
        is Blurt -> J.case("blurt", "_0" to J.str(command.raw))
        is System -> J.case("system", "_0" to J.str(move.raw))
    }

    companion object {
        fun fromJson(e: JsonElement?): KeyAction? {
            val (name, o) = J.case(e) ?: return null
            return when (name) {
                "chord" -> Chord(RemoteChord.fromJson(o["_0"]) ?: return null, J.bool(o, "cycle") ?: return null)
                "sequence" -> Sequence(J.list(o, "_0") { RemoteStep.fromJson(it) } ?: return null)
                "text" -> Text(J.str(o, "_0") ?: return null, J.bool(o, "enter") ?: return null)
                "arrows" -> Arrows
                "sticky" -> Sticky(J.int(o, "_0")?.takeIf { it in 0..255 } ?: return null)
                "nextTab" -> NextTab
                "blurt" -> Blurt(RemoteBlurtCommand.from(J.str(o, "_0")) ?: return null)
                "system" -> System(RemoteSystemMove.from(J.str(o, "_0")) ?: return null)
                else -> null
            }
        }
    }
}

data class KeySlot(
    val id: String = newID(),
    val action: KeyAction,
    /** what the key shows, large: "sf:name", "mark:name", or any text or emoji. null = the key's own name */
    val glyph: String? = null,
    /** the small line under it; null = the key's name where the large part is something else; "" = nothing */
    val caption: String? = null,
    /** what it's for, in the key list and to TalkBack. Never on the key */
    val hint: String? = null,
    /** columns wide. null = one */
    val span: Int? = null,
) {
    constructor(action: KeyAction, glyph: String? = null, caption: String? = null, hint: String? = null) :
        this(newID(), action, glyph, caption, hint, null)

    fun keyName(host: RemoteHost = RemoteHost.MAC): String? = when (action) {
        is KeyAction.Chord -> action.chord.label(host)
        is KeyAction.Sequence -> action.steps.mapNotNull { (it as? RemoteStep.Key)?.chord?.label(host) }.joinToString(" ")
        is KeyAction.Sticky -> RemoteModifiers.glyphs(action.mods, host)
        KeyAction.NextTab -> RemoteChord(RemoteModifiers.CONTROL, "Tab").label(host)
        else -> null
    }

    /** What the key shows, large. */
    fun face(host: RemoteHost = RemoteHost.MAC): String {
        glyph?.let { return it }
        return when {
            action is KeyAction.Chord && action.chord.mods == 0 && action.chord.key == "Return" -> "sf:return"
            action is KeyAction.Chord && action.chord.mods == 0 && action.chord.key == "Delete" -> "sf:delete.left"
            action is KeyAction.Text -> action.text.take(8)
            action is KeyAction.Arrows -> "sf:arrow.up.and.down.and.arrow.left.and.right"
            action is KeyAction.Blurt -> "sf:bird"
            action is KeyAction.System -> "sf:macwindow"
            else -> keyName(host) ?: ""
        }
    }

    /** The small line: yours, or the key's name under an icon, so what's pressed is always there to read. */
    fun detail(host: RemoteHost = RemoteHost.MAC): String? {
        caption?.let { return it.ifEmpty { null } }
        val n = keyName(host) ?: return null
        return if (glyph == null) null else n
    }

    /** What the key is called in lists. */
    fun title(host: RemoteHost = RemoteHost.MAC): String = hint ?: caption ?: keyName(host) ?: face(host)

    fun toJson(): JsonObject = J.obj(
        "id" to J.str(id), "action" to action.toJson(), "glyph" to J.str(glyph), "caption" to J.str(caption), "hint" to J.str(hint),
        "span" to J.int(span),
    )

    companion object {
        fun newID(): String = UUID.randomUUID().toString().uppercase()

        fun fromJson(e: JsonElement?): KeySlot? {
            val o = e as? JsonObject ?: return null
            return KeySlot(J.str(o, "id") ?: return null, KeyAction.fromJson(o["action"]) ?: return null, J.str(o, "glyph"), J.str(o, "caption"),
                J.str(o, "hint"), J.int(o, "span"))
        }
    }
}

/** One stretch of the list, with a tab that jumps to it. */
data class KeySection(val id: String = KeySlot.newID(), val name: String, val slots: List<KeySlot>, val columns: Int = Deck.COLUMNS) {
    constructor(name: String, slots: List<KeySlot>, columns: Int = Deck.COLUMNS) : this(KeySlot.newID(), name, slots, columns)

    fun toJson(): JsonObject = J.obj("id" to J.str(id), "name" to J.str(name), "slots" to J.list(slots) { it.toJson() }, "columns" to J.int(columns))

    companion object {
        fun fromJson(e: JsonElement?): KeySection? {
            val o = e as? JsonObject ?: return null
            return KeySection(J.str(o, "id") ?: return null, J.str(o, "name") ?: return null, J.list(o, "slots") { KeySlot.fromJson(it) } ?: return null,
                J.int(o, "columns") ?: return null)
        }
    }
}

/** A group in the key picker. */
data class KeyGroup(val group: String, val slots: List<KeySlot>)

/**
 * The dock (always in reach, whatever the list is scrolled to; the talk key sits with it, outside these) and the sections. Immutable: the
 * editing functions return the changed deck.
 */
data class Deck(val dock: List<KeySlot>, val sections: List<KeySection>) {
    private data class Place(val section: Int?, val index: Int)

    private fun place(id: String): Place? {
        dock.indexOfFirst { it.id == id }.takeIf { it >= 0 }?.let { return Place(null, it) }
        sections.forEachIndexed { n, s -> s.slots.indexOfFirst { it.id == id }.takeIf { it >= 0 }?.let { return Place(n, it) } }
        return null
    }

    /** `from` takes `onto`'s place, the rest making room; with the dock in it, the two change places (the dock always has its keys). */
    fun move(from: String, onto: String): Deck {
        val a = place(from) ?: return this
        val b = place(onto) ?: return this
        val dock = dock.toMutableList()
        val slots = sections.map { it.slots.toMutableList() }
        when {
            a.section == null && b.section == null -> { val t = dock[a.index]; dock[a.index] = dock[b.index]; dock[b.index] = t }
            a.section == null -> { val t = dock[a.index]; dock[a.index] = slots[b.section!!][b.index]; slots[b.section][b.index] = t }
            b.section == null -> { val t = slots[a.section][a.index]; slots[a.section][a.index] = dock[b.index]; dock[b.index] = t }
            else -> {
                val s = slots[a.section].removeAt(a.index)
                slots[b.section].add(minOf(b.index, slots[b.section].size), s)
            }
        }
        return Deck(dock, sections.mapIndexed { i, s -> s.copy(slots = slots[i]) })
    }

    fun replace(id: String, slot: KeySlot): Deck {
        val i = dock.indexOfFirst { it.id == id }
        if (i >= 0) return copy(dock = dock.toMutableList().also { it[i] = slot })
        return copy(sections = sections.map { s -> s.copy(slots = s.slots.map { if (it.id == id) slot else it }) })
    }

    /** Off the pages; the dock keeps its keys. */
    fun remove(id: String): Deck = copy(sections = sections.map { s -> s.copy(slots = s.slots.filter { it.id != id }) })

    /** A key added to a section, at `index` (null: the end). */
    fun add(slot: KeySlot, section: String, index: Int? = null): Deck = copy(sections = sections.map { s ->
        if (s.id != section) s else s.copy(slots = s.slots.toMutableList().also { it.add((index ?: it.size).coerceIn(0, it.size), slot) })
    })

    /** A new empty section at the end, while there's room for one (MAX_SECTIONS). */
    fun addSection(name: String): Deck = if (sections.size >= MAX_SECTIONS) this else copy(sections = sections + KeySection(name, emptyList()))

    fun renameSection(id: String, name: String): Deck = copy(sections = sections.map { if (it.id == id) it.copy(name = name) else it })

    /** Never the last one. */
    fun removeSection(id: String): Deck = if (sections.size <= 1) this else copy(sections = sections.filter { it.id != id })

    fun toJson(): String = J.obj("dock" to J.list(dock) { it.toJson() }, "sections" to J.list(sections) { it.toJson() }).toString()

    companion object {
        const val COLUMNS = 6
        /** the four modifiers, four that end or move things, and the space bar */
        const val DOCK_COUNT = 9
        const val MAX_SECTIONS = 6

        /** Where the app keeps each platform's deck. */
        fun storeKey(host: RemoteHost): String = "deck.${host.raw}.v1"

        fun fromJson(json: String): Deck? {
            val o = try {
                J.format.parseToJsonElement(json) as? JsonObject
            } catch (_: Exception) {
                null
            } ?: return null
            return Deck(J.list(o, "dock") { KeySlot.fromJson(it) } ?: return null, J.list(o, "sections") { KeySection.fromJson(it) } ?: return null)
        }

        /** What was stored for this platform if it's whole, else the defaults. */
        fun restore(json: String?, host: RemoteHost): Deck {
            val d = json?.let { fromJson(it) }
            return if (d != null && d.sections.isNotEmpty() && d.dock.size == DOCK_COUNT) d else standard(host)
        }

        val spaceBar: KeySlot get() = KeySlot(KeyAction.Chord(RemoteChord(0, "Space")), glyph = "sf:space", caption = "", hint = "Space")

        /** The defaults, per docs/design/remote-protocol.md §Default keys per host. */
        fun standard(host: RemoteHost = RemoteHost.MAC): Deck {
            val k = Keys(host)
            return Deck(k.dock(), listOf(
                KeySection("Main", k.editKeys() + k.switchKeys() + k.actionKeys() + k.blurtKeys()),
                KeySection("Letters", letterKeys(), columns = 10),
                KeySection("Symbols", symbolKeys(), columns = 10),
                KeySection("More", functionKeys() + k.systemKeys()),
            ))
        }

        /** Everything the key picker offers, in groups. */
        fun catalogue(host: RemoteHost = RemoteHost.MAC): List<KeyGroup> {
            val k = Keys(host)
            return listOf(
                KeyGroup("Main", k.editKeys() + k.switchKeys() + k.actionKeys()),
                KeyGroup("More", k.lessUsedKeys()),
                KeyGroup("Vibe Coding", k.vibeKeys()),
                KeyGroup("Switch", listOf(KeySlot(KeyAction.NextTab, glyph = "sf:rectangle.stack", hint = "Next Tab")) +
                    (1..4).map { chord(k.primary, "$it", "$it") } + k.systemKeys() + if (host == RemoteHost.MAC) emptyList() else movesKeys()),
                KeyGroup("Edit", k.editingKeys()),
                KeyGroup("Modifiers", k.modifierKeys()),
                KeyGroup("Browser", listOf(chord(k.primary, "=", "Zoom In", icon = "plus.magnifyingglass"), chord(k.primary, "-", "Zoom Out", icon = "minus.magnifyingglass"))),
                KeyGroup("Blurt", blurtKeys()),
                KeyGroup("Letters", letterKeys()),
                KeyGroup("Symbols", symbolKeys() + functionKeys()),
            )
        }

        /** For choosing a key's face: SF Symbol names, as on iOS. */
        val icons = listOf("doc.on.doc", "doc.on.clipboard", "scissors", "arrow.uturn.backward", "arrow.uturn.forward", "trash", "magnifyingglass", "link",
            "plus", "minus", "xmark", "checkmark", "star", "heart", "bolt", "flag", "bookmark", "tag", "pin", "paperclip", "folder", "doc",
            "terminal", "command", "keyboard", "globe", "safari", "gear", "wrench.and.screwdriver", "hammer", "ant", "sparkles", "brain",
            "bubble.left", "paperplane", "mic", "camera", "photo", "play", "pause", "stop", "forward", "backward", "sidebar.left",
            "macwindow", "square.split.2x1", "arrow.clockwise", "arrow.up.to.line", "arrow.down.to.line", "chevron.left", "chevron.right")

        // MARK: what it ships with

        private const val C = RemoteModifiers.CONTROL
        private const val A = RemoteModifiers.OPTION
        private const val S = RemoteModifiers.SHIFT
        private const val W = RemoteModifiers.COMMAND

        /** An icon where there's a good one, the key's name under it. No words for what it does: that depends on the app. */
        private fun chord(m: Int, k: String, hint: String? = null, cycle: Boolean = false, icon: String? = null, mark: String? = null, glyph: String? = null) =
            KeySlot(KeyAction.Chord(RemoteChord(m, k), cycle), glyph = icon?.let { "sf:$it" } ?: mark?.let { "mark:$it" } ?: glyph, hint = hint)

        private fun blurt(c: RemoteBlurtCommand, symbol: String, caption: String) = KeySlot(KeyAction.Blurt(c), glyph = "sf:$symbol", caption = caption, hint = caption)

        private fun sticky(m: Int, name: String) = KeySlot(KeyAction.Sticky(m), hint = name)

        private fun blurtKeys() = listOf(
            blurt(RemoteBlurtCommand.SNAP, "camera.viewfinder", "Snap"), blurt(RemoteBlurtCommand.RECORD, "record.circle", "Record"),
            blurt(RemoteBlurtCommand.VOICE_NOTE, "waveform", "Voice Note"), blurt(RemoteBlurtCommand.COPY_TEXT, "text.viewfinder", "Copy Text"),
            blurt(RemoteBlurtCommand.TRANSLATE, "character.bubble", "Translate"), blurt(RemoteBlurtCommand.CARDS, "rectangle.stack", "Cards"),
        )

        /** Only a computer has these: what a phone's keyboard can't type. */
        private fun functionKeys() = (1..12).map { chord(0, "F$it") } + listOf(
            chord(0, "Home", glyph = "Home"), chord(0, "End", glyph = "End"), chord(0, "PageUp", glyph = "PgUp"), chord(0, "PageDown", glyph = "PgDn"),
            chord(0, "ForwardDelete", "Forward Delete", icon = "delete.right"),
        )

        /** The named moves the host maps to its own (three fingers do them anyway). */
        private fun movesKeys() = listOf(
            KeySlot(KeyAction.System(RemoteSystemMove.MISSION_CONTROL), glyph = "sf:rectangle.3.group", caption = "All Windows"),
            KeySlot(KeyAction.System(RemoteSystemMove.APP_EXPOSE), glyph = "sf:rectangle.grid.2x2", caption = "App Windows"),
            KeySlot(KeyAction.System(RemoteSystemMove.SPACE_LEFT), glyph = "sf:arrow.left.square", caption = "Desktop Left"),
            KeySlot(KeyAction.System(RemoteSystemMove.SPACE_RIGHT), glyph = "sf:arrow.right.square", caption = "Desktop Right"),
        )

        /** The keyboard's own four rows, numbers on top. Plain keys, so a held or sticky modifier makes them shortcuts. Same everywhere. */
        private fun letterKeys() = "1234567890QWERTYUIOPASDFGHJKL;ZXCVBNM,./".map { chord(0, it.toString()) }

        /** What ⇧ makes of the number row and the rest of the punctuation: everything 字母 has no key for. Same everywhere. */
        private fun symbolKeys(): List<KeySlot> {
            val pairs = listOf(
                Triple("!", "1", true), Triple("@", "2", true), Triple("#", "3", true), Triple("$", "4", true), Triple("%", "5", true),
                Triple("^", "6", true), Triple("&", "7", true), Triple("*", "8", true), Triple("(", "9", true), Triple(")", "0", true),
                Triple("-", "-", false), Triple("_", "-", true), Triple("=", "=", false), Triple("+", "=", true), Triple("[", "[", false),
                Triple("]", "]", false), Triple("{", "[", true), Triple("}", "]", true), Triple("\\", "\\", false), Triple("|", "\\", true),
                Triple(":", ";", true), Triple("'", "'", false), Triple("\"", "'", true), Triple("<", ",", true), Triple(">", ".", true),
                Triple("?", "/", true), Triple("`", "`", false), Triple("~", "`", true),
            )
            return pairs.map { (g, k, s) -> KeySlot(KeyAction.Chord(RemoteChord(if (s) S else 0, k)), glyph = g, caption = "") }
        }
    }

    /** The keys that differ by platform. `primary` is what copy and paste are held with: ⌘ on a Mac, Ctrl elsewhere. */
    private class Keys(val host: RemoteHost) {
        val mac = host == RemoteHost.MAC
        val primary = if (mac) W else C
        /** the Windows / Super key's own name */
        val logo = RemoteModifiers.label(W, host)

        fun dock(): List<KeySlot> {
            val mods = if (mac) {
                listOf(sticky(C, "Control"), sticky(A, "Option"), sticky(W, "Command"), sticky(S, "Shift"))
            } else {
                listOf(sticky(C, "Control"), sticky(W, logo), sticky(A, "Alt"), sticky(S, "Shift"))
            }
            return mods + listOf(
                KeySlot(KeyAction.Chord(RemoteChord(0, "Tab")), glyph = "sf:arrow.right.to.line", caption = "", hint = "Complete"),
                chord(0, "Escape", "Stop"), chord(0, "Delete", "Delete"), chord(0, "Return", "Send"), spaceBar,
            )
        }

        fun editKeys() = listOf(
            chord(primary, "C", "Copy", icon = "doc.on.doc"), chord(primary, "V", "Paste", icon = "clipboard"),
            chord(primary, "X", "Cut", icon = "scissors"), chord(primary, "Z", "Undo", icon = "arrow.uturn.backward"),
            when (host) {
                RemoteHost.WINDOWS -> chord(C, "Y", "Redo", icon = "arrow.uturn.forward")
                else -> chord(primary or S, "Z", "Redo", icon = "arrow.uturn.forward")
            },
            chord(primary, "A", "Select All", mark = "selectAll"),
        )

        /** Between apps, windows, tabs, pages. Holding and sliding steps both ways, so there's no key for going back through apps. */
        fun switchKeys() = when (host) {
            RemoteHost.MAC -> listOf(
                chord(W, "Tab", "Apps", cycle = true, mark = "apps"), chord(W, "`", "Windows", cycle = true, icon = "macwindow.on.rectangle"),
                chord(W, "[", "Back", icon = "chevron.left"), chord(W, "]", "Forward", icon = "chevron.right"),
                chord(C or S, "Tab", "Previous Tab", cycle = true, mark = "tabPrevious"), chord(C, "Tab", "Next Tab", cycle = true, mark = "tabNext"),
            )
            else -> listOf(
                chord(A, "Tab", "Apps", cycle = true, mark = "apps"),
                if (host == RemoteHost.WINDOWS) chord(W, "Tab", "Task View", icon = "rectangle.3.group")
                else chord(A, "`", "Windows", cycle = true, icon = "macwindow.on.rectangle"),
                chord(A, "Left", "Back", icon = "chevron.left"), chord(A, "Right", "Forward", icon = "chevron.right"),
                chord(C or S, "Tab", "Previous Tab", cycle = true, mark = "tabPrevious"), chord(C, "Tab", "Next Tab", cycle = true, mark = "tabNext"),
            )
        }

        fun actionKeys() = if (mac) {
            listOf(
                chord(W, "F", "Find", icon = "doc.text.magnifyingglass"),
                // written out: what ⌘K does depends entirely on the app, and ⌃C mustn't look like ⌘W, which can close a terminal
                KeySlot(KeyAction.Chord(RemoteChord(W, "K")), glyph = "⌘K", caption = "", hint = "Inline Edit"),
                chord(W, "Space", "Spotlight", icon = "magnifyingglass"),
                KeySlot(KeyAction.Chord(RemoteChord(C, "C")), glyph = "⌃C", caption = "", hint = "Interrupt"),
                chord(W, "T", "New Tab", mark = "tabNew"), chord(W, "W", "Close Tab", mark = "tabClose"),
            )
        } else {
            listOf(
                chord(C, "F", "Find", icon = "doc.text.magnifyingglass"),
                KeySlot(KeyAction.Chord(RemoteChord(C, "K")), glyph = "Ctrl K", caption = "", hint = "Inline Edit"),
                // the logo key alone: Start on Windows, Activities on GNOME
                KeySlot(KeyAction.Chord(RemoteChord(W, "")), glyph = logo, caption = "", hint = if (host == RemoteHost.WINDOWS) "Start" else "Activities"),
                // Ctrl+C is copy here, and on the first row; copy in a terminal is Ctrl+Shift+C
                KeySlot(KeyAction.Chord(RemoteChord(C or S, "C")), glyph = "Ctrl ⇧C", caption = "", hint = "Copy in Terminal"),
                chord(C, "T", "New Tab", mark = "tabNew"), chord(C, "W", "Close Tab", mark = "tabClose"),
            )
        }

        fun blurtKeys() = Companion.blurtKeys()

        /** 更多's own: the computer's moves. */
        fun systemKeys(): List<KeySlot> = when (host) {
            RemoteHost.MAC -> movesKeys()
            RemoteHost.WINDOWS -> listOf(
                chord(W, "D", "Desktop", icon = "menubar.dock.rectangle"), chord(W, "E", "Files", icon = "folder"),
                chord(W, "L", "Lock", icon = "lock"), chord(A, "F4", "Close Window", icon = "xmark.square"),
                chord(C or S, "Escape", "Task Manager", icon = "gauge.with.dots.needle.33percent"),
                chord(W or S, "S", "Snip", icon = "scissors.badge.ellipsis"),
            )
            RemoteHost.LINUX -> listOf(
                chord(W, "D", "Desktop", icon = "menubar.dock.rectangle"), chord(W, "L", "Lock", icon = "lock"),
                chord(A, "F4", "Close Window", icon = "xmark.square"),
            )
        }

        /** Kept for whoever wants them on a key; not on one to begin with. */
        fun lessUsedKeys(): List<KeySlot> = if (mac) {
            listOf(
                chord(W, "R", "Reload", icon = "arrow.clockwise"), chord(W or S, "T", "Reopen Tab", icon = "arrow.uturn.backward.square"),
                chord(W, "S", "Save", icon = "square.and.arrow.down"), chord(W, "L", "Address", icon = "link"),
                chord(W or S, "[", "Previous Tab", icon = "chevron.left.square"), chord(W or S, "]", "Next Tab", icon = "chevron.right.square"),
                chord(A, "Delete", "Delete Word", icon = "delete.left"), chord(W, "Delete", "Delete Line", icon = "delete.left.fill"),
                chord(W, "Return", "Accept", icon = "checkmark.circle"), chord(S, "Tab", "Back a Field", icon = "arrow.left.to.line"),
                chord(W, "P", "Open File", icon = "doc.badge.gearshape"), chord(W or S, "P", "Command Palette", icon = "command.square"),
                chord(W, "B", "Sidebar", icon = "sidebar.left"), chord(W, "J", "Terminal Panel", icon = "rectangle.bottomthird.inset.filled"),
                chord(C, "O", "Transcript", icon = "text.justify.left"), chord(C, "R", "History", icon = "clock.arrow.circlepath"),
                chord(C, "L", "Clear Screen", icon = "eraser"),
                chord(A, "L", "Reformat", icon = "text.badge.checkmark"),
                chord(C, "Space", "Input Source", icon = "globe"),
                KeySlot(KeyAction.System(RemoteSystemMove.FIND_CURSOR), glyph = "sf:scope", caption = "Find Pointer"),
            )
        } else {
            listOf(
                chord(0, "F5", "Reload", icon = "arrow.clockwise"), chord(C or S, "T", "Reopen Tab", icon = "arrow.uturn.backward.square"),
                chord(C, "S", "Save", icon = "square.and.arrow.down"), chord(A, "D", "Address", icon = "link"),
                chord(C, "PageUp", "Previous Tab", icon = "chevron.left.square"), chord(C, "PageDown", "Next Tab", icon = "chevron.right.square"),
                chord(C, "Delete", "Delete Word", icon = "delete.left"),
                chord(C, "Return", "Accept", icon = "checkmark.circle"), chord(S, "Tab", "Back a Field", icon = "arrow.left.to.line"),
                chord(C, "P", "Open File", icon = "doc.badge.gearshape"), chord(C or S, "P", "Command Palette", icon = "command.square"),
                chord(C, "B", "Sidebar", icon = "sidebar.left"), chord(C, "J", "Terminal Panel", icon = "rectangle.bottomthird.inset.filled"),
                chord(C, "O", "Transcript", icon = "text.justify.left"), chord(C, "R", "History", icon = "clock.arrow.circlepath"),
                chord(C, "L", "Clear Screen", icon = "eraser"),
                chord(A, "L", "Reformat", icon = "text.badge.checkmark"),
                chord(W, "Space", "Input Source", icon = "globe"),
                KeySlot(KeyAction.System(RemoteSystemMove.FIND_CURSOR), glyph = "sf:scope", caption = "Find Pointer"),
            )
        }

        fun vibeKeys() = listOf(
            chord(C, "B", "Background", icon = "square.2.layers.3d"),
            chord(C, "J", "New Line", icon = "return.left"),
            KeySlot(KeyAction.Sequence(listOf(RemoteStep.Key(RemoteChord(0, "Escape")), RemoteStep.Wait(90), RemoteStep.Key(RemoteChord(0, "Escape")))),
                glyph = "esc esc", hint = "Rewind"),
            chord(0, "1", "Option 1"), chord(0, "2", "Option 2"), chord(0, "3", "Option 3"),
            chord(primary or S, "Delete", "Reject", icon = "xmark.circle"),
            chord(primary, "I", "Composer", icon = "text.bubble"),
            chord(C, "`", "Terminal", icon = "terminal"),
        )

        fun editingKeys() = listOf(
            chord(0, "Return", "Send"), chord(S, "Return", "New Line", icon = "return.left"), chord(0, "Space", "Space"),
            KeySlot(KeyAction.Arrows, hint = "Arrows"),
            chord(0, "Up"), chord(0, "Down"), chord(0, "Left"), chord(0, "Right"),
            if (mac) chord(W, "Left", "Line Start", icon = "arrow.left.to.line") else chord(0, "Home", "Line Start", icon = "arrow.left.to.line"),
            if (mac) chord(W, "Right", "Line End", icon = "arrow.right.to.line") else chord(0, "End", "Line End", icon = "arrow.right.to.line"),
            chord(if (mac) A else C, "Left", "Word Left", icon = "arrow.left"), chord(if (mac) A else C, "Right", "Word Right", icon = "arrow.right"),
        )

        fun modifierKeys() = if (mac) {
            listOf(sticky(W, "Command"), sticky(S, "Shift"), sticky(A, "Option"), sticky(C, "Control"), sticky(W or S, "Command Shift"))
        } else {
            listOf(sticky(W, logo), sticky(S, "Shift"), sticky(A, "Alt"), sticky(C, "Control"), sticky(C or S, "Control Shift"))
        }
    }
}
