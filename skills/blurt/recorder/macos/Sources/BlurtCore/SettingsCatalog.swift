// Every setting the Settings window shows, as data: its panes (in the sidebar's groups), each pane's sections, and one
// entry per row — its id, its title and one-line description (string keys), a longer explanation where there is one,
// and search keywords (settings.kw.<id>, both languages). The panes render their rows from these entries
// (BlurtApp Settings/SettingsKit.swift: SettingRow("general.login") takes its title and description from here), and
// the window's search runs over the same entries, so the index can't drift from what is on screen;
// SettingsCatalogTests checks every key exists in both languages and that each id is rendered exactly once.
//
// Ids are "<pane>.<name>". A `.section` entry is a whole section (a list like the projects or the models) that search
// can land on; `generated` rows come out of a ForEach over an enum (the shortcuts, the dictation app categories, the
// speech purposes, General's capability switches); `fold` names the row whose disclosure hides the entry until a
// search jumps there, or whose menu holds it (SettingMenuToggle / SettingMenuPicker: a search lands on that row).
// Capabilities (Capabilities.swift, v1.0.23): the panes are arranged by them, and one that is turned off takes its
// pane, its rows elsewhere (its shortcuts) and its search results with it — `paneShown`, `rowShown`, `results(_:off:)`
// — while its switch in General ("general.feature.<id>") stays, and is where a link to anything of it lands (`landing`).
// Search: every word of the query has to appear in the entry's title, description, keywords or section — in the UI
// language or in the other one — scored title first. Plain substring matching, no language rules. The results come in
// groups, one per pane, best group first (ties: the sidebar's order), each by section, best first: what the results
// page shows and what the sidebar counts. A query that names a pane ("short", "快捷") — or, when no row matches by its
// own words, one that matches a pane's keywords ("hotkey") — finds the pane as a whole: its group leads, the pane itself
// is its first hit and its rows follow in the page's order. Actions (Restore defaults) are only found by their own words.
import Foundation

public struct SettingsText: Hashable {
    public let key: String
    public let table: String
    public init(_ key: String, _ table: String) { self.key = key; self.table = table }
}

public struct SettingsEntry: Hashable {
    public enum Kind: Hashable { case row, section }
    public let id: String
    public let kind: Kind
    /// The section it is in (a section entry: itself); nil = an untitled group.
    public let section: String?
    public let title: SettingsText
    public let detail: SettingsText?
    /// A longer explanation (the row's tooltip), searched too.
    public let more: SettingsText?
    /// The row whose disclosure folds this one away, or whose menu holds it.
    public let fold: String?
    public let generated: Bool
    public var pane: String { String(id.prefix { $0 != "." }) }
    public var keywords: SettingsText { SettingsText("settings.kw.\(id)", "Settings") }
}

public struct SettingsSection: Hashable {
    public let id: String
    public let title: SettingsText
    public var pane: String { String(id.prefix { $0 != "." }) }
}

public struct SettingsPaneInfo: Hashable {
    public let id: String
    public let title: SettingsText
    /// SF Symbol name
    public let symbol: String
    public let group: String
    public var keywords: SettingsText { SettingsText("settings.kw.pane.\(id)", "Settings") }
}

public struct SettingsHit: Hashable {
    public let entry: SettingsEntry
    public let score: Int
}

/// One pane's share of the results.
public struct SettingsResultGroup: Hashable {
    public let pane: String
    /// The query names the pane (or matches only its keywords): the pane itself is the group's first hit, and `hits`
    /// are all its settings, in the page's order.
    public let paneHit: Bool
    /// The settings found, by section (best section first, a section's own entry leading it), best first in a section.
    public let hits: [SettingsHit]
    public let score: Int
}

public enum SettingsCatalog {
    // MARK: panes

    /// The sidebar's groups, in order: (id, title). v1.0.23: by capability (Capabilities.swift) — Features: one pane per
    /// thing Blurt does, named and drawn as in the main window's sidebar, each there only while its capability is on
    /// (`paneShown`) · App: what every feature shares (General with the five switches, Models, Shortcuts, Agents) ·
    /// This Mac: Privacy, Storage. Before, Preferences / Work / This Mac, with the recording, voice-note and card
    /// settings in General.
    public static let groups: [(id: String, title: SettingsText)] = [
        ("features", SettingsText("settings.group.features", "Settings")),
        ("app", SettingsText("settings.group.app", "Settings")),
        ("mac", SettingsText("settings.group.mac", "Settings")),
    ]

    public static let panes: [SettingsPaneInfo] = [
        // a capability's pane is named as the capability is everywhere (feature.<id>, Home.strings)
        pane("dictation", "feature.dictation", "Home", "character.cursor.ibeam", "features"),
        // snaps, voice notes and what a dragged card carries (v1.0.23: before, two boxes in General)
        pane("cards", "feature.cards", "Home", "rectangle.stack", "features"),
        // ⌥C and ⌥T (2026-10-30: its own page; before, a box in General)
        pane("screentext", "feature.screen_text", "Home", "text.viewfinder", "features"),
        // a recording and what becomes of it (v1.0.23: before, a box in General); its projects follow
        pane("recording", "feature.recording", "Home", "record.circle", "features"),
        pane("projects", "main.sidebar.projects", "Main", "folder", "features"),
        // phones, and the computers this Mac drives or that drive it (docs/design/remote-desktop-viewer.md)
        pane("remote", "feature.phone", "Home", "laptopcomputer.and.iphone", "features"),
        pane("general", "settings.kit.general", "Settings", "gearshape", "app"),
        // sidebar glyphs with an empty inside and few details at 13 pt (dogfood 2026-11-21: cpu, keyboard and
        // internaldrive read as fine grilles beside the outlines): a model is a cube, a shortcut ⌘, storage a drive
        pane("speech", "settings.kit.speech", "Settings", "cube", "app"),
        pane("shortcuts", "settings.kit.shortcuts", "Settings", "command", "app"),
        pane("agents", "settings.kit.agents", "Settings", "paperplane", "app"),   // 交给 Agent's glyph: the wand is dictation polish
        pane("privacy", "settings.kit.privacy", "Settings", "hand.raised", "mac"),
        pane("storage", "settings.kit.storage", "Settings", "externaldrive", "mac"),
    ]

    /// The searches the no-match page offers (in the UI language): each finds rows in every language
    /// (SettingsCatalogTests), so a miss always has somewhere to go.
    public static let suggestions: [SettingsText] = ["shortcut", "model", "microphone", "language"]
        .map { SettingsText("settings.search.try.\($0)", "Settings") }

    public static func pane(_ id: String) -> SettingsPaneInfo? { panes.first { $0.id == id } }

    /// The capability a pane is the settings of (Capabilities.swift); nil: the app's own panes, always there.
    public static func capability(ofPane id: String) -> Capability? {
        switch id {
        case "dictation": return .dictation
        case "cards": return .cards
        case "screentext": return .screenText
        case "recording", "projects": return .recording
        case "remote": return .phone
        default: return nil
        }
    }

    /// A capability's own pane (Recording & Items', not the Projects that go with it): its glyph is the capability's.
    public static func pane(of c: Capability) -> SettingsPaneInfo? { panes.first { capability(ofPane: $0.id) == c } }

    /// A capability that is off has no pane: not in the sidebar, not in search, and a link to it lands on General
    /// (where the five switches are).
    public static func paneShown(_ id: String, off: Set<Capability> = Capability.off) -> Bool {
        capability(ofPane: id).map { !off.contains($0) } ?? true
    }

    /// The capability a row belongs to when that isn't its pane's: a shortcut's owner (the Shortcuts pane lists every
    /// capability's keys), the dictation key shown there, and Projects' "new snaps and voice notes go to" (Cards').
    public static func capability(ofRow id: String) -> Capability? {
        if id == "shortcuts.dictation_key" { return .dictation }
        if id.hasPrefix("shortcuts."), let a = HotkeyCenter.Action(rawValue: String(id.dropFirst("shortcuts.".count))) {
            return Capability.owner(of: a)
        }
        if id == "projects.capture_into" || id == "projects.capture" { return .cards }
        return nil
    }

    /// Whether a row (or a section) is drawn and found: its pane is there, and so is the capability it belongs to. The
    /// words under the notch while you speak are dictation's and the voice note's alike: gone only with both.
    public static func rowShown(_ id: String, off: Set<Capability> = Capability.off) -> Bool {
        guard paneShown(String(id.prefix { $0 != "." }), off: off) else { return false }
        if id == "general.live_text" { return !(off.contains(.dictation) && off.contains(.cards)) }
        return capability(ofRow: id).map { !off.contains($0) } ?? true
    }

    /// A capability's switch in General's Features section: where a link to something of an off capability lands.
    public static func featureRow(_ c: Capability) -> String { "general.feature.\(c.rawValue)" }

    /// Where a link ("cards", "cards/cards.snap_sound", "shortcuts/snap" — after `redirect`) lands with these
    /// capabilities off: where it says, or, its pane or its row being an off capability's, General at that
    /// capability's switch ("general/general.feature.cards") — one click from having it back.
    public static func landing(_ link: String, off: Set<Capability> = Capability.off) -> String {
        let pane = String(link.prefix { $0 != "/" })
        if let c = capability(ofPane: pane), off.contains(c) { return "general/\(featureRow(c))" }
        guard link.count > pane.count + 1 else { return link }
        let rest = String(link.dropFirst(pane.count + 1))
        let row = rest.contains(".") ? rest : "\(pane).\(rest)"
        if let c = capability(ofRow: row), off.contains(c) { return "general/\(featureRow(c))" }
        return link
    }

    /// Panes that are gone, and where their links (blurt://settings/<pane>[/<row>], a remembered last pane) land now.
    /// Export went in v0.9: the user's agent sends items with its own tools, so Agents says how to ask it.
    public static let moved: [String: String] = ["export": "agents/agents.ask"]

    /// Rows that moved to another place (v0.9: the projects got their own pane, the Dictation Lab went to Dictation's
    /// Advanced, the four drag switches became one choice, About became General's closing line): old row → new row.
    public static let movedRows: [String: String] = [
        "general.projects": "projects.list", "general.capture_into": "projects.capture_into",
        "general.dictation_lab": "dictation.lab", "general.developer": "dictation.advanced",
        "general.smart_paste": "cards.card_drag", "general.drag_caption": "cards.card_drag", "general.drag_copy_note": "cards.card_drag",
        // v1.0.23: Settings by capability — General's Voice notes and Cards boxes are the Cards pane, its Recording
        // box the Recording & Items pane (the words under the notch stay in General: dictation shows them too)
        "general.collect": "cards.collect", "general.snap_sound": "cards.snap_sound",
        "general.voice_end_on_pause": "cards.voice_end_on_pause",
        "general.card_drag": "cards.card_drag", "general.agent_drag": "cards.agent_drag", "general.drag_note_file": "cards.drag_note_file",
        "general.cards": "cards.snaps", "general.voice": "cards.voice",
        "general.after_recording": "recording.after_recording", "general.countdown": "recording.countdown",
        "general.system_audio": "recording.system_audio", "general.hide_notch": "recording.hide_notch",
        "general.recording": "recording.capture",
        // v1.0.8: one cloud service became a list of them, and each job its row (Settings → Models)
        "dictation.cloud_polish": "speech.polish", "speech.cloud_polish": "speech.polish",
        "dictation.translate_cloud": "dictation.translate_model", "screentext.translate_cloud": "screentext.translate_model",
        "general.version": "general.about", "general.help": "general.about", "general.assistant": "general.about",
        // 2026-10-30: Copy Text from Screen got its own page
        "general.screen_text_refine": "screentext.refine", "general.screen_text_translate": "screentext.translate",
        "general.screen_text": "screentext.copy",
    ]

    /// "export" or "export/target" → "agents/agents.ask"; "general/general.capture_into" (or "general/capture_into") →
    /// "projects/projects.capture_into"; anything else as it is.
    public static func redirect(_ link: String) -> String {
        let pane = String(link.prefix { $0 != "/" })
        if let to = moved[pane] { return to }
        guard link.count > pane.count + 1 else { return link }
        let row = String(link.dropFirst(pane.count + 1))
        guard let to = movedRows[row.contains(".") ? row : "\(pane).\(row)"] else { return link }
        return "\(to.prefix { $0 != "." })/\(to)"
    }

    // MARK: sections

    public static let sections: [SettingsSection] = [
        // General: the five capabilities' switches, then the app's own choices
        sec("general.features", "settings.general.features"),
        sec("general.app", "settings.general.app"),
        sec("general.about", "settings.general.about"),

        // Cards, in the order a card is made and used: taking a snap, the voice note, dragging the card out
        sec("cards.snaps", "settings.cards.section.snaps"),
        sec("cards.voice", "settings.general.section.voice"),
        sec("cards.drag", "settings.cards.section.drag"),

        // Recording & Items: the recording itself, then what becomes of it
        sec("recording.capture", "settings.general.recording"),
        sec("recording.items", "settings.recording.section.items"),

        sec("projects.list", "main.sidebar.projects", "Main"),
        sec("projects.capture", "settings.projects.capture_heading"),

        // Dictation: how dictating works (untitled: named like the page), then what comes out — the style, the words,
        // the history, the models. Permissions are a notice at the top only while one is missing.
        sec("dictation.main", "dictation.settings.section", "Dictation"),
        sec("dictation.text", "dictation.text.section", "Dictation"),
        sec("dictation.translation", "dictation.translate.section", "Dictation"),
        sec("dictation.data", "dictation.data.section", "Dictation"),
        sec("dictation.advanced", "settings.general.section.developer"),

        // Speech: which model does each job (and is the recommended set in), the languages, a folded Advanced; the
        // model library is a sheet ("Manage Models…") that a search or a link opens
        // Copy Text from Screen: ⌥C's reading, then ⌥T's translation
        sec("screentext.copy", "settings.screen_text.section.copy"),
        sec("screentext.translation", "settings.screen_text.section.translate"),
        sec("screentext.history_section", "settings.screen_text.section.history"),

        // 远程控制 / Remote Control: On this Mac (what this Mac does for its devices) and Other networks (how one on another
        // network gets here). The devices themselves are on the main window's page of the same name
        // (docs/design/remote-desktop-viewer.md §One page for the devices); the pane's first row leads there.
        sec("remote.options", "settings.remote.section.options"),
        sec("remote.relay", "settings.remote.section.relay"),

        sec("speech.use", "speech.section.mac", "Speech"),
        sec("speech.services", "models.section.services", "Models"),
        sec("speech.jobs", "speech.section.jobs", "Speech"),
        sec("speech.languages", "speech.section.languages", "Speech"),
        sec("speech.advanced", "speech.section.advanced", "Speech"),
        sec("speech.models", "speech.section.models", "Speech"),
        // dictation's choices side by side, a sheet (Compare… on the page's lead) that a search or a link opens
        sec("speech.compare", "speech.compare.title", "Speech"),

        sec("shortcuts.capture", "capture.keys.section.capture", "Capture"),
        sec("shortcuts.recording", "capture.keys.while_recording", "Capture"),
        sec("shortcuts.dictation", "dictation.settings.tab", "Dictation"),
        sec("shortcuts.open", "capture.keys.section.open", "Capture"),

        // v1.0.26, in the order people come for: using Blurt in their agent, background organizing (its list, then
        // its model and effort, untitled under it), the apps a dragged card goes into, asking an agent
        sec("agents.use", "agents.use.header", "Agents"),
        sec("agents.list", "agents.organize.header", "Agents"),
        sec("agents.organize", "agents.organize.header", "Agents"),
        sec("agents.drop", "agents.drop.header", "Agents"),
        sec("agents.ask", "agents.ask.header", "Agents"),

        sec("privacy.permissions", "settings.privacy.permissions_live"),
        sec("privacy.data", "settings.privacy.data"),

        sec("storage.recordings", "settings.storage.recordings"),
        sec("storage.models", "settings.storage.models"),
        sec("storage.files", "settings.storage.app_data"),
    ]

    public static func section(_ id: String) -> SettingsSection? { sections.first { $0.id == id } }

    // MARK: entries

    /// The Shortcuts page's sections and their actions (HotkeyCenter.Action raw values), in the page's order: what you
    /// capture, the keys of a recording in progress, dictation, and opening or switching things. The dictation key
    /// (set in Settings → Dictation) leads its section, ahead of these.
    public static let shortcutSections: [(section: String, actions: [String])] = [
        ("shortcuts.capture", ["record", "snap", "text", "translate", "voice"]),
        ("shortcuts.recording", ["pause", "pen", "stop"]),
        ("shortcuts.dictation", ["reformat"]),
        ("shortcuts.open", ["project", "cards", "menu", "main"]),
    ]
    /// The section an action's row is in.
    public static func shortcutSection(_ action: String) -> String? { shortcutSections.first { $0.actions.contains(action) }?.section }
    /// The actions whose name needs a line to say what it does (capture.action.<name>.detail).
    public static let describedShortcuts: Set<String> = ["cards", "reformat", "text", "translate"]
    /// The three jobs of speech recognition (BlurtApp ASRPurpose), in the pane's order.
    public static let speechPurposes = ["batch", "live", "note"]

    public static let entries: [SettingsEntry] = {
        var e: [SettingsEntry] = [
            // General: the capabilities' switches (the section is found by "features", "功能"; each switch by its
            // capability's name and by "turn off", "关闭"), then the app's own rows
            whole("general.features", detail: S("settings.general.features.footer")),
        ]
        for c in Capability.allCases {
            e.append(row(featureRow(c), "general.features", SettingsText("feature.\(c.rawValue)", "Home"),
                         detail: SettingsText("feature.\(c.rawValue).what", "Home"), generated: true))
        }
        e += [
            row("general.login", "general.app", "settings.general.login", detail: S("settings.general.login.detail")),
            row("general.menu_bar_icon", "general.app", "settings.general.menu_bar_icon", detail: S("settings.general.menu_bar_icon.detail")),
            row("general.island_idle", "general.app", "settings.general.island_idle", detail: S("settings.general.island_idle.detail")),
            // dictation's and the voice note's alike (record.live_text): the app's, not one capability's
            row("general.live_text", "general.app", "settings.general.live_text", detail: S("settings.general.live_text.detail"),
                more: S("settings.general.live_text.hint")),
            row("general.language", "general.app", "settings.general.language"),
            whole("general.about"),

            // Cards (the strings keep their settings.general.* keys from when these rows were in General)
            row("cards.collect", "cards.snaps", "settings.general.collect", more: S("settings.general.collect.hint")),
            row("cards.snap_sound", "cards.snaps", "settings.general.snap_sound"),
            row("cards.voice_end_on_pause", "cards.voice", "settings.general.voice_end_on_pause",
                more: S("settings.general.voice_end_on_pause.hint")),
            row("cards.card_drag", "cards.drag", "settings.general.card_drag", more: S("settings.general.card_drag.hint")),
            row("cards.agent_drag", "cards.drag", "settings.general.agent_drag", more: S("settings.general.agent_drag.hint")),
            row("cards.drag_note_file", "cards.drag", "settings.general.drag_note_file", more: S("settings.general.drag_note_file.hint")),
            // how long History (cards used in other apps) keeps them: record.cards.history_days (BlurtCore TakenCaptures)
            row("cards.history", "cards.drag", "settings.cards.history", detail: S("settings.cards.history.detail")),

            // Recording & Items
            row("recording.countdown", "recording.capture", SettingsText("app.menu.countdown", "Main")),
            row("recording.system_audio", "recording.capture", "settings.general.system_audio"),
            row("recording.hide_notch", "recording.capture", "settings.general.hide_notch", detail: S("settings.general.hide_notch.detail")),
            row("recording.after_recording", "recording.items", "settings.general.after_recording"),

            // Projects
            row("projects.capture_into", "projects.capture", "settings.projects.capture_row"),
            whole("projects.list", detail: S("settings.general.projects.hint")),

            // Dictation
            row("dictation.enable", "dictation.main", D("dictation.settings.enable"), detail: D("dictation.settings.enable.detail")),
            // the key's menu: keeping Fn from macOS (Fn only)
            row("dictation.key", "dictation.main", D("dictation.settings.key")),
            row("dictation.fn_capture", "dictation.main", D("dictation.fn.capture"), detail: D("dictation.fn.capture.detail"), fold: "dictation.key"),
            row("dictation.mode", "dictation.main", D("dictation.settings.mode")),
            row("dictation.cancel_key", "dictation.main", D("dictation.settings.cancel_key"), detail: D("dictation.settings.cancel_key.detail")),
            row("dictation.double_tap", "dictation.main", D("dictation.settings.double_tap"), detail: D("dictation.settings.double_tap.detail")),
            row("dictation.modifier_tap", "dictation.main", D("dictation.settings.modifier_tap"), detail: D("dictation.settings.modifier_tap.detail")),
            row("dictation.mic", "dictation.main", D("dictation.mic.section"), detail: D("dictation.mic.detail"), more: D("dictation.mic.builtin.detail")),
            row("dictation.only_my_voice", "dictation.main", D("dictation.only_my_voice"), detail: D("dictation.only_my_voice.detail")),
            row("dictation.sounds", "dictation.main", D("dictation.sounds")),
            row("dictation.stop_sound", "dictation.main", D("dictation.stop_sound")),
            row("dictation.default_style", "dictation.text", D("dictation.style.default")),
            row("dictation.by_app", "dictation.text", D("dictation.style.by_app"), detail: D("dictation.style.by_app.detail")),
        ]
        for c in ["chat", "code", "mail", "notes", "other"] {
            e.append(row("dictation.cat.\(c)", "dictation.text", D("dictation.style.cat.\(c)"), detail: D("dictation.style.cat.\(c).detail"),
                         fold: "dictation.by_app", generated: true))
        }
        e += [
            row("dictation.suggest_lists", "dictation.text", D("dictation.style.suggest"), fold: "dictation.by_app"),
            row("dictation.learn_styles", "dictation.text", D("dictation.style.learn_toggle"), detail: D("dictation.style.learn_toggle.detail"),
                fold: "dictation.by_app"),
            row("dictation.polish_timeout", "dictation.text", D("dictation.polish.timeout"), detail: D("dictation.polish.timeout.detail"),
                fold: "dictation.by_app"),
            // translate mode (docs/design/dictation-translate.md): into what — its own, not ⌥T's (2026-10-30) — and the
            // model that translates (Settings → Models' Translate row, said here)
            row("dictation.translate", "dictation.translation", D("dictation.translate.settings.title"), detail: D("dictation.translate.settings.detail")),
            row("dictation.translate_model", "dictation.translation", SettingsText("models.uses.translate", "Models")),
            // the words' menu: reading the context, learning
            row("dictation.word_list", "dictation.text", D("dictation.vocab.summary.title"), detail: D("dictation.vocab.summary.detail")),
            row("dictation.context", "dictation.text", D("dictation.vocab.context"), detail: D("dictation.vocab.context.detail"),
                fold: "dictation.word_list"),
            row("dictation.learn", "dictation.text", D("dictation.vocab.learn"), detail: D("dictation.vocab.learn.detail"), fold: "dictation.word_list"),
            // the history's menu: how long it is kept, clearing it; keeping the audio is a row of its own (what is kept
            // is said where it is seen)
            row("dictation.history_saved", "dictation.data", D("dictation.history.saved"), detail: D("dictation.history.saved.detail")),
            row("dictation.history_keep", "dictation.data", D("dictation.history.keep")),
            row("dictation.keep_audio", "dictation.data", D("dictation.history.keep_audio"), detail: D("dictation.history.keep_audio.detail")),
            // chosen and listed in Settings → Speech
            row("dictation.models", "dictation.data", D("dictation.models.section"), detail: D("dictation.models.detail")),
            row("dictation.lab", "dictation.advanced", "settings.general.dictation_lab", detail: S("settings.general.dictation_lab.hint")),

            // Copy Text from Screen: ⌥C's second reading; ⌥T's target (its own, not dictation's) and the model that translates
            row("screentext.refine", "screentext.copy", "settings.general.screen_text", more: S("settings.general.screen_text.hint")),
            row("screentext.translate", "screentext.translation", "settings.screen_text.translate",
                more: S("settings.screen_text.translate.hint")),
            row("screentext.translate_model", "screentext.translation", SettingsText("models.uses.translate", "Models")),
            row("screentext.history_keep", "screentext.history_section", "settings.screen_text.history.keep"),
            row("screentext.history", "screentext.history_section", "settings.screen_text.history",
                detail: S("settings.screen_text.history.detail")),

            // 远程控制: the devices' row first (its title and line are live on the page), then the two sections
            row("remote.devices", nil, "settings.remote.devices.title", detail: S("settings.remote.devices.detail")),
            row("remote.stay_awake", "remote.options", "settings.remote.stay_awake", detail: S("settings.remote.stay_awake.desktop"),
                more: S("settings.remote.stay_awake.desktop.more")),
            row("remote.say_asleep", "remote.options", "settings.remote.say_asleep", detail: S("settings.remote.say_asleep.detail")),
            row("remote.hud", "remote.options", "settings.remote.hud", detail: S("settings.remote.hud.detail")),
            row("remote.screen", "remote.options", "settings.remote.screen", detail: S("settings.remote.screen.detail")),
            row("remote.go_between", "remote.relay", "settings.remote.go_between", detail: S("settings.remote.go_between.detail")),
            // its footnote's Copy Instructions is found by this row's keywords (cloudflare, set up a relay…)
            row("remote.relay.address", "remote.relay", "settings.remote.relay.own", detail: S("settings.remote.relay.address.detail")),

            // Speech
        ]
        for p in speechPurposes {
            e.append(row("speech.\(p)", "speech.jobs", P("speech.purpose.\(p)"), detail: P("speech.purpose.\(p).detail"), generated: true))
        }
        // dictation's two models are two more jobs; "speech.dictation" stays the id links use (speech/dictation)
        e += [
            row("speech.recognition", "speech.jobs", P("speech.purpose.recognition"), detail: P("speech.purpose.recognition.detail")),
            row("speech.dictation", "speech.jobs", P("speech.purpose.dictation"), detail: P("speech.purpose.dictation.detail")),
            row("speech.polish", "speech.jobs", P("speech.purpose.polish"), detail: P("speech.purpose.polish.detail")),
            row("speech.translate", "speech.jobs", SettingsText("models.job.translate", "Models"), detail: SettingsText("models.job.translate.detail", "Models")),
            row("speech.vision", "speech.jobs", SettingsText("models.job.vision", "Models"), detail: SettingsText("models.job.vision.detail", "Models")),
            // the cloud services (the services themselves come from the user's setup; the section is what search finds)
            whole("speech.services", detail: SettingsText("models.services.detail", "Models")),
            whole("speech.languages", detail: P("speech.languages.footer")),
            row("speech.language", "speech.languages", P("speech.advanced.language"), detail: P("speech.advanced.language.detail")),
            row("speech.threads", "speech.advanced", P("speech.limits.threads"), detail: P("speech.limits.threads.detail"),
                more: P("speech.limits.footer")),
            row("speech.concurrent", "speech.advanced", P("speech.limits.concurrent"), detail: P("speech.limits.concurrent.detail")),
            row("speech.memory", "speech.advanced", P("speech.limits.memory"), detail: P("speech.limits.memory.detail")),
            row("speech.battery", "speech.advanced", P("speech.limits.battery"), detail: P("speech.limits.battery.detail")),
            row("speech.mirror", "speech.advanced", P("speech.advanced.mirror"), detail: P("speech.advanced.mirror.detail")),
            // cloud recognition's model and audio speed (its keys are Cloud services' lines: CloudSpeechLines)
            row("speech.cloud", "speech.advanced", P("speech.cloud.title"), detail: P("speech.note.cloud")),
            whole("speech.models", detail: P("speech.models.footer")),
            whole("speech.compare", detail: P("speech.compare.note")),
        ]

        // Shortcuts: one row per action (HotkeyCenter.Action), section by section in the page's order, the dictation
        // key heading its section (the pen's hold key is the pen row's second line: its keywords find it), then the
        // page's Restore Defaults
        func shortcut(_ a: String, _ section: String) -> SettingsEntry {
            row("shortcuts.\(a)", section, SettingsText("capture.action.\(a)", "Capture"),
                detail: describedShortcuts.contains(a) ? SettingsText("capture.action.\(a).detail", "Capture") : nil, generated: true)
        }
        for (section, actions) in shortcutSections {
            if section == "shortcuts.dictation" {
                e.append(row("shortcuts.dictation_key", section, SettingsText("capture.keys.dictation_key", "Capture")))
            }
            e += actions.map { shortcut($0, section) }
        }
        e += [
            row("shortcuts.restore", nil, SettingsText("capture.keys.restore", "Capture")),

            // Agents
            whole("agents.use", detail: SettingsText("agents.use.footer", "Agents")),
            whole("agents.list", detail: SettingsText("agents.lead", "Agents")),
            whole("agents.drop", detail: SettingsText("agents.drop.header", "Agents")),
            whole("agents.organize", detail: SettingsText("agents.organize.footer", "Agents")),
            whole("agents.ask", detail: SettingsText("agents.ask.footer", "Agents")),

            // Privacy
            whole("privacy.permissions", detail: S("settings.privacy.macos_applies_screen_recording")),
            row("privacy.local_asr", "privacy.data", "settings.privacy.local_speech_recognition_only",
                detail: S("settings.privacy.audio_never_goes_cloud")),
            row("privacy.keep_live", "privacy.data", "settings.privacy.keep_raw_live_caption", detail: S("settings.privacy.deleted_by_default_once")),
            row("privacy.spotlight", "privacy.data", "settings.privacy.items_appear_spotlight", detail: S("settings.privacy.spotlight.detail")),

            // Storage
            // (the storage rows themselves — folders, videos, models, files — come from the disk; the sections and
            // their keywords are what search lands on)
            whole("storage.recordings"),
            row("storage.auto_delete", "storage.recordings", "settings.storage.videos.auto", detail: S("settings.storage.videos.footer")),
            whole("storage.models", detail: S("settings.storage.model.footer")),
            whole("storage.files"),
        ]
        return e
    }()

    /// Rows that are a button rather than a setting: found by their own words only, never listed with their pane.
    public static let actions: Set<String> = ["shortcuts.restore"]

    public static func entry(_ id: String) -> SettingsEntry? { byID[id] }
    private static let byID: [String: SettingsEntry] = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    // MARK: text

    /// Arguments for a string with placeholders (the app fills in the dictation key, the core count …), by string key.
    /// Without them a placeholder reads "…".
    public static var arguments: ((String) -> [CVarArg]?)?

    /// A text in the UI language, or in `language`; nil when that language doesn't have the key (keywords are optional).
    public static func text(_ t: SettingsText, language: String? = nil) -> String? {
        guard let raw = language.map({ Loc.string(t.key, table: t.table, language: $0) }) ?? (Loc.has(t.key, table: t.table) ? Loc.string(t.key, table: t.table) : nil)
        else { return nil }
        if language == nil, let a = arguments?(t.key) { return Loc.format(raw, a) }
        return fillGaps(raw)
    }

    /// "Double-tap %@ to send" → "Double-tap … to send"; "%%" → "%".
    static func fillGaps(_ s: String) -> String {
        guard s.contains("%") else { return s }
        var out = "", i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "%" else { out.append(c); i = s.index(after: i); continue }
            var j = s.index(after: i)
            if j < s.endIndex, s[j] == "%" { out.append("%"); i = s.index(after: j); continue }
            while j < s.endIndex, s[j].isNumber || s[j] == "$" || s[j] == "l" { j = s.index(after: j) }
            if j < s.endIndex { j = s.index(after: j) }      // the conversion: @ d u f s
            out.append("…")
            i = j
        }
        return out
    }

    public static func title(_ e: SettingsEntry) -> String { text(e.title) ?? e.id }
    public static func detail(_ e: SettingsEntry) -> String? { e.detail.flatMap { text($0) } }

    // MARK: search

    /// Every setting found, in the order the results page lists them (its groups one after the other).
    public static func search(_ query: String, off: Set<Capability> = Capability.off) -> [SettingsHit] {
        results(query, off: off).flatMap(\.hits)
    }

    /// The results by pane, best group first; ties keep the sidebar's order. A query that is a pane's name or its start
    /// ("快捷", "short") finds that pane as a whole; one that only matches a pane's keywords ("hotkey") does so when
    /// nothing matches the rows themselves — "voice" finds the voice settings, not the whole of Dictation.
    /// `off`: the capabilities turned off — their panes and rows are not found (`rowShown`); their switches in General are.
    public static func results(_ query: String, off: Set<Capability> = Capability.off) -> [SettingsResultGroup] {
        let terms = words(query)
        guard !terms.isEmpty else { return [] }
        let here = Loc.language, other = otherLanguage
        let entries = off.isEmpty ? Self.entries : Self.entries.filter { rowShown($0.id, off: off) }
        let panes = off.isEmpty ? Self.panes : Self.panes.filter { paneShown($0.id, off: off) }
        let all = entries.map { fields($0, here: here, other: other) }
        func pass(_ paneLevel: Bool) -> [SettingsHit] {
            var hits: [(SettingsHit, Int)] = []
            for (n, e) in entries.enumerated() {
                let f = paneLevel ? all[n] : all[n].filter { !$0.pane }
                var total = 0
                var ok = true
                for t in terms {
                    let s = score(t, f)
                    if s == 0 { ok = false; break }
                    total += s
                }
                if ok { hits.append((SettingsHit(entry: e, score: total), n)) }
            }
            return hits.sorted { $0.0.score != $1.0.score ? $0.0.score > $1.0.score : $0.1 < $1.1 }.map(\.0)
        }
        // the query is (the start of) a pane's name ("快捷", "short", "Shortcuts"): the pane is found as a whole and
        // leads, so the results don't jump around while the name is typed — two letters at least, or one Chinese character
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        let longEnough = q.count >= (q.unicodeScalars.allSatisfy(\.isASCII) ? 2 : 1)
        var whole = !longEnough ? Set<String>() : Set(panes.filter { p in
            [here, other].contains { lang in text(p.title, language: lang).map(fold)?.hasPrefix(q) == true }
        }.map(\.id))
        var own = pass(false)
        if own.isEmpty && whole.isEmpty {
            // nothing matches by its own words: a pane whose name or keywords hold every word ("hotkey") is found as a
            // whole; otherwise rows matched with their pane's help ("shortcut snap") are listed one by one
            for p in panes where terms.allSatisfy({ score($0, paneFields(p, here: here, other: other)) > 0 }) { whole.insert(p.id) }
            if whole.isEmpty { own = pass(true) }
        }
        var groups: [SettingsResultGroup] = []
        let lead = 100_000
        for p in panes where whole.contains(p.id) {
            let found = Set(own.map(\.entry.id))
            let rows = entries.filter { $0.pane == p.id && (!actions.contains($0.id) || found.contains($0.id)) }
                .map { SettingsHit(entry: $0, score: lead) }
            groups.append(SettingsResultGroup(pane: p.id, paneHit: true, hits: bySection(rows), score: lead))
        }
        for p in panes where !whole.contains(p.id) {
            let rows = own.filter { $0.entry.pane == p.id }
            guard let best = rows.first?.score else { continue }
            groups.append(SettingsResultGroup(pane: p.id, paneHit: false, hits: bySection(rows), score: best))
        }
        let order = Dictionary(uniqueKeysWithValues: panes.enumerated().map { ($1.id, $0) })
        return groups.sorted { $0.score != $1.score ? $0.score > $1.score : order[$0.pane, default: 0] < order[$1.pane, default: 0] }
    }

    /// Hits (best first) by section: the sections in the order of their best hit, a section's own entry leading it,
    /// rows without a section (actions) last.
    private static func bySection(_ hits: [SettingsHit]) -> [SettingsHit] {
        var keys: [String] = []
        var runs: [String: [SettingsHit]] = [:]
        for h in hits {
            let k = h.entry.section ?? ""
            if runs[k] == nil { keys.append(k) }
            runs[k, default: []].append(h)
        }
        let ordered = keys.filter { !$0.isEmpty } + keys.filter(\.isEmpty)
        return ordered.flatMap { k -> [SettingsHit] in
            let r = runs[k] ?? []
            return r.filter { $0.entry.kind == .section } + r.filter { $0.entry.kind != .section }
        }
    }

    /// The query's words, folded.
    public static func words(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map { fold(String($0)) }.filter { !$0.isEmpty }
    }

    /// The language search looks in besides the UI's.
    public static var otherLanguage: String { Loc.languages.first { $0 != Loc.language } ?? "en" }

    /// Why an entry was found, when its title doesn't say so: the stretch of its description, its keyword or its longer
    /// explanation that holds the query's other words — always in the UI's language. Found only through the other
    /// language (an English word typed in the Chinese UI): its own description, in the UI's language, untouched (or
    /// nothing) — never a line of English inside Chinese. nil when the title holds every word, or when the entry was
    /// found by its section or its pane (the results show those as headings).
    public static func reason(_ e: SettingsEntry, query: String) -> String? {
        let missing = words(query).filter { !fold(title(e)).contains($0) }
        guard !missing.isEmpty else { return nil }
        let texts = [detail(e)].compactMap { $0 } + keywordList(e.keywords, nil) + [e.more.flatMap { text($0) }].compactMap { $0 }
        return excerpt(texts, missing) ?? detail(e)
    }

    /// Why a pane was found as a whole, when its name doesn't say so: the keyword that holds the query ("hotkey"), in the
    /// UI's language; nothing when it was its name in the other language.
    public static func reason(pane id: String, query: String) -> String? {
        guard let p = pane(id) else { return nil }
        let missing = words(query).filter { !fold(text(p.title) ?? "").contains($0) }
        guard !missing.isEmpty else { return nil }
        return excerpt(keywordList(p.keywords, nil), missing)
    }

    private static func keywordList(_ t: SettingsText, _ lang: String?) -> [String] {
        guard let s = lang == nil ? text(t) : text(t, language: lang) else { return [] }
        return s.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" }).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The sentence holding the most of `terms`, from the first text that has them: whole from its start (the row ends
    /// it with "…" when it is too long — cut at one end only), without its parentheses (a list of key glyphs reads as
    /// noise in a result).
    static func excerpt(_ texts: [String], _ terms: [String]) -> String? {
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        func hits(_ t: String) -> Int { terms.filter { t.range(of: $0, options: opts) != nil }.count }
        var best: (text: String, n: Int)?
        for t in texts {
            let n = hits(t)
            if n > (best?.n ?? 0) { best = (t, n) }
            if n == terms.count { break }
        }
        guard let t = best?.text else { return nil }
        // its sentences (a full stop, then a space or the end; Chinese stops end one by themselves)
        var sentences: [String] = []
        var cur = ""
        for (i, c) in zip(t.indices, t) {
            cur.append(c)
            let next = t.index(after: i)
            if "。！？".contains(c) || (".!?".contains(c) && (next == t.endIndex || t[next].isWhitespace)) {
                sentences.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(cur.trimmingCharacters(in: .whitespaces)) }
        let most = sentences.map(hits).max() ?? 0
        let pick = sentences.first { hits($0) == most } ?? t
        let bare = pick.replacingOccurrences(of: #"\s*[（(][^）)]*[）)]"#, with: "", options: .regularExpression)
        return bare.isEmpty ? pick : bare
    }

    typealias Field = (text: String, title: Bool, pane: Bool, weight: Int)

    /// The texts one entry is found by, folded, with what a match in each is worth; `pane`: the pane's name or keywords.
    /// An action is found by its name and keywords only ("restore", "reset"), never by a word of its description
    /// ("shortcut" in Restore defaults' one).
    private static func fields(_ e: SettingsEntry, here: String, other: String) -> [Field] {
        var out: [Field] = []
        let action = actions.contains(e.id)
        func add(_ t: SettingsText?, _ lang: String?, title: Bool = false, pane: Bool = false, _ w: Int) {
            guard let t = t, !(action && (t == e.detail || t == e.more)),
                  let s = lang == nil ? text(t) : text(t, language: lang) else { return }
            out.append((fold(s), title, pane, w))
        }
        add(e.title, nil, title: true, 100)
        add(e.keywords, here, 45)
        add(e.title, other, 40)
        add(e.keywords, other, 35)
        add(e.section.flatMap(section)?.title, here, 30)
        add(pane(e.pane)?.title, here, pane: true, 20)
        add(pane(e.pane)?.keywords, here, pane: true, 20)
        add(e.detail, nil, 20)
        add(e.more, here, 15)
        add(e.section.flatMap(section)?.title, other, 12)
        add(pane(e.pane)?.title, other, pane: true, 10)
        add(pane(e.pane)?.keywords, other, pane: true, 10)
        add(e.detail, other, 8)
        return out
    }

    /// A pane's own texts: its name and keywords, in both languages.
    private static func paneFields(_ p: SettingsPaneInfo, here: String, other: String) -> [Field] {
        [text(p.title, language: here), text(p.keywords, language: here), text(p.title, language: other), text(p.keywords, language: other)]
            .compactMap { $0 }.map { (text: fold($0), title: false, pane: true, weight: 10) }
    }

    /// A field's best match for one word: the title scores by where the word sits (its start, a word's start, anywhere);
    /// elsewhere a Latin word has to start a word ("voice" isn't found in "SenseVoice"); Chinese matches anywhere.
    private static func score(_ term: String, _ fields: [Field]) -> Int {
        var best = 0
        let latin = term.unicodeScalars.allSatisfy(\.isASCII)
        for f in fields {
            var from = f.text.startIndex
            while let r = f.text.range(of: term, range: from..<f.text.endIndex) {
                let atStart = r.lowerBound == f.text.startIndex
                let atWord = atStart || !f.text[f.text.index(before: r.lowerBound)].isLetter
                var s = 0
                if f.title { s = atStart ? 100 : atWord ? 80 : 60 }
                else if atWord || !latin { s = f.weight }
                best = max(best, s)
                if s > 0 && (atWord || !f.title) { break }      // a title may still have the word at a word's start
                from = r.upperBound
            }
        }
        return best
    }

    /// Case, accents and full / half width don't matter.
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en"))
    }

    // MARK: building

    private static func pane(_ id: String, _ key: String, _ table: String, _ symbol: String, _ group: String) -> SettingsPaneInfo {
        SettingsPaneInfo(id: id, title: SettingsText(key, table), symbol: symbol, group: group)
    }
    private static func sec(_ id: String, _ key: String, _ table: String = "Settings") -> SettingsSection {
        SettingsSection(id: id, title: SettingsText(key, table))
    }
    private static func S(_ k: String) -> SettingsText { SettingsText(k, "Settings") }
    private static func D(_ k: String) -> SettingsText { SettingsText(k, "Dictation") }
    private static func P(_ k: String) -> SettingsText { SettingsText(k, "Speech") }

    private static func row(_ id: String, _ section: String?, _ title: String, detail: SettingsText? = nil, more: SettingsText? = nil,
                            fold: String? = nil, generated: Bool = false) -> SettingsEntry {
        row(id, section, S(title), detail: detail, more: more, fold: fold, generated: generated)
    }
    private static func row(_ id: String, _ section: String?, _ title: SettingsText, detail: SettingsText? = nil, more: SettingsText? = nil,
                            fold: String? = nil, generated: Bool = false) -> SettingsEntry {
        SettingsEntry(id: id, kind: .row, section: section, title: title, detail: detail, more: more, fold: fold, generated: generated)
    }
    /// A whole section as one entry: its title is the section's.
    private static func whole(_ id: String, detail: SettingsText? = nil) -> SettingsEntry {
        let s = sections.first { $0.id == id }
        return SettingsEntry(id: id, kind: .section, section: id, title: s?.title ?? SettingsText(id, "Settings"), detail: detail,
                             more: nil, fold: nil, generated: false)
    }
}
