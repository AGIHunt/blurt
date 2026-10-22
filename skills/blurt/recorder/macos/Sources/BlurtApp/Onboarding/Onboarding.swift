// The setup assistant (§2.2), at most four steps, every one skippable:
//   1. permissions — Screen Recording, Microphone, Accessibility, live;
//   2. uv + Python — found, or installed into ~/.blurt/bin with the user's consent (the official installer), then the
//      scripts' dependencies warmed up so the first real run doesn't wait;
//   3. a speech model — the recommended one for the user's language, downloaded with progress;
//   4. agents — which are installed / logged in, and the blurt skill + MCP installed into one (preview first).
// Shown once on first launch (config app.onboarded), again from Settings → General or blurt://onboarding.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step = 0
    @Published var uv: String? = ScriptRunner.shared.uvPath
    @Published var installingUV = false
    @Published var uvLog: [String] = []
    @Published var warm: String?            // nil | "running" | "done" | error text
    let steps = 4
    var close: () -> Void = {}

    func finish() {
        Config.shared.set("app.onboarded", true)
        close()
    }

    static let uvInstallCommand = "curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=\"$HOME/.blurt/bin\" UV_NO_MODIFY_PATH=1 sh"

    /// Only after the user pressed the button that shows this exact command.
    func installUV() {
        installingUV = true
        uvLog = []
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        var env = ShellEnv.agentEnvironment()
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        // ~/.blurt/bin follows BLURT_HOME, like everything else
        p.arguments = ["-c", OnboardingModel.uvInstallCommand.replacingOccurrences(of: "$HOME/.blurt", with: BlurtPaths.home.path)]
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        streamLines(p) { [weak self] line, _ in self?.uvLog.append(line) }
        p.terminationHandler = { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                self.installingUV = false
                self.uv = ScriptRunner.shared.uvPath
                if self.uv != nil { self.warmUp() }
            }
        }
        do { try p.run() } catch { installingUV = false; uvLog.append("\(error)") }
    }

    /// Pre-installs the scripts' dependencies (numpy, sherpa-onnx…) and builds the search index.
    func warmUp() {
        guard warm != "running" else { return }
        warm = "running"
        Task {
            do {
                let a = try await SkillCLI.shared.run("transcribe.py", ["backends"], timeout: 600)
                let b = try await SkillCLI.shared.run("index.py", ["scan"], timeout: 300)
                warm = a.ok && b.ok ? "done" : (a.ok ? b.errorText : a.errorText)
            } catch { warm = "\(error)" }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var m: OnboardingModel
    @StateObject var perms = Permissions()
    @ObservedObject var speech = SpeechModel.shared
    @ObservedObject var agents = AgentsModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if let icon = NSApp.applicationIconImage { Image(nsImage: icon).resizable().frame(width: 52, height: 52) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("欢迎使用口喷鸡", "Welcome to Blurt")).font(.title2.weight(.semibold))
                    Text(L("四步准备好：边说边录，交给 agent 去修。", "Four quick steps: talk while you record, let your agent fix it."))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)

            HStack(spacing: 6) {
                ForEach(0..<m.steps, id: \.self) { i in
                    Capsule().fill(i <= m.step ? Color.accentColor : Color(nsColor: .quaternaryLabelColor)).frame(height: 4)
                }
            }.padding(.horizontal, 28)

            Group {
                switch m.step {
                case 0: permissions
                case 1: python
                case 2: model
                default: agentsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28).padding(.vertical, 18)

            Divider()
            HStack {
                Button(L("跳过设置", "Skip setup")) { m.finish() }.buttonStyle(.link)
                Spacer()
                if m.step > 0 { Button(L("上一步", "Back")) { m.step -= 1 } }
                Button(m.step == m.steps - 1 ? L("完成", "Done") : L("下一步", "Next")) {
                    if m.step == m.steps - 1 { m.finish() } else { m.step += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
        }
        .frame(width: 640, height: 520)
        .onAppear { perms.start() }
        .onDisappear { perms.stop() }
    }

    func title(_ n: Int, _ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("第 \(n) 步 · ", "Step \(n) · ") + t).font(.headline)
            Text(sub).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 10)
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(1, L("权限", "Permissions"), L("口喷鸡录的是你选的区域，录完的文件只存在你的 Mac 上。状态会实时更新。",
                                              "Blurt records the area you pick; files stay on your Mac. The status below updates live."))
            GroupBox { VStack(spacing: 12) { PermissionRows(p: perms) }.padding(6) }
        }
    }

    var python: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(2, L("Python 环境（uv）", "Python (uv)"), L("整理、搜索、语音识别是随 skill 发布的 Python 脚本，用 uv 运行，不需要你装 Python。",
                                                          "Processing, search and speech recognition are Python scripts that ship with the skill; uv runs them — no Python setup needed."))
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        StatusDot(tone: m.uv != nil ? .good : .warn)
                        Text(m.uv.map { L("已找到 uv：", "uv found: ") + ($0 as NSString).abbreviatingWithTildeInPath } ?? L("没找到 uv", "uv not found"))
                        Spacer()
                    }
                    if m.uv == nil {
                        Text(L("经你同意后，口喷鸡会用 uv 官方安装脚本把它装到 ~/.blurt/bin（不改你的 shell 配置）：",
                               "With your OK, Blurt runs uv's official installer into ~/.blurt/bin (your shell config is not touched):"))
                            .font(.callout).foregroundStyle(.secondary)
                        CommandText(text: OnboardingModel.uvInstallCommand)
                        HStack {
                            Button(L("安装 uv", "Install uv")) { m.installUV() }.disabled(m.installingUV)
                            if m.installingUV { ProgressView().controlSize(.small) }
                        }
                        if !m.uvLog.isEmpty { Text(m.uvLog.suffix(3).joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    } else {
                        HStack {
                            switch m.warm {
                            case nil: Button(L("预装依赖", "Warm up dependencies")) { m.warmUp() }
                                      Text(L("提前下载脚本要用的包，第一次整理就不用等", "Fetches the scripts' packages now so the first run doesn't wait")).font(.caption).foregroundStyle(.secondary)
                            case "running"?: ProgressView().controlSize(.small); Text(L("正在准备…（第一次约一分钟）", "Preparing… (about a minute the first time)")).foregroundStyle(.secondary)
                            case "done"?: Label(L("依赖已就绪，索引已建好", "Dependencies ready, index built"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            case let e?: Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3)
                            }
                        }
                    }
                }.padding(6)
            }
        }
    }

    var recommended: ASRModel? { speech.models.first { $0.isDefault == true } ?? speech.models.first(where: \.local) }

    var model: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(3, L("语音模型", "Speech model"), L("在本机把你说的话转成文字，不上传。推荐的模型支持中、英、日、韩、粤语。",
                                                 "Turns your narration into text on this Mac — nothing is uploaded. The recommended model covers Chinese, English, Japanese, Korean and Cantonese."))
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if m.uv == nil {
                        Text(L("需要先装好 uv（上一步）。", "Needs uv first (previous step).")).foregroundStyle(.secondary)
                    } else if let r = recommended {
                        HStack {
                            StatusDot(tone: r.installed ? .good : .warn)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("SenseVoice Small").fontWeight(.medium)
                                Text("\(Int(r.sizeMB)) MB · " + r.languages.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if r.installed { Label(L("已下载", "Downloaded"), systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                            else if speech.download[r.id] == nil { Button(L("下载", "Download")) { speech.startDownload(r) } }
                        }
                        if let d = speech.download[r.id] {
                            ProgressView(value: min(d.done, max(d.total, 1)), total: max(d.total, 1)) { Text(d.text).font(.caption) }
                        }
                        Toggle(L("下载走国内镜像（hf-mirror.com）", "Download via hf-mirror.com (mainland China)"),
                               isOn: Binding(get: { speech.mirror }, set: { speech.setMirror($0) }))
                    } else {
                        HStack { ProgressView().controlSize(.small); Text(L("读取模型…", "Reading models…")).foregroundStyle(.secondary) }
                    }
                    if let e = speech.error { Text(e).font(.caption).foregroundStyle(.orange) }
                }.padding(6)
            }
            Hint(L("也可以以后在 设置 → 语音 里换模型或用云端识别。", "You can switch models or use cloud recognition later in Settings → Speech."))
        }
        .task { if m.uv != nil { await speech.load() } }
    }

    var agentsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(4, L("Coding agent", "Coding agent"), L("口喷鸡把录屏交给你已经在用的 agent 整理和修 bug。装上 blurt skill 和 MCP，它就能读条目、修完回写状态。",
                                                       "Blurt hands recordings to the agent you already use. With the blurt skill + MCP installed it can read items and report fixes back."))
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if agents.loading && agents.rows.isEmpty { HStack { ProgressView().controlSize(.small); Text(L("检查已安装的 agent…", "Looking for agents…")).foregroundStyle(.secondary) } }
                    ForEach(agents.rows.filter { $0.installed }) { a in
                        HStack {
                            StatusDot(tone: a.state == "ready" ? .good : a.state == "logged_out" ? .bad : .warn)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name)
                                Text(a.why.isEmpty ? a.state : a.why).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if agents.installing == a.id { ProgressView().controlSize(.small) }
                            else { Button(L("安装 skill + MCP…", "Install skill + MCP…")) { Task { await agents.preview(a) } } }
                        }
                    }
                    if !agents.loading && agents.rows.filter(\.installed).isEmpty {
                        Text(L("没找到 Claude Code、Codex、Kimi Code 等。装一个后在 设置 → Agent 里接入。",
                               "No Claude Code, Codex, Kimi Code… found. Install one, then connect it in Settings → Agents.")).foregroundStyle(.secondary)
                    }
                }.padding(6)
            }
        }
        .task { if agents.rows.isEmpty { await agents.load() } }
        .sheet(isPresented: Binding(get: { agents.plan != nil }, set: { if !$0 { agents.plan = nil } })) {
            if let p = agents.plan { InstallSheet(m: agents, agent: p.agent, plan: p.plan, applied: p.applied) }
        }
    }
}

final class Onboarding: NSObject, NSWindowDelegate {
    static let shared = Onboarding()
    private var window: NSWindow?
    private var model: OnboardingModel?

    static var needed: Bool { Config.shared["app.onboarded"] as? Bool != true }

    func show(step: Int = 0) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.present(step) } }
    }

    @MainActor
    private func present(_ step: Int) {
        if let w = window {
            model?.step = step
            activateApp(); w.makeKeyAndOrderFront(nil); return
        }
        let m = OnboardingModel()
        m.step = step
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = L("设置口喷鸡", "Set up Blurt")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.sharingType = ProcessInfo.processInfo.environment["BLURT_DEBUG_CHROME"] == nil ? .none : .readOnly
        m.close = { [weak w] in w?.close() }
        w.contentViewController = NSHostingController(rootView: OnboardingView(m: m))
        w.center()
        window = w
        model = m
        activateApp()
        w.makeKeyAndOrderFront(nil)
        emit(["event": "onboarding", "step": step])
    }

    func windowWillClose(_ notification: Notification) {
        Config.shared.set("app.onboarded", true)     // closing it counts as "skip"
        window = nil
        model = nil
    }

    var windowNumber: Int? { window?.windowNumber }
}
