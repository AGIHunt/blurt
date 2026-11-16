// Settings → Text & Translation (取字与翻译; 2026-10-30: its own page, beside Dictation; before, a box in General).
//   Copy (⌥C)       Extra accuracy: a switch (record.screen_text.refine, ScreenTextRefine); the line under it says which
//                   model reads ("Uses qwen3.6-flash · cloud") with Change… — the Copy Text from Screen row of
//                   Settings → Models picks it — or what is missing (this Mac's model to download).
//   Translate (⌥T)  "⌥T translates into" (record.screen_text.translate, ScreenTranslateConfig) and the model that
//                   translates (Settings → Models' Translate row, shared with dictation). Reading foreign text into your
//                   own language usually goes the other way from dictation's ⌘ (writing your own words in another
//                   language), so the two don't share a target. Under Auto, a line says where other languages go.
//   History         how long what was read is kept (record.screen_text.history_days: 7, 30, forever, not kept), with
//                   the page that lists it (2026-11-16) and Clear History….
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

    /// "12 saved · deleted after 30 days", Open History… — how long, and Clear History…, in its menu (Dictation's
    /// history row's way).
    var historyRow: some View {
        let d = m.historyDays
        let detail = d == 0 ? T("settings.screen_text.history.summary.off")
            : d < 0 ? T("home.screen_text.summary.forever", m.historyCount)
            : T("home.screen_text.summary", m.historyCount, T("dictation.history.days", d))
        return SettingRow("screentext.history", detail: detail, hosts: ["screentext.history_keep"]) {
            Menu {
                SettingMenuPicker("screentext.history_keep", selection: Binding(get: { m.historyDays }, set: { m.setHistoryDays($0) })) {
                    ForEach([7, 30], id: \.self) { n in Text(T("dictation.history.days", n)).tag(n) }
                    Text(T("settings.screen_text.history.forever")).tag(-1)
                    Divider()
                    Text(T("dictation.history.dont_keep")).tag(0)
                }
                Divider()
                Button(T("settings.screen_text.history.clear"), role: .destructive) { m.askClear() }
                    .disabled(m.historyCount == 0)
            } label: {
                Text(T("settings.screen_text.history.open"))
            } primaryAction: { MainWindowController.shared.go(.screenText) }
            .fixedSize()
        }
    }
}
