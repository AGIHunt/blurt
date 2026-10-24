// Settings → Speech (K9): which speech model this Mac uses for recordings, live captions and voice notes, chosen
// for its chip, memory and the languages the user speaks (`transcribe.py models`: hardware, tier, registry,
// recommendation, what is installed and measured). Automatic by default (`transcribe.py auto --apply`); manual
// per purpose. Dictation's speech and polish models are chosen here too, in their own section (DictationModels.swift:
// the recommended pair with its total size, one Download / Use per model; Settings → Dictation links here). A
// comparison of the models that run here — accuracy for the user's languages, speed, memory, download
// size — measured on this Mac when the user asks (`transcribe.py bench`), reference numbers otherwise. Resource caps
// (asr.limits: threads, transcriptions at once, GPU memory share, lighter models on battery), cloud keys (never
// stored or shown: only whether each variable is set), recognition language and the download mirror.
// Strings: Resources/*.lproj/Speech.strings (Loc table "Speech").
import AppKit
import SwiftUI
import BlurtCore

/// Loc.t for the Speech table (Loc.t's own variadic arguments can't be forwarded).
private func S(_ key: String, _ args: CVarArg...) -> String {
    let fmt = Loc.string(key, table: "Speech")
    return args.isEmpty ? fmt : String(format: fmt, locale: Loc.locale, arguments: args)
}

// MARK: - What transcribe.py reports

struct ASRBench: Decodable, Hashable {
    var rtf: Double?
    var peakRAM: Double?
    var cpuCores: Double?
    var rates: [String: Double]?
    var at: String?
    enum CodingKeys: String, CodingKey { case rtf, at, rates = "error", peakRAM = "peak_ram_mb", cpuCores = "cpu_cores" }
}

struct ASRModel: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var backend: String
    var role: String
    var local: Bool
    var sizeMB: Double
    var ramMB: Double?
    /// ISO codes, or ["multi"] for Whisper-style "every language"
    var languages: [String]
    var installed: Bool
    var path: String?
    var approx: Bool?
    var package: String?
    var runsHere: Bool?
    var fits: Bool?
    var purposes: [String]?
    var keys: [String]?
    var qualityNoteKey: String?
    var rtfRef: Double?
    var errorRef: [String: Double]?
    var bench: ASRBench?
    var isDefault: Bool?

    var multilingual: Bool { languages == ["multi"] }
    var title: String { name ?? id }

    enum CodingKeys: String, CodingKey {
        case id, name, backend, role, local, languages, installed, path, approx, package, purposes, keys, bench
        case sizeMB = "size_mb", ramMB = "ram_mb", runsHere = "runs_here", fits, qualityNoteKey = "quality_note_key"
        case rtfRef = "rtf_ref", errorRef = "error_ref", isDefault = "default"
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try? c.decode(String.self, forKey: .name)
        backend = try c.decode(String.self, forKey: .backend)
        role = (try? c.decode(String.self, forKey: .role)) ?? "asr"
        local = (try? c.decode(Bool.self, forKey: .local)) ?? true
        sizeMB = (try? c.decode(Double.self, forKey: .sizeMB)) ?? 0
        ramMB = try? c.decode(Double.self, forKey: .ramMB)
        if let l = try? c.decode([String].self, forKey: .languages) { languages = l }
        else { languages = ["multi"] }
        installed = (try? c.decode(Bool.self, forKey: .installed)) ?? false
        path = try? c.decode(String.self, forKey: .path)
        approx = try? c.decode(Bool.self, forKey: .approx)
        package = try? c.decode(String.self, forKey: .package)
        runsHere = try? c.decode(Bool.self, forKey: .runsHere)
        fits = try? c.decode(Bool.self, forKey: .fits)
        purposes = try? c.decode([String].self, forKey: .purposes)
        keys = try? c.decode([String].self, forKey: .keys)
        qualityNoteKey = try? c.decode(String.self, forKey: .qualityNoteKey)
        rtfRef = try? c.decode(Double.self, forKey: .rtfRef)
        errorRef = try? c.decode([String: Double].self, forKey: .errorRef)
        bench = try? c.decode(ASRBench.self, forKey: .bench)
        isDefault = try? c.decode(Bool.self, forKey: .isDefault)
    }

    func speaks(_ lang: String) -> Bool { multilingual || languages.contains(lang) }
}

struct ASRHardware: Decodable {
    struct GPU: Decodable { var kind: String; var name: String?; var cores: Int?; var vramGB: Double?
        enum CodingKeys: String, CodingKey { case kind, name, cores, vramGB = "vram_gb" } }
    var chip: String?
    var ramGB: Double
    var perfCores: Int
    var effCores: Int
    var gpu: GPU
    var tier: String
    var onBattery: Bool?
    enum CodingKeys: String, CodingKey {
        case chip, gpu, tier, ramGB = "ram_gb", perfCores = "perf_cores", effCores = "eff_cores", onBattery = "on_battery"
    }
}

struct ASRLimits: Decodable {
    var threads: Int
    var maxConcurrent: Int
    var maxMemoryFraction: Double
    enum CodingKeys: String, CodingKey { case threads, maxConcurrent = "max_concurrent", maxMemoryFraction = "max_memory_fraction" }
}

struct ASRState: Decodable {
    var auto: Bool
    var tier: String
    var hardware: ASRHardware
    var limits: ASRLimits
    var languages: [String]
    var languagesSet: Bool?
    var selected: [String: String?]
    var recommended: [String: String]
    var localOnly: Bool?
    var models: [ASRModel]
    enum CodingKeys: String, CodingKey {
        case auto, tier, hardware, limits, languages, selected, recommended, models
        case languagesSet = "languages_set", localOnly = "local_only"
    }
}

/// The three jobs speech recognition does, in the order the pane shows them.
enum ASRPurpose: String, CaseIterable, Identifiable {
    case batch, live, note
    var id: String { rawValue }
    var title: String { S("speech.purpose.\(rawValue)") }
    var detail: String { S("speech.purpose.\(rawValue).detail") }
    var symbol: String {
        switch self {
        case .batch: return "record.circle"
        case .live: return "captions.bubble"
        case .note: return "mic"
        }
    }
}

/// A finished or failed measurement, kept for the session (the measured numbers themselves come back through
/// `transcribe.py models` from $BLURT_HOME/asr-bench.json).
struct BenchResult { var rtf: Double?; var error: String? }

// MARK: - Model

@MainActor
final class SpeechModel: ObservableObject {
    static let shared = SpeechModel()

    @Published var state: ASRState?
    @Published var models: [ASRModel] = []
    @Published var loading = false
    @Published var error: String?
    @Published var download: [String: (done: Double, total: Double, text: String)] = [:]   // model id → progress
    @Published var failed: [String: String] = [:]                                          // model id → why the download stopped
    @Published var benching: Set<String> = []
    @Published var bench: [String: BenchResult] = [:]                                      // model id → last run
    @Published var language = "auto"
    @Published var mirror = false
    var procs: [String: Process] = [:]

    var localOnly: Bool { Config.shared["privacy.local_asr"] as? Bool ?? false }
    var auto: Bool { state?.auto ?? true }
    var languages: [String] { state?.languages ?? [] }

    init() {
        language = Config.shared["asr.language"] as? String ?? "auto"
        mirror = Config.shared["asr.hf_mirror"] as? Bool ?? false
    }

    func model(_ id: String?) -> ASRModel? { id.flatMap { i in models.first { $0.id == i } } }
    func selected(_ p: ASRPurpose) -> ASRModel? { model(state?.selected[p.rawValue] ?? nil) }
    func recommended(_ p: ASRPurpose) -> ASRModel? { model(state?.recommended[p.rawValue]) }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await SkillCLI.shared.run("transcribe.py", ["models"], timeout: 180)
            guard r.ok, let s = r.decode(ASRState.self) else { error = S("speech.error.read"); return }
            // a finished download: the suggestion folds away and the jobs show their new model
            let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || state == nil
            withAnimation(calm ? nil : .easeInOut(duration: 0.25)) {
                state = s
                models = s.models.filter { $0.role == "asr" }  // not the VAD every local model uses
            }
            error = nil
        } catch { self.error = S("speech.error.read") }
    }

    /// Re-pick for this Mac (auto) and reload.
    func reapply() async {
        if auto { _ = try? await SkillCLI.shared.run("transcribe.py", ["auto", "--apply"], timeout: 120) }
        await load()
    }

    func setAuto(_ on: Bool) {
        Config.shared.set("asr.auto", on)
        Task { await reapply() }
    }

    /// A hand-picked model for one purpose: automatic choice ends, the other purposes keep what they use now.
    func choose(_ m: ASRModel, for p: ASRPurpose) {
        var cur: [String: Any] = [:]
        for q in ASRPurpose.allCases { if let id = state?.selected[q.rawValue] ?? nil { cur[q.rawValue] = id } }
        cur[p.rawValue] = m.id
        Config.shared.set("asr.models", cur)
        Config.shared.set("asr.auto", false)
        Task { await load() }
    }

    func setLanguages(_ l: [String]) {
        Config.shared.set("asr.languages", l.isEmpty ? nil : l)
        if language != "auto", !l.contains(language) { setLanguage("auto") }
        Task { await reapply() }
    }

    func setLanguage(_ l: String) { language = l; Config.shared.set("asr.language", l == "auto" ? nil : l) }
    func setMirror(_ on: Bool) { mirror = on; Config.shared.set("asr.hf_mirror", on ? true : nil) }
    func setLimit(_ key: String, _ value: Any?) { Config.shared.set("asr.limits.\(key)", value); Task { await load() } }
    var onBattery: String { Config.shared["asr.on_battery"] as? String ?? "lighter" }
    func setOnBattery(_ lighter: Bool) { Config.shared.set("asr.on_battery", lighter ? nil : "same"); objectWillChange.send() }

    /// `transcribe.py setup --model-id ID` (it adds its own packages through uv). Progress from its stderr.
    func startDownload(_ m: ASRModel, then: (() -> Void)? = nil) {
        guard procs[m.id] == nil else { return }
        failed[m.id] = nil
        download[m.id] = (0, m.sizeMB, S("speech.download.preparing"))
        var env: [String: String] = [:]
        if mirror { env["BLURT_HF_MIRROR"] = "1" }
        do {
            procs[m.id] = try SkillCLI.shared.spawn("transcribe.py", ["setup", "--model-id", m.id], env: env,
                                                     onLine: { [weak self] line, _ in self?.progress(m, line) },
                                                     onExit: { [weak self] st in
                guard let self = self else { return }
                self.procs[m.id] = nil
                self.download[m.id] = nil
                if st != 0 && st != 15 { self.failed[m.id] = S("speech.download.failed") }
                emit(["event": "asr_download", "model": m.id, "status": Int(st)])
                Task { await self.reapply(); then?() }
            })
        } catch { download[m.id] = nil; failed[m.id] = S("speech.download.failed") }
    }

    private func progress(_ m: ASRModel, _ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^(\d+)/(\d+) MB"#, options: .regularExpression) {
            let parts = t[r].replacingOccurrences(of: " MB", with: "").split(separator: "/")
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b > 0 {
                download[m.id] = (a, b, S("speech.download.progress", mb(a), mb(b)))
            }
        } else if t.hasPrefix("unpacking ") {
            download[m.id] = (download[m.id]?.total ?? m.sizeMB, download[m.id]?.total ?? m.sizeMB, S("speech.download.unpacking"))
        }
    }

    func cancelDownload(_ m: ASRModel) { procs[m.id]?.terminate() }

    /// `transcribe.py bench --model-id ID`: spoken samples in the user's languages (macOS `say`), measured here.
    func runBench(_ m: ASRModel) async {
        benching.insert(m.id)
        defer { benching.remove(m.id) }
        do {
            let r = try await SkillCLI.shared.run("transcribe.py", ["bench", "--model-id", m.id], timeout: 1200)
            let o = r.json
            bench[m.id] = BenchResult(rtf: o?["rtf"] as? Double, error: r.ok ? nil : S("speech.bench.failed"))
            emit(["event": "bench", "model": m.id, "rtf": bench[m.id]?.rtf ?? -1])
        } catch { bench[m.id] = BenchResult(rtf: nil, error: S("speech.bench.failed")) }
        await load()
    }

    /// Only our own downloads (inside ~/.blurt/models) can be removed from here — to the Trash. Models in the shared
    /// Hugging Face cache may be used by other apps.
    func canRemove(_ m: ASRModel) -> Bool {
        guard m.installed, let p = m.path else { return false }
        return URL(fileURLWithPath: p).standardizedFileURL.path.hasPrefix(BlurtPaths.home.appendingPathComponent("models").standardizedFileURL.path)
    }
    func remove(_ m: ASRModel) {
        guard canRemove(m), let p = m.path else { return }
        NSWorkspace.shared.recycle([URL(fileURLWithPath: p)]) { _, _ in Task { @MainActor in await self.reapply() } }
    }

    // MARK: numbers for the comparison

    /// Mean error rate over the user's languages this model speaks: measured here, else the reference machine's.
    func errorRate(_ m: ASRModel) -> (value: Double, measured: Bool)? {
        let langs = languages.filter { m.speaks($0) }
        if let r = m.bench?.rates {
            let v = langs.compactMap { r[$0] }
            if !v.isEmpty { return (v.reduce(0, +) / Double(v.count), true) }
        }
        if let r = m.errorRef {
            let v = langs.compactMap { r[$0] }
            if !v.isEmpty { return (v.reduce(0, +) / Double(v.count), false) }
        }
        return nil
    }
    func speed(_ m: ASRModel) -> (value: Double, measured: Bool)? {
        if let r = m.bench?.rtf, r > 0 { return (1 / r, true) }
        if let r = m.rtfRef, r > 0 { return (1 / r, false) }
        return nil
    }
    func memory(_ m: ASRModel) -> (value: Double, measured: Bool)? {
        if let p = m.bench?.peakRAM { return (p, true) }
        return m.ramMB.map { ($0, false) }
    }
    func missing(_ m: ASRModel) -> [String] { languages.filter { !m.speaks($0) } }
}

// MARK: - Formatting

private func mb(_ v: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(v * 1_048_576), countStyle: .memory)
}

private func percent(_ v: Double, digits: Int = 1) -> String {
    let f = NumberFormatter()
    f.locale = Loc.locale
    f.numberStyle = .percent
    f.minimumFractionDigits = 0
    f.maximumFractionDigits = digits
    return f.string(from: v as NSNumber) ?? "\(v)"
}

private func decimal(_ v: Double, digits: Int = 0) -> String {
    let f = NumberFormatter()
    f.locale = Loc.locale
    f.numberStyle = .decimal
    f.maximumFractionDigits = digits
    return f.string(from: v as NSNumber) ?? "\(v)"
}

/// Whole sentences one after another: a space between them in English, none after Chinese full stops.
private func sentences(_ parts: [String]) -> String {
    parts.filter { !$0.isEmpty }.joined(separator: Loc.isChinese ? "" : " ")
}

/// A language's name in the UI language ("Japanese" / "日语").
private func languageName(_ code: String) -> String {
    Loc.locale.localizedString(forLanguageCode: code) ?? code
}

/// A language's name in itself ("日本語"), for the list a person picks their own languages from.
private func endonym(_ code: String) -> String {
    let l = Locale(identifier: code)
    let n = l.localizedString(forLanguageCode: code) ?? code
    return n.prefix(1).uppercased(with: l) + n.dropFirst()
}

/// Languages offered in the picker: the ones the bundled models have been measured on first, then the rest of what
/// the multilingual models understand.
private let offeredLanguages = ["en", "zh", "yue", "ja", "ko", "es", "fr", "de", "it", "pt", "ru", "ar", "hi", "vi", "th",
                                "id", "ms", "tr", "nl", "pl", "sv", "da", "fi", "cs", "el", "hu", "ro", "uk", "fa", "fil"]

// MARK: - Pane

struct SpeechPane: View {
    /// Settings → Dictation's "Change…" / "Download…" (and tests): scroll to a section ("dictation").
    static let scrollRequest = Notification.Name("BlurtSpeechPaneScroll")
    /// The section to scroll to, kept until the pane has scrolled there: a pane that isn't on screen yet picks it up
    /// when it appears, one already showing gets `scrollRequest`.
    @MainActor static var pendingScroll: String?
    @ObservedObject var m = SpeechModel.shared
    @State var confirmRemove: ASRModel?

    /// Settings → Speech scrolled to dictation's models.
    @MainActor static func showDictationModels() {
        pendingScroll = "dictation"
        AppEnvironment.settings?.show(pane: SettingsPane.speech.rawValue)
        NotificationCenter.default.post(name: SpeechPane.scrollRequest, object: nil)
    }

    /// Scrolls to the pending section. A pane that has just appeared lays its Form out over a few passes (and the
    /// models load into it), so the scroll is repeated until that settles; a repeat where it already is moves nothing.
    @MainActor private func scrollToPending(_ proxy: ScrollViewProxy) {
        guard let id = SpeechPane.pendingScroll else { return }
        for (i, delay) in [0, 0.15, 0.4, 0.8].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard SpeechPane.pendingScroll == id else { return }
                proxy.scrollTo(id, anchor: .top)
                if i == 3 { SpeechPane.pendingScroll = nil }
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in PaneFrame {
            machineSection
            DictationModelsSection()
            languagesSection
            modelsSection
            resourcesSection
            cloudSection
            advancedSection
        }
        .onAppear { scrollToPending(proxy) }
        .onReceive(NotificationCenter.default.publisher(for: SpeechPane.scrollRequest)) { _ in scrollToPending(proxy) }
        }
        .task { await m.load() }
        .alert(S("speech.remove.title"), isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button(S("speech.remove.confirm"), role: .destructive) { if let r = confirmRemove { m.remove(r) }; confirmRemove = nil }
            Button(S("speech.cancel"), role: .cancel) { confirmRemove = nil }
        } message: { Text(confirmRemove?.path ?? "") }
    }

    // MARK: This Mac + what it uses

    @ViewBuilder var machineSection: some View {
        Section {
            if let s = m.state {
                MachineRow(hw: s.hardware)
                Toggle(isOn: Binding(get: { m.auto }, set: { m.setAuto($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(S("speech.auto.title"))
                        Text(S("speech.auto.detail")).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(ASRPurpose.allCases) { p in purposeRow(p) }
                ForEach(suggestions, id: \.model.id) { sug in suggestionRow(sug.model, purposes: sug.purposes) }
            } else if m.loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(S("speech.loading")).foregroundStyle(.secondary) }
            }
        } header: {
            HStack {
                Text(S("speech.section.machine"))
                Spacer()
                if m.loading && m.state != nil { ProgressView().controlSize(.mini) }
            }
        } footer: {
            if let e = m.error { Text(e).font(.caption).foregroundStyle(Color.brandErr) }
        }
    }

    func purposeRow(_ p: ASRPurpose) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: p.symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title)
                Text(p.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if m.auto {
                Text(m.selected(p)?.title ?? "—").foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(get: { m.selected(p)?.id ?? "" }, set: { id in
                    if let x = m.model(id) { m.choose(x, for: p) }
                })) {
                    ForEach(choices(p)) { x in Text(x.title).tag(x.id) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Installed models that run here (cloud ones when a key is set and local-only is off).
    func choices(_ p: ASRPurpose) -> [ASRModel] {
        var out = m.models.filter { $0.installed && ($0.runsHere ?? true) && ($0.local || !m.localOnly) }
        if let cur = m.selected(p), !out.contains(cur) { out.insert(cur, at: 0) }
        return out
    }

    /// Recommended models that aren't downloaded yet, with the purposes they would take over.
    var suggestions: [(model: ASRModel, purposes: [ASRPurpose])] {
        guard m.auto else { return [] }
        var out: [(model: ASRModel, purposes: [ASRPurpose])] = []
        for p in ASRPurpose.allCases {
            guard let r = m.recommended(p), !r.installed, r.local else { continue }
            if let i = out.firstIndex(where: { $0.model.id == r.id }) { out[i].purposes.append(p) } else { out.append((r, [p])) }
        }
        return out
    }

    func suggestionRow(_ x: ASRModel, purposes: [ASRPurpose]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Color.brandInk).frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(S("speech.suggest.title", x.title)).fontWeight(.medium)
                    Text(suggestionDetail(x, purposes)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if m.download[x.id] == nil {
                    Button(S("speech.suggest.download", modelSize(x.sizeMB))) { m.startDownload(x) }
                        .disabled(!(x.runsHere ?? true))
                }
            }
            if let d = m.download[x.id] { DownloadBar(d: d) { m.cancelDownload(x) }.padding(.leading, 32) }
            if let f = m.failed[x.id] { Text(f).font(.caption).foregroundStyle(Color.brandErr).padding(.leading, 32) }
        }
        .padding(.vertical, 4)
    }

    func suggestionDetail(_ x: ASRModel, _ purposes: [ASRPurpose]) -> String {
        let uses = Loc.list(purposes.map { $0.title.lowercased(with: Loc.locale) })
        var parts = [S("speech.suggest.for", uses)]
        let cur = purposes.compactMap { m.selected($0) }.first
        if let c = cur, let a = m.errorRate(c)?.value, let b = m.errorRate(x)?.value, b < a * 0.8, a > 0 {
            parts.append(S("speech.suggest.better", percent(a), percent(b)))
        } else if let c = cur, !m.missing(c).isEmpty, m.missing(x).isEmpty {
            parts.append(S("speech.suggest.languages", Loc.list(m.missing(c).map(languageName))))
        }
        return sentences(parts)
    }

    // MARK: Languages

    @ViewBuilder var languagesSection: some View {
        Section {
            FlowLayout(spacing: 6) {
                ForEach(m.languages, id: \.self) { code in
                    LanguageChip(title: endonym(code), help: languageName(code), removable: m.languages.count > 1) {
                        m.setLanguages(m.languages.filter { $0 != code })
                    }
                }
                Menu {
                    ForEach(offeredLanguages.filter { !m.languages.contains($0) }, id: \.self) { code in
                        Button(endonym(code) + (endonym(code) == languageName(code) ? "" : " — " + languageName(code))) {
                            m.setLanguages(m.languages + [code])
                        }
                    }
                } label: {
                    Label(S("speech.languages.add"), systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.vertical, 2)
        } header: { Text(S("speech.section.languages")) } footer: {
            Text(S(m.state?.languagesSet == true ? "speech.languages.footer" : "speech.languages.footer.system"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The comparison

    @ViewBuilder var modelsSection: some View {
        let here = m.models.filter { $0.local && ($0.runsHere ?? true) }
        let elsewhere = m.models.filter { $0.local && !($0.runsHere ?? true) }.count
        Section {
            ForEach(here) { modelRow($0) }
        } header: { Text(S("speech.section.models")) } footer: {
            VStack(alignment: .leading, spacing: 3) {
                Text(S("speech.models.footer")).fixedSize(horizontal: false, vertical: true)
                if elsewhere > 0 { Text(S("speech.models.elsewhere")) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    func modelRow(_ x: ASRModel) -> some View {
        let uses = (x.purposes ?? []).compactMap(ASRPurpose.init(rawValue:))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(tone: x.installed ? (uses.isEmpty ? .off : .good) : .off)
                    .opacity(x.installed ? 1 : 0.5)
                Text(x.title).fontWeight(uses.isEmpty ? .regular : .semibold)
                if !uses.isEmpty {
                    Text(uses.map(\.title).joined(separator: " · "))
                        .font(.caption2.weight(.medium)).foregroundStyle(Color.brandInk)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.brandTint))
                }
                Spacer(minLength: 8)
                actions(x, inUse: !uses.isEmpty)
            }
            HStack(spacing: 14) {  // fixed minimum widths: the columns line up from one model to the next
                Metric(label: S("speech.metric.accuracy"), value: m.errorRate(x).map { percent(max(0, 1 - $0.value)) } ?? "—",
                       measured: m.errorRate(x)?.measured).frame(minWidth: 76, alignment: .leading)
                Metric(label: S("speech.metric.speed"), value: m.speed(x).map { S("speech.metric.speed.value", decimal($0.value)) } ?? "—",
                       measured: m.speed(x)?.measured).frame(minWidth: 112, alignment: .leading)
                Metric(label: S("speech.metric.memory"), value: m.memory(x).map { mb($0.value) } ?? "—",
                       measured: m.memory(x)?.measured).frame(minWidth: 80, alignment: .leading)
                Metric(label: S("speech.metric.size"), value: (x.approx == true ? "≈ " : "") + modelSize(x.sizeMB), measured: nil)
            }
            .padding(.leading, 17)
            Text(coverage(x)).font(.caption).foregroundStyle(.secondary).padding(.leading, 17)
                .fixedSize(horizontal: false, vertical: true)
            if let d = m.download[x.id] { DownloadBar(d: d) { m.cancelDownload(x) }.padding(.leading, 17) }
            if let f = m.failed[x.id] { Text(f).font(.caption).foregroundStyle(Color.brandErr).padding(.leading, 17) }
            if let b = m.bench[x.id], let e = b.error { Text(e).font(.caption).foregroundStyle(Color.brandErr).padding(.leading, 17) }
        }
        .padding(.vertical, 3)
    }

    func coverage(_ x: ASRModel) -> String {
        let miss = m.missing(x)
        return sentences([x.qualityNoteKey.map { S($0) } ?? "",
                          miss.isEmpty ? S("speech.coverage.all") : S("speech.coverage.missing", Loc.list(miss.map(languageName)))])
    }

    @ViewBuilder
    func actions(_ x: ASRModel, inUse: Bool) -> some View {
        HStack(spacing: 6) {
            if x.installed {
                if m.benching.contains(x.id) {
                    ProgressView().controlSize(.small)
                    Text(S("speech.bench.running")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(S("speech.bench.button")) { Task { await m.runBench(x) } }
                        .controlSize(.small)
                        .help(S("speech.bench.help"))
                }
            } else if m.download[x.id] == nil {
                Button(S("speech.download.button")) { m.startDownload(x) }.controlSize(.small)
            }
            if m.canRemove(x) && !inUse {
                Button { confirmRemove = x } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help(S("speech.remove.confirm"))
                    .accessibilityLabel(S("speech.remove.confirm"))
            }
        }
    }

    // MARK: Resources

    @ViewBuilder var resourcesSection: some View {
        if let s = m.state {
            let cores = s.hardware.perfCores + s.hardware.effCores
            Section {
                Stepper(value: Binding(get: { s.limits.threads }, set: { m.setLimit("threads", $0) }), in: 1...max(1, cores)) {
                    LabeledRow(title: S("speech.limits.threads"), value: decimal(Double(s.limits.threads)),
                               detail: S("speech.limits.threads.detail", decimal(Double(cores))))
                }
                Stepper(value: Binding(get: { s.limits.maxConcurrent }, set: { m.setLimit("max_concurrent", $0) }), in: 1...4) {
                    LabeledRow(title: S("speech.limits.concurrent"), value: decimal(Double(s.limits.maxConcurrent)),
                               detail: S("speech.limits.concurrent.detail"))
                }
                if s.hardware.gpu.kind == "apple" {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledRow(title: S("speech.limits.memory"), value: percent(s.limits.maxMemoryFraction, digits: 0),
                                   detail: S("speech.limits.memory.detail", mb(s.hardware.ramGB * 1024 * s.limits.maxMemoryFraction)))
                        Slider(value: Binding(get: { s.limits.maxMemoryFraction }, set: { v in
                            m.state?.limits.maxMemoryFraction = (v * 20).rounded() / 20
                        }), in: 0.1...0.5, step: 0.05) { editing in
                            if !editing, let f = m.state?.limits.maxMemoryFraction { m.setLimit("max_memory_fraction", f) }
                        }
                        .accessibilityLabel(S("speech.limits.memory"))
                    }
                }
                Toggle(isOn: Binding(get: { m.onBattery == "lighter" }, set: { m.setOnBattery($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(S("speech.limits.battery"))
                        Text(S("speech.limits.battery.detail")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text(S("speech.section.resources")) } footer: {
                Text(S("speech.limits.footer")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Cloud

    @ViewBuilder var cloudSection: some View {
        Section {
            ForEach(m.models.filter { !$0.local }) { x in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StatusDot(tone: x.installed && !m.localOnly ? .good : .off)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(x.title)
                        Text((x.keys ?? []).joined(separator: "  ")).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(x.installed ? S("speech.cloud.set") : S("speech.cloud.not_set")).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: { Text(S("speech.section.cloud")) } footer: {
            Text(S(m.localOnly ? "speech.cloud.local_only" : "speech.cloud.keys"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Advanced

    @ViewBuilder var advancedSection: some View {
        Section {
            Picker(S("speech.advanced.language"), selection: Binding(get: { m.language }, set: { m.setLanguage($0) })) {
                Text(S("speech.advanced.language.auto")).tag("auto")
                ForEach(m.languages, id: \.self) { Text(endonym($0)).tag($0) }
            }
            Toggle(S("speech.advanced.mirror"), isOn: Binding(get: { m.mirror }, set: { m.setMirror($0) }))
        } header: { Text(S("speech.section.advanced")) }
    }
}

// MARK: - Pieces

/// "Apple M5 Max · 128 GB memory · 40-core GPU" with the tier the models were picked for.
private struct MachineRow: View {
    var hw: ASRHardware
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: hw.gpu.kind == "apple" ? "cpu" : "memorychip")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.brandInk)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.brandTint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(hw.chip ?? S("speech.machine.unknown")).font(.headline)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(S("speech.tier.\(hw.tier)"))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                if hw.onBattery == true { Text(S("speech.machine.battery")).font(.caption2).foregroundStyle(.secondary) }
            }
            .help(S("speech.tier.\(hw.tier).help"))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    var details: String {
        var parts = [S("speech.machine.memory", mb(hw.ramGB * 1024))]
        if let c = hw.gpu.cores { parts.append(S("speech.machine.gpu_cores", decimal(Double(c)))) }
        else if let v = hw.gpu.vramGB, let n = hw.gpu.name { parts.append("\(n) · " + mb(v * 1024)) }
        parts.append(S("speech.machine.cpu_cores", decimal(Double(hw.perfCores + hw.effCores))))
        return parts.joined(separator: " · ")
    }
}

private struct Metric: View {
    var label: String
    var value: String
    var measured: Bool?
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary).textCase(nil)
            HStack(spacing: 3) {
                Text(value).font(.callout.weight(.medium)).monospacedDigit()
                if measured == true {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 9)).foregroundStyle(Color.brandOk)
                        .help(S("speech.metric.measured"))
                        .accessibilityLabel(S("speech.metric.measured"))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LabeledRow: View {
    var title: String
    var value: String
    var detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DownloadBar: View {
    var d: (done: Double, total: Double, text: String)
    var cancel: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: d.total > 0 ? min(d.done, d.total) : 0, total: max(d.total, 1))
            Text(d.text).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                .frame(minWidth: 120, alignment: .trailing)
            Button(S("speech.download.stop"), action: cancel).controlSize(.small)
        }
    }
}

private struct LanguageChip: View {
    var title: String
    var help: String
    var removable: Bool
    var remove: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.callout)
            if removable {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(hover ? .primary : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(S("speech.languages.remove", title))
            }
        }
        .padding(.leading, 9).padding(.trailing, removable ? 6 : 9).padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(hover ? 0.18 : 0.11)))
        .onHover { hover = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Left-to-right wrapping layout for the language chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
