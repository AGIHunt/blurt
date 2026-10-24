// The models dictation runs on, in one place (docs/design/dictation.md §Recognition model, §Polish): the speech models
// it can use (`transcribe.py dictation-models`) and the polish models (`polish.py models`), their downloads (only when
// the user asks; progress from the scripts' "N/M MB" lines), the choice, the recommended pair with its total size, and
// their names (the Dictation page's history shows names, not ids). Settings → Speech lists and picks them
// (`DictationModelsSection`); Settings → Dictation shows the current choice with a link there.
// One verb per state: Download (not on this Mac) / Use (on this Mac) / the selected one is marked. Sizes come from
// the catalogues' size_mb, formatted by `modelSize`.
// Strings: Resources/*.lproj/Speech.strings ("speech.dictation.*").
import AppKit
import SwiftUI
import BlurtCore

private func S(_ key: String, _ args: CVarArg...) -> String {
    let fmt = Loc.string(key, table: "Speech")
    return args.isEmpty ? fmt : String(format: fmt, locale: Loc.locale, arguments: args)
}

struct PolishModel: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var family: String
    var sizeMB: Double
    var installed: Bool
    var recommended: Bool
    enum CodingKeys: String, CodingKey { case id, name, family, installed, recommended, sizeMB = "size_mb" }
}

/// `transcribe.py dictation-models`: what dictation can use here.
struct DictationASRModel: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var sizeMB: Double
    var installed: Bool
    var recommended: Bool
    /// none | prompt | context | hotwords: how the model takes the custom words
    var vocab: String
    enum CodingKeys: String, CodingKey { case id, name, installed, recommended, vocab, sizeMB = "size_mb" }
}

struct DictationASRState: Decodable {
    var configured: String?
    var recommended: String
    var selected: String
    var models: [DictationASRModel]
}

struct PolishState: Decodable {
    var supported: Bool
    var tier: String
    var recommended: String
    var selected: String?
    var configured: String?
    var models: [PolishModel]
}

/// A model's download size the same way everywhere: whole MB below 1 GB, one decimal above ("228 MB", "2.4 GB").
func modelSize(_ mb: Double) -> String {
    let f = NumberFormatter()
    f.locale = Loc.locale
    f.numberStyle = .decimal
    if mb < 1000 {
        f.maximumFractionDigits = 0
        return (f.string(from: mb.rounded() as NSNumber) ?? "\(Int(mb))") + " MB"
    }
    f.minimumFractionDigits = 1
    f.maximumFractionDigits = 1
    return (f.string(from: (mb / 1024) as NSNumber) ?? "\(mb / 1024)") + " GB"
}

@MainActor
final class DictationModels: ObservableObject {
    static let shared = DictationModels()

    @Published var asr: DictationASRState?
    @Published var polish: PolishState?
    @Published var asrDownload: [String: (done: Double, total: Double)] = [:]
    @Published var asrFailed: [String: Bool] = [:]
    @Published var download: [String: (done: Double, total: Double)] = [:]
    @Published var failed: [String: Bool] = [:]
    private var procs: [String: Process] = [:]
    private var cancelled = Set<String>()
    private var loaded = false

    init() {
        // tests: `dictation polish install ID | cancel ID | use ID | state` — the model rows' buttons, then a
        // "polish_settings" event with every row's state (works whichever pane is showing)
        NotificationCenter.default.addObserver(forName: DictationPane.polishRequest, object: nil, queue: .main) { n in
            let arg = n.object as? String ?? ""
            MainActor.assumeIsolated { DictationModels.shared.testCommand(arg) }
        }
    }

    func load() async {
        loaded = true
        async let a = SkillCLI.shared.run("transcribe.py", ["dictation-models"], timeout: 120)
        async let p = SkillCLI.shared.run("polish.py", ["models"], timeout: 60)
        asr = (try? await a)?.decode(DictationASRState.self)
        polish = (try? await p)?.decode(PolishState.self)
    }

    /// Once per run (the history's names); Settings reloads whenever it opens.
    func loadIfNeeded() { if !loaded { Task { await load() } } }

    // MARK: names

    func asrName(_ id: String) -> String { asr?.models.first { $0.id == id }?.name ?? id }
    func polishName(_ id: String) -> String { polish?.models.first { $0.id == id }?.name ?? id }
    var selectedASR: DictationASRModel? { asr.flatMap { a in a.models.first { $0.id == a.selected } } }
    var selectedPolish: PolishModel? { polish.flatMap { p in p.models.first { $0.id == p.selected } } }

    // MARK: the recommended pair

    var recommendedASR: DictationASRModel? { asr.flatMap { a in a.models.first { $0.id == a.recommended } } }
    var recommendedPolish: PolishModel? {
        guard let p = polish, p.supported else { return nil }
        return p.models.first { $0.id == p.recommended }
    }
    /// The whole recommended set's size, and what of it still has to be downloaded.
    var recommendedMB: (total: Double, missing: Double) {
        var total = 0.0, missing = 0.0
        if let a = recommendedASR { total += a.sizeMB; if !a.installed { missing += a.sizeMB } }
        if let p = recommendedPolish { total += p.sizeMB; if !p.installed { missing += p.sizeMB } }
        return (total, missing)
    }
    func downloadRecommended() {
        if let a = recommendedASR, !a.installed { installASR(a) }
        if let p = recommendedPolish, !p.installed { install(p) }
    }

    // MARK: speech model

    func chooseASR(_ m: DictationASRModel) {
        save("asr_model", m.id)
        Task { await load() }
    }

    /// `transcribe.py setup --model-id ID` (it adds its package through uv) — only when the user asks.
    func installASR(_ m: DictationASRModel) {
        guard asrDownload[m.id] == nil else { return }
        asrFailed[m.id] = nil
        asrDownload[m.id] = (0, m.sizeMB)
        var env: [String: String] = [:]
        if Config.shared["asr.hf_mirror"] as? Bool == true { env["BLURT_HF_MIRROR"] = "1" }
        let script = ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1"
            ? ProcessInfo.processInfo.environment["BLURT_TEST_ASR_SETUP"] ?? "transcribe.py" : "transcribe.py"
        let p = try? SkillCLI.shared.spawn(script, ["setup", "--model-id", m.id], env: env, onLine: { [weak self] line, _ in
            if let d = DictationModels.progress(line) { self?.asrDownload[m.id] = d }
        }, onExit: { [weak self] st in
            guard let self = self else { return }
            self.asrDownload[m.id] = nil
            if st != 0 { self.asrFailed[m.id] = true } else { self.save("asr_model", m.id) }
            emit(["event": "asr_download", "model": m.id, "status": Int(st)])
            Task { await self.load() }
        })
        if p == nil { asrDownload[m.id] = nil; asrFailed[m.id] = true }
    }

    // MARK: polish model

    func choose(_ m: PolishModel) {
        save("polish_model", m.id)
        Dictation.shared.refreshPolishModel()
        Task { await load() }
    }

    /// `polish.py setup --model ID --use` — only when the user asks.
    func install(_ m: PolishModel) {
        guard procs[m.id] == nil else { return }
        failed[m.id] = nil
        cancelled.remove(m.id)
        download[m.id] = (0, m.sizeMB)
        var env: [String: String] = [:]
        if Config.shared["asr.hf_mirror"] as? Bool == true { env["BLURT_HF_MIRROR"] = "1" }
        // BLURT_TEST_POLISH_SETUP (test builds only): a script that stands in for polish.py and fakes the download
        let script = ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1"
            ? ProcessInfo.processInfo.environment["BLURT_TEST_POLISH_SETUP"] ?? "polish.py" : "polish.py"
        procs[m.id] = try? SkillCLI.shared.spawn(script, ["setup", "--model", m.id, "--use"], env: env, onLine: { [weak self] line, _ in
            if let d = DictationModels.progress(line) { self?.download[m.id] = d }
        }, onExit: { [weak self] st in
            guard let self = self else { return }
            self.procs[m.id] = nil
            self.download[m.id] = nil
            if st != 0 && !self.cancelled.contains(m.id) { self.failed[m.id] = true }
            self.cancelled.remove(m.id)
            emit(["event": "polish_download", "model": m.id, "status": Int(st)])
            Dictation.shared.refreshPolishModel()
            Task { await self.load() }
        })
        if procs[m.id] == nil { download[m.id] = nil; failed[m.id] = true }
    }

    func cancel(_ m: PolishModel) {
        guard let p = procs[m.id] else { return }
        cancelled.insert(m.id)
        p.terminate()
    }

    /// "  N/M MB" → (N, M)
    static func progress(_ line: String) -> (done: Double, total: Double)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: #"^(\d+)/(\d+) MB"#, options: .regularExpression) else { return nil }
        let q = t[r].replacingOccurrences(of: " MB", with: "").split(separator: "/")
        guard q.count == 2, let a = Double(q[0]), let b = Double(q[1]), b > 0 else { return nil }
        return (a, b)
    }

    private func save(_ key: String, _ value: Any?) {
        Dictation.set(key, value)
        Dictation.shared.apply()
        emit(["event": "dictation_setting", "key": key, "value": value.map { "\($0)" } ?? "default"])
    }

    func testCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        Task {
            if polish == nil { await load() }
            if a.count == 2, let model = polish?.models.first(where: { $0.id == a[1] }) {
                switch a[0] {
                case "install": install(model)
                case "cancel": cancel(model)
                case "use": choose(model)
                default: break
                }
            }
            emit(["event": "polish_settings", "selected": polish?.selected ?? NSNull(), "polish": Dictation.polishOn,
                  "models": (polish?.models ?? []).map { x -> String in
                      let d = download[x.id].map { " \(Int($0.done))/\(Int($0.total))" } ?? ""
                      return "\(x.id)\(x.installed ? " installed" : "")\(x.recommended ? " recommended" : "")\(d)\(failed[x.id] == true ? " failed" : "")"
                  }])
        }
    }
}

// MARK: - Settings → Speech: the dictation models

/// The recommended pair with its total size, then the speech models and the polish models: the selected, recommended
/// and downloaded ones, the rest folded under "Other models".
struct DictationModelsSection: View {
    @ObservedObject var m = DictationModels.shared

    var body: some View {
        Section {
            if m.asr == nil && m.polish == nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(S("speech.dictation.loading")).foregroundStyle(.secondary) }
            } else {
                recommended
                if let a = m.asr {
                    subheading(S("speech.dictation.asr"))
                    let (main, more) = split(a.models) { $0.id == a.selected || $0.recommended || $0.installed || m.asrDownload[$0.id] != nil }
                    ForEach(main) { asrRow($0, selected: a.selected == $0.id) }
                    if !more.isEmpty {
                        DisclosureGroup(S("speech.dictation.more", more.count)) {
                            ForEach(more) { asrRow($0, selected: a.selected == $0.id) }
                        }
                    }
                }
                if let p = m.polish {
                    subheading(S("speech.dictation.polish"))
                    if !p.supported {
                        Text(S("speech.dictation.polish.unsupported")).font(.callout).foregroundStyle(.secondary)
                    } else {
                        let sorted = p.models.sorted { ($0.recommended ? 0 : 1, $0.sizeMB) < ($1.recommended ? 0 : 1, $1.sizeMB) }
                        let (main, more) = split(sorted) { $0.id == p.selected || $0.recommended || $0.installed || m.download[$0.id] != nil }
                        ForEach(main) { polishRow($0, selected: p.selected == $0.id) }
                        if !more.isEmpty {
                            DisclosureGroup(S("speech.dictation.more", more.count)) {
                                ForEach(more) { polishRow($0, selected: p.selected == $0.id) }
                            }
                        }
                    }
                }
            }
        } header: { Text(S("speech.section.dictation")) } footer: {
            Text(S("speech.dictation.footer")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .id("dictation")
        .task { await m.load() }
    }

    private func split<T>(_ xs: [T], _ keep: (T) -> Bool) -> ([T], [T]) { (xs.filter(keep), xs.filter { !keep($0) }) }

    private func subheading(_ s: String) -> some View {
        Text(s).font(.callout.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
    }

    /// "Recommended: Qwen3-ASR 1.7B + Gemma 4 E2B · 5.7 GB" with one Download for what's missing.
    @ViewBuilder var recommended: some View {
        let names = [m.recommendedASR?.name, m.recommendedPolish?.name].compactMap { $0 }
        if !names.isEmpty {
            let mb = m.recommendedMB
            HStack(alignment: .center, spacing: 10) {
                StatusDot(tone: mb.missing == 0 ? .good : .off)
                VStack(alignment: .leading, spacing: 2) {
                    Text(S("speech.dictation.recommended", names.joined(separator: " + ")))
                    Text(mb.missing == 0 ? S("speech.dictation.recommended.ready", modelSize(mb.total))
                                         : S("speech.dictation.recommended.size", modelSize(mb.total)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if mb.missing > 0 && m.asrDownload.isEmpty && m.download.isEmpty {
                    Button(S("speech.dictation.download", modelSize(mb.missing))) { m.downloadRecommended() }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    func asrRow(_ x: DictationASRModel, selected: Bool) -> some View {
        DictationModelRow(name: x.name ?? x.id, sizeMB: x.sizeMB, recommended: x.recommended, installed: x.installed,
                          selected: selected, detail: x.vocab == "none" ? S("speech.dictation.no_words") : nil,
                          progress: m.asrDownload[x.id], failed: m.asrFailed[x.id] == true,
                          use: { m.chooseASR(x) }, download: { m.installASR(x) }, cancel: nil)
    }

    func polishRow(_ x: PolishModel, selected: Bool) -> some View {
        DictationModelRow(name: x.name, sizeMB: x.sizeMB, recommended: x.recommended, installed: x.installed,
                          selected: selected, detail: nil, progress: m.download[x.id], failed: m.failed[x.id] == true,
                          use: { m.choose(x) }, download: { m.install(x) }, cancel: { m.cancel(x) })
    }
}

/// One model: a radio mark, its name (Recommended), its size; Download / Use, or the download's progress.
struct DictationModelRow: View {
    var name: String
    var sizeMB: Double
    var recommended: Bool
    var installed: Bool
    var selected: Bool
    var detail: String?
    var progress: (done: Double, total: Double)?
    var failed: Bool
    var use: () -> Void
    var download: () -> Void
    var cancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.brandInk : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name)
                    if recommended { Badge(S("speech.dictation.recommended.badge")) }
                }
                Group {
                    if let d = progress {
                        Text(S("speech.dictation.progress", modelSize(d.done), modelSize(max(d.total, sizeMB)))).monospacedDigit()
                    } else {
                        Text(([modelSize(sizeMB)] + (detail.map { [$0] } ?? [])).joined(separator: " · "))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let d = progress {
                ProgressView(value: min(d.done, d.total), total: max(d.total, 1)).frame(width: 90)
                if let c = cancel { Button(S("speech.cancel"), action: c).controlSize(.small) }
            } else if installed {
                if !selected { Button(S("speech.dictation.use"), action: use).controlSize(.small) }
            } else {
                if failed { Text(S("speech.dictation.failed")).font(.caption).foregroundStyle(Color.brandErr) }
                Button(S("speech.download.button"), action: download).controlSize(.small)
            }
        }
        .choiceCard(selected)
        .contentShape(Rectangle())
        .onTapGesture { if installed && !selected { use() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
