// Settings → Dictation (docs/design/dictation.md): the essentials on one page of rows (SettingsKit; titles and
// descriptions from SettingsCatalog) —
//   Dictation   on / off, the key (Fn first, right ⌥, either ⌥), how it works (auto / tap / hold: the one how-to line),
//               double tap = Return, with Fn: keeping Fn from macOS and macOS's own "Press Globe key to" setting (only
//               when it clashes), other Fn dictation apps running; a status row only when the key can't be heard
//   Style       one choice: Verbatim (no polish) / Light / Structured / Auto (DictationStyleChoice: the polish key and
//               the styles' default); per kind of app, apps set on their own, list suggestions, learning and the
//               polish time limit folded under "By kind of app" (unfolded when a search lands in it)
//   Models      the speech and polish model in use, with Change… / Download… → Settings → Speech, where they are chosen
//               (DictationModels.swift)
//   Words       a one-line summary with Manage… → the Dictation page's Words tab; reading the context and learning
//   History     retention, keeping audio, opening and clearing it
//   (the voice-note line — what to use to keep what you say — is the first group's footnote)
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
    @StateObject var m = DictationSettings()
    @StateObject var perms = Permissions()
    @ObservedObject var models = DictationModels.shared
    @ObservedObject var guide = PermissionGuide.shared
    @State var confirmClear = false
    @State var showPermissions = false
    @State var showByApp = false

    private let nav = SettingsNavigator.shared       // not observed: the pane needn't redraw as the search is typed

    var body: some View {
        SettingsPage(.dictation) {
            if guide.finished != nil { PermissionDoneBanner().padding(.top, 12) }   // the permission guide just finished
            SettingsGroup("dictation.main",
                          footer: T("dictation.settings.voice_note_hint", hk(.voice).isEmpty ? T("dictation.settings.voice_note_off") : hk(.voice))) {
                SettingToggle("dictation.enable", isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) }))
                if m.enabled && !m.tap { keyStatus }
                SettingRow("dictation.key", detail: m.key == .eitherOption ? T("dictation.settings.either_hint") : nil) {
                    RowPicker(label: T("dictation.settings.key"), selection: Binding(get: { m.key }, set: { m.setKey($0) })) {
                        ForEach(DictationTrigger.Key.allCases, id: \.self) { k in Text(Dictation.keyName(k)).tag(k) }    // Fn first
                    }
                }
                .disabled(!m.enabled)
                SettingRow("dictation.mode", detail: T("dictation.mode.\(m.mode.rawValue).detail", Dictation.keyInline(m.key))) {
                    RowPicker(label: T("dictation.settings.mode"), selection: Binding(get: { m.mode }, set: { m.setMode($0) })) {
                        ForEach(DictationTrigger.Mode.allCases, id: \.self) { md in Text(T("dictation.mode.\(md.rawValue)")).tag(md) }
                    }
                }
                .disabled(!m.enabled)
                SettingToggle("dictation.double_tap", isOn: Binding(get: { m.doubleTap }, set: { m.setDoubleTap($0) }),
                              title: T("dictation.settings.double_tap", Dictation.keyShort(m.key)))
                    .disabled(!m.enabled)
                if m.key == .fn && m.enabled { fnRows }
            }

            SettingsGroup("dictation.style") { styleRows }
            SettingsGroup("dictation.models") { modelRows }
            SettingsGroup("dictation.words") { wordRows }

            SettingsGroup("dictation.history") {
                SettingRow("dictation.history_keep") {
                    RowPicker(label: T("dictation.history.keep"), selection: Binding(get: { m.retention }, set: { m.setRetention($0) })) {
                        Text(T("dictation.history.days", 7)).tag(7)
                        Text(T("dictation.history.days", 30)).tag(30)
                        Text(T("dictation.history.days", 90)).tag(90)
                        Text(T("dictation.history.days", 365)).tag(365)
                    }
                }
                SettingToggle("dictation.keep_audio", isOn: Binding(get: { m.keepAudio }, set: { m.setKeepAudio($0) }))
                SettingRow("dictation.history_saved") {
                    HStack(spacing: 8) {
                        Button(T("dictation.history.open")) { DictationHistoryWindow.shared.show() }
                        Button(T("dictation.history.clear"), role: .destructive) { confirmClear = true }
                            .disabled(m.historyCount == 0)
                    }
                }
            }

            SettingsGroup("dictation.mic") {
                SettingToggle("dictation.builtin_mic", isOn: Binding(get: { m.builtInMic }, set: { m.setBuiltInMic($0) }))
                    .disabled(!m.enabled)
                SettingToggle("dictation.start_sound", isOn: Binding(get: { m.startSound }, set: { m.setStartSound($0) }))
                    .disabled(!m.enabled)
            }

            SettingsGroup("dictation.permissions") { permissionRows }
        }
        // tests: `dictation settings-scroll style|models|words|history|permissions`
        .onReceive(NotificationCenter.default.publisher(for: DictationPane.scrollRequest)) { n in
            guard let id = n.object as? String else { return }
            if id == "style" { showByApp = true }
            nav.reveal("dictation.\(id)")
        }
        // a search or a link landing on a row that is folded away: unfold it first
        .onReceive(SettingsFlash.shared.$request) { r in
            guard let id = r?.id else { return }
            if id == "dictation.by_app" || SettingsCatalog.entry(id)?.fold == "dictation.by_app" { showByApp = true }
            if id == "dictation.permissions" { showPermissions = true }
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
        SettingRow("dictation.default_style", detail: T("dictation.style.\(m.style.rawValue).detail"), detailBelow: true) {
            Picker(T("dictation.style.default"), selection: Binding(get: { m.style }, set: { m.setStyle($0) })) {
                ForEach([DictationStyle.verbatim, .light, .structured, .auto], id: \.self) { s in Text(Dictation.styleName(s)).tag(s) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .disabled(!m.enabled)
        if m.style != .verbatim {
            SettingRow("dictation.by_app") {
                Button { withAnimation(.easeOut(duration: 0.15)) { showByApp.toggle() } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showByApp ? 90 : 0))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(T("dictation.style.by_app"))
                .accessibilityValue(showByApp ? "1" : "0")
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showByApp.toggle() } }
            .disabled(!m.enabled)
            if showByApp {
                VStack(alignment: .leading, spacing: 0) { byApp }
                    .padding(.leading, 20)
                    .disabled(!m.enabled)
            }
        }
    }

    @ViewBuilder var byApp: some View {
        ForEach(DictationAppCategory.allCases, id: \.self) { c in
            SettingRow("dictation.cat.\(c.rawValue)") {
                RowPicker(label: T("dictation.style.cat.\(c.rawValue)"), selection: Binding(get: { m.styles.categories[c] }, set: { m.setStyle($0, for: c) })) {
                    Text(T("dictation.style.follow", Dictation.styleName(m.style))).tag(DictationStyle?.none)
                    ForEach(DictationStyle.allCases, id: \.self) { s in Text(Dictation.styleName(s)).tag(Optional(s)) }
                }
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

    // MARK: models (chosen in Settings → Speech)

    @ViewBuilder var modelRows: some View {
        // the recogniser as the key sees it: in use, coming down (its bar), or not there yet (Download…)
        let asr = models.selectedASR
        let job = models.dictationJob
        let coming = job.flatMap { j in ModelDownloads.shared.queue.contains(j.id) ? j : nil }
        SettingRow("dictation.asr_model", detail: coming.map { j in
            let p = models.progress(j.id) ?? (0, j.sizeMB)
            return T("dictation.models.downloading", modelSize(p.done), modelSize(max(p.total, j.sizeMB)))
        }) {
            modelControl(value: asr?.installed == true ? asr.map { $0.name ?? $0.id } : nil, loading: models.asr == nil)
        }
        if m.style != .verbatim {
            SettingRow("dictation.polish_model") {
                if let p = models.polish, !p.supported {
                    Text(T("dictation.models.unsupported")).foregroundStyle(.secondary)
                } else {
                    modelControl(value: models.selectedPolish?.name, loading: models.polish == nil)
                }
            }
        }
    }

    /// "Qwen3-ASR 1.7B   Change…" — or "Not downloaded yet   Download…" (chosen in Settings → Speech)
    @ViewBuilder func modelControl(value: String?, loading: Bool) -> some View {
        HStack(spacing: 8) {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Text(value ?? T("dictation.models.none")).foregroundStyle(.secondary)
                Button(value == nil ? T("dictation.models.get") : T("dictation.models.change")) { SpeechPane.showDictationModels() }
            }
        }
    }

    // MARK: words (managed on the Dictation page)

    @ViewBuilder var wordRows: some View {
        SettingRow("dictation.word_list", detail: wordSummary) {
            Button(T("dictation.vocab.manage")) { DictationHistoryWindow.shared.showWords() }
        }
        SettingToggle("dictation.context", isOn: Binding(get: { m.contextOn }, set: { m.setContext($0) }))
        SettingToggle("dictation.learn", isOn: Binding(get: { m.learnOn }, set: { m.setLearn($0) }))
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
    @ViewBuilder var keyStatus: some View {
        if let pid = Dictation.shared.deferredTo {
            // another Blurt has the key: nothing to set up here (this one takes over when that one quits)
            statusLine(T("dictation.status.other_instance", "\(pid)"), T("dictation.status.other_instance.detail"), tone: .off) { EmptyView() }
        } else {
            statusLine(T("dictation.status.off", Dictation.keyInline(m.key)), T("dictation.status.off.detail")) {
                Button(T("dictation.status.fix")) { Dictation.shared.openSetup(from: "dictation") }
            }
        }
    }

    /// A state that needs you: the attention dot, what and why, the one thing to do.
    func statusLine<A: View>(_ title: String, _ detail: String, tone: Tone = .warn, @ViewBuilder action: () -> A) -> some View {
        SettingsLine {
            HStack(alignment: .center, spacing: 14) {
                StatusDot(tone: tone).frame(width: SettingsMetrics.leadingWidth)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: SettingsMetrics.titleSize))
                    Text(detail).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                action()
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Which listener runs, and the one thing only the user can prove: the key heard while another app is in front.
    var listenerLine: String {
        let l = T("dictation.listener.\(m.fnFiltering && m.listener == .tap ? "filter" : m.listener.rawValue)")
        let h = m.lastOther.map { T("dictation.heard.other", heardTime($0)) } ?? T("dictation.heard.never", Dictation.keyInline(m.key))
        return l + (Loc.isChinese ? "" : " ") + h
    }

    @ViewBuilder var permissionRows: some View {
        if m.allAllowed {
            SettingsLine {
                HStack(spacing: 14) {
                    StatusDot(tone: .good).frame(width: SettingsMetrics.leadingWidth)
                    Text(T("dictation.perm.all_set")).font(.system(size: SettingsMetrics.titleSize))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showPermissions ? 90 : 0)).frame(width: 22, height: 22)
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showPermissions.toggle() } }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { showPermissions.toggle() }
            }
            if showPermissions { VStack(alignment: .leading, spacing: 0) { permissionList }.padding(.leading, 20) }
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
        if m.enabled && m.inputMonitoring && m.listener != .tap { SettingsLine { Hint(T("dictation.perm.restart_hint")) } }
        if m.enabled { SettingsLine { Hint(listenerLine) } }
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
        SettingToggle("dictation.fn_capture", isOn: Binding(get: { m.fnCapture }, set: { m.setFnCapture($0) }),
                      detail: T(m.fnCapture ? (m.fnFiltering ? "dictation.fn.capture.on" : "dictation.fn.capture.needs_ax") : "dictation.fn.capture.detail"))
        if FnUsage.clashes(m.fnUsage) {
            statusLine(T("dictation.fn.usage", T("dictation.fn_usage.\(m.fnUsage.map { "\($0.rawValue)" } ?? "default")")), T("dictation.fn.usage.clash")) {
                Button(T("dictation.fn.usage.fix")) { PermissionGuide.shared.start(.dictation, only: [.fnKey], source: .dictation) }
            }
        }
        if !m.fnApps.isEmpty {
            SettingsLine { Hint(T("dictation.settings.fn_clash", m.fnApps.joined(separator: T("settings.perm.list_sep")))) }
        }
    }

    func permissionRow(_ k: PermissionKind, _ title: String, _ why: String, granted: Bool, notNeeded: Bool = false) -> some View {
        SettingsLine {
        HStack(alignment: .center, spacing: 14) {
            StatusDot(tone: granted ? .good : .warn).frame(width: SettingsMetrics.leadingWidth)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: SettingsMetrics.titleSize))
                Text(why).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
