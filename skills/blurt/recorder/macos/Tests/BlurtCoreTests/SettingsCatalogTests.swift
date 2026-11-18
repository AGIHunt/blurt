// BlurtCore/SettingsCatalog.swift: the Settings window's rows as data. Every text exists in both languages, every id is
// rendered exactly once by the panes (BlurtApp/Settings/*.swift, App/HotkeySettings.swift: SettingRow / SettingToggle /
// SettingMenuToggle / SettingMenuPicker / SettingsPageButton / SettingsGroup with that id) and nothing is rendered that the catalogue — and so search — doesn't know; search finds
// rows by title, keyword or the other language.
// v1.0.23: the panes are arranged by capability (Capabilities.swift). A capability that is off has no pane, no rows in
// the Shortcuts pane and nothing in search; a link to it lands on its switch in General. The search tests pass `off`
// themselves (the default reads the config of whoever runs the tests).
import XCTest
@testable import BlurtCore

final class SettingsCatalogTests: XCTestCase {
    override func tearDown() { Loc.setting = nil }

    func testEveryTextExistsInBothLanguages() {
        var texts: [(String, SettingsText)] = []
        for p in SettingsCatalog.panes { texts += [(p.id, p.title), (p.id + " keywords", p.keywords)] }
        for g in SettingsCatalog.groups { texts.append((g.id, g.title)) }
        for s in SettingsCatalog.sections { texts.append((s.id, s.title)) }
        for e in SettingsCatalog.entries {
            texts.append((e.id, e.title))
            if let d = e.detail { texts.append((e.id + " detail", d)) }
            if let m = e.more { texts.append((e.id + " more", m)) }
        }
        for lang in Loc.languages {
            for (what, t) in texts {
                XCTAssertNotNil(Loc.string(t.key, table: t.table, language: lang), "\(what): \(t.table).\(t.key) missing in \(lang)")
            }
            // keywords are optional per row, but never in one language only
            for e in SettingsCatalog.entries {
                let k = e.keywords
                XCTAssertEqual(Loc.string(k.key, table: k.table, language: "en") == nil, Loc.string(k.key, table: k.table, language: "zh-Hans") == nil,
                               "\(k.key) in one language only")
            }
        }
    }

    func testIdsAndStructure() {
        let ids = SettingsCatalog.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "an id twice")
        // rows and sections share the page's scroll ids: a row may not take a section's
        let sectionIDs = Set(SettingsCatalog.sections.map(\.id))
        XCTAssertEqual(SettingsCatalog.entries.filter { $0.kind == .row && sectionIDs.contains($0.id) }.map(\.id), [])
        let panes = Set(SettingsCatalog.panes.map(\.id))
        XCTAssertEqual(Set(SettingsCatalog.panes.map(\.group)).subtracting(SettingsCatalog.groups.map(\.id)), [])
        for s in SettingsCatalog.sections { XCTAssertTrue(panes.contains(s.pane), s.id) }
        for e in SettingsCatalog.entries {
            XCTAssertTrue(panes.contains(e.pane), e.id)
            if let s = e.section {
                XCTAssertEqual(SettingsCatalog.section(s)?.pane, e.pane, "\(e.id): section \(s)")
            }
            if e.kind == .section { XCTAssertEqual(e.section, e.id) }
            if let f = e.fold { XCTAssertEqual(SettingsCatalog.entry(f)?.kind, .row, "\(e.id) folds under \(f)") }
        }
        for p in panes { XCTAssertTrue(SettingsCatalog.entries.contains { $0.pane == p }, "\(p) has nothing to find") }
        // the generated rows are the enums' cases, no more and no fewer
        func generated(_ prefix: String) -> Set<String> {
            Set(SettingsCatalog.entries.filter { $0.generated && $0.id.hasPrefix(prefix) }.map { String($0.id.dropFirst(prefix.count)) })
        }
        XCTAssertEqual(generated("shortcuts."), Set(HotkeyCenter.Action.allCases.map(\.rawValue)))
        XCTAssertEqual(generated("dictation.cat."), Set(DictationAppCategory.allCases.map(\.rawValue)))
        XCTAssertEqual(generated("speech."), Set(SettingsCatalog.speechPurposes))
        // General's switches, one per capability (a ForEach over Capability.allCases)
        XCTAssertEqual(generated("general.feature."), Set(Capability.allCases.map(\.rawValue)))
    }

    /// The sidebar: Features (a pane per capability, named and ordered as everywhere else, Projects after the
    /// Recording & Items they belong to) · App · This Mac.
    func testThePanesAreArrangedByCapability() {
        XCTAssertEqual(SettingsCatalog.groups.map(\.id), ["features", "app", "mac"])
        func panes(_ g: String) -> [String] { SettingsCatalog.panes.filter { $0.group == g }.map(\.id) }
        XCTAssertEqual(panes("features"), ["dictation", "cards", "screentext", "recording", "projects", "remote"])
        XCTAssertEqual(panes("app"), ["general", "speech", "shortcuts", "agents"])
        XCTAssertEqual(panes("mac"), ["privacy", "storage"])
        // every pane under Features is a capability's and goes with it; the others are always there
        for p in SettingsCatalog.panes {
            XCTAssertEqual(SettingsCatalog.capability(ofPane: p.id) != nil, p.group == "features", p.id)
        }
        // every capability has its pane, named as the capability is (Home.strings), in the capabilities' order
        let own = ["dictation": "dictation", "cards": "cards", "screen_text": "screentext", "recording": "recording", "phone": "remote"]
        for c in Capability.allCases {
            let pane = SettingsCatalog.pane(own[c.rawValue] ?? "")
            XCTAssertEqual(pane.flatMap { SettingsCatalog.capability(ofPane: $0.id) }, c, c.rawValue)
            XCTAssertEqual(pane?.title, SettingsText("feature.\(c.rawValue)", "Home"), c.rawValue)
        }
        XCTAssertEqual(SettingsCatalog.panes.filter { own.values.contains($0.id) }.map(\.id), Capability.allCases.map { own[$0.rawValue]! })
        // General leads with the five switches, in the capabilities' order, each saying what the capability does
        XCTAssertEqual(SettingsCatalog.sections.filter { $0.pane == "general" }.first?.id, "general.features")
        let switches = SettingsCatalog.entries.filter { $0.section == "general.features" && $0.kind == .row }
        XCTAssertEqual(switches.map(\.id), Capability.allCases.map(SettingsCatalog.featureRow))
        for (e, c) in zip(switches, Capability.allCases) {
            XCTAssertEqual(e.title, SettingsText("feature.\(c.rawValue)", "Home"))
            XCTAssertEqual(e.detail, SettingsText("feature.\(c.rawValue).what", "Home"))
        }
        // nothing of a capability is left in General: its rows are the switches, the app's own, and About
        XCTAssertEqual(Set(SettingsCatalog.entries.filter { $0.pane == "general" }.compactMap(\.section)),
                       ["general.features", "general.app", "general.about"])
        // Cards: in the order a card is made and used
        XCTAssertEqual(SettingsCatalog.sections.filter { $0.pane == "cards" }.map(\.id), ["cards.snaps", "cards.voice", "cards.drag"])
        XCTAssertEqual(SettingsCatalog.sections.filter { $0.pane == "recording" }.map(\.id), ["recording.capture", "recording.items"])
    }

    /// Off means gone: no pane, no shortcut rows, nothing found — except the switch that brings it back.
    func testAnOffCapabilityHasNoPaneNoRowsAndNoResults() {
        XCTAssertTrue(SettingsCatalog.paneShown("cards", off: []))
        XCTAssertFalse(SettingsCatalog.paneShown("cards", off: [.cards]))
        XCTAssertFalse(SettingsCatalog.paneShown("projects", off: [.recording]))      // projects are for items
        XCTAssertFalse(SettingsCatalog.paneShown("recording", off: [.recording]))
        XCTAssertFalse(SettingsCatalog.paneShown("remote", off: [.phone]))
        XCTAssertTrue(SettingsCatalog.paneShown("general", off: Set(Capability.allCases)))
        XCTAssertTrue(SettingsCatalog.paneShown("shortcuts", off: Set(Capability.allCases)))
        // the Shortcuts pane draws a key only while its capability is on; Open Menu and Open Blurt are nobody's
        for a in HotkeyCenter.Action.allCases {
            let id = "shortcuts.\(a.rawValue)"
            XCTAssertTrue(SettingsCatalog.rowShown(id, off: []), id)
            if let c = Capability.owner(of: a) {
                XCTAssertFalse(SettingsCatalog.rowShown(id, off: [c]), id)
                XCTAssertTrue(SettingsCatalog.rowShown(id, off: Set(Capability.allCases).subtracting([c])), id)
            } else {
                XCTAssertTrue(SettingsCatalog.rowShown(id, off: Set(Capability.allCases)), id)
            }
        }
        XCTAssertFalse(SettingsCatalog.rowShown("shortcuts.dictation_key", off: [.dictation]))
        XCTAssertTrue(SettingsCatalog.rowShown("shortcuts.restore", off: Set(Capability.allCases)))
        // where new snaps and voice notes go is Cards', in the Projects pane
        XCTAssertFalse(SettingsCatalog.rowShown("projects.capture_into", off: [.cards]))
        XCTAssertFalse(SettingsCatalog.rowShown("projects.capture_into", off: [.recording]))
        XCTAssertTrue(SettingsCatalog.rowShown("projects.list", off: [.cards]))
        // the words under the notch are dictation's and the voice note's: gone only with both
        XCTAssertTrue(SettingsCatalog.rowShown("general.live_text", off: [.cards]))
        XCTAssertTrue(SettingsCatalog.rowShown("general.live_text", off: [.dictation]))
        XCTAssertFalse(SettingsCatalog.rowShown("general.live_text", off: [.dictation, .cards]))
        // the switches themselves are always there
        for c in Capability.allCases { XCTAssertTrue(SettingsCatalog.rowShown(SettingsCatalog.featureRow(c), off: Set(Capability.allCases))) }

        for lang in ["en", "zh-Hans"] {
            Loc.setting = lang
            for q in ["卡片", "cards", "snap", "截图", "voice note", "drag", "shortcut", "快捷键"] {
                let r = SettingsCatalog.results(q, off: [.cards])
                XCTAssertFalse(r.contains { $0.pane == "cards" }, "\(lang) \(q)")
                let ids = r.flatMap(\.hits).map(\.entry.id)
                XCTAssertFalse(ids.contains { $0.hasPrefix("cards.") }, "\(lang) \(q)")
                XCTAssertTrue(Set(ids).isDisjoint(with: ["shortcuts.snap", "shortcuts.voice", "shortcuts.cards", "projects.capture_into"]), "\(lang) \(q)")
            }
            // what is left to find is the way back
            XCTAssertEqual(SettingsCatalog.search("卡片", off: [.cards]).first?.entry.id, "general.feature.cards", lang)
            XCTAssertEqual(SettingsCatalog.search("cards", off: [.cards]).first?.entry.id, "general.feature.cards", lang)
            XCTAssertEqual(SettingsCatalog.search("recording", off: [.recording]).first?.entry.id, "general.feature.recording", lang)
            XCTAssertFalse(SettingsCatalog.results("project", off: [.recording]).contains { $0.pane == "projects" }, lang)
            XCTAssertFalse(SettingsCatalog.search("shortcut", off: [.recording]).contains { ["shortcuts.record", "shortcuts.pause", "shortcuts.project"].contains($0.entry.id) }, lang)
            XCTAssertTrue(SettingsCatalog.search("shortcut", off: [.recording]).contains { $0.entry.id == "shortcuts.snap" }, lang)
            // with everything off the Features group has no pane left and search still works
            let all = Set(Capability.allCases)
            XCTAssertTrue(SettingsCatalog.results("a", off: all).allSatisfy { SettingsCatalog.pane($0.pane)?.group != "features" }, lang)
        }
    }

    /// The new panes and the switches are found by what people type, in either language.
    func testSearchFindsTheCapabilities() {
        for lang in ["en", "zh-Hans"] {
            Loc.setting = lang
            func first(_ q: String) -> SettingsResultGroup? { SettingsCatalog.results(q, off: []).first }
            func ids(_ q: String) -> [String] { SettingsCatalog.search(q, off: []).map(\.entry.id) }
            // a capability's name: its pane as a whole, its rows in the page's order — and its switch
            for (q, pane, row) in [("卡片", "cards", "cards.collect"), ("cards", "cards", "cards.collect"),
                                   ("录屏", "recording", "recording.countdown"), ("recording", "recording", "recording.countdown")] {
                XCTAssertEqual(first(q)?.pane, pane, "\(lang) \(q)")
                XCTAssertEqual(first(q)?.paneHit, true, "\(lang) \(q)")
                XCTAssertEqual(first(q)?.hits.first?.entry.id, row, "\(lang) \(q)")
                XCTAssertTrue(ids(q).contains("general.feature.\(pane)"), "\(lang) \(q)")
            }
            // "features" / "功能": the section with the five switches
            for q in ["功能", "features"] {
                XCTAssertEqual(ids(q).first, "general.features", "\(lang) \(q)")
                for c in Capability.allCases { XCTAssertTrue(ids(q).contains(SettingsCatalog.featureRow(c)), "\(lang) \(q) \(c.rawValue)") }
            }
            // "turn off" / "关闭": every switch
            for q in ["关闭", "turn off", "disable"] {
                for c in Capability.allCases { XCTAssertTrue(ids(q).contains(SettingsCatalog.featureRow(c)), "\(lang) \(q) \(c.rawValue)") }
            }
            // rows that moved are found where they are now
            XCTAssertEqual(ids("shutter").first, "cards.snap_sound", lang)
            XCTAssertEqual(ids("倒计时").first, "recording.countdown", lang)
            XCTAssertEqual(ids("countdown").first, "recording.countdown", lang)
            XCTAssertTrue(ids("markdown").contains("cards.drag_note_file"), lang)
            XCTAssertTrue(ids("live caption").contains("general.live_text"), lang)
        }
    }

    /// A link to something of an off capability opens General at that capability's switch.
    func testLinksToAnOffCapabilityLandOnItsSwitch() {
        XCTAssertEqual(SettingsCatalog.landing("cards", off: []), "cards")
        XCTAssertEqual(SettingsCatalog.landing("cards/cards.snap_sound", off: []), "cards/cards.snap_sound")
        XCTAssertEqual(SettingsCatalog.landing("cards", off: [.cards]), "general/general.feature.cards")
        XCTAssertEqual(SettingsCatalog.landing("cards/cards.snap_sound", off: [.cards]), "general/general.feature.cards")
        XCTAssertEqual(SettingsCatalog.landing("screentext/translate", off: [.screenText]), "general/general.feature.screen_text")
        XCTAssertEqual(SettingsCatalog.landing("projects", off: [.recording]), "general/general.feature.recording")
        XCTAssertEqual(SettingsCatalog.landing("recording/recording.countdown", off: [.recording]), "general/general.feature.recording")
        XCTAssertEqual(SettingsCatalog.landing("remote", off: [.phone]), "general/general.feature.phone")
        XCTAssertEqual(SettingsCatalog.landing("dictation/dictation.key", off: [.dictation]), "general/general.feature.dictation")
        // a row of an off capability in a pane that stays
        XCTAssertEqual(SettingsCatalog.landing("shortcuts/shortcuts.snap", off: [.cards]), "general/general.feature.cards")
        XCTAssertEqual(SettingsCatalog.landing("shortcuts/snap", off: [.cards]), "general/general.feature.cards")
        XCTAssertEqual(SettingsCatalog.landing("shortcuts/shortcuts.menu", off: Set(Capability.allCases)), "shortcuts/shortcuts.menu")
        XCTAssertEqual(SettingsCatalog.landing("shortcuts", off: [.cards]), "shortcuts")
        XCTAssertEqual(SettingsCatalog.landing("general/general.login", off: Set(Capability.allCases)), "general/general.login")
        XCTAssertEqual(SettingsCatalog.landing("", off: [.cards]), "")
        // an old link to a row that moved, with its new home off (the permission guide's way back to the drag choice)
        XCTAssertEqual(SettingsCatalog.landing(SettingsCatalog.redirect("general/general.card_drag"), off: [.cards]), "general/general.feature.cards")
        // every switch is a row of General
        for c in Capability.allCases { XCTAssertEqual(SettingsCatalog.entry(SettingsCatalog.featureRow(c))?.pane, "general") }
    }

    /// The panes render each id once, and only ids the catalogue has: the search index and the window can't drift.
    func testThePanesRenderTheCatalogue() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BlurtApp")
        var files = try FileManager.default.contentsOfDirectory(at: app.appendingPathComponent("Settings"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        files.append(app.appendingPathComponent("App/HotkeySettings.swift"))
        // a setting in a row's menu (SettingMenuToggle / SettingMenuPicker) is rendered there, once, like a row
        let pattern = try NSRegularExpression(pattern: #"\b(SettingRow|SettingToggle|SettingMenuToggle|SettingMenuPicker|SettingsPageButton|SettingsGroup)\(\s*"([a-z0-9_.]+)""#)
        var rows: [String: Int] = [:], groups: [String: Int] = [:]
        for f in files {
            let code = try String(contentsOf: f, encoding: .utf8).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for m in pattern.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                let kind = String(code[Range(m.range(at: 1), in: code)!]), id = String(code[Range(m.range(at: 2), in: code)!])
                if kind == "SettingsGroup" { groups[id, default: 0] += 1 } else { rows[id, default: 0] += 1 }
            }
        }
        XCTAssertFalse(rows.isEmpty, "no rows found: the scan looks in the wrong place")
        for e in SettingsCatalog.entries where !e.generated {
            switch e.kind {
            case .row: XCTAssertEqual(rows[e.id], 1, "\(e.id) rendered \(rows[e.id] ?? 0) times")
            case .section: XCTAssertEqual(groups[e.id], 1, "section \(e.id) rendered \(groups[e.id] ?? 0) times")
            }
        }
        for id in rows.keys { XCTAssertEqual(SettingsCatalog.entry(id)?.kind, .row, "\(id) is rendered but not in the catalogue") }
        for id in groups.keys { XCTAssertNotNil(SettingsCatalog.section(id), "group \(id) is not a catalogue section") }
    }

    func testSearchFindsByTitleKeywordAndTheOtherLanguage() {
        Loc.setting = "en"
        func top(_ q: String) -> String? { SettingsCatalog.search(q, off: []).first?.entry.id }
        func ids(_ q: String) -> [String] { SettingsCatalog.search(q, off: []).map(\.entry.id) }
        XCTAssertEqual(top("open blurt at login"), "general.login")
        XCTAssertEqual(top("startup"), "general.login")               // a keyword
        XCTAssertEqual(top("mirror"), "speech.mirror")
        XCTAssertEqual(top("开机"), "general.login")                   // Chinese in the English UI
        XCTAssertTrue(ids("hotkey").contains("shortcuts.snap"))       // the pane's keywords: its rows
        XCTAssertTrue(ids("voice").contains("cards.voice_end_on_pause"))
        XCTAssertFalse(ids("voice").contains("dictation.key"))       // …but not when rows match themselves
        XCTAssertFalse(ids("voice").contains("dictation.mode"))      // a pane keyword alone doesn't pull in its rows
        XCTAssertTrue(ids("model").contains("speech.threads"))       // "model" names the Models pane (v1.0.4): its rows come
        XCTAssertTrue(ids("model").contains("storage.models"))
        XCTAssertEqual(ids("shortcuts").first, "shortcuts.record")   // a pane's name: its rows lead, in page order
        XCTAssertEqual(ids("shortcut").first, "shortcuts.record")    // …or the start of it, as it's typed
        XCTAssertEqual(ids("short").first, "shortcuts.record")
        XCTAssertEqual(ids("快捷").first, "shortcuts.record")
        XCTAssertNotEqual(ids("s").first, "shortcuts.record")        // one letter isn't a pane's name yet
        XCTAssertEqual(top("codex"), "agents.list")                   // an agent's name finds the agents list
        XCTAssertEqual(top("claude"), "agents.list")
        XCTAssertEqual(top("Kimi"), "agents.list")
        XCTAssertEqual(top("voice pause"), "cards.voice_end_on_pause")    // every word, anywhere
        XCTAssertTrue(ids("LOGIN").contains("general.login"))         // case doesn't matter
        XCTAssertEqual(ids(""), [])
        XCTAssertEqual(ids("   "), [])
        XCTAssertEqual(ids("zzqqxx"), [])
        // a title match outranks a description match
        let hits = SettingsCatalog.search("spotlight", off: [])
        XCTAssertEqual(hits.first?.entry.id, "privacy.spotlight")

        Loc.setting = "zh-Hans"
        XCTAssertEqual(top("开机"), "general.login")
        XCTAssertEqual(top("镜像"), "speech.mirror")
        XCTAssertEqual(top("login"), "general.login")                 // English in the Chinese UI
        XCTAssertTrue(ids("快捷键").contains("shortcuts.record"))
        XCTAssertEqual(ids("快捷").first, "shortcuts.record")
        XCTAssertEqual(ids("short").first, "shortcuts.record")
        XCTAssertEqual(top("codex"), "agents.list")
        XCTAssertEqual(SettingsCatalog.title(SettingsCatalog.entry("general.login")!), "登录时打开口喷鸡")
    }

    /// Links to rows that moved (v0.9: Projects got its own pane, the Lab went to Dictation, the drag switches became one
    /// choice, About a closing line) land where the row is now; every target exists.
    func testMovedRowsRedirect() {
        XCTAssertEqual(SettingsCatalog.redirect("general/general.capture_into"), "projects/projects.capture_into")
        XCTAssertEqual(SettingsCatalog.redirect("general/capture_into"), "projects/projects.capture_into")
        XCTAssertEqual(SettingsCatalog.redirect("general/general.dictation_lab"), "dictation/dictation.lab")
        XCTAssertEqual(SettingsCatalog.redirect("general/smart_paste"), "cards/cards.card_drag")
        // v1.0.23: the recording, voice-note and card settings left General for their capabilities' panes
        XCTAssertEqual(SettingsCatalog.redirect("general/general.snap_sound"), "cards/cards.snap_sound")
        XCTAssertEqual(SettingsCatalog.redirect("general/general.card_drag"), "cards/cards.card_drag")
        XCTAssertEqual(SettingsCatalog.redirect("general/collect"), "cards/cards.collect")
        XCTAssertEqual(SettingsCatalog.redirect("general/general.agent_drag"), "cards/cards.agent_drag")
        XCTAssertEqual(SettingsCatalog.redirect("general/general.drag_note_file"), "cards/cards.drag_note_file")
        XCTAssertEqual(SettingsCatalog.redirect("general/general.voice_end_on_pause"), "cards/cards.voice_end_on_pause")
        XCTAssertEqual(SettingsCatalog.redirect("general/general.voice"), "cards/cards.voice")
        XCTAssertEqual(SettingsCatalog.redirect("general/general.cards"), "cards/cards.snaps")
        XCTAssertEqual(SettingsCatalog.redirect("general/general.after_recording"), "recording/recording.after_recording")
        XCTAssertEqual(SettingsCatalog.redirect("general/countdown"), "recording/recording.countdown")
        XCTAssertEqual(SettingsCatalog.redirect("general/general.system_audio"), "recording/recording.system_audio")
        XCTAssertEqual(SettingsCatalog.redirect("general/general.hide_notch"), "recording/recording.hide_notch")
        XCTAssertEqual(SettingsCatalog.redirect("general/general.recording"), "recording/recording.capture")
        XCTAssertEqual(SettingsCatalog.redirect("general/general.live_text"), "general/general.live_text")     // dictation's too: it stayed
        XCTAssertEqual(SettingsCatalog.redirect("cards/cards.snap_sound"), "cards/cards.snap_sound")
        XCTAssertEqual(SettingsCatalog.redirect("general/general.login"), "general/general.login")
        XCTAssertEqual(SettingsCatalog.redirect("general"), "general")
        XCTAssertEqual(SettingsCatalog.redirect("export/target"), "agents/agents.ask")
        // Copy Text from Screen left General for its own page (2026-10-30)
        XCTAssertEqual(SettingsCatalog.redirect("general/general.screen_text_refine"), "screentext/screentext.refine")
        XCTAssertEqual(SettingsCatalog.redirect("general/screen_text_translate"), "screentext/screentext.translate")
        for (old, new) in SettingsCatalog.movedRows {
            XCTAssertNil(SettingsCatalog.entry(old), "\(old) moved but is still in the catalogue")
            XCTAssertTrue(SettingsCatalog.entry(new) != nil || SettingsCatalog.section(new) != nil, "\(old) → \(new): no such row")
        }
    }

    func testResultsComeByPaneAndAPaneNameFindsThePane() {
        defer { Loc.setting = nil }
        for lang in ["en", "zh-Hans"] {
            Loc.setting = lang
            let r = SettingsCatalog.results("short", off: [])
            // the pane named leads, as one hit with its settings after it in the page's order — not Restore defaults
            XCTAssertEqual(r.first?.pane, "shortcuts", lang)
            XCTAssertEqual(r.first?.paneHit, true, lang)
            XCTAssertEqual(r.first?.hits.first?.entry.id, "shortcuts.record", lang)
            XCTAssertFalse(r.first?.hits.contains { $0.entry.id == "shortcuts.restore" } ?? true, lang)
            XCTAssertEqual(r.first?.hits.map { $0.entry.section }.filter { $0 == "shortcuts.capture" }.count, 5, lang)   // record, snap, text, translate, voice
            // the other panes' hits follow, each pane once; the page's order is the search's
            XCTAssertEqual(Set(r.map(\.pane)).count, r.count, lang)
            XCTAssertTrue(r.dropFirst().allSatisfy { !$0.paneHit }, lang)
            XCTAssertEqual(SettingsCatalog.search("short", off: []).map(\.entry.id), r.flatMap(\.hits).map(\.entry.id), lang)
            // why a pane matched is said in the UI's language only: its own name needs no reason, and its name or a
            // keyword in the other language is never shown (no English inside the Chinese UI)
            XCTAssertNil(SettingsCatalog.reason(pane: "shortcuts", query: "short"), lang)
            XCTAssertEqual(SettingsCatalog.reason(pane: "shortcuts", query: "hotkey"), lang == "en" ? "hotkey" : nil, lang)
        }
        Loc.setting = "en"
        // an action is found only by its own words
        XCTAssertEqual(SettingsCatalog.results("restore", off: []).first?.hits.first?.entry.id, "shortcuts.restore")
        // pane keywords alone: the pane as a whole
        XCTAssertEqual(SettingsCatalog.results("hotkey", off: []).first?.paneHit, true)
        XCTAssertEqual(SettingsCatalog.results("hotkey", off: []).first?.pane, "shortcuts")
        // groups: best first, a pane's hits by section
        let voice = SettingsCatalog.results("voice", off: [])
        XCTAssertTrue(voice.allSatisfy { !$0.paneHit })
        for g in voice {
            var seen: [String] = []
            for s in g.hits.map({ $0.entry.section ?? "" }) where seen.last != s {
                XCTAssertFalse(seen.contains(s), "section \(s) of \(g.pane) split")
                seen.append(s)
            }
        }
        XCTAssertEqual(voice.map(\.score), voice.map(\.score).sorted(by: >))
        // why a row matched when its title doesn't say: the stretch of its description
        let login = SettingsCatalog.entry("general.login")!
        XCTAssertEqual(SettingsCatalog.reason(login, query: "login"), nil)
        XCTAssertTrue(SettingsCatalog.reason(login, query: "short")?.localizedCaseInsensitiveContains("shortcuts") == true)
        XCTAssertEqual(SettingsCatalog.reason(login, query: "startup"), "startup")
        // the sentence that holds the words, whole from its start, without its parentheses (cut at the row's end only)
        XCTAssertEqual(SettingsCatalog.excerpt(["Blurt tells you when a shortcut clashes with another Blurt action"], ["another"]),
                       "Blurt tells you when a shortcut clashes with another Blurt action")
        XCTAssertEqual(SettingsCatalog.excerpt(["Screenshots become cards. They use macOS’s own shortcuts (⇧⌘3, ⇧⌘4)."], ["short"]),
                       "They use macOS’s own shortcuts.")
        // in the Chinese UI, a row found through its English text shows its own Chinese description, never the English
        Loc.setting = "zh-Hans"
        let r = SettingsCatalog.reason(login, query: "short")
        XCTAssertFalse(r?.contains("shortcuts") ?? false, r ?? "")
        Loc.setting = "en"
    }

    /// The no-match page's common searches each land somewhere, in either UI language.
    func testSuggestionsAlwaysFindSomething() {
        XCTAssertFalse(SettingsCatalog.suggestions.isEmpty)
        for lang in Loc.languages {
            Loc.setting = lang
            for t in SettingsCatalog.suggestions {
                let word = SettingsCatalog.text(t)
                XCTAssertNotNil(word, "\(t.key) missing in \(lang)")
                XCTAssertFalse(SettingsCatalog.search(word ?? "", off: []).isEmpty, "\(lang): “\(word ?? "")” finds nothing")
                // …and with every capability off: the app's own panes answer each
                XCTAssertFalse(SettingsCatalog.search(word ?? "", off: Set(Capability.allCases)).isEmpty, "\(lang): “\(word ?? "")” finds nothing with all off")
            }
        }
        XCTAssertTrue(SettingsCatalog.search("zzqx", off: []).isEmpty)
    }

    /// T() fills its own placeholders. Wrapped in String(format:) it has already filled them with nothing, so the text shows "(null)" and the
    /// arguments go nowhere: the pairing ask once said "Allow (null) to control this Mac?".
    func testNoTextIsFormattedTwice() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: #"String\(\s*format:\s*TP?\("#)
        var seen = 0
        for case let f as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where f.pathExtension == "swift" {
            let code = try String(contentsOf: f, encoding: .utf8)
            seen += 1
            for m in pattern.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                let line = code[..<Range(m.range, in: code)!.lowerBound].filter { $0 == "\n" }.count + 1
                XCTFail("\(f.lastPathComponent):\(line): pass the arguments to T() instead")
            }
        }
        XCTAssertGreaterThan(seen, 50, "no sources found: the scan looks in the wrong place")
    }

    func testPlaceholdersReadAsAGapWithoutArguments() {
        XCTAssertEqual(SettingsCatalog.fillGaps("Double-tap %@ to send"), "Double-tap … to send")
        XCTAssertEqual(SettingsCatalog.fillGaps("%1$@, in %2$@"), "…, in …")
        XCTAssertEqual(SettingsCatalog.fillGaps("%ld seconds, 100%%"), "… seconds, 100%")
        XCTAssertEqual(SettingsCatalog.fillGaps("plain"), "plain")
    }
}
