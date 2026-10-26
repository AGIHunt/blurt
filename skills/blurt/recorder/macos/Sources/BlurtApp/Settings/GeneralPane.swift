// Settings → General: the app's everyday choices on one short page, four boxes and a closing line.
//   App          open at login (LoginItem: the assistant's switch too, so a test build never registers itself),
//                language (the running app keeps the one it opened with: Relaunch Now next to it).
//   Recording    what happens after one, the countdown, system audio.
//   Voice notes  how one ends — one choice, press the key again or a 1.5 s pause (record.voice.end_on_pause, off:
//                Capture/VoiceInput.swift) —, the words while you talk (record.live_text, on: Capture/LiveTranscript.swift).
//   Cards        macOS's own screenshots as cards (record.collect_system_shots); what a card dragged into an app
//                carries — one choice over three settings: "picture, then the note" (record.smart_paste, on:
//                Capture/SmartPaste.swift), "picture with the note under it" (record.drag_caption), "picture only";
//                with either of the first two, a note that couldn't go in goes on the clipboard (record.drag_copy_note,
//                on), with picture only it doesn't —; the note as a .md file too (record.drag_note_file, off). Pasting
//                the note needs Accessibility: said in attention ink with Allow… only while that choice is made and
//                the permission is missing.
//   About        one quiet line under the boxes: Blurt and its version, Check for Updates…, User Guide, Setup
//                Assistant… as brand-ink text buttons; a skill / app contract mismatch is said above it in attention
//                ink, with How to Update, for as long as it lasts.
// The projects have their own pane (ProjectsPane.swift); the Dictation Lab is under Dictation's Advanced. Rows and
// their descriptions come from SettingsCatalog; longer explanations are behind each row's ⓘ. Every pop-up is the same
// width (SettingsMetrics.controlWidth), so the controls share one column.
import AppKit
import ServiceManagement
import SwiftUI
import BlurtCore

/// What a card dragged into another app carries (the Cards box's one choice).
enum CardDragMode: String, CaseIterable {
    case paste, caption, picture

    /// From the three settings it stands for: the note burned in wins, then smart paste, else the picture alone.
    static var current: CardDragMode { CardExport.burnCaption ? .caption : SmartPaste.enabled ? .paste : .picture }

    /// Writes the three settings; each one left at its default where it can be (smart paste and the clipboard
    /// fallback on, the caption off).
    func apply() {
        setRecordConfig("smart_paste", self == .paste ? nil : false)
        setRecordConfig("drag_caption", self == .caption ? true : nil)
        setRecordConfig("drag_copy_note", self == .picture ? false : nil)
        if self != .paste { SmartPaste.shared.disarm("off") }
        emit(["event": "card_drag_mode", "mode": rawValue])
    }
}

@MainActor
final class GeneralModel: ObservableObject {
    @Published var openAtLogin = false
    @Published var loginError: String?
    @Published var language = "auto"
    @Published var processMode = "auto"
    @Published var countdown = 3
    @Published var systemAudio = false
    @Published var collect = false
    @Published var cardDrag = CardDragMode.paste
    @Published var dragNoteFile = false
    @Published var voiceEndOnPause = false
    @Published var liveText = true

    init() { reload() }

    func reload() {
        openAtLogin = LoginItem.enabled
        let l = Config.shared["lang"] as? String ?? "auto"
        language = l == "zh" ? "zh-Hans" : (["en", "zh-Hans"].contains(l) ? l : "auto")
        processMode = (recordConfig()["process"] as? String ?? "auto") == "off" ? "off" : "auto"
        countdown = recordConfig()["countdown"] as? Int ?? 3
        systemAudio = recordConfig()["system_audio"] as? Bool ?? false
        collect = snapper.collecting
        cardDrag = CardDragMode.current
        dragNoteFile = CardExport.attachNoteFile
        voiceEndOnPause = VoiceInput.endOnPause
        liveText = LiveTranscript.enabled
    }

    /// The same switch as the assistant's (LoginItem): a test build never registers itself in the user's Login Items.
    func setLogin(_ on: Bool) {
        loginError = LoginItem.set(on, via: "settings") == nil ? nil : T("settings.general.login_failed")
        openAtLogin = LoginItem.enabled
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
    func setCardDrag(_ v: CardDragMode) { v.apply(); cardDrag = CardDragMode.current }
    func setDragNoteFile(_ v: Bool) { setRecordConfig("drag_note_file", v ? true : nil); dragNoteFile = v }
    func setVoiceEndOnPause(_ v: Bool) { VoiceInput.setEndOnPause(v); voiceEndOnPause = v }
    func setLiveText(_ v: Bool) { LiveTranscript.setEnabled(v); liveText = v }
}

struct GeneralPane: View {
    @StateObject var m = GeneralModel()
    @StateObject var perms = Permissions()

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return v.isEmpty ? "—" : v
    }


    var body: some View {
        SettingsPage(.general) {
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
                        ChoicePopup(label: T("settings.general.language"),
                                    choices: [("auto", T("settings.general.language.system")), ("en", "English"), ("zh-Hans", "简体中文")],
                                    selection: Binding(get: { m.language }, set: { m.setLanguage($0) }), dividers: [1])
                    }
                }
            }

            SettingsGroup("general.recording") {
                SettingRow("general.after_recording") {
                    ChoicePopup(label: T("settings.general.after_recording"),
                                choices: [("auto", T("app.menu.after.organize")), ("off", T("app.menu.after.keep"))],
                                selection: Binding(get: { m.processMode }, set: { m.setProcess($0) }))
                }
                SettingRow("general.countdown") {
                    ChoicePopup(label: T("app.menu.countdown"),
                                choices: [(0, T("app.menu.countdown.none")), (3, T("app.menu.countdown.seconds", 3)), (5, T("app.menu.countdown.seconds", 5))],
                                selection: Binding(get: { m.countdown }, set: { m.setCountdown($0) }))
                }
                SettingToggle("general.system_audio", isOn: Binding(get: { m.systemAudio }, set: { m.setSystemAudio($0) }))
            }

            SettingsGroup("general.voice") {
                SettingRow("general.voice_end_on_pause") {
                    ChoicePopup(label: T("settings.general.voice_end_on_pause"),
                                choices: [(false, T("settings.general.voice_end.key")), (true, T("settings.general.voice_end.pause"))],
                                selection: Binding(get: { m.voiceEndOnPause }, set: { m.setVoiceEndOnPause($0) }))
                }
                SettingToggle("general.live_text", isOn: Binding(get: { m.liveText }, set: { m.setLiveText($0) }))
            }

            SettingsGroup("general.cards") {
                SettingToggle("general.collect", isOn: Binding(get: { m.collect }, set: { m.setCollect($0) }))
                // pasting the note in needs Accessibility: said only while that choice is made and it is missing
                let needsAccess = m.cardDrag == .paste && perms.accessibility != .granted
                SettingRow("general.card_drag", detail: needsAccess ? T("settings.general.card_drag.needs_ax") : nil,
                           detailColor: needsAccess ? Color.brandAttnInk : nil) {
                    HStack(spacing: 8) {
                        if needsAccess {
                            Button(T("settings.kit.allow")) { PermissionGuide.shared.start(.all, only: [.accessibility], source: .general) }
                                .fixedSize()
                        }
                        ChoicePopup(label: T("settings.general.card_drag"),
                                    choices: CardDragMode.allCases.map { ($0, T("settings.general.card_drag.\($0.rawValue)")) },
                                    selection: Binding(get: { m.cardDrag }, set: { m.setCardDrag($0) }))
                    }
                }
                SettingToggle("general.drag_note_file", isOn: Binding(get: { m.dragNoteFile }, set: { m.setDragNoteFile($0) }))
            }

            SettingsGroup("general.about", boxed: false) { aboutLine }
        }
        .onAppear { m.reload(); perms.start() }
        .onDisappear { perms.stop() }
    }

    /// About, as one quiet line at the text column: the version, then the rarely needed ways on as quiet text buttons
    /// (secondary ink, underlined under the pointer) — one line of facts, not a row of brand links.
    @ViewBuilder var aboutLine: some View {
        // the skill and the app don't speak the same contract: said here for as long as it lasts
        let mismatch = SkillContract.check(skill: SkillContract.skillVersion())
        VStack(alignment: .leading, spacing: 6) {
            if let mm = mismatch {
                HStack(spacing: 8) {
                    Text(T(mm.appIsOlder ? "app.contract.app_older" : "app.contract.skill_older")).foregroundStyle(Color.brandAttnInk)
                        .fixedSize(horizontal: false, vertical: true)
                    InkLink(T("app.contract.how")) { Housekeeping.contractHelp() }
                }
            }
            HStack(spacing: 6) {
                Text(T("settings.general.about.version", Self.version)).foregroundStyle(.secondary).textSelection(.enabled)
                    .gridProbe(.head, "about")
                if mismatch == nil && Updater.shared.available {
                    dot
                    InkLink(T("app.menu.updates")) { Updater.shared.checkForUpdates(nil) }.disabled(!Updater.shared.canCheck)
                }
                dot
                QuietLink(T("settings.general.help")) { NSWorkspace.shared.open(Help.guideURL()) }
                dot
                QuietLink(T("settings.general.assistant.link")) { Onboarding.shared.show() }
            }
        }
        .font(.system(size: SettingsMetrics.detailSize))
        .padding(.horizontal, SettingsMetrics.boxInset)
    }

    private var dot: some View { Text("·").foregroundStyle(.secondary).accessibilityHidden(true) }
}

/// A text button in the About line: secondary ink like the facts beside it, underlined under the pointer.
struct QuietLink: View {
    var title: String
    var action: () -> Void
    @State private var hover = false
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) { Text(title).underline(hover).foregroundStyle(hover ? .primary : .secondary) }
            .buttonStyle(.plain)
            .onHover { inside in
                hover = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}
