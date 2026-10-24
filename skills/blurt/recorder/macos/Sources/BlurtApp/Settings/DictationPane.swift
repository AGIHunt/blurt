// Settings → Dictation (docs/design/dictation.md): the essentials on one short page —
//   Dictation   on / off, the key (Fn first, right ⌥, either ⌥), how it works (auto / tap / hold: the one how-to line),
//               double tap = Return, with Fn: keeping Fn from macOS and macOS's own "Press Globe key to" setting (only
//               when it clashes), other Fn dictation apps running; a status row only when the key can't be heard
//   Style       one choice: Verbatim (no polish) / Light / Structured / Auto (DictationStyleChoice: the polish key and
//               the styles' default); per kind of app, apps set on their own, list suggestions, learning and the
//               polish time limit folded under "By kind of app"
//   Models      the speech and polish model in use, with Change… / Download… → Settings → Speech, where they are chosen
//               (DictationModels.swift)
//   Words       a one-line summary with Manage… → the Dictation page's Words tab; reading the context and learning
//   History     retention, keeping audio, opening and clearing it
//   Microphone  the Mac's own mic, the start sound
//   Permissions folded to one line when all are allowed (with the listener and when the key was last heard in another
//               app); otherwise the rows with Allow and "Set Up Permissions"
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
    /// the Words summary: the user's own words, the built-in ones, suggestions waiting
    @Published var wordCounts = (mine: 0, builtIn: 0, suggested: 0)
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
                  builtIn: all.filter { $0.state == .active && $0.source == .builtIn }.count,
                  suggested: all.filter { $0.state == .suggested }.count)
        if wc != wordCounts { wordCounts = wc }
    }

    /// Every permission dictation needs is there (the section folds to one line).
    var allAllowed: Bool { accessibility && (inputMonitoring || (key == .fn && fnFiltering)) && mic == .granted }

    // MARK: words, microphone

    func setContext(_ v: Bool) { contextOn = v; save("context", v ? nil : false) }
    func setLearn(_ v: Bool) { learnOn = v; save("learn", v ? nil : false) }
    /// automatic (unset) shows what it does now; flipping it stores the choice
    @Published var builtInMic = Dictation.useBuiltInMic
    @Published var startSound = Dictation.startSound
    func setBuiltInMic(_ v: Bool) {
        builtInMic = v
        save("builtin_mic", v)
        MicEngine.shared.prepare(builtIn: v)
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
    /// an app's name from its bundle id (installed apps only; else the id)
    func appName(_ bundle: String) -> String {
        guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return bundle }
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
    }

    /// A row's Allow: the permission guide for that one (Blurt in the list, the pane, the helper panel).
    func allow(_ k: PermissionKind) { PermissionGuide.shared.start(.dictation, only: [k], source: .dictation) }

    func clearHistory() {
        DictationHistory.shared.clear()
        DictationHistoryWindow.shared.reloadIfOpen()
        refresh()
    }
}

struct DictationPane: View {
    /// tests: `dictation settings-scroll style|models|words|history|permissions` (a screenshot of a lower section)
    static let scrollRequest = Notification.Name("BlurtDictationPaneScroll")
    /// tests: `dictation polish install ID | cancel ID | use ID | state` (DictationModels.testCommand)
    static let polishRequest = Notification.Name("BlurtDictationPanePolish")
    @StateObject var m = DictationSettings()
    @StateObject var perms = Permissions()
    @ObservedObject var models = DictationModels.shared
    @ObservedObject var guide = PermissionGuide.shared
    @State var confirmClear = false
    @State var showPermissions = false
    @State var showByApp = false

    var body: some View {
        ScrollViewReader { proxy in PaneFrame {
            Section {
                PermissionDoneBanner()          // the permission guide just finished: the first thing seen
                Toggle(T("dictation.settings.enable"), isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) }))
                if m.enabled && !m.tap { keyStatus }
                Picker(T("dictation.settings.key"), selection: Binding(get: { m.key }, set: { m.setKey($0) })) {
                    ForEach(DictationTrigger.Key.allCases, id: \.self) { k in Text(Dictation.keyName(k)).tag(k) }    // Fn first
                }
                .disabled(!m.enabled)
                if m.key == .eitherOption { Hint(T("dictation.settings.either_hint")) }
                Picker(T("dictation.settings.mode"), selection: Binding(get: { m.mode }, set: { m.setMode($0) })) {
                    ForEach(DictationTrigger.Mode.allCases, id: \.self) { md in Text(T("dictation.mode.\(md.rawValue)")).tag(md) }
                }
                .disabled(!m.enabled)
                Hint(T("dictation.mode.\(m.mode.rawValue).detail", Dictation.keyInline(m.key)))
                Toggle(isOn: Binding(get: { m.doubleTap }, set: { m.setDoubleTap($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("dictation.settings.double_tap", Dictation.keyShort(m.key)))
                        Text(T("dictation.settings.double_tap.detail")).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!m.enabled)
                if m.key == .fn && m.enabled { fnRows }
                Hint(T("dictation.settings.voice_note_hint", hk(.voice).isEmpty ? T("dictation.settings.voice_note_off") : hk(.voice)))
            } header: { Text(T("dictation.settings.section")) }

            Section {
                styleRows
            } header: { Text(T("dictation.style.section")) }
            .id("style")

            Section {
                modelRows
            } header: { Text(T("dictation.models.section")) }
            .id("models")

            Section {
                wordRows
            } header: { Text(T("dictation.vocab.section")) }
            .id("words")

            Section {
                Picker(T("dictation.history.keep"), selection: Binding(get: { m.retention }, set: { m.setRetention($0) })) {
                    Text(T("dictation.history.days", 7)).tag(7)
                    Text(T("dictation.history.days", 30)).tag(30)
                    Text(T("dictation.history.days", 90)).tag(90)
                    Text(T("dictation.history.days", 365)).tag(365)
                }
                Toggle(isOn: Binding(get: { m.keepAudio }, set: { m.setKeepAudio($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("dictation.history.keep_audio"))
                        Text(T("dictation.history.keep_audio.detail")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(T("dictation.history.open")) { DictationHistoryWindow.shared.show() }
                    Spacer()
                    Button(T("dictation.history.clear"), role: .destructive) { confirmClear = true }
                        .disabled(m.historyCount == 0)
                }
            } header: { Text(T("dictation.history.section")) }
            .id("history")

            Section {
                Toggle(isOn: Binding(get: { m.builtInMic }, set: { m.setBuiltInMic($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("dictation.mic.builtin"))
                        Text(T("dictation.mic.builtin.detail")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!m.enabled)
                Toggle(T("dictation.mic.start_sound"), isOn: Binding(get: { m.startSound }, set: { m.setStartSound($0) }))
                    .disabled(!m.enabled)
            } header: { Text(T("dictation.mic.section")) }

            Section {
                permissionRows
            } header: { Text(T("dictation.perm.section")) }
            .id("permissions")
        }
        // tests: `dictation settings-scroll style|models|words|history|permissions`
        .onReceive(NotificationCenter.default.publisher(for: DictationPane.scrollRequest)) { n in
            guard let id = n.object as? String else { return }
            if id == "permissions" { showPermissions = true }
            if id == "style" { showByApp = true }
            DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
        }
        }
        .onAppear { m.start(); perms.start() }
        .onDisappear { m.stop(); perms.stop() }
        .alert(T("dictation.history.clear.title"), isPresented: $confirmClear) {
            Button(T("dictation.history.clear.confirm"), role: .destructive) { m.clearHistory() }
            Button(T("dictation.cancel"), role: .cancel) {}
        } message: { Text(T("dictation.history.clear.message", m.historyCount)) }
    }

    // MARK: style

    /// The one choice with a line on what it does; per kind of app and the rest folded under "By kind of app".
    @ViewBuilder var styleRows: some View {
        Picker(T("dictation.style.section"), selection: Binding(get: { m.style }, set: { m.setStyle($0) })) {
            ForEach([DictationStyle.verbatim, .light, .structured, .auto], id: \.self) { s in Text(Dictation.styleName(s)).tag(s) }
        }
        .pickerStyle(.segmented)
        .disabled(!m.enabled)
        Hint(T("dictation.style.\(m.style.rawValue).detail"))
        if m.style != .verbatim {
            DisclosureGroup(T("dictation.style.by_app"), isExpanded: $showByApp) { byApp }
                .disabled(!m.enabled)
        }
    }

    @ViewBuilder var byApp: some View {
        ForEach(DictationAppCategory.allCases, id: \.self) { c in
            Picker(selection: Binding(get: { m.styles.categories[c] }, set: { m.setStyle($0, for: c) })) {
                Text(T("dictation.style.follow", Dictation.styleName(m.style))).tag(DictationStyle?.none)
                ForEach(DictationStyle.allCases, id: \.self) { s in Text(Dictation.styleName(s)).tag(Optional(s)) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("dictation.style.cat.\(c.rawValue)"))
                    Text(T("dictation.style.cat.\(c.rawValue).detail")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if !m.styles.apps.isEmpty {
            Text(T("dictation.style.apps")).font(.callout).foregroundStyle(.secondary)
            ForEach(m.styles.apps.keys.sorted(), id: \.self) { b in
                HStack(spacing: 8) {
                    Text(m.appName(b))
                    if m.styles.learned.contains(b) { Badge(T("dictation.style.learned")) }
                    Spacer()
                    Text(Dictation.styleName(m.styles.apps[b] ?? .light)).foregroundStyle(.secondary)
                    Button(T("dictation.style.reset")) { m.resetApp(b) }.controlSize(.small).help(T("dictation.style.reset.help"))
                }
                .accessibilityElement(children: .combine)
            }
        }
        Toggle(T("dictation.style.suggest"), isOn: Binding(get: { m.suggestLists }, set: { m.setSuggestLists($0) }))
        Toggle(isOn: Binding(get: { m.learnStyles }, set: { m.setLearnStyles($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(T("dictation.style.learn_toggle"))
                Text(T("dictation.style.learn_toggle.detail")).font(.caption).foregroundStyle(.secondary)
            }
        }
        Stepper(value: Binding(get: { m.timeout }, set: { m.setTimeout($0) }), in: 1...10, step: 0.5) {
            HStack {
                Text(T("dictation.polish.timeout"))
                Spacer()
                Text(T("dictation.polish.seconds", seconds(m.timeout))).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        Hint(hk(.reformat).isEmpty ? T("dictation.style.keys.no_hotkey") : T("dictation.style.keys", hk(.reformat)))
    }

    // MARK: models (chosen in Settings → Speech)

    @ViewBuilder var modelRows: some View {
        modelRow(T("dictation.models.asr"), value: models.selectedASR.map { $0.name ?? $0.id }, loading: models.asr == nil)
        if m.style != .verbatim {
            if let p = models.polish, !p.supported {
                LabeledContent(T("dictation.models.polish")) { Text(T("dictation.models.unsupported")).foregroundStyle(.secondary) }
            } else {
                modelRow(T("dictation.models.polish"), value: models.selectedPolish?.name, loading: models.polish == nil)
            }
        }
    }

    /// "Recognition model   Qwen3-ASR 1.7B   Change…" — or "Not downloaded yet   Download…"
    func modelRow(_ title: String, value: String?, loading: Bool) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Text(value ?? T("dictation.models.none")).foregroundStyle(.secondary)
                    Button(value == nil ? T("dictation.models.get") : T("dictation.models.change")) { SpeechPane.showDictationModels() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: words (managed on the Dictation page)

    @ViewBuilder var wordRows: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(T("dictation.vocab.summary.title"))
                Text(wordSummary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(T("dictation.vocab.manage")) { DictationHistoryWindow.shared.showWords() }
        }
        .accessibilityElement(children: .combine)
        Toggle(isOn: Binding(get: { m.contextOn }, set: { m.setContext($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(T("dictation.vocab.context"))
                Text(T("dictation.vocab.context.detail")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        Toggle(isOn: Binding(get: { m.learnOn }, set: { m.setLearn($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(T("dictation.vocab.learn"))
                Text(T("dictation.vocab.learn.detail")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Yours: 12 · Built-in: 19 · To review: 3"
    var wordSummary: String {
        var parts = [T("dictation.vocab.summary.mine", m.wordCounts.mine)]
        if m.wordCounts.builtIn > 0 { parts.append(T("dictation.vocab.summary.builtin", m.wordCounts.builtIn)) }
        if m.wordCounts.suggested > 0 { parts.append(T("dictation.vocab.summary.suggested", m.wordCounts.suggested)) }
        return parts.joined(separator: " · ")
    }

    // MARK: the key, Fn, permissions

    /// Only when the key isn't heard (the event tap, not the permission rows: they can say "allowed" while the tap
    /// still isn't there, and the other way round).
    var keyStatus: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDot(tone: .warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(T("dictation.status.off", Dictation.keyInline(m.key)))
                Text(T("dictation.status.off.detail")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(T("dictation.status.fix")) { Dictation.shared.openSetup(from: "dictation") }
        }
        .accessibilityElement(children: .combine)
    }

    /// Which listener runs, and the one thing only the user can prove: the key heard while another app is in front.
    var listenerLine: String {
        let l = T("dictation.listener.\(m.fnFiltering && m.listener == .tap ? "filter" : m.listener.rawValue)")
        let h = m.lastOther.map { T("dictation.heard.other", heardTime($0)) } ?? T("dictation.heard.never", Dictation.keyInline(m.key))
        return l + (Loc.isChinese ? "" : " ") + h
    }

    @ViewBuilder var permissionRows: some View {
        if m.allAllowed {
            DisclosureGroup(isExpanded: $showPermissions) {
                permissionList
            } label: {
                HStack(spacing: 10) { StatusDot(tone: .good); Text(T("dictation.perm.all_set")) }
            }
        } else {
            if !guide.missing(.dictation).isEmpty {
                PermissionSetupButton(flow: .dictation, source: .dictation, p: perms, banner: false)
            }
            permissionList
        }
    }

    @ViewBuilder var permissionList: some View {
        permissionRow(.accessibility, T("dictation.perm.accessibility"), T("dictation.perm.accessibility.why"), granted: m.accessibility)
        permissionRow(.inputMonitoring, T("dictation.perm.input_monitoring"),
                      T(m.key == .fn && m.fnFiltering ? "dictation.perm.input_monitoring.why_fn" : "dictation.perm.input_monitoring.why", Dictation.keyInline(m.key)),
                      granted: m.inputMonitoring || (m.key == .fn && m.fnFiltering), notNeeded: !m.inputMonitoring && m.key == .fn && m.fnFiltering)
        permissionRow(.microphone, T("settings.perm.microphone"), T("dictation.perm.microphone.why"), granted: m.mic == .granted)
        if m.enabled && m.inputMonitoring && m.listener != .tap { Hint(T("dictation.perm.restart_hint")) }
        if m.enabled { Text(listenerLine).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }

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

    /// With Fn: keeping it from macOS (the filter, on Accessibility), macOS's own "Press Globe key to" setting (read
    /// live; shown only when it would react too — Fix… walks the user there with the helper panel, Blurt never changes
    /// it), other Fn dictation apps running.
    @ViewBuilder var fnRows: some View {
        Toggle(isOn: Binding(get: { m.fnCapture }, set: { m.setFnCapture($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(T("dictation.fn.capture"))
                Text(T(m.fnCapture ? (m.fnFiltering ? "dictation.fn.capture.on" : "dictation.fn.capture.needs_ax") : "dictation.fn.capture.detail"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if FnUsage.clashes(m.fnUsage) {
            HStack(alignment: .center, spacing: 10) {
                StatusDot(tone: .warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("dictation.fn.usage", T("dictation.fn_usage.\(m.fnUsage.map { "\($0.rawValue)" } ?? "default")")))
                    Text(T("dictation.fn.usage.clash")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(T("dictation.fn.usage.fix")) { PermissionGuide.shared.start(.dictation, only: [.fnKey], source: .dictation) }
            }
            .accessibilityElement(children: .combine)
        }
        if !m.fnApps.isEmpty {
            Hint(T("dictation.settings.fn_clash", m.fnApps.joined(separator: T("settings.perm.list_sep"))))
        }
    }

    func permissionRow(_ k: PermissionKind, _ title: String, _ why: String, granted: Bool, notNeeded: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDot(tone: granted ? .good : .warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(notNeeded ? T("settings.perm.not_needed") : granted ? T("settings.kit.allowed") : T("settings.kit.not_set"))
                .foregroundStyle(.secondary).font(.callout)
            if !granted {
                Button(T("settings.kit.allow")) { m.allow(k) }
                Button { Permissions.openPane(k) } label: { Image(nsImage: BlurtIcon.externalLink.symbolImage(pointSize: 12)) }
                    .buttonStyle(.borderless).help(T("settings.kit.system_settings")).accessibilityLabel(T("settings.kit.system_settings"))
            }
        }
        .accessibilityElement(children: .combine)
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
