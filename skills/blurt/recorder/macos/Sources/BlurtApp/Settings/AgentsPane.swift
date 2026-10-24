// Settings → Agents: which coding agents process recordings (record.agents, in order — drag to reorder, untick to
// leave one out) and which can run in Blurt's sessions (sessions.py doctor), each one's state with the reason and the
// command that fixes it (agents.py detect); installing the blurt skill + MCP server into an agent (agents.py install:
// a --dry-run preview first, applied only after the user confirms); the current project's default agent for sessions
// (projects.json default_agent); a test run. Agents without a command line (ZCode) are listed apart.
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
    @Published var doctor: SessionsDoctor?
    @Published var projectAgent: String = ""
    /// Each installed agent's models (agents.py models), for "Model for organizing".
    @Published var models: [String: AgentModels] = [:]

    var headless: [CoreAgent] { rows.filter(\.headless) }
    var manual: [CoreAgent] { rows.filter { !$0.headless } }
    var project: Project? { ProjectStore.shared.current }
    func sessions(_ a: CoreAgent) -> Bool { doctor?.agents[a.id] ?? false }

    func load(login: Bool = true) async {
        loading = true
        defer { loading = false }
        async let doc = try? AgentSessions.shared.doctor()
        do {
            let d = try await Agents.shared.detectAll(login: login)
            var fresh = d.agents
            if !login {
                // a quick re-read (after a reorder or a tick) can't tell who is logged in: keep what the last full
                // check found, or every row turns into "unknown"
                let known = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for i in fresh.indices {
                    guard let old = known[fresh[i].id], old.installed == fresh[i].installed, old.state != "unknown" else { continue }
                    fresh[i].state = old.state
                    fresh[i].why = old.why
                    fresh[i].fix = old.fix
                    fresh[i].login = old.login
                }
            }
            rows = fresh
            // the first usable one in the shown order (the same rule as agents.py detect)
            let order = d.order
            pick = ["ready", "configured", "unknown"].lazy.compactMap { want in
                order.first { id in fresh.contains { $0.id == id && $0.headless && $0.state == want } }
            }.first ?? d.pick
            enabled = Set(Agents.shared.order ?? d.agents.filter(\.headless).map(\.id))
            if enabled.isEmpty { enabled = Set(d.order) }
            error = nil
        } catch { self.error = "\(error)" }
        doctor = await doc
        projectAgent = project?.defaultAgent ?? ""
        for a in rows where a.headless && a.installed {
            if let m = try? await Agents.shared.models(a.id), !m.models.isEmpty { models[a.id] = m }
        }
    }

    /// "cheapest" (agents.json's default for organizing) | "default" (the CLI's own setting) | a model id.
    func processingModel(_ id: String) -> String { Agents.shared.processingSetting(id).model ?? "cheapest" }
    func processingEffort(_ id: String) -> String { Agents.shared.processingSetting(id).effort ?? "low" }

    func setProcessing(_ id: String, model: String? = nil, effort: String? = nil) {
        let cur = Agents.shared.processingSetting(id)
        let m = model ?? cur.model, e = effort ?? cur.effort
        // the shipped defaults (cheapest, low) are stored as nothing, so a better default later reaches everyone
        Agents.shared.setProcessing(id, model: m == "cheapest" ? nil : m, effort: e == "low" ? nil : e)
        emit(["event": "processing_model", "agent": id, "model": m ?? "cheapest", "effort": e ?? "low"])
        objectWillChange.send()
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
        Task {
            do { try await ProjectStore.shared.update(p.id, ["default_agent": id.isEmpty ? NSNull() : id]) }
            catch { self.error = "\(error)" }
        }
    }

    /// Step 1: the preview. Nothing is written.
    func preview(_ a: CoreAgent) async {
        installing = a.id
        defer { installing = nil }
        do {
            let p = try await Agents.shared.install(a.id, dryRun: true)
            plan = (a, p, false)
            emit(["event": "install_preview", "agent": a.id, "changes": p.changes.map(InstallSheet.summary)])
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
            guard let argv = c.argv, let exe = argv.first else { tests[a.id] = (false, TL("agents.test.no_command")); return }
            let env = SkillCLI.shared.environment().merging(c.env) { _, n in n }
            let t0 = Date()
            let r = await Task.detached { ShellEnv.runCapture(exe, Array(argv.dropFirst()), env: env, timeout: 120) }.value
            let out = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let secs = Date().timeIntervalSince(t0)
            if r.status == 0, out.lowercased().contains("ok") {
                let f = NumberFormatter()
                f.locale = Loc.locale
                f.maximumFractionDigits = 1
                f.minimumFractionDigits = 1
                tests[a.id] = (true, TL("agents.test.ok", f.string(from: secs as NSNumber) ?? "\(secs)"))
            } else {
                let why = r.status.map { TL("agents.test.exit", Int($0)) } ?? TL("agents.test.timeout")
                tests[a.id] = (false, why + " · " + String(out.suffix(160)))
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
                    Text(TL("agents.header"))
                    Spacer()
                    if m.loading { ProgressView().controlSize(.mini) }
                    Button { Task { await m.load() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                        .help(TL("agents.check_again")).accessibilityLabel(TL("agents.check_again"))
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(TL("agents.footer"))
                    if let e = m.error { Text(e).foregroundStyle(Color.brandErr) }
                }.font(.caption).foregroundStyle(.secondary)
            }

            sessionsSection

            if !m.manual.isEmpty {
                Section {
                    ForEach(m.manual) { a in agentRow(a, ordered: false) }
                } header: { Text(TL("agents.manual.header")) } footer: {
                    Text(TL("agents.manual.footer")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { await m.load() }
        .sheet(isPresented: Binding(get: { m.plan != nil }, set: { if !$0 { m.plan = nil } })) {
            if let p = m.plan { InstallSheet(m: m, agent: p.agent, plan: p.plan, applied: p.applied) }
        }
    }

    @ViewBuilder
    var sessionsSection: some View {
        Section {
            HStack(spacing: 8) {
                StatusDot(tone: AgentSessions.shared.tmuxAvailable ? .good : .warn)
                VStack(alignment: .leading, spacing: 1) {
                    if let v = AgentSessions.shared.tmuxVersion, AgentSessions.shared.tmuxAvailable {
                        Text(TL("agents.tmux.ok", v)).fontWeight(.medium)
                        Text(TL("agents.tmux.ok.detail")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(TL(AgentSessions.shared.tmuxPath == nil ? "agents.tmux.missing" : "agents.tmux.old")).fontWeight(.medium)
                        Text(TL("agents.tmux.missing.detail")).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if !AgentSessions.shared.tmuxAvailable {
                    CommandText(text: "brew install tmux")
                    Button { AgentSessions.shared.refreshTmux(); Task { await m.load(login: false) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(TL("agents.check_again")).accessibilityLabel(TL("agents.check_again"))
                }
            }
            if let p = m.project {
                Picker(TL("agents.project_agent", p.name), selection: Binding(get: { m.projectAgent }, set: { m.setProjectAgent($0) })) {
                    Text(TL("agents.project_agent.default")).tag("")
                    ForEach(m.rows.filter { m.sessions($0) && $0.installed }) { Text($0.name).tag($0.id) }
                }
                Hint(TL("agents.project_agent.hint"))
            }
        } header: { Text(TL("agents.sessions.header")) }
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
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help(TL("agents.drag"))
                    Toggle("", isOn: Binding(get: { on }, set: { m.toggle(a.id, $0) })).labelsHidden().toggleStyle(.checkbox)
                }
                StatusDot(tone: tone(a))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(a.name).fontWeight(.medium).foregroundStyle(on || !ordered ? .primary : .secondary)
                        if let v = a.version { Text(shortVersion(v)).font(.caption).foregroundStyle(.tertiary) }
                        if ordered && a.id == m.pick { badge(TL("agents.runs_first"), nil) }
                        if a.installed && m.sessions(a) {
                            badge(TL("agents.sessions_badge"), Color.secondary).help(TL("agents.sessions_badge.help"))
                        }
                    }
                    Text(stateText(a)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if a.installed || !a.headless {
                    if m.installing == a.id { ProgressView().controlSize(.small) }
                    else { Button(TL("agents.install")) { Task { await m.preview(a) } }.controlSize(.small) }
                }
                if a.headless && a.installed {
                    if m.testing == a.id { ProgressView().controlSize(.small) }
                    else { Button(TL("agents.test")) { Task { await m.test(a) } }.controlSize(.small).help(TL("agents.test.help")) }
                }
            }
            if !a.fix.isEmpty {
                HStack(spacing: 6) {
                    Text(TL(a.installed ? "agents.fix" : "agents.install_hint")).font(.caption).foregroundStyle(.secondary)
                    if looksLikeCommand(a.fix) { CommandText(text: commandPart(a.fix)) }
                    else { Text(a.fix).font(.caption).textSelection(.enabled) }
                }.padding(.leading, ordered ? 44 : 17)
            }
            if ordered, a.installed, let ms = m.models[a.id] { processingRow(a, ms) }
            if a.id == "codex" && a.installed {
                Text(TL("agents.codex_trust")).font(.caption).foregroundStyle(.tertiary).padding(.leading, ordered ? 44 : 17)
            }
            if let t = m.tests[a.id] {
                Label(t.text, systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(t.ok ? Color.brandOk : Color.brandErr).padding(.leading, ordered ? 44 : 17)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if ordered { Button(TL("agents.move_up")) { m.moveUp(a.id) } }
        }
    }

    /// "Model for organizing": what recordings, Organize, Let AI sort and AI fill-in run with — a small model at low
    /// effort is plenty and costs a fraction of the tokens.
    @ViewBuilder
    func processingRow(_ a: CoreAgent, _ ms: AgentModels) -> some View {
        HStack(spacing: 8) {
            Text(TL("agents.processing")).font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { m.processingModel(a.id) }, set: { m.setProcessing(a.id, model: $0) })) {
                Text(ms.cheapest.map { c in TL("agents.processing.cheapest_named", ms.models.first { $0.id == c }?.name ?? c) }
                     ?? TL("agents.processing.cheapest")).tag("cheapest")
                Text(ms.cliDefault.map { TL("agents.processing.default_named", $0) } ?? TL("agents.processing.default")).tag("default")
                Divider()
                ForEach(ms.models) { x in Text(x.name).tag(x.id) }
            }
            .labelsHidden().fixedSize().controlSize(.small)
            .accessibilityLabel(TL("agents.processing"))
            if !ms.efforts.isEmpty {
                Picker("", selection: Binding(get: { m.processingEffort(a.id) }, set: { m.setProcessing(a.id, effort: $0) })) {
                    Text(TL("agents.effort.default")).tag("default")
                    Divider()
                    ForEach(ms.efforts, id: \.self) { e in Text(TL("agents.effort.\(e)")).tag(e) }
                }
                .labelsHidden().fixedSize().controlSize(.small)
                .accessibilityLabel(TL("agents.effort"))
            }
        }
        .padding(.leading, 44)
        .help(TL("agents.processing.help"))
    }

    /// `c` nil: the brand badge ("Runs first"), brand ink on the brand tint (§3.4)
    func badge(_ s: String, _ c: Color?) -> some View {
        Text(s).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(c == nil ? Color.brandInk : Color.primary)
            .background(Capsule().fill(c.map { $0.opacity(0.16) } ?? Color.brandTint))
    }

    func stateText(_ a: CoreAgent) -> String {
        if !a.headless { return TL(a.installed ? "agents.state.manual" : "agents.state.not_installed") }
        if a.why.isEmpty {
            switch a.state {
            case "not_installed": return TL("agents.state.not_installed")
            case "ready": return TL("agents.state.ready")
            default: return a.state
            }
        }
        return a.why
    }

    /// a `command` in backticks, or a bare install line ("npm i -g …") — not prose like "run claude, then /login"
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

    /// One line per change for the confirmation sheet.
    static func summary(_ c: InstallChange) -> String {
        switch c.action {
        case "symlink": return TL("install.symlink", c.path ?? "", c.target ?? "")
        case "exists": return TL("install.exists", c.path ?? c.argv?.joined(separator: " ") ?? "")
        case "conflict": return TL("install.conflict", c.path ?? "", c.pointsTo ?? "?")
        case "run": return TL("install.run", (c.argv ?? []).joined(separator: " "))
        case "json_merge": return TL("install.json_merge", (c.key ?? []).joined(separator: "."), c.path ?? "")
        case "manual": return TL("install.manual", c.what ?? "", c.how ?? "")
        default: return "\(c.action): \(c.error ?? c.path ?? "")"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TL(applied ? "install.title.applied" : "install.title", agent.name)).font(.headline)
            Text(TL(applied ? "install.result" : "install.preview")).font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(plan.changes.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: icon(c)).foregroundStyle(color(c))
                        Text(Self.summary(c)).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let e = c.error { Text(e).font(.caption).foregroundStyle(Color.brandErr).padding(.leading, 22) }
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
                    Button(TL("common.done")) { m.plan = nil; Task { await m.load() } }.keyboardShortcut(.defaultAction)
                } else {
                    Button(TL("common.cancel")) { m.plan = nil }.keyboardShortcut(.cancelAction)
                    Button(TL("install.confirm")) { Task { await m.apply() } }.keyboardShortcut(.defaultAction)
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
        if c.ok == false || c.action == "error" { return .brandErr }
        switch c.action {
        case "conflict", "manual": return .brandAttn
        case "exists": return .secondary
        default: return applied ? .brandOk : .brandInk
        }
    }
}

extension InstallChange {
    /// The localized one-liner (Settings → Agents, the self-test channel).
    var summary: String { InstallSheet.summary(self) }
}

/// "2.1.259 (Claude Code)" / "codex-cli 0.157.0" → "2.1.259" / "0.157.0"
func shortVersion(_ v: String) -> String {
    if let r = v.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) { return String(v[r]) }
    return String(v.prefix(16))
}
