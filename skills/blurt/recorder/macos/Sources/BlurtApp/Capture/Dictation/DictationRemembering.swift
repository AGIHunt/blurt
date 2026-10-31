// Per-app memory of Structured and Translate (v1.0.6, the founder; the rules are BlurtCore's DictationRemember):
//
//  • a typed take that was switched (⇧ / Fn+⇧ / the island to Structured, ⌘ / the island's left half to Translate)
//    leaves that switch on in its app: the next take there starts Structured, or translated, until it is switched
//    back. Settings → Dictation lists the apps (Reset / remove). Off: Settings → Dictation → "Remember Structured and
//    Translate for each app" (record.dictation.learn_styles, on);
//  • the first few times something is remembered, a line says so and how to switch back;
//  • a take that starts with something remembered says so when the app's last take was an hour ago or more (or none
//    since launch), while it listens: a translation left on in yesterday's chat must not go out unnoticed;
//  • a take whose text went into another app than the one it started in (the user switched while it was on its way:
//    since 2026-10-31 it is pasted there) leaves nothing, in either app. The switch was made while speaking in A for
//    text meant for B: remembered on A, A's next takes would start translated (or Structured) where the user never
//    wanted it — the risk above; on B, it would be measured against A's starting state (turning A's remembered
//    translation off would drop B's). A one-off it stays: the next take in B starts with B's own settings.
import AppKit
import BlurtCore

/// What a take switched (⇧ / ⌘ / the island), taken as it stops listening — the next take resets the live state — and
/// remembered once its text is in (`Dictation.remember`), in the app it started in, unless it went into another one.
struct DictationSwitches {
    let bundle: String
    let style: DictationStyle?
    let styleSource: DictationStyleSource?
    let styleToggles: Int
    let translateOn: Bool
    let translateToggles: Int
}

extension Dictation {
    /// The app's last typed take this launch (the reminder's clock).
    private static var lastTakeAt: [String: Date] = [:]

    /// A take stops listening: what it switched, for `remember` once its text is in (nil: no app to remember it for).
    func switchesAtStop() -> DictationSwitches? {
        guard let b = styleBundle, !b.isEmpty else { return nil }
        Dictation.lastTakeAt[b] = Date()
        return DictationSwitches(bundle: b, style: styleDecision?.style, styleSource: explicitStyle?.source ?? styleDecision?.source,
                                 styleToggles: styleToggles, translateOn: translating.on, translateToggles: translating.toggles)
    }

    /// After a typed take: what was switched stays on in the app it started in. `appChanged`: the text went into
    /// another app — nothing is remembered (the header says why).
    func remember(_ sw: DictationSwitches, appChanged: Bool) {
        let b = sw.bundle
        guard Dictation.learnStyles else { return }
        if appChanged {
            if sw.styleToggles > 0 || sw.translateToggles > 0 || sw.styleSource == .chord {
                emit(["event": "dictation_remember", "what": "skipped", "bundle": b, "why": "app_changed"])
            }
            return
        }
        var saved: [String] = []
        if let style = sw.style, let source = sw.styleSource,
           let c = DictationRemember.style(final: style, source: source, toggles: sw.styleToggles,
                                           config: Dictation.styleConfig, bundle: b) {
            Dictation.setStyleConfig(c)
            emit(["event": "dictation_remember", "what": "style", "bundle": b, "style": c.apps[b]?.rawValue ?? NSNull()])
            if c.apps[b] == .structured { saved.append(Dictation.styleName(.structured)) }
        }
        if let c = DictationRemember.translate(on: sw.translateOn, toggles: sw.translateToggles,
                                               config: Dictation.translateConfig, bundle: b) {
            Dictation.setTranslateConfig(c)
            emit(["event": "dictation_remember", "what": "translate", "bundle": b, "on": c.apps.contains(b)])
            if c.apps.contains(b) { saved.append(Loc.t("dictation.remember.translate", table: "Dictation")) }
        }
        // said the first three times only; after that the ear's glyphs and the start reminder carry it
        let shown = Dictation.settings["remember_hint_shown"] as? Int ?? 0
        guard !saved.isEmpty, shown < 3 else { return }
        Dictation.set("remember_hint_shown", shown + 1)
        toast("dictation.remember.saved", Dictation.appName(bundle: b, fallback: nil),
              saved.joined(separator: Loc.t("dictation.remember.and", table: "Dictation")),
              keys(for: saved.count == 2, translated: sw.translateOn && sw.translateToggles > 0),
              key: Dictation.noticeToastKey, seconds: 4)
    }

    /// A take starts: when it starts with something remembered and the app was quiet for an hour, say so.
    func remindRemembered() {
        guard let b = styleBundle, !b.isEmpty, Dictation.learnStyles,
              DictationRemember.remind(lastTake: Dictation.lastTakeAt[b], now: Date()) else { return }
        let structured = Dictation.styleConfig.learned.contains(b) && styleDecision?.style == .structured
        let translated = translating.on && translating.source == "app"
        guard structured || translated else { return }
        var what: [String] = []
        if structured { what.append(Dictation.styleName(.structured)) }
        if translated { what.append(Loc.t("dictation.remember.translate", table: "Dictation")) }
        emit(["event": "dictation_remember", "what": "remind", "bundle": b, "structured": structured, "translate": translated])
        toast("dictation.remember.kept", Dictation.appName(bundle: b, fallback: nil),
              what.joined(separator: Loc.t("dictation.remember.and", table: "Dictation")),
              structured && translated ? "⇧ / ⌘" : structured ? "⇧" : "⌘",
              key: Dictation.styleToastKey, seconds: 4)
        Dictation.lastTakeAt[b] = Date()        // once, not again on every take of a long session
    }

    private func keys(for both: Bool, translated: Bool) -> String {
        if both { return "⇧ / ⌘" }
        return translated ? "⌘" : "⇧"
    }
}
