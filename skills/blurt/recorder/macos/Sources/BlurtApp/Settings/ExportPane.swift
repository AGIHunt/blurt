// Settings → Export: where confirmed items go by default — per project (<repo>/.blurt/config.json → export, the same
// key the skill's exporters read; SKILL reference/export-*.md), or globally for ~/Blurt (config export). Shows whether
// each exporter's tool is ready (lark-cli / a Feishu app, gh) without ever showing a credential.
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
    @Published var checking = false
    let ws = currentWorkspace()

    var isProject: Bool { !isDefaultWorkspace(ws) }
    private var section: [String: Any] {
        isProject ? (ProjectConfig.read(ws)["export"] as? [String: Any] ?? [:]) : (Config.shared["export"] as? [String: Any] ?? [:])
    }

    func load() async {
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
        if isProject { ProjectConfig.set(ws, "export", key, value) } else { Config.shared.set("export.\(key)", value) }
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
                    Text("Markdown + CSV").tag("local")
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
                Hint(m.isProject ? T("settings.export.blurt_config_json_shared", "\(m.ws.lastPathComponent)")
                                 : T("settings.export.default_workspace_blurt"))
            } header: { Text(T("settings.export.default_destination")) }

            Section {
                tool(T("settings.export.feishu_lark_cli"), ok: m.lark != nil,
                     detail: m.lark.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? T("settings.export.not_installed_exports_as"),
                     fix: m.lark == nil ? "npx @larksuite/cli@latest install" : nil)
                tool(T("settings.export.feishu_self_built_app"), ok: m.feishuApp,
                     detail: m.feishuApp ? T("settings.export.feishu_app_id_set") : T("settings.export.optional_used_without_lark"), fix: nil)
                tool("GitHub: gh", ok: m.gh != nil && m.ghAuthed == true,
                     detail: m.gh == nil ? T("settings.export.not_installed") : (m.ghAuthed == true ? T("settings.export.logged") : T("settings.export.not_logged")),
                     fix: m.gh == nil ? "brew install gh" : (m.ghAuthed == false ? "gh auth login" : nil))
                tool("Markdown + CSV", ok: true, detail: T("settings.export.nothing_install"), fix: nil)
            } header: {
                HStack { Text(T("settings.export.exporters")); Spacer(); if m.checking { ProgressView().controlSize(.mini) } }
            } footer: {
                Text(T("settings.export.exports_run_from_review"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await m.load() }
    }

    func tool(_ name: String, ok: Bool, detail: String, fix: String?) -> some View {
        HStack {
            StatusDot(tone: ok ? .good : .off)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let f = fix { CommandText(text: f) }
        }
    }
}
