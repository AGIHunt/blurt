// Cloud speech's model choices (CloudSpeechSheet; docs/design/first-minute-speech.md §2.4): a default, the service's
// current ids, and Custom… for any other; each id carries what was measured on it, or says it wasn't. Aliyun's speech
// models other than qwen3-asr-flash need its native API, which transcribe.py doesn't speak, so they aren't offered.
// The text jobs' models (polish, translate, Copy Text from Screen) come from each service's live list instead
// (Settings → Models: CloudStore, BlurtCore CloudModelList). Storage: CloudSpeech's per-service model; "" always means
// the default, so a better default reaches everyone who didn't pick one.
import SwiftUI
import BlurtCore

enum CloudPickerJob: String { case speech }

struct CloudModelChoice: Hashable {
    let id: String
    /// the measurement's line (Dictation.strings `dictation.cloud.model.note.*`), nil = not measured
    let note: String?
    /// the product's name where the id is only an API's ("Qwen3-ASR Flash" for qwen3-asr-flash); nil: the id is the name
    var name: String? = nil
    var title: String { name ?? id }
}

enum CloudModels {
    /// The service's speech models, the default first: "dashscope" or CloudSpeech.Service's raw value (2026-10-31:
    /// OpenAI's gpt-4o transcription models were retired for gpt-transcribe; whisper-1 stays the default for its
    /// timestamps).
    static func choices(_ job: CloudPickerJob, provider: String) -> [CloudModelChoice] {
        func c(_ id: String, _ note: String? = nil, name: String? = nil) -> CloudModelChoice { CloudModelChoice(id: id, note: note, name: name) }
        switch provider {
        case "dashscope": return [c("qwen3-asr-flash", "speech.qwen3_asr", name: "Qwen3-ASR Flash")]
        case "openai": return [c("whisper-1"), c("gpt-transcribe")]
        case "groq": return [c("whisper-large-v3-turbo"), c("whisper-large-v3")]
        default: return []          // the user's own service: Custom… only
        }
    }

    /// What "" means for this job and provider ("" when the provider has no default: the model must be typed).
    static func defaultID(_ job: CloudPickerJob, provider: String) -> String { choices(job, provider: provider).first?.id ?? "" }
}

/// One model choice: a pop-up of the provider's list (the default marked) and Custom…, which shows a field for any id.
/// `model` is the stored value: "" = the default. `inherit`: what "" means when the job falls back to another one
/// (translate → the polish model), shown instead of a default.
struct CloudModelPicker: View {
    let label: String
    let job: CloudPickerJob
    let provider: String
    @Binding var model: String
    var inherit: String? = nil
    var width: CGFloat = 220
    @State private var custom = false

    private static let customTag = "\u{1}custom"
    private var choices: [CloudModelChoice] { CloudModels.choices(job, provider: provider) }
    private var defaultID: String { CloudModels.defaultID(job, provider: provider) }
    private var trimmed: String { model.trimmingCharacters(in: .whitespaces) }
    /// the pop-up's value: "" (default / same as polish), a listed id, or Custom…
    private var selection: String {
        if custom { return Self.customTag }
        if trimmed.isEmpty || trimmed == defaultID && inherit == nil { return "" }
        return choices.contains { $0.id == trimmed } ? trimmed : Self.customTag
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !choices.isEmpty || inherit != nil {
                ChoicePopup(label: label, choices: entries, selection: Binding(get: { selection }, set: pick), width: width)
            }
            if choices.isEmpty && inherit == nil || selection == Self.customTag {
                TextField(choices.isEmpty ? T("dictation.cloud.model.placeholder") : T("dictation.cloud.model.custom.placeholder"), text: $model)
                    .textFieldStyle(.roundedBorder)
            }
            if let n = note {
                Text(n).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SettingsMetrics.fieldTextInset)
            }
        }
        // the row's label lines up with the pop-up's title, whatever follows under it (a field, the measured line)
        .alignmentGuide(.firstTextBaseline) { $0[.top] + 18 }
        .onAppear { custom = selection == Self.customTag }
    }

    private var entries: [(String, String)] {
        var out: [(String, String)] = []
        if inherit != nil { out.append(("", T("dictation.cloud.model.same_as"))) }
        for c in choices {
            let isDefault = inherit == nil && c.id == defaultID
            out.append((isDefault ? "" : c.id, isDefault ? T("dictation.cloud.model.default", c.title) : c.title))
        }
        out.append((Self.customTag, T("dictation.cloud.model.custom")))
        return out
    }

    private func pick(_ v: String) {
        custom = v == Self.customTag
        if custom { if choices.contains(where: { $0.id == trimmed }) || trimmed.isEmpty { model = "" } ; return }
        model = v
    }

    /// what was measured on the chosen model, or that it wasn't (Custom: nothing)
    private var note: String? {
        if selection == Self.customTag { return nil }
        let id = selection.isEmpty ? (inherit == nil ? defaultID : "") : selection
        guard !id.isEmpty, let c = choices.first(where: { $0.id == id }) else { return nil }
        return c.note.map { T("dictation.cloud.model.note.\($0)") } ?? T("dictation.cloud.model.unmeasured")
    }
}
