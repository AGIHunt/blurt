// Settings → Dictation's one Style choice, and what a history entry reports it did (docs/design/dictation-styles.md
// §Settings). Pure, unit-tested (DictationStyleTests).
//
// One choice — Verbatim / Light / Structured / Auto — over the two keys the engine already reads, so the engine needs
// nothing new: record.dictation.polish ("off" = no polish at all: no model loaded, no context read) and the styles'
// global default (record.dictation.styles "default"). Verbatim stores both (polish off, default verbatim), so a take
// typed in it says Verbatim in the history; the others store polish unset and their style as the default (Light =
// unset). The per-category styles stay as they are (they only apply while polish is on).
import Foundation

public enum DictationStyleChoice {
    /// The choice Settings shows for these keys.
    public static func current(polishOff: Bool, config: DictationStyleConfig) -> DictationStyle {
        polishOff ? .verbatim : (config.fallback == .verbatim ? .verbatim : config.fallback ?? DictationStyleConfig.smartDefault)
    }

    /// Picking `s`: the styles config to store, and record.dictation.polish (nil = unset, polish on).
    public static func apply(_ s: DictationStyle, to config: DictationStyleConfig) -> (config: DictationStyleConfig, polish: String?) {
        var c = config
        c.fallback = s == DictationStyleConfig.smartDefault ? nil : s
        return (c, s == .verbatim ? "off" : nil)
    }
}

/// What a dictation in the history did, for its detail: the style that actually ran (not just the one asked for) and
/// what polish did.
public enum DictationEntryReport {
    public enum Polish: Equatable {
        /// polished by this model (its id)
        case model(String)
        /// polish refused or was too slow: typed as heard (the model's id when known)
        case fellBack(String?)
        /// nothing to tidy (a word or two)
        case short
        /// the take's style doesn't polish, or polish is off
        case off
        /// polish was wanted but there was no model to run it
        case noModel
    }

    /// `hasModel`: a polish model is on this Mac now — an older take that wasn't polished, with no style saying why,
    /// is put down to polish being off then.
    public static func polish(_ e: DictationEntry, hasModel: Bool) -> Polish {
        if e.fellBack { return .fellBack(e.model) }
        if e.polished != nil { return .model(e.model ?? "") }
        if e.reason == "short" { return .short }
        if let s = e.style, DictationStyle(rawValue: s.style) == .verbatim { return .off }
        return hasModel ? .off : .noModel
    }

    /// The style the typed text is in: Verbatim when nothing polished it (style, polish off, no model, a fall-back);
    /// Light when Structured's pass gave nothing back or Auto made no list; else the style asked for. nil: an entry
    /// from before styles.
    public static func styleRan(_ e: DictationEntry) -> DictationStyle? {
        guard let rec = e.style else { return nil }
        let asked = DictationStyle(rawValue: rec.style) ?? .light
        if asked == .verbatim || e.fellBack || e.polished == nil { return .verbatim }
        switch asked {
        case .auto: return rec.rendered ? .structured : .light
        case .structured: return rec.rendered || e.timing?["structure_ms"] != nil ? .structured : .light
        default: return asked
        }
    }
}
