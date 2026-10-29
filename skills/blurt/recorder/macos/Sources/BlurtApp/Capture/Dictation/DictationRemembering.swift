// Per-app memory of Structured and Translate (v1.0.6, the founder; the rules are BlurtCore's DictationRemember):
//
//  • a typed take that was switched (⇧ / Fn+⇧ / the island to Structured, ⌘ / the island's left half to Translate)
//    leaves that switch on in its app: the next take there starts Structured, or translated, until it is switched
//    back. Settings → Dictation lists the apps (Reset / remove). Off: Settings → Dictation → "Remember Structured and
//    Translate for each app" (record.dictation.learn_styles, on);
//  • the first few times something is remembered, a line says so and how to switch back;
//  • a take that starts with something remembered says so when the app's last take was an hour ago or more (or none
//    since launch), while it listens: a translation left on in yesterday's chat must not go out unnoticed.
import AppKit
import BlurtCore

extension Dictation {
    /// The app's last typed take this launch (the reminder's clock).
    private static var lastTakeAt: [String: Date] = [:]

    /// After a typed take: what was switched stays on in the app.
    func rememberSwitches() {
        guard let b = styleBundle, !b.isEmpty else { return }
        defer { Dictation.lastTakeAt[b] = Date() }
        guard Dictation.learnStyles else { return }
        var saved: [String] = []
        if let d = styleDecision,
           let c = DictationRemember.style(final: d.style, source: explicitStyle?.source ?? d.source, toggles: styleToggles,
                                           config: Dictation.styleConfig, bundle: b) {
            Dictation.setStyleConfig(c)
            emit(["event": "dictation_remember", "what": "style", "bundle": b, "style": c.apps[b]?.rawValue ?? NSNull()])
            if c.apps[b] == .structured { saved.append(Dictation.styleName(.structured)) }
        }
        if let c = DictationRemember.translate(on: translating.on, toggles: translating.toggles,
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
              saved.joined(separator: Loc.t("dictation.remember.and", table: "Dictation")), keys(for: saved.count == 2),
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

    private func keys(for both: Bool) -> String {
        if both { return "⇧ / ⌘" }
        return translating.on && translating.toggles > 0 ? "⌘" : "⇧"
    }
}
