// Settings → Cards (v1.0.23: its own pane, named as the capability is everywhere; before, the Voice notes and Cards
// boxes of General). Three boxes, in the order a card is made and used:
//   Snaps           macOS's own screenshots as cards too (record.collect_system_shots), the shutter sound
//                   (record.snap_sound, off).
//   Voice notes     how one ends — one choice, press the key again or a 1.5 s pause (record.voice.end_on_pause, off:
//                   Capture/VoiceInput.swift). The words under the notch while you talk are dictation's too: General.
//   Dragging cards  what a card dragged into an app carries — one choice over three settings: "picture, then the note"
//                   (record.smart_paste, on: Capture/SmartPaste.swift), "picture with the note under it"
//                   (record.drag_caption), "picture only"; with either of the first two, a note that couldn't go in
//                   goes on the clipboard (record.drag_copy_note, on), with picture only it doesn't —; into an agent
//                   (Codex, Claude Code, WorkBuddy, Cursor…: BlurtCore AgentWindow) the picture's path and the note, as
//                   in a terminal (record.agent_drag "paths", the default), or as the choice above ("same"), with the
//                   list of those apps behind Agents…; the note as a .md file too (record.drag_note_file, off).
//                   Pasting the note needs Accessibility: said in attention ink with Allow… only while that choice is
//                   made and the permission is missing. Then History: how long cards dragged or pasted into other
//                   apps stay on the Cards page — 7 days (the default, left out of the config), 30 days, Forever
//                   (record.cards.history_days: 7 / 30 / -1; BlurtCore TakenCaptures). A shorter choice moves what is
//                   past it to the Trash at once (Snapper.expireTaken), as dictation's history does.
// Where new snaps and voice notes are filed is with the projects (Settings → Projects), which belong to Recording &
// Items. The pane is there only while the Cards capability is on (SettingsCatalog.paneShown); links to these rows'
// old ids in General land here (SettingsCatalog.movedRows).
import AppKit
import SwiftUI
import BlurtCore

/// What a card dragged into another app carries (the Dragging cards box's one choice).
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
final class CardsModel: ObservableObject {
    @Published var collect = false
    @Published var snapSound = false
    @Published var voiceEndOnPause = false
    @Published var cardDrag = CardDragMode.paste
    @Published var agentPaths = true
    @Published var dragNoteFile = false
    @Published var historyDays = TakenCaptures.defaultDays

    init() { reload() }

    func reload() {
        collect = snapper.collecting
        snapSound = recordConfig()["snap_sound"] as? Bool ?? false
        voiceEndOnPause = VoiceInput.endOnPause
        cardDrag = CardDragMode.current
        agentPaths = AgentProbe.getsPaths
        dragNoteFile = CardExport.attachNoteFile
        historyDays = Snapper.historyDays
    }

    func setCollect(_ v: Bool) {
        setRecordConfig("collect_system_shots", v)
        snapper.syncCollector()
        collect = snapper.collecting
    }
    func setSnapSound(_ v: Bool) { setRecordConfig("snap_sound", v ? true : nil); snapSound = v }
    func setVoiceEndOnPause(_ v: Bool) { VoiceInput.setEndOnPause(v); voiceEndOnPause = v }
    func setCardDrag(_ v: CardDragMode) { v.apply(); cardDrag = CardDragMode.current }
    func setAgentPaths(_ v: Bool) {
        setRecordConfig("agent_drag", v ? nil : "same")
        agentPaths = v
        emit(["event": "agent_drag_mode", "mode": v ? "paths" : "same"])
    }
    func setDragNoteFile(_ v: Bool) { setRecordConfig("drag_note_file", v ? true : nil); dragNoteFile = v }
    func setHistoryDays(_ d: Int) {
        historyDays = d
        setRecordConfig("cards.history_days", TakenCaptures.configValue(d))
        emit(["event": "cards_history_days", "days": d])
        // what is past the new days goes now; the page (and its "Kept for …") reads them again either way
        if snapper.expireTaken() == 0 {
            NotificationCenter.default.post(name: .blurtTakenChanged, object: nil, userInfo: ["count": snapper.recentlyTaken.count])
        }
    }

    /// "7 days", "30 days", "Forever".
    static func historyTitle(_ d: Int) -> String {
        d < 0 ? T("settings.cards.history.forever") : T("settings.cards.history.days", d)
    }
}

struct CardsPane: View {
    @StateObject var m = CardsModel()
    @StateObject var perms = Permissions()

    var body: some View {
        SettingsPage(.cards) {
            SettingsGroup("cards.snaps") {
                SettingToggle("cards.collect", isOn: Binding(get: { m.collect }, set: { m.setCollect($0) }))
                SettingToggle("cards.snap_sound", isOn: Binding(get: { m.snapSound }, set: { m.setSnapSound($0) }))
            }

            SettingsGroup("cards.voice") {
                SettingRow("cards.voice_end_on_pause") {
                    ChoicePopup(label: T("settings.general.voice_end_on_pause"),
                                choices: [(false, T("settings.general.voice_end.key")), (true, T("settings.general.voice_end.pause"))],
                                selection: Binding(get: { m.voiceEndOnPause }, set: { m.setVoiceEndOnPause($0) }))
                }
            }

            SettingsGroup("cards.drag") {
                // pasting the note in needs Accessibility: said only while that choice is made and it is missing
                let needsAccess = m.cardDrag == .paste && perms.accessibility != .granted
                SettingRow("cards.card_drag", detail: needsAccess ? T("settings.general.card_drag.needs_ax") : nil,
                           detailColor: needsAccess ? Color.brandAttnInk : nil) {
                    HStack(spacing: 8) {
                        if needsAccess {
                            Button(T("settings.kit.allow")) { PermissionGuide.shared.start(.all, only: [.accessibility], source: .general) }
                                .buttonStyle(SettingsOutlinedButtonStyle())
                                .fixedSize()
                        }
                        ChoicePopup(label: T("settings.general.card_drag"),
                                    choices: CardDragMode.allCases.map { ($0, T("settings.general.card_drag.\($0.rawValue)")) },
                                    selection: Binding(get: { m.cardDrag }, set: { m.setCardDrag($0) }))
                    }
                }
                // which apps are agents: Settings → Agents → Dragging Cards (one list with the agents, v1.0.26)
                SettingRow("cards.agent_drag") {
                    ChoicePopup(label: T("settings.general.agent_drag"),
                                choices: [(true, T("settings.general.agent_drag.paths")), (false, T("settings.general.agent_drag.same"))],
                                selection: Binding(get: { m.agentPaths }, set: { m.setAgentPaths($0) }))
                }
                SettingToggle("cards.drag_note_file", isOn: Binding(get: { m.dragNoteFile }, set: { m.setDragNoteFile($0) }))
                SettingRow("cards.history") {
                    ChoicePopup(label: T("settings.cards.history"),
                                choices: TakenCaptures.choices.map { ($0, CardsModel.historyTitle($0)) },
                                selection: Binding(get: { m.historyDays }, set: { m.setHistoryDays($0) }))
                }
            }
        }
        .onAppear { m.reload(); perms.start() }
        .onDisappear { perms.stop() }
    }
}
