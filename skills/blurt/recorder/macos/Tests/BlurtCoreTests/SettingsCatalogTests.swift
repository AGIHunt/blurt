// BlurtCore/SettingsCatalog.swift: the Settings window's rows as data. Every text exists in both languages, every id is
// rendered exactly once by the panes (BlurtApp/Settings/*.swift, App/HotkeySettings.swift: SettingRow / SettingToggle /
// SettingsGroup with that id) and nothing is rendered that the catalogue — and so search — doesn't know; search finds
// rows by title, keyword or the other language.
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
    }

    /// The panes render each id once, and only ids the catalogue has: the search index and the window can't drift.
    func testThePanesRenderTheCatalogue() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BlurtApp")
        var files = try FileManager.default.contentsOfDirectory(at: app.appendingPathComponent("Settings"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        files.append(app.appendingPathComponent("App/HotkeySettings.swift"))
        let pattern = try NSRegularExpression(pattern: #"\b(SettingRow|SettingToggle|SettingsGroup)\(\s*"([a-z0-9_.]+)""#)
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
        func top(_ q: String) -> String? { SettingsCatalog.search(q).first?.entry.id }
        func ids(_ q: String) -> [String] { SettingsCatalog.search(q).map(\.entry.id) }
        XCTAssertEqual(top("open blurt at login"), "general.login")
        XCTAssertEqual(top("startup"), "general.login")               // a keyword
        XCTAssertEqual(top("mirror"), "speech.mirror")
        XCTAssertEqual(top("开机"), "general.login")                   // Chinese in the English UI
        XCTAssertTrue(ids("hotkey").contains("shortcuts.snap"))       // the pane's keywords: its rows
        XCTAssertTrue(ids("voice").contains("general.voice_end_on_pause"))
        XCTAssertFalse(ids("voice").contains("dictation.key"))       // …but not when rows match themselves
        XCTAssertFalse(ids("model").contains("speech.threads"))      // a pane keyword alone doesn't pull in its rows
        XCTAssertTrue(ids("model").contains("storage.models"))
        XCTAssertEqual(ids("shortcuts").first, "shortcuts.record")   // a pane's name: its rows lead, in page order
        XCTAssertEqual(ids("shortcut").first, "shortcuts.record")    // …or the start of it, as it's typed
        XCTAssertEqual(ids("short").first, "shortcuts.record")
        XCTAssertEqual(ids("快捷").first, "shortcuts.record")
        XCTAssertNotEqual(ids("s").first, "shortcuts.record")        // one letter isn't a pane's name yet
        XCTAssertEqual(top("codex"), "agents.list")                   // an agent's name finds the agents list
        XCTAssertEqual(top("claude"), "agents.list")
        XCTAssertEqual(top("Kimi"), "agents.list")
        XCTAssertEqual(top("voice pause"), "general.voice_end_on_pause")  // every word, anywhere
        XCTAssertTrue(ids("LOGIN").contains("general.login"))         // case doesn't matter
        XCTAssertEqual(ids(""), [])
        XCTAssertEqual(ids("   "), [])
        XCTAssertEqual(ids("zzqqxx"), [])
        // a title match outranks a description match
        let hits = SettingsCatalog.search("spotlight")
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
        XCTAssertEqual(SettingsCatalog.redirect("general/smart_paste"), "general/general.card_drag")
        XCTAssertEqual(SettingsCatalog.redirect("general/general.login"), "general/general.login")
        XCTAssertEqual(SettingsCatalog.redirect("general"), "general")
        XCTAssertEqual(SettingsCatalog.redirect("export/target"), "agents/agents.ask")
        for (old, new) in SettingsCatalog.movedRows {
            XCTAssertNil(SettingsCatalog.entry(old), "\(old) moved but is still in the catalogue")
            XCTAssertTrue(SettingsCatalog.entry(new) != nil || SettingsCatalog.section(new) != nil, "\(old) → \(new): no such row")
        }
    }

    func testPlaceholdersReadAsAGapWithoutArguments() {
        XCTAssertEqual(SettingsCatalog.fillGaps("Double-tap %@ to send"), "Double-tap … to send")
        XCTAssertEqual(SettingsCatalog.fillGaps("%1$@, in %2$@"), "…, in …")
        XCTAssertEqual(SettingsCatalog.fillGaps("%ld seconds, 100%%"), "… seconds, 100%")
        XCTAssertEqual(SettingsCatalog.fillGaps("plain"), "plain")
    }
}
