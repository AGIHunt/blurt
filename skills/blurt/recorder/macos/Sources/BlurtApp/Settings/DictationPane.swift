// Settings → Dictation (docs/design/dictation.md), modelled on System Settings → Keyboard → Dictation: a short page of
// rows (SettingsKit; titles and descriptions from SettingsCatalog), one control each, the popups in one 180 pt column.
//   (notice)    only while dictation can't work: a permission missing (Allow…, the guide), the key not heard (Turn
//               On…), macOS's own "Press Globe key to" also reacting to Fn (Fix…), another Blurt holding the key
//   Dictation   on / off (the master: everything under it dims when off; the listener and when the key was last heard
//               in another app are its tooltip) · Shortcut: the key, with Fn's "Use Fn only for dictation" in its
//               menu · Start and stop: tap or hold / tap / hold (Esc and the voice note in its tooltip) · Double-tap to
//               send · Microphone: Automatic / this Mac's / the default input · the start sound
//   Text        Style: Verbatim (no polish) / Light / Structured / Auto (DictationStyleChoice: the polish key and the
//               styles' default) · By kind of app: per category, apps set on their own, list suggestions, learning
//               and the polish time limit folded under it (unfolded when a search lands in it) · Names and terms:
//               Manage… (the Dictation page's Words tab), with reading the context and learning in its menu ·
//               History: Open History…, with how long it is kept, the audio and Clear History… in its menu · Models:
//               the names in use with Change in Speech… (Settings → Speech chooses them, DictationModels.swift), or
//               what is missing with one Download for all of it, or the download's progress with Show
//   Advanced    folded at the foot (open while it is on): Show the Dictation Lab (record.dictation.lab), for developers
// Everything is record.dictation.* in config.json; Dictation.shared.apply() picks changes up at once.
// Strings: Resources/*.lproj/Dictation.strings (T("dictation.…")).
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class DictationSettings: ObservableObject {
    @Published var enabled = Dictation.enabled
    @Published var key = Dictation.key
    @Published var mode = Dictation.mode
    @Published var doubleTap = Dictation.doubleTapSend
    @Published var timeout = Dictation.polishTimeout
    @Published var retention = Dictation.retentionDays
    @Published var keepAudio = Dictation.keepAudio
    @Published var inputMonitoring = DictationKeys.inputMonitoring
    @Published var accessibility = DictationKeys.accessibility
    @Published var tap = Dictation.shared.tapInstalled
    @Published var listener = Dictation.shared.listenerKind
    @Published var lastOther = Dictation.shared.lastKeyFromOtherApp
    @Published var mic = SystemAccess.state(.microphone)
    @Published var fnCapture = Dictation.fnCapture
    @Published var fnFiltering = Dictation.shared.fnFiltering
    @Published var fnUsage: FnUsage? = SystemAccess.fnUsage
    @Published var fnApps: [String] = SystemAccess.fnClashApps
    @Published var historyCount = 0
    @Published var contextOn = Dictation.contextOn
    @Published var learnOn = Dictation.learnOn
    /// the Words summary: the user's own words, suggestions waiting
    @Published var wordCounts = (mine: 0, suggested: 0)
    private var timer: Timer?

    func start() {
        Dictation.shared.seedVocabulary()
        refresh()
        emit(["event": "dictation_pane", "tap": tap])
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        Task { await DictationModels.shared.load() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        let im = DictationKeys.inputMonitoring, ax = DictationKeys.accessibility, t = Dictation.shared.tapInstalled
        if im != inputMonitoring { inputMonitoring = im }
        if ax != accessibility { accessibility = ax }
        let l = Dictation.shared.listenerKind, o = Dictation.shared.lastKeyFromOtherApp
        if l != listener { listener = l; emit(["event": "dictation_pane", "listener": l.rawValue]) }
        if o != lastOther { lastOther = o }
        let mc = SystemAccess.state(.microphone), ff = Dictation.shared.fnFiltering, fu = SystemAccess.fnUsage, fa = SystemAccess.fnClashApps
        if mc != mic { mic = mc }
        if ff != fnFiltering { fnFiltering = ff }
        if fu != fnUsage { fnUsage = fu; emit(["event": "dictation_pane", "fn_usage": fu?.rawValue ?? NSNull()]) }
        if fa != fnApps { fnApps = fa }
        if t != tap {
            tap = t
            emit(["event": "dictation_pane", "tap": t])
        }
        let n = DictationHistory.shared.load().count
        if n != historyCount { historyCount = n }
        let st = Dictation.styleConfig          // a learned suggestion accepted on the island shows up here
        if st != styles { styles = st }
        let s = DictationStyleChoice.current(polishOff: !Dictation.polishOn, config: st)
        if s != style { style = s }
        let all = DictationVocabulary.shared.load()
        let wc = (mine: all.filter { $0.state == .active && $0.source != .builtIn }.count,
                  suggested: all.filter { $0.state == .suggested }.count)
        if wc != wordCounts { wordCounts = wc }
    }

    // MARK: words, microphone

    func setContext(_ v: Bool) { contextOn = v; save("context", v ? nil : false) }
    func setLearn(_ v: Bool) { learnOn = v; save("learn", v ? nil : false) }
    /// nil = Automatic (the Mac's own mic when the default input is Bluetooth), true = always the Mac's, false = always
    /// the default input (DictationMicChoice)
    @Published var micChoice = Dictation.builtInMicSetting
    @Published var startSound = Dictation.startSound
    func setMic(_ v: Bool?) {
        micChoice = v
        save("builtin_mic", v)
        MicEngine.shared.prepare(builtIn: Dictation.useBuiltInMic)
    }
    func setStartSound(_ v: Bool) { startSound = v; save("start_sound", v ? true : nil) }

    private func save(_ key: String, _ value: Any?) {
        Dictation.set(key, value)
        Dictation.shared.apply()
        emit(["event": "dictation_setting", "key": key, "value": value.map { "\($0)" } ?? "default"])
    }

    func setEnabled(_ v: Bool) { enabled = v; save("enabled", v ? nil : false) }
    // stored even when it is the default: a later default (≤ 0.8: right ⌥, tap) never moves a choice the user made
    func setKey(_ v: DictationTrigger.Key) { key = v; save("key", v.rawValue); refresh() }
    func setMode(_ v: DictationTrigger.Mode) { mode = v; save("mode", v.rawValue) }
    func setDoubleTap(_ v: Bool) { doubleTap = v; save("double_tap_send", v ? nil : false) }
    func setFnCapture(_ v: Bool) { fnCapture = v; save("fn_capture", v ? nil : false); refresh() }
    func setTimeout(_ s: Double) { timeout = s; save("polish_timeout_ms", Int(s * 1000) == 3000 ? nil : Int(s * 1000)) }
    func setRetention(_ d: Int) {
        retention = d
        save("retention_days", d == 30 ? nil : d)
        DispatchQueue.global(qos: .utility).async { DictationHistory.shared.prune(days: d) }
    }
    func setKeepAudio(_ v: Bool) { keepAudio = v; save("keep_audio", v ? true : nil) }

    // MARK: style (dictation-styles.md)

    @Published var styles = Dictation.styleConfig
    @Published var style = DictationStyleChoice.current(polishOff: !Dictation.polishOn, config: Dictation.styleConfig)
    @Published var suggestLists = Dictation.suggestLists
    @Published var learnStyles = Dictation.learnStyles

    /// The one Style choice: Verbatim turns polish off; the others turn it on with that style as the default.
    func setStyle(_ s: DictationStyle) {
        let r = DictationStyleChoice.apply(s, to: Dictation.styleConfig)
        Dictation.setStyleConfig(r.config)
        styles = r.config
        style = s
        save("polish", r.polish)
        emit(["event": "dictation_setting", "key": "style", "value": s.rawValue])
    }
    /// a category's style; nil = the default above
    func setStyle(_ s: DictationStyle?, for c: DictationAppCategory) {
        var cfg = Dictation.styleConfig
        cfg.categories[c] = s
        Dictation.setStyleConfig(cfg)
        styles = cfg
        emit(["event": "dictation_setting", "key": "styles.\(c.rawValue)", "value": s?.rawValue ?? "default"])
    }
    /// an app set on its own (by a learned suggestion) back to its category's style
    func resetApp(_ bundle: String) {
        var cfg = Dictation.styleConfig
        cfg.apps[bundle] = nil
        cfg.learned.remove(bundle)
        Dictation.setStyleConfig(cfg)
        styles = cfg
        emit(["event": "dictation_setting", "key": "styles.apps", "value": "reset \(bundle)"])
    }
    func setSuggestLists(_ v: Bool) { suggestLists = v; save("suggest_lists", v ? nil : false) }
    func setLearnStyles(_ v: Bool) { learnStyles = v; save("learn_styles", v ? nil : false) }
    /// an app's name from its bundle id (AppNames: the running or installed app's; else "Unknown app", never the id)
    func appName(_ bundle: String) -> String { AppNames.displayOrUnknown(name: nil, bundle: bundle) }

    func clearHistory() {
        DictationHistory.shared.clear()
        DictationHistoryWindow.shared.reloadIfOpen()
        refresh()
    }
}

struct DictationPane: View {
    /// tests: `dictation settings-scroll style|models|words|history|mic` (a screenshot of a row further down)
    static let scrollRequest = Notification.Name("BlurtDictationPaneScroll")
    @StateObject var m = DictationSettings()
    @StateObject var perms = Permissions()
    @ObservedObject var models = DictationModels.shared
    @ObservedObject var guide = PermissionGuide.shared
    @State var confirmClear = false
    @State var showByApp = false
    /// Advanced (the Dictation Lab): folded unless the Lab is on
    @State var showAdvanced = DictationLabModel.enabled
    @State var lab = DictationLabModel.enabled

    private let nav = SettingsNavigator.shared       // not observed: the pane needn't redraw as the search is typed

    var body: some View {
        SettingsPage(.dictation) {
            if guide.finished != nil { PermissionDoneBanner().padding(.top, 12) }   // the permission guide just finished
            notice
            SettingsGroup("dictation.main") { mainRows }
            SettingsGroup("dictation.text") { textRows }

            // for developers: folded away at the page's foot
            SettingsGroup("dictation.advanced", disclosure: $showAdvanced) {
                SettingToggle("dictation.lab", isOn: Binding(get: { lab }, set: { v in
                    lab = v
                    Config.shared.set("record.dictation.lab", v ? true : nil)
                }))
            }
        }
        // tests: `dictation settings-scroll style|models|words|history|mic`
        .onReceive(NotificationCenter.default.publisher(for: DictationPane.scrollRequest)) { n in
            guard let id = n.object as? String else { return }
            if id == "style" { showByApp = true }
            let rows = ["style": "dictation.text", "words": "dictation.word_list", "history": "dictation.history_saved"]
            nav.reveal(rows[id] ?? "dictation.\(id)")
        }
        // a search or a link landing on a row that is folded away: unfold it first
        .onReceive(SettingsFlash.shared.$request) { r in
            guard let id = r?.id else { return }
            if id == "dictation.by_app" || SettingsCatalog.entry(id)?.fold == "dictation.by_app" { showByApp = true }
            if id == "dictation.lab" || id == "dictation.advanced" { showAdvanced = true }
        }
        .onAppear { m.start(); perms.start() }
        .onDisappear { m.stop(); perms.stop() }
        .alert(T("dictation.history.clear.title"), isPresented: $confirmClear) {
            Button(T("dictation.history.clear.confirm"), role: .destructive) { m.clearHistory() }
            Button(T("dictation.cancel"), role: .cancel) {}
        } message: { Text(T("dictation.history.clear.message", m.historyCount)) }
    }

    // MARK: how dictating works

    @ViewBuilder var mainRows: some View {
        SettingToggle("dictation.enable", isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) }), help: m.enabled ? listenerLine : nil)
        Group {
            SettingRow("dictation.key", detail: keyDetail?.text, help: keyDetail?.help, detailColor: keyDetail?.warn == true ? .brandAttnInk : nil,
                       hosts: ["dictation.fn_capture"]) {
                ChoicePopup(label: T("dictation.settings.key"),
                            choices: DictationTrigger.Key.allCases.map { ($0, Dictation.keyName($0)) },     // Fn first
                            selection: Binding(get: { m.key }, set: { m.setKey($0) }),
                            checks: m.key == .fn ? [SettingMenuToggle("dictation.fn_capture", isOn: Binding(get: { m.fnCapture }, set: { m.setFnCapture($0) }))] : [])
            }
            SettingRow("dictation.mode", detail: T("dictation.mode.\(m.mode.rawValue).detail", Dictation.keyInline(m.key)),
                       help: T("dictation.mode.help", hk(.voice).isEmpty ? T("dictation.settings.voice_note_off") : hk(.voice))) {
                ChoicePopup(label: T("dictation.settings.mode"), choices: DictationTrigger.Mode.allCases.map { ($0, T("dictation.mode.\($0.rawValue)")) },
                            selection: Binding(get: { m.mode }, set: { m.setMode($0) }))
            }
            SettingToggle("dictation.double_tap", isOn: Binding(get: { m.doubleTap }, set: { m.setDoubleTap($0) }),
                          detail: T("dictation.settings.double_tap.key", Dictation.keyShort(m.key)), help: T("dictation.settings.double_tap.help"))
            SettingRow("dictation.mic") {
                ChoicePopup(label: T("dictation.mic.section"),
                            choices: [(nil, T("dictation.mic.auto")), (true, T("dictation.mic.mac")), (false, T("dictation.mic.default"))],
                            selection: Binding(get: { m.micChoice }, set: { m.setMic($0) }))
            }
            SettingToggle("dictation.start_sound", isOn: Binding(get: { m.startSound }, set: { m.setStartSound($0) }))
        }
        .disabled(!m.enabled)
    }

    /// The key's one line, only when there is something to say: another Fn dictation app running (attention), or
    /// how "either ⌥" counts a tap.
    var keyDetail: (text: String, help: String?, warn: Bool)? {
        if m.key == .fn, !m.fnApps.isEmpty {
            return (T("dictation.settings.fn_clash", m.fnApps.joined(separator: T("settings.perm.list_sep"))), T("dictation.settings.fn_clash.help"), true)
        }
        if m.key == .eitherOption { return (T("dictation.settings.either_hint"), nil, false) }
        return nil
    }

    /// Which listener runs, and the one thing only the user can prove: the key heard while another app is in front.
    var listenerLine: String {
        let l = T("dictation.listener.\(m.fnFiltering && m.listener == .tap ? "filter" : m.listener.rawValue)")
        let h = m.lastOther.map { T("dictation.heard.other", heardTime($0)) } ?? T("dictation.heard.never", Dictation.keyInline(m.key))
        let restart = m.inputMonitoring && m.listener != .tap ? [T("dictation.perm.restart_hint")] : []
        return ([l, h] + restart).joined(separator: Loc.isChinese ? "" : " ")
    }

    // MARK: the notice: only while dictation can't work

    /// One line at the top for the one thing in the way, most basic first; nothing while dictation is off or works.
    @ViewBuilder var notice: some View {
        if m.enabled {
            let missing = guide.missing(.dictation).filter { $0 != .fnKey }
            let _ = perms.accessibility                 // re-evaluated as the states change (once a second)
            Group {
                if !m.tap, let pid = Dictation.shared.deferredTo {
                    // another Blurt has the key: nothing to set up here (this one takes over when that one quits)
                    SettingsNotice(title: T("dictation.status.other_instance", "\(pid)"), detail: T("dictation.status.other_instance.detail"),
                                   tone: .off) { EmptyView() }
                } else if !missing.isEmpty {
                    SettingsNotice(title: T("dictation.notice.needs", missing.map(PermissionGuide.name).joined(separator: T("settings.perm.list_sep"))),
                                   detail: missing.count == 1 ? PermissionGuide.why(missing[0]) : nil) {
                        Button(guide.running ? T("settings.perm.setup_running") : T("settings.kit.allow")) {
                            guide.start(.dictation, source: .dictation)
                        }
                    }
                } else if !m.tap {
                    SettingsNotice(title: T("dictation.status.off", Dictation.keyInline(m.key)), detail: T("dictation.status.off.detail")) {
                        Button(T("dictation.status.fix")) { Dictation.shared.openSetup(from: "dictation") }
                    }
                } else if m.key == .fn, FnUsage.clashes(m.fnUsage) {
                    // macOS's own "Press Globe key to" (read live; Fix… walks the user there with the helper panel,
                    // Blurt never changes it)
                    SettingsNotice(title: T("dictation.fn.usage", T("dictation.fn_usage.\(m.fnUsage.map { "\($0.rawValue)" } ?? "default")")),
                                   detail: T("dictation.fn.usage.clash")) {
                        Button(T("dictation.fn.usage.fix")) { PermissionGuide.shared.start(.dictation, only: [.fnKey], source: .dictation) }
                    }
                }
            }
            .padding(.top, 18)
        }
    }

    // MARK: what comes out: style, words, history, models

    @ViewBuilder var textRows: some View {
        SettingRow("dictation.default_style", detail: T("dictation.style.\(m.style.rawValue).detail")) {
            ChoicePopup(label: T("dictation.style.default"), choices: [DictationStyle.verbatim, .light, .structured, .auto].map { ($0, Dictation.styleName($0)) },
                        selection: Binding(get: { m.style }, set: { m.setStyle($0) }))
        }
        .disabled(!m.enabled)
        if m.style != .verbatim {
            SettingRow("dictation.by_app", detail: byAppSummary) {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showByApp ? 90 : 0))
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showByApp.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(showByApp ? "1" : "0")
            .accessibilityAction { showByApp.toggle() }
            .disabled(!m.enabled)
            if showByApp {
                VStack(alignment: .leading, spacing: 0) { byApp }
                    .padding(.leading, 20)
                    .disabled(!m.enabled)
            }
        }
        wordsRow
        historyRow
        modelsRow
    }

    /// What is set per kind of app ("Code and terminals: Verbatim · 2 apps on their own"); else what the row is for.
    var byAppSummary: String? {
        var parts = DictationAppCategory.allCases.compactMap { c in
            m.styles.categories[c].map { T("dictation.style.by_app.pair", T("dictation.style.cat.\(c.rawValue)"), Dictation.styleName($0)) }
        }
        if !m.styles.apps.isEmpty { parts.append(T("dictation.style.by_app.apps", m.styles.apps.count)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder var byApp: some View {
        ForEach(DictationAppCategory.allCases, id: \.self) { c in
            SettingRow("dictation.cat.\(c.rawValue)") {
                ChoicePopup(label: T("dictation.style.cat.\(c.rawValue)"),
                            choices: [(DictationStyle?.none, T("dictation.style.follow", Dictation.styleName(m.style)))]
                                + DictationStyle.allCases.map { (Optional($0), Dictation.styleName($0)) },
                            selection: Binding(get: { m.styles.categories[c] }, set: { m.setStyle($0, for: c) }))
            }
        }
        if !m.styles.apps.isEmpty {
            SettingsLine(padding: 8) { Hint(T("dictation.style.apps")) }
            ForEach(m.styles.apps.keys.sorted(), id: \.self) { b in
                SettingsLine(padding: 8) {
                    HStack(spacing: 8) {
                        Text(m.appName(b)).font(.system(size: SettingsMetrics.titleSize))
                        if m.styles.learned.contains(b) { Badge(T("dictation.style.learned")) }
                        Spacer()
                        Text(Dictation.styleName(m.styles.apps[b] ?? .light)).foregroundStyle(.secondary)
                        Button(T("dictation.style.reset")) { m.resetApp(b) }.controlSize(.small).help(T("dictation.style.reset.help"))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        SettingToggle("dictation.suggest_lists", isOn: Binding(get: { m.suggestLists }, set: { m.setSuggestLists($0) }))
        SettingToggle("dictation.learn_styles", isOn: Binding(get: { m.learnStyles }, set: { m.setLearnStyles($0) }))
        SettingRow("dictation.polish_timeout",
                   detail: hk(.reformat).isEmpty ? T("dictation.style.keys.no_hotkey") : T("dictation.style.keys", hk(.reformat))) {
            HStack(spacing: 6) {
                Text(T("dictation.polish.seconds", seconds(m.timeout))).foregroundStyle(.secondary).monospacedDigit()
                Stepper(T("dictation.polish.timeout"), value: Binding(get: { m.timeout }, set: { m.setTimeout($0) }), in: 1...10, step: 0.5)
                    .labelsHidden()
            }
        }
    }

    /// "13 of your own · 1 to review" (the count that needs you in attention ink), Manage… with the two learning
    /// switches in its menu: set once, rarely touched.
    var wordsRow: some View {
        var summary = Text(T("dictation.vocab.summary.mine", m.wordCounts.mine))
        if m.wordCounts.suggested > 0 {
            summary = summary + Text(" · ") + Text(T("dictation.vocab.summary.suggested", m.wordCounts.suggested)).foregroundColor(.brandAttnInk)
        }
        return SettingRow("dictation.word_list", richDetail: summary, hosts: ["dictation.context", "dictation.learn"]) {
            Menu {
                SettingMenuToggle("dictation.context", isOn: Binding(get: { m.contextOn }, set: { m.setContext($0) }))
                SettingMenuToggle("dictation.learn", isOn: Binding(get: { m.learnOn }, set: { m.setLearn($0) }))
            } label: {
                Text(T("dictation.vocab.manage"))
            } primaryAction: { DictationHistoryWindow.shared.showWords() }
            .fixedSize()
        }
    }

    /// "9 saved · deleted after 30 days", Open History… — how long, the audio and the destructive Clear History… are
    /// in its menu, never a button at rest.
    var historyRow: some View {
        SettingRow("dictation.history_saved", detail: T("dictation.history.summary", m.historyCount, T("dictation.history.days", m.retention)),
                   hosts: ["dictation.history_keep", "dictation.keep_audio"]) {
            Menu {
                SettingMenuPicker("dictation.history_keep", selection: Binding(get: { m.retention }, set: { m.setRetention($0) })) {
                    ForEach([7, 30, 90, 365], id: \.self) { d in Text(T("dictation.history.days", d)).tag(d) }
                }
                SettingMenuToggle("dictation.keep_audio", isOn: Binding(get: { m.keepAudio }, set: { m.setKeepAudio($0) }))
                Divider()
                Button(T("dictation.history.clear"), role: .destructive) { confirmClear = true }
                    .disabled(m.historyCount == 0)
            } label: {
                Text(T("dictation.history.open"))
            } primaryAction: { DictationHistoryWindow.shared.show() }
            .fixedSize()
        }
    }

    // MARK: models (chosen in Settings → Speech)

    /// One row for both models: their names and Change in Speech… once in; "Not on this Mac yet · 2.4 GB" with one
    /// Download for all that's missing; while the download manager has one (running or waiting its turn), its line
    /// with Show — never "not downloaded" beside a running download.
    var modelsRow: some View {
        let s = modelsState
        let detail: String? = {
            switch s {
            case .loading: return nil
            case .coming(let j): return downloadLine(j)
            case .missing(let jobs): return T("dictation.models.missing", modelSize(jobs.reduce(0) { $0 + $1.sizeMB }))
            case .ready: return modelNames
            }
        }()
        var missing = false
        if case .missing = s { missing = true }
        return SettingRow("dictation.models", detail: detail, detailColor: missing ? .brandAttnInk : nil) {
            switch s {
            case .loading: BrandSpinnerView()
            case .coming: Button(T("dictation.models.show")) { ModelDownloads.showProgress() }
            case .missing: Button(T("dictation.models.download")) { models.downloadMissing(polish: m.style != .verbatim) }
            case .ready: TextLinkButton(T("dictation.models.change")) { SpeechPane.showDictationModels() }
            }
        }
    }

    enum ModelsState { case loading, coming(ModelDownloadQueue.Job), missing([ModelDownloadQueue.Job]), ready }

    var modelsState: ModelsState {
        let dl = ModelDownloads.shared
        let polish = m.style != .verbatim
        if models.asr == nil && models.polish == nil { return .loading }
        let asrJob = models.dictationJob.flatMap { j in dl.queue.contains(j.id) ? j : nil }
            ?? dl.queue.pending.first { j in j.kind == .dictation && models.asr?.models.contains { $0.id == j.id } == true }
        if let j = asrJob ?? (polish ? dl.queue.pending.first { j in j.kind == .polish } : nil) { return .coming(j) }
        let missing = models.missingJobs(polish: polish)
        return missing.isEmpty ? .ready : .missing(missing)
    }

    /// "Qwen3-ASR 1.7B · Gemma 4 E2B": the recogniser in use, and the polish model while a style polishes.
    var modelNames: String? {
        var names: [String] = []
        if let a = models.selectedASR { names.append(a.name ?? models.asrName(a.id)) }
        if m.style != .verbatim, let p = models.selectedPolish, p.installed { names.append(p.name) }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    /// "Downloading · 1.2 GB of 2.5 GB" while it runs, "Waiting to download · 3.4 GB" while it waits its turn.
    func downloadLine(_ j: ModelDownloadQueue.Job) -> String {
        guard let p = models.progress(j.id) else { return T("dictation.models.queued", modelSize(j.sizeMB)) }
        return T("dictation.models.downloading", modelSize(p.done), modelSize(max(p.total, j.sizeMB)))
    }

    // MARK: formatting

    private func heardTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Loc.locale
        f.dateStyle = Calendar.current.isDateInToday(d) ? .none : .short
        f.timeStyle = .medium
        return f.string(from: d)
    }

    private func seconds(_ s: Double) -> String {
        let f = NumberFormatter()
        f.locale = Loc.locale
        f.maximumFractionDigits = 1
        return f.string(from: s as NSNumber) ?? "\(s)"
    }
}

/// A small capsule label next to a name ("Recommended", "Learned"): brand ink on the brand tint (§3.4); with a `tint`,
/// that colour as text on 15 % of itself.
struct Badge: View {
    let text: String
    var tint: Color?
    init(_ text: String, tint: Color? = nil) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(tint.map { $0.opacity(0.15) } ?? Color.brandTint))
            .foregroundStyle(tint ?? Color.brandInk)
    }
}
