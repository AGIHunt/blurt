// Settings → Copy Text from Screen (2026-10-30: its own page, beside Dictation; before, a box in General).
//   Copy (⌥C)       Extra accuracy: off, this Mac's OCR model, or the cloud model set up for cloud polish
//                   (record.screen_text.refine, ScreenTextRefine) — the line under it says what each one costs and what
//                   is missing.
//   Translate (⌥T)  "⌥T translates into" and its own "Use the cloud model to translate" (record.screen_text.translate,
//                   ScreenTranslateConfig). Reading foreign text into your own language usually goes the other way from
//                   dictation's ⌘ (writing your own words in another language), so the two don't share a target; the
//                   cloud model and its key are set up once, under Models → Cloud polish.
// docs/design/screen-text.md §1f.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class ScreenTextModel: ObservableObject {
    @Published var refine = ScreenTextRefine.Mode.off
    @Published var installed: Bool? = ScreenTextRefine.installed
    @Published var cloudReady = false
    @Published var localPolish = false
    @Published var translate = ScreenTranslateConfig()

    init() { reload() }

    func reload() {
        refine = ScreenTextRefine.mode
        cloudReady = ScreenTextRefine.cloudPayload != nil
        localPolish = Dictation.shared.polishModel != nil
        translate = ScreenTextCopy.translateConfig
        ScreenTextRefine.refreshInstalled { [weak self] in self?.installed = ScreenTextRefine.installed }
    }

    func setRefine(_ v: ScreenTextRefine.Mode) {
        ScreenTextRefine.setMode(v)
        refine = v
        // choosing this Mac's model is asking for it: the download starts (one 720 MB file, the one download manager)
        if v == .local, installed == false { download() }
    }

    func setTranslate(_ change: (inout ScreenTranslateConfig) -> Void) {
        var c = ScreenTextCopy.translateConfig
        change(&c)
        ScreenTextCopy.setTranslateConfig(c)
        translate = c
        emit(["event": "screen_text_setting", "key": "translate", "target": c.target.rawValue, "cloud": c.cloud])
    }

    func download() {
        ModelDownloads.shared.download([.init(id: ScreenTextRefine.modelID, kind: .screenText, name: "PaddleOCR-VL",
                                              sizeMB: ScreenTextRefine.modelSizeMB)], via: "settings")
    }
}

struct ScreenTextPane: View {
    @StateObject var m = ScreenTextModel()
    @ObservedObject private var downloads = ModelDownloads.shared

    var body: some View {
        SettingsPage(.screenText) {
            SettingsGroup("screentext.copy") { refineRow }
            SettingsGroup("screentext.translation") { translateRows }
        }
        .onAppear { m.reload() }
    }

    /// ⌥C's second reading (ScreenTextRefine): off, this Mac's OCR model, or the cloud model set up for cloud polish —
    /// the line under it says what each one costs (a download and memory, or a cent a hundred captures) and what is missing.
    var refineRow: some View {
        let id = ScreenTextRefine.modelID
        let gb = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        var detail = T("settings.general.screen_text.detail.off")
        var action: (String, () -> Void)?
        switch m.refine {
        case .off: break
        case .local:
            if downloads.isRunning(id) || downloads.isQueued(id) {
                let p = downloads.progress(id)
                detail = T("settings.general.screen_text.detail.downloading",
                           p.map { "\(modelSize($0.done)) / \(modelSize($0.total))" } ?? modelSize(ScreenTextRefine.modelSizeMB))
            } else if m.installed == false {
                detail = T("settings.general.screen_text.detail.download", modelSize(ScreenTextRefine.modelSizeMB))
                action = (T("settings.general.screen_text.download"), { m.download() })
            } else {
                detail = T("settings.general.screen_text.detail.local")
                if gb < 16 { detail += " " + T("settings.general.screen_text.detail.local_small", gb) }
            }
        case .cloud:
            if m.cloudReady {
                detail = T("settings.general.screen_text.detail.cloud", DictationCloud.setup.effectiveModel)
            } else {
                detail = T("settings.general.screen_text.detail.cloud_missing")
                action = (T("settings.general.screen_text.setup"), { AppEnvironment.settings?.show(pane: "speech/speech.cloud_polish") })
            }
        }
        return SettingRow("screentext.refine", detail: detail) {
            HStack(spacing: 8) {
                if let a = action {
                    Button(a.0, action: a.1).buttonStyle(SettingsOutlinedButtonStyle()).fixedSize()
                }
                ChoicePopup(label: T("settings.general.screen_text"),
                            choices: ScreenTextRefine.Mode.allCases.map { ($0, T("settings.general.screen_text.\($0.rawValue)")) },
                            selection: Binding(get: { m.refine }, set: { m.setRefine($0) }))
            }
        }
    }

    /// ⌥T: into what (Auto: your own language ↔ the other one, named), and whether the cloud model translates.
    @ViewBuilder var translateRows: some View {
        SettingRow("screentext.translate", detail: TranslateTargets.autoNote(m.translate.target)) {
            ChoicePopup(label: T("settings.screen_text.translate"), choices: TranslateTargets.choices(),
                        selection: Binding(get: { m.translate.target }, set: { v in m.setTranslate { $0.target = v } }),
                        width: TranslateTargets.popupWidth, dividers: [1])
        }
        // nothing to switch on yet: the switch shows off, and the fix sits before it (as Dictation's row)
        SettingRow("screentext.translate_cloud",
                   detail: m.cloudReady ? T("dictation.translate.cloud.detail", DictationCloud.setup.destination)
                       : m.localPolish ? T("dictation.translate.cloud.none") : T("dictation.translate.cloud.nothing")) {
            HStack(spacing: 8) {
                if !m.cloudReady {
                    Button(T("dictation.translate.cloud.setup")) { AppEnvironment.settings?.show(pane: "speech/speech.cloud_polish") }
                        .controlSize(.small)
                }
                Toggle(SettingsCatalog.entry("screentext.translate_cloud").map(SettingsCatalog.title) ?? "",
                       isOn: Binding(get: { m.cloudReady && m.translate.cloud }, set: { v in m.setTranslate { $0.cloud = v } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .disabled(!m.cloudReady)
            }
        }
    }
}
