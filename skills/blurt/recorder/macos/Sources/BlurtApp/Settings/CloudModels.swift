// The models each cloud job can use, per provider (docs/design/first-minute-speech.md §2.4–2.5): a default, a short list
// of the provider's current ids, and Custom… for any other. Each id carries what was measured on it — on the founder's
// 270 kept dictations (polish), the 60-case translate set (two blind judges), tests/fixtures/screen_text (Copy Text from
// Screen) — or says it wasn't. The lists were read from each provider's /models on 2026-10-29; Aliyun's speech models
// other than qwen3-asr-flash need its native API, which transcribe.py doesn't speak, so they aren't offered.
// Storage stays where it was: DictationCloud.Setup.model (polish), .translateModel / .visionModel (empty = the
// provider's default), CloudSpeech's per-service model; "" always means the default, so a better default reaches
// everyone who didn't pick one.
import SwiftUI
import BlurtCore

enum CloudJob: String { case speech, polish, translate, vision }

struct CloudModelChoice: Hashable {
    let id: String
    /// the measurement's line (Dictation.strings `dictation.cloud.model.note.*`), nil = not measured
    let note: String?
}

enum CloudModels {
    /// The provider's list for a job, the default first. provider: DictationCloud.Provider's raw value, or for speech
    /// "dashscope" / CloudSpeech.Service's raw value.
    static func choices(_ job: CloudJob, provider: String) -> [CloudModelChoice] {
        func c(_ id: String, _ note: String? = nil) -> CloudModelChoice { CloudModelChoice(id: id, note: note) }
        switch (job, provider) {
        case (.polish, "deepseek"): return [c("deepseek-flash", "polish.deepseek_flash"), c("deepseek-v4-pro")]
        case (.polish, "dashscope"): return [c("deepseek-v4.1-flash", "polish.ds41"), c("qwen3.8-flash", "polish.qwen38"),
                                             c("qwen3.6-flash", "polish.qwen36"), c("qwen-flash", "polish.qwen_flash"),
                                             c("qwen-plus", "polish.qwen_plus")]
        case (.translate, "deepseek"): return [c("deepseek-flash", "translate.deepseek_flash"), c("deepseek-v4-pro")]
        case (.translate, "dashscope"): return [c("deepseek-v4.1-flash", "translate.ds41"), c("qwen3.8-flash", "translate.qwen38"),
                                                c("qwen3.6-flash", "translate.qwen36")]
        case (.vision, "deepseek"): return [c("deepseek-flash", "vision.deepseek_flash")]
        case (.vision, "dashscope"): return [c("qwen3.6-flash", "vision.qwen36"), c("qwen3.5-flash", "vision.qwen35"),
                                             c("qwen3-vl-plus", "vision.qwen3_vl_plus"), c("qwen3.5-ocr", "vision.qwen35_ocr"),
                                             c("qwen-vl-ocr", "vision.qwen_vl_ocr")]
        case (.speech, "dashscope"): return [c("qwen3-asr-flash", "speech.qwen3_asr")]
        case (.speech, "openai"): return [c("whisper-1"), c("gpt-4o-mini-transcribe"), c("gpt-4o-transcribe")]   // whisper-1 gives timestamps
        case (.speech, "groq"): return [c("whisper-large-v3-turbo"), c("whisper-large-v3")]
        default: return []          // the user's own service: Custom… only
        }
    }

    /// What "" means for this job and provider ("" when the provider has no default: the model must be typed).
    static func defaultID(_ job: CloudJob, provider: String) -> String { choices(job, provider: provider).first?.id ?? "" }
}

/// One model choice: a pop-up of the provider's list (the default marked) and Custom…, which shows a field for any id.
/// `model` is the stored value: "" = the default. `inherit`: what "" means when the job falls back to another one
/// (translate → the polish model), shown instead of a default.
struct CloudModelPicker: View {
    let label: String
    let job: CloudJob
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
            out.append((isDefault ? "" : c.id, isDefault ? T("dictation.cloud.model.default", c.id) : c.id))
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
