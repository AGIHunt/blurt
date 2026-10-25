// Dictation styles in the app (docs/design/dictation-styles.md §3; the rules are BlurtCore's DictationStyle /
// DictationStyleLearn; the language work is the polish model's):
//
//  • at the key-down the app in front gives the take its style (record.dictation.styles; light everywhere unless the
//    user chose otherwise); verbatim skips polish for the whole take;
//  • while talking: ⇧ alone, or a click on the island, toggles Structured for this take (the trigger's `.style`);
//    Fn+⇧ as the start press starts in Structured. No spoken commands ("make a list" is content: people dictate
//    instructions to AI agents). The island's right ear shows the list glyph while Structured; a toast names the switch;
//  • at key-up, Structured (and Auto): one pass of the polish model over the stitched text (polish.py `structure`,
//    DictationStream.finish): it resolves self-corrections and lays out what was enumerated, or leaves a paragraph.
//    Light never resolves a correction and never lists. Then the category's variant (chat: no final 。 on one
//    sentence; code: one line);
//  • reformat-last (⌥⇧L, the island's suggestion chip): the last take in the next style — verbatim → light →
//    structured → verbatim — with the same model passes (made on demand, off the dictation's path), replacing it in the
//    field only while it is exactly as it was typed (else the clipboard), with Undo. ⌥⇧L while a take is on its way waits
//    for it (it means the take said last; cancelled, failed or empty, the request goes with it); the chip and Undo act on the take they were shown for, never on a newer one, and
//    go when the next take starts. History: the style, the router's inputs, every reformat / undo / revert /
//    suggestion, and the text now in the field;
//  • the list chip: after a light take long enough to hold a list, the structuring pass runs in the background (after
//    the paste); when the model made it a list, the island offers it;
//  • learning only suggests: ≥ 3 consistent signals in an app → the island asks once.
// Test hooks: `dictation style …` (DictationTestHooks.swift).
import AppKit
import BlurtCore

/// The last paste, for reformat-last: its versions and where it went.
final class DictationLastPaste {
    let id: String
    let bundle: String?
    let app: String?
    let category: DictationAppCategory
    /// the style it was typed in (auto: structured when a list was typed, else light)
    let original: DictationStyle
    var current: DictationStyle
    /// the transcript (custom words fixed): verbatim's text
    let raw: String
    /// light's text (polish's, before the variant); nil: the take wasn't polished (made on demand)
    var light: String?
    /// the structuring pass's text (nil: not made yet, or it refused — `structuredTried` tells which)
    var structured: String?
    var structuredTried = false
    /// what is in the field now, as typed (fitted), and where
    var typed: String
    /// the styled text of `current` (before the fit at the cursor)
    var currentVersion: String
    let field: DictationField?
    var location: Int?
    var prefix = "", suffix = ""
    let at = Date()

    init(id: String, bundle: String?, app: String?, category: DictationAppCategory, original: DictationStyle, raw: String,
         light: String?, typed: String, currentVersion: String, field: DictationField?, location: Int?) {
        self.id = id; self.bundle = bundle; self.app = app; self.category = category; self.original = original
        self.current = original; self.raw = raw; self.light = light; self.typed = typed; self.currentVersion = currentVersion
        self.field = field; self.location = location
    }

    /// The text of `style` (nil: it has none yet — light or the structured pass not made).
    func version(_ style: DictationStyle) -> String? {
        switch style {
        case .verbatim: return DictationStyleVariant.apply(raw, category: category, structured: false).text
        case .light: return light.map { DictationStyleVariant.apply($0, category: category, structured: false).text }
        case .structured, .auto:
            guard let s = structured else { return nil }
            let p = style.pick(light: light ?? raw, structured: s)
            return DictationStyleVariant.apply(p.text, category: category, structured: p.list).text
        }
    }

    /// The anchors around the typed text in the field (40 characters each side), read now.
    func anchor() {
        guard let f = field, let loc = location, let (text, _) = f.read() else { return }
        let ns = text as NSString, len = (typed as NSString).length
        var at = loc
        if at < 0 || at + len > ns.length || ns.substring(with: NSRange(location: at, length: len)) != typed {
            let lo = max(0, loc - 200)
            let r = ns.range(of: typed, options: [], range: NSRange(location: lo, length: ns.length - lo))
            guard r.location != NSNotFound else { location = nil; return }
            at = r.location
        }
        location = at
        prefix = ns.substring(with: NSRange(location: max(0, at - 40), length: at - max(0, at - 40)))
        let end = at + len
        suffix = ns.substring(with: NSRange(location: end, length: min(40, ns.length - end)))
    }
}

extension Dictation {
    // MARK: the router

    /// A take begins (the key-down, or the start): the app in front gives the base style.
    func beginStyle(bundle: String?) {
        styleBundle = bundle
        explicitStyle = nil
        styleToggles = 0
        routeStyle()
    }

    func routeStyle() {
        styleDecision = DictationStyleRouter.decide(explicit: explicitStyle, config: Dictation.styleConfig, bundle: styleBundle)
        island.refresh()
    }

    /// ⇧ alone / a click on the island while listening: Structured for this take, or back.
    func toggleStyle(via: DictationStyleSource) {
        guard phase == .listening, let d = styleDecision else { return }
        let to = DictationStyleRouter.toggled(d.style, base: d.base)
        explicitStyle = (to, via)
        styleToggles += 1
        routeStyle()
        emit(["event": "dictation_style", "action": "toggle", "via": via.rawValue, "style": to.rawValue, "id": entryID])
        noteUsed(.list)
        // the ear's chip says which style it is; the line explains Structured the first couple of times only
        // (DictationStyleToggleHint — every toast stays ≥ 5 s, so a line on every ⇧ would be noise), "Back to …" too
        let shown = Dictation.settings["style_hint_shown"] as? Int ?? 0
        guard DictationStyleToggleHint.says(shown: shown) else { return }
        if to == .structured { Dictation.set("style_hint_shown", shown + 1) }
        // its own key: a second ⇧ replaces the first's line, and it never takes the place of the last take's Undo
        island.toast(Loc.t(to == .structured ? "dictation.style.toast.structured" : "dictation.style.toast.back",
                           table: "Dictation", Dictation.styleName(to)), key: Dictation.styleToastKey, seconds: 3)
    }

    static func styleName(_ s: DictationStyle) -> String { Loc.t("dictation.style.\(s.rawValue)", table: "Dictation") }

    // MARK: after the stitch (deliver)

    /// The take's text in its style, and the record for the history: the structured text Structured asked for (made at
    /// key-up by the stream), the category's variant.
    func styleText(_ r: DictationStream.Result, take: DictationTake) -> (text: String, record: DictationStyleRecord, ms: Int) {
        let t0 = CACurrentMediaTime()
        let d = take.style ?? DictationStyleRouter.decide(config: Dictation.styleConfig, bundle: take.bundle)
        let pick = d.style.pick(light: r.text, structured: r.structured)
        let v = DictationStyleVariant.apply(pick.text, category: d.category, structured: pick.list)
        let rec = DictationStyleRecord(style: d.style.rawValue, source: d.source.rawValue, category: d.category.rawValue,
                                       base: d.base.rawValue, explicit: take.explicit?.style.rawValue,
                                       toggles: take.toggles, rendered: pick.list, variant: v.changes)
        return (v.text, rec, Int((CACurrentMediaTime() - t0) * 1000))
    }

    /// The fit at the cursor (DictationFit), or for a list: it starts on a line of its own.
    static func fit(_ text: String, before: String, after: String, list: Bool) -> (text: String, changes: [String]) {
        if list {
            let b = before.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            return !b.isEmpty && !b.hasSuffix("\n") ? ("\n" + text, ["list_line"]) : (text, [])
        }
        // right after a list item: the take starts a paragraph of its own
        if DictationFit.endsInListItem(before: before, after: after) { return ("\n\n" + text, ["after_list"]) }
        let fit = DictationFit.fit(text, before: before, after: after)
        return fit.trimmed ? (fit.text, fit.changes) : (text, [])
    }

    /// After the paste: what reformat-last needs, the ≡ suggestion for a take the model finds a list in, and the
    /// learning check.
    func rememberPaste(id: String, app: NSRunningApplication?, bundle: String?, r: DictationStream.Result, record: DictationStyleRecord,
                       typed: String, result: DictationInsert.Result, field: DictationField?, location: Int?) {
        let cat = DictationAppCategory(rawValue: record.category) ?? .other
        let style = DictationStyle(rawValue: record.style) ?? .light
        let original: DictationStyle = style == .auto ? (record.rendered ? .structured : .light) : style
        // light's text: what polish gave (a fall-back is the transcript, as typed); a take polish didn't run on gets it
        // on demand
        let lp = DictationLastPaste(id: id, bundle: bundle, app: AppNames.name(for: bundle, running: app), category: cat,
                                    original: original, raw: r.raw, light: r.polished != nil || r.fellBack ? r.text : nil,
                                    typed: typed, currentVersion: "", field: field, location: location)
        lp.structured = r.structured
        lp.structuredTried = style.structures && (r.structured != nil || r.structureReason != nil)
        lp.currentVersion = lp.version(original) ?? typed
        lp.anchor()
        lastPaste = lp
        DictationWatch.shared.onReverted = { [weak self, weak lp] in
            guard let self = self, let lp = lp, self.lastPaste === lp else { return }
            let rec = DictationReformatRecord(action: "revert", from: lp.current.rawValue, to: DictationStyle.light.rawValue, replaced: false)
            DictationHistory.shared.restyle(lp.id, rec)
            emit(["event": "dictation_style", "action": "revert", "id": lp.id])
            self.checkStyleSuggestion(bundle: lp.bundle)
        }
        // the ≡ chip: the model finds a list in a take that went in as prose — one key (or this click) away. The pass
        // runs after the paste, so the dictation never waits for it.
        if Dictation.suggestLists, result != .none, original == .light, DictationStitch.mayHoldList(lp.light ?? lp.raw) {
            withStructured(lp) { [weak self] in
                guard let self = self, self.lastPaste === lp, !self.listening, lp.current == .light,
                      let s = lp.structured, DictationStitch.listLines(s) >= 2 else { return }
                DictationHistory.shared.restyle(lp.id, DictationReformatRecord(action: "suggest", from: "light", to: "structured", replaced: false))
                let key = hk(.reformat)
                island.toast(Loc.t(key.isEmpty ? "dictation.style.chip" : "dictation.style.chip.key", table: "Dictation", key),
                             key: Dictation.toastKey, seconds: 6,
                             actionTitle: Loc.t("dictation.style.chip.action", table: "Dictation"), action: { [weak self, weak lp] in
                    guard let lp = lp else { return }
                    self?.reformat(lp, to: .structured, action: "reformat", via: "chip")
                })
                emit(["event": "dictation_style", "action": "suggest_list", "id": id, "lines": DictationStitch.listLines(s)])
            }
        }
        checkStyleSuggestion(bundle: lp.bundle)
    }

    // MARK: reformat-last

    /// ⌥⇧L (and the test hook): the last take in the next style of the cycle that reads differently.
    func reformatLast(via: String) {
        guard !listening else { return }                // talking: ⇧ is the style key now
        // a take is being pasted (or the last one is still on its way): this is about the take said last — once it
        // is in, and only that one (cancelled, failed or empty: the request goes with it)
        guard !inserting, queue.isEmpty else {
            let id = reformatAfterPaste.request(last: queue.last, via: via)
            return emit(["event": "dictation_reformat", "result": "after_paste", "via": via, "for": id ?? NSNull()])
        }
        noteUsed(.reformat)
        guard let lp = lastPaste else {
            island.toast(Loc.t("dictation.style.reformat.nothing", table: "Dictation"), key: Dictation.toastKey)
            emit(["event": "dictation_reformat", "result": "nothing", "via": via])
            return
        }
        let order = [lp.current.next, lp.current.next.next]
        withLight(lp) { [weak self] in
            self?.withStructured(lp) { [weak self] in
                guard let self = self, self.lastPaste === lp else { return }
                for s in order {
                    if let t = lp.version(s), t != lp.currentVersion { return self.apply(lp, to: s, text: t, action: "reformat", via: via) }
                }
                island.toast(Loc.t("dictation.style.reformat.same", table: "Dictation"), key: Dictation.toastKey)
                emit(["event": "dictation_reformat", "result": "same", "via": via, "id": lp.id])
            }
        }
    }

    /// The suggestion chip (structured) and Undo (the original style), for the take `lp` they were shown for, never
    /// whichever is newest when clicked: when a newer take has come since, they do nothing (they never rewrite the
    /// newer text — dogfood #29: the toast read the last take at click time, not its own; the toasts went with the
    /// newer take's start).
    func reformat(_ lp: DictationLastPaste, to style: DictationStyle, action: String, via: String) {
        guard !listening, !inserting, lastPaste === lp else {
            return emit(["event": "dictation_reformat", "result": "stale", "via": via, "id": lp.id])
        }
        withLight(lp) { [weak self] in
            self?.withStructured(lp) { [weak self] in
                guard let self = self, self.lastPaste === lp, let t = lp.version(style), t != lp.currentVersion else { return }
                self.apply(lp, to: style, text: t, action: action, via: via)
            }
        }
    }

    /// Light for a take that was typed verbatim: polish it now (the warm server; off the dictation's path).
    private func withLight(_ lp: DictationLastPaste, _ then: @escaping () -> Void) {
        guard lp.light == nil, !lp.raw.isEmpty, Dictation.polishOn, polishModel != nil else { return then() }
        let vocab = DictationVocabulary.shared.payload(), variant = lp.category == .chat ? "chat" : nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Dictation.polish(lp.raw, timeout: Dictation.polishTimeout, loadBudget: Dictation.loadBudget, vocab: vocab,
                                     context: nil, variant: variant)
            let text = (r?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            DispatchQueue.main.async {
                if r?["fell_back"] as? Bool != true, let t = text { lp.light = t }
                then()
            }
        }
    }

    /// The structuring pass for the last take, once (reformat-last, the chip): the same model pass Structured runs at
    /// key-up, on Light's text (the transcript when there is none). Off the dictation's path.
    func withStructured(_ lp: DictationLastPaste, _ then: @escaping () -> Void) {
        guard lp.structured == nil, !lp.structuredTried, Dictation.polishOn, polishModel != nil else { return then() }
        lp.structuredTried = true
        let src = lp.light ?? lp.raw
        guard !src.isEmpty else { return then() }
        let vocab = DictationVocabulary.shared.payload()
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = CACurrentMediaTime()
            let r = Dictation.structure(src, timeout: Dictation.structureTimeout, loadBudget: Dictation.loadBudget, vocab: vocab)
            let text = (r?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            DispatchQueue.main.async {
                if r?["fell_back"] as? Bool != true, let t = text { lp.structured = t }
                emit(["event": "dictation_structure", "id": lp.id, "on_demand": true, "ms": Int((CACurrentMediaTime() - t0) * 1000),
                      "list": r?["list"] as? Bool ?? false, "fell_back": r?["fell_back"] as? Bool ?? (r == nil),
                      "reason": r?["reason"] ?? NSNull()])
                then()
            }
        }
    }

    /// The last take as the user edited it in the field, in `style` — the same passes the take's own versions got
    /// (Light: polish; Structured: the structuring pass; Verbatim: as it stands) — then copied, the field left alone.
    private func restyleEdited(_ lp: DictationLastPaste, _ edited: String, to style: DictationStyle, action: String, via: String) {
        let vocab = DictationVocabulary.shared.payload(), variant = lp.category == .chat ? "chat" : nil
        let t0 = CACurrentMediaTime()
        DispatchQueue.global(qos: .userInitiated).async {
            var out = edited
            switch style {
            case .structured, .auto:
                if let r = Dictation.structure(edited, timeout: Dictation.structureTimeout, loadBudget: Dictation.loadBudget, vocab: vocab),
                   r["fell_back"] as? Bool != true, let t = r["text"] as? String, !t.isEmpty { out = t }
            case .light:
                if let r = Dictation.polish(edited, timeout: Dictation.polishTimeout, loadBudget: Dictation.loadBudget, vocab: vocab,
                                            context: nil, variant: variant),
                   r["fell_back"] as? Bool != true, let t = r["text"] as? String, !t.isEmpty { out = t }
            case .verbatim:
                break
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.lastPaste === lp else { return }
                DictationInsert.copy(out)
                lp.current = style
                lp.currentVersion = out
                DictationHistory.shared.restyle(lp.id, DictationReformatRecord(action: action, from: lp.original.rawValue,
                                                                               to: style.rawValue, replaced: false, text: nil, before: nil))
                emit(["event": "dictation_reformat", "result": "copied", "why": "edited", "via": via, "id": lp.id,
                      "to": style.rawValue, "text": out, "from_edited": true, "ms": Int((CACurrentMediaTime() - t0) * 1000)])
                island.toast(Loc.t("dictation.style.copied.edited", table: "Dictation", Dictation.styleName(style)),
                             key: Dictation.toastKey, seconds: 3)
            }
        }
    }

    /// Puts `text` where the last take went, if it is still exactly as typed; else on the clipboard.
    private func apply(_ lp: DictationLastPaste, to style: DictationStyle, text: String, action: String, via: String) {
        let t0 = CACurrentMediaTime()
        let from = lp.current
        let typedBefore = lp.typed
        func done(_ replaced: Bool, _ why: String?) {
            lp.current = style
            lp.currentVersion = text
            DictationHistory.shared.restyle(lp.id, DictationReformatRecord(action: action, from: from.rawValue, to: style.rawValue,
                                                                           replaced: replaced, text: replaced ? lp.typed : nil,
                                                                           before: replaced ? typedBefore : nil))
            DictationHistoryWindow.shared.reloadIfOpen()
            emit(["event": "dictation_reformat", "result": replaced ? "replaced" : "copied", "why": why ?? NSNull(), "via": via,
                  "id": lp.id, "from": from.rawValue, "to": style.rawValue, "action": action, "text": text,
                  "ms": Int((CACurrentMediaTime() - t0) * 1000)])
            let name = Dictation.styleName(style)
            var t: Island.Toast
            if action == "undo" {
                t = Island.Toast(text: Loc.t(replaced ? "dictation.style.undone" : "dictation.style.copied", table: "Dictation", name),
                                 actionTitle: nil, action: nil)
            } else {
                let original = lp.original
                t = Island.Toast(text: Loc.t(replaced ? "dictation.style.reformatted" : "dictation.style.copied", table: "Dictation", name),
                                 actionTitle: replaced ? Loc.t("dictation.toast.undo", table: "Dictation") : nil,
                                 action: replaced ? { [weak self, weak lp] in
                                     guard let lp = lp else { return }
                                     self?.reformat(lp, to: original, action: "undo", via: "toast")
                                 } : nil)
            }
            if replaced { t.icon = .check }      // the ok check when the field really changed ("copied" is not done yet)
            t.seconds = replaced && action != "undo" ? 5 : 2.4
            // one toast about the last take: a second ⌥⇧L replaces the first at once (its Undo is then for the new
            // version), and the next take's start drops it
            t.key = Dictation.toastKey
            island.toast(t)
            if action != "undo" || replaced { checkStyleSuggestion(bundle: lp.bundle) }
        }
        guard let f = lp.field, Date().timeIntervalSince(lp.at) < DictationReformat.window, let loc = lp.location,
              let (now, _) = f.read() else {
            DictationInsert.copy(text)
            return done(false, lp.field == nil ? "no_field" : "too_late")
        }
        guard let span = DictationReformat.span(in: now, inserted: lp.typed, prefix: lp.prefix, suffix: lp.suffix, near: loc) else {
            // the user changed it: never overwritten — and what they see now is what gets reformatted and copied
            // (v0.9 dogfood: their 方案→计划 fix was missing from the copy, the stored take reformatted instead)
            let maxLen = (lp.typed as NSString).length * 3 + 200
            guard let edited = DictationLearn.locate(in: now, prefix: lp.prefix, suffix: lp.suffix, near: loc, maxLength: maxLen),
                  !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                DictationInsert.copy(text)      // the edit can't be told apart: the take as said, and the toast says so
                emit(["event": "dictation_reformat", "result": "copied", "why": "edited_unread", "via": via, "id": lp.id])
                island.toast(Loc.t("dictation.style.copied.original", table: "Dictation", Dictation.styleName(style)),
                             key: Dictation.toastKey, seconds: 3)
                return
            }
            return restyleEdited(lp, edited, to: style, action: action, via: via)
        }
        let ns = now as NSString
        let before = String(ns.substring(to: span.location).suffix(500))
        let after = String(ns.substring(from: NSMaxRange(span)).prefix(500))
        let fitted = Dictation.fit(text, before: before, after: after, list: DictationStitch.listLines(text) >= 2).text
        DictationWatch.shared.stop("reformat")
        DictationInsert.replace(fitted, in: f, range: span) { ok in
            guard ok else {
                DictationInsert.copy(text)
                return done(false, "not_replaced")
            }
            lp.typed = fitted
            lp.location = span.location
            lp.anchor()
            if Dictation.learnOn { DictationWatch.shared.start(field: f, inserted: fitted, location: span.location) }
            done(true, nil)
        }
    }

    // MARK: learning (suggest, never switch)

    /// ≥ 3 consistent signals in this app → the island asks once.
    func checkStyleSuggestion(bundle: String?) {
        guard Dictation.learnStyles, let b = bundle, !b.isEmpty else { return }
        let cfg = Dictation.styleConfig
        let current = DictationStyleRouter.decide(config: cfg, bundle: b).base
        let asked = Set(Dictation.settings["style_asked"] as? [String] ?? [])
        DispatchQueue.global(qos: .utility).async {
            let entries = DictationHistory.shared.load()
            guard let s = DictationStyleLearn.suggest(entries: entries, bundle: b, current: current, asked: asked) else { return }
            DispatchQueue.main.async { self.askStyleSuggestion(s) }
        }
    }

    func askStyleSuggestion(_ s: DictationStyleLearn.Suggestion) {
        var asked = Dictation.settings["style_asked"] as? [String] ?? []
        guard !asked.contains(s.key) else { return }
        asked.append(s.key)
        Dictation.set("style_asked", asked)           // asked once, whatever the answer
        emit(["event": "dictation_style", "action": "suggest_default", "bundle": s.bundle, "style": s.style.rawValue, "signals": s.signals])
        let app = Dictation.appName(bundle: s.bundle, fallback: s.app)
        // a question that goes away by itself (12 s; unanswered = no): it must never hold up the toasts behind it
        // (reformat's Undo, the list chip)
        var t = Island.Toast(text: Loc.t("dictation.style.learn.\(s.style.rawValue)", table: "Dictation", app),
                             actionTitle: Loc.t("dictation.style.learn.yes", table: "Dictation"), action: {
            var c = Dictation.styleConfig
            c.apps[s.bundle] = s.style
            c.learned.insert(s.bundle)
            Dictation.setStyleConfig(c)
            emit(["event": "dictation_style", "action": "learned", "bundle": s.bundle, "style": s.style.rawValue])
            island.toast(Loc.t("dictation.style.learn.done", table: "Dictation"), key: nil, icon: .check)
        })
        t.secondTitle = Loc.t("dictation.style.learn.no", table: "Dictation")
        t.second = { emit(["event": "dictation_style", "action": "declined", "bundle": s.bundle, "style": s.style.rawValue]) }
        t.seconds = 12
        island.toast(t)
    }

    /// An app's name from its bundle id (AppNames: the running or installed app's), else what the history says when
    /// it is a name, else "Unknown app" — never the id.
    static func appName(bundle: String, fallback: String?) -> String {
        AppNames.display(name: nil, bundle: bundle) ?? AppNames.displayOrUnknown(name: fallback, bundle: nil)
    }
}
