// Settings → Dictation (docs/design/dictation.md): on / off, the key (right ⌥ or Fn) and how it works (tap / hold),
// the two permissions it needs (Input Monitoring for the key, Accessibility to paste), polish (Off / Light, the model
// with its download), the polish time limit, history retention, keeping audio, clearing the history.
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
    @Published var inputMonitoring = DictationKeys.allowed
    @Published var accessibility = AXIsProcessTrusted()
    @Published var tap = Dictation.shared.tapInstalled
    @Published var polish: PolishState?
    @Published var download: [String: (done: Double, total: Double)] = [:]
    @Published var failed: [String: Bool] = [:]
    @Published var historyCount = 0
    private var timer: Timer?
    private var procs: [String: Process] = [:]

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        Task { await loadModels() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        let im = DictationKeys.allowed, ax = AXIsProcessTrusted(), t = Dictation.shared.tapInstalled
        if im != inputMonitoring { inputMonitoring = im }
        if ax != accessibility { accessibility = ax }
        if t != tap { tap = t }
        let n = DictationHistory.shared.load().count
        if n != historyCount { historyCount = n }
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
        if !CGRequestListenEventAccess() { Permissions.openPane("Privacy_ListenEvent") }
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
        download[m.id] = (0, m.sizeMB)
        var env: [String: String] = [:]
        if Config.shared["asr.hf_mirror"] as? Bool == true { env["BLURT_HF_MIRROR"] = "1" }
        procs[m.id] = try? SkillCLI.shared.spawn("polish.py", ["setup", "--model", m.id, "--use"], env: env, onLine: { [weak self] line, _ in
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: #"^(\d+)/(\d+) MB"#, options: .regularExpression) {
                let p = t[r].replacingOccurrences(of: " MB", with: "").split(separator: "/")
                if p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b > 0 { self?.download[m.id] = (a, b) }
            }
        }, onExit: { [weak self] st in
            guard let self = self else { return }
            self.procs[m.id] = nil
            self.download[m.id] = nil
            if st != 0 && st != 15 { self.failed[m.id] = true }
            emit(["event": "polish_download", "model": m.id, "status": Int(st)])
            Dictation.shared.refreshPolishModel()
            Task { await self.loadModels() }
        })
        if procs[m.id] == nil { download[m.id] = nil; failed[m.id] = true }
    }
    func cancel(_ m: PolishModel) { procs[m.id]?.terminate() }

    func clearHistory() {
        DictationHistory.shared.clear()
        DictationHistoryWindow.shared.reloadIfOpen()
        refresh()
    }
}

struct DictationPane: View {
    static let scrollRequest = Notification.Name("BlurtDictationPaneScroll")
    @StateObject var m = DictationSettings()
    @State var confirmClear = false

    var body: some View {
        ScrollViewReader { proxy in PaneFrame {
            Section {
                Toggle(isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("dictation.settings.enable"))
                        Text(T("dictation.settings.enable.detail", keyName(m.key)))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Picker(T("dictation.settings.key"), selection: Binding(get: { m.key }, set: { m.setKey($0) })) {
                    Text(T("dictation.key.right_option")).tag(DictationTrigger.Key.rightOption)
                    Text(T("dictation.key.fn")).tag(DictationTrigger.Key.fn)
                }
                .disabled(!m.enabled)
                Picker(T("dictation.settings.mode"), selection: Binding(get: { m.mode }, set: { m.setMode($0) })) {
                    Text(T("dictation.mode.tap")).tag(DictationTrigger.Mode.tap)
                    Text(T("dictation.mode.hold")).tag(DictationTrigger.Mode.hold)
                }
                .disabled(!m.enabled)
                if m.key == .fn { Hint(T("dictation.settings.fn_hint")) }
                Hint(T("dictation.settings.voice_note_hint", hk(.voice).isEmpty ? T("dictation.settings.voice_note_off") : hk(.voice)))
            } header: { Text(T("dictation.settings.section")) }

            Section {
                permissionRow(T("dictation.perm.input_monitoring"), T("dictation.perm.input_monitoring.why", keyName(m.key)),
                              granted: m.inputMonitoring, allow: m.requestInputMonitoring, pane: "Privacy_ListenEvent")
                permissionRow(T("dictation.perm.accessibility"), T("dictation.perm.accessibility.why"),
                              granted: m.accessibility, allow: m.requestAccessibility, pane: "Privacy_Accessibility")
                if m.enabled && m.inputMonitoring && !m.tap { Hint(T("dictation.perm.restart_hint")) }
            } header: { Text(T("dictation.perm.section")) }

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
        }
        .onAppear { m.start() }
        .onDisappear { m.stop() }
        .alert(T("dictation.history.clear.title"), isPresented: $confirmClear) {
            Button(T("dictation.history.clear.confirm"), role: .destructive) { m.clearHistory() }
            Button(T("dictation.cancel"), role: .cancel) {}
        } message: { Text(T("dictation.history.clear.message", m.historyCount)) }
    }

    private func keyName(_ k: DictationTrigger.Key) -> String { T(k == .fn ? "dictation.key.fn" : "dictation.key.right_option") }

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
                    if model.recommended {
                        Text(T("dictation.polish.recommended")).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15))).foregroundStyle(Color.accentColor)
                    }
                }
                Text(T(model.family == "qwen" ? "dictation.polish.family.qwen" : "dictation.polish.family.gemma", byteString(Int64(model.sizeMB * 1_048_576))))
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
