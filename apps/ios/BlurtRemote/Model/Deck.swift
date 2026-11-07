// The keys (docs/design/remote.md §Keys). One long list that scrolls, like the emoji keyboard: tabs jump to its sections and follow it,
// and every key can be moved anywhere. A dock stays put below it, for what's needed wherever the list is. A key shows an icon and the name
// of the key, never what it's for: the same shortcut does different things in different apps. Stored as JSON in the app's preferences.
import BlurtRemoteKit
import Foundation

/// How a key behaves on the phone.
enum KeyAction: Codable, Hashable {
    /// A tap presses it. With `cycle`, holding keeps `chord.mods` down and sliding steps through (⌘Tab, ⌃Tab, ⌘`).
    case chord(RemoteChord, cycle: Bool)
    /// Run on the Mac in one go, so the timing holds whatever the Wi-Fi does.
    case sequence([RemoteStep])
    /// Text typed at the cursor, Return after it if asked.
    case text(String, enter: Bool)
    /// The arrow pad: drag for ←↑→↓, tap then drag for the same with ⇧.
    case arrows
    /// Tap: for the next key or click. Double tap: until tapped again.
    case sticky(RemoteModifiers)
    /// The next tab where the app in front keeps its tabs: ⌃Tab, or ⌘⇧] in a terminal.
    case nextTab
    case blurt(RemoteBlurtCommand)
    case system(RemoteSystemMove)
}

struct KeySlot: Codable, Hashable, Identifiable {
    var id = UUID()
    var action: KeyAction
    /// what the key shows, large: "sf:name" for an SF Symbol, or any text or emoji. nil = the key's own name
    var glyph: String?
    /// the small line under it; nil = the key's name where the large part is something else
    var caption: String?
    /// what it's for, in the key list and to VoiceOver. Never on the key: a shortcut means different things in different apps
    var hint: String?

    init(_ action: KeyAction, glyph: String? = nil, caption: String? = nil, hint: String? = nil) {
        self.action = action; self.glyph = glyph; self.caption = caption; self.hint = hint
    }

    private var keyName: String? {
        switch action {
        case let .chord(c, _): return c.label
        case let .sequence(s): return s.compactMap { if case let .key(c) = $0 { c.label } else { nil } }.joined(separator: " ")
        case let .sticky(m): return m.glyphs
        case .nextTab: return "⌃⇥"
        default: return nil
        }
    }

    var face: String {
        if let glyph { return glyph }
        switch action {
        case let .chord(c, _) where c.mods.isEmpty && c.key == "Return": return "sf:return"
        case let .chord(c, _) where c.mods.isEmpty && c.key == "Delete": return "sf:delete.left"
        case let .text(t, _): return String(t.prefix(8))
        case .arrows: return "sf:arrow.up.and.down.and.arrow.left.and.right"
        case .blurt: return "sf:bird"
        case .system: return "sf:macwindow"
        default: return keyName ?? ""
        }
    }

    /// The small line: yours, or the key's name under an icon, so what's pressed is always there to read.
    var detail: String? {
        if let caption { return caption.isEmpty ? nil : caption }
        guard let n = keyName else { return nil }
        return glyph == nil ? nil : n
    }

    /// What the key is called in lists.
    var title: String { hint ?? caption ?? keyName ?? face }
}

/// One stretch of the list, with a tab that jumps to it.
struct KeySection: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var slots: [KeySlot]
    /// more than the usual: plain keys, the size of the iPhone's own
    var columns = Deck.columns

    init(_ name: String, _ slots: [KeySlot], columns: Int = Deck.columns) { self.name = name; self.slots = slots; self.columns = columns }
}

struct Deck: Codable, Equatable {
    /// always in reach, whatever the list is scrolled to; the talk key sits with them. The arrow key does too, but it's not one of these:
    /// it needs room to slide all four ways, so it has its own place
    var dock: [KeySlot]
    var sections: [KeySection]

    static let columns = 8
    /// a row, less the talk key
    static let dockCount = 7
    static let maxSections = 6

    private static let storeKey = "deck.v5"

    static func load() -> Deck {
        guard let d = UserDefaults.standard.data(forKey: storeKey), let deck = try? JSONDecoder().decode(Deck.self, from: d),
              !deck.sections.isEmpty, deck.dock.count == dockCount else { return .standard }
        return deck
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.storeKey) }
    }
}

// MARK: - What it ships with

/// An icon where there's a good one, the key's name under it. No words for what it does: that depends on the app.
private func chord(_ m: RemoteModifiers, _ k: String, _ hint: String? = nil, cycle: Bool = false, icon: String? = nil, glyph: String? = nil) -> KeySlot {
    KeySlot(.chord(RemoteChord(m, k), cycle: cycle), glyph: icon.map { "sf:\($0)" } ?? glyph, hint: hint)
}

private func blurt(_ c: RemoteBlurtCommand, _ symbol: String, _ caption: String) -> KeySlot {
    KeySlot(.blurt(c), glyph: "sf:\(symbol)", caption: caption, hint: caption)
}

private func sticky(_ m: RemoteModifiers, _ name: String) -> KeySlot { KeySlot(.sticky(m), hint: name) }

extension Deck {
    /// The dock is what's needed whatever the list shows: send, stop, and the modifiers, whose state must stay in sight. Everything used
    /// every day is on the first screen of the list, with nothing to scroll for: the first rows are what's used every few minutes.
    static var standard: Deck {
        Deck(dock: [
            chord([], "Escape", String(localized: "Stop")), chord([], "Tab", String(localized: "Complete")), chord([], "Delete", String(localized: "Delete")),
            sticky(.command, "Command"), sticky(.shift, "Shift"), sticky(.control, "Control"), chord([], "Return", String(localized: "Send")),
        ], sections: [
            KeySection(String(localized: "Main"), mainKeys + blurtKeys + moveKeys),
            KeySection(String(localized: "Letters"), letterKeys, columns: 10),
            KeySection(String(localized: "Symbols"), symbolKeys, columns: 10),
        ])
    }

    private static var mainKeys: [KeySlot] {
        [
            chord(.command, "C", String(localized: "Copy"), icon: "doc.on.doc"), chord(.command, "V", String(localized: "Paste"), icon: "doc.on.clipboard"),
            chord(.command, "X", String(localized: "Cut"), icon: "scissors"), chord(.command, "Z", String(localized: "Undo"), icon: "arrow.uturn.backward"),
            chord([.command, .shift], "Z", String(localized: "Redo"), icon: "arrow.uturn.forward"), chord(.command, "A", String(localized: "Select All"), icon: "selection.pin.in.out"),

            chord(.command, "Tab", String(localized: "Apps"), cycle: true, icon: "square.stack.3d.up"), chord(.command, "`", String(localized: "Windows"), cycle: true, icon: "macwindow.on.rectangle"),
            chord(.control, "Tab", String(localized: "Next Tab"), cycle: true, icon: "chevron.right.2"), chord([.control, .shift], "Tab", String(localized: "Previous Tab"), cycle: true, icon: "chevron.left.2"),
            chord(.shift, "Tab", String(localized: "Back a Field"), icon: "arrow.left.to.line"), chord(.control, "C", String(localized: "Interrupt"), icon: "xmark.octagon"),

            sticky(.option, "Option"), chord(.command, "T", String(localized: "New Tab"), icon: "plus.rectangle.on.rectangle"),
            chord(.command, "W", String(localized: "Close Tab"), icon: "xmark.rectangle"), chord([.command, .shift], "T", String(localized: "Reopen Tab"), icon: "arrow.uturn.backward.square"),
            chord(.command, "R", String(localized: "Reload"), icon: "arrow.clockwise"), chord(.command, "F", String(localized: "Find"), icon: "magnifyingglass"),

            chord(.command, "S", String(localized: "Save"), icon: "square.and.arrow.down"), chord(.command, "L", String(localized: "Address"), icon: "link"),
            chord(.command, "[", String(localized: "Back"), icon: "chevron.left"), chord(.command, "]", String(localized: "Forward"), icon: "chevron.right"),
            chord([.command, .shift], "[", String(localized: "Previous Tab"), icon: "chevron.left.square"), chord([.command, .shift], "]", String(localized: "Next Tab"), icon: "chevron.right.square"),

            chord(.option, "Delete", String(localized: "Delete Word"), icon: "delete.left"), chord([.command], "Delete", String(localized: "Delete Line"), icon: "delete.left.fill"),
            chord([.command], "Return", String(localized: "Accept"), icon: "checkmark.circle"), chord(.command, "P", String(localized: "Open File"), icon: "doc.text.magnifyingglass"),
            chord([.command, .shift], "P", String(localized: "Command Palette"), icon: "command.square"), chord(.command, "K", String(localized: "Inline Edit"), icon: "sparkles"),

            chord(.command, "B", String(localized: "Sidebar"), icon: "sidebar.left"), chord(.command, "J", String(localized: "Terminal Panel"), icon: "rectangle.bottomthird.inset.filled"),
            chord(.control, "O", String(localized: "Transcript"), icon: "text.justify.left"), chord(.control, "R", String(localized: "History"), icon: "clock.arrow.circlepath"),
            chord(.control, "L", String(localized: "Clear Screen"), icon: "eraser"), chord(.command, "Space", "Spotlight", icon: "magnifyingglass.circle"),
        ]
    }

    private static var blurtKeys: [KeySlot] {
        [
            blurt(.snap, "camera.viewfinder", String(localized: "Snap")), blurt(.record, "record.circle", String(localized: "Record")),
            blurt(.voiceNote, "waveform", String(localized: "Voice Note")), blurt(.copyText, "text.viewfinder", String(localized: "Copy Text")),
            blurt(.translate, "character.bubble", String(localized: "Translate")), blurt(.cards, "rectangle.stack", String(localized: "Cards")),
            chord(.option, "L", String(localized: "Reformat"), icon: "text.badge.checkmark"),
            KeySlot(.system(.findCursor), glyph: "sf:scope", caption: String(localized: "Find Pointer")),
        ]
    }

    private static var moveKeys: [KeySlot] {
        [
            KeySlot(.system(.missionControl), glyph: "sf:rectangle.3.group", caption: String(localized: "All Windows")),
            KeySlot(.system(.appExpose), glyph: "sf:rectangle.grid.2x2", caption: String(localized: "App Windows")),
            KeySlot(.system(.spaceLeft), glyph: "sf:arrow.left.square", caption: String(localized: "Desktop Left")),
            KeySlot(.system(.spaceRight), glyph: "sf:arrow.right.square", caption: String(localized: "Desktop Right")),
        ]
    }

    /// The keyboard's own rows, ten across, so the hand knows where they are. Plain keys, so a held or sticky ⌘ makes them shortcuts and the
    /// Mac's input method treats them as typing.
    private static var letterKeys: [KeySlot] { "1234567890QWERTYUIOPASDFGHJKL;ZXCVBNM,./".map { chord([], String($0)) } }

    private static var symbolKeys: [KeySlot] {
        let pairs: [(String, String, Bool)] = [
            ("!", "1", true), ("@", "2", true), ("#", "3", true), ("$", "4", true), ("%", "5", true),
            ("^", "6", true), ("&", "7", true), ("*", "8", true), ("(", "9", true), (")", "0", true),
            ("-", "-", false), ("_", "-", true), ("=", "=", false), ("+", "=", true), ("[", "[", false),
            ("]", "]", false), ("{", "[", true), ("}", "]", true), ("\\", "\\", false), ("|", "\\", true),
            (":", ";", true), ("'", "'", false), ("\"", "'", true), ("<", ",", true), (">", ".", true),
            ("?", "/", true), ("`", "`", false), ("~", "`", true),
        ]
        var keys = pairs.map { g, k, s in KeySlot(.chord(RemoteChord(s ? .shift : [], k), cycle: false), glyph: g, caption: "") }
        keys += [chord([], "Space"), chord([], "ForwardDelete"), chord([], "Home"), chord([], "End"), chord([], "PageUp"), chord([], "PageDown")]
        keys += (1...12).map { chord([], "F\($0)") }
        return keys
    }

    /// Everything the key picker offers, in groups.
    static var catalogue: [(group: String, slots: [KeySlot])] {
        [
            (String(localized: "Main"), mainKeys),
            (String(localized: "Vibe Coding"), [
                chord(.control, "B", String(localized: "Background"), icon: "square.2.layers.3d"),
                chord(.control, "J", String(localized: "New Line"), icon: "return.left"),
                KeySlot(.sequence([.key(RemoteChord([], "Escape")), .wait(90), .key(RemoteChord([], "Escape"))]), glyph: "esc esc", hint: String(localized: "Rewind")),
                chord([], "1", String(localized: "Option 1")), chord([], "2", String(localized: "Option 2")), chord([], "3", String(localized: "Option 3")),
                chord([.command, .shift], "Delete", String(localized: "Reject"), icon: "xmark.circle"),
                chord(.command, "I", String(localized: "Composer"), icon: "text.bubble"),
                chord(.control, "`", String(localized: "Terminal"), icon: "terminal"),
            ]),
            (String(localized: "Switch"), [
                KeySlot(.nextTab, glyph: "sf:rectangle.stack", hint: String(localized: "Next tab, ⌘⇧] in a terminal")),
                chord(.command, "1", "1"), chord(.command, "2", "2"), chord(.command, "3", "3"), chord(.command, "4", "4"),
            ] + moveKeys),
            (String(localized: "Edit"), [
                chord([], "Return", String(localized: "Send")), chord(.shift, "Return", String(localized: "New Line"), icon: "return.left"), chord([], "Space", String(localized: "Space")),
                KeySlot(.arrows, hint: String(localized: "Arrows")),
                chord([], "Up"), chord([], "Down"), chord([], "Left"), chord([], "Right"),
                chord(.command, "Left", String(localized: "Line Start"), icon: "arrow.left.to.line"), chord(.command, "Right", String(localized: "Line End"), icon: "arrow.right.to.line"),
                chord(.option, "Left", String(localized: "Word Left"), icon: "arrow.left"), chord(.option, "Right", String(localized: "Word Right"), icon: "arrow.right"),
            ]),
            (String(localized: "Modifiers"), [
                sticky(.command, "Command"), sticky(.shift, "Shift"), sticky(.option, "Option"), sticky(.control, "Control"),
                sticky([.command, .shift], "Command Shift"),
            ]),
            (String(localized: "Browser"), [
                chord(.command, "=", String(localized: "Zoom In"), icon: "plus.magnifyingglass"), chord(.command, "-", String(localized: "Zoom Out"), icon: "minus.magnifyingglass"),
            ]),
            ("Blurt", blurtKeys),
            (String(localized: "Letters"), letterKeys),
            (String(localized: "Symbols"), symbolKeys),
        ]
    }

    /// For choosing a key's face.
    static let icons = ["doc.on.doc", "doc.on.clipboard", "scissors", "arrow.uturn.backward", "arrow.uturn.forward", "trash", "magnifyingglass", "link",
                        "plus", "minus", "xmark", "checkmark", "star", "heart", "bolt", "flag", "bookmark", "tag", "pin", "paperclip", "folder", "doc",
                        "terminal", "command", "keyboard", "globe", "safari", "gear", "wrench.and.screwdriver", "hammer", "ant", "sparkles", "brain",
                        "bubble.left", "paperplane", "mic", "camera", "photo", "play", "pause", "stop", "forward", "backward", "sidebar.left",
                        "macwindow", "square.split.2x1", "arrow.clockwise", "arrow.up.to.line", "arrow.down.to.line", "chevron.left", "chevron.right"]
}
