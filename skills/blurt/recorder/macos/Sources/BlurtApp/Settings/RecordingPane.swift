// Settings → Recording & Items (v1.0.23: its own pane, named as the capability is everywhere; before, the Recording
// box of General). Two boxes, in the order of a recording:
//   Recording   the countdown before it starts (record.countdown), system audio (record.system_audio), "Don't record
//               the notch" (record.hide_notch: a take running now follows at once).
//   Items       what happens after one (record.process: organised into items by your agent, or the video kept as it
//               is), and, while they are organised, a row that is not a setting but the way to the ones that decide
//               how: which agent, its model and effort (Settings → Agents, at Organize). A link, not a copy: each
//               setting is kept, and found by search, in one place (the QA walkthrough: "a recording's settings are in
//               three places"). Where the items are filed is the next pane in the sidebar, Projects: no row for it.
// The recording's shortcuts are in Shortcuts, its models in Models. The pane is there only while the Recording
// capability is on (SettingsCatalog.paneShown), and so is Projects; links to these rows' old ids in General land here
// (SettingsCatalog.movedRows).
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class RecordingModel: ObservableObject {
    @Published var processMode = "auto"
    @Published var countdown = 3
    @Published var systemAudio = false
    @Published var hideNotch = false

    init() { reload() }

    func reload() {
        processMode = (recordConfig()["process"] as? String ?? "auto") == "off" ? "off" : "auto"
        countdown = recordConfig()["countdown"] as? Int ?? 3
        systemAudio = recordConfig()["system_audio"] as? Bool ?? false
        hideNotch = OwnWindows.hideNotch
    }

    func setProcess(_ v: String) { setRecordConfig("process", v); processMode = v }
    func setCountdown(_ v: Int) { setRecordConfig("countdown", v); countdown = v }
    func setSystemAudio(_ v: Bool) { setRecordConfig("system_audio", v); systemAudio = v }
    /// "Don't record the notch" (record.hide_notch): a take running now follows at once.
    func setHideNotch(_ v: Bool) {
        setRecordConfig(CaptureExclusion.hideNotchKey, v ? true : nil)
        hideNotch = v
        (NSApp.delegate as? App)?.rec?.updateFilter()
    }
}

struct RecordingPane: View {
    @StateObject var m = RecordingModel()

    var body: some View {
        SettingsPage(.recording) {
            SettingsGroup("recording.capture") {
                SettingRow("recording.countdown") {
                    ChoicePopup(label: T("app.menu.countdown"),
                                choices: [(0, T("app.menu.countdown.none")), (3, T("app.menu.countdown.seconds", 3)), (5, T("app.menu.countdown.seconds", 5))],
                                selection: Binding(get: { m.countdown }, set: { m.setCountdown($0) }))
                }
                SettingToggle("recording.system_audio", isOn: Binding(get: { m.systemAudio }, set: { m.setSystemAudio($0) }))
                SettingToggle("recording.hide_notch", isOn: Binding(get: { m.hideNotch }, set: { m.setHideNotch($0) }))
            }

            SettingsGroup("recording.items") {
                SettingRow("recording.after_recording") {
                    ChoicePopup(label: T("settings.general.after_recording"),
                                choices: [("auto", T("app.menu.after.organize")), ("off", T("app.menu.after.keep"))],
                                selection: Binding(get: { m.processMode }, set: { m.setProcess($0) }))
                }
                // kept as a video only: no agent has a part in it
                if m.processMode != "off" {
                    SettingsLinkRow(title: T("settings.recording.agent"), detail: T("settings.recording.agent.detail"),
                                    button: T("settings.recording.agent.open")) {
                        AppEnvironment.settings?.show(pane: "agents/agents.organize")
                    }
                }
            }
        }
        .onAppear { m.reload() }
    }
}

/// A row that leads to a setting kept on another page (which agent organises: Agents), laid out as a setting's row is:
/// what it is and one line on where it is decided on the left, that page's button on the right (outlined, as every
/// row's button). Not a setting itself: it has no catalogue entry, so search finds the real one where it lives.
struct SettingsLinkRow: View {
    var title: String
    var detail: String?
    var button: String
    var action: () -> Void

    var body: some View {
        SettingsLine {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: SettingsMetrics.titleSize)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridProbe(.text, title)
                    if let d = detail, !d.isEmpty {
                        Text(d).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(button, action: action).buttonStyle(SettingsOutlinedButtonStyle()).fixedSize()
                    .gridProbe(.trailing, title)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
