// The Dictation Lab's two columns (DictationLab.swift has the model): the cases, with a few commands in the page's
// header band beside the views (LabCommandBar: +, Read a Script, Run All Cases once there is a case, ⋯ for Import /
// Export / keeping audio), and the workbench — the record
// button first, what you meant, the optional text around the cursor (closed) and the scenario pills, every stage side
// by side with its milliseconds, the diff, Compare, the marks — over a pinned bar with Save, or the regression run's
// table. Colours are BrandColor tokens (light, dark, Increase Contrast; docs/design/system.md A.4), icons BlurtIcon /
// SF Symbols, words T("dictation.lab.*"). The one primary per view is the brand button (Save, in the pinned bar);
// while a take is processed the recorder card carries the AI-working hairline (`.aiWorking`); Compare and the
// regression run show a spinner. Nothing blooms or glows. The list's selection is the brand wash (ListWash / RowWash,
// as the history's); the workbench sits on one leading inset (LabGrid) and wraps (the pills) rather than running past
// a narrow detail column's edges.
import AppKit
import SwiftUI
import BlurtCore

private func labGlyph(_ i: BlurtIcon, _ size: CGFloat = 12) -> Image {
    Image(nsImage: i.isBrand ? i.image(size: size + 2) : i.symbolImage(pointSize: size)).renderingMode(.template)
}

private let cardFill = Color(nsColor: .textBackgroundColor).opacity(0.6)
private let chipFill = Color(nsColor: .quaternaryLabelColor).opacity(0.4)
private let okColor = Color.brandOk

private func pct(_ v: Double?) -> String {
    guard let v = v else { return "—" }
    return String(format: "%.1f%%", v * 100)
}

/// The scenario tags a case can carry (case.json "scenario"), with their choices.
enum LabScenario {
    static let keys: [(key: String, values: [String])] = [
        ("app", ["wechat", "chat", "code", "terminal", "browser", "notes", "mail", "docs", "other"]),
        ("languages", ["zh", "en", "mixed"]),
        ("noise", ["quiet", "some", "noisy"]),
        ("speed", ["slow", "normal", "fast"]),
    ]
}

// MARK: - the list column

/// The list column: a bar of commands over the cases (+ for a new take, Read a Script, Run All Cases once there is a
/// case, and ⋯ with Import Audio…, Export… and keeping the audio of the next dictations), then the cases alone — no
/// command dressed as a row. No cases: the shared empty state, without a button (the recorder on the right is the
/// action).
struct LabListView: View {
    @ObservedObject var lab: DictationLabModel

    private var selection: Binding<String?> {
        Binding(get: { lab.isNew || lab.pane == .regression ? nil : lab.draft.id },
                set: { v in
                    guard let v = v else { return }
                    // reading a script, the take just saved is the one showing: its new row appearing isn't a click
                    if v == lab.draft.id && lab.pane == .script { return }
                    lab.open(v)
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            // the commands sit in the page's header band (DictationPageHeader), beside the views
            if lab.cases.isEmpty {
                EmptyStateContent(title: T("dictation.lab.cases.empty.title"), message: T("dictation.lab.cases.empty.hint"))
            } else {
                List(selection: selection) {
                    ForEach(lab.cases) { c in
                        LabCaseRow(c: c).tag(c.id)
                            .listRowBackground(RowWash(on: selection.wrappedValue == c.id))
                            .contextMenu {
                                Button(T("dictation.lab.delete")) { lab.delete(c.id) }
                            }
                    }
                }
                .listStyle(.inset)
                .background(ListWash())
            }
            if lab.keepNext > 0 { keeping }
        }
        .frame(minWidth: 320, minHeight: 300)
        .onAppear { lab.reload() }
    }

    /// While the audio of the next dictations is kept: say so, with the way to stop (the setting itself is in ⋯).
    var keeping: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                labGlyph(.waveform, 11).foregroundStyle(.secondary)
                Text(T("dictation.lab.keep_next.on", lab.keepNext)).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Button(T("dictation.lab.keep_next.stop")) { lab.setKeepNext(0) }
                    .buttonStyle(.plain).foregroundStyle(Color.brandInk)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .help(T("dictation.lab.keep_next.tip"))
    }
}

/// The list column's commands as a compact bar (as Notes' and Mail's): icon buttons with a quiet hover, a word where
/// the icon alone wouldn't say it, the rarely used ones in ⋯.
struct LabCommandBar: View {
    @ObservedObject var lab: DictationLabModel

    /// In the page's header band, after History | Words | Lab: the words beside the icons where the column has room,
    /// the icons alone (their names on hover) where it hasn't.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            buttons(titled: true)
            buttons(titled: false)
        }
    }

    func buttons(titled: Bool) -> some View {
        HStack(spacing: 2) {
            LabBarButton(icon: .plus, help: T("dictation.lab.new_take.tip"), on: false) { lab.newTake() }
                .disabled(lab.phase != .idle)
                .accessibilityLabel(T("dictation.lab.new_take"))
            LabBarButton(icon: .document, title: titled ? T("dictation.lab.script") : nil, help: scriptHelp, on: lab.pane == .script) { lab.startScript() }
                .disabled(lab.phase != .idle)
                .accessibilityLabel(T("dictation.lab.script"))
            if !lab.cases.isEmpty {
                LabBarButton(icon: .restart, title: titled ? T("dictation.lab.run_all") : nil, help: runHelp, on: lab.pane == .regression) { lab.pane = .regression }
                    .accessibilityLabel(T("dictation.lab.run_all"))
            }
            more
        }
        .fixedSize()
    }

    private var scriptHelp: String {
        guard let p = lab.currentPack else { return T("dictation.lab.script.detail") }
        let pr = lab.progress
        return T("dictation.lab.script.detail") + " · \(p.name) · \(pr.done)/\(pr.total)"
    }

    private var runHelp: String {
        guard let o = lab.runResult?["overall"] as? [String: Any], let s = o["score"] as? Double else { return T("dictation.lab.run_all.detail") }
        return T("dictation.lab.run_all.detail") + " · " + T("dictation.lab.run_all.last", String(format: "%.1f", s))
    }

    /// Import, export and keeping the audio of the next dictations: rare, so one menu.
    var more: some View {
        Menu {
            Button(Look.menuCase(T("dictation.lab.import"))) { lab.importAudio() }.disabled(lab.phase != .idle)
            Button(Look.menuCase(T("dictation.lab.export"))) { lab.export() }.disabled(lab.cases.isEmpty)
            Divider()
            Picker(Look.menuCase(T("dictation.lab.keep_next")), selection: Binding(get: { lab.keepNext }, set: { lab.setKeepNext($0) })) {
                Text(T("dictation.lab.keep_next.off")).tag(0)
                ForEach(keepChoices, id: \.self) { n in
                    Text(LabCommandBar.presets.contains(n) ? T("dictation.lab.keep_next.n", n) : T("dictation.lab.keep_next.count", n)).tag(n)
                }
            }
        } label: {
            labGlyph(.more, 13)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 4)
        .help(T("dictation.lab.more"))
        .accessibilityLabel(T("dictation.lab.more"))
    }

    static let presets = [5, 10, 25, 50]
    /// the presets, and what is left of a count that is running down
    private var keepChoices: [Int] { Array(Set(LabCommandBar.presets + (lab.keepNext > 0 ? [lab.keepNext] : []))).sorted() }
}

/// A bar button: an icon (and a word); a rounded neutral wash on hover, and while its pane is showing.
private struct LabBarButton: View {
    let icon: BlurtIcon
    var title: String? = nil
    let help: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                labGlyph(icon, 12).frame(width: 14)
                if let t = title { Text(t).lineLimit(1).fixedSize() }
            }
            .font(.system(size: 12, weight: on ? .semibold : .regular))
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .padding(.horizontal, title == nil ? 5 : 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(on ? 0.09 : hover && enabled ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct LabCaseRow: View {
    let c: LabCase

    var body: some View {
        let wer = c.metrics?["wer"] as? Double
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                labGlyph(c.hasAudio ? .waveform : .document, 10).foregroundStyle(.secondary)
                Text("\(DictationHistoryModel.dayTitle(c.created)) \(DictationHistoryModel.time(c.created))")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                if let d = c.duration { Text(DictationHistoryModel.duration(d)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary) }
                Spacer(minLength: 6)
                if !c.errors.isEmpty {
                    Text(T("dictation.lab.errors.count", c.errors.count)).font(.system(size: 10.5)).foregroundStyle(Color.brandAttnInk)
                }
                if let w = wer {
                    Text(T("dictation.lab.metric.wer.short", pct(w))).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(w == 0 ? okColor : .secondary)
                }
            }
            Text((c.truth ?? c.finalText ?? T("dictation.lab.untitled")).trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 13)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - the detail column

struct LabDetailView: View {
    @ObservedObject var lab: DictationLabModel

    var body: some View {
        Group {
            if lab.pane == .regression { LabRegressionView(lab: lab) } else { LabWorkbench(lab: lab) }
        }
        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The workbench's grid: every block starts on one leading inset, the pinned bar too.
enum LabGrid {
    static let inset: CGFloat = 28
}

/// A titled block of the workbench: the heading in the label colour (weight, not grey, sets it apart from the
/// fields), an optional caption beside it.
private struct LabSection<Content: View>: View {
    let title: String
    var caption: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let c = caption {
                    Text(c).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if let t = trailing { t }
            }
            content
        }
    }
}

/// One scenario tag as a property pill: its name while it isn't set ("App ⌄"), "App: WeChat ⌄" once it is; a menu
/// of the choices with "Not set" first.
private struct LabScenarioPill: View {
    let key: String
    let values: [String]
    let value: String
    let set: (String) -> Void

    var body: some View {
        let name = T("dictation.lab.scenario.\(key)")
        let on = !value.isEmpty
        Menu {
            Picker(selection: Binding(get: { value }, set: set)) {
                Text(T("dictation.lab.scenario.none")).tag("")
                Divider()
                ForEach(values, id: \.self) { v in Text(T("dictation.lab.scenario.\(key).\(v)")).tag(v) }
            } label: { EmptyView() }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Text(on ? T("dictation.lab.scenario.pill", name, T("dictation.lab.scenario.\(key).\(value)")) : name)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .font(.system(size: 12))
        .padding(.leading, 10).padding(.trailing, 6).frame(height: 24)
        .background(Capsule().fill(on ? chipFill : Color.clear))
        .overlay(Capsule().strokeBorder(Color(nsColor: on ? .clear : .separatorColor), lineWidth: 1))
        .accessibilityLabel(name)
        .accessibilityValue(on ? T("dictation.lab.scenario.\(key).\(value)") : T("dictation.lab.scenario.none"))
    }
}

/// A block of text with a label and a caption (milliseconds, a note).
private struct StageCard: View {
    let label: String
    let text: String?
    var caption: String? = nil
    var empty: String = "—"
    var warn: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let c = caption {
                    // the time keeps its line: the label gives way
                    Text(c).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                }
            }
            if let t = text, !t.isEmpty {
                Text(t).font(.system(size: 13)).lineSpacing(2).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(empty).font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            if let w = warn {
                HStack(spacing: 4) { labGlyph(.undo, 10); Text(w) }.font(.system(size: 11)).foregroundStyle(Color.brandAttnInk)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

/// The output with what differs from the truth marked: changed / added words tinted, missing ones struck through.
struct LabDiffText: View {
    let ref: String
    let hyp: String
    var body: some View {
        Text(LabDiffText.attributed(ref, hyp)).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    static func attributed(_ ref: String, _ hyp: String) -> AttributedString {
        var out = AttributedString()
        for c in LabMetrics.diff(ref, hyp) {
            switch c.op {
            case .equal:
                out += AttributedString(c.hyp)
            case .insert, .replace:
                if c.op == .replace {
                    var d = AttributedString(c.ref)
                    d.strikethroughStyle = .single
                    d.foregroundColor = Color.brandErr
                    out += d
                }
                var a = AttributedString(c.hyp)
                a.backgroundColor = Color.brandAttn.opacity(0.28)      // a diff is not brand
                out += a
            case .delete:
                var d = AttributedString(c.ref)
                d.strikethroughStyle = .single
                d.foregroundColor = Color.brandErr
                out += d
            }
        }
        return out
    }
}

/// WER / CER / punctuation / terms, small and side by side.
private struct MetricBadges: View {
    let s: LabMetrics.Score
    var body: some View {
        HStack(spacing: 6) {
            badge(T("dictation.lab.metric.wer"), pct(s.wer), s.wer == 0)
            badge(T("dictation.lab.metric.cer"), pct(s.cer), s.cer == 0)
            badge(T("dictation.lab.metric.punct"), pct(s.punct), s.punct == 0)
            if let t = s.terms { badge(T("dictation.lab.metric.terms"), "\(t.hit)/\(t.expected)", t.hit == t.expected) }
        }
    }
    func badge(_ k: String, _ v: String, _ good: Bool) -> some View {
        HStack(spacing: 4) {
            Text(k).foregroundStyle(.secondary)
            Text(v).fontWeight(.semibold).monospacedDigit().foregroundStyle(good ? okColor : .primary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(chipFill))
    }
}

private struct Chip: View {
    let text: String
    var on = false
    var action: (() -> Void)? = nil
    var body: some View {
        let label = HStack(spacing: 3) {
            if on { labGlyph(.check, 9) }
            Text(text)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(on ? Color.brandTint : chipFill))
        .overlay(Capsule().strokeBorder(on ? Color.brandInk : .clear, lineWidth: 0.8))
        if let a = action { Button(action: a) { label }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []) } else { label }
    }
}

struct LabWorkbench: View {
    @ObservedObject var lab: DictationLabModel
    /// "Text around the cursor" is optional: closed until the user opens it (or the case has some)
    @State private var showContext = false

    private func text(_ get: @escaping (LabCase) -> String?, _ set: @escaping (inout LabCase, String?) -> Void) -> Binding<String> {
        Binding(get: { get(lab.draft) ?? "" }, set: { v in lab.edit { set(&$0, v) } })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if lab.pane == .script { LabScriptCard(lab: lab).id("top") } else { title.id("top") }
                        recorder.aiWorking(lab.phase == .processing, cornerRadius: 12)
                        if lab.pane != .script {
                            LabSection(title: T("dictation.lab.reference")) {
                                TextField(T("dictation.lab.reference.placeholder"), text: text({ $0.reference }, { $0.reference = $1 }), axis: .vertical)
                                    .textFieldStyle(.roundedBorder).lineLimit(3...8)
                            }
                            cursor
                            scenario
                        }
                        if let take = lab.draft.take { stages(take).id("stages") }
                        if lab.draft.take != nil || (lab.draft.truth != nil && lab.pane != .script) { markup.id("markup") }
                        if !lab.learned.isEmpty { learned }
                        if !lab.isNew && lab.draft.hasAudio { compare.id("compare") }
                    }
                    .padding(.horizontal, LabGrid.inset).padding(.top, 8).padding(.bottom, 28)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: lab.scrollTarget) { t in
                    guard let t = t else { return }
                    withAnimation { proxy.scrollTo(t, anchor: .top) }
                    DispatchQueue.main.async { lab.scrollTarget = nil }
                }
            }
            Divider()
            saveBar
        }
        .onAppear { if !lab.before.isEmpty || !lab.after.isEmpty { showContext = true } }
        .onChange(of: lab.draft.id) { _ in if !lab.before.isEmpty || !lab.after.isEmpty { showContext = true } }
    }

    /// The take's (or the case's) name, the one promise of the page, and Move to Trash for a saved case.
    var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(lab.isNew ? T("dictation.lab.new_take") : T("dictation.lab.case", "\(DictationHistoryModel.dayTitle(lab.draft.created)) \(DictationHistoryModel.time(lab.draft.created))"))
                    .font(.system(size: 17, weight: .semibold))
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "lock").font(.system(size: 10))
                    Text(T("dictation.lab.privacy.short")).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if !lab.isNew {
                Button(role: .destructive) { lab.delete(lab.draft.id) } label: {
                    HStack(spacing: 4) { labGlyph(.trash, 11); Text(T("dictation.lab.delete")) }
                }
                .help(T("dictation.lab.delete.tip"))
            }
        }
    }

    // MARK: record

    /// The record button (the page's loudest thing), what it is doing, and the microphone (Sound → Input's popup,
    /// borderless, the device's whole name). Importing a file is in the list's ⋯.
    var recorder: some View {
        HStack(alignment: .center, spacing: 16) {
            Button { lab.toggleRecord() } label: {
                ZStack {
                    Circle().fill(lab.phase == .recording ? Color.brandRec : Color.brandInk)
                    if lab.phase == .processing || lab.phase == .starting {
                        ProgressView().controlSize(.small).tint(lab.phase == .recording ? .white : Color(nsColor: BrandColor.onInk))
                    } else {
                        labGlyph(lab.phase == .recording ? .stopFill : .mic, 20)
                            .foregroundStyle(lab.phase == .recording ? .white : Color(nsColor: BrandColor.onInk))
                    }
                }
                .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
            .disabled(lab.phase == .processing)
            .accessibilityLabel(lab.phase == .recording ? T("dictation.lab.stop") : T("dictation.lab.record"))
            VStack(alignment: .leading, spacing: 3) {
                Text(status).font(.system(size: 13, weight: .semibold))
                if lab.phase == .recording {
                    HStack(spacing: 8) {
                        LabLevelBars(levels: lab.levels).frame(width: 160, height: 15)
                        Text(String(format: "%d:%02d", Int(lab.elapsed) / 60, Int(lab.elapsed) % 60)).monospacedDigit()
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                } else {
                    Text(T("dictation.lab.record.hint", Dictation.keyShort)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                if let e = lab.error { Text(e).font(.system(size: 11.5)).foregroundStyle(Color.brandErr).fixedSize(horizontal: false, vertical: true) }
                micMenu.padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    var micMenu: some View {
        Menu {
            Picker(selection: Binding(get: { lab.mic }, set: { lab.setMic($0) })) {
                Text(Look.menuCase(T("dictation.lab.mic.default"))).tag("")
                if !lab.mics.isEmpty { Divider() }
                ForEach(lab.mics, id: \.self) { Text($0).tag($0) }
            } label: { EmptyView() }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Text(lab.mic.isEmpty ? Look.menuCase(T("dictation.lab.mic.default")) : lab.mic)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .font(.system(size: 11.5))
        .padding(.leading, -3)      // the borderless button's own inset: its text on the status's edge
        .disabled(lab.phase != .idle)
        .help(T("dictation.lab.mic.tip"))
        .accessibilityLabel(T("dictation.lab.mic.tip"))
    }

    var status: String {
        switch lab.phase {
        case .idle: return lab.draft.take == nil ? T("dictation.lab.status.ready") : T("dictation.lab.status.done")
        case .starting: return T("dictation.lab.status.starting")
        case .recording: return T("dictation.lab.status.recording")
        case .processing: return T("dictation.lab.status.processing")
        }
    }

    // MARK: the optional fields

    /// Text around the cursor: a disclosure row (its state in a word when closed), then what it does, the two
    /// texts stacked at full width, and whether the case keeps them.
    var cursor: some View {
        let filled = !lab.before.isEmpty || !lab.after.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            Button { showContext.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showContext ? 90 : 0)).frame(width: 10)
                    Text(T("dictation.lab.cursor")).font(.system(size: 13, weight: .semibold))
                    Text(filled ? (lab.includeContext ? T("dictation.lab.cursor.filled_kept") : T("dictation.lab.cursor.filled"))
                         : T("dictation.lab.optional"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(showContext ? .isSelected : [])
            .accessibilityHint(T("dictation.lab.cursor.tip"))
            if showContext {
                VStack(alignment: .leading, spacing: 8) {
                    Text(T("dictation.lab.cursor.tip")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(T("dictation.lab.cursor.before"), text: $lab.before, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    TextField(T("dictation.lab.cursor.after"), text: $lab.after, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    HStack {
                        Text(T("dictation.lab.cursor.include")).font(.system(size: 12))
                        Spacer()
                        Toggle(T("dictation.lab.cursor.include"), isOn: $lab.includeContext).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    /// The scenario tags: one row of property pills (Linear's), each its name until set, then "Name: value".
    var scenario: some View {
        LabSection(title: T("dictation.lab.scenario"), caption: T("dictation.lab.scenario.tip")) {
            LabFlowLayout(spacing: 6) {        // wraps in a narrow detail column instead of running past its edges
                ForEach(LabScenario.keys, id: \.key) { k in
                    LabScenarioPill(key: k.key, values: k.values, value: lab.draft.scenario[k.key] ?? "") { v in
                        lab.edit { var s = $0.scenario; s[k.key] = v; $0.scenario = s }
                    }
                }
            }
        }
    }

    // MARK: the stages

    func ms(_ t: [String: Any], _ k: String) -> Int? { t[k] as? Int }

    /// The speech model's language call for the take: the language and how far it was from the English line — a close
    /// call is flagged (v0.9: a sentence 0.0006 over the line was typed as an English translation, and scored perfect).
    @ViewBuilder func tagLine(_ outputs: [String: Any]) -> some View {
        if let t = DictationLanguageTag.closest(outputs["tags"] as? [[String: Any]] ?? []), let m = t.margin {
            let margin = String(format: "%+.2f", m)
            Text(t.fragile ? T("dictation.lab.tag.fragile", margin)
                 : T("dictation.lab.tag", Loc.locale.localizedString(forLanguageCode: outputs["language"] as? String ?? "") ?? (t.tag ?? "—"), margin))
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(t.fragile ? Color.brandAttnInk : .secondary)
        }
    }

    @ViewBuilder func stages(_ take: [String: Any]) -> some View {
        let t = take["timings"] as? [String: Any] ?? [:]
        let polished = take["polished"] as? String
        let fellBack = take["fell_back"] as? Bool ?? false
        let pieces = take["segments"] as? [[String: Any]] ?? []
        LabSection(title: T("dictation.lab.stages")) {
            HStack(alignment: .top, spacing: 10) {
                StageCard(label: T("dictation.lab.stage.raw"), text: take["raw"] as? String,
                          caption: T("dictation.lab.ms", ms(t, "asr_ms_all") ?? ms(t, "asr_ms") ?? 0))
                StageCard(label: T("dictation.lab.stage.polished"), text: polished,
                          caption: T("dictation.lab.ms", ms(t, "polish_ms_all") ?? ms(t, "polish_ms") ?? 0),
                          empty: T("dictation.lab.stage.polish_off"),
                          warn: fellBack ? T("dictation.lab.fell_back", DictationHistoryModel.reasonText(take["reason"] as? String)) : nil)
                StageCard(label: T("dictation.lab.stage.final"), text: take["fitted"] as? String ?? take["text"] as? String,
                          caption: T("dictation.lab.ms.total", ms(t, "total_ms") ?? 0))
            }
            .fixedSize(horizontal: false, vertical: true)
            tagLine(take)
            if pieces.count > 0 { piecesTable(pieces) }
            details(take, t)
        }
    }

    func piecesTable(_ pieces: [[String: Any]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { i, p in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(span(p)).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p["asr_text"] as? String ?? "").font(.system(size: 12)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let out = p["text"] as? String, !out.isEmpty, out != p["raw"] as? String {
                            Text(T("dictation.lab.piece.committed", out)).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(T("dictation.lab.piece.ms", p["asr_ms"] as? Int ?? 0, p["polish_ms"] as? Int ?? 0))
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                if i < pieces.count - 1 { Divider() }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    func span(_ p: [String: Any]) -> String {
        if p["whole"] as? Bool == true { return T("dictation.lab.piece.whole") }
        let a = p["start"] as? Double ?? 0, b = p["end"] as? Double ?? 0
        var s = String(format: "%.1f–%.1f s", a, b)
        if let g = p["pause_after"] as? Double { s += String(format: " · %.1f", g) }
        return s
    }

    func details(_ take: [String: Any], _ t: [String: Any]) -> some View {
        let terms = take["terms_applied"] as? [String] ?? []
        let repaired = take["repaired"] as? [String] ?? []
        let fit = take["fit"] as? [String] ?? []
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 7) {
            GridRow {
                label(T("dictation.lab.detail.terms"))
                Text(terms.isEmpty ? T("dictation.lab.none") : terms.joined(separator: T("main.dictation.correct.sep")))
                    .foregroundStyle(terms.isEmpty ? .secondary : .primary)
            }
            GridRow {
                label(T("dictation.lab.detail.guard"))
                Text(take["fell_back"] as? Bool == true ? T("dictation.lab.fell_back", DictationHistoryModel.reasonText(take["reason"] as? String))
                     : take["polished"] is String ? T("dictation.lab.guard.passed") : T("dictation.lab.stage.polish_off"))
            }
            if !repaired.isEmpty {
                GridRow { label(T("dictation.lab.detail.repaired")); Text(repaired.joined(separator: T("main.dictation.correct.sep"))) }
            }
            GridRow {
                label(T("dictation.lab.detail.fit"))
                Text(fit.isEmpty ? T("dictation.lab.fit.none") : fit.map { T("dictation.lab.fit.\($0)") }.joined(separator: " · "))
            }
            GridRow {
                label(T("dictation.lab.detail.models"))
                Text([take["asr_model"] as? String, take["polish_model"] as? String].compactMap { $0 }.joined(separator: " · "))
                    .textSelection(.enabled)
            }
            GridRow {
                label(T("dictation.lab.detail.timings"))
                Text(T("dictation.lab.timings", ms(t, "asr_ms") ?? 0, ms(t, "polish_ms") ?? 0, ms(t, "load_ms") ?? 0, ms(t, "total_ms") ?? 0,
                       ms(t, "segments") ?? 1))
                    .monospacedDigit()
            }
        }
        .font(.system(size: 12))
    }

    /// the labels in one fixed, leading column (as the history's Details), the same in both languages
    func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).lineLimit(1).gridColumnAlignment(.leading).frame(width: 112, alignment: .leading)
    }

    // MARK: mark up

    var markup: some View {
        LabSection(title: T("dictation.lab.markup")) {
            if let truth = lab.truth, let out = lab.finalText {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(T("dictation.lab.against", lab.draft.corrected != nil ? T("dictation.lab.corrected.short") : T("dictation.lab.reference.short")))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        if let s = lab.score { MetricBadges(s: s) }
                    }
                    LabDiffText(ref: truth, hyp: out)
                    if let m = lab.score?.terms?.missed, !m.isEmpty {
                        Text(T("dictation.lab.terms.missed", m.joined(separator: ", "))).font(.system(size: 11.5)).foregroundStyle(Color.brandAttnInk)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 9).fill(cardFill))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(T("dictation.lab.corrected")).font(.system(size: 11.5, weight: .medium))
                Spacer()
                if let out = lab.finalText {
                    Button(T("dictation.lab.corrected.from_output")) { lab.edit { $0.corrected = out } }
                        .controlSize(.small).buttonStyle(.link).foregroundStyle(Color.brandInk)
                }
            }
            TextField(T("dictation.lab.corrected.placeholder"), text: text({ $0.corrected }, { $0.corrected = $1 }), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...6)
            Text(T("dictation.lab.errors")).font(.system(size: 11.5, weight: .medium)).padding(.top, 4)
            FlowRow(items: LabCase.errorTags.map { tag in
                Chip(text: T("dictation.lab.error_tag.\(tag)"), on: lab.draft.errors.contains(tag)) {
                    lab.edit { c in
                        var e = c.errors
                        if let i = e.firstIndex(of: tag) { e.remove(at: i) } else { e.append(tag) }
                        c.errors = e
                    }
                }
            })
            TextField(T("dictation.lab.note.placeholder"), text: Binding(get: { lab.draft.note }, set: { v in lab.edit { $0.note = v } }), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4)
            HStack(spacing: 14) {
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { n in
                        Button { lab.edit { $0.stars = $0.stars == n ? nil : n } } label: {
                            Image(systemName: (lab.draft.stars ?? 0) >= n ? "star.fill" : "star")
                                .foregroundStyle((lab.draft.stars ?? 0) >= n ? Color.brandAttn : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(T("dictation.lab.stars", n))
                    }
                }
                Picker("", selection: Binding(get: { lab.draft.good.map { $0 ? 1 : 0 } ?? -1 },
                                              set: { v in lab.edit { $0.good = v < 0 ? nil : v == 1 } })) {
                    Text(T("dictation.lab.rating.none")).tag(-1)
                    Text(T("dictation.lab.rating.good")).tag(1)
                    Text(T("dictation.lab.rating.bad")).tag(0)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(.top, 2)
        }
    }

    var learned: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            labGlyph(.spark, 11).foregroundStyle(okColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(T("dictation.lab.learned")).font(.system(size: 12, weight: .medium))
                Text(lab.learned.map(\.summary).joined(separator: "; ")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(T("dictation.lab.learn.undo")) { lab.undoLearned() }.controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(okColor.opacity(0.10)))
    }

    // MARK: compare

    var compare: some View {
        LabSection(title: T("dictation.lab.compare"), trailing: AnyView(
            HStack(spacing: 6) {
                if lab.rerunning { BrandSpinnerView() }
                Button(T("dictation.lab.compare.run")) { lab.rerun() }.disabled(lab.rerunning || lab.chosen.isEmpty || lab.dirty)
                    .help(lab.dirty ? T("dictation.lab.compare.save_first") : T("dictation.lab.compare.tip"))
            }.controlSize(.small))) {
            FlowRow(items: lab.options.map { o in
                Chip(text: o.label, on: lab.chosen.contains(o.spec)) {
                    if lab.chosen.contains(o.spec) { lab.chosen.remove(o.spec) } else { lab.chosen.insert(o.spec) }
                }
            })
            if !lab.reruns.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lab.reruns.enumerated()), id: \.element.id) { i, r in
                        rerunRow(r)
                        if i < lab.reruns.count - 1 { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 9).fill(cardFill))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
        }
    }

    func rerunRow(_ r: DictationLabModel.Rerun) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(r.label).font(.system(size: 11.5, weight: .medium)).frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if let e = r.error {
                    Text(e).font(.system(size: 11.5)).foregroundStyle(Color.brandErr)
                } else if let t = lab.truth {
                    LabDiffText(ref: t, hyp: r.text)
                } else {
                    Text(r.text).font(.system(size: 13)).textSelection(.enabled)
                }
                if r.outputs["fell_back"] as? Bool == true {
                    Text(T("dictation.lab.fell_back", DictationHistoryModel.reasonText(r.outputs["reason"] as? String)))
                        .font(.system(size: 11)).foregroundStyle(Color.brandAttnInk)
                }
                tagLine(r.outputs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                if let s = lab.score(of: r.text) {
                    Text(T("dictation.lab.metric.wer.short", pct(s.wer))).font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(s.wer == 0 ? okColor : .primary)
                    if let t = s.terms { Text(T("dictation.lab.metric.terms.short", t.hit, t.expected)).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                }
                Text(T("dictation.lab.ms", r.ms)).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
    }

    // MARK: save

    /// Pinned under the workbench, so the commit never scrolls away: what just happened on the left; Discard and the
    /// one primary on the right, with why it is off while there is nothing to save yet.
    var saveBar: some View {
        HStack(spacing: 10) {
            if let n = lab.notice {
                HStack(spacing: 4) { labGlyph(.check, 11).foregroundStyle(okColor); Text(n).lineLimit(1).truncationMode(.tail) }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if lab.isNew && lab.pane != .script && lab.draft.take == nil && lab.draft.truth == nil {
                Text(T("dictation.lab.save.needs_take")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            if lab.isNew && lab.draft.take != nil {
                Button(T("dictation.lab.discard")) { lab.newTake() }.disabled(lab.phase != .idle)
            }
            // the workbench's primary, except while reading a script: there "Next" is
            Button(lab.isNew ? T("dictation.lab.save") : T("dictation.lab.save_changes")) { lab.save() }
                .keyboardShortcut("s", modifiers: .command)
                .primaryButton(lab.pane != .script)
                .disabled(!lab.canSave)
                .help(T("dictation.lab.save.tip"))
        }
        .controlSize(.regular)
        .padding(.horizontal, LabGrid.inset).padding(.vertical, 12)
    }
}

/// The level of the last ~9 s, as thin bars.
private struct LabLevelBars: View {
    let levels: [Float]
    var body: some View {
        GeometryReader { g in
            let n = max(1, Int(g.size.width / 3))
            let xs = Array(levels.suffix(n))
            HStack(alignment: .center, spacing: 1) {
                ForEach(Array(xs.enumerated()), id: \.offset) { _, l in
                    Capsule().fill(Color.brandInk.opacity(0.8)).frame(width: 2, height: max(2, CGFloat(l) * g.size.height))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// Views that wrap onto more lines (chips).
private struct FlowRow<V: View>: View {
    let items: [V]
    var body: some View {
        LabFlowLayout(spacing: 5) { ForEach(Array(items.enumerated()), id: \.offset) { _, v in v } }
    }
}

private struct LabFlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 500
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0, x + z.width > w { x = 0; y += line + spacing; line = 0 }
            x += z.width + spacing; line = max(line, z.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(w, widest), height: y + line)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, line: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > b.minX, x + z.width > b.maxX { x = b.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z))
            x += z.width + spacing; line = max(line, z.height)
        }
    }
}

// MARK: - reading a script

/// The prompt to read aloud, where the user is in the pack, the takes so far, and the way on.
struct LabScriptCard: View {
    @ObservedObject var lab: DictationLabModel

    var body: some View {
        let pr = lab.progress
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker(T("dictation.lab.script.pack"), selection: Binding(get: { lab.currentPack?.id ?? "" }, set: { v in
                    lab.packID = v
                    lab.newTake(script: true)
                })) {
                    ForEach(lab.packs) { p in Text(p.name).tag(p.id) }
                }
                .frame(maxWidth: 320)
                .disabled(lab.phase != .idle)
                Spacer()
                Menu {
                    Button(T("dictation.lab.script.generate")) { lab.generateMore() }.disabled(lab.generating)
                    Button(T("dictation.lab.script.import")) { lab.importPack() }
                } label: { labGlyph(.more, 12) }
                .menuStyle(.borderlessButton).fixedSize()
                .help(T("dictation.lab.script.more"))
                if lab.generating { BrandSpinnerView() }
            }
            HStack(spacing: 8) {
                ProgressView(value: Double(pr.done), total: Double(max(1, pr.total))).frame(maxWidth: 240)
                Text(T("dictation.lab.script.progress", pr.done, pr.total)).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Text(T("dictation.lab.script.position", lab.promptIndex + 1, pr.total)).font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let q = lab.currentPrompt {
                VStack(alignment: .leading, spacing: 10) {
                    Text(T("dictation.lab.script.read")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(q.read).font(.system(size: 20, weight: .regular)).lineSpacing(5).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    if q.expected != q.read {
                        Text(T("dictation.lab.script.expected", q.expected)).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    FlowRow(items: q.tagList.map { Chip(text: T("dictation.lab.tag.\($0)")) })
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(cardFill))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                takes(q)
                HStack(spacing: 8) {
                    Button { lab.go(prompt: -1) } label: { HStack(spacing: 4) { labGlyph(.chevronLeft, 10); Text(T("dictation.lab.script.prev")) } }
                        .disabled(lab.promptIndex == 0 || lab.phase != .idle)
                    Spacer()
                    if lab.draft.take != nil {
                        Button(T("dictation.lab.script.retry")) { lab.record(file: nil, via: "retry") }.disabled(lab.phase != .idle)
                    }
                    Button { lab.nextUnread() } label: { HStack(spacing: 4) { Text(T("dictation.lab.script.next")); labGlyph(.chevronRight, 10) } }
                        .buttonStyle(.brand)
                        .disabled(lab.phase != .idle || lab.promptIndex >= pr.total - 1)
                }
            } else {
                Text(T("dictation.lab.script.none")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder func takes(_ q: DictationLabModel.Prompt) -> some View {
        let ts = lab.takes(q)
        if !ts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(T("dictation.lab.script.takes", ts.count)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(ts) { c in
                    HStack(spacing: 8) {
                        Button { lab.open(c.id, keepPane: true) } label: {
                            HStack(spacing: 6) {
                                if c.id == lab.draft.id { labGlyph(.check, 10).foregroundStyle(Color.brandInk) }
                                Text(DictationHistoryModel.time(c.created)).monospacedDigit()
                                Text(T("dictation.lab.metric.wer.short", pct(c.metrics?["wer"] as? Double))).monospacedDigit()
                                    .foregroundStyle((c.metrics?["wer"] as? Double) == 0 ? okColor : .secondary)
                                Text(c.finalText ?? "").lineLimit(1).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if ts.count > 1 {
                            Button(T("dictation.lab.script.keep_only")) { lab.keepOnly(c.id) }.buttonStyle(.link).foregroundStyle(Color.brandInk).controlSize(.small)
                        }
                    }
                    .font(.system(size: 11.5))
                }
            }
        }
    }
}

// MARK: - the regression run

struct LabRegressionView: View {
    @ObservedObject var lab: DictationLabModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(T("dictation.lab.run_all")).font(.system(size: 17, weight: .semibold))
                    Text(T("dictation.lab.run_all.explain")).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Picker(T("dictation.lab.run_all.config"), selection: $lab.runSpec) {
                        ForEach(lab.options) { o in Text(o.label).tag(o.spec) }
                        if lab.options.isEmpty { Text(T("dictation.lab.compare.current")).tag("current") }
                    }
                    .frame(maxWidth: 360)
                    Button(T("dictation.lab.run_all.run")) { lab.runAll() }
                        .buttonStyle(.brand).disabled(lab.running || lab.cases.allSatisfy { !$0.hasAudio })
                    if lab.running {
                        BrandSpinnerView()
                        Text(T("dictation.lab.run_all.running")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if let r = lab.runResult { result(r) }
                if let e = lab.error { Text(e).font(.system(size: 12)).foregroundStyle(Color.brandErr) }
                Text(T("dictation.lab.run_all.cli")).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("uv run skills/blurt/scripts/dictation_lab.py run --json").font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder func result(_ r: [String: Any]) -> some View {
        let o = r["overall"] as? [String: Any] ?? [:]
        let rows = r["rows"] as? [[String: Any]] ?? []
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                // the score: large, neutral (a number is not brand; better / worse below carry the colour)
                Text((o["score"] as? Double).map { String(format: "%.1f", $0) } ?? "—").font(.system(size: 30, weight: .semibold)).monospacedDigit()
                Text(T("dictation.lab.run_all.score")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text(T("dictation.lab.metric.wer")).foregroundStyle(.secondary); Text(pct(o["wer"] as? Double)).monospacedDigit()
                    Text(T("dictation.lab.metric.cer")).foregroundStyle(.secondary); Text(pct(o["cer"] as? Double)).monospacedDigit()
                    Text(T("dictation.lab.metric.terms")).foregroundStyle(.secondary); Text(pct(o["term_accuracy"] as? Double)).monospacedDigit()
                }
                GridRow {
                    Text(T("dictation.lab.change.better")).foregroundStyle(okColor); Text("\(o["better"] as? Int ?? 0)").monospacedDigit()
                    Text(T("dictation.lab.change.worse")).foregroundStyle(Color.brandErr); Text("\(o["worse"] as? Int ?? 0)").monospacedDigit()
                    Text(T("dictation.lab.change.same")).foregroundStyle(.secondary); Text("\(o["same"] as? Int ?? 0)").monospacedDigit()
                }
            }
            .font(.system(size: 12))
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(T("dictation.lab.run_all.case")).frame(maxWidth: .infinity, alignment: .leading)
                Text(T("dictation.lab.run_all.before")).frame(width: 70, alignment: .trailing)
                Text(T("dictation.lab.run_all.after")).frame(width: 70, alignment: .trailing)
                Text(T("dictation.lab.metric.terms")).frame(width: 50, alignment: .trailing)
                Text(T("dictation.lab.run_all.change")).frame(width: 80, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                rowView(row)
                if i < rows.count - 1 { Divider() }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        let tags = (r["by_tag"] as? [String: [String: Any]] ?? [:]).filter { !$0.key.hasPrefix("pack:") }.sorted { $0.key < $1.key }
        if !tags.isEmpty {
            Text(T("dictation.lab.run_all.by_tag")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            LabFlowLayout(spacing: 6) {
                ForEach(tags, id: \.key) { k, v in
                    HStack(spacing: 4) {
                        Text(LabRegressionView.tagName(k)).foregroundStyle(.secondary)
                        Text(pct(v["wer"] as? Double)).fontWeight(.semibold).monospacedDigit()
                        Text("·\(v["cases"] as? Int ?? 0)").foregroundStyle(.tertiary).monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill((v["worse"] as? Int ?? 0) > 0 ? Color.brandErr.opacity(0.15) : chipFill))
                }
            }
        }
    }

    /// "length:short" → its name in the script tags' words; other tags as they are.
    static func tagName(_ k: String) -> String {
        let dotted = k.replacingOccurrences(of: ":", with: ".")
        let key = dotted.hasPrefix("scenario.") ? "dictation.lab." + dotted
            : "dictation.lab.tag." + dotted.replacingOccurrences(of: "feature.", with: "features.")
        let t = T(key)
        return t == key ? k : t
    }

    func rowView(_ row: [String: Any]) -> some View {
        let b = row["before"] as? [String: Any], a = row["after"] as? [String: Any]
        let change = row["change"] as? String ?? "n/a"
        let terms = a?["terms"] as? [String: Any]
        return Button { if let id = row["id"] as? String { lab.open(id) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row["truth"] as? String ?? row["id"] as? String ?? "").font(.system(size: 12)).lineLimit(1)
                    if let t = row["text"] as? String, let truth = row["truth"] as? String {
                        LabDiffText(ref: truth, hyp: t).lineLimit(2)
                    } else if let e = row["error"] as? String {
                        Text(e).font(.system(size: 11)).foregroundStyle(Color.brandErr)
                    }
                    if row["fragile_tag"] as? Bool == true, let m = row["tag_margin"] as? Double {
                        Text(T("dictation.lab.tag.fragile", String(format: "%+.2f", m)))
                            .font(.system(size: 11)).foregroundStyle(Color.brandAttnInk)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(pct(b?["wer"] as? Double)).frame(width: 70, alignment: .trailing).foregroundStyle(.secondary)
                Text(pct(a?["wer"] as? Double)).frame(width: 70, alignment: .trailing)
                Text(terms.map { "\($0["hit"] as? Int ?? 0)/\($0["expected"] as? Int ?? 0)" } ?? "—").frame(width: 50, alignment: .trailing)
                Text(T("dictation.lab.change.\(change == "n/a" ? "na" : change)"))
                    .foregroundStyle(change == "better" ? okColor : change == "worse" || change == "error" ? Color.brandErr : .secondary)
                    .fontWeight(change == "better" || change == "worse" ? .semibold : .regular)
                    .frame(width: 80, alignment: .trailing)
            }
            .font(.system(size: 11.5)).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
