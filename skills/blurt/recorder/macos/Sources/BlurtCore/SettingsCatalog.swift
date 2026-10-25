// Every setting the Settings window shows, as data: its panes (in the sidebar's groups), each pane's sections, and one
// entry per row — its id, its title and one-line description (string keys), a longer explanation where there is one,
// and search keywords (settings.kw.<id>, both languages). The panes render their rows from these entries
// (BlurtApp Settings/SettingsKit.swift: SettingRow("general.login") takes its title and description from here), and
// the window's search runs over the same entries, so the index can't drift from what is on screen;
// SettingsCatalogTests checks every key exists in both languages and that each id is rendered exactly once.
//
// Ids are "<pane>.<name>". A `.section` entry is a whole section (a list like the projects or the models) that search
// can land on; `generated` rows come out of a ForEach over an enum (the shortcuts, the dictation app categories, the
// speech purposes); `fold` names the row whose disclosure hides the entry until a search jumps there.
// Search: every word of the query has to appear in the entry's title, description, keywords or section — in the UI
// language or in the other one — scored title first; a query that only names a pane lists that pane's rows. Plain
// substring matching, no language rules.
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
    /// The row whose disclosure folds this one away.
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

public enum SettingsCatalog {
    // MARK: panes

    /// The sidebar's groups, in order: (id, title).
    public static let groups: [(id: String, title: SettingsText)] = [
        ("preferences", SettingsText("settings.group.preferences", "Settings")),
        ("work", SettingsText("settings.group.work", "Settings")),
        ("mac", SettingsText("settings.group.mac", "Settings")),
    ]

    public static let panes: [SettingsPaneInfo] = [
        pane("general", "settings.kit.general", "Settings", "gearshape", "preferences"),
        pane("dictation", "dictation.settings.tab", "Dictation", "character.cursor.ibeam", "preferences"),
        pane("speech", "settings.kit.speech", "Settings", "waveform", "preferences"),
        pane("shortcuts", "settings.kit.shortcuts", "Settings", "keyboard", "preferences"),
        pane("agents", "settings.kit.agents", "Settings", "wand.and.stars", "work"),
        pane("privacy", "settings.kit.privacy", "Settings", "hand.raised", "mac"),
        pane("storage", "settings.kit.storage", "Settings", "internaldrive", "mac"),
    ]

    public static func pane(_ id: String) -> SettingsPaneInfo? { panes.first { $0.id == id } }

    /// Panes that are gone, and where their links (blurt://settings/<pane>[/<row>], a remembered last pane) land now.
    /// Export went in v0.9: the user's agent sends items with its own tools, so Agents says how to ask it.
    public static let moved: [String: String] = ["export": "agents/agents.ask"]

    /// "export" or "export/target" → "agents/agents.ask"; anything else as it is.
    public static func redirect(_ link: String) -> String {
        let pane = String(link.prefix { $0 != "/" })
        return moved[pane] ?? link
    }

    // MARK: sections

    public static let sections: [SettingsSection] = [
        sec("general.projects", "main.sidebar.projects", "Main"),
        sec("general.app", "settings.general.app"),
        sec("general.recording", "settings.general.recording"),
        sec("general.voice", "settings.general.section.voice"),
        sec("general.cards", "settings.general.section.cards"),
        sec("general.developer", "settings.general.section.developer"),
        sec("general.about", "settings.general.about"),

        sec("dictation.main", "dictation.settings.section", "Dictation"),
        sec("dictation.style", "dictation.style.section", "Dictation"),
        sec("dictation.models", "dictation.models.section", "Dictation"),
        sec("dictation.words", "dictation.vocab.section", "Dictation"),
        sec("dictation.history", "dictation.history.section", "Dictation"),
        sec("dictation.mic", "dictation.mic.section", "Dictation"),
        sec("dictation.permissions", "dictation.perm.section", "Dictation"),

        sec("speech.machine", "speech.section.machine", "Speech"),
        sec("speech.dictation", "speech.section.dictation", "Speech"),
        sec("speech.languages", "speech.section.languages", "Speech"),
        sec("speech.models", "speech.section.models", "Speech"),
        sec("speech.resources", "speech.section.resources", "Speech"),
        sec("speech.cloud", "speech.section.cloud", "Speech"),
        sec("speech.advanced", "speech.section.advanced", "Speech"),

        sec("shortcuts.anytime", "capture.keys.anytime", "Capture"),
        sec("shortcuts.recording", "capture.keys.while_recording", "Capture"),

        sec("agents.list", "agents.header", "Terminal"),
        sec("agents.sessions", "agents.sessions.header", "Terminal"),
        sec("agents.manual", "agents.manual.header", "Terminal"),
        sec("agents.ask", "agents.ask.header", "Terminal"),

        sec("privacy.permissions", "settings.privacy.permissions_live"),
        sec("privacy.data", "settings.privacy.data"),

        sec("storage.recordings", "settings.privacy.recordings_screenshots"),
        sec("storage.models", "settings.storage.models"),
        sec("storage.dictation", "dictation.settings.tab", "Dictation"),
        sec("storage.files", "settings.privacy.blurt_own_files"),
    ]

    public static func section(_ id: String) -> SettingsSection? { sections.first { $0.id == id } }

    // MARK: entries

    /// The shortcut actions under "While recording"; the rest are "Anytime".
    public static let recordingShortcuts: Set<String> = ["pause", "marker", "pen", "stop"]
    /// The three jobs of speech recognition (BlurtApp ASRPurpose), in the pane's order.
    public static let speechPurposes = ["batch", "live", "note"]

    public static let entries: [SettingsEntry] = {
        var e: [SettingsEntry] = [
            // General
            row("general.capture_into", "general.projects", "settings.general.capture_into"),
            whole("general.projects", detail: S("settings.general.projects.hint")),
            row("general.login", "general.app", "settings.general.login", detail: S("settings.general.login.detail")),
            row("general.language", "general.app", "settings.general.language"),
            row("general.after_recording", "general.recording", "settings.general.after_recording"),
            row("general.countdown", "general.recording", SettingsText("app.menu.countdown", "Main")),
            row("general.system_audio", "general.recording", "settings.general.system_audio"),
            row("general.collect", "general.recording", "settings.general.collect", detail: S("settings.general.collect.hint")),
            row("general.voice_end_on_pause", "general.voice", "settings.general.voice_end_on_pause",
                detail: S("settings.general.voice_end_on_pause.detail"), more: S("settings.general.voice_end_on_pause.hint")),
            row("general.live_text", "general.voice", "settings.general.live_text",
                detail: S("settings.general.live_text.detail"), more: S("settings.general.live_text.hint")),
            row("general.smart_paste", "general.cards", "settings.general.smart_paste",
                detail: S("settings.general.smart_paste.detail"), more: S("settings.general.smart_paste.hint")),
            row("general.drag_copy_note", "general.cards", "settings.general.drag_copy_note",
                detail: S("settings.general.drag_copy_note.detail"), more: S("settings.general.drag_copy_note.hint")),
            row("general.drag_note_file", "general.cards", "settings.general.drag_note_file",
                detail: S("settings.general.drag_note_file.detail"), more: S("settings.general.drag_note_file.hint")),
            row("general.drag_caption", "general.cards", "settings.general.drag_caption", detail: S("settings.general.drag_caption.hint")),
            row("general.dictation_lab", "general.developer", "settings.general.dictation_lab", detail: S("settings.general.dictation_lab.hint")),
            row("general.version", "general.about", "settings.general.version"),
            row("general.help", "general.about", "settings.general.help", detail: S("settings.general.help.detail")),
            row("general.assistant", "general.about", "settings.general.assistant.title", detail: S("settings.general.assistant.detail")),

            // Dictation
            row("dictation.enable", "dictation.main", D("dictation.settings.enable"), detail: D("dictation.settings.enable.detail")),
            row("dictation.key", "dictation.main", D("dictation.settings.key")),
            row("dictation.mode", "dictation.main", D("dictation.settings.mode")),
            row("dictation.double_tap", "dictation.main", D("dictation.settings.double_tap"), detail: D("dictation.settings.double_tap.detail")),
            row("dictation.fn_capture", "dictation.main", D("dictation.fn.capture"), detail: D("dictation.fn.capture.detail")),
            row("dictation.default_style", "dictation.style", D("dictation.style.default")),
            row("dictation.by_app", "dictation.style", D("dictation.style.by_app"), detail: D("dictation.style.by_app.detail")),
        ]
        for c in ["chat", "code", "mail", "notes", "other"] {
            e.append(row("dictation.cat.\(c)", "dictation.style", D("dictation.style.cat.\(c)"), detail: D("dictation.style.cat.\(c).detail"),
                         fold: "dictation.by_app", generated: true))
        }
        e += [
            row("dictation.suggest_lists", "dictation.style", D("dictation.style.suggest"), fold: "dictation.by_app"),
            row("dictation.learn_styles", "dictation.style", D("dictation.style.learn_toggle"), detail: D("dictation.style.learn_toggle.detail"),
                fold: "dictation.by_app"),
            row("dictation.polish_timeout", "dictation.style", D("dictation.polish.timeout"), fold: "dictation.by_app"),
            row("dictation.asr_model", "dictation.models", D("dictation.models.asr")),
            row("dictation.polish_model", "dictation.models", D("dictation.models.polish")),
            row("dictation.word_list", "dictation.words", D("dictation.vocab.summary.title")),
            row("dictation.context", "dictation.words", D("dictation.vocab.context"), detail: D("dictation.vocab.context.detail")),
            row("dictation.learn", "dictation.words", D("dictation.vocab.learn"), detail: D("dictation.vocab.learn.detail")),
            row("dictation.history_keep", "dictation.history", D("dictation.history.keep")),
            row("dictation.keep_audio", "dictation.history", D("dictation.history.keep_audio"), detail: D("dictation.history.keep_audio.detail")),
            row("dictation.history_saved", "dictation.history", D("dictation.history.saved"), detail: D("dictation.history.saved.detail")),
            row("dictation.builtin_mic", "dictation.mic", D("dictation.mic.builtin"), detail: D("dictation.mic.builtin.detail")),
            row("dictation.start_sound", "dictation.mic", D("dictation.mic.start_sound")),
            whole("dictation.permissions"),

            // Speech
            row("speech.auto", "speech.machine", P("speech.auto.title"), detail: P("speech.auto.detail")),
        ]
        for p in speechPurposes {
            e.append(row("speech.\(p)", "speech.machine", P("speech.purpose.\(p)"), detail: P("speech.purpose.\(p).detail"), generated: true))
        }
        e += [
            whole("speech.dictation", detail: P("speech.dictation.footer")),
            whole("speech.languages", detail: P("speech.languages.footer")),
            whole("speech.models", detail: P("speech.models.footer")),
            row("speech.threads", "speech.resources", P("speech.limits.threads"), detail: P("speech.limits.threads.detail")),
            row("speech.concurrent", "speech.resources", P("speech.limits.concurrent"), detail: P("speech.limits.concurrent.detail")),
            row("speech.memory", "speech.resources", P("speech.limits.memory"), detail: P("speech.limits.memory.detail")),
            row("speech.battery", "speech.resources", P("speech.limits.battery"), detail: P("speech.limits.battery.detail")),
            whole("speech.cloud", detail: P("speech.cloud.keys")),
            row("speech.language", "speech.advanced", P("speech.advanced.language")),
            row("speech.mirror", "speech.advanced", P("speech.advanced.mirror")),
        ]

        // Shortcuts: one row per action (HotkeyCenter.Action), in the page's order, the dictation key among them, then
        // the pen's hold key
        func shortcut(_ a: String) -> SettingsEntry {
            row("shortcuts.\(a)", recordingShortcuts.contains(a) ? "shortcuts.recording" : "shortcuts.anytime",
                SettingsText("capture.action.\(a)", "Capture"), generated: true)
        }
        e += ["record", "snap", "voice", "project", "cards", "menu", "main"].map(shortcut)
        e += [row("shortcuts.dictation", "shortcuts.anytime", D("dictation.settings.tab"))]
        e += ["reformat", "pause", "marker", "pen", "stop"].map(shortcut)
        e += [
            row("shortcuts.draw_key", "shortcuts.recording", SettingsText("capture.keys.hold_draw", "Capture"),
                detail: SettingsText("capture.keys.draw_note", "Capture")),
            row("shortcuts.restore", nil, SettingsText("capture.keys.restore", "Capture"), detail: S("settings.kit.conflicts_are_checked_three")),

            // Agents
            whole("agents.list", detail: SettingsText("agents.footer", "Terminal")),
            whole("agents.sessions", detail: SettingsText("agents.tmux.ok.detail", "Terminal")),
            whole("agents.ask", detail: SettingsText("agents.ask.footer", "Terminal")),

            // Privacy
            whole("privacy.permissions", detail: S("settings.privacy.macos_applies_screen_recording")),
            row("privacy.local_asr", "privacy.data", "settings.privacy.local_speech_recognition_only",
                detail: S("settings.privacy.audio_never_goes_cloud")),
            row("privacy.keep_live", "privacy.data", "settings.privacy.keep_raw_live_caption", detail: S("settings.privacy.deleted_by_default_once")),
            row("privacy.spotlight", "privacy.data", "settings.privacy.items_appear_spotlight", detail: S("settings.privacy.spotlight.detail")),

            // Storage
            whole("storage.recordings"),
            row("storage.videos", "storage.recordings", "settings.storage.videos", detail: S("settings.storage.videos.footer")),
            row("storage.auto_delete", "storage.recordings", "settings.storage.videos.auto"),
            whole("storage.models", detail: S("settings.storage.model.footer")),
            row("storage.choose_models", "storage.models", "settings.storage.choose_models", detail: S("settings.storage.choose_models.detail")),
            whole("storage.files", detail: S("settings.privacy.index_can_be_deleted")),
            row("storage.live_audio", "storage.files", "settings.privacy.raw_live_caption_audio"),
        ]
        return e
    }()

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

    /// The entries every word of `query` matches, best first (ties keep the catalogue's order). A query that is a pane's
    /// name or its start ("快捷", "short") puts that pane's rows first; one that only matches a pane's keywords ("hotkey") lists
    /// its rows when nothing matches the rows themselves — "voice" finds the voice settings, not every row of Dictation.
    public static func search(_ query: String) -> [SettingsHit] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map { fold(String($0)) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let here = Loc.language, other = Loc.languages.first { $0 != here } ?? "en"
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
        // the query is (the start of) a pane's name ("快捷", "short", "Shortcuts"): that pane's rows lead, so the
        // results don't jump around while the name is typed — two letters at least, or one Chinese character
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        let longEnough = q.count >= (q.unicodeScalars.allSatisfy(\.isASCII) ? 2 : 1)
        let named = !longEnough ? [] : Set(panes.filter { p in
            [here, other].contains { lang in text(p.title, language: lang).map(fold)?.hasPrefix(q) == true }
        }.map(\.id))
        let rows = pass(false)
        guard !named.isEmpty else { return rows.isEmpty ? pass(true) : rows }
        let lead = entries.filter { named.contains($0.pane) }.map { SettingsHit(entry: $0, score: 1000) }
        return lead + rows.filter { !named.contains($0.entry.pane) }
    }

    typealias Field = (text: String, title: Bool, pane: Bool, weight: Int)

    /// The texts one entry is found by, folded, with what a match in each is worth; `pane`: the pane's name or keywords.
    private static func fields(_ e: SettingsEntry, here: String, other: String) -> [Field] {
        var out: [Field] = []
        func add(_ t: SettingsText?, _ lang: String?, title: Bool = false, pane: Bool = false, _ w: Int) {
            guard let t = t, let s = lang == nil ? text(t) : text(t, language: lang) else { return }
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
