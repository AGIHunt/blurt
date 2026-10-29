// Settings → Models → Cloud polish (DictationCloud; docs/design/dictation.md §Cloud polish), right under dictation's
// polish model: the row says what polishes now, Set Up… opens this sheet (so does the island's daily reminder:
// `openRequest`). One switch, the service (DeepSeek, or the user's own OpenAI- or
// Anthropic-compatible one: base URL and model), the API key (kept in the Keychain; the field never shows it back),
// Test (one tiny request: polish_cloud.py check, the key on stdin), and a plain paragraph on what goes to the service
// and what it costs. Nothing changes until Done.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class DictationCloudModel: ObservableObject {
    enum Check: Equatable { case idle, running, ok(Int), failed(String) }

    @Published var setup = DictationCloud.setup
    /// a key typed here (empty: keep the one in the Keychain)
    @Published var key = ""
    @Published var check: Check = .idle
    @Published var hasKey: [DictationCloud.Provider: Bool] = [:]

    init() { refreshKeys() }

    func refreshKeys() {
        for p in DictationCloud.Provider.allCases { hasKey[p] = DictationCloud.Key.has(p) }
    }

    var keyStored: Bool { hasKey[setup.provider] ?? false }
    /// on needs a key: typed now, or one already kept
    var canTurnOn: Bool { keyStored || !key.trimmingCharacters(in: .whitespaces).isEmpty }

    func test() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let use = k.isEmpty ? DictationCloud.Key.read(setup.provider) : k, !use.isEmpty else {
            check = .failed(T("dictation.cloud.check.no_key")); return
        }
        check = .running
        let body = try? JSONSerialization.data(withJSONObject: ["cloud": DictationCloud.payload(setup, key: use)])
        emit(["event": "dictation_cloud", "action": "test", "provider": setup.provider.rawValue])
        Scripts.call("polish_cloud.py", ["check"], stdin: body, timeout: 30) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let o): self.check = .ok(o["ms"] as? Int ?? 0)
            case .failure(let f): self.check = .failed(DictationCloudModel.sentence(f.code))
            }
            emit(["event": "dictation_cloud", "action": "tested", "ok": { if case .ok = self.check { return true }; return false }()])
        }
    }

    static func sentence(_ code: String) -> String {
        switch code {
        case "auth": return T("dictation.cloud.check.auth")
        case "network", "timeout": return T("dictation.cloud.check.network")
        case "rate_limited": return T("dictation.cloud.check.rate")
        case "config": return T("dictation.cloud.check.config")
        default: return T("dictation.cloud.check.other")
        }
    }

    func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { DictationCloud.Key.write(setup.provider, k) }
        var s = setup
        // a key just typed means "use it" (the setup assistant's one key, docs/design/first-minute-speech.md §4.3)
        if !k.isEmpty { s.on = true }
        if s.on && !DictationCloud.Key.has(s.provider) { s.on = false }
        DictationCloud.save(s)
        key = ""
        refreshKeys()
        Dictation.shared.apply()
    }

    func forgetKey() {
        DictationCloud.Key.write(setup.provider, "")
        key = ""
        refreshKeys()
        emit(["event": "dictation_cloud", "action": "forget_key", "provider": setup.provider.rawValue])
    }
}

struct DictationCloudSheet: View {
    @StateObject var m = DictationCloudModel()
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(T("dictation.cloud.title")).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(T("dictation.cloud.note"))
                .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Toggle(T("dictation.cloud.on"), isOn: Binding(get: { m.setup.on }, set: { m.setup.on = $0 }))
                .toggleStyle(.switch).controlSize(.small)
                .disabled(!m.setup.on && !m.canTurnOn)
                .padding(.top, 14)
            form.padding(.top, 14)
            what.padding(.top, 14)
            footer.padding(.top, 18)
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                label("dictation.cloud.service")
                ChoicePopup(label: T("dictation.cloud.service"),
                            choices: DictationCloud.Provider.allCases.map { ($0, T("dictation.cloud.provider.\($0.rawValue)")) },
                            selection: Binding(get: { m.setup.provider }, set: { m.setup.provider = $0; m.key = ""; m.check = .idle }),
                            width: 220)
            }
            GridRow {
                label("dictation.cloud.base_url")
                TextField(m.setup.provider.defaultBaseURL, text: Binding(get: { m.setup.baseURL }, set: { m.setup.baseURL = $0; m.check = .idle }))
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                label("dictation.cloud.model")
                TextField(m.setup.provider.defaultModel.isEmpty ? T("dictation.cloud.model.placeholder") : m.setup.provider.defaultModel,
                          text: Binding(get: { m.setup.model }, set: { m.setup.model = $0; m.check = .idle }))
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                label("dictation.cloud.key")
                VStack(alignment: .leading, spacing: 5) {
                    SecureField(m.keyStored ? T("dictation.cloud.key.stored") : T("dictation.cloud.key.placeholder"),
                                text: Binding(get: { m.key }, set: { m.key = $0; m.check = .idle }))
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 12) {
                        if let u = m.setup.provider.keyPage {
                            TextLinkButton(T("dictation.cloud.key.get")) { NSWorkspace.shared.open(u) }
                        }
                        if m.keyStored { TextLinkButton(T("dictation.cloud.key.forget"), tint: .secondary) { m.forgetKey() } }
                    }
                    .font(.system(size: SettingsMetrics.detailSize))
                    .padding(.leading, SettingsMetrics.fieldTextInset)      // under the field's text, not its outline
                }
            }
        }
    }

    func label(_ key: String) -> some View {
        Text(T(key)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    /// what goes, where it goes, what it costs: one quiet paragraph
    var what: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(T("dictation.cloud.what"))
            if m.setup.provider == .deepseek { Text(T("dictation.cloud.cost")) }
        }
        .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(T("dictation.cloud.test")) { m.test() }
                .disabled(m.check == .running || (!m.canTurnOn))
            switch m.check {
            case .idle: EmptyView()
            case .running: BrandSpinnerView(size: 12)
            case .ok(let ms):
                Text(T("dictation.cloud.check.ok", String(format: "%.1f", Double(ms) / 1000)))
                    .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandOk)
            case .failed(let s):
                Text(s).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandErr).lineLimit(2)
            }
            Spacer()
            Button(T("dictation.cloud.cancel"), action: close).keyboardShortcut(.cancelAction)
            Button(T("dictation.cloud.done")) { m.save(); close() }.keyboardShortcut(.defaultAction)
        }
    }
}

/// The Models pane's row: off — this Mac's model polishes; on — the service and model; on without a key — say so.
struct CloudPolishRow: View {
    /// open the sheet (the island's reminder, tests: `dictation settings-scroll cloud_sheet`)
    static let openRequest = Notification.Name("BlurtCloudPolishOpen")
    @State var sheet = false
    @State var cloud = DictationCloud.setup
    @State var ready = DictationCloud.ready

    var body: some View {
        // off with no local polish model (a first run on macOS's recogniser): nothing polishes — said so
        let detail: String = !cloud.on ? T(Dictation.shared.polishModel == nil ? "dictation.cloud.row.off_none" : "dictation.cloud.row.off")
            : !ready ? T("dictation.cloud.row.no_key")
            : T("dictation.cloud.row.on", T("dictation.cloud.provider.\(cloud.provider.rawValue)"), cloud.effectiveModel)
        SettingRow("speech.cloud_polish", detail: detail, icon: "cloud", detailColor: cloud.on && !ready ? .brandAttnInk : nil) {
            Button(T(cloud.on ? "dictation.cloud.row.change" : "dictation.cloud.row.setup")) { sheet = true }
        }
        .sheet(isPresented: $sheet) {
            DictationCloudSheet {
                sheet = false
                cloud = DictationCloud.setup
                ready = DictationCloud.ready
                SettingsNavigator.shared.reveal("speech.cloud_polish")      // where it is, with the row's flash
            }
            .buttonStyle(.automatic)
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudPolishRow.openRequest)) { _ in sheet = true }
        .onReceive(NotificationCenter.default.publisher(for: DictationPane.scrollRequest)) { n in
            if n.object as? String == "cloud_sheet" { sheet = true }
        }
    }
}
