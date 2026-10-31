// Dictation's choices side by side, so a user can judge for themselves (docs/design/system.md §3.4, Settings → Models;
// the numbers: BlurtCore DictationChoices, from docs/design/dictation-eval-2026-10-31.md §7).
//
//   the lead     the Models page's one lead line: "Recommended for this Mac: Qwen3-ASR 1.7B", with Compare… at its
//                right end (the page stays as it was under it).
//   the sheet    "Dictation choices": this Mac (chip, memory) and how it was measured in one line, then one row per
//                choice — macOS Speech, Qwen3-ASR 0.6B, Fun-ASR-Nano (Chinese / English / Japanese speakers only),
//                1.7B, the local model + cloud polish, cloud recognition — with
//                Accuracy (a 5-mark meter, DictationChoices.level: how good, never a count of mistakes — in the
//                user's own language when it isn't Chinese and was measured), Delay (after you stop talking), Cost (free + the download; per dictation; per hour)
//                and what leaves the Mac (nothing / your text / your voice, and to whom). Under a row's name:
//                Recommended (badge), In use (check, brand ink), or what it needs here (16 GB of memory, Apple
//                silicon, macOS 26). Its action: Use, Download (the app's one download manager, used once it is in),
//                its bar and Stop while it comes down, Add Key… for a cloud row with no service (Settings → Models'
//                Add Service sheet; the row is used once the key is in). Done (Return) / Esc / a click outside close.
//   opened from  the lead's Compare…, the dictation row's pop-up ("Compare Choices…"), a search ("speech.compare").
// The setup assistant's speech step names the same choices in its own lines (ChoiceText), without numbers.
import AppKit
import SwiftUI
import BlurtCore

private func S(_ key: String, _ args: CVarArg...) -> String {
    let fmt = Loc.string(key, table: "Speech")
    return args.isEmpty ? fmt : String(format: fmt, locale: Loc.locale, arguments: args)
}

// MARK: - where this Mac stands

/// What the table needs to know about this Mac and dictation now, read from the speech lists and the cloud setup.
@MainActor
struct DictationNow {
    let mac: DictationChoices.Mac
    /// dictation's recogniser now (nil: none in yet)
    let recognizer: String?
    let inUse: DictationChoice?
    let recommended: DictationChoice
    /// the local model cloud polish runs on here
    let base: DictationChoice
    /// "Apple M2, 8 GB" (nil while it is read)
    let machine: String?

    static func read() -> DictationNow {
        let m = SpeechModel.shared, d = DictationModels.shared
        let hw = m.state?.hardware
        #if arch(arm64)
        let arm = true
        #else
        let arm = false
        #endif
        let ram = hw?.ramGB ?? Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let connected = CloudStore.connected
        let models = d.asr?.models ?? []
        let mac = DictationChoices.Mac(
            ramGB: ram, appleSilicon: hw.map { $0.gpu.kind == "apple" } ?? arm,
            macOSSpeech: models.contains { $0.id == DictationChoice.macOSSpeech.rawValue } || AppleSpeech.available,
            textKey: CloudStore.curatedConnected(.polish) || CloudStore.cloudModel(.polish) != nil,
            speechKey: connected.contains { $0.preset == "dashscope" } || models.contains { $0.id == DictationChoice.cloudRecognizer.rawValue },
            rtf: m.model(DictationChoice.qwenLarge.rawValue)?.bench?.rtf, slowChip: DictationTier.slowChip(hw?.chip),
            languages: m.languages.isEmpty ? Locale.preferredLanguages : m.languages)
        let rec = d.asr.flatMap { a in (a.selectedInstalled ?? true) ? a.selected : nil }
        let machine = hw.map { S("speech.machine.short", $0.chip ?? S("speech.machine.unknown"), ChoiceText.memory($0.ramGB)) }
        return DictationNow(mac: mac, recognizer: rec,
                            inUse: DictationChoices.inUse(recognizer: rec, cloudPolish: CloudStore.cloudModel(.polish) != nil),
                            recommended: DictationChoices.recommended(mac),
                            base: DictationChoices.polishBase(recognizer: rec, mac: mac), machine: machine)
    }

    func facts(_ c: DictationChoice) -> DictationFacts { DictationChoices.facts(c, on: base) }
    func fit(_ c: DictationChoice) -> DictationChoices.Fit { DictationChoices.fit(c, on: base, mac: mac) }
}

// MARK: - the words (shared with the setup assistant)

enum ChoiceText {
    /// A choice's name: the model's own, "1.7B + cloud polish", "Cloud recognition".
    @MainActor static func name(_ c: DictationChoice, base: DictationChoice, short: Bool = true) -> String {
        switch c {
        case .cloudPolish:
            let b = model(base.rawValue)
            return S("speech.compare.cloud_polish", short ? b.replacingOccurrences(of: "Qwen3-ASR ", with: "") : b)
        case .cloudRecognizer: return S("speech.compare.cloud_asr")
        default: return model(c.rawValue)
        }
    }

    @MainActor static func model(_ id: String) -> String { DictationModels.shared.asrName(id) }

    /// The error the meter shows for a choice: the user's own language's when it is measured, else the mixed one.
    static func error(_ f: DictationFacts, _ lang: String?) -> Double { lang.flatMap { f.languages[$0] } ?? f.mixed }

    /// Memory the way the Models page says it ("8 GB", as the Mac's own About says).
    static func memory(_ gb: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(gb * 1_073_741_824), countStyle: .memory)
    }

    static func seconds(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = Loc.locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return f.string(from: v as NSNumber) ?? "\(v)"
    }

    /// "~0.2 s", "0.2–0.3 s"
    static func delay(_ r: ClosedRange<Double>) -> String {
        r.lowerBound == r.upperBound ? S("speech.compare.delay.one", seconds(r.lowerBound))
            : S("speech.compare.delay.range", seconds(r.lowerBound), seconds(r.upperBound))
    }

    /// The price in the money the service bills in here: yuan in mainland China, US dollars elsewhere.
    static func money(cny: Double, usd: Double) -> String {
        let china = CloudRegion.forSystem(Locale.current.region?.identifier) == .china
        let f = NumberFormatter()
        f.locale = Loc.locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 4
        f.minimumFractionDigits = 0
        let v = china ? cny : usd
        return "≈ " + (china ? "¥" : "$") + (f.string(from: v as NSNumber) ?? "\(v)")
    }

    /// The cost cell: what it costs, and per what (or the download).
    static func cost(_ f: DictationFacts, sizeMB: Double?, installed: Bool = false) -> (String, String) {
        switch f.cost {
        case .free:
            if installed { return (S("speech.compare.free"), S("speech.compare.installed")) }
            let mb = sizeMB ?? f.downloadMB
            return (S("speech.compare.free"), mb > 0 ? S("speech.compare.download", modelSize(mb)) : S("speech.compare.builtin"))
        case .perDictation(let cny, let usd): return (money(cny: cny, usd: usd), S("speech.compare.per_dictation"))
        case .perHour(let cny, let usd): return (money(cny: cny, usd: usd), S("speech.compare.per_hour"))
        }
    }

    /// "to DeepSeek" / 「发往 DeepSeek」, 「发往阿里云」 (no space before a Chinese name).
    static func to(_ name: String) -> String { tight(S("speech.compare.to", name), name) }

    /// Chinese puts a space between Chinese and Latin words, none between two Chinese ones: 「发给 DeepSeek」,
    /// 「发给阿里云百炼」.
    static func tight(_ s: String, _ name: String) -> String {
        guard Loc.isChinese, let c = name.unicodeScalars.first, c.properties.isIdeographic else { return s }
        return s.replacingOccurrences(of: " " + name, with: name)
    }

    /// What leaves the Mac, and where it goes.
    @MainActor static func leaves(_ f: DictationFacts) -> (String, String?) {
        switch f.leaves {
        case .nothing: return (S("speech.compare.leaves.nothing"), nil)
        case .text:
            let to = CloudStore.cloudModel(.polish)?.service ?? CloudRouting.ranked(CloudStore.connected).first.map(CloudStore.name)
            return (S("speech.compare.leaves.text"), to.map(Self.to) ?? S("speech.compare.to.any"))
        case .voice: return (S("speech.compare.leaves.voice"), to(S("speech.compare.alibaba")))
        }
    }

    /// The page's lead: "Recommended for this Mac: Qwen3-ASR 1.7B".
    @MainActor static func lead(_ now: DictationNow) -> String {
        S("speech.compare.lead", name(now.recommended, base: now.base, short: false))
    }

    static func fit(_ f: DictationChoices.Fit) -> String? {
        switch f {
        case .fits, .needsKey: return nil
        case .needsMemory(let gb): return S("speech.compare.needs_memory", memory(Double(gb)))
        case .needsAppleSilicon: return S("speech.compare.needs_apple")
        case .needsMacOS26: return S("speech.compare.needs_macos")
        }
    }
}

// MARK: - what a row's action does

@MainActor
enum DictationChoiceAction {
    /// Make a choice dictation's: its recogniser (downloaded first when it isn't here: used once it is in), and polish
    /// on this Mac for a local choice (the row says nothing leaves the Mac) or on the connected service for cloud
    /// polish. Every other job keeps its setting.
    static func use(_ c: DictationChoice, now: DictationNow) {
        switch c {
        case .macOSSpeech, .qwenSmall, .funNano, .qwenLarge:
            if CloudStore.cloudModel(.polish) != nil { CloudStore.setChoice(.local, for: .polish) }
            recognizer(c.rawValue)
        case .cloudPolish:
            if CloudStore.setup.choice(.polish) == .local { CloudStore.setChoice(.auto, for: .polish) }
            if now.recognizer != now.base.rawValue, DictationChoices.inUse(recognizer: now.recognizer, cloudPolish: true) != .cloudPolish {
                recognizer(now.base.rawValue)
            }
        case .cloudRecognizer:
            recognizer(c.rawValue)
        }
        Dictation.shared.apply()
        CloudModelsUI.shared.bump()
        emit(["event": "dictation_compare_use", "choice": c.rawValue])
    }

    private static func recognizer(_ id: String) {
        let d = DictationModels.shared
        guard let x = d.asr?.models.first(where: { $0.id == id }) else { return }
        if x.installed || x.builtin == true { d.chooseASR(x) } else { d.installASR(x) }
    }

    /// The download this choice is waiting on (its recogniser), when one is running or queued.
    static func downloading(_ c: DictationChoice, now: DictationNow) -> String? {
        let id = c == .cloudPolish ? now.base.rawValue : c.rawValue
        let dl = ModelDownloads.shared
        return dl.queue.contains(id) ? id : nil
    }

    /// Its recogniser needs downloading first.
    static func needsDownload(_ c: DictationChoice, now: DictationNow) -> Bool {
        guard c != .cloudRecognizer, c != .macOSSpeech else { return false }
        let id = c == .cloudPolish ? now.base.rawValue : c.rawValue
        return DictationModels.shared.asr?.models.first { $0.id == id }?.installed != true
    }
}

// MARK: - the sheet

struct DictationCompareSheet: View {
    var close: () -> Void
    @ObservedObject var m = SpeechModel.shared
    @ObservedObject var d = DictationModels.shared
    @ObservedObject private var dl = ModelDownloads.shared
    @ObservedObject private var ui = CloudModelsUI.shared
    /// Add Key…: the service sheet, and the row to use once a key is in
    @State private var adding: Adding?
    struct Adding: Identifiable { var choice: DictationChoice; var id: String { choice.rawValue } }

    /// fixed columns, so the numbers line up from row to row
    enum Col {
        static let accuracy: CGFloat = 158, delay: CGFloat = 66, cost: CGFloat = 96, leaves: CGFloat = 112
        static let action: CGFloat = 86, gap: CGFloat = 10
    }

    var body: some View {
        _ = ui.tick
        let now = DictationNow.read()
        let lang = DictationChoices.ownLanguage(m.languages.isEmpty ? Locale.preferredLanguages : m.languages)
        return VStack(alignment: .leading, spacing: 0) {
            Text(S("speech.compare.title")).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(CloudText.sentences([now.machine.map { S("speech.compare.mac", $0) } ?? "", S("speech.compare.note")].filter { !$0.isEmpty }))
                .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            SettingsGroup("speech.compare", title: "") {
                header
                ForEach(DictationChoices.choices(now.mac, inUse: now.inUse == .cloudPolish ? now.base : now.inUse), id: \.self) { c in
                    row(c, now: now, lang: lang)
                }
            }
            .padding(.top, -12)
            HStack {
                Spacer()
                Button(S("speech.lib.done"), action: close).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
        .frame(width: 800)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $adding) { a in
            // Model Studio for cloud recognition (its key recognises speech); any service for polish
            CloudServiceSheet(editing: nil, preset: a.choice == .cloudRecognizer ? "dashscope" : nil) {
                adding = nil
                Task { @MainActor in
                    await d.load()
                    let after = DictationNow.read()
                    if after.fit(a.choice) == .fits { DictationChoiceAction.use(a.choice, now: after) }
                }
            }
            .buttonStyle(.automatic)
        }
    }

    var header: some View {
        HStack(spacing: Col.gap) {
            Color.clear.frame(maxWidth: .infinity)
            headerCell(S("speech.compare.col.accuracy"), Col.accuracy, help: S("speech.compare.col.accuracy.help"))
            headerCell(S("speech.compare.col.delay"), Col.delay, help: S("speech.compare.col.delay.help"))
            headerCell(S("speech.compare.col.cost"), Col.cost)
            headerCell(S("speech.compare.col.leaves"), Col.leaves)
            Color.clear.frame(width: Col.action)
        }
        .padding(.bottom, 5)
    }

    func headerCell(_ t: String, _ width: CGFloat, help: String = "") -> some View {
        Text(t).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            .frame(width: width, alignment: .leading)
            .help(help)
    }

    /// A cell: the value, and one quiet line under it.
    func cell(_ top: String, _ under: String?, _ width: CGFloat, help: String = "", dim: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(top).font(.system(size: SettingsMetrics.detailSize)).monospacedDigit()
                .foregroundStyle(dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            if let u = under {
                Text(u).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: width, alignment: .leading)
        .help(help)
    }

    func row(_ c: DictationChoice, now: DictationNow, lang: String?) -> some View {
        let f = now.facts(c)
        let fit = now.fit(c)
        let runs = fit == .fits || fit == .needsKey
        let inUse = now.inUse == c
        let model = c.local ? d.asr?.models.first { $0.id == c.rawValue } : nil
        let (cost, per) = ChoiceText.cost(f, sizeMB: model?.sizeMB, installed: model?.installed == true && c != .macOSSpeech)
        let (leaves, to) = ChoiceText.leaves(f)
        let help: String = {
            switch c {
            case .cloudPolish: return S("speech.compare.cloud_polish.help", ChoiceText.model(now.base.rawValue))
            case .cloudRecognizer: return S("speech.compare.cloud_asr.help")
            default: return ""
            }
        }()
        return SettingsLine(padding: 6) {
            HStack(alignment: .center, spacing: Col.gap) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ChoiceText.name(c, base: now.base)).font(.system(size: SettingsMetrics.titleSize)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(runs ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    marks(c, now: now, fit: fit, inUse: inUse)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(help)
                AccuracyMeter(level: DictationChoices.level(ChoiceText.error(f, lang)), dim: !runs)
                    .frame(width: Col.accuracy, alignment: .leading)
                    .help(S("speech.compare.col.accuracy.help"))
                cell(ChoiceText.delay(f.delay), nil, Col.delay, dim: !runs)
                cell(cost, per, Col.cost, dim: !runs)
                cell(leaves, to, Col.leaves, dim: !runs)
                HStack(spacing: 0) { Spacer(minLength: 0); action(c, now: now, fit: fit, inUse: inUse) }.frame(width: Col.action)
            }
            .frame(minHeight: 34)
            .accessibilityElement(children: .contain)
        }
    }

    /// Under the name: Recommended, In use, or what this Mac lacks for it.
    @ViewBuilder func marks(_ c: DictationChoice, now: DictationNow, fit: DictationChoices.Fit, inUse: Bool) -> some View {
        let rec = now.recommended == c
        if let why = ChoiceText.fit(fit) {
            Text(why).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        } else if rec || inUse {
            HStack(spacing: 6) {
                if rec { Badge(S("speech.tag.recommended")) }
                if inUse {
                    Label(S("speech.compare.in_use"), systemImage: "checkmark")
                        .labelStyle(.titleAndIcon).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.brandInk)
                }
            }
        }
    }

    @ViewBuilder func action(_ c: DictationChoice, now: DictationNow, fit: DictationChoices.Fit, inUse: Bool) -> some View {
        if inUse {
            EmptyView()
        } else if fit == .needsKey {
            Button(S("speech.compare.add_key")) { adding = Adding(choice: c) }.controlSize(.small)
        } else if fit != .fits {
            EmptyView()
        } else if let id = DictationChoiceAction.downloading(c, now: now) {
            HStack(spacing: 6) {
                let p = dl.progress(id)
                ProgressView(value: min(p?.done ?? 0, p?.total ?? 1), total: max(p?.total ?? 1, 1)).controlSize(.small).frame(width: 56)
                Button { dl.stop(id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).help(S("speech.download.stop")).accessibilityLabel(S("speech.download.stop"))
            }
        } else if DictationChoiceAction.needsDownload(c, now: now) {
            Button(S("speech.download.button")) { DictationChoiceAction.use(c, now: now) }.controlSize(.small)
        } else {
            Button(S("speech.lib.use")) { DictationChoiceAction.use(c, now: now) }.controlSize(.small)
        }
    }

}

/// Accuracy as five marks, the filled ones in the brand's ink (DictationChoices.level).
struct AccuracyMeter: View {
    let level: Int
    var dim = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Capsule()
                    .fill(i <= level ? AnyShapeStyle(dim ? Color.secondary : Color.brandInk) : AnyShapeStyle(.quaternary))
                    .frame(width: 12, height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(S("speech.compare.col.accuracy"))
        .accessibilityValue("\(level) / 5")
    }
}
