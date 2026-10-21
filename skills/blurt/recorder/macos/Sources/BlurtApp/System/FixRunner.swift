// "Let the agent fix" (AppEnvironment.fixWithAgent, ⌘↩ in the main window): a small panel to pick the agent and how —
//   • in the background: agents.py command <id> headless → the app runs the argv in the item's repo, shows the
//     agent's progress (parsed stream-json / jsonl), and the run record goes to $BLURT_HOME/runs/;
//   • interactive: Claude's claude-cli://open deep link (prompt pre-filled, nothing runs until the user sends it),
//     a Terminal window running codex "<prompt>", or the prompt on the clipboard (Kimi, ZCode).
// The prompt comes from `agents.py prompt fix` (one wording for every host). The app marks the items "fixing" with
// this run's id before starting; the agent marks them fixed itself (MCP mark_fixed / items.py fix) — FixWatcher sees
// that and the chicken pecks the bug. Background fixes never commit or push.
import AppKit
import SwiftUI
import UserNotifications
import BlurtCore

@MainActor
final class FixSession: ObservableObject {
    enum Phase: Equatable { case choosing, preparing, running, finished(Int32), interactiveDone(String), failed(String) }

    let uids: [String]
    let items: [IndexedItem]
    @Published var agents: [CoreAgent] = []
    @Published var agent: String = ""
    @Published var background = true
    @Published var phase: Phase = .choosing
    @Published var lines: [ProgressLine] = []
    @Published var started: Date?
    @Published var fixed = Set<String>()
    @Published var detecting = true
    var run: AgentRun?
    var prompt: FixPrompt?

    init(uids: [String]) {
        self.uids = uids
        items = uids.compactMap { IndexLookup.item(uid: $0) }
        background = (Config.shared["fix.mode"] as? String ?? "background") != "interactive"
    }

    var repoName: String { (prompt?.repo ?? items.first?.workspacePath ?? "").split(separator: "/").last.map(String.init) ?? "" }
    var selected: CoreAgent? { agents.first { $0.id == agent } }
    var canBackground: Bool { selected?.headless == true && selected?.usable == true }
    var canInteractive: Bool { selected?.interactive != nil && (selected?.installed ?? false || selected?.interactive == "copy") }

    func load() async {
        detecting = true
        defer { detecting = false }
        guard let d = try? await Agents.shared.detectAll() else { return }
        agents = d.agents.filter { $0.installed || $0.interactive == "copy" }
        let saved = Config.shared["fix.agent"] as? String
        agent = [saved, d.pick, agents.first(where: \.usable)?.id, agents.first?.id].compactMap { $0 }
            .first { id in agents.contains { $0.id == id } } ?? ""
        if !canBackground { background = false }
    }

    func start() async {
        guard let a = selected else { return }
        Config.shared.set("fix.agent", a.id)
        Config.shared.set("fix.mode", background ? "background" : "interactive")
        phase = .preparing
        do {
            let p = try await Agents.shared.fixPrompt(uids)
            prompt = p
            let repo = URL(fileURLWithPath: p.repo)
            if background {
                let runID = AgentRun.newID()
                for it in items {   // the panel and the main window show "fixing" right away; the agent's own mark is the same state
                    _ = try? await SkillCLI.shared.run("items.py", ["fix", it.sessionDir, it.uid, "--state", "fixing",
                                                                    "--agent", a.id, "--run-id", runID], timeout: 30)
                }
                let r = try await Agents.shared.run(a.id, prompt: p.prompt, repo: repo, items: uids, runID: runID)
                run = r
                started = Date()
                phase = .running
                emit(["event": "fix_run", "run_id": r.id, "agent": a.id, "repo": repo.path, "items": uids])
                r.onProgress = { [weak self] s in
                    self?.lines.append(s)
                    if (self?.lines.count ?? 0) > 400 { self?.lines.removeFirst(100) }
                }
                r.onExit = { [weak self] st in
                    guard let self = self else { return }
                    self.phase = .finished(st)
                    for it in self.items { FixWatcher.shared.check(URL(fileURLWithPath: it.sessionDir).appendingPathComponent("items.json").path) }
                    emit(["event": "fix_run_end", "run_id": r.id, "exit": Int(st), "cost_usd": r.costUSD ?? 0])
                }
            } else {
                let c = try await Agents.shared.interactive(a.id, prompt: p.prompt, repo: repo)
                let what = FixRunner.perform(c, name: a.name)
                phase = .interactiveDone(what)
            }
        } catch {
            phase = .failed("\(error)")
        }
    }

    func stop() { run?.cancel() }
}

struct FixView: View {
    @ObservedObject var s: FixSession
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                UIIcon.bug.view.frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.items.count == 1 ? L("让 agent 修这一条", "Let an agent fix this") : L("让 agent 修 \(s.items.count) 条", "Let an agent fix \(s.items.count) items"))
                        .font(.headline)
                    Text(s.items.map(\.title).joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            switch s.phase {
            case .choosing, .preparing: chooser
            case .running, .finished: progress
            case .interactiveDone(let what):
                Label(what, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                HStack { Spacer(); Button(L("好", "Done"), action: close).keyboardShortcut(.defaultAction) }
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled)
                HStack { Spacer(); Button(L("关闭", "Close"), action: close) }
            }
        }
        .padding(18)
        .frame(width: 460)
        .task { await s.load() }
    }

    var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("Agent", "Agent"), selection: $s.agent) {
                ForEach(s.agents) { a in
                    Text(a.name + (a.usable ? "" : "  — " + (a.why.isEmpty ? a.state : a.why))).tag(a.id)
                }
            }
            .disabled(s.detecting)
            Picker(L("方式", "How"), selection: $s.background) {
                Text(L("后台运行", "In the background")).tag(true)
                Text(interactiveLabel).tag(false)
            }
            .pickerStyle(.segmented)
            Text(s.background
                 ? L("在 \(s.repoName.isEmpty ? "项目" : s.repoName) 里无人值守地修改代码，不提交、不推送；修好后条目标成已修。",
                     "Edits the code in \(s.repoName.isEmpty ? "the project" : s.repoName) unattended — no commits, no pushes; items are marked fixed when done.")
                 : L("打开 agent，提示词已填好，由你确认后再开始。", "Opens the agent with the prompt filled in; nothing runs until you send it."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if s.detecting || s.phase == .preparing { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("取消", "Cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(s.background ? L("开始修复", "Start fixing") : L("打开", "Open")) { Task { await s.start() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(s.agent.isEmpty || s.phase == .preparing || (s.background ? !s.canBackground : !s.canInteractive))
            }
        }
    }

    var interactiveLabel: String {
        switch s.selected?.interactive {
        case "url": return L("在 \(s.selected?.name ?? "") 里打开", "Open in \(s.selected?.name ?? "")")
        case "terminal": return L("在终端里打开", "Open in Terminal")
        case "copy": return L("复制提示词", "Copy the prompt")
        default: return L("交互式", "Interactive")
        }
    }

    var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if case .running = s.phase { ProgressView().controlSize(.small) }
                if case .finished(let st) = s.phase {
                    (st == 0 ? UIIcon.ok : UIIcon.failed).view
                }
                Text(statusText).font(.callout.weight(.medium))
                Spacer()
                if let t = s.started {
                    TimelineView(.periodic(from: t, by: 1)) { ctx in
                        Text(Duration.seconds(Int((ctx.date).timeIntervalSince(t))).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(s.lines.suffix(200).enumerated()), id: \.offset) { i, l in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                UIIcon.forProgress(l.kind).view.font(.system(size: 10.5)).frame(width: 14)
                                Text(l.text)
                                    .font(l.kind == .say || l.kind == .done ? .system(size: 12) : .system(size: 11, design: .monospaced))
                                    .foregroundStyle(l.kind == .error ? Color.red : l.kind == .log ? Color.secondary : Color.primary)
                                    .lineLimit(l.kind == .log ? 1 : 4)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).id(i)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 170)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .onChange(of: s.lines.count) { _ in proxy.scrollTo(min(s.lines.count, 200) - 1, anchor: .bottom) }
            }
            HStack {
                if let r = s.run {
                    Button(L("查看日志", "Show log")) { NSWorkspace.shared.open(r.logURL) }
                    if let c = r.costUSD { Text(String(format: "$%.3f", c)).foregroundStyle(.secondary).font(.callout) }
                }
                Spacer()
                if case .running = s.phase {
                    Button(L("停止", "Stop")) { s.stop() }
                    Button(L("后台继续", "Hide")) { close() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(L("关闭", "Close"), action: close).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    var statusText: String {
        let name = s.selected?.name ?? s.agent
        switch s.phase {
        case .running: return L("\(name) 正在修…", "\(name) is fixing…")
        case .finished(let st):
            let n = s.items.filter { s.fixed.contains($0.uid) }.count
            if st == 0 { return n > 0 ? L("完成，\(n) 条已修", "Done — \(n) fixed") : L("\(name) 结束了", "\(name) finished") }
            return L("\(name) 退出（\(st)）", "\(name) exited (\(st))")
        default: return ""
        }
    }
}

final class FixRunner: NSObject, NSWindowDelegate {
    static let shared = FixRunner()
    private var windows: [NSWindow] = []
    private(set) var sessions: [FixSession] = []
    var windowNumber: Int? { windows.last?.windowNumber }

    @MainActor
    func start(_ uids: [String], autostart: (agent: String, background: Bool)? = nil) {
        guard !uids.isEmpty else { return }
        let s = FixSession(uids: uids)
        guard !s.items.isEmpty else {
            appDelegate?.toast(L("索引里找不到这些条目，先让索引更新一下", "Those items aren't in the index yet — try again in a moment"))
            return
        }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = L("让 agent 修", "Fix with an agent")
        w.isReleasedWhenClosed = false
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.delegate = self
        let host = NSHostingController(rootView: FixView(s: s, close: { [weak w] in w?.close() }))
        host.sizingOptions = [.preferredContentSize]
        w.contentViewController = host
        w.center()
        activateApp()
        w.makeKeyAndOrderFront(nil)
        windows.append(w)
        sessions.append(s)
        if let a = autostart {
            Task { @MainActor in
                await s.load()
                s.agent = a.agent
                s.background = a.background
                await s.start()
            }
        }
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let i = windows.firstIndex(of: w) else { return }
        windows.remove(at: i)
        // a background run keeps going; its record and the pecking don't need the panel
        let s = sessions.remove(at: i)
        _ = s
    }

    /// Carry out `agents.py command … interactive`. Returns what happened, for the panel.
    @MainActor
    static func perform(_ c: AgentCommand, name: String) -> String {
        var did: [String] = []
        if let text = c.clipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            did.append(L("提示词已复制", "prompt copied"))
        }
        if let u = c.url.flatMap(URL.init(string:)) {
            if NSWorkspace.shared.open(u) { did.append(L("已在 \(name) 里打开", "opened in \(name)")) }
            else { did.append(L("打不开 \(name) 的链接（装了吗？）", "couldn't open \(name)'s link (is it installed?)")) }
        } else if c.terminal, let argv = c.argv {
            openInTerminal(argv, cwd: c.cwd, env: c.env)
            did.append(L("已在终端里启动 \(name)", "started \(name) in Terminal"))
        }
        if let app = c.openApp {
            NSWorkspace.shared.open(URL(fileURLWithPath: app))
            did.append(L("已打开 \(name)，粘贴提示词即可", "opened \(name) — paste the prompt"))
        }
        return did.isEmpty ? L("没有可做的", "nothing to do") : did.joined(separator: L("，", ", "))
    }

    /// A .command file Terminal runs: cd to the repo, export the run's env, exec the agent (prompt as one argument).
    static func openInTerminal(_ argv: [String], cwd: String, env: [String: String]) {
        let dir = BlurtPaths.home.appendingPathComponent("prompts")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("fix-\(Int(Date().timeIntervalSince1970)).command")
        var s = "#!/bin/zsh -l\n# written by Blurt: let an agent fix items\ncd \(shq(cwd)) || exit 1\n"
        for (k, v) in env.sorted(by: { $0.key < $1.key }) { s += "export \(k)=\(shq(v))\n" }
        s += "rm -f \(shq(f.path))\nexec " + argv.map(shq).joined(separator: " ") + "\n"
        try? s.write(to: f, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.path)
        let term = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([f], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: the fixed moment

    func announceFixed(uid: String, item: [String: Any], session: URL) {
        let title = item["title"] as? String ?? uid
        let fix = item["fix"] as? [String: Any] ?? [:]
        let agent = fix["agent"] as? String
        let note = fix["note"] as? String ?? ""
        let detail = [agent.map { L("由 \($0) 修复", "by \($0)") }, note.isEmpty ? nil : note].compactMap { $0 }.joined(separator: " · ")
        PeckCard.shared.play(title: title, detail: detail, uid: uid)
        for s in sessions where s.uids.contains(uid) { Task { @MainActor in s.fixed.insert(uid) } }
        Notify.post(title: L("修好了：", "Fixed: ") + title, body: detail, uid: uid)
    }
}

/// System notifications — only once the user allowed them; never asked for in tests (non-default BLURT_HOME), where the
/// bundle id is shared with the real app.
enum Notify {
    static var allowed: Bool { ProcessInfo.processInfo.environment["BLURT_HOME"] == nil && Bundle.main.bundleIdentifier != nil }

    static func post(title: String, body: String, uid: String) {
        guard allowed else { return }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = title
            n.body = body
            n.userInfo = ["uid": uid]
            c.add(UNNotificationRequest(identifier: "fixed-\(uid)-\(Int(Date().timeIntervalSince1970))", content: n, trigger: nil))
        }
    }
}
