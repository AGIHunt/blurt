// Send Feedback (docs/design/feedback.md): the Dictation page's History → "Send Feedback…" opens this sheet. The user
// checks the dictations to send (the rows selected in the list come checked; Select All), says whether the text around
// the cursor goes with them, and sends: feedback.py bundles each one's history line, its recording, the device and the
// models into one zip (≤ 100 MB) and uploads it. No rating, no form — the developers replay the takes themselves.
// Nothing leaves the Mac before Send; the sheet says what goes, where, who can read it and when it is deleted.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class DictationFeedbackModel: ObservableObject {
    enum Phase: Equatable { case picking, sending, sent(String), failed(String) }

    static let limit: Int64 = 100_000_000

    let entries: [DictationEntry]
    @Published var checked: Set<String>
    @Published var includeContext = true
    @Published var phase: Phase = .picking
    /// the bytes each dictation adds: its recording, else a few KB of text
    private var sizes: [String: Int64] = [:]

    init(entries: [DictationEntry], selected: Set<String>) {
        self.entries = entries
        let pre = selected.intersection(entries.map(\.id))
        checked = pre.isEmpty ? Set(entries.prefix(1).map(\.id)) : pre
        for e in entries { sizes[e.id] = DictationFeedbackModel.size(of: e) }
    }

    static func size(of e: DictationEntry) -> Int64 {
        let text: Int64 = 4_000
        guard let a = e.audio else { return text }
        let u = DictationHistory.shared.resolve(a)
        let n = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0
        return text + n
    }

    func hasAudio(_ e: DictationEntry) -> Bool { (sizes[e.id] ?? 0) > 4_000 }

    var total: Int64 { checked.reduce(0) { $0 + (sizes[$1] ?? 0) } }
    var tooLarge: Bool { total > DictationFeedbackModel.limit }
    var allChecked: Bool { !entries.isEmpty && checked.count == entries.count }

    func toggle(_ id: String) { if checked.contains(id) { checked.remove(id) } else { checked.insert(id) } }
    func toggleAll() { checked = allChecked ? [] : Set(entries.map(\.id)) }

    func send() {
        guard !checked.isEmpty, !tooLarge, phase != .sending else { return }
        phase = .sending
        // oldest first, as they were said
        let ids = entries.filter { checked.contains($0.id) }.reversed().map(\.id)
        let info = Bundle.main.infoDictionary
        var args = ["send", "--ids", ids.joined(separator: ","),
                    "--app-version", info?["CFBundleShortVersionString"] as? String ?? "unknown",
                    "--app-build", info?["CFBundleVersion"] as? String ?? "unknown"]
        if !includeContext { args.append("--no-context") }
        emit(["event": "dictation_feedback", "action": "send", "takes": ids.count, "bytes": total, "context": includeContext])
        Scripts.call("feedback.py", args, timeout: 600) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let o):
                let id = o["id"] as? String ?? ""
                self.phase = .sent(id)
                emit(["event": "dictation_feedback", "action": "sent", "id": id])
            case .failure(let f):
                self.phase = .failed(DictationFeedbackModel.sentence(f.code))
                emit(["event": "dictation_feedback", "action": "failed", "code": f.code])
            }
        }
    }

    static func sentence(_ code: String) -> String {
        switch code {
        case "network": return T("dictation.feedback.error.network")
        case "rate_limited": return T("dictation.feedback.error.rate")
        case "full": return T("dictation.feedback.error.full")
        case "too_large": return T("dictation.feedback.too_large")
        default: return T("dictation.feedback.error.other")
        }
    }

    static func megabytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(n, 1_000), countStyle: .file)
    }
}

struct DictationFeedbackSheet: View {
    @StateObject var f: DictationFeedbackModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(T("dictation.feedback.title")).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            switch f.phase {
            case .sent(let id): sent(id)
            default: picking
            }
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: picking

    var picking: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(T("dictation.feedback.note"))
                .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            listHeader.padding(.top, 14)
            list
            // the rows' own box, one size of checkbox in the sheet
            Button { f.includeContext.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    DictationFeedbackSheet.box(f.includeContext ? .on : .off)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("dictation.feedback.context"))
                        Text(T("dictation.feedback.context.detail")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(f.includeContext ? .isSelected : [])
            .padding(.horizontal, 10)
            .padding(.top, 12)
            what.padding(.top, 12)
            footer.padding(.top, 16)
        }
        .disabled(f.phase == .sending)
    }

    var listHeader: some View {
        HStack(spacing: 8) {
            // the rows' own box, so Select All lines up with them (a dash while only some are checked)
            Button { f.toggleAll() } label: {
                HStack(spacing: 8) {
                    DictationFeedbackSheet.box(f.allChecked ? .on : f.checked.isEmpty ? .off : .some)
                    Text(T("dictation.feedback.all"))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text(T("dictation.feedback.count", f.checked.count, DictationFeedbackModel.megabytes(f.total)))
                .font(.system(size: SettingsMetrics.detailSize).monospacedDigit())
                .foregroundStyle(f.tooLarge ? Color.brandErr : .secondary)
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    var list: some View {
        let tw = timeWidth
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(f.entries) { e in row(e, timeWidth: tw) }
            }
            .padding(.vertical, 4)
        }
        .frame(height: 248)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    /// The time column as wide as its longest time ("14:14", or "Oct 28 14:14" when older ones are listed): the text
    /// starts right after it, no blank band.
    var timeWidth: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let w = f.entries.map { (DictationFeedbackSheet.time($0.time) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(w) + 4
    }

    func row(_ e: DictationEntry, timeWidth: CGFloat) -> some View {
        Button { f.toggle(e.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DictationFeedbackSheet.box(f.checked.contains(e.id) ? .on : .off)
                Text(DictationFeedbackSheet.time(e.time)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).frame(width: timeWidth, alignment: .leading)
                Text(DictationEntry.preview(e.finalText)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(f.hasAudio(e) ? Island.clock(e.duration) : T("dictation.feedback.text_only"))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(f.checked.contains(e.id) ? .isSelected : [])
    }

    /// what goes, where, who reads it, when it is deleted — one quiet paragraph, not a form
    var what: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(T("dictation.feedback.what"))
            Text(T("dictation.feedback.where"))
        }
        .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            if case .failed(let s) = f.phase {
                Text(s).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandErr).lineLimit(2)
            } else if f.tooLarge {
                Text(T("dictation.feedback.too_large")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandErr)
            } else if f.phase == .sending {
                BrandSpinnerView(size: 12)
                Text(T("dictation.feedback.sending")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(T("dictation.feedback.cancel"), action: close).keyboardShortcut(.cancelAction)
            Button(f.checked.isEmpty ? T("dictation.feedback.send") : T("dictation.feedback.send.n", f.checked.count)) { f.send() }
                .keyboardShortcut(.defaultAction)
                .disabled(f.checked.isEmpty || f.tooLarge || f.phase == .sending)
        }
    }

    // MARK: sent

    func sent(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(T("dictation.feedback.sent")).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(T("dictation.feedback.id")).foregroundStyle(.secondary)
                Text(id).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                Button(T("dictation.feedback.copy_id")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(id, forType: .string)
                }
                .controlSize(.small)
            }
            .padding(.top, 10)
            Text(T("dictation.feedback.id.detail")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            HStack {
                Spacer()
                Button(T("dictation.feedback.done"), action: close).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
    }

    enum Box { case on, off, some }
    static func box(_ b: Box) -> some View {
        Image(systemName: b == .on ? "checkmark.square.fill" : b == .some ? "minus.square.fill" : "square")
            .foregroundStyle(b == .off ? Color.secondary : Color.brandInk)
            .font(.system(size: 13))
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(d) ? "jmm" : "MMMdjmm")
        return f.string(from: d)
    }
}
