// Settings → General, in groups: Projects (the folders opened in Blurt, and which one new captures go to); App (open at
// login, language — Spotlight is in Privacy: each setting lives in one pane); Recording (what happens after one,
// countdown, system audio, collecting macOS screenshots); Voice notes (whether a pause ends one —
// record.voice.end_on_pause, off: Capture/VoiceInput.swift — and the words while you talk — record.live_text, on:
// Capture/LiveTranscript.swift); Cards (what dragging a card out does: chat apps get picture and note in two pastes —
// record.smart_paste, on: Capture/SmartPaste.swift —, copy its note where it didn't go in — record.drag_copy_note, on —,
// also attach the note as a .md file — record.drag_note_file, off —, burn the note under the dragged picture —
// record.drag_caption, off); Advanced (the Dictation Lab); About (version, updates, the user guide, the setup
// assistant). Rows and their descriptions come from SettingsCatalog. The menu-bar menu stays short because these live here.
import AppKit
import ServiceManagement
import SwiftUI
import BlurtCore

@MainActor
final class GeneralModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var current: String = "auto"
    @Published var openAtLogin = false
    @Published var loginError: String?
    @Published var language = "auto"
    @Published var processMode = "auto"
    @Published var countdown = 3
    @Published var systemAudio = false
    @Published var collect = false
    @Published var dragCopyNote = true
    @Published var dragNoteFile = false
    @Published var dragCaption = false
    @Published var smartPaste = true
    @Published var voiceEndOnPause = false
    @Published var liveText = true
    @Published var dictationLab = DictationLabModel.enabled
    @Published var error: String?

    init() { reload() }

    func reload() {
        let s = ProjectStore.shared
        s.reload()
        projects = s.projects
        current = s.currentID ?? "auto"
        openAtLogin = SMAppService.mainApp.status == .enabled
        let l = Config.shared["lang"] as? String ?? "auto"
        language = l == "zh" ? "zh-Hans" : (["en", "zh-Hans"].contains(l) ? l : "auto")
        processMode = (recordConfig()["process"] as? String ?? "auto") == "off" ? "off" : "auto"
        countdown = recordConfig()["countdown"] as? Int ?? 3
        systemAudio = recordConfig()["system_audio"] as? Bool ?? false
        collect = snapper.collecting
        dragCopyNote = CardExport.copyNoteAfterDrag
        dragNoteFile = CardExport.attachNoteFile
        dragCaption = CardExport.burnCaption
        smartPaste = SmartPaste.enabled
        voiceEndOnPause = VoiceInput.endOnPause
        liveText = LiveTranscript.enabled
    }

    private func run(_ f: @escaping () async throws -> Void) {
        Task { @MainActor in
            do { try await f(); error = nil } catch let e as ProjectError {
                error = Scripts.Failure(code: e.code, message: "\(e)").localized
            } catch { self.error = "\(error)" }
            reload()
        }
    }

    func setCurrent(_ id: String) { run { try await ProjectStore.shared.use(id == "auto" ? nil : id) } }
    func remove(_ p: Project) { run { try await ProjectStore.shared.remove(p.id) } }
    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = T("main.open.prompt")
        panel.message = T("main.open.message")
        let open: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK else { return }
            let urls = panel.urls
            self?.run { for u in urls { _ = try await ProjectStore.shared.open(folder: u) } }
        }
        // a sheet on the Settings window, not an app-wide modal panel
        if let w = NSApp.keyWindow { panel.beginSheetModal(for: w, completionHandler: open) } else { open(panel.runModal()) }
    }
    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
    func setLanguage(_ v: String) {
        Config.shared.set("lang", v == "auto" ? nil : v)
        language = v
    }
    func setProcess(_ v: String) { setRecordConfig("process", v); processMode = v }
    func setCountdown(_ v: Int) { setRecordConfig("countdown", v); countdown = v }
    func setSystemAudio(_ v: Bool) { setRecordConfig("system_audio", v); systemAudio = v }
    func setCollect(_ v: Bool) {
        setRecordConfig("collect_system_shots", v)
        snapper.syncCollector()
        collect = snapper.collecting
    }
    func setDragCopyNote(_ v: Bool) { setRecordConfig("drag_copy_note", v); dragCopyNote = v }
    func setDragNoteFile(_ v: Bool) { setRecordConfig("drag_note_file", v ? true : nil); dragNoteFile = v }
    func setDragCaption(_ v: Bool) { setRecordConfig("drag_caption", v); dragCaption = v }
    func setSmartPaste(_ v: Bool) {
        setRecordConfig("smart_paste", v)
        smartPaste = v
        if !v { SmartPaste.shared.disarm("off") }
    }
    func setVoiceEndOnPause(_ v: Bool) { VoiceInput.setEndOnPause(v); voiceEndOnPause = v }
    func setLiveText(_ v: Bool) { LiveTranscript.setEnabled(v); liveText = v }
    func setDictationLab(_ v: Bool) { Config.shared.set("record.dictation.lab", v ? true : nil); dictationLab = v }
}

struct GeneralPane: View {
    @StateObject var m = GeneralModel()

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return v.isEmpty ? "—" : v
    }

    var body: some View {
        SettingsPage(.general) {
            SettingsGroup("general.projects", footer: T("settings.general.projects.hint")) {
                SettingRow("general.capture_into") {
                    RowPicker(label: T("settings.general.capture_into"), selection: Binding(get: { m.current }, set: { m.setCurrent($0) })) {
                        Text(T("settings.general.auto")).tag("auto")
                        ForEach(m.projects, id: \.id) { p in Text(p.name).tag(p.id) }
                    }
                }
                ForEach(m.projects, id: \.id) { p in projectLine(p) }
                SettingsLine {
                    HStack {
                        Button(T("project.open_folder")) { m.openFolder() }
                        Spacer()
                        Button(T("settings.general.open_unassigned")) { NSWorkspace.shared.open(ProjectStore.shared.inbox.store) }
                    }
                }
                if let e = m.error { Text(e).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandErr).padding(.bottom, 4) }
            }

            SettingsGroup("general.app") {
                SettingToggle("general.login", isOn: Binding(get: { m.openAtLogin }, set: { m.setLogin($0) }),
                              detail: m.loginError)
                // the running app keeps the language it opened with: say so, and offer to reopen it now
                let pendingLanguage = Loc.normalize(m.language) != Loc.language
                SettingRow("general.language", detail: pendingLanguage ? T("settings.general.language.restart") : nil) {
                    HStack(spacing: 8) {
                        if pendingLanguage {
                            Button(T("settings.general.language.relaunch")) { SystemAccess.relaunch(source: "language", guide: false) }
                        }
                        RowPicker(label: T("settings.general.language"), selection: Binding(get: { m.language }, set: { m.setLanguage($0) })) {
                            Text(T("settings.general.language.system")).tag("auto")
                            Text("English").tag("en")
                            Text("简体中文").tag("zh-Hans")
                        }
                    }
                }
            }

            SettingsGroup("general.recording") {
                SettingRow("general.after_recording") {
                    RowPicker(label: T("settings.general.after_recording"), selection: Binding(get: { m.processMode }, set: { m.setProcess($0) })) {
                        Text(T("app.menu.after.organize")).tag("auto")
                        Text(T("app.menu.after.keep")).tag("off")
                    }
                }
                SettingRow("general.countdown") {
                    RowPicker(label: T("app.menu.countdown"), selection: Binding(get: { m.countdown }, set: { m.setCountdown($0) })) {
                        Text(T("app.menu.countdown.none")).tag(0)
                        Text(T("app.menu.countdown.seconds", 3)).tag(3)
                        Text(T("app.menu.countdown.seconds", 5)).tag(5)
                    }
                }
                SettingToggle("general.system_audio", isOn: Binding(get: { m.systemAudio }, set: { m.setSystemAudio($0) }))
                SettingToggle("general.collect", isOn: Binding(get: { m.collect }, set: { m.setCollect($0) }))
            }

            SettingsGroup("general.voice") {
                SettingToggle("general.voice_end_on_pause", isOn: Binding(get: { m.voiceEndOnPause }, set: { m.setVoiceEndOnPause($0) }))
                SettingToggle("general.live_text", isOn: Binding(get: { m.liveText }, set: { m.setLiveText($0) }))
            }

            SettingsGroup("general.cards") {
                SettingToggle("general.smart_paste", isOn: Binding(get: { m.smartPaste }, set: { m.setSmartPaste($0) }))
                SettingToggle("general.drag_copy_note", isOn: Binding(get: { m.dragCopyNote }, set: { m.setDragCopyNote($0) }))
                SettingToggle("general.drag_note_file", isOn: Binding(get: { m.dragNoteFile }, set: { m.setDragNoteFile($0) }))
                SettingToggle("general.drag_caption", isOn: Binding(get: { m.dragCaption }, set: { m.setDragCaption($0) }))
            }

            SettingsGroup("general.developer") {
                SettingToggle("general.dictation_lab", isOn: Binding(get: { m.dictationLab }, set: { m.setDictationLab($0) }))
            }

            SettingsGroup("general.about") {
                // the skill and the app don't speak the same contract: said here for as long as it lasts
                let mismatch = SkillContract.check(skill: SkillContract.skillVersion())
                SettingRow("general.version", detail: mismatch.map { T($0.appIsOlder ? "app.contract.app_older" : "app.contract.skill_older") },
                           detailColor: mismatch == nil ? nil : Color.brandAttnInk) {
                    HStack(spacing: 10) {
                        Text(Self.version).monospacedDigit().foregroundStyle(.secondary).textSelection(.enabled)
                        if mismatch != nil {
                            Button(T("app.contract.how")) { Housekeeping.contractHelp() }
                        } else if Updater.shared.available {
                            Button(T("app.menu.updates")) { Updater.shared.checkForUpdates(nil) }.disabled(!Updater.shared.canCheck)
                        }
                    }
                }
                SettingRow("general.help") {
                    Button(T("action.open")) { NSWorkspace.shared.open(Help.guideURL()) }
                }
                SettingRow("general.assistant") {
                    Button(T("action.open")) { Onboarding.shared.show() }
                }
            }
        }
        .onAppear { m.reload() }
    }

    /// A project: its folder, name, key and path, with Open and Remove.
    func projectLine(_ p: Project) -> some View {
        SettingsLine(padding: 8) {
            HStack(spacing: 14) {
                Image(systemName: p.exists ? "folder" : "questionmark.folder").foregroundStyle(.secondary)
                    .frame(width: SettingsMetrics.leadingWidth).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.name).font(.system(size: SettingsMetrics.titleSize))
                        Text(p.key).font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                    }
                    Text((p.path.path as NSString).abbreviatingWithTildeInPath).font(.system(size: SettingsMetrics.detailSize))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(p.path.path)
                }
                Spacer(minLength: 8)
                Button { NSWorkspace.shared.open(p.path) } label: { Image(systemName: "arrow.up.forward.app") }.buttonStyle(.borderless)
                    .help(T("action.open")).accessibilityLabel(T("action.open"))
                Button { m.remove(p) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    .help(T("settings.general.remove.help")).accessibilityLabel(T("settings.general.remove.help"))
            }
            .accessibilityElement(children: .contain)
        }
    }
}
