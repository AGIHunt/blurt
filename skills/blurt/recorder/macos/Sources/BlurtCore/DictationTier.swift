// What dictation runs on for a Mac (docs/design/dictation.md §Defaults by Mac; the measurements:
// docs/design/dictation-eval-2026-10-31.md §6): the recogniser, its window and whether it hears the field's text, the
// local polish model, and — with a cloud key — cloud polish with macOS's transcript as the second opinion. Pure: the
// app (Settings → Models shows it) and transcribe.py's `dictation_tier` (which picks what Automatic runs) are the same
// rule; tests/fixtures/dictation_tier.jsonl checks both.
//
// On the founder's 95 takes: Qwen3-ASR 1.7B (30 s windows, field context) 2.50 % errors, 0.6B (20 s windows) 3.34 %,
// macOS Speech 6.72 %; Gemma 4 E2B as local polish within ±0.2 points (it does fillers and punctuation, not words);
// cloud polish (DeepSeek V4.1 Flash) with macOS's transcript as "Also heard" 2.20 % on the 1.7B, 2.84 % on the 0.6B.
// The 1.7B needs ~3.1 GB and its last 30 s window decoded at key-up: it goes to 16 GB+ Macs fast enough for it —
// measured (`transcribe.py bench`: rtf ≤ rtfLimit), or, not measured, any chip but a base M1 / M2 (7–10 GPU cores
// against the reference M5 Max's 40: over a second at key-up on long takes). Where the 1.7B doesn't go (8 GB, slow chips)
// Fun-ASR-Nano runs for people who speak only Chinese, English and Japanese (2.92 %, 0.07–0.17 s at key-up, 2.6 GB:
// it fits 8 GB), else the 0.6B (30 languages); 8 GB Macs get no local polish (it doesn't fit beside them). Until the
// recogniser is downloaded, macOS's own runs (`first`).
import Foundation

public enum DictationTier {
    /// The 1.7B's real-time factor at most this (decode seconds per second of speech, `transcribe.py bench`)
    public static let rtfLimit = 0.05
    public static let large = "qwen3-asr-1.7b-mlx"
    public static let small = "qwen3-asr-0.6b-mlx"
    /// Fun-ASR-Nano: the small recogniser for people who speak only its languages
    public static let fun = "fun-asr-nano-mlx"
    /// its languages (asr_models.json `languages`)
    public static let funLanguages: Set<String> = ["zh", "en", "ja"]
    public static let polishModel = "gemma4-e2b"
    public static let firstMinutes = "apple-speech"
    /// The base chips the 1.7B is too slow on when nothing was measured (not Pro, Max or Ultra)
    public static let slowChips: Set<String> = ["Apple M1", "Apple M2"]

    public enum Size: String { case minimal, light, standard, pro }
    /// Why this recogniser: the memory (8 GB and under), fast enough, the measured rtf, or the chip's name
    public enum Reason: String { case ram, fast, rtf, chip }

    public struct Choice: Equatable {
        public var tier: Size
        /// the speech model's id (asr_models.json); nil under 8 GB — the voice-note pick runs
        public var recognizer: String?
        /// the window dictation hears its pieces again in (s): the model's rehear_window_s
        public var window: Double?
        /// the field's text before the cursor goes to the recogniser as context (the 1.7B's field_context_chars)
        public var fieldContext: Bool
        /// the local polish model (polish_models.json); nil: none by default
        public var localPolish: String?
        /// polish in the cloud (DeepSeek V4.1 Flash on Model Studio / DeepSeek where offered: CloudModelList's
        /// measured default) — the recogniser stays on the Mac (§6.3 A)
        public var cloudPolish: Bool
        /// macOS's transcript of the same audio goes to cloud polish as "Also heard" (without it cloud polish made the
        /// text worse: 2.50 → 3.16 %)
        public var secondTranscript: Bool
        /// what dictates while the recogniser downloads
        public var first: String
        public var why: Reason
    }

    /// A base M1 / M2 by the chip's name ("Apple M1"; "Apple M1 Pro" is not one).
    public static func slowChip(_ chip: String?) -> Bool {
        slowChips.contains((chip ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    /// "zh-Hans-CN" → "zh", "en_US" → "en" (the scripts' user_languages are these already)
    static func base(_ code: String) -> String {
        String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    /// Fun-ASR-Nano speaks every one of `languages` (none known: no — the 0.6B speaks thirty).
    public static func funSpeaks(_ languages: [String]) -> Bool {
        let l = languages.map(base).filter { !$0.isEmpty }
        return !l.isEmpty && l.allSatisfy(funLanguages.contains)
    }

    /// The recogniser where the 1.7B doesn't go: Fun-ASR-Nano for its languages, else the 0.6B.
    public static func smallRecognizer(_ languages: [String]) -> String { funSpeaks(languages) ? fun : small }

    /// The window dictation hears pieces again in with the small recogniser (asr_models.json rehear_window_s)
    public static func window(_ id: String) -> Double { id == large ? 30 : id == fun ? funWindow : 20 }
    public static let funWindow: Double = 30

    /// The defaults for a Mac with `ramGB` of memory. `rtf`: the 1.7B's measured real-time factor here (nil: not
    /// measured — `slowChip` decides); `hasCloudKey`: a cloud service that can polish is connected; `languages`: the
    /// user's (the scripts' user_languages), which decide between Fun-ASR-Nano and the 0.6B.
    public static func recommended(ramGB: Double, rtf: Double?, hasCloudKey: Bool, slowChip: Bool = false,
                                   languages: [String] = []) -> Choice {
        let tier: Size = ramGB < 7.5 ? .minimal : ramGB < 15 ? .light : ramGB < 30 ? .standard : .pro
        let fast = rtf.map { $0 <= rtfLimit } ?? !slowChip
        let big = (tier == .standard || tier == .pro) && fast
        let rec: String? = big ? large : tier == .minimal ? nil : smallRecognizer(languages)
        let why: Reason = tier == .minimal || tier == .light ? .ram : big ? .fast : rtf != nil ? .rtf : .chip
        return Choice(tier: tier, recognizer: rec, window: rec.map(window), fieldContext: big,
                      localPolish: tier == .standard || tier == .pro ? polishModel : nil,
                      cloudPolish: hasCloudKey, secondTranscript: hasCloudKey, first: firstMinutes, why: why)
    }
}
