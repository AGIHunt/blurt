// Settings → Dictation (docs/design/dictation.md): on / off, the key (right ⌥ or Fn) and how it works (tap / hold),
// which listener hears it and when it was last heard in another app, the two permissions it needs (Input Monitoring
// for the key, Accessibility to paste and read the text around the cursor), the recognition model (with its
// download), custom words (add, remove, learned ones, suggestions to accept or ignore; reading the context and
// learning can be turned off), polish (Off / Light, the model with its download), the polish time limit, history
// retention, keeping audio, clearing the history.
// Everything is record.dictation.* in config.json; Dictation.shared.apply() picks changes up at once.
// Strings: Resources/*.lproj/Dictation.strings (T("dictation.…")).
import AppKit
import SwiftUI
import BlurtCore

struct PolishModel: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var family: String
    var sizeMB: Double
    var installed: Bool
    var recommended: Bool
    enum CodingKeys: String, CodingKey { case id, name, family, installed, recommended, sizeMB = "size_mb" }
}

/// `transcribe.py dictation-models`: what dictation can use here.
struct DictationASRModel: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var sizeMB: Double
    var installed: Bool
    var recommended: Bool
    /// none | prompt | context | hotwords: how the model takes the custom words
    var vocab: String
    enum CodingKeys: String, CodingKey { case id, name, installed, recommended, vocab, sizeMB = "size_mb" }
}

struct DictationASRState: Decodable {
    var configured: String?
    var recommended: String
    var selected: String
    var models: [DictationASRModel]
}

struct PolishState: Decodable {
    var supported: Bool
    var tier: String
    var recommended: String
    var selected: String?
    var configured: String?
    var models: [PolishModel]
}

@MainActor
final class DictationSettings: ObservableObject {
    @Published var enabled = Dictation.enabled
    @Published var key = Dictation.key
    @Published var mode = Dictation.mode
    @Published var polishOn = Dictation.polishOn
    @Published var timeout = Dictation.polishTimeout
    @Published var retention = Dictation.retentionDays
    @Published var keepAudio = Dictation.keepAudio
    @Published var inputMonitoring = DictationKeys.inputMonitoring
    @Published var accessibility = DictationKeys.accessibility
    @Published var tap = Dictation.shared.tapInstalled
    @Published var listener = Dictation.shared.listenerKind
    @Published var lastOther = Dictation.shared.lastKeyFromOtherApp
    @Published var polish: PolishState?
    @Published var download: [String: (done: Double, total: Double)] = [:]
    @Published var failed: [String: Bool] = [:]
    @Published var historyCount = 0
    @Published var contextOn = Dictation.contextOn
    @Published var learnOn = Dictation.learnOn
    @Published var words: [VocabTerm] = []
    @Published var suggestions: [VocabTerm] = []
    @Published var newWord = ""
    @Published var asr: DictationASRState?
    @Published var asrDownload: [String: (done: Double, total: Double)] = [:]
    @Published var asrFailed: [String: Bool] = [:]
    private var timer: Timer?
    private var procs: [String: Process] = [:]
    private var cancelled = Set<String>()

    func start() {
        Dictation.shared.seedVocabulary()
        refresh()
        emit(["event": "dictation_pane", "tap": tap])
        Task { await loadASR() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        Task { await loadModels() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        let im = DictationKeys.inputMonitoring, ax = DictationKeys.accessibility, t = Dictation.shared.tapInstalled
        if im != inputMonitoring { inputMonitoring = im }
        if ax != accessibility { accessibility = ax }
        let l = Dictation.shared.listenerKind, o = Dictation.shared.lastKeyFromOtherApp
        if l != listener { listener = l; emit(["event": "dictation_pane", "listener": l.rawValue]) }
        if o != lastOther { lastOther = o }
        if t != tap {
            tap = t
            emit(["event": "dictation_pane", "tap": t])
        }
        let n = DictationHistory.shared.load().count
        if n != historyCount { historyCount = n }
        reloadWords()
    }

    // MARK: custom words

    func reloadWords() {
        let all = DictationVocabulary.shared.load()
        let w = all.filter { $0.state == .active }.sorted { ($0.source == .learned ? 0 : 1, $0.term.lowercased()) < ($1.source == .learned ? 0 : 1, $1.term.lowercased()) }
        let sg = all.filter { $0.state == .suggested }
        if w != words { words = w }
        if sg != suggestions { suggestions = sg }
    }

    func addWord() {
        let t = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        DictationVocabulary.shared.add(t)
        newWord = ""
        reloadWords()
        emit(["event": "dictation_vocab", "op": "add", "term": t])
    }
    func removeWord(_ t: VocabTerm) { DictationVocabulary.shared.remove(t.term); reloadWords(); emit(["event": "dictation_vocab", "op": "remove", "term": t.term]) }
    func accept(_ t: VocabTerm) { DictationVocabulary.shared.accept(t.term); reloadWords(); emit(["event": "dictation_vocab", "op": "accept", "term": t.term]) }
    func reject(_ t: VocabTerm) { DictationVocabulary.shared.reject(t.term); reloadWords(); emit(["event": "dictation_vocab", "op": "reject", "term": t.term]) }
    func setContext(_ v: Bool) { contextOn = v; save("context", v ? nil : false) }
    func setLearn(_ v: Bool) { learnOn = v; save("learn", v ? nil : false) }

    // MARK: recognition model

    func loadASR() async {
        let r = try? await SkillCLI.shared.run("transcribe.py", ["dictation-models"], timeout: 120)
        asr = r?.decode(DictationASRState.self)
    }

    func chooseASR(_ m: DictationASRModel) {
        save("asr_model", m.id)
        Task { await loadASR() }
    }

    /// `transcribe.py setup --model-id ID` (it adds its package through uv) — only when the user asks.
    func installASR(_ m: DictationASRModel) {
        guard asrDownload[m.id] == nil else { return }
        asrFailed[m.id] = nil
        asrDownload[m.id] = (0, m.sizeMB)
        var env: [String: String] = [:]
        if Config.shared["asr.hf_mirror"] as? Bool == true { env["BLURT_HF_MIRROR"] = "1" }
        let script = ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1"
            ? ProcessInfo.processInfo.environment["BLURT_TEST_ASR_SETUP"] ?? "transcribe.py" : "transcribe.py"
        let p = try? SkillCLI.shared.spawn(script, ["setup", "--model-id", m.id], env: env, onLine: { [weak self] line, _ in
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: #"^(\d+)/(\d+) MB"#, options: .regularExpression) {
                let q = t[r].replacingOccurrences(of: " MB", with: "").split(separator: "/")
                if q.count == 2, let a = Double(q[0]), let b = Double(q[1]), b > 0 { self?.asrDownload[m.id] = (a, b) }
            }
        }, onExit: { [weak self] st in
            guard let self = self else { return }
            self.asrDownload[m.id] = nil
            if st != 0 { self.asrFailed[m.id] = true } else { self.save("asr_model", m.id) }
            emit(["event": "asr_download", "model": m.id, "status": Int(st)])
            Task { await self.loadASR() }
        })
        if p == nil { asrDownload[m.id] = nil; asrFailed[m.id] = true }
    }

    func loadModels() async {
        let r = try? await SkillCLI.shared.run("polish.py", ["models"], timeout: 60)
        polish = r?.decode(PolishState.self)
    }

    private func save(_ key: String, _ value: Any?) {
        Dictation.set(key, value)
        Dictation.shared.apply()
        emit(["event": "dictation_setting", "key": key, "value": value.map { "\($0)" } ?? "default"])
    }

    func setEnabled(_ v: Bool) { enabled = v; save("enabled", v ? nil : false) }
    func setKey(_ v: DictationTrigger.Key) { key = v; save("key", v == .rightOption ? nil : v.rawValue) }
    func setMode(_ v: DictationTrigger.Mode) { mode = v; save("mode", v == .tap ? nil : v.rawValue) }
    func setPolish(_ on: Bool) { polishOn = on; save("polish", on ? nil : "off") }
    func setTimeout(_ s: Double) { timeout = s; save("polish_timeout_ms", Int(s * 1000) == 3000 ? nil : Int(s * 1000)) }
    func setRetention(_ d: Int) {
        retention = d
        save("retention_days", d == 30 ? nil : d)
        DispatchQueue.global(qos: .utility).async { DictationHistory.shared.prune(days: d) }
    }
    func setKeepAudio(_ v: Bool) { keepAudio = v; save("keep_audio", v ? true : nil) }

    func choose(_ m: PolishModel) {
        save("polish_model", m.id)
        Dictation.shared.refreshPolishModel()
        Task { await loadModels() }
    }

    func requestInputMonitoring() {
        if !Dictation.requestListenAccess(via: "settings") { Dictation.openSystemPane() }
        Dictation.shared.apply()
    }
    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { Permissions.openPane("Privacy_Accessibility") }
    }

    /// `polish.py setup --model ID --use` — only when the user asks; progress from its "  N/M MB" lines.
    func install(_ m: PolishModel) {
        guard procs[m.id] == nil else { return }
        failed[m.id] = nil
        cancelled.remove(m.id)
        download[m.id] = (0, m.sizeMB)
        var env: [String: String] = [:]
        if Config.shared["asr.hf_mirror"] as? Bool == true { env["BLURT_HF_MIRROR"] = "1" }
        // BLURT_TEST_POLISH_SETUP (test builds only): a script that stands in for polish.py and fakes the download
        let script = ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1"
            ? ProcessInfo.processInfo.environment["BLURT_TEST_POLISH_SETUP"] ?? "polish.py" : "polish.py"
        procs[m.id] = try? SkillCLI.shared.spawn(script, ["setup", "--model", m.id, "--use"], env: env, onLine: { [weak self] line, _ in
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: #"^(\d+)/(\d+) MB"#, options: .regularExpression) {
                let p = t[r].replacingOccurrences(of: " MB", with: "").split(separator: "/")
                if p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b > 0 { self?.download[m.id] = (a, b) }
            }
        }, onExit: { [weak self] st in
            guard let self = self else { return }
            self.procs[m.id] = nil
            self.download[m.id] = nil
            if st != 0 && !self.cancelled.contains(m.id) { self.failed[m.id] = true }
            self.cancelled.remove(m.id)
            emit(["event": "polish_download", "model": m.id, "status": Int(st)])
            Dictation.shared.refreshPolishModel()
            Task { await self.loadModels() }
        })
        if procs[m.id] == nil { download[m.id] = nil; failed[m.id] = true }
    }
    func cancel(_ m: PolishModel) {
        guard let p = procs[m.id] else { return }
        cancelled.insert(m.id)
        p.terminate()
    }

    func clearHistory() {
        DictationHistory.shared.clear()
        DictationHistoryWindow.shared.reloadIfOpen()
        refresh()
    }
}

struct DictationPane: View {
    static let scrollRequest = Notification.Name("BlurtDictationPaneScroll")
    /// tests: `dictation polish install ID | cancel ID | use ID | state` — the model rows' buttons, then a
    /// "polish_settings" event with every row's state
    static let polishRequest = Notification.Name("BlurtDictationPanePolish")
    @StateObject var m = DictationSettings()
    @State var confirmClear = false

    var body: some View {
        ScrollViewReader { proxy in PaneFrame {
            Section {
                Toggle(isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("dictation.settings.enable"))
                        Text(T("dictation.settings.enable.detail", Dictation.keyInline(m.key)))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if m.enabled { keyStatus }
                Picker(T("dictation.settings.key"), selection: Binding(get: { m.key }, set: { m.setKey($0) })) {
                    Text(T("dictation.key.right_option")).tag(DictationTrigger.Key.rightOption)
                    Text(T("dictation.key.either_option")).tag(DictationTrigger.Key.eitherOption)
                    Text(T("dictation.key.fn")).tag(DictationTrigger.Key.fn)
                }
                .disabled(!m.enabled)
                if m.key == .eitherOption { Hint(T("dictation.settings.either_hint")) }
                Picker(T("dictation.settings.mode"), selection: Binding(get: { m.mode }, set: { m.setMode($0) })) {
                    Text(T("dictation.mode.tap")).tag(DictationTrigger.Mode.tap)
                    Text(T("dictation.mode.hold")).tag(DictationTrigger.Mode.hold)
                }
                .disabled(!m.enabled)
                if m.key == .fn { Hint(T("dictation.settings.fn_hint")) }
                Hint(T("dictation.settings.voice_note_hint", hk(.voice).isEmpty ? T("dictation.settings.voice_note_off") : hk(.voice)))
            } header: { Text(T("dictation.settings.section")) }

            Section {
                permissionRow(T("dictation.perm.input_monitoring"), T("dictation.perm.input_monitoring.why", Dictation.keyInline(m.key)),
                              granted: m.inputMonitoring, allow: m.requestInputMonitoring, pane: "Privacy_ListenEvent")
                permissionRow(T("dictation.perm.accessibility"), T("dictation.perm.accessibility.why"),
                              granted: m.accessibility, allow: m.requestAccessibility, pane: "Privacy_Accessibility")
                if m.enabled && m.inputMonitoring && m.listener != .tap { Hint(T("dictation.perm.restart_hint")) }
            } header: { Text(T("dictation.perm.section")) }

            Section {
                asrModels
            } header: { Text(T("dictation.asr.section")) }
            .id("asr")

            Section {
                vocabulary
            } header: { Text(T("dictation.vocab.section")) }
            .id("vocab")

            Section {
                Picker(T("dictation.polish.title"), selection: Binding(get: { m.polishOn }, set: { m.setPolish($0) })) {
                    Text(T("dictation.polish.off")).tag(false)
                    Text(T("dictation.polish.light")).tag(true)
                }
                .pickerStyle(.segmented)
                Hint(T("dictation.polish.detail"))
                if m.polishOn { polishModels }
                if m.polishOn {
                    Stepper(value: Binding(get: { m.timeout }, set: { m.setTimeout($0) }), in: 1...10, step: 0.5) {
                        HStack {
                            Text(T("dictation.polish.timeout"))
                            Spacer()
                            Text(T("dictation.polish.seconds", seconds(m.timeout))).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            } header: { Text(T("dictation.polish.section")) }
            .id("polish")

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
        }
        // tests: `dictation settings-scroll polish|history` (a screenshot of the lower sections)
        .onReceive(NotificationCenter.default.publisher(for: DictationPane.scrollRequest)) { n in
            if let id = n.object as? String { proxy.scrollTo(id, anchor: .top) }
        }
        .onReceive(NotificationCenter.default.publisher(for: DictationPane.polishRequest)) { n in
            let a = (n.object as? String ?? "").split(separator: " ").map(String.init)
            if a.count == 2, let model = m.polish?.models.first(where: { $0.id == a[1] }) {
                switch a[0] {
                case "install": m.install(model)
                case "cancel": m.cancel(model)
                case "use": m.choose(model)
                default: break
                }
            }
            emit(["event": "polish_settings", "selected": m.polish?.selected ?? NSNull(), "polish": m.polishOn,
                  "models": (m.polish?.models ?? []).map { x -> String in
                      let d = m.download[x.id].map { " \(Int($0.done))/\(Int($0.total))" } ?? ""
                      return "\(x.id)\(x.installed ? " installed" : "")\(x.recommended ? " recommended" : "")\(d)\(m.failed[x.id] == true ? " failed" : "")"
                  }])
        }
        }
        .onAppear { m.start() }
        .onDisappear { m.stop() }
        .alert(T("dictation.history.clear.title"), isPresented: $confirmClear) {
            Button(T("dictation.history.clear.confirm"), role: .destructive) { m.clearHistory() }
            Button(T("dictation.cancel"), role: .cancel) {}
        } message: { Text(T("dictation.history.clear.message", m.historyCount)) }
    }

    // MARK: recognition model

    @ViewBuilder var asrModels: some View {
        if let a = m.asr {
            ForEach(a.models) { model in asrRow(model, selected: a.selected == model.id) }
            if a.selected != a.recommended, let rec = a.models.first(where: { $0.id == a.recommended }), !rec.installed {
                Hint(T("dictation.asr.recommend_hint", rec.name ?? rec.id))
            }
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(T("dictation.polish.loading")).foregroundStyle(.secondary) }
        }
    }

    func asrRow(_ model: DictationASRModel, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.name ?? model.id)
                    if model.recommended { Badge(T("dictation.polish.recommended")) }
                }
                Group {
                    if let d = m.asrDownload[model.id] {
                        Text(T("dictation.polish.progress", byteString(Int64(d.done * 1_048_576)), byteString(Int64(max(d.total, model.sizeMB) * 1_048_576))))
                            .monospacedDigit()
                    } else {
                        Text(T("dictation.asr.vocab.\(model.vocab == "none" ? "none" : "yes")") + " · " + byteString(Int64(model.sizeMB * 1_048_576)))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if m.asrDownload[model.id] != nil {
                ProgressView().controlSize(.small)
            } else if model.installed {
                if !selected { Button(T("dictation.polish.use")) { m.chooseASR(model) }.controlSize(.small) }
            } else {
                if m.asrFailed[model.id] == true { Text(T("dictation.polish.failed")).font(.caption).foregroundStyle(.orange) }
                Button(T("dictation.polish.install")) { m.installASR(model) }.controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if model.installed && !selected { m.chooseASR(model) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: custom words

    @ViewBuilder var vocabulary: some View {
        Hint(T("dictation.vocab.detail"))
        HStack {
            TextField(T("dictation.vocab.add.placeholder"), text: $m.newWord)
                .textFieldStyle(.roundedBorder)
                .onSubmit { m.addWord() }
            Button(T("dictation.vocab.add")) { m.addWord() }
                .disabled(m.newWord.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        ForEach(m.suggestions) { t in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) { Text(t.term); Badge(T("dictation.vocab.suggested"), tint: .orange) }
                    if !t.soundsLike.isEmpty {
                        Text(T("dictation.vocab.heard_as", t.soundsLike.joined(separator: T("dictation.vocab.list_sep"))))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(T("dictation.vocab.accept")) { m.accept(t) }.controlSize(.small)
                Button(T("dictation.vocab.ignore")) { m.reject(t) }.controlSize(.small)
            }
            .accessibilityElement(children: .combine)
        }
        if m.words.isEmpty {
            Text(T("dictation.vocab.empty")).font(.callout).foregroundStyle(.secondary)
        }
        ForEach(m.words) { t in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(t.term)
                        if t.source == .learned { Badge(T("dictation.vocab.learned")) }
                        if t.source == .project { Badge(T("dictation.vocab.auto"), tint: .secondary) }
                    }
                    if !t.soundsLike.isEmpty {
                        Text(T("dictation.vocab.heard_as", t.soundsLike.joined(separator: T("dictation.vocab.list_sep"))))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button { m.removeWord(t) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help(T("dictation.vocab.remove")).accessibilityLabel(T("dictation.vocab.remove"))
            }
            .accessibilityElement(children: .combine)
        }
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

    /// Whether the key is heard right now — the event tap, not the permission rows below (they can say "allowed"
    /// while the tap still isn't there, and the other way round).
    var keyStatus: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDot(tone: m.tap ? .good : .warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(T(m.tap ? "dictation.status.on" : "dictation.status.off", Dictation.keyInline(m.key)))
                Text(T(m.tap ? (m.mode == .hold ? "dictation.status.on.hold" : "dictation.status.on.tap") : "dictation.status.off.detail",
                       Dictation.keyInline(m.key)))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                // which listener runs, and the one thing only the user can prove: the key heard while another app is in front
                Text(T("dictation.listener.\(m.listener.rawValue)") + " " + (m.lastOther.map { T("dictation.heard.other", heardTime($0)) }
                        ?? T("dictation.heard.never", Dictation.keyInline(m.key))))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !m.tap { Button(T("dictation.status.fix")) { Dictation.shared.openSetup() } }
        }
        .accessibilityElement(children: .combine)
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

    func permissionRow(_ title: String, _ why: String, granted: Bool, allow: @escaping () -> Void, pane: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDot(tone: granted ? .good : .warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(granted ? T("settings.kit.allowed") : T("settings.kit.not_set")).foregroundStyle(.secondary).font(.callout)
            if !granted {
                Button(T("settings.kit.allow"), action: allow)
                Button { Permissions.openPane(pane) } label: { Image(nsImage: BlurtIcon.externalLink.symbolImage(pointSize: 12)) }
                    .buttonStyle(.borderless).help(T("settings.kit.system_settings")).accessibilityLabel(T("settings.kit.system_settings"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder var polishModels: some View {
        if let p = m.polish {
            if !p.supported {
                Hint(T("dictation.polish.unsupported"))
            } else {
                // recommended first, then installed, then smallest
                ForEach(p.models.sorted { ($0.recommended ? 0 : 1, $0.installed ? 0 : 1, $0.sizeMB) < ($1.recommended ? 0 : 1, $1.installed ? 0 : 1, $1.sizeMB) }) { model in modelRow(model, selected: p.selected == model.id, state: p) }
                if p.selected == nil { Hint(T("dictation.polish.none_installed")) }
            }
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(T("dictation.polish.loading")).foregroundStyle(.secondary) }
        }
    }

    func modelRow(_ model: PolishModel, selected: Bool, state: PolishState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.name)
                    if model.recommended { Badge(T("dictation.polish.recommended")) }
                }
                Group {
                    if let d = m.download[model.id] {
                        Text(T("dictation.polish.progress", byteString(Int64(d.done * 1_048_576)), byteString(Int64(max(d.total, model.sizeMB) * 1_048_576))))
                            .monospacedDigit()
                    } else {
                        Text(T("dictation.polish.family.\(model.family == "qwen" ? "qwen" : "gemma")\(model.installed ? ".installed" : "")",
                               byteString(Int64(model.sizeMB * 1_048_576))))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let d = m.download[model.id] {
                ProgressView(value: min(d.done, d.total), total: max(d.total, 1)).frame(width: 90)
                Button(T("dictation.cancel")) { m.cancel(model) }.controlSize(.small)
            } else if model.installed {
                if !selected { Button(T("dictation.polish.use")) { m.choose(model) }.controlSize(.small) }
            } else {
                if m.failed[model.id] == true { Text(T("dictation.polish.failed")).font(.caption).foregroundStyle(.orange) }
                Button(T("dictation.polish.install")) { m.install(model) }.controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if model.installed && !selected { m.choose(model) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A small capsule label next to a name ("Recommended", "Learned").
struct Badge: View {
    let text: String
    var tint: Color = .accentColor
    init(_ text: String, tint: Color = .accentColor) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.15))).foregroundStyle(tint)
    }
}
