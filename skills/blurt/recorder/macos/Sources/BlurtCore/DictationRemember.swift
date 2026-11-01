// What a switch during a take leaves for the next one in the same app (v1.0.6, the founder): Structured (⇧, the
// island) and Translate (⌘, the island's left half) stay on in that app until switched back, instead of the
// island asking after three switches (docs/design/dictation-styles.md §3.5). A remembered style goes into the app's
// own style (`DictationStyleConfig.apps`, marked learned: Settings lists it with Reset); a remembered translation
// into the list of apps that translate (`DictationTranslateConfig.apps`). Switching back removes it. Only a take that
// was typed counts: one cancelled or with nothing heard leaves nothing. Pure: DictationRememberTests.
import Foundation

public enum DictationRemember {
    /// After a typed take in `bundle`: the style config with the take's final style remembered, or nil when nothing
    /// changes (no switch this take, or the app already has that style).
    public static func style(final: DictationStyle, source: DictationStyleSource, toggles: Int,
                             config: DictationStyleConfig, bundle: String) -> DictationStyleConfig? {
        guard toggles > 0 || source == .chord, [.shift, .island, .chord].contains(source) else { return nil }
        var c = config
        c.apps[bundle] = nil
        let own = DictationStyleRouter.decide(config: c, bundle: bundle).base      // the app's style without one of its own
        if final == own { c.learned.remove(bundle) } else { c.apps[bundle] = final; c.learned.insert(bundle) }
        return c.apps[bundle] == config.apps[bundle] && c.learned == config.learned ? nil : c
    }

    /// After a typed take in `bundle`: the translate config with the take's final on / off remembered, or nil.
    public static func translate(on: Bool, toggles: Int, config: DictationTranslateConfig, bundle: String) -> DictationTranslateConfig? {
        guard toggles > 0, on != config.apps.contains(bundle) else { return nil }
        var c = config
        if on { c.apps.insert(bundle) } else { c.apps.remove(bundle) }
        return c
    }

    /// A take starting with something remembered says so when the app's last take was this long ago (or none since
    /// launch): a translation still on from yesterday's chat must not go out unnoticed.
    public static let remindAfter: TimeInterval = 3600

    public static func remind(lastTake: Date?, now: Date) -> Bool {
        guard let t = lastTake else { return true }
        return now.timeIntervalSince(t) >= remindAfter
    }
}
