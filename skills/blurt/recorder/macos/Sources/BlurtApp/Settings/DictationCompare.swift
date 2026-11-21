// Dictation's choices side by side, so a user can judge for themselves (docs/design/system.md §3.4, Settings → Models;
// the numbers: BlurtCore DictationChoices, from docs/design/dictation-eval-2026-10-31.md §7).
//
//   the lead     the Models page's one lead line: "Recommended for this Mac: Qwen3-ASR 1.7B", with Compare… at its
//                right end (the page stays as it was under it).
//   the sheet    "Dictation Choices" and how it was measured in one line, then two open sections on one grid (the
//                title, the headings, the names and Done share the sheet's 22 pt edges):
//                  On this Mac — "Free, nothing leaves your Mac" said once under the heading — macOS Speech,
//                    Qwen3-ASR 0.6B, Fun-ASR-Nano (Chinese / English / Japanese speakers only), Qwen3-ASR 1.7B, with
//                    Accuracy, Delay, Download (its size, Downloaded, Built in) and Memory (while you dictate);
//                  Cloud — "Uses your own API key" — Qwen3-ASR 1.7B + cloud polish, Qwen3-ASR Flash (Alibaba Cloud),
//                    Doubao Seed-ASR 2.0 (Volcengine; Chinese speakers only: streamed while you talk, best with cloud
//                    polish), with Accuracy, Delay, Cost per hour (one unit: cloud polish estimated from ten-second
//                    dictations, its per-dictation figure in the cell's tooltip) and Uploaded ("Voice → Alibaba Cloud").
//                Each section: the recommended row first, then by accuracy, then by delay. Accuracy is a five-segment
//                meter in half steps (DictationChoices.halves: how good, never a count of mistakes — in the user's own
//                language when it isn't Chinese and was measured), so the cloud's ≤ 2.2 % reads above the 1.7B's 2.5 %.
//                After a name, on its line: the Recommended tag (neutral ink on brand tint) or what this Mac lacks for
//                it (16 GB of memory, Apple silicon, macOS 26: the row goes secondary and has no action).
//                One thing in the action column: In Use (a brand-ink check), or the row's action — Use, Download (the
//                app's one download manager, used once it is in), Add Key… for a cloud row with no service (Settings →
//                Models' Add Service sheet; used once the key is in). At rest only the recommended row shows its
//                action; the others show theirs on hover (a faint row tint) or keyboard focus; a download in progress
//                keeps its bar and Stop. Footer: this Mac (chip, memory) on the left, Done (the brand default, Return)
//                on the right; Esc / a click outside also close.
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
            languages: m.languages.isEmpty ? Locale.preferredLanguages : m.languages,
            volcengineKey: connected.contains { $0.preset == VolcengineSpeech.preset })
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
    /// A choice's name: the model's own ("Qwen3-ASR Flash", "Doubao Seed-ASR 2.0"), or "Qwen3-ASR 1.7B + cloud polish"
    /// ("1.7B + cloud polish" when `short`, where the row above names the model).
    @MainActor static func name(_ c: DictationChoice, base: DictationChoice, short: Bool = false) -> String {
        switch c {
        case .cloudPolish:
            let b = model(base.rawValue)
            return S("speech.compare.cloud_polish", short ? b.replacingOccurrences(of: "Qwen3-ASR ", with: "") : b)
        default: return model(c.rawValue)
        }
    }

    @MainActor static func model(_ id: String) -> String { DictationModels.shared.asrName(id) }

    /// What the figures are based on: the user's own language when it was measured, else Chinese mixed with English.
    static func note(_ lang: String?) -> String {
        guard let l = lang else { return S("speech.compare.note") }
        return S("speech.compare.note.lang", Loc.locale.localizedString(forLanguageCode: l) ?? l)
    }

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

    /// "≈ 0.2 s" / 「约 0.2 秒」, "0.2–0.3 s"
    static func delay(_ r: ClosedRange<Double>) -> String {
        r.lowerBound == r.upperBound ? S("speech.compare.delay.one", seconds(r.lowerBound))
            : S("speech.compare.delay.range", seconds(r.lowerBound), seconds(r.upperBound))
    }

    /// Whether prices are said in yuan (mainland China) or US dollars (elsewhere): the money the service bills in.
    static var yuan: Bool { CloudRegion.forSystem(Locale.current.region?.identifier) == .china }

    /// "¥0.8" / "$0.11": the price in the money the service bills in here, `digits` after the point at most.
    static func amount(cny: Double, usd: Double, digits: Int = 4, minDigits: Int = 0) -> String {
        let f = NumberFormatter()
        f.locale = Loc.locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = digits
        f.minimumFractionDigits = minDigits
        let v = yuan ? cny : usd
        return (yuan ? "¥" : "$") + (f.string(from: v as NSNumber) ?? "\(v)")
    }

    /// An estimate: "≈ ¥0.8" / 「约 ¥0.8」 (one marker for every approximate figure, the delays' too).
    static func approx(_ s: String) -> String { S("speech.compare.approx", s) }

    /// A per-use price as a whole number of a round batch, the figure a reader can hold without arithmetic: "¥1" per
    /// 1,000 uses in China, "$1" per 10,000 elsewhere (¥0.001 a use read as nothing and invited no comparison). Uses,
    /// not dictations: the same cloud model translates and reads screen text too. `per`: "1,000 uses" / 「每千次」.
    static func batch(cny: Double, usd: Double) -> (amount: String, per: String) {
        yuan ? (amount(cny: cny * 1000, usd: usd * 1000), S("speech.compare.per_1000"))
            : (amount(cny: cny * 10000, usd: usd * 10000), S("speech.compare.per_10000"))
    }

    /// DeepSeek's cloud polish as `batch`, without "≈" (the lines that show it say "about" themselves): Settings →
    /// Models' services and the setup assistant's cloud row.
    static var cloudPolishPrice: (amount: String, per: String)? {
        guard case .perDictation(let cny, let usd) = DictationChoices.facts(.cloudPolish).cost else { return nil }
        return batch(cny: cny, usd: usd)
    }

    /// The Cost per hour cell of a cloud row: "≈ ¥0.8", "≈ $0.11" (yuan to one decimal, dollars to the cent) — one unit
    /// for every row, so they compare (DictationChoices.perHour); nil for a free one.
    static func hourly(_ f: DictationFacts) -> String? {
        DictationChoices.perHour(f).map { approx(amount(cny: $0.cny, usd: $0.usd, digits: yuan ? 1 : 2, minDigits: yuan ? 0 : 2)) }
    }

    /// Cloud polish's hourly figure is an estimate: what one dictation costs, for its tooltip.
    static var polishPerDictation: String {
        let p = DictationChoices.polishPerDictation
        return S("speech.compare.cost.polish.help", amount(cny: p.cny, usd: p.usd))
    }

    /// The Download cell of a local row: its size, "Downloaded", or "Built in" (macOS Speech).
    static func download(_ f: DictationFacts, sizeMB: Double?, installed: Bool) -> String {
        if installed { return S("speech.compare.installed") }
        let mb = sizeMB ?? f.downloadMB
        return mb > 0 ? modelSize(mb) : S("speech.compare.builtin")
    }

    /// Chinese puts a space between Chinese and Latin words, none between two Chinese ones: 「发给 DeepSeek」,
    /// 「发给阿里云百炼」.
    static func tight(_ s: String, _ name: String) -> String {
        guard Loc.isChinese, let c = name.unicodeScalars.first, c.properties.isIdeographic else { return s }
        return s.replacingOccurrences(of: " " + name, with: name)
    }

    /// What a cloud row uploads and to whom, on one line: "Text → DeepSeek" (the polish service in use, else the first
    /// connected one, else "your service"), "Voice → Alibaba Cloud", "Voice → Volcengine". Nil for a local row: its
    /// section says nothing leaves the Mac.
    @MainActor static func leaves(_ f: DictationFacts) -> String? {
        switch f.leaves {
        case .nothing: return nil
        case .text:
            let to = CloudStore.cloudModel(.polish)?.service ?? CloudRouting.ranked(CloudStore.connected).first.map(CloudStore.name)
            return S("speech.compare.sends.text", to ?? S("speech.compare.your_service"))
        case .voice: return S("speech.compare.sends.voice", S("speech.compare.alibaba"))
        case .voiceToVolcengine: return S("speech.compare.sends.voice", S("speech.compare.volcengine"))
        }
    }

    /// The page's lead: "Recommended for dictation: Qwen3-ASR 1.7B", "· In use" once it is the one dictation runs on —
    /// so a recommendation already taken doesn't read as one still to download.
    @MainActor static func lead(_ now: DictationNow) -> String {
        let n = name(now.recommended, base: now.base, short: false)
        return now.inUse == now.recommended ? S("speech.compare.lead.in_use", n) : S("speech.compare.lead", n)
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
        case .cloudRecognizer, .volcengine:
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
        guard !c.cloudRecognition, c != .macOSSpeech else { return false }
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
    /// the row under the pointer: its action shows (test builds: BLURT_TEST_COMPARE_HOVER=<choice id>)
    @State private var hovered: DictationChoice? = ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1"
        ? ProcessInfo.processInfo.environment["BLURT_TEST_COMPARE_HOVER"].flatMap(DictationChoice.init(rawValue:)) : nil
    /// the row whose action has the keyboard's focus (Full Keyboard Access): it shows too
    @FocusState private var focused: DictationChoice?

    /// One grid for both sections, so a column's values line up from row to row and across the two: every column its
    /// widest value in English and Chinese ("Voice → Alibaba Cloud" 126 pt, "添加密钥…" 86, "Cost per hour" 73) and
    /// 12 pt apart, which leaves every visible gutter ≥ 16 pt; the name takes the rest (≈ 208 pt: "Qwen3-ASR 1.7B + cloud
    /// polish" is 196). 740 pt wide, so the sheet stays inside the Settings window at its 760 pt minimum.
    enum Col {
        static let accuracy: CGFloat = 66, delay: CGFloat = 64, third: CGFloat = 78, fourth: CGFloat = 132
        static let action: CGFloat = 88, gap: CGFloat = 12
        /// the sheet's edges: the title, the headings, the names, the actions and Done all start or end here
        static let inset: CGFloat = 22
        static let width: CGFloat = 740
        static let row: CGFloat = 34
    }

    enum Section: CaseIterable { case local, cloud }

    var body: some View {
        _ = ui.tick
        let now = DictationNow.read()
        let lang = DictationChoices.ownLanguage(m.languages.isEmpty ? Locale.preferredLanguages : m.languages)
        let shown = DictationChoices.choices(now.mac, inUse: now.inUse == .cloudPolish ? now.base : now.inUse)
        return VStack(alignment: .leading, spacing: 0) {
            Text(S("speech.compare.title")).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(ChoiceText.note(lang))
                .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            // the catalogue's section (a search for "accuracy" lands on this sheet), open: no box, no inset of its own,
            // so the headings and names share the title's edge
            SettingsGroup("speech.compare", title: "", boxed: false) {
                ForEach(Section.allCases, id: \.self) { sec in
                    let rows = order(shown.filter { sec == .local ? $0.local : !$0.local }, now: now, lang: lang)
                    if !rows.isEmpty {
                        section(sec, rows: rows, now: now, lang: lang)
                            .padding(.top, sec == .local ? 0 : 24)
                    }
                }
            }
            .padding(.top, 18 - SettingsMetrics.groupGap)
            HStack(alignment: .center, spacing: 12) {
                if let mac = now.machine {
                    Text(S("speech.compare.mac", mac)).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(S("speech.lib.done"), action: close)
                    .buttonStyle(.borderedProminent).tint(Color.settingsDefault)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, Col.inset).padding(.top, 20).padding(.bottom, 18)
        .frame(width: Col.width)
        .fixedSize(horizontal: false, vertical: true)
        // screenshots of a test build in the background: drawn as the key sheet people see, Done filled
        .modifier(TestKeyLook(on: SettingsTestKeyLook.on))
        .sheet(item: $adding) { a in
            // Model Studio for Qwen3-ASR Flash (its key recognises speech), Volcengine Speech for its row; any service
            // for polish
            CloudServiceSheet(editing: nil, preset: a.choice == .cloudRecognizer ? "dashscope"
                              : a.choice == .volcengine ? VolcengineSpeech.preset : nil) {
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

    /// A section's rows: the recommended one first, then the more accurate, then the quicker (two rows that tie keep
    /// the table's order); one this Mac can't run (16 GB of memory, Apple silicon, macOS 26) at the section's end.
    func order(_ cs: [DictationChoice], now: DictationNow, lang: String?) -> [DictationChoice] {
        func key(_ c: DictationChoice) -> [Double] {
            let f = now.facts(c), fit = now.fit(c)
            return [now.recommended == c ? 0 : 1, fit == .fits || fit == .needsKey ? 0 : 1,
                    -Double(DictationChoices.halves(ChoiceText.error(f, lang))), f.delay.lowerBound, f.delay.upperBound]
        }
        return cs.enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            return ka != kb ? ka.lexicographicallyPrecedes(kb) : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: a section

    /// The heading (13 pt semibold) with what the whole section shares under it in one quiet line, the column names
    /// on that line's baseline, then the rows with hairlines between them (none under the heading).
    func section(_ sec: Section, rows: [DictationChoice], now: DictationNow, lang: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: Col.gap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(S(sec == .local ? "speech.compare.section.local" : "speech.compare.section.cloud"))
                        .font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(S(sec == .local ? "speech.compare.section.local.note" : "speech.compare.section.cloud.note"))
                        .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                headerCell(S("speech.compare.col.accuracy"), Col.accuracy)
                headerCell(S("speech.compare.col.delay"), Col.delay, help: S("speech.compare.col.delay.help"))
                if sec == .local {
                    headerCell(S("speech.compare.col.size"), Col.third)
                    headerCell(S("speech.compare.col.memory"), Col.fourth, help: S("speech.compare.col.memory.help"))
                } else {
                    headerCell(S("speech.compare.col.cost"), Col.third, help: S("speech.compare.col.cost.help"))
                    headerCell(S("speech.compare.col.leaves"), Col.fourth)
                }
                Color.clear.frame(width: Col.action, height: 1)
            }
            .padding(.bottom, 6)
            ForEach(Array(rows.enumerated()), id: \.element) { i, c in
                if i > 0 { Divider() }
                row(c, now: now, lang: lang)
            }
        }
    }

    func headerCell(_ t: String, _ width: CGFloat, help: String = "") -> some View {
        Text(t).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            .frame(width: width, alignment: .leading)
            .help(help)
    }

    /// A value: 12 pt, tabular digits, one line; "—" in secondary for none.
    func cell(_ t: String?, _ width: CGFloat, help: String = "", dim: Bool, quiet: Bool = false) -> some View {
        Text(t ?? "—").font(.system(size: SettingsMetrics.detailSize)).monospacedDigit()
            .foregroundStyle(dim || quiet || t == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
            .help(help)
    }

    // MARK: a row

    func row(_ c: DictationChoice, now: DictationNow, lang: String?) -> some View {
        let f = now.facts(c)
        let fit = now.fit(c)
        let runs = fit == .fits || fit == .needsKey
        let inUse = now.inUse == c
        let model = c.local ? d.asr?.models.first { $0.id == c.rawValue } : nil
        let help: String = {
            switch c {
            case .cloudPolish: return S("speech.compare.cloud_polish.help", ChoiceText.model(now.base.rawValue))
            case .cloudRecognizer: return S("speech.compare.cloud_asr.help")
            case .volcengine: return S("speech.compare.volcengine.help")
            default: return ""
            }
        }()
        let lit = hovered == c || focused == c
        let installed = model?.installed == true && c != .macOSSpeech
        return HStack(alignment: .center, spacing: Col.gap) {
            nameCell(c, now: now, fit: fit, runs: runs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(help)
            AccuracyMeter(halves: DictationChoices.halves(ChoiceText.error(f, lang)), dim: !runs)
                .frame(width: Col.accuracy, alignment: .leading)
            cell(ChoiceText.delay(f.delay), Col.delay, dim: !runs)
            if c.local {
                cell(ChoiceText.download(f, sizeMB: model?.sizeMB, installed: installed), Col.third, dim: !runs,
                     quiet: installed || c == .macOSSpeech)
                cell(f.memoryGB > 0 ? ChoiceText.memory(f.memoryGB) : nil, Col.fourth, dim: !runs)
            } else {
                cell(ChoiceText.hourly(f), Col.third, help: c == .cloudPolish ? ChoiceText.polishPerDictation : "", dim: !runs)
                cell(ChoiceText.leaves(f), Col.fourth, dim: !runs)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                action(c, now: now, fit: fit, inUse: inUse, shown: lit || now.recommended == c)
            }
            .frame(width: Col.action)
        }
        .padding(.vertical, 5)
        .frame(minHeight: Col.row)
        .background {
            // the pointer's row: a faint tint just past the text's edges (as Linear's and Raycast's lists)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovered == c ? 0.045 : 0))
                .padding(.horizontal, -8)
        }
        .contentShape(Rectangle())
        .onHover { h in
            if h { hovered = c } else if hovered == c { hovered = nil }
        }
        .accessibilityElement(children: .contain)
    }

    /// The name, then on its line what this Mac lacks for it (secondary) or the Recommended tag — under the name only
    /// when the two don't fit side by side.
    @ViewBuilder func nameCell(_ c: DictationChoice, now: DictationNow, fit: DictationChoices.Fit, runs: Bool) -> some View {
        let name = Text(ChoiceText.name(c, base: now.base)).font(.system(size: SettingsMetrics.titleSize))
            .foregroundStyle(runs ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        let why = ChoiceText.fit(fit)
        if let w = why {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) { name.lineLimit(1).fixedSize(); whyText(w).fixedSize() }
                VStack(alignment: .leading, spacing: 2) { name.lineLimit(2).fixedSize(horizontal: false, vertical: true); whyText(w) }
            }
        } else if now.recommended == c {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 6) { name.lineLimit(1).fixedSize(); ChoiceTag(S("speech.tag.recommended")).fixedSize() }
                VStack(alignment: .leading, spacing: 3) {
                    name.lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    ChoiceTag(S("speech.tag.recommended"))
                }
            }
        } else {
            name.lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    func whyText(_ w: String) -> some View {
        Text(w).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary).lineLimit(1)
    }

    /// The one thing at a row's end: In Use, or its action — shown at rest on the recommended row, on the others while
    /// the pointer or the keyboard is on them (still there for VoiceOver); a download keeps its bar and Stop.
    @ViewBuilder func action(_ c: DictationChoice, now: DictationNow, fit: DictationChoices.Fit, inUse: Bool, shown: Bool) -> some View {
        if inUse {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.brandInk)
                Text(S("speech.compare.in_use")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
            }
            .lineLimit(1).fixedSize()
            .accessibilityElement(children: .combine)
        } else if fit == .needsKey {
            reveal(S("speech.compare.add_key"), c, shown) { adding = Adding(choice: c) }
        } else if fit != .fits {
            EmptyView()
        } else if let id = DictationChoiceAction.downloading(c, now: now) {
            HStack(spacing: 6) {
                let p = dl.progress(id)
                ProgressView(value: min(p?.done ?? 0, p?.total ?? 1), total: max(p?.total ?? 1, 1)).controlSize(.small).frame(width: 60)
                Button { dl.stop(id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).help(S("speech.download.stop")).accessibilityLabel(S("speech.download.stop"))
            }
        } else if DictationChoiceAction.needsDownload(c, now: now) {
            reveal(S("speech.download.button"), c, shown) { DictationChoiceAction.use(c, now: now) }
        } else {
            reveal(S("speech.lib.use"), c, shown) { DictationChoiceAction.use(c, now: now) }
        }
    }

    func reveal(_ title: String, _ c: DictationChoice, _ shown: Bool, _ act: @escaping () -> Void) -> some View {
        Button(title, action: act)
            .buttonStyle(.bordered).lineLimit(1).fixedSize()
            .focused($focused, equals: c)
            .opacity(shown ? 1 : 0)
    }
}

/// "Recommended": neutral ink on the brand tint (system.md §2.1: text on tint stays ink), a caption's size.
struct ChoiceTag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(Color.brandTint))
    }
}

/// Accuracy as a five-segment meter in half steps (DictationChoices.halves): secondary ink on a faint track, a
/// measured level rather than a star rating.
struct AccuracyMeter: View {
    let halves: Int
    var dim = false
    static let segment = CGSize(width: 10, height: 5), spacing: CGFloat = 3

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(0..<5, id: \.self) { i in
                let part = CGFloat(min(max(halves - i * 2, 0), 2)) / 2
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color.primary.opacity(dim ? 0.28 : 0.6))
                        .mask(alignment: .leading) { Rectangle().frame(width: Self.segment.width * part) }
                }
                .frame(width: Self.segment.width, height: Self.segment.height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(S("speech.compare.col.accuracy"))
        .accessibilityValue(S("speech.compare.accuracy.value", ChoiceText.seconds(Double(halves) / 2)))
    }
}
