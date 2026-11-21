// Settings → Text & Translation (取字与翻译; 2026-10-30: its own page, beside Dictation; before, a box in General).
//   Copy (⌥C)       Extra accuracy: a switch (record.screen_text.refine, ScreenTextRefine); the line under it says which
//                   model reads ("Uses qwen3.6-flash · cloud") with Change… — the Copy Text from Screen row of
//                   Settings → Models picks it — or what is missing (this Mac's model to download).
//   Translate (⌥T)  "⌥T translates into" (record.screen_text.translate, ScreenTranslateConfig) and the model that
//                   translates (Settings → Models' Translate row, shared with dictation). Reading foreign text into your
//                   own language usually goes the other way from dictation's ⌘ (writing your own words in another
//                   language), so the two don't share a target. Under Auto, a line says where other languages go.
//   History         "Keep history for": a popup in sight (record.screen_text.history_days: 7, 30, forever, not kept),
//                   as Settings → Cards → History — it was in the menu of Open History…, where no one found it. A
//                   choice that would delete entries asks first ("Delete 12 entries?", founder 2026-11-21). Then the
//                   saved text and translations: Open History… (the page that lists them, 2026-11-16), Clear History… in its ⋯.
// docs/design/screen-text.md §1f.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class ScreenTextModel: ObservableObject {
    @Published var on = false
    @Published var mode = ScreenTextRefine.Mode.off
    @Published var installed: Bool? = ScreenTextRefine.installed
    @Published var translate = ScreenTranslateConfig()
    @Published var historyDays = ScreenTextCopy.historyDays
    @Published var historyCount = 0

    init() { reload() }

    func reload() {
        on = ScreenTextRefine.on
        mode = ScreenTextRefine.mode
        translate = ScreenTextCopy.translateConfig
        historyDays = ScreenTextCopy.historyDays
        historyCount = ScreenTextHistory.shared.load().count
        ScreenTextRefine.refreshInstalled { [weak self] in self?.installed = ScreenTextRefine.installed }
    }

    func setOn(_ v: Bool) {
        ScreenTextRefine.setOn(v)
        on = v
        mode = ScreenTextRefine.mode
        emit(["event": "screen_text_setting", "key": "refine", "on": v, "mode": mode.rawValue])
    }

    func setTranslate(_ change: (inout ScreenTranslateConfig) -> Void) {
        var c = ScreenTextCopy.translateConfig
        change(&c)
        ScreenTextCopy.setTranslateConfig(c)
        translate = c
        emit(["event": "screen_text_setting", "key": "translate", "target": c.target.rawValue])
    }

    /// A shorter period, or Don't keep, that would delete entries asks first; Cancel keeps the period as it was.
    func pickHistoryDays(_ d: Int) {
        guard d != historyDays else { return }
        let n = ScreenTextHistory.shared.wouldPrune(days: d)
        emit(["event": "screen_text_setting", "key": "history_days_asked", "days": d, "would_delete": n])
        guard n == 0 || confirmShorten(d, deleting: n) else {
            objectWillChange.send()         // the popup shows the period kept again
            emit(["event": "screen_text_setting", "key": "history_days_cancelled", "days": d])
            return
        }
        setHistoryDays(d)
    }

    /// "Delete 12 entries?" — those older than the new period, or all of them for Don't keep. Test builds answer with
    /// BLURT_TEST_CONFIRM (yes | no) instead of the alert.
    private func confirmShorten(_ d: Int, deleting n: Int) -> Bool {
        if let a = ProcessInfo.processInfo.environment["BLURT_TEST_CONFIRM"], ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" {
            return a == "yes"
        }
        let a = NSAlert()
        a.alertStyle = .warning
        a.icon = NSApp.applicationIconImage
        a.messageText = T("settings.screen_text.history.shorten.title", n)
        a.informativeText = d == 0 ? T("settings.screen_text.history.shorten.off", n)
            : T("settings.screen_text.history.shorten.message", T("dictation.history.days", d))
        let cancel = a.addButton(withTitle: T("settings.screen_text.history.cancel"))
        cancel.keyEquivalent = "\r"
        let del = a.addButton(withTitle: T("settings.screen_text.history.shorten.confirm"))
        del.hasDestructiveAction = true
        del.keyEquivalent = ""
        return a.runModal() == .alertSecondButtonReturn
    }

    func setHistoryDays(_ d: Int) {
        ScreenTextCopy.setHistoryDays(d)
        historyDays = d
        emit(["event": "screen_text_setting", "key": "history_days", "days": d])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.historyCount = ScreenTextHistory.shared.load().count }
    }

    func askClear() {
        guard historyCount > 0 else { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.icon = NSApp.applicationIconImage
        a.messageText = T("settings.screen_text.history.clear.title")
        a.informativeText = T("settings.screen_text.history.clear.message", historyCount)
        let cancel = a.addButton(withTitle: T("settings.screen_text.history.cancel"))
        cancel.keyEquivalent = "\r"
        let clear = a.addButton(withTitle: T("settings.screen_text.history.clear.confirm"))
        clear.hasDestructiveAction = true
        clear.keyEquivalent = ""
        guard a.runModal() == .alertSecondButtonReturn else { return }
        ScreenTextHistory.shared.clear()
        historyCount = 0
        NotificationCenter.default.post(name: .blurtScreenTextChanged, object: nil)
        emit(["event": "screen_text_setting", "key": "history_clear"])
    }

    func download() {
        ModelDownloads.shared.download([.init(id: ScreenTextRefine.modelID, kind: .screenText, name: "PaddleOCR-VL",
                                              sizeMB: ScreenTextRefine.modelSizeMB)], via: "settings")
    }
}

struct ScreenTextPane: View {
    @StateObject var m = ScreenTextModel()
    @ObservedObject private var downloads = ModelDownloads.shared
    @ObservedObject private var ui = CloudModelsUI.shared

    var body: some View {
        SettingsPage(.screenText) {
            SettingsGroup("screentext.copy") { refineRow }
            SettingsGroup("screentext.translation") { translateRows }
            SettingsGroup("screentext.history_section") { historyRow }
        }
        .onAppear { m.reload() }
        .onChange(of: ui.tick) { _ in m.mode = ScreenTextRefine.mode }
    }

    /// ⌥C's second reading (ScreenTextRefine): a switch; the line says which model reads (Change… → Settings → Models)
    /// or what is missing — this Mac's model to download.
    var refineRow: some View {
        let id = ScreenTextRefine.modelID
        let gb = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        var detail = T("settings.general.screen_text.detail.off")
        var download = false
        if m.on {
            detail = CloudText.uses(.vision)
            if m.mode == .local {
                if downloads.isRunning(id) || downloads.isQueued(id) {
                    let p = downloads.progress(id)
                    detail = T("settings.general.screen_text.detail.downloading",
                               p.map { "\(modelSize($0.done)) / \(modelSize($0.total))" } ?? modelSize(ScreenTextRefine.modelSizeMB))
                } else if m.installed == false {
                    detail = T("settings.general.screen_text.detail.download", modelSize(ScreenTextRefine.modelSizeMB))
                    download = true
                } else if gb < 16 {
                    detail += Loc.isChinese ? "。" : ". "
                    detail += T("settings.general.screen_text.detail.local_small", gb)
                }
            }
        }
        return SettingRow("screentext.refine", detail: detail) {
            HStack(spacing: 8) {
                if download {
                    Button(T("settings.general.screen_text.download")) { m.download() }.buttonStyle(SettingsOutlinedButtonStyle()).fixedSize()
                }
                if m.on { JobChangeButton(job: .vision).buttonStyle(SettingsOutlinedButtonStyle()).fixedSize() }
                Toggle(T("settings.general.screen_text"), isOn: Binding(get: { m.on }, set: { m.setOn($0) }))
                    .labelsHidden().toggleStyle(BrandSwitchStyle(label: T("settings.general.screen_text")))
            }
        }
    }

    /// ⌥T: into what (Auto: your own language ↔ the other one, named), and which model translates.
    @ViewBuilder var translateRows: some View {
        SettingRow("screentext.translate", detail: TranslateTargets.autoNote(m.translate.target) ?? TranslateTargets.autoOthers(m.translate.target)) {
            ChoicePopup(label: T("settings.screen_text.translate"), choices: TranslateTargets.choices(),
                        selection: Binding(get: { m.translate.target }, set: { v in m.setTranslate { $0.target = v } }),
                        width: TranslateTargets.popupWidth, dividers: [1])
        }
        CloudObserving {
            SettingRow("screentext.translate_model", detail: CloudText.uses(.translate)) { JobChangeButton(job: .translate) }
        }
    }

    /// "Keep history for" in sight, as Settings → Cards → History (it hid in Open History…'s menu); under it what is
    /// kept, with the page that lists it and Clear History….
    @ViewBuilder var historyRow: some View {
        let d = m.historyDays
        let detail = d == 0 ? T("settings.screen_text.history.summary.off")
            : d < 0 ? T("home.screen_text.summary.forever", m.historyCount)
            : T("home.screen_text.summary", m.historyCount, T("dictation.history.days", d))
        SettingRow("screentext.history_keep", detail: detail) {
            ChoicePopup(label: T("settings.screen_text.history.keep"),
                        choices: [(7, T("dictation.history.days", 7)), (30, T("dictation.history.days", 30)),
                                  (-1, T("settings.screen_text.history.forever")), (0, T("dictation.history.dont_keep"))],
                        selection: Binding(get: { m.historyDays }, set: { m.pickHistoryDays($0) }), dividers: [3])
        }
        SettingRow("screentext.history") {
            // Clear History… in the row's ⋯ (a destructive action is never a button at rest, §3.4)
            HStack(spacing: 6) {
                Button(T("settings.screen_text.history.open")) { MainWindowController.shared.go(.screenText) }
                    .buttonStyle(SettingsOutlinedButtonStyle()).fixedSize()
                RowMenu(label: T("settings.screen_text.history.clear"), visible: m.historyCount > 0) {
                    Button(T("settings.screen_text.history.clear"), role: .destructive) { m.askClear() }
                }
            }
        }
    }
}
