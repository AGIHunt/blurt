// Key faces as on the iPhone ("sf:<SF Symbol>", "mark:<name>"), drawn with Material Symbols Rounded at weight 300: the closest family to SF
// Symbols' regular weight, line icons with round ends. Each SF name maps to the Material Symbol that says the same thing. Only these glyphs are
// in the app (res/font/symbols*.ttf); apps/android/tools/symbols.py makes those fonts and SymbolCodes.kt from the names below.
package dev.blurt.remote.app.keys

object Icons {
    /** SF Symbol → Material Symbol. A trailing "|flip" draws it mirrored (forward delete). */
    val sf: Map<String, String> = mapOf(
        "arrow.clockwise" to "refresh",
        "arrow.left" to "arrow_back",
        "arrow.left.square" to "keyboard_double_arrow_left",
        "arrow.left.to.line" to "keyboard_tab_rtl",
        "arrow.right" to "arrow_forward",
        "arrow.right.square" to "keyboard_double_arrow_right",
        "arrow.right.to.line" to "keyboard_tab",
        "arrow.up.and.down.and.arrow.left.and.right" to "open_with",
        "arrow.uturn.backward" to "undo",
        "arrow.uturn.backward.square" to "restore_page",
        "arrow.uturn.forward" to "redo",
        "camera.viewfinder" to "screenshot_region",
        "character.bubble" to "translate",
        "checkmark.circle" to "check_circle",
        "chevron.left" to "chevron_left",
        "chevron.left.square" to "keyboard_arrow_left",
        "chevron.right" to "chevron_right",
        "chevron.right.square" to "keyboard_arrow_right",
        "clipboard" to "content_paste",
        "clock.arrow.circlepath" to "history",
        "command.square" to "keyboard_command_key",
        "delete.left" to "backspace",
        "delete.left.fill" to "backspace|fill",
        "delete.right" to "backspace|flip",
        "doc.badge.gearshape" to "file_open",
        "doc.on.doc" to "content_copy",
        "doc.text.magnifyingglass" to "find_in_page",
        "eraser" to "ink_eraser",
        "folder" to "folder",
        "gauge.with.dots.needle.33percent" to "speed",
        "globe" to "language",
        "link" to "link",
        "lock" to "lock",
        "macwindow.on.rectangle" to "select_window",
        "magnifyingglass" to "search",
        "menubar.dock.rectangle" to "dock_to_bottom",
        "minus.magnifyingglass" to "zoom_out",
        "plus.magnifyingglass" to "zoom_in",
        "record.circle" to "radio_button_checked",
        "rectangle.3.group" to "view_cozy",
        "rectangle.bottomthird.inset.filled" to "bottom_panel_open",
        "rectangle.grid.2x2" to "grid_view",
        "rectangle.stack" to "stacks",
        "return" to "keyboard_return",
        "return.left" to "subdirectory_arrow_left",
        "scissors" to "content_cut",
        "scissors.badge.ellipsis" to "screenshot_frame",
        "scope" to "my_location",
        "sidebar.left" to "side_navigation",
        "space" to "space_bar",
        "square.2.layers.3d" to "layers",
        "square.and.arrow.down" to "save",
        "terminal" to "terminal",
        "text.badge.checkmark" to "wrap_text",
        "text.bubble" to "chat",
        "text.justify.left" to "format_align_left",
        "text.viewfinder" to "document_scanner",
        "waveform" to "graphic_eq",
        "xmark.circle" to "cancel",
        "xmark.square" to "disabled_by_default",
        "bird" to "graphic_eq",
        "macwindow" to "web_asset",
        // the face picker (Deck.icons)
        "doc.on.clipboard" to "content_paste_go",
        "trash" to "delete",
        "plus" to "add",
        "minus" to "remove",
        "xmark" to "close",
        "checkmark" to "check",
        "star" to "star",
        "heart" to "favorite",
        "bolt" to "bolt",
        "flag" to "flag",
        "bookmark" to "bookmark",
        "tag" to "sell",
        "pin" to "push_pin",
        "paperclip" to "attach_file",
        "doc" to "description",
        "command" to "keyboard_command_key",
        "keyboard" to "keyboard",
        "safari" to "explore",
        "gear" to "settings",
        "wrench.and.screwdriver" to "build",
        "hammer" to "construction",
        "ant" to "bug_report",
        "sparkles" to "auto_awesome",
        "brain" to "psychology",
        "bubble.left" to "chat_bubble",
        "paperplane" to "send",
        "mic" to "mic",
        "camera" to "photo_camera",
        "photo" to "image",
        "play" to "play_arrow",
        "pause" to "pause",
        "stop" to "stop",
        "forward" to "fast_forward",
        "backward" to "fast_rewind",
        "square.split.2x1" to "vertical_split",
        "arrow.up.to.line" to "vertical_align_top",
        "arrow.down.to.line" to "vertical_align_bottom",
    )

    /** What the app's own controls use. */
    val ui: List<String> = listOf(
        "tune", "desktop_windows", "keyboard", "my_location", "apps", "mic", "info", "more_vert", "more_horiz", "close", "drag_indicator",
        "qr_code_scanner", "edit", "keyboard_arrow_up", "keyboard_arrow_down", "keyboard_arrow_left", "keyboard_arrow_right", "add", "remove",
        "check", "search", "content_paste", "keyboard_hide",
        // a modifier key's face: the font's own ⌃ ⌥ ⇧ are thin and small next to ⌘
        "keyboard_control_key", "keyboard_option_key", "shift",
    )

    /** A face that is one modifier's mark, drawn as the symbol of the same shape. */
    val modifierFaces: Map<String, String> = mapOf(
        "⌃" to "keyboard_control_key", "⌥" to "keyboard_option_key", "⌘" to "keyboard_command_key", "⇧" to "shift",
    )

    data class Glyph(val char: String, val filled: Boolean, val flip: Boolean)

    /** A face's Material Symbol, or null for one this app doesn't have (it shows as text). */
    fun glyph(face: String): Glyph? {
        val name = if (face.startsWith("sf:")) sf[face.removePrefix("sf:")] ?: return null else face
        val parts = name.split("|")
        val code = SymbolCodes.codes[parts[0]] ?: return null
        return Glyph(String(Character.toChars(code)), "fill" in parts, "flip" in parts)
    }

    fun char(name: String): String = SymbolCodes.codes[name]?.let { String(Character.toChars(it)) } ?: ""
}
