// Dictation's takes in flight (docs/design/dictation.md §Takes in flight): what happens between a take's stop and
// its text being in. The rules are BlurtCore's (DictationTakeFlow.swift: DictationPasteQueue, DictationTips,
// DictationASRFailure); this acts on them.
//
//  • the stop frees the key at once: each stopped take is a `DictationTake` with everything its text needs (the app
//    it started in, the style, the context, its stream), and a tap starts the next take while this one is still being
//    transcribed or polished. The takes are pasted in the order they were said, one paste at a time;
//  • a take is pasted only into the app it started in: when the user moved to another app meanwhile (a slow take), the
//    text is copied and the island says "Copied — paste with ⌘V", and a queued Return is dropped;
//  • after the stop, the live panel shows the text actually typed for about 1.5 s — what a double tap would send;
//  • Esc (or the menu's Cancel) while a take is on its way throws it away: never pasted, its Return dropped;
//  • recognition failed (no model, a model that didn't answer, an error): the take keeps its audio and a history
//    row, the island says what failed, with Retry (or Download… when there is no model). Never "nothing heard";
//  • the once-a-day notices (a polish or speech model fell back), the quiet tips of the first takes, what a skipped
//    Return or a press the mode doesn't use means.
// `Dictation.getSpeechModel` / `getPolishModel` are the one way dictation asks for a model download (Settings →
// Speech → Dictation, the download started there).
import AppKit
import BlurtCore
import Combine

/// A take that stopped listening, on its way to the cursor.
final class DictationTake {
    let id: String
    /// the app in front at the key-down, and what "the same app" is compared by at paste time
    let front: NSRunningApplication?
    let frontKey: String
    let started: Date
    let duration: Double
    let wav: URL
    let context: DictationContext?
    let polishTried: Bool
    let keyUp: CFTimeInterval
    // the style as the take ended (DictationStyles.swift)
    let style: DictationStyleRouter.Decision?
    let explicit: (style: DictationStyle, source: DictationStyleSource)?
    let toggles: Int
    let bundle: String?
    /// its words under the island (LiveTranscript's session)
    let liveSession: Int
    let stream: DictationStream
    /// Structured / Auto: one structuring pass at the end
    let structure: Bool
    var stage: Dictation.Phase = .transcribing
    /// a double tap came for it: Return once it is pasted
    var sendAfterPaste = false
    var cancelled = false
    var result: DictationStream.Result?

    init(id: String, front: NSRunningApplication?, frontKey: String, started: Date, duration: Double, wav: URL,
         context: DictationContext?, polishTried: Bool, keyUp: CFTimeInterval, style: DictationStyleRouter.Decision?,
         explicit: (style: DictationStyle, source: DictationStyleSource)?, toggles: Int, bundle: String?,
         liveSession: Int, stream: DictationStream, structure: Bool) {
        self.id = id; self.front = front; self.frontKey = frontKey; self.started = started; self.duration = duration
        self.wav = wav; self.context = context; self.polishTried = polishTried; self.keyUp = keyUp; self.style = style
        self.explicit = explicit; self.toggles = toggles; self.bundle = bundle; self.liveSession = liveSession
        self.stream = stream; self.structure = structure
    }
}

extension Dictation {
    /// The key of the toasts that belong to one take (reformat's Undo, the list chip): a new take drops them.
    static let takeToastKey = "dictation.take"

    // MARK: the line of takes

    /// A take stopped: it joins the line and its last piece goes to the models.
    func enqueue(_ take: DictationTake) {
        takes[take.id] = take
        queue.add(take.id)
        take.stream.setContext(take.context)
        take.stream.onStage = { [weak self, weak take] stage in
            guard let self = self, let take = take, !take.cancelled else { return }
            take.stage = stage == "polish" ? .polishing : .transcribing
            self.updatePhase()
        }
        updatePhase()
        take.stream.finish(keyUp: take.keyUp, structure: take.structure) { [weak self] r in self?.landed(take, r) }
    }

    /// A take's text is in (or recognition failed, or there were no words).
    private func landed(_ take: DictationTake, _ r: DictationStream.Result) {
        guard !take.cancelled, takes[take.id] === take else {
            try? FileManager.default.removeItem(at: take.wav)        // a result nobody takes: its audio goes too
            return
        }
        if let f = r.asrError { return recognitionFailed(take, f) }
        guard !r.empty else {
            try? FileManager.default.removeItem(at: take.wav)
            if take.sendAfterPaste {         // nothing to send: Return would send something else
                emit(["event": "dictation_send", "result": "skipped", "why": "nothing_dictated", "after": "paste"])
            }
            LiveTranscript.shared.end(session: take.liveSession)
            leave(take)
            island.toast(Loc.t("dictation.toast.nothing", table: "Dictation"), actionTitle: nil, action: nil)
            emit(["event": "dictation_text", "id": take.id, "ok": false, "asr_ms": r.timing["asr_ms"] ?? 0])
            return
        }
        take.result = r
        queue.markReady(take.id)
        pump()
    }

    /// Out of the line without a paste.
    private func leave(_ take: DictationTake) {
        takes[take.id] = nil
        queue.drop(take.id)
        updatePhase()
        pump()
    }

    /// The next take in line, when it is its turn: pasted.
    func pump() {
        guard !inserting, let id = queue.next() else { return updatePhase() }
        guard let take = takes[id], let r = take.result else {
            queue.drop(id)
            return pump()
        }
        updatePhase()
        deliver(take, r)
    }

    /// Esc / the menu's Cancel with no take listening: the takes still on their way go (never pasted). A paste
    /// already under way can't be taken back, but its queued Return is dropped. true: something was cancelled.
    @discardableResult
    func cancelPending() -> Bool {
        if let d = queue.delivering, let t = takes[d], t.sendAfterPaste {
            t.sendAfterPaste = false
            emit(["event": "dictation_send", "result": "cancelled", "id": d])
        }
        let ids = queue.ids.filter { $0 != queue.delivering }
        guard !ids.isEmpty else {
            if inserting { emit(["event": "dictation_cancel", "phase": "inserting", "kept": true]) }
            return false
        }
        for id in ids {
            guard let t = takes[id] else { queue.drop(id); continue }
            t.cancelled = true
            t.sendAfterPaste = false
            t.stream.cancel()
            try? FileManager.default.removeItem(at: t.wav)
            LiveTranscript.shared.end(session: t.liveSession)
            takes[id] = nil
            queue.drop(id)
            emit(["event": "dictation_cancel", "id": id, "phase": t.stage.rawValue])
        }
        updatePhase()
        pump()
        return true
    }

    // MARK: recognition failed

    /// The speech model couldn't recognise the take: its audio stays, a history row says so, the island says what
    /// failed — with Retry, or Download… when there is no model.
    private func recognitionFailed(_ take: DictationTake, _ f: DictationASRFailure) {
        if take.sendAfterPaste {
            take.sendAfterPaste = false
            emit(["event": "dictation_send", "result": "skipped", "why": "asr_failed", "after": "paste"])
        }
        LiveTranscript.shared.end(session: take.liveSession)
        let e = DictationEntry(id: take.id, time: take.started, app: take.front?.localizedName ?? take.bundle,
                               bundle: take.bundle ?? take.front?.bundleIdentifier, duration: take.duration, raw: "",
                               polished: nil, text: "", model: nil, fellBack: false, reason: "asr_failed:\(f.code)",
                               insert: "none", audio: "audio/\(take.wav.lastPathComponent)")
        DictationHistory.shared.append(e)
        DictationHistoryWindow.shared.reloadIfOpen()
        failedTakes[take.id] = take
        // only the last few stay in memory (an older one is retried from the history)
        if failedTakes.count > 5, let old = failedTakes.values.min(by: { $0.started < $1.started }) { failedTakes[old.id] = nil }
        leave(take)
        emit(["event": "dictation_text", "id": take.id, "ok": false, "asr_error": f.code])
        if f == .noModel {
            speechModels = speechModels.map { ($0.selected, false, $0.recommended, $0.recommendedInstalled) }
            return noSpeechModel()
        }
        var t = Island.Toast(text: Loc.t(f == .timedOut ? "dictation.toast.asr_slow" : "dictation.toast.asr_failed", table: "Dictation"),
                             actionTitle: Loc.t("dictation.toast.retry", table: "Dictation"), action: { [weak self] in
            self?.retry(take.id, via: "island")
        })
        t.seconds = 8
        island.toast(t)
    }

    /// No speech model on this Mac: the island says so, its button gets one.
    func noSpeechModel() {
        var t = Island.Toast(text: Loc.t("dictation.toast.no_model", table: "Dictation"),
                             actionTitle: Loc.t("dictation.toast.no_model.get", table: "Dictation"), action: {
            Dictation.getSpeechModel(from: "island")
        })
        t.seconds = 8
        island.toast(t)
    }

    /// Retry a take whose recognition failed (the island's button, the history's): the whole recording again, then
    /// pasted like any take — into the app it started in, else copied (from the history: always copied).
    func retry(_ id: String, via: String) {
        let take = failedTakes.removeValue(forKey: id) ?? historyTake(id)
        guard let take = take, FileManager.default.fileExists(atPath: take.wav.path) else {
            emit(["event": "dictation_retry", "id": id, "result": "no_audio", "via": via])
            return toast("dictation.toast.retry_gone")
        }
        take.cancelled = false
        take.stage = .transcribing
        takes[id] = take
        queue.add(id)
        updatePhase()
        emit(["event": "dictation_retry", "id": id, "via": via])
        take.stream.retry(structure: take.structure) { [weak self] r in self?.landed(take, r) }
    }

    /// A failed take from the history (after a relaunch): its audio, today's settings, no app to paste into.
    private func historyTake(_ id: String) -> DictationTake? {
        guard let e = DictationHistory.shared.load().first(where: { $0.id == id }), let a = e.audio else { return nil }
        let wav = DictationHistory.shared.resolve(a)
        var opt = DictationStream.Options()
        opt.language = Config.shared["asr.language"] as? String ?? "auto"
        opt.streaming = false
        opt.polishTimeout = Dictation.polishTimeout
        opt.structureTimeout = Dictation.structureTimeout
        opt.loadBudget = Dictation.loadBudget
        opt.vocab = DictationVocabulary.shared.payload()
        opt.polish = Dictation.polishOn && polishModel != nil
        let s = DictationStream(id: id, dir: DictationHistory.shared.audioDir, wholeWav: wav, options: opt)
        return DictationTake(id: id, front: nil, frontKey: "history", started: e.time, duration: e.duration, wav: wav,
                             context: nil, polishTried: opt.polish, keyUp: CACurrentMediaTime(), style: nil, explicit: nil,
                             toggles: 0, bundle: e.bundle, liveSession: -1, stream: s, structure: false)
    }

    // MARK: the paste

    private func deliver(_ take: DictationTake, _ r: DictationStream.Result) {
        let id = take.id, app = take.front
        // the words this dictation wrote: by polish, or (when the speech model was told the words) by the model itself
        var terms = r.terms
        if r.biased { for t in DictationVocabulary.shared.active().map(\.term) where r.text.contains(t) && !terms.contains(t) { terms.append(t) } }
        // the take's style: the structured text when Structured asked for it (the model's pass at key-up), the
        // category's variant of light (DictationStyles.swift)
        let styled = styleText(r, take: take)
        var text = styled.text
        let styleRecord = styled.record
        // the user moved to another app while the text was on its way: it is copied, never pasted there
        let appChanged = take.frontKey != currentFrontKey
        // where the text goes in, read just before pasting: the field the watch then follows for the user's fixes, and
        // the text on either side of the cursor the dictation is fitted into (DictationFit: the words that repeat the
        // field go, punctuation and spacing follow the sentence). A field whose text can't be read (WeChat) gets the
        // text as it is; nothing in the field is ever changed, only what is inserted.
        let field = !appChanged && (Dictation.learnOn || Dictation.contextOn) ? DictationField.focused() : nil
        let now = field?.read()
        let at = now?.selection.location
        var fitted: [String] = []
        if Dictation.contextOn, let f = now {
            let ns = f.text as NSString
            let loc = min(max(0, f.selection.location), ns.length)
            let len = min(max(0, f.selection.length), ns.length - loc)
            let before = String(ns.substring(to: loc).suffix(500))
            let after = String(ns.substring(from: loc + len).prefix(500))
            let fit = Dictation.fit(text, before: before, after: after, list: styleRecord.rendered)
            if fit.changes.count > 0 {
                emit(["event": "dictation_fit", "id": id, "changes": fit.changes, "from": text.count, "to": fit.text.count])
                text = fit.text
                fitted = fit.changes
            }
        }
        let pasteAt = CACurrentMediaTime()
        let bundle = take.bundle ?? app?.bundleIdentifier      // the app the take went into (tests: `dictation style app`)
        var timing = r.timing
        timing["total_ms"] = Int((pasteAt - take.keyUp) * 1000)
        // the words under the island become what is typed — polished, structured — for a moment: what a double tap
        // now sends
        if !appChanged { LiveTranscript.shared.showTyped(text, session: take.liveSession, seconds: 1.5) } else {
            LiveTranscript.shared.end(session: take.liveSession)
        }
        inserting = true
        DictationInsert.insert(text, appChanged: appChanged) { [weak self] result in
            guard let self = self else { return }
            self.queue.delivered(id)
            self.takes[id] = nil
            self.inserting = false
            var sent = false
            if take.sendAfterPaste {
                take.sendAfterPaste = false
                if result == .pasted { self.pressReturn(after: "paste"); sent = true } else {
                    // left on the clipboard (another app in front now, a password field, Blurt in front …): Return
                    // would send without it
                    emit(["event": "dictation_send", "result": "skipped", "why": appChanged ? "app_changed" : "not_pasted", "after": "paste"])
                    self.sendSkipped("not_pasted")
                }
            }
            // the Dictation Lab's "keep the audio of the next N dictations" (record.dictation.lab_keep_next): only the
            // audio, never the text around the cursor
            let labKeep = Dictation.labKeepNext > 0
            if labKeep { Dictation.set("lab_keep_next", Dictation.labKeepNext - 1) }
            let keep = Dictation.keepAudio || labKeep
            if !keep { try? FileManager.default.removeItem(at: take.wav) }
            var entry = DictationEntry(id: id, time: take.started, app: bundle == app?.bundleIdentifier ? app?.localizedName : bundle,
                                       bundle: bundle, duration: take.duration, raw: r.asrText, polished: r.polished, text: text,
                                       model: r.model, fellBack: r.fellBack, reason: r.reason,
                                       insert: result.rawValue, audio: keep ? "audio/\(take.wav.lastPathComponent)" : nil,
                                       asrModel: r.asrModel, language: r.language,
                                       termsApplied: terms, contextUsed: r.contextUsed,
                                       context: Dictation.keepAudio && r.contextUsed ? take.context?.debugText : nil,
                                       timing: timing.filter { DictationEntry.timingKeys.contains($0.key) },
                                       repaired: r.repaired.isEmpty ? nil : r.repaired, fitted: fitted.isEmpty ? nil : fitted)
            entry.style = styleRecord
            DictationHistory.shared.append(entry)
            if !terms.isEmpty { DispatchQueue.global(qos: .utility).async { DictationVocabulary.shared.recordHits(terms) } }
            if result == .pasted, let f = field, let loc = at { DictationWatch.shared.start(field: f, inserted: text, location: loc) }
            // reformat-last's material: the versions, and where the text went (only while it stays untouched)
            self.rememberPaste(id: id, app: app, bundle: bundle, r: r, record: styleRecord, typed: text, result: result,
                               field: result == .pasted ? field : nil, location: at)
            DictationHistoryWindow.shared.reloadIfOpen()
            if result == .copied {
                self.toast(appChanged ? "dictation.toast.copied_app" : "dictation.toast.copied", seconds: appChanged ? 4 : 2.4)
            } else if result == .pasted, !DictationInsert.lastPasteConfirmed {
                // pasted into a focus Accessibility couldn't confirm as text (WeChat & co.): in case it didn't land
                var t = Island.Toast(text: Loc.t("dictation.toast.pasted_unsure", table: "Dictation"),
                                     actionTitle: Loc.t("dictation.toast.copy_again", table: "Dictation"), action: {
                    DictationInsert.copy(text)
                    emit(["event": "dictation_copy_again", "id": id])
                })
                t.seconds = 4
                island.toast(t)
            }
            if result == .pasted { self.afterPaste(take, r, category: styleRecord.category, sent: sent) }
            var out: [String: Any] = ["event": "dictation_text", "id": id, "ok": true, "raw": r.raw, "text": text,
                                      "fell_back": r.fellBack, "reason": r.reason ?? NSNull(),
                                      "polished": r.polished ?? NSNull(), "model": r.model ?? NSNull(),
                                      "insert": result.rawValue, "polish_tried": take.polishTried, "asr_text": r.asrText,
                                      "terms": terms, "context_used": r.contextUsed, "asr_model": r.asrModel ?? NSNull(),
                                      "biased": r.biased, "repaired": r.repaired, "fitted": fitted,
                                      "style": styleRecord.style, "style_source": styleRecord.source,
                                      "category": styleRecord.category, "structure_reason": r.structureReason ?? NSNull(),
                                      "rendered": styleRecord.rendered, "variant": styleRecord.variant,
                                      "style_ms": styled.ms, "app_changed": appChanged]
            for (k, v) in timing { out[k] = v }
            self.lastResult = out
            emit(out)
            // ⌥⇧L pressed while this paste was under way: it meant this take
            if let via = self.reformatAfterPaste {
                self.reformatAfterPaste = nil
                self.reformatLast(via: via)
            }
            self.pump()
        }
    }

    // MARK: what the island says around a take

    /// A double tap's Return didn't go in: why, so the user doesn't think the message went.
    func sendSkipped(_ why: String?) {
        switch why {
        case "no_accessibility"?:
            var t = Island.Toast(text: Loc.t("dictation.toast.not_sent.ax", table: "Dictation"),
                                 actionTitle: Loc.t("dictation.toast.set_up", table: "Dictation"), action: {
                Dictation.shared.openSetup(from: "island")
            })
            t.seconds = 5
            island.toast(t)
        case "secure_input"?: toast("dictation.toast.not_sent.secure", seconds: 3)
        case "not_pasted"?: toast("dictation.toast.not_sent.copied", seconds: 3)
        default: toast("dictation.toast.not_sent", seconds: 2.4)
        }
    }

    /// A press this mode doesn't use: once a day, how it starts (not when the tap was a double tap's first one).
    func missedPress(_ m: DictationTrigger.Miss) {
        let at = CACurrentMediaTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + trigger.doubleTapWindow + 0.15) { [weak self] in
            guard let self = self, self.lastSendAt < at, !self.listening else { return }
            let key = m == .tappedInHoldMode ? "dictation.toast.hold_mode" : "dictation.toast.tap_mode"
            guard Dictation.onceADay("miss_\(m == .tappedInHoldMode ? "hold" : "tap")") else { return }
            emit(["event": "dictation_miss", "miss": "\(m)"])
            self.toast(key, Dictation.keyShort, seconds: 4)
        }
    }

    /// true once per day for `what` (app.dictation_notices: the day each was last said).
    static func onceADay(_ what: String) -> Bool {
        var said = Config.shared["app.dictation_notices"] as? [String: Any] ?? [:]
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let today = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        if DictationInsert.testMode, ProcessInfo.processInfo.environment["BLURT_TEST_NOTICES_ALWAYS"] == "1" {} else {
            guard said[what] as? String != today else { return false }
        }
        said[what] = today
        Config.shared.set("app.dictation_notices", said)
        return true
    }

    /// After a take went in: a model that fell back (once a day), else one of the first takes' tips.
    private func afterPaste(_ take: DictationTake, _ r: DictationStream.Result, category: String, sent: Bool) {
        var tips = Config.shared["app.dictation_tips"] as? [String: Int] ?? [:]
        tips["takes", default: 0] += 1
        Config.shared.set("app.dictation_tips", tips)
        // the polish model isn't there: the words went in as said, and the style control isn't what ran
        if Dictation.polishOn, polishModel == nil, take.style?.base.polishes ?? true, Dictation.onceADay("polish_missing") {
            emit(["event": "dictation_notice", "notice": "polish_missing"])
            return notice("dictation.toast.no_polish", action: { Dictation.getPolishModel(from: "island") })
        }
        // the recommended speech model isn't there: a weaker one ran (it may not know the user's words)
        if let m = speechModels, !m.recommendedInstalled, let used = r.asrModel, used != m.recommended,
           Dictation.onceADay("asr_fallback") {
            emit(["event": "dictation_notice", "notice": "asr_fallback", "model": used])
            return notice("dictation.toast.weaker_asr", action: { Dictation.getSpeechModel(from: "island") })
        }
        let chat = category == DictationAppCategory.chat.rawValue
        guard let tip = DictationTip.next(chat: chat, sendOn: Dictation.doubleTapSend, sent: sent || take.sendAfterPaste, shown: tips),
              tip != .reformat || !hk(.reformat).isEmpty else { return }
        // after the double-tap window (a send then makes the tip moot), never over a result toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, island.currentToast == nil, self.lastSendAt < take.keyUp, !self.listening else { return }
            var shown = Config.shared["app.dictation_tips"] as? [String: Int] ?? [:]
            shown[tip.rawValue, default: 0] += 1
            Config.shared.set("app.dictation_tips", shown)
            emit(["event": "dictation_tip", "tip": tip.rawValue])
            switch tip {
            case .send: self.toast("dictation.tip.send", Dictation.keyShort, seconds: 3)
            case .list: self.toast("dictation.tip.list", seconds: 3)
            case .reformat: self.toast("dictation.tip.reformat", hk(.reformat), seconds: 3)
            }
        }
    }

    private func notice(_ key: String, action: @escaping () -> Void) {
        var t = Island.Toast(text: Loc.t(key, table: "Dictation"),
                             actionTitle: Loc.t("dictation.toast.no_model.get", table: "Dictation"), action: action)
        t.seconds = 6
        island.toast(t)
    }

    /// The user used it themselves: its tip isn't needed any more.
    func noteUsed(_ tip: DictationTip) {
        if tip == .send { lastSendAt = CACurrentMediaTime() }
        var tips = Config.shared["app.dictation_tips"] as? [String: Int] ?? [:]
        guard (tips[tip.rawValue] ?? 0) < tip.times else { return }
        tips[tip.rawValue] = tip.times
        Config.shared.set("app.dictation_tips", tips)
    }

    // MARK: models

    /// The one way dictation gets its speech model: Settings → Speech → Dictation, the recommended model's download
    /// started there (DictationModels — Settings' own downloader).
    static func getSpeechModel(from source: String) {
        emit(["event": "dictation_get_model", "kind": "asr", "from": source])
        MainActor.assumeIsolated {
            SpeechPane.showDictationModels()
            let m = DictationModels.shared
            Task { @MainActor in
                await m.load()
                if let a = m.recommendedASR, !a.installed { m.installASR(a) }
            }
        }
    }

    /// The same for the polish model.
    static func getPolishModel(from source: String) {
        emit(["event": "dictation_get_model", "kind": "polish", "from": source])
        MainActor.assumeIsolated {
            SpeechPane.showDictationModels()
            let m = DictationModels.shared
            Task { @MainActor in
                await m.load()
                if let p = m.recommendedPolish, !p.installed { m.install(p) }
            }
        }
    }

    /// Settings reloads the model list (it opened, a download finished): what the key-down knows follows.
    func watchModelChanges() {
        MainActor.assumeIsolated {
            let sub = DictationModels.shared.$asr.compactMap { $0 }.receive(on: DispatchQueue.main).sink { [weak self] a in
                self?.setSpeechModels(["selected": a.selected, "recommended": a.recommended,
                                       "models": a.models.map { ["id": $0.id, "installed": $0.installed] as [String: Any] }])
            }
            observers.append(sub)
        }
    }

    // MARK: the history

    /// The history was cleared (Settings) or entries deleted: reformat-last and the after-typing watch forget what
    /// went; the audio of a take still listening or on its way is never deleted under it.
    func watchHistoryClear() {
        DictationHistory.liveIDs = { [weak self] in
            guard let self = self else { return [] }
            return Array(self.takes.keys) + (self.listening || self.precapturing ? [self.entryID] : [])
        }
        let o = NotificationCenter.default.addObserver(forName: DictationHistory.changed, object: nil, queue: .main) { [weak self] n in
            guard let self = self else { return }
            let gone = n.userInfo?["ids"] as? [String]       // nil: everything
            if let lp = self.lastPaste, gone?.contains(lp.id) ?? true {
                self.lastPaste = nil
                DictationWatch.shared.stop("cleared")
            }
            if let g = gone { for i in g { self.failedTakes[i] = nil } } else { self.failedTakes = [:] }
            emit(["event": "dictation_history_changed", "ids": gone ?? NSNull()])
        }
        observers.append(o)
    }
}
