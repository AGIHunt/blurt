// Settings → General: projects (the folders opened in Blurt, and which one new captures go to), open at login,
// language (Spotlight is in Privacy: each setting lives in one pane); recording (what happens after one, countdown,
// system audio, collecting macOS screenshots, and what dragging a card out does: copy its note too where it didn't go in — record.drag_copy_note, on — also attach the
// note as a .md file — record.drag_note_file, off — and burn the note under the dragged picture — record.drag_caption,
// off; chat apps get picture and note in two pastes — record.smart_paste, on: Capture/SmartPaste.swift); voice notes
// (whether a pause ends one — record.voice.end_on_pause, off: Capture/VoiceInput.swift) and the words while you talk
// (record.live_text, on: Capture/LiveTranscript.swift);
// about (version, the user guide, updates). The menu-bar menu stays short because these live here.
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
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        run { for u in urls { _ = try await ProjectStore.shared.open(folder: u) } }
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
        PaneFrame {
            Section {
                Picker(T("settings.general.capture_into"), selection: Binding(get: { m.current }, set: { m.setCurrent($0) })) {
                    Text(T("settings.general.auto")).tag("auto")
                    ForEach(m.projects, id: \.id) { p in Text(p.name).tag(p.id) }
                }
                ForEach(m.projects, id: \.id) { p in
                    HStack {
                        Image(systemName: p.exists ? "folder" : "questionmark.folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(p.name)
                                Text(p.key).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            }
                            Text((p.path.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(p.path.path)
                        }
                        Spacer()
                        Button { NSWorkspace.shared.open(p.path) } label: { Image(systemName: "arrow.up.forward.app") }.buttonStyle(.borderless)
                            .help(T("action.open")).accessibilityLabel(T("action.open"))
                        Button { m.remove(p) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            .help(T("settings.general.remove.help")).accessibilityLabel(T("settings.general.remove.help"))
                    }
                }
                HStack {
                    Button(T("project.open_folder")) { m.openFolder() }
                    Spacer()
                    Button(T("settings.general.open_unassigned")) { NSWorkspace.shared.open(ProjectStore.shared.inbox.store) }
                }
                if let e = m.error { Text(e).font(.caption).foregroundStyle(Color.brandErr) }
                Hint(T("settings.general.projects.hint"))
            } header: { Text(T("main.sidebar.projects")) }

            Section {
                Toggle(T("settings.general.login"), isOn: Binding(get: { m.openAtLogin }, set: { m.setLogin($0) }))
                if let e = m.loginError { Text(e).font(.caption).foregroundStyle(Color.brandErr) }
                Picker(T("settings.general.language"), selection: Binding(get: { m.language }, set: { m.setLanguage($0) })) {
                    Text(T("settings.general.language.system")).tag("auto")
                    Text("English").tag("en")
                    Text("简体中文").tag("zh-Hans")
                }
                if Loc.normalize(m.language) != Loc.language {   // the running app keeps the language it opened with
                    Hint(T("settings.general.language.restart"))
                }
            } header: { Text(T("settings.general.app")) }

            Section {
                Picker(T("settings.general.after_recording"), selection: Binding(get: { m.processMode }, set: { m.setProcess($0) })) {
                    Text(T("app.menu.after.organize")).tag("auto")
                    Text(T("app.menu.after.keep")).tag("off")
                }
                Picker(T("app.menu.countdown"), selection: Binding(get: { m.countdown }, set: { m.setCountdown($0) })) {
                    Text(T("app.menu.countdown.none")).tag(0)
                    Text(T("app.menu.countdown.seconds", 3)).tag(3)
                    Text(T("app.menu.countdown.seconds", 5)).tag(5)
                }
                Toggle(T("settings.general.system_audio"), isOn: Binding(get: { m.systemAudio }, set: { m.setSystemAudio($0) }))
                Toggle(T("settings.general.collect"), isOn: Binding(get: { m.collect }, set: { m.setCollect($0) }))
                Hint(T("settings.general.collect.hint"))
                Toggle(T("settings.general.voice_end_on_pause"), isOn: Binding(get: { m.voiceEndOnPause }, set: { m.setVoiceEndOnPause($0) }))
                Hint(T("settings.general.voice_end_on_pause.hint"))
                Toggle(T("settings.general.live_text"), isOn: Binding(get: { m.liveText }, set: { m.setLiveText($0) }))
                Hint(T("settings.general.live_text.hint"))
                Toggle(T("settings.general.smart_paste"), isOn: Binding(get: { m.smartPaste }, set: { m.setSmartPaste($0) }))
                Hint(T("settings.general.smart_paste.hint"))
                Toggle(T("settings.general.drag_copy_note"), isOn: Binding(get: { m.dragCopyNote }, set: { m.setDragCopyNote($0) }))
                Hint(T("settings.general.drag_copy_note.hint"))
                Toggle(T("settings.general.drag_note_file"), isOn: Binding(get: { m.dragNoteFile }, set: { m.setDragNoteFile($0) }))
                Hint(T("settings.general.drag_note_file.hint"))
                Toggle(T("settings.general.drag_caption"), isOn: Binding(get: { m.dragCaption }, set: { m.setDragCaption($0) }))
                Hint(T("settings.general.drag_caption.hint"))
                Toggle(T("settings.general.dictation_lab"), isOn: Binding(get: { m.dictationLab }, set: { m.setDictationLab($0) }))
                Hint(T("settings.general.dictation_lab.hint"))
            } header: { Text(T("settings.general.recording")) }

            Section {
                LabeledContent(T("settings.general.version"), value: Self.version)
                HStack {
                    Button(T("settings.general.help")) { NSWorkspace.shared.open(Help.guideURL()) }
                    Button(T("settings.general.assistant")) { Onboarding.shared.show() }
                    Spacer()
                    if Updater.shared.available {
                        Button(T("app.menu.updates")) { Updater.shared.checkForUpdates(nil) }.disabled(!Updater.shared.canCheck)
                    }
                }
            } header: { Text(T("settings.general.about")) }
        }
        .onAppear { m.reload() }
    }
}
