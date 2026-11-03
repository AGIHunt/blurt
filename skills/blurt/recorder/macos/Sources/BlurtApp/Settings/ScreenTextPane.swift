// Settings → Copy Text from Screen (2026-10-30: its own page, beside Dictation; before, a box in General).
//   Copy (⌥C)       Extra accuracy: a switch (record.screen_text.refine, ScreenTextRefine); the line under it says which
//                   model reads ("Uses qwen3.6-flash · cloud") with Change… — the Copy Text from Screen row of
//                   Settings → Models picks it — or what is missing (this Mac's model to download).
//   Translate (⌥T)  "⌥T translates into" (record.screen_text.translate, ScreenTranslateConfig) and the model that
//                   translates (Settings → Models' Translate row, shared with dictation). Reading foreign text into your
//                   own language usually goes the other way from dictation's ⌘ (writing your own words in another
//                   language), so the two don't share a target.
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

    init() { reload() }

    func reload() {
        on = ScreenTextRefine.on
        mode = ScreenTextRefine.mode
        translate = ScreenTextCopy.translateConfig
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
        SettingRow("screentext.translate", detail: TranslateTargets.autoNote(m.translate.target)) {
            ChoicePopup(label: T("settings.screen_text.translate"), choices: TranslateTargets.choices(),
                        selection: Binding(get: { m.translate.target }, set: { v in m.setTranslate { $0.target = v } }),
                        width: TranslateTargets.popupWidth, dividers: [1])
        }
        CloudObserving {
            SettingRow("screentext.translate_model", detail: CloudText.uses(.translate)) { JobChangeButton(job: .translate) }
        }
    }
}
