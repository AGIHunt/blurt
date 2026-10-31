// Dictation's choices side by side (Settings → Models: the lead line and Compare…; the setup assistant's speech
// step): how often each gets a word wrong, the wait after you stop talking, the cost, and what leaves the Mac — and
// which fits this Mac. Pure: DictationChoicesTests.
//
// Source of every number: docs/design/dictation-eval-2026-10-31.md (§1 summary, §3 public speech, §5 latency after
// key-up, §6 the three tiers, §7 what to tell users; Fun-ASR-Nano: §2.1, §3, §4.4, §5 and its re-measure through the
// app's path in docs/design/dictation.md §Defaults by Mac). Mixed = the founder's 95 takes (Mandarin with English terms),
// error per unit (a Chinese character or an English word); per language = §3's public sets (English: LibriSpeech
// clean, Chinese: AISHELL-1, German: Common Voice de). Japanese is left out on purpose: §3 says its CER mixes kanji and
// kana spellings — "read the order, not the level" — so a level would mislead. A new eval changes this
// table and nothing else: the copy only formats it.
//
// Two rows describe the eval's configuration, which the app doesn't fully send yet (keep in step with §4):
//   cloudPolish      2.20 % needs Apple's transcript as a second opinion ("Also heard", §4.2); without it cloud polish
//                    made the 1.7B worse (2.50 → 3.16 %).
//   cloudRecognizer  2.0 % is the whole take with the field text; the app's own piece-by-piece path echoed the field
//                    and the word list (26.6 %, §4.1) — the adapter below never recommends it.
//   volcengine       Seed-ASR 2.0 streamed while the user talks (§2.1, §5, §6.3 B′): 2.18 %, ~0.5 s after key-up
//                    however long the take, ¥1 an hour. Its names are weaker (79 %); with cloud polish 91 %. An option,
//                    never the recommendation; offered to Chinese speakers (the service is mainland China's).
import Foundation

/// One way to dictate. The raw value is the recogniser's id in asr_models.json, except cloud polish, which runs on a
/// local model (Qwen3-ASR or Fun-ASR-Nano) and sends only the text out.
public enum DictationChoice: String, CaseIterable, Hashable, Sendable {
    case macOSSpeech = "apple-speech"
    case qwenSmall = "qwen3-asr-0.6b-mlx"
    /// Chinese, English and Japanese only: shown to people who speak only those (DictationChoices.choices)
    case funNano = "fun-asr-nano-mlx"
    case qwenLarge = "qwen3-asr-1.7b-mlx"
    case cloudPolish = "cloud-polish"
    case cloudRecognizer = "qwen3-asr-flash"
    /// Volcengine Seed-ASR 2.0, streamed (VolcengineSpeech)
    case volcengine = "volcengine-seedasr"

    /// a cloud service hears the voice
    public var cloudRecognition: Bool { self == .cloudRecognizer || self == .volcengine }

    public var local: Bool { self == .macOSSpeech || localModel }
    /// a downloaded local model cloud polish can sit on
    public var localModel: Bool { self == .qwenSmall || self == .funNano || self == .qwenLarge }
    /// the dictation recogniser it sets (cloud polish: the local Qwen3-ASR under it, chosen by the caller)
    public var recognizer: String? { self == .cloudPolish ? nil : rawValue }
}

public struct DictationFacts: Hashable, Sendable {
    public enum Leaves: Hashable, Sendable {
        case nothing, text
        /// the voice, to Alibaba Cloud (Model Studio)
        case voice
        /// the voice, to ByteDance's Volcengine
        case voiceToVolcengine
    }
    public enum Cost: Hashable, Sendable {
        case free
        /// per dictation (~1,500 tokens) — in yuan and in US dollars
        case perDictation(cny: Double, usd: Double)
        /// per hour of speech
        case perHour(cny: Double, usd: Double)
    }

    public let choice: DictationChoice
    /// error per unit on the founder's mixed Chinese + English takes (§1, §6)
    public let mixed: Double
    /// error per unit by language (§3), nil where not measured
    public let languages: [String: Double]
    /// names and English terms right (§1)
    public let termsRight: Double?
    /// seconds from key-up to text, p50 short take … p50 minute-long take (§5, rounded as §7 says them)
    public let delay: ClosedRange<Double>
    public let downloadMB: Double
    /// memory it holds while dictation runs (§6.2)
    public let memoryGB: Double
    /// the least RAM the eval recommends it for (§6.2: 8 GB → 0.6B, 16 GB → 1.7B)
    public let minRAMGB: Double
    public let cost: Cost
    public let leaves: Leaves
}

public enum DictationChoices {
    /// The comparison, in the order it is shown: out of the box, the local models, then the cloud.
    public static let table: [DictationFacts] = [
        DictationFacts(choice: .macOSSpeech, mixed: 0.0672, languages: ["en": 0.0154, "zh": 0.0434, "de": 0.0844],
                       termsRight: 0.45, delay: 0.2...0.2, downloadMB: 0, memoryGB: 0, minRAMGB: 0, cost: .free, leaves: .nothing),
        DictationFacts(choice: .qwenSmall, mixed: 0.0334, languages: ["en": 0.0154, "zh": 0.0317, "de": 0.0931],
                       termsRight: 0.75, delay: 0.1...0.2, downloadMB: 1010, memoryGB: 2.1, minRAMGB: 8, cost: .free, leaves: .nothing),
        // Fun-ASR-Nano as the app runs it (30 s windows, the Words as hotwords: 2.92 %, the eval's own runner 2.84 %;
        // 0.07 / 0.17 s after key-up on ~5 s / ~60 s takes — dictation.md §Defaults by Mac); §3: no German
        DictationFacts(choice: .funNano, mixed: 0.0292, languages: ["en": 0.0162, "zh": 0.0246],
                       termsRight: 0.77, delay: 0.1...0.2, downloadMB: 1598, memoryGB: 2.6, minRAMGB: 8, cost: .free, leaves: .nothing),
        DictationFacts(choice: .qwenLarge, mixed: 0.0250, languages: ["en": 0.0116, "zh": 0.0164, "de": 0.0758],
                       termsRight: 0.79, delay: 0.2...0.3, downloadMB: 2468, memoryGB: 3.1, minRAMGB: 16, cost: .free, leaves: .nothing),
        // on the 1.7B; on the 0.6B see `cloudPolishOnSmall`. Delay: the 1.7B's plus DeepSeek V4.1 Flash's 0.8–1.1 s.
        // ¥0.002 ≈ $0.0003 a dictation (§6.3 A). Not measured on the public sets.
        DictationFacts(choice: .cloudPolish, mixed: 0.0220, languages: [:], termsRight: 0.89, delay: 1.0...1.4,
                       downloadMB: 2468, memoryGB: 3.1, minRAMGB: 16, cost: .perDictation(cny: 0.002, usd: 0.0003), leaves: .text),
        // Qwen3-ASR Flash, the whole take at key-up with the field text (§1 point 4); $0.11 an hour ≈ ¥0.8 (§6.3 B, §7)
        DictationFacts(choice: .cloudRecognizer, mixed: 0.0200, languages: ["en": 0.0147, "zh": 0.0152, "de": 0.0368],
                       termsRight: nil, delay: 0.5...1.5, downloadMB: 0, memoryGB: 0, minRAMGB: 0,
                       cost: .perHour(cny: 0.8, usd: 0.11), leaves: .voice),
        // Volcengine Seed-ASR 2.0 streamed (`bigmodel_nostream`, the words as hotwords, the field text as a dialogue
        // turn): 2.18 %, names 79 %; 0.45 / 0.52 s after key-up on ~5 s / ~60 s takes (§5); ¥1 an hour ≈ $0.14 (§6.3 B′).
        // Per language (§3): English and German with automatic language (as for a non-Chinese speaker), Chinese
        // (AISHELL) with its zh-en default (as for a Chinese speaker).
        DictationFacts(choice: .volcengine, mixed: 0.0218, languages: ["en": 0.0108, "zh": 0.0270, "de": 0.0455],
                       termsRight: 0.79, delay: 0.5...0.5, downloadMB: 0, memoryGB: 0, minRAMGB: 0,
                       cost: .perHour(cny: 1.0, usd: 0.14), leaves: .voiceToVolcengine),
    ]

    /// Cloud polish over the 0.6B (§6.3 A: 2.84 %), for Macs that run the small model.
    public static let cloudPolishOnSmall = DictationFacts(
        choice: .cloudPolish, mixed: 0.0284, languages: [:], termsRight: nil, delay: 0.9...1.3, downloadMB: 1010, memoryGB: 2.1,
        minRAMGB: 8, cost: .perDictation(cny: 0.002, usd: 0.0003), leaves: .text)

    /// Cloud polish over Fun-ASR-Nano (2.73 %, names 89 %: one run through the app's path, DeepSeek V4.1 Flash with macOS's
    /// transcript as "Also heard" — docs/design/dictation.md §Defaults by Mac).
    public static let cloudPolishOnFun = DictationFacts(
        choice: .cloudPolish, mixed: 0.0273, languages: [:], termsRight: 0.89, delay: 0.9...1.3, downloadMB: 1598, memoryGB: 2.6,
        minRAMGB: 8, cost: .perDictation(cny: 0.002, usd: 0.0003), leaves: .text)

    public static func facts(_ c: DictationChoice, on base: DictationChoice = .qwenLarge) -> DictationFacts {
        if c == .cloudPolish && base == .qwenSmall { return cloudPolishOnSmall }
        if c == .cloudPolish && base == .funNano { return cloudPolishOnFun }
        return table.first { $0.choice == c }!
    }

    /// The rows shown on this Mac, in the table's order: Fun-ASR-Nano only for people who speak only its languages,
    /// Volcengine only for people who speak Chinese (a mainland China service) — either one also when dictation already
    /// uses it.
    public static func choices(_ mac: Mac, inUse: DictationChoice? = nil) -> [DictationChoice] {
        DictationChoice.allCases.filter { c in
            switch c {
            case .funNano: return DictationTier.funSpeaks(mac.languages) || inUse == .funNano
            case .volcengine: return speaksChinese(mac.languages) || inUse == .volcengine
            default: return true
            }
        }
    }

    static func speaksChinese(_ languages: [String]) -> Bool { languages.contains { ["zh", "yue"].contains(base($0)) } }

    // MARK: the words

    /// How accurate, for people: 3–5 of five stars, never a count of mistakes (the founder, 2026-10-31: "1 mistake every
    /// 40 words" reads as poor quality — say how good it is). 5 at ≤ 2.7 % (1.7B, the cloud), 4 at ≤ 4 % (0.6B,
    /// Fun-ASR-Nano), else 3 (macOS Speech on Chinese + English; on English alone it is a 5).
    public static func level(_ error: Double) -> Int {
        guard error > 0 else { return 0 }
        if error <= 0.027 { return 5 }
        if error <= 0.04 { return 4 }
        return 3
    }

    /// The language whose own line is shown beside the mixed one: the user's first language when it isn't Chinese and
    /// was measured; nil for Chinese speakers (the mixed line is theirs) and unmeasured languages.
    public static func ownLanguage(_ languages: [String]) -> String? {
        guard let first = languages.first.map(base) else { return nil }
        if first == "zh" || first == "yue" { return nil }
        return table.contains { $0.languages[first] != nil } ? first : nil
    }

    /// "en-US" → "en", "zh-Hans" → "zh"
    static func base(_ code: String) -> String { String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "") }

    // MARK: this Mac

    public enum Fit: Hashable, Sendable {
        case fits
        /// RAM, in GB
        case needsMemory(Int)
        case needsAppleSilicon
        case needsMacOS26
        /// a cloud row with no service connected: the row's action adds one
        case needsKey
    }

    public struct Mac: Hashable, Sendable {
        public var ramGB: Double
        public var appleSilicon: Bool
        /// macOS's own recogniser runs here (macOS 26 in a language it speaks)
        public var macOSSpeech: Bool
        /// a connected service polish can use (any)
        public var textKey: Bool
        /// a connected service that also recognises speech (Model Studio)
        public var speechKey: Bool
        /// Volcengine Speech is connected (its App ID and Access Token)
        public var volcengineKey: Bool
        /// `transcribe.py bench` real-time factor of the 1.7B here (nil: not measured)
        public var rtf: Double?
        /// a base M1 / M2 (DictationTier.slowChip): the 1.7B is too slow there when nothing was measured
        public var slowChip: Bool
        /// the languages the user speaks (the scripts' user_languages, else the Mac's): Fun-ASR-Nano or the 0.6B
        public var languages: [String]
        public init(ramGB: Double, appleSilicon: Bool, macOSSpeech: Bool, textKey: Bool, speechKey: Bool, rtf: Double? = nil,
                    slowChip: Bool = false, languages: [String] = [], volcengineKey: Bool = false) {
            self.ramGB = ramGB; self.appleSilicon = appleSilicon; self.macOSSpeech = macOSSpeech
            self.textKey = textKey; self.speechKey = speechKey; self.rtf = rtf; self.slowChip = slowChip
            self.languages = languages; self.volcengineKey = volcengineKey
        }
    }

    /// Whether a choice runs on this Mac, and what it needs when it doesn't. Memory: reported sizes run a little under
    /// the label (a 16 GB Mac says 15.9), so half a GB of slack.
    public static func fit(_ c: DictationChoice, on base: DictationChoice = .qwenLarge, mac: Mac) -> Fit {
        let f = facts(c, on: base)
        switch c {
        case .macOSSpeech:
            return mac.macOSSpeech ? .fits : .needsMacOS26
        case .qwenSmall, .funNano, .qwenLarge, .cloudPolish:
            if !mac.appleSilicon { return .needsAppleSilicon }
            if mac.ramGB + 0.5 < f.minRAMGB { return .needsMemory(Int(f.minRAMGB)) }
            return c == .cloudPolish && !mac.textKey ? .needsKey : .fits
        case .cloudRecognizer:
            return mac.speechKey ? .fits : .needsKey
        case .volcengine:
            return mac.volcengineKey ? .fits : .needsKey
        }
    }

    /// The local model cloud polish sits on: the one dictation uses now (Qwen3-ASR or Fun-ASR-Nano), else the one
    /// recommended here.
    public static func polishBase(recognizer: String?, mac: Mac) -> DictationChoice {
        if let r = recognizer, let c = DictationChoice(rawValue: r), c.localModel { return c }
        let l = recommendedLocal(mac)
        return l == .macOSSpeech ? .qwenSmall : l
    }

    /// The best choice on this Mac without the cloud (§6.2): the 1.7B from 16 GB; on 8 GB and on a slow GPU (rtf over
    /// ~0.05: base M1 / M2 — §6.2 says pick by measured speed, not by chip name) Fun-ASR-Nano for Chinese, English and
    /// Japanese speakers, else the 0.6B; macOS Speech where none runs (Intel).
    public static func recommendedLocal(_ mac: Mac) -> DictationChoice {
        guard mac.appleSilicon else { return .macOSSpeech }
        let t = DictationTier.recommended(ramGB: mac.ramGB, rtf: mac.rtf, hasCloudKey: false, slowChip: mac.slowChip,
                                          languages: mac.languages)
        return t.recognizer.flatMap(DictationChoice.init(rawValue:)) ?? .macOSSpeech
    }

    // MARK: the recommendation

    /// What Settings recommends for this Mac — DictationTier's defaults (the same rule the app and transcribe.py
    /// apply), as a row of the table: the local recogniser, + cloud polish when a service that can polish is connected.
    /// Every caller (the Models page's lead, Compare…, the setup assistant) reads this one function.
    public static func recommended(_ mac: Mac) -> DictationChoice {
        let local = recommendedLocal(mac)
        if mac.textKey, local.localModel { return .cloudPolish }
        return local
    }

    /// The row dictation runs on now: the recogniser it uses (nil: nothing yet), and whether polish goes to a cloud
    /// service. Cloud polish counts only over a downloaded local model (the configurations measured); macOS Speech with cloud
    /// polish, or another model, is no row of the table (nil) — never a row whose privacy column isn't true.
    public static func inUse(recognizer: String?, cloudPolish: Bool) -> DictationChoice? {
        guard let r = recognizer, let c = DictationChoice(rawValue: r), c != .cloudPolish else { return nil }
        if c.cloudRecognition { return c }
        if cloudPolish { return c.localModel ? .cloudPolish : nil }
        return c
    }
}
