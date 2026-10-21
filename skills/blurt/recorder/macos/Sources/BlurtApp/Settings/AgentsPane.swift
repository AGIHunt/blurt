// Settings → Agents: which coding agents process recordings and fix items, in what order (record.agents — drag to
// reorder, untick to leave one out), each one's state with the reason and the command that fixes it (agents.py detect),
// installing the blurt skill + MCP server into an agent (agents.py install: a --dry-run preview first, applied only
// after the user confirms), a per-project override, and a test run. Agents without a headless mode (ZCode) are listed
// apart: skill + MCP only, set up by hand.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class AgentsModel: ObservableObject {
    static let shared = AgentsModel()

    @Published var rows: [CoreAgent] = []
    @Published var enabled = Set<String>()
    @Published var pick: String?
    @Published var loading = false
    @Published var error: String?
    @Published var plan: (agent: CoreAgent, plan: InstallPlan, applied: Bool)?
    @Published var installing: String?
    @Published var testing: String?
    @Published var tests: [String: (ok: Bool, text: String)] = [:]
    @Published var projectAgent: String = ""

    var headless: [CoreAgent] { rows.filter(\.headless) }
    var manual: [CoreAgent] { rows.filter { !$0.headless } }
    var project: URL? { let w = currentWorkspace(); return isDefaultWorkspace(w) ? nil : w }

    func load(login: Bool = true) async {
        loading = true
        defer { loading = false }
        do {
            let d = try await Agents.shared.detectAll(login: login)
            rows = d.agents
            pick = d.pick
            enabled = Set(Agents.shared.order ?? d.agents.filter(\.headless).map(\.id))
            if enabled.isEmpty { enabled = Set(d.order) }
            error = nil
        } catch { self.error = "\(error)" }
        if let p = project { projectAgent = ((ProjectConfig.read(p)["record"] as? [String: Any])?["agents"] as? [String])?.first ?? "" }
    }

    /// record.agents = the ticked headless agents in the shown order.
    func save() {
        let ids = headless.map(\.id).filter { enabled.contains($0) }
        Agents.shared.order = ids.isEmpty ? nil : ids
        Task { await load(login: false) }
    }

    func move(from: IndexSet, to: Int) {
        var h = headless
        h.move(fromOffsets: from, toOffset: to)
        rows = h + manual
        save()
    }
    func moveUp(_ id: String) {
        guard let i = headless.firstIndex(where: { $0.id == id }), i > 0 else { return }
        move(from: IndexSet(integer: i), to: i - 1)
    }
    func toggle(_ id: String, _ on: Bool) {
        if on { enabled.insert(id) } else { enabled.remove(id) }
        save()
    }

    func setProjectAgent(_ id: String) {
        guard let p = project else { return }
        projectAgent = id
        ProjectConfig.set(p, "record", "agents", id.isEmpty ? nil : [id])
    }

    /// Step 1: the preview. Nothing is written.
    func preview(_ a: CoreAgent) async {
        installing = a.id
        defer { installing = nil }
        do {
            let p = try await Agents.shared.install(a.id, dryRun: true)
            plan = (a, p, false)
            emit(["event": "install_preview", "agent": a.id, "changes": p.changes.map(\.summary)])
        } catch { self.error = "\(error)" }
    }

    /// Step 2, after the user said yes.
    func apply() async {
        guard let cur = plan else { return }
        installing = cur.agent.id
        defer { installing = nil }
        do {
            let p = try await Agents.shared.install(cur.agent.id, dryRun: false)
            plan = (cur.agent, p, true)
            emit(["event": "install_applied", "agent": cur.agent.id, "applied": p.applied])
        } catch { self.error = "\(error)" }
    }

    /// One tiny headless prompt through the agent's real command line: proves it runs and is logged in (costs a
    /// few tokens).
    func test(_ a: CoreAgent) async {
        testing = a.id
        defer { testing = nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-agent-test")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            let c = try await Agents.shared.command(a.id, mode: "headless", prompt: "Reply with exactly the word: ok", repo: tmp, events: false)
            guard let argv = c.argv, let exe = argv.first else { tests[a.id] = (false, L("没有 headless 命令", "no headless command")); return }
            let env = SkillCLI.shared.environment().merging(c.env) { _, n in n }
            let t0 = Date()
            let r = await Task.detached { ShellEnv.runCapture(exe, Array(argv.dropFirst()), env: env, timeout: 120) }.value
            let out = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let secs = Date().timeIntervalSince(t0)
            if r.status == 0, out.lowercased().contains("ok") {
                tests[a.id] = (true, String(format: L("能用，%.1f 秒回复", "Works — replied in %.1f s"), secs))
            } else {
                tests[a.id] = (false, (r.status == nil ? L("超时", "timed out") : L("退出码 \(r.status!)", "exit \(r.status!)")) + " · " + String(out.suffix(160)))
            }
        } catch { tests[a.id] = (false, "\(error)") }
    }
}

struct AgentsPane: View {
    @ObservedObject var m = AgentsModel.shared

    var body: some View {
        PaneFrame {
            Section {
                ForEach(m.headless) { a in agentRow(a, ordered: true) }
                    .onMove { m.move(from: $0, to: $1) }
            } header: {
                HStack {
                    Text(L("整理和修复用的 agent（按顺序试）", "Agents for processing and fixing (tried in order)"))
                    Spacer()
                    if m.loading { ProgressView().controlSize(.mini) }
                    Button { Task { await m.load() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                        .help(L("重新检查", "Check again"))
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("拖动调整顺序；第一个能用的来干活，没登录、额度用完时自动换下一个。取消勾选的不会被用到。",
                           "Drag to reorder. The first usable one runs; on a login / quota problem the next one takes over. Unticked agents are never used."))
                    if let e = m.error { Text(e).foregroundStyle(.orange) }
                }.font(.caption).foregroundStyle(.secondary)
            }

            if !m.manual.isEmpty {
                Section {
                    ForEach(m.manual) { a in agentRow(a, ordered: false) }
                } header: { Text(L("只接 skill + MCP", "Skill + MCP only")) } footer: {
                    Text(L("这些没有命令行，不会后台运行；在它们自己的设置里导入 blurt skill 和 MCP 一次即可，「让 agent 修」会复制提示词。",
                           "No command line, so they never run in the background. Import the blurt skill and MCP once in their own settings; “Fix with an agent” copies the prompt for them."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let p = m.project {
                Section {
                    Picker(L("这个项目用", "This project uses"), selection: Binding(get: { m.projectAgent }, set: { m.setProjectAgent($0) })) {
                        Text(L("跟随上面的顺序", "The order above")).tag("")
                        ForEach(m.headless) { Text($0.name).tag($0.id) }
                    }
                    Hint(L("写在 \(p.lastPathComponent)/.blurt/config.json，团队成员共用。", "Saved in \(p.lastPathComponent)/.blurt/config.json, shared with your team."))
                } header: { Text(L("项目：", "Project: ") + p.lastPathComponent) }
            }
        }
        .task { await m.load() }
        .sheet(isPresented: Binding(get: { m.plan != nil }, set: { if !$0 { m.plan = nil } })) {
            if let p = m.plan { InstallSheet(m: m, agent: p.agent, plan: p.plan, applied: p.applied) }
        }
    }

    func tone(_ a: CoreAgent) -> Tone {
        switch a.state {
        case "ready": return .good
        case "configured", "unknown": return a.installed ? .warn : .off
        case "logged_out": return .bad
        default: return .off
        }
    }

    @ViewBuilder
    func agentRow(_ a: CoreAgent, ordered: Bool) -> some View {
        let on = m.enabled.contains(a.id)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if ordered {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help(L("拖动排序", "Drag to reorder"))
                    Toggle("", isOn: Binding(get: { on }, set: { m.toggle(a.id, $0) })).labelsHidden().toggleStyle(.checkbox)
                }
                StatusDot(tone: tone(a))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(a.name).fontWeight(.medium).foregroundStyle(on || !ordered ? .primary : .secondary)
                        if let v = a.version { Text(shortVersion(v)).font(.caption).foregroundStyle(.tertiary) }
                        if ordered && a.id == m.pick { Text(L("当前首选", "Runs first")).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18))) }
                    }
                    Text(stateText(a)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if a.installed || !a.headless {
                    if m.installing == a.id { ProgressView().controlSize(.small) }
                    else {
                        Button(L("安装 skill + MCP…", "Install skill + MCP…")) { Task { await m.preview(a) } }.controlSize(.small)
                    }
                }
                if a.headless && a.installed {
                    if m.testing == a.id { ProgressView().controlSize(.small) }
                    else { Button(L("测试", "Test")) { Task { await m.test(a) } }.controlSize(.small).help(L("发一句极短的提示词，确认能跑（花很少的 token）", "Sends a one-line prompt to check it runs (a few tokens)")) }
                }
            }
            if !a.fix.isEmpty {
                HStack(spacing: 6) {
                    Text(a.installed ? L("修复：", "Fix:") : L("安装：", "Install:")).font(.caption).foregroundStyle(.secondary)
                    if looksLikeCommand(a.fix) { CommandText(text: commandPart(a.fix)) }
                    else { Text(a.fix).font(.caption).textSelection(.enabled) }
                }.padding(.leading, ordered ? 44 : 17)
            }
            if let t = m.tests[a.id] {
                Label(t.text, systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(t.ok ? .green : .red).padding(.leading, ordered ? 44 : 17)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if ordered { Button(L("往前挪", "Move up")) { m.moveUp(a.id) } }
        }
    }

    func stateText(_ a: CoreAgent) -> String {
        if !a.headless { return a.installed ? L("已安装 · 手动接入", "installed · set up by hand") : L("没安装", "not installed") }
        if a.why.isEmpty {
            switch a.state {
            case "not_installed": return L("没安装", "not installed")
            case "ready": return L("已登录", "logged in")
            default: return a.state
            }
        }
        return a.why
    }

    /// a `command` in backticks, or a bare install line ("npm i -g …") — not prose like "在终端运行 claude，然后输入 /login"
    func looksLikeCommand(_ s: String) -> Bool {
        s.contains("`") || ["npm ", "curl ", "brew ", "pip ", "uv ", "npx "].contains { s.hasPrefix($0) }
    }

    /// "run `codex login` in a terminal" → "codex login"; plain commands stay as they are.
    func commandPart(_ s: String) -> String {
        if let r = s.range(of: "`[^`]+`", options: .regularExpression) { return String(s[r].dropFirst().dropLast()) }
        return s
    }
}

struct InstallSheet: View {
    @ObservedObject var m: AgentsModel
    var agent: CoreAgent
    var plan: InstallPlan
    var applied: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(applied ? L("已安装到 \(agent.name)", "Installed into \(agent.name)") : L("把 blurt 装进 \(agent.name)", "Install blurt into \(agent.name)"))
                .font(.headline)
            Text(applied ? L("结果：", "Result:") : L("会做这些改动（还没改任何东西）：", "These changes will be made (nothing has changed yet):"))
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(plan.changes.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: icon(c)).foregroundStyle(color(c))
                        Text(c.summary).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let e = c.error { Text(e).font(.caption).foregroundStyle(.red).padding(.leading, 22) }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            HStack {
                if m.installing != nil { ProgressView().controlSize(.small) }
                Spacer()
                if applied {
                    Button(L("好", "Done")) { m.plan = nil; Task { await m.load() } }.keyboardShortcut(.defaultAction)
                } else {
                    Button(L("取消", "Cancel")) { m.plan = nil }.keyboardShortcut(.cancelAction)
                    Button(L("安装", "Install")) { Task { await m.apply() } }.keyboardShortcut(.defaultAction)
                        .disabled(!plan.changes.contains(where: \.changesSomething) || m.installing != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    func icon(_ c: InstallChange) -> String {
        if c.ok == false || c.action == "error" { return "xmark.octagon.fill" }
        switch c.action {
        case "exists": return "checkmark.circle"
        case "conflict", "manual": return "exclamationmark.triangle"
        default: return applied ? "checkmark.circle.fill" : "plus.circle"
        }
    }
    func color(_ c: InstallChange) -> Color {
        if c.ok == false || c.action == "error" { return .red }
        switch c.action {
        case "conflict", "manual": return .orange
        case "exists": return .secondary
        default: return applied ? .green : .accentColor
        }
    }
}

/// "2.1.259 (Claude Code)" / "codex-cli 0.157.0" → "2.1.259" / "0.157.0"
func shortVersion(_ v: String) -> String {
    if let r = v.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) { return String(v[r]) }
    return String(v.prefix(16))
}
