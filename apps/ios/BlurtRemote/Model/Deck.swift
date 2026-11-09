// The keys (docs/design/remote.md §Keys). Pages of the same shape, with tabs; a page that grows scrolls. Every key can be moved anywhere. A dock stays put below it, for what's needed wherever the list is. A key shows an icon and the name
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
    /// what the key shows, large: "sf:name" for an SF Symbol, "mark:name" for one drawn here (KeyMarks), or any text or emoji. nil = the key's own name
    var glyph: String?
    /// the small line under it; nil = the key's name where the large part is something else
    var caption: String?
    /// what it's for, in the key list and to VoiceOver. Never on the key: a shortcut means different things in different apps
    var hint: String?
    /// columns wide: the space bar. nil = one
    var span: Int?

    init(_ action: KeyAction, glyph: String? = nil, caption: String? = nil, hint: String? = nil) {
        self.action = action; self.glyph = glyph; self.caption = caption; self.hint = hint
    }

    /// The key's own name, as the computer writes it: ⌘C on a Mac, Ctrl+C on Windows and Linux.
    private func keyName(on h: RemoteHost) -> String? {
        switch action {
        case let .chord(c, _): return h.label(c)
        case let .sequence(s): return s.compactMap { if case let .key(c) = $0 { h.label(c) } else { nil } }.joined(separator: " ")
        case let .sticky(m): return h.label(m)
        case .nextTab: return h.label(RemoteChord(.control, "Tab"))
        default: return nil
        }
    }

    /// A shortcut with no icon, on a PC: the key large and its modifiers under it, as a keycap reads (K, Ctrl). On a Mac it's written out (⌘K).
    private func keycap(on h: RemoteHost) -> RemoteChord? {
        guard h != .mac, glyph == nil, case let .chord(c, _) = action, !c.mods.isEmpty, !c.key.isEmpty else { return nil }
        return c
    }

    func face(on h: RemoteHost) -> String {
        if let glyph { return glyph }
        switch action {
        case let .chord(c, _) where c.mods.isEmpty && c.key == "Return": return "sf:return"
        case let .chord(c, _) where c.mods.isEmpty && c.key == "Delete": return "sf:delete.left"
        case let .text(t, _): return String(t.prefix(8))
        case .arrows: return "sf:arrow.up.and.down.and.arrow.left.and.right"
        case .blurt: return "sf:bird"
        case .system: return "sf:macwindow"
        case .sticky(.command) where h == .windows: return "mark:win"
        default:
            if let c = keycap(on: h) { return h.keyName(c.key) }
            return keyName(on: h) ?? ""
        }
    }

    /// The small line: yours, or the key's name under an icon, so what's pressed is always there to read.
    func detail(on h: RemoteHost) -> String? {
        if let caption { return caption.isEmpty ? nil : caption }
        if let c = keycap(on: h) { return h.label(c.mods) }
        guard let n = keyName(on: h) else { return nil }
        if glyph == nil, h == .windows, case .sticky(.command) = action { return n }     // the drawn Win key, named under it
        return glyph == nil ? nil : n
    }

    /// What the key is called in lists.
    func title(on h: RemoteHost) -> String { hint ?? caption ?? keyName(on: h) ?? face(on: h) }

    /// As the computer in hand has them.
    var face: String { face(on: .shown) }
    var detail: String? { detail(on: .shown) }
    var title: String { title(on: .shown) }
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
    /// it needs room to slide all four ways, so it has its own place. In landscape three stay out when the keys are put away (PadLayout.thumbSlots)
    var dock: [KeySlot]
    var sections: [KeySection]

    static let columns = 6
    /// the four modifiers, four that end or move things, and the space bar
    static let dockCount = 9
    static let maxSections = 6

    private static let storeKey = "deck.v9"

    static func load() -> Deck {
        let u = UserDefaults.standard
        func stored(_ key: String, dock n: Int) -> Deck? {
            guard let d = u.data(forKey: key), let deck = try? JSONDecoder().decode(Deck.self, from: d), !deck.sections.isEmpty, deck.dock.count == n else { return nil }
            return deck
        }
        if let deck = stored(storeKey, dock: dockCount) { return deck }
        // set up by an earlier version: kept, brought up to date
        var deck: Deck
        if let d = stored("deck.v8", dock: dockCount) {
            deck = d
        } else if var d = stored("deck.v7", dock: 8) {
            // the space bar joins the dock, or if it was moved into the dock already, the first of the usual ones it lacks
            let hasSpace = d.dock.contains { $0.action == spaceBar.action }
            d.dock.append(hasSpace ? Deck.standard.dock.first { s in !d.dock.contains { $0.action == s.action } } ?? spaceBar : spaceBar)
            deck = d
        } else {
            return .standard
        }
        // 字母 and 符号 as they shipped, untouched since: the new ones. A page its owner changed stays as it is
        let now = Deck.standard.sections
        for i in deck.sections.indices {
            let a = deck.sections[i].slots.map(\.action)
            if a == Self.lettersBefore.map(\.action) { deck.sections[i].slots = now[1].slots }
            if a == Self.symbolsBefore.map(\.action) { deck.sections[i].slots = now[2].slots }
        }
        deck.save()
        return deck
    }

    static var spaceBar: KeySlot { KeySlot(.chord(RemoteChord([], "Space"), cycle: false), glyph: "sf:space", caption: "", hint: String(localized: "Space")) }

    /// One layout per kind of computer: a Mac's is the one it always was, under its old name; Windows and Linux each have their own.
    private static func key(for h: RemoteHost) -> String { h == .mac ? storeKey : "deck.\(h.rawValue).v1" }

    static func load(for h: RemoteHost) -> Deck {
        guard h != .mac else { return load() }
        guard let d = UserDefaults.standard.data(forKey: key(for: h)), let deck = try? JSONDecoder().decode(Deck.self, from: d), !deck.sections.isEmpty,
              deck.dock.count == dockCount else { return standard(for: h) }
        return deck
    }

    func save(for h: RemoteHost) {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key(for: h)) }
    }

    func save() { save(for: .mac) }
}

// MARK: - What it ships with

/// An icon where there's a good one, the key's name under it. No words for what it does: that depends on the app.
private func chord(_ m: RemoteModifiers, _ k: String, _ hint: String? = nil, cycle: Bool = false, icon: String? = nil, mark: String? = nil, glyph: String? = nil) -> KeySlot {
    KeySlot(.chord(RemoteChord(m, k), cycle: cycle), glyph: icon.map { "sf:\($0)" } ?? mark.map { "mark:\($0)" } ?? glyph, hint: hint)
}

private func blurt(_ c: RemoteBlurtCommand, _ symbol: String, _ caption: String) -> KeySlot {
    KeySlot(.blurt(c), glyph: "sf:\(symbol)", caption: caption, hint: caption)
}

private func sticky(_ m: RemoteModifiers, _ name: String) -> KeySlot { KeySlot(.sticky(m), hint: name) }

extension Deck {
    /// Few enough to remember: a row each for editing, moving between things, acting on them, and Blurt. What a tap on a modifier and a key
    /// already in view can do (⌥⌫, ⌘↩, ⌘⌫), and what's a tap on the picture away (⌘L), stays out of the way; every one is in the key picker.
    /// The dock is what a phone's own keyboard has no key for, what ends things, and the space bar. The keys that get used most sit by the
    /// thumb, next to the talk key.
    static var standard: Deck {
        Deck(dock: [
            sticky(.control, "Control"), sticky(.option, "Option"), sticky(.command, "Command"), sticky(.shift, "Shift"),
            KeySlot(.chord(RemoteChord([], "Tab"), cycle: false), glyph: "sf:arrow.right.to.line", caption: "", hint: String(localized: "Complete")),
            chord([], "Escape", String(localized: "Stop")), chord([], "Delete", String(localized: "Delete")), chord([], "Return", String(localized: "Send")),
            spaceBar,
        ], sections: [
            KeySection(String(localized: "Main"), editKeys + switchKeys + actionKeys + blurtKeys),
            KeySection(String(localized: "Letters"), letterKeys, columns: 10),
            KeySection(String(localized: "Symbols"), symbolKeys, columns: 10),
            KeySection(String(localized: "More"), functionKeys + macKeys),
        ])
    }

    private static var editKeys: [KeySlot] {
        [
            chord(.command, "C", String(localized: "Copy"), icon: "doc.on.doc"), chord(.command, "V", String(localized: "Paste"), icon: "clipboard"),
            chord(.command, "X", String(localized: "Cut"), icon: "scissors"), chord(.command, "Z", String(localized: "Undo"), icon: "arrow.uturn.backward"),
            chord([.command, .shift], "Z", String(localized: "Redo"), icon: "arrow.uturn.forward"), chord(.command, "A", String(localized: "Select All"), mark: "selectAll"),
        ]
    }

    /// Between apps, windows, tabs, pages. Holding and sliding steps both ways, so there's no key for going back through apps.
    private static var switchKeys: [KeySlot] {
        [
            chord(.command, "Tab", String(localized: "Apps"), cycle: true, mark: "apps"), chord(.command, "`", String(localized: "Windows"), cycle: true, icon: "macwindow.on.rectangle"),
            chord(.command, "[", String(localized: "Back"), icon: "chevron.left"), chord(.command, "]", String(localized: "Forward"), icon: "chevron.right"),
            chord([.control, .shift], "Tab", String(localized: "Previous Tab"), cycle: true, mark: "tabPrevious"), chord(.control, "Tab", String(localized: "Next Tab"), cycle: true, mark: "tabNext"),
        ]
    }

    private static var actionKeys: [KeySlot] {
        [
            chord(.command, "F", String(localized: "Find"), icon: "doc.text.magnifyingglass"),
            // written out: what ⌘K does depends entirely on the app, and ⌃C mustn't look like ⌘W, which can close a terminal
            KeySlot(.chord(RemoteChord(.command, "K"), cycle: false), glyph: "⌘K", caption: "", hint: String(localized: "Inline Edit")),
            chord(.command, "Space", "Spotlight", icon: "magnifyingglass"), KeySlot(.chord(RemoteChord(.control, "C"), cycle: false), glyph: "⌃C", caption: "", hint: String(localized: "Interrupt")),
            chord(.command, "T", String(localized: "New Tab"), mark: "tabNew"), chord(.command, "W", String(localized: "Close Tab"), mark: "tabClose"),
        ]
    }

    private static var blurtKeys: [KeySlot] {
        [
            blurt(.snap, "camera.viewfinder", String(localized: "Snap")), blurt(.record, "record.circle", String(localized: "Record")),
            blurt(.voiceNote, "waveform", String(localized: "Voice Note")), blurt(.copyText, "text.viewfinder", String(localized: "Copy Text")),
            blurt(.translate, "character.bubble", String(localized: "Translate")), blurt(.cards, "rectangle.stack", String(localized: "Cards")),
        ]
    }

    /// Kept for whoever wants them on a key; not on one to begin with.
    private static var lessUsedKeys: [KeySlot] {
        [
            chord(.command, "R", String(localized: "Reload"), icon: "arrow.clockwise"), chord([.command, .shift], "T", String(localized: "Reopen Tab"), icon: "arrow.uturn.backward.square"),
            chord(.command, "S", String(localized: "Save"), icon: "square.and.arrow.down"), chord(.command, "L", String(localized: "Address"), icon: "link"),
            chord([.command, .shift], "[", String(localized: "Previous Tab"), icon: "chevron.left.square"), chord([.command, .shift], "]", String(localized: "Next Tab"), icon: "chevron.right.square"),
            chord(.option, "Delete", String(localized: "Delete Word"), icon: "delete.left"), chord([.command], "Delete", String(localized: "Delete Line"), icon: "delete.left.fill"),
            chord([.command], "Return", String(localized: "Accept"), icon: "checkmark.circle"), chord(.shift, "Tab", String(localized: "Back a Field"), icon: "arrow.left.to.line"),
            chord(.command, "P", String(localized: "Open File"), icon: "doc.badge.gearshape"), chord([.command, .shift], "P", String(localized: "Command Palette"), icon: "command.square"),
            chord(.command, "B", String(localized: "Sidebar"), icon: "sidebar.left"), chord(.command, "J", String(localized: "Terminal Panel"), icon: "rectangle.bottomthird.inset.filled"),
            chord(.control, "O", String(localized: "Transcript"), icon: "text.justify.left"), chord(.control, "R", String(localized: "History"), icon: "clock.arrow.circlepath"),
            chord(.control, "L", String(localized: "Clear Screen"), icon: "eraser"),
            chord(.option, "L", String(localized: "Reformat"), icon: "text.badge.checkmark"),
            chord(.control, "Space", String(localized: "Input Source"), icon: "globe"),
            KeySlot(.system(.findCursor), glyph: "sf:scope", caption: String(localized: "Find Pointer")),
        ]
    }

    /// Only a computer has these: what a phone's keyboard can't type, and the Mac's own moves.
    private static var functionKeys: [KeySlot] {
        (1...12).map { chord([], "F\($0)") }
            + [chord([], "Home", glyph: "Home"), chord([], "End", glyph: "End"), chord([], "PageUp", glyph: "PgUp"), chord([], "PageDown", glyph: "PgDn"),
               chord([], "ForwardDelete", String(localized: "Forward Delete"), icon: "delete.right")]
    }

    private static var macKeys: [KeySlot] {
        [
            KeySlot(.system(.missionControl), glyph: "sf:rectangle.3.group", caption: String(localized: "All Windows")),
            KeySlot(.system(.appExpose), glyph: "sf:rectangle.grid.2x2", caption: String(localized: "App Windows")),
            KeySlot(.system(.spaceLeft), glyph: "sf:arrow.left.square", caption: String(localized: "Desktop Left")),
            KeySlot(.system(.spaceRight), glyph: "sf:arrow.right.square", caption: String(localized: "Desktop Right")),
        ]
    }

    /// The keyboard's own four rows, numbers on top, so the hand knows where they are. The space bar is in the dock. Plain keys, so a held
    /// or sticky ⌘ makes them shortcuts and the Mac's input method treats them as typing.
    private static var letterKeys: [KeySlot] {
        "1234567890QWERTYUIOPASDFGHJKL;ZXCVBNM,./".map { chord([], String($0)) }
    }

    /// What ⇧ makes of the number row and the rest of the keyboard's punctuation: everything 字母 has no key for.
    private static var symbolKeys: [KeySlot] {
        let pairs: [(String, String, Bool)] = [
            ("!", "1", true), ("@", "2", true), ("#", "3", true), ("$", "4", true), ("%", "5", true),
            ("^", "6", true), ("&", "7", true), ("*", "8", true), ("(", "9", true), (")", "0", true),
            ("-", "-", false), ("_", "-", true), ("=", "=", false), ("+", "=", true), ("[", "[", false),
            ("]", "]", false), ("{", "[", true), ("}", "]", true), ("\\", "\\", false), ("|", "\\", true),
            (":", ";", true), ("'", "'", false), ("\"", "'", true), ("<", ",", true), (">", ".", true),
            ("?", "/", true), ("`", "`", false), ("~", "`", true),
        ]
        return pairs.map { g, k, s in KeySlot(.chord(RemoteChord(s ? .shift : [], k), cycle: false), glyph: g, caption: "") }
    }

    /// 字母 and 符号 as they were up to 2026-11-08: the space bar on 字母, digits on 符号, and ; / on both.
    private static var lettersBefore: [KeySlot] {
        "QWERTYUIOPASDFGHJKL;ZXCVBNM,./".map { chord([], String($0)) }
            + [KeySlot(.chord(RemoteChord([], "Space"), cycle: false)), chord([], "-"), chord([], "="), chord([], "'")]
    }

    private static var symbolsBefore: [KeySlot] {
        "1234567890".map { chord([], String($0)) } + symbolKeys + [chord([], "/"), chord([], ";")]
    }

    /// Everything the key picker offers, in groups.
    static var catalogue: [(group: String, slots: [KeySlot])] {
        [
            (String(localized: "Main"), editKeys + switchKeys + actionKeys),
            (String(localized: "More"), lessUsedKeys),
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
            ] + macKeys),
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
            (String(localized: "Symbols"), symbolKeys + functionKeys),
        ]
    }

    /// For choosing a key's face.
    static let icons = ["doc.on.doc", "doc.on.clipboard", "scissors", "arrow.uturn.backward", "arrow.uturn.forward", "trash", "magnifyingglass", "link",
                        "plus", "minus", "xmark", "checkmark", "star", "heart", "bolt", "flag", "bookmark", "tag", "pin", "paperclip", "folder", "doc",
                        "terminal", "command", "keyboard", "globe", "safari", "gear", "wrench.and.screwdriver", "hammer", "ant", "sparkles", "brain",
                        "bubble.left", "paperplane", "mic", "camera", "photo", "play", "pause", "stop", "forward", "backward", "sidebar.left",
                        "macwindow", "square.split.2x1", "arrow.clockwise", "arrow.up.to.line", "arrow.down.to.line", "chevron.left", "chevron.right"]
}

// MARK: - Windows and Linux (docs/design/remote-protocol.md §Default keys per host)

/// The modifiers as that computer's keyboard has them. The same bits as a Mac's: command is Win or Super there, option is Alt.
private let C = RemoteModifiers.control, W = RemoteModifiers.command, A = RemoteModifiers.option, S = RemoteModifiers.shift

extension Deck {
    /// What each kind of computer starts with. A Mac's is the one it always had.
    static func standard(for h: RemoteHost) -> Deck { h == .mac ? standard : pc(h) }

    /// Everything the key picker offers for that computer.
    static func catalogue(for h: RemoteHost) -> [(group: String, slots: [KeySlot])] { h == .mac ? catalogue : pcCatalogue(h) }

    /// The one cycle key in the thumb's column in landscape, there when the keys are put away: ⌘Tab on a Mac, Alt+Tab elsewhere.
    static func appsKey(for h: RemoteHost) -> KeySlot {
        KeySlot(.chord(RemoteChord(h == .mac ? .command : A, "Tab"), cycle: true), glyph: "mark:apps", caption: "", hint: String(localized: "Apps"))
    }

    /// The same four rows as a Mac's, each key the one that computer uses for it. Ctrl+C is copy there, so the third row's interrupt slot is
    /// Ctrl+Shift+C, copy in a terminal; Win or Super alone opens Start or Activities.
    private static func pc(_ h: RemoteHost) -> Deck {
        Deck(dock: [
            KeySlot(.sticky(C), hint: h.name(C)), KeySlot(.sticky(W), hint: h.name(W)), KeySlot(.sticky(A), hint: h.name(A)), KeySlot(.sticky(S), hint: h.name(S)),
            KeySlot(.chord(RemoteChord([], "Tab"), cycle: false), glyph: "sf:arrow.right.to.line", caption: "", hint: String(localized: "Complete")),
            chord([], "Escape", String(localized: "Stop")), chord([], "Delete", String(localized: "Delete")), chord([], "Return", String(localized: "Send")),
            spaceBar,
        ], sections: [
            KeySection(String(localized: "Main"), pcEdit(h) + pcSwitch(h) + pcAction(h) + blurtKeys),
            KeySection(String(localized: "Letters"), letterKeys, columns: 10),
            KeySection(String(localized: "Symbols"), symbolKeys, columns: 10),
            KeySection(String(localized: "More"), functionKeys + pcMore(h)),
        ])
    }

    private static func pcEdit(_ h: RemoteHost) -> [KeySlot] {
        [
            chord(C, "C", String(localized: "Copy"), icon: "doc.on.doc"), chord(C, "V", String(localized: "Paste"), icon: "clipboard"),
            chord(C, "X", String(localized: "Cut"), icon: "scissors"), chord(C, "Z", String(localized: "Undo"), icon: "arrow.uturn.backward"),
            h == .windows ? chord(C, "Y", String(localized: "Redo"), icon: "arrow.uturn.forward") : chord([C, S], "Z", String(localized: "Redo"), icon: "arrow.uturn.forward"),
            chord(C, "A", String(localized: "Select All"), mark: "selectAll"),
        ]
    }

    private static func pcSwitch(_ h: RemoteHost) -> [KeySlot] {
        [
            chord(A, "Tab", String(localized: "Apps"), cycle: true, mark: "apps"),
            h == .windows ? chord(W, "Tab", String(localized: "Task View"), icon: "rectangle.3.group")
                : chord(A, "`", String(localized: "Windows"), cycle: true, icon: "macwindow.on.rectangle"),
            chord(A, "Left", String(localized: "Back"), icon: "chevron.left"), chord(A, "Right", String(localized: "Forward"), icon: "chevron.right"),
            chord([C, S], "Tab", String(localized: "Previous Tab"), cycle: true, mark: "tabPrevious"), chord(C, "Tab", String(localized: "Next Tab"), cycle: true, mark: "tabNext"),
        ]
    }

    private static func pcAction(_ h: RemoteHost) -> [KeySlot] {
        [
            chord(C, "F", String(localized: "Find"), icon: "doc.text.magnifyingglass"),
            // no icon: K large with Ctrl under it, as ⌘K is written out on a Mac
            chord(C, "K", String(localized: "Inline Edit")),
            // the key alone, as a Mac's ⌘Space: search for anything
            chord(W, "", h == .windows ? String(localized: "Start") : String(localized: "Activities"), icon: "magnifyingglass"),
            chord([C, S], "C", String(localized: "Copy in Terminal")),
            chord(C, "T", String(localized: "New Tab"), mark: "tabNew"), chord(C, "W", String(localized: "Close Tab"), mark: "tabClose"),
        ]
    }

    /// The computer's own moves, on 更多 after the F-keys and navigation.
    private static func pcMore(_ h: RemoteHost) -> [KeySlot] {
        h == .windows ? [
            chord(W, "D", String(localized: "Desktop"), icon: "menubar.dock.rectangle"), chord(W, "E", String(localized: "Files"), icon: "folder"),
            chord(W, "L", String(localized: "Lock"), icon: "lock"), chord(A, "F4", String(localized: "Close Window"), icon: "xmark.rectangle"),
            chord([C, S], "Escape", String(localized: "Task Manager"), icon: "waveform.path.ecg.rectangle"),
            chord([W, S], "S", String(localized: "Snip"), icon: "rectangle.dashed"),
        ] : [
            chord(W, "D", String(localized: "Desktop"), icon: "menubar.dock.rectangle"), chord(W, "L", String(localized: "Lock"), icon: "lock"),
            chord(A, "F4", String(localized: "Close Window"), icon: "xmark.rectangle"),
        ]
    }

    private static func pcSystem(_ h: RemoteHost) -> [KeySlot] {
        h == .windows ? [
            KeySlot(.system(.missionControl), glyph: "sf:rectangle.3.group", caption: String(localized: "Task View")),
            KeySlot(.system(.spaceLeft), glyph: "sf:arrow.left.square", caption: String(localized: "Desktop Left")),
            KeySlot(.system(.spaceRight), glyph: "sf:arrow.right.square", caption: String(localized: "Desktop Right")),
        ] : [
            KeySlot(.system(.missionControl), glyph: "sf:rectangle.3.group", caption: String(localized: "Activities")),
            KeySlot(.system(.appExpose), glyph: "sf:rectangle.grid.2x2", caption: String(localized: "App Windows")),
            KeySlot(.system(.spaceLeft), glyph: "sf:arrow.left.square", caption: String(localized: "Workspace Left")),
            KeySlot(.system(.spaceRight), glyph: "sf:arrow.right.square", caption: String(localized: "Workspace Right")),
        ]
    }

    /// The Mac's picker, each key the one that computer uses. Left out: what's Mac only (Spotlight is Start or Activities here, ⌘` is
    /// Alt+` on Linux and nothing on Windows, ⌘⌫ has no one key), and what would be a second key for one already here: ⌘B and ⌘J are
    /// Ctrl+B and Ctrl+J, already Background and New Line; ⌃R and ⌃L are Ctrl+R and Ctrl+L, already Reload and Address.
    private static func pcCatalogue(_ h: RemoteHost) -> [(group: String, slots: [KeySlot])] {
        [
            (String(localized: "Main"), pcEdit(h) + pcSwitch(h) + pcAction(h)),
            (String(localized: "More"), [
                chord(C, "R", String(localized: "Reload"), icon: "arrow.clockwise"), chord([C, S], "T", String(localized: "Reopen Tab"), icon: "arrow.uturn.backward.square"),
                chord(C, "S", String(localized: "Save"), icon: "square.and.arrow.down"), chord(C, "L", String(localized: "Address"), icon: "link"),
                chord(C, "PageUp", String(localized: "Previous Tab"), icon: "chevron.left.square"), chord(C, "PageDown", String(localized: "Next Tab"), icon: "chevron.right.square"),
                chord(C, "Delete", String(localized: "Delete Word"), icon: "delete.left"),
                chord(C, "Return", String(localized: "Accept"), icon: "checkmark.circle"), chord(S, "Tab", String(localized: "Back a Field"), icon: "arrow.left.to.line"),
                chord(C, "P", String(localized: "Open File"), icon: "doc.badge.gearshape"), chord([C, S], "P", String(localized: "Command Palette"), icon: "command.square"),
                chord(C, "O", String(localized: "Transcript"), icon: "text.justify.left"),
                chord(A, "L", String(localized: "Reformat"), icon: "text.badge.checkmark"),
                chord(W, "Space", String(localized: "Input Source"), icon: "globe"),
                KeySlot(.system(.findCursor), glyph: "sf:scope", caption: String(localized: "Find Pointer")),
            ] + pcMore(h)),
            (String(localized: "Vibe Coding"), [
                chord(C, "B", String(localized: "Background"), icon: "square.2.layers.3d"),
                chord(C, "J", String(localized: "New Line"), icon: "return.left"),
                KeySlot(.sequence([.key(RemoteChord([], "Escape")), .wait(90), .key(RemoteChord([], "Escape"))]), glyph: "Esc Esc", hint: String(localized: "Rewind")),
                chord([], "1", String(localized: "Option 1")), chord([], "2", String(localized: "Option 2")), chord([], "3", String(localized: "Option 3")),
                chord([C, S], "Delete", String(localized: "Reject"), icon: "xmark.circle"),
                chord(C, "I", String(localized: "Composer"), icon: "text.bubble"),
                chord(C, "`", String(localized: "Terminal"), icon: "terminal"),
            ]),
            (String(localized: "Switch"), [
                KeySlot(.nextTab, glyph: "sf:rectangle.stack", hint: h == .linux ? String(localized: "Next tab, Ctrl+PgDn in a terminal") : String(localized: "Next Tab")),
                chord(C, "1", "1"), chord(C, "2", "2"), chord(C, "3", "3"), chord(C, "4", "4"),
            ] + pcSystem(h)),
            (String(localized: "Edit"), [
                chord([], "Return", String(localized: "Send")), chord(S, "Return", String(localized: "New Line"), icon: "return.left"), chord([], "Space", String(localized: "Space")),
                KeySlot(.arrows, hint: String(localized: "Arrows")),
                chord([], "Up"), chord([], "Down"), chord([], "Left"), chord([], "Right"),
                chord(C, "Left", String(localized: "Word Left"), icon: "arrow.left"), chord(C, "Right", String(localized: "Word Right"), icon: "arrow.right"),
            ]),
            (String(localized: "Modifiers"), [
                KeySlot(.sticky(C), hint: h.name(C)), KeySlot(.sticky(W), hint: h.name(W)), KeySlot(.sticky(A), hint: h.name(A)), KeySlot(.sticky(S), hint: h.name(S)),
                KeySlot(.sticky([C, S]), hint: h.label([C, S])),
            ]),
            (String(localized: "Browser"), [
                chord(C, "=", String(localized: "Zoom In"), icon: "plus.magnifyingglass"), chord(C, "-", String(localized: "Zoom Out"), icon: "minus.magnifyingglass"),
            ]),
            ("Blurt", blurtKeys),
            (String(localized: "Letters"), letterKeys),
            (String(localized: "Symbols"), symbolKeys + functionKeys),
        ]
    }
}
