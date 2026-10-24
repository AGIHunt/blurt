// Settings → Export: where items go when the agent exports them — per project (<repo>/.blurt/config.json → export, the
// same key the skill's exporters read; SKILL reference/export-*.md), or globally for ~/Blurt (config export). One row
// per destination in plain words — Feishu / Lark, GitHub Issues, Markdown and CSV — each Ready, Checking or Not set up
// with the one command that sets it up; which tool it uses (lark-cli or a Feishu app, gh) is in the row's tooltip.
// Never shows a credential.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class ExportModel: ObservableObject {
    @Published var target = "ask"
    @Published var url = ""
    @Published var outDir = ""
    @Published var lark: String?            // path
    @Published var feishuApp = false
    @Published var gh: String?
    @Published var ghAuthed: Bool?
    @Published var checking = true          // until the first look: no "Not set up" flash
    /// The current project's folder; nil = Unassigned (Blurt's own config.json). Read again each time the pane shows.
    @Published var ws: URL? = ProjectStore.shared.current?.path

    var isProject: Bool { ws != nil }
    private var section: [String: Any] {
        if let ws = ws { return ProjectConfig.read(ws)["export"] as? [String: Any] ?? [:] }
        return (Config.shared["export"] as? [String: Any] ?? [:])
    }

    func load() async {
        ws = ProjectStore.shared.current?.path
        let s = section
        target = s["target"] as? String ?? "ask"
        url = s["url"] as? String ?? ""
        outDir = s["out"] as? String ?? ""
        checking = true
        defer { checking = false }
        let env = SkillCLI.shared.environment()
        lark = ShellEnv.findExecutable("lark-cli")
        gh = ShellEnv.findExecutable("gh")
        let feishuCfg = Config.shared["feishu"] as? [String: Any] ?? [:]
        feishuApp = !(env["FEISHU_APP_ID"] ?? "").isEmpty || !((feishuCfg["app_id"] as? String) ?? "").isEmpty
        if let g = gh {
            let r = await Task.detached { ShellEnv.runCapture(g, ["auth", "status"], env: env, timeout: 15) }.value
            ghAuthed = r.status == 0
        }
    }

    func set(_ key: String, _ value: Any?) {
        if let ws = ws { ProjectConfig.set(ws, "export", key, value) } else { Config.shared.set("export.\(key)", value) }
    }
    func setTarget(_ t: String) { target = t; set("target", t == "ask" ? nil : t) }
    func commitURL() { set("url", url.isEmpty ? nil : url) }
    func chooseOut() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = T("settings.export.choose")
        guard p.runModal() == .OK, let u = p.url else { return }
        outDir = u.path
        set("out", u.path)
    }
}

struct ExportPane: View {
    @StateObject var m = ExportModel()

    var body: some View {
        PaneFrame {
            Section {
                Picker(T("settings.export.send_confirmed_items"), selection: Binding(get: { m.target }, set: { m.setTarget($0) })) {
                    Text(T("settings.export.ask_each_time")).tag("ask")
                    Text(T("settings.export.feishu_lark_bitable")).tag("feishu")
                    Text("GitHub Issues").tag("github")
                    Text(T("settings.export.local")).tag("local")
                }
                if m.target == "feishu" {
                    TextField(T("settings.export.table_url"), text: $m.url, prompt: Text("https://….feishu.cn/base/…?table=…"))
                        .onSubmit { m.commitURL() }
                    Hint(T("settings.export.open_table_browser_copy"))
                }
                if m.target == "local" {
                    HStack {
                        Text(T("settings.export.save"))
                        Spacer()
                        Text(m.outDir.isEmpty ? T("settings.export.session_folder") : (m.outDir as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                        Button(T("settings.export.choose_2")) { m.chooseOut() }
                    }
                }
                Hint(m.isProject ? T("settings.export.blurt_config_json_shared", ProjectStore.shared.current?.name ?? m.ws?.lastPathComponent ?? "")
                                 : T("settings.export.default_workspace_blurt"))
            } header: { Text(T("settings.export.default_destination")) }

            Section {
                // Feishu / Lark: lark-cli (exports as you), or a Feishu app (FEISHU_APP_ID) when there is no lark-cli
                let larkReady = m.lark != nil || m.feishuApp
                tool(T("settings.export.feishu"), state: m.checking && !larkReady ? .checking : larkReady ? .ready : .notSetUp,
                     tip: m.lark.map { "lark-cli · " + ($0 as NSString).abbreviatingWithTildeInPath }
                         ?? (m.feishuApp ? T("settings.export.feishu_app_id_set") : nil),
                     fix: larkReady ? nil : "npx @larksuite/cli@latest install")
                // GitHub Issues: gh, signed in (`gh auth status` takes a moment)
                tool("GitHub Issues", state: m.gh == nil ? (m.checking ? .checking : .notSetUp)
                                         : m.ghAuthed == nil ? .checking : m.ghAuthed == true ? .ready : .signedOut,
                     tip: m.gh.map { "gh · " + ($0 as NSString).abbreviatingWithTildeInPath },
                     fix: m.gh == nil ? "brew install gh" : (m.ghAuthed == false ? "gh auth login" : nil))
                tool(T("settings.export.local"), state: .ready, tip: nil, fix: nil)
            } header: { Text(T("settings.export.exporters")) } footer: {
                Text(T("settings.export.footer")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await m.load() }
    }

    enum ToolState { case ready, checking, notSetUp, signedOut }

    func tool(_ name: String, state: ToolState, tip: String?, fix: String?) -> some View {
        HStack {
            StatusDot(tone: state == .ready ? .good : .off)
            Text(name)
            Spacer()
            if state == .checking { ProgressView().controlSize(.mini) }
            Text(T(state == .ready ? "settings.export.ready" : state == .checking ? "settings.export.checking"
                   : state == .signedOut ? "settings.export.not_logged" : "settings.export.not_set_up"))
                .foregroundStyle(.secondary)
            if let f = fix { CommandText(text: f) }
        }
        .help(tip ?? "")
    }
}
