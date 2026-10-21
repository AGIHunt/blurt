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
        p.prompt = L("选择", "Choose")
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
                Picker(L("确认后的条目导出到", "Send confirmed items to"), selection: Binding(get: { m.target }, set: { m.setTarget($0) })) {
                    Text(L("每次问我", "Ask each time")).tag("ask")
                    Text(L("飞书多维表格", "Feishu / Lark Bitable")).tag("feishu")
                    Text("GitHub Issues").tag("github")
                    Text("Markdown + CSV").tag("local")
                }
                if m.target == "feishu" {
                    TextField(L("表格链接", "Table URL"), text: $m.url, prompt: Text("https://….feishu.cn/base/…?table=…"))
                        .onSubmit { m.commitURL() }
                    Hint(L("在浏览器里打开那张表，复制地址栏。列按含义自动对应，缺的列会自动建。", "Open the table in the browser and copy the address. Columns are matched by meaning; missing ones are created."))
                }
                if m.target == "local" {
                    HStack {
                        Text(L("保存到", "Save to"))
                        Spacer()
                        Text(m.outDir.isEmpty ? L("会话文件夹里", "the session's folder") : (m.outDir as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                        Button(L("选择…", "Choose…")) { m.chooseOut() }
                    }
                }
                Hint(m.isProject ? L("这是 \(m.ws.lastPathComponent) 的设置（.blurt/config.json），团队共用。", "For \(m.ws.lastPathComponent) (.blurt/config.json), shared with your team.")
                                 : L("这是默认工作区 ~/Blurt 的设置。", "For the default workspace ~/Blurt."))
            } header: { Text(L("默认去向", "Default destination")) }

            Section {
                tool(L("飞书：lark-cli", "Feishu: lark-cli"), ok: m.lark != nil,
                     detail: m.lark.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? L("没装 — 用自己的身份导出，不用建应用", "not installed — exports as you, no app needed"),
                     fix: m.lark == nil ? "npx @larksuite/cli@latest install" : nil)
                tool(L("飞书：自建应用", "Feishu: a self-built app"), ok: m.feishuApp,
                     detail: m.feishuApp ? L("FEISHU_APP_ID 已设置", "FEISHU_APP_ID is set") : L("可选；没装 lark-cli 时用", "optional; used without lark-cli"), fix: nil)
                tool("GitHub: gh", ok: m.gh != nil && m.ghAuthed == true,
                     detail: m.gh == nil ? L("没装", "not installed") : (m.ghAuthed == true ? L("已登录", "logged in") : L("没登录", "not logged in")),
                     fix: m.gh == nil ? "brew install gh" : (m.ghAuthed == false ? "gh auth login" : nil))
                tool("Markdown + CSV", ok: true, detail: L("不需要任何工具", "nothing to install"), fix: nil)
            } header: {
                HStack { Text(L("导出工具", "Exporters")); Spacer(); if m.checking { ProgressView().controlSize(.mini) } }
            } footer: {
                Text(L("导出由 agent 或审核页完成；重复导出不会建重复的记录。", "Exports run from the review page or your agent; re-exporting never creates duplicates."))
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
