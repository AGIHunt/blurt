// Settings → General: what every feature shares, on one short page — two boxes and a closing line.
//   Features     the five things Blurt does (BlurtCore Capabilities.swift), each with its switch: its glyph and name as
//                in the main window's sidebar, one line on what it does (Home.strings). Off means gone — its
//                shortcuts are given back, and it is not in the menus, the main window or Settings (its pane leaves
//                the sidebar at once; the footnote says so). The switch stays here, so it is one click from back.
//                Dictation's is the same switch as Settings → Dictation's own (SettingsFeatures.set). A link to
//                something of an off capability lands on its row here (SettingsCatalog.landing).
//   App          open at login (LoginItem: the assistant's switch too, so a test build never registers itself), the
//                menu-bar icon, the notch at rest, the words under the notch while you speak (record.live_text, on:
//                Capture/LiveTranscript.swift — dictation's and the voice note's alike, so it is the app's; not shown
//                with both off), language (the running app keeps the one it opened with: Relaunch Now next to it).
//   About        one quiet line under the boxes: Blurt and its version, Check for Updates…, User Guide, Setup
//                Assistant… as brand-ink text buttons; a skill / app contract mismatch is said above it in attention
//                ink, with How to Update, for as long as it lasts.
// Each capability's own settings are on its pane (v1.0.23: before, Recording, Voice notes and Cards were boxes here —
// CardsPane.swift, RecordingPane.swift; the projects have ProjectsPane.swift; the Dictation Lab is under Dictation's
// Advanced). Rows and their descriptions come from SettingsCatalog; longer explanations are behind each row's ⓘ.
// Every pop-up is the same width (SettingsMetrics.controlWidth), so the controls share one column.
import AppKit
import Combine
import ServiceManagement
import SwiftUI
import BlurtCore

@MainActor
final class GeneralModel: ObservableObject {
    @Published var openAtLogin = false
    @Published var loginError: String?
    @Published var language = "auto"
    @Published var liveText = true
    @Published var menuBarIcon = true
    @Published var islandIdle = true
    /// the dictation key, as the Dictation switch's line names it ("Press Fn and talk…")
    @Published var dictationKey = ""
    private var keyWatch: AnyCancellable?

    init() {
        reload()
        // the key was changed in Settings → Dictation while this page is kept
        keyWatch = NotificationCenter.default.publisher(for: Dictation.settingsChanged).receive(on: RunLoop.main).sink { [weak self] _ in
            let k = Dictation.keyShort(Dictation.key)
            if self?.dictationKey != k { self?.dictationKey = k }
        }
    }

    func reload() {
        openAtLogin = LoginItem.enabled
        let l = Config.shared["lang"] as? String ?? "auto"
        language = l == "zh" ? "zh-Hans" : (["en", "zh-Hans"].contains(l) ? l : "auto")
        liveText = LiveTranscript.enabled
        menuBarIcon = App.showsMenuBarIcon
        islandIdle = Island.showsAtRest
        dictationKey = Dictation.keyShort(Dictation.key)
        SettingsFeatures.shared.look()
    }

    func setMenuBarIcon(_ v: Bool) { (NSApp.delegate as? App)?.setMenuBarIcon(v); menuBarIcon = v }
    func setIslandIdle(_ v: Bool) { Island.showsAtRest = v; islandIdle = v }

    /// The same switch as the assistant's (LoginItem): a test build never registers itself in the user's Login Items.
    func setLogin(_ on: Bool) {
        loginError = LoginItem.set(on, via: "settings") == nil ? nil : T("settings.general.login_failed")
        openAtLogin = LoginItem.enabled
    }
    func setLanguage(_ v: String) {
        Config.shared.set("lang", v == "auto" ? nil : v)
        language = v
    }
    func setLiveText(_ v: Bool) { LiveTranscript.setEnabled(v); liveText = v }
}

struct GeneralPane: View {
    @StateObject var m = GeneralModel()
    @ObservedObject private var features = SettingsFeatures.shared

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return v.isEmpty ? "—" : v
    }

    var body: some View {
        SettingsPage(.general) {
            SettingsGroup("general.features", footer: T("settings.general.features.footer")) {
                ForEach(Capability.allCases, id: \.self) { c in featureRow(c) }
            }

            SettingsGroup("general.app") {
                SettingToggle("general.login", isOn: Binding(get: { m.openAtLogin }, set: { m.setLogin($0) }),
                              detail: m.loginError)
                SettingToggle("general.menu_bar_icon", isOn: Binding(get: { m.menuBarIcon }, set: { m.setMenuBarIcon($0) }))
                SettingToggle("general.island_idle", isOn: Binding(get: { m.islandIdle }, set: { m.setIslandIdle($0) }))
                // dictation's and the voice note's: with both off there are no words to show
                if SettingsCatalog.rowShown("general.live_text", off: features.off) {
                    SettingToggle("general.live_text", isOn: Binding(get: { m.liveText }, set: { m.setLiveText($0) }))
                }
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

            SettingsGroup("general.about", boxed: false) { aboutLine }
        }
        .onAppear { m.reload() }
    }

    /// A capability and its switch: the glyph and the name it has in the sidebars, what it does in one line (the
    /// dictation one names the key), the switch. The rows are SettingsCatalog's "general.feature.<id>" (one per
    /// Capability case), so a search for "turn off", a capability's name or a link to an off pane lands on them.
    func featureRow(_ c: Capability) -> some View {
        SettingToggle(SettingsCatalog.featureRow(c), isOn: Binding(get: { !features.off.contains(c) }, set: { features.set(c, on: $0) }),
                      detail: c == .dictation ? T("feature.dictation.what", m.dictationKey) : nil,
                      icon: SettingsCatalog.pane(of: c)?.symbol)
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
