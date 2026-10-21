// Settings → Speech: speech-recognition models from `transcribe.py models` (installed / downloadable, size,
// languages), download with progress (`transcribe.py setup --backend B`, stderr "  N/M MB"), a measured real-time
// factor (`transcribe.py bench`), which backend is used (config asr.backend / asr.language), and how cloud keys are
// provided. Keys are never stored or shown here: the scripts read them from the login shell's environment, and this
// pane only says whether each variable is set.
import AppKit
import SwiftUI
import BlurtCore

struct ASRModel: Decodable, Identifiable, Hashable {
    var id: String
    var backend: String
    var role: String
    var local: Bool
    var sizeMB: Double
    var languages: [String]
    var installed: Bool
    var configured: Bool?
    var path: String?
    var approx: Bool?
    var package: String?
    var platform: String?
    var keys: [String]?
    var isDefault: Bool?

    enum CodingKeys: String, CodingKey {
        case id, backend, role, local, languages, installed, configured, path, approx, package, platform, keys
        case sizeMB = "size_mb", isDefault = "default"
    }
}

struct ASRModels: Decodable {
    var modelsDir: String?
    var models: [ASRModel]
    enum CodingKeys: String, CodingKey { case models, modelsDir = "models_dir" }
}

struct BenchResult: Codable { var rtf: Double?; var loadSeconds: Double?; var at: Double; var error: String? }

@MainActor
final class SpeechModel: ObservableObject {
    static let shared = SpeechModel()

    @Published var models: [ASRModel] = []
    @Published var loading = false
    @Published var error: String?
    @Published var keys: [String: Bool] = [:]
    @Published var download: [String: (done: Double, total: Double, text: String)] = [:]   // backend → progress
    @Published var benching: Set<String> = []
    @Published var bench: [String: BenchResult] = [:]
    @Published var language = "auto"
    @Published var mirror = false
    var procs: [String: Process] = [:]

    var backend: String { Config.shared["asr.backend"] as? String ?? "sensevoice" }
    var localOnly: Bool { Config.shared["privacy.local_asr"] as? Bool ?? false }

    init() {
        language = Config.shared["asr.language"] as? String ?? "auto"
        mirror = Config.shared["asr.hf_mirror"] as? Bool ?? false
        bench = (try? JSONDecoder().decode([String: BenchResult].self, from: Data(contentsOf: SpeechModel.benchFile))) ?? [:]
    }

    static var benchFile: URL { BlurtPaths.home.appendingPathComponent("bench/results.json") }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await SkillCLI.shared.run("transcribe.py", ["models"], timeout: 180)
            guard r.ok, let m = r.decode(ASRModels.self) else { error = r.errorText; return }
            models = m.models.filter { $0.role == "asr" }
            error = nil
            let b = try await SkillCLI.shared.run("transcribe.py", ["backends"], timeout: 120)
            keys = (b.json?["api_keys"] as? [String: Bool]) ?? [:]
        } catch { self.error = "\(error)" }
    }

    func use(_ m: ASRModel) {
        Config.shared.set("asr.backend", m.backend)
        if Config.shared["asr.model"] != nil, m.backend == "sensevoice" { Config.shared.set("asr.model", nil) }
        Task { await load() }
    }

    func setLanguage(_ l: String) { language = l; Config.shared.set("asr.language", l == "auto" ? nil : l) }
    func setMirror(_ on: Bool) { mirror = on; Config.shared.set("asr.hf_mirror", on ? true : nil) }

    /// `transcribe.py setup --backend B` — downloads (and selects) it. Progress from its stderr.
    func startDownload(_ m: ASRModel, then: (() -> Void)? = nil) {
        guard procs[m.backend] == nil else { return }
        download[m.backend] = (0, m.sizeMB, L("准备下载…", "Starting…"))
        var env: [String: String] = [:]
        if mirror { env["BLURT_HF_MIRROR"] = "1" }
        do {
            procs[m.backend] = try SkillCLI.shared.spawn("transcribe.py", ["setup", "--backend", m.backend], with: m.package.map { [$0] } ?? [],
                                                         env: env, onLine: { [weak self] line, _ in self?.progress(m, line) },
                                                         onExit: { [weak self] st in
                guard let self = self else { return }
                self.procs[m.backend] = nil
                self.download[m.backend] = nil
                if st != 0 { self.error = L("下载失败（\(st)），可以打开「国内镜像」再试", "Download failed (\(st)) — try the mirror") }
                Task { await self.load(); then?() }
            })
        } catch { download[m.backend] = nil; self.error = "\(error)" }
    }

    private func progress(_ m: ASRModel, _ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^(\d+)/(\d+) MB"#, options: .regularExpression) {
            let parts = t[r].replacingOccurrences(of: " MB", with: "").split(separator: "/")
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]) {
                download[m.backend] = (a, b, "\(Int(a)) / \(Int(b)) MB")
            }
        } else if t.hasPrefix("downloading ") {
            let what = t.dropFirst(12).split(separator: " ").first.map(String.init) ?? ""
            download[m.backend] = (download[m.backend]?.done ?? 0, download[m.backend]?.total ?? m.sizeMB, what)
        }
    }

    func cancelDownload(_ m: ASRModel) { procs[m.backend]?.terminate() }

    /// `transcribe.py bench --backend B` (30 s spoken sample) → RTF.
    func runBench(_ m: ASRModel) async {
        benching.insert(m.backend)
        defer { benching.remove(m.backend) }
        do {
            let r = try await SkillCLI.shared.run("transcribe.py", ["bench", "--backend", m.backend], with: m.package.map { [$0] } ?? [], timeout: 600)
            let o = r.json
            let res = BenchResult(rtf: o?["rtf"] as? Double, loadSeconds: o?["load_seconds"] as? Double, at: Date().timeIntervalSince1970,
                                  error: r.ok ? nil : r.errorText)
            bench[m.backend] = res
            try? FileManager.default.createDirectory(at: SpeechModel.benchFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(bench).write(to: SpeechModel.benchFile)
            emit(["event": "bench", "backend": m.backend, "rtf": res.rtf ?? -1])
        } catch { bench[m.backend] = BenchResult(rtf: nil, loadSeconds: nil, at: Date().timeIntervalSince1970, error: "\(error)") }
    }

    /// Only our own downloads (inside ~/.blurt/models) can be removed from here — to the Trash.
    func canRemove(_ m: ASRModel) -> Bool {
        guard m.installed, let p = m.path else { return false }
        return URL(fileURLWithPath: p).standardizedFileURL.path.hasPrefix(BlurtPaths.home.appendingPathComponent("models").standardizedFileURL.path)
    }
    func remove(_ m: ASRModel) {
        guard canRemove(m), let p = m.path else { return }
        NSWorkspace.shared.recycle([URL(fileURLWithPath: p)]) { _, _ in Task { @MainActor in await self.load() } }
    }
}

struct SpeechPane: View {
    @ObservedObject var m = SpeechModel.shared
    @State var confirmRemove: ASRModel?

    var body: some View {
        PaneFrame {
            Section {
                if m.loading && m.models.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text(L("读取模型…", "Reading models…")).foregroundStyle(.secondary) }
                }
                ForEach(m.models.filter(\.local)) { row($0) }
            } header: {
                HStack {
                    Text(L("本地模型", "On this Mac"))
                    Spacer()
                    if m.loading { ProgressView().controlSize(.mini) }
                }
            } footer: {
                if let e = m.error { Text(e).foregroundStyle(.orange).font(.caption) }
            }

            Section {
                ForEach(m.models.filter { !$0.local }) { row($0) }
                Hint(L("云端识别的 key 不存在口喷鸡里：在 ~/.zshrc 里 export 对应的变量（如下），口喷鸡从你的登录 shell 读取。这里只显示是否已设置。",
                       "Cloud keys are not stored in Blurt: export the variable in ~/.zshrc (below) and Blurt reads it from your login shell. This pane only shows whether it is set."))
                ForEach(m.keys.keys.sorted(), id: \.self) { k in
                    HStack {
                        StatusDot(tone: m.keys[k] == true ? .good : .off)
                        Text(k).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(m.keys[k] == true ? L("已设置", "set") : L("未设置", "not set")).foregroundStyle(.secondary)
                    }
                }
                if m.localOnly { Hint(L("隐私设置里打开了「只用本地识别」，云端模型不可选。", "Local-only recognition is on (Privacy), so cloud models can't be chosen.")) }
            } header: { Text(L("云端", "Cloud")) }

            Section {
                Picker(L("说话的语言", "Spoken language"), selection: Binding(get: { m.language }, set: { m.setLanguage($0) })) {
                    Text(L("自动识别", "Detect")).tag("auto")
                    Text("中文").tag("zh"); Text("English").tag("en"); Text("日本語").tag("ja"); Text("한국어").tag("ko"); Text("粵語").tag("yue")
                }
                Toggle(L("下载走国内镜像（hf-mirror.com）", "Download via hf-mirror.com (mainland China)"),
                       isOn: Binding(get: { m.mirror }, set: { m.setMirror($0) }))
            } header: { Text(L("识别", "Recognition")) }
        }
        .task { await m.load() }
        .alert(L("移到废纸篓？", "Move to the Trash?"), isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button(L("移到废纸篓", "Move to Trash"), role: .destructive) { if let r = confirmRemove { m.remove(r) }; confirmRemove = nil }
            Button(L("取消", "Cancel"), role: .cancel) { confirmRemove = nil }
        } message: { Text(confirmRemove?.path ?? "") }
    }

    @ViewBuilder
    func row(_ x: ASRModel) -> some View {
        let active = x.backend == m.backend
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                StatusDot(tone: x.installed ? (active ? .good : .warn) : .off)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title(x)).fontWeight(active ? .semibold : .regular)
                        if active { Text(L("使用中", "In use")).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18))) }
                        if x.isDefault == true && !active { Text(L("推荐", "Recommended")).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text(subtitle(x)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                actions(x, active: active)
            }
            if let d = m.download[x.backend] {
                HStack {
                    ProgressView(value: d.total > 0 ? min(d.done, d.total) : 0, total: max(d.total, 1))
                    Text(d.text).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 90, alignment: .trailing)
                    Button(L("停止", "Stop")) { m.cancelDownload(x) }.controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    func actions(_ x: ASRModel, active: Bool) -> some View {
        HStack(spacing: 6) {
            if x.local && x.installed {
                if m.benching.contains(x.backend) { ProgressView().controlSize(.small) }
                else { Button(L("测速", "Benchmark")) { Task { await m.runBench(x) } }.help(L("用 30 秒样本测实时率", "Real-time factor on a 30 s sample")) }
            }
            if x.local && !x.installed && m.download[x.backend] == nil {
                Button(L("下载", "Download")) { m.startDownload(x) }.disabled(x.platform == "macos-arm64" && !isAppleSilicon)
            }
            if x.installed && !active && (x.local || !m.localOnly) { Button(L("使用", "Use")) { m.use(x) } }
            if !x.local && !x.installed && !m.localOnly { Button(L("使用", "Use")) { m.use(x) }.disabled(true).help(L("先设置 key", "Set the key first")) }
            if m.canRemove(x) && !active {
                Button { confirmRemove = x } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(L("移到废纸篓", "Move to the Trash"))
            }
        }
    }

    func title(_ x: ASRModel) -> String {
        switch x.backend {
        case "sensevoice": return "SenseVoice Small"
        case "mlx-whisper": return "Whisper large-v3-turbo (MLX)"
        case "faster-whisper": return "Whisper large-v3-turbo (faster-whisper)"
        case "openai": return L("OpenAI 兼容接口", "OpenAI-compatible API")
        case "dashscope": return "Qwen3-ASR (DashScope)"
        default: return x.id
        }
    }

    func subtitle(_ x: ASRModel) -> String {
        var parts: [String] = []
        if x.local { parts.append((x.approx == true ? "≈ " : "") + (x.sizeMB >= 1000 ? String(format: "%.1f GB", x.sizeMB / 1024) : "\(Int(x.sizeMB.rounded())) MB")) }
        parts.append(x.languages.joined(separator: " "))
        if x.local && !x.installed && x.backend == m.backend { parts.append(L("还没下载，第一次识别时会自动下载", "not downloaded yet — fetched on first use")) }
        if let b = m.bench[x.backend] {
            if let r = b.rtf { parts.append(String(format: L("实测 RTF %.3f（1 分钟录音约 %.0f 秒）", "RTF %.3f (≈ %.0f s per minute of audio)"), r, r * 60)) }
            else if let e = b.error { parts.append(L("测速失败：", "benchmark failed: ") + String(e.prefix(80))) }
        }
        if x.platform == "macos-arm64" && !isAppleSilicon { parts.append(L("需要 Apple 芯片", "needs Apple silicon")) }
        if let k = x.keys, !k.isEmpty, !x.local { parts.append(k.joined(separator: " / ")) }
        return parts.joined(separator: " · ")
    }

    var isAppleSilicon: Bool {
        var v: Int32 = 0; var n = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &n, nil, 0) == 0 && v == 1
    }
}
