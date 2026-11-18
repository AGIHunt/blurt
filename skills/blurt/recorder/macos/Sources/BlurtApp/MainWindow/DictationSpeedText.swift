// How fast dictation is, in words (BlurtCore DictationSpeed has the figures): "0.4 s", "Text 0.4 s after you
// stopped", "Recognition 0.3 s · Polish 0.7 s", "On this Mac, text usually 0.4 s after you stop". Read by the
// Dictation page (the first day heading, an entry's details) and Settings → Models / → Dictation (the model rows).
// Settings reads the history file through a short-lived cache, so drawing a pane never re-reads it each time.
import Foundation
import BlurtCore

@MainActor
enum DictationSpeedText {
    /// "0.4 秒" / "0.4 s"; "不到 0.1 秒" / "under 0.1 s"
    static func seconds(_ ms: Int) -> String {
        DictationSpeed.secondsText(ms, locale: Loc.locale).map { T("dictation.speed.seconds", $0) } ?? T("dictation.speed.under")
    }

    /// One take's headline: "停下后 0.4 秒出字" (nil: no timings, or nothing was typed)
    static func after(_ e: DictationEntry) -> String? {
        DictationSpeed.total(e).map { T("dictation.speed.after", seconds($0)) }
    }

    /// What the wait went on: "识别 0.3 秒 · 润色 0.7 秒" — only the stages that ran (nil: none recorded)
    static func parts(_ e: DictationEntry) -> String? {
        guard DictationSpeed.total(e) != nil else { return nil }
        let ps = DictationSpeed.stages(e).map { T("dictation.speed.\($0.stage.rawValue)", seconds($0.ms)) }
        return ps.isEmpty ? nil : ps.joined(separator: " · ")
    }

    /// The page's figure: "通常停下后 0.4 秒出字", and its tooltip (over how many takes; the long ones apart).
    static func usual(_ s: DictationSpeed) -> (line: String, tip: String) {
        var tip = T("dictation.speed.usual.tip", Loc.number(s.count))
        if let l = s.longMedianMS { tip += (Loc.isChinese ? "" : " ") + T("dictation.speed.usual.long", seconds(l)) }
        return (T("dictation.speed.usual", seconds(s.medianMS)), tip)
    }

    /// Settings' line beside the dictation model in use: measured on this Mac with that model (nil: fewer than five
    /// takes with it — nothing is said rather than a guess).
    static func here(model: String?) -> String? {
        guard let m = model, let s = DictationSpeed(cachedEntries(), model: m) else { return nil }
        // recognition apart when it was recorded: the figure the recommendation's reference line is comparable with
        if let a = s.asrMedianMS { return T("dictation.speed.here.asr", seconds(s.medianMS), seconds(a)) }
        return T("dictation.speed.here", seconds(s.medianMS))
    }

    // MARK: the history, read at most every 30 s for Settings

    private static var cache: (at: Date, entries: [DictationEntry])?

    static func cachedEntries() -> [DictationEntry] {
        if let c = cache, Date().timeIntervalSince(c.at) < 30 { return c.entries }
        let es = DictationHistory.shared.load()
        cache = (Date(), es)
        return es
    }
}

// MARK: Settings → Models

extension DictationSpeedText {
    /// A model row's line with this Mac's measured wait under it (the dictation model in use only).
    static func withMeasured(_ detail: String?, model: String?) -> String? {
        guard let h = here(model: model) else { return detail }
        return detail.map { $0 + "\n" + h } ?? h
    }

    /// The recommendation's expectation for the dictation model it would download: the published wait after key-up
    /// (DictationChoices.delay — measured on the reference Mac, recognition only), labelled as not this Mac's. Nil for
    /// a model without a published figure: nothing is made up.
    static func reference(_ ids: [String]) -> String? {
        guard let c = ids.lazy.compactMap(DictationChoice.init(rawValue:)).first(where: \.localModel) else { return nil }
        let fmt = Loc.string("speech.speed.reference", table: "Speech")
        return Loc.format(fmt, [ChoiceText.model(c.rawValue), ChoiceText.delay(DictationChoices.facts(c).delay)])
    }
}
