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
//  • Esc (or the menu's Cancel) while a take is on its way stops it: never pasted, its Return dropped — with Undo on
//    "Cancelled" for a few seconds (an Esc meant for the app in front shouldn't cost the take), its audio kept until then;
//  • recognition failed (no model, a model that didn't answer, an error): the take keeps its audio and a history
//    row, the island says what failed and that the recording was kept, with Retry (or Download… when a model or the
//    VAD is missing — once it is there, the island offers Retry for that take). Never "nothing heard";
//  • ⌥⇧L while a take is on its way is for that take (DictationReformatAfterPaste): it runs when that take is in,
//    and goes with it when it is cancelled, fails or heard nothing;
//  • the once-a-day notices (a polish or speech model fell back), the quiet tips of the first takes, what a skipped
//    Return or a press the mode doesn't use means.
// `Dictation.getSpeechModel` / `getPolishModel` are the one way dictation asks for a model download — through the
// app's one download manager (App/ModelDownloads.swift): the speech model's starts in place (the island says so, with
// Show), the polish model's opens Settings → Speech → Dictation with its download started.
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
    /// a double tap came for it: Return once it is pasted (the island's ears say "sending" meanwhile: Dictation.sendQueued)
    var sendAfterPaste = false { didSet { if sendAfterPaste != oldValue { island.dictationChanged() } } }
    var cancelled = false
    var result: DictationStream.Result?
    /// recognition failed with this (DictationASRFailure.code): kept for Retry
    var failure: String?
    /// the mic's levels while it listened: "nothing heard" names a silent mic by them (NothingHeard)
    var levels: [Float] = []

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
    // The island's toast keys for dictation (Island.toast / BlurtCore ToastQueue: a toast with the same key replaces
    // the one showing at once; different keys queue, newest first, and an Undo or Retry pushed out comes back).
    // `Dictation.toastKey` ("dictation") is what the island says about the last take — reformat's Undo, the list chip,
    // "nothing heard", "copied": a new take drops them (Dictation.start), with the tips (`tipToastKey`) and the
    // 5-minute limit (not the once-a-day notices, `noticeToastKey`); ⇧'s style line goes when the take stops
    // listening (BlurtCore DictationToastKeys has the rule).
    // The others are kept across a new take.
    static let toastKey = DictationToastKeys.take
    /// "no speech model · Download…" and "the model is ready · Retry": the newest says what is true now.
    static let modelToastKey = DictationToastKeys.model
    /// ⇧'s style line while a take listens: a second ⇧ replaces it (and it never takes the place of the last take's
    /// Undo or "copied", which keep their own key).
    static let styleToastKey = DictationToastKeys.style
    /// "Cancelled · Undo" for takes stopped on their way: a second Esc's replaces it; a new take doesn't drop it.
    static let cancelToastKey = DictationToastKeys.cancel
    /// "Recognition failed · Retry" for one take: its own key, so two failed takes each keep their Retry.
    static func failedToastKey(_ id: String) -> String { "dictation.failed.\(id)" }
    /// Once-a-day notices with a button (passive: they wait behind replies; a new take keeps them).
    static let noticeToastKey = DictationToastKeys.notice
    /// The first takes' tips (passive): a new take drops them.
    static let tipToastKey = DictationToastKeys.tip

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
            // a result nobody takes: its audio goes too (not while "Cancelled" still offers Undo for it)
            if cancelledTakes[take.id] !== take { try? FileManager.default.removeItem(at: take.wav) }
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
            toastNothing(levels: take.levels)       // the mic it listened with, and Change Mic…
            emit(["event": "dictation_text", "id": take.id, "ok": false, "asr_ms": r.timing["asr_ms"] ?? 0])
            return
        }
        take.result = r
        queue.markReady(take.id)
        pump()
    }

    /// Out of the line without a paste (a ⌥⇧L meant for it goes too).
    private func leave(_ take: DictationTake) {
        takes[take.id] = nil
        queue.drop(take.id)
        reformatAfterPaste.forget(take.id)
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

    /// Esc / the menu's Cancel with no take listening: the takes still on their way stop (never pasted). A paste
    /// already under way can't be taken back, but its queued Return is dropped. The stopped takes keep their audio
    /// for `undoSeconds` — "Cancelled" offers Undo (an Esc meant for the app in front, a popover, vim). Returns the
    /// ids that were stopped.
    @discardableResult
    func cancelPending() -> [String] {
        if let d = queue.delivering, let t = takes[d], t.sendAfterPaste {
            t.sendAfterPaste = false
            emit(["event": "dictation_send", "result": "cancelled", "id": d])
        }
        let ids = queue.ids.filter { $0 != queue.delivering }
        guard !ids.isEmpty else {
            if inserting { emit(["event": "dictation_cancel", "phase": "inserting", "kept": true]) }
            return []
        }
        var stopped: [String] = []
        for id in ids {
            guard let t = takes[id] else { queue.drop(id); continue }
            t.cancelled = true
            t.sendAfterPaste = false
            t.stream.cancel()
            LiveTranscript.shared.end(session: t.liveSession)
            takes[id] = nil
            queue.drop(id)
            reformatAfterPaste.forget(id)
            cancelledTakes[id] = t
            stopped.append(id)
            emit(["event": "dictation_cancel", "id": id, "phase": t.stage.rawValue])
        }
        // after Undo's time: the audio goes
        DispatchQueue.main.asyncAfter(deadline: .now() + Dictation.undoSeconds + 1) { [weak self] in
            guard let self = self else { return }
            for id in stopped {
                guard let t = self.cancelledTakes.removeValue(forKey: id) else { continue }
                try? FileManager.default.removeItem(at: t.wav)
            }
        }
        updatePhase()
        pump()
        return stopped
    }

    /// How long "Cancelled" offers Undo for takes stopped on their way.
    static let undoSeconds = 5.0

    /// "Cancelled", with Undo when takes on their way were stopped (they go on as if Esc hadn't come).
    func toastCancelled(_ stopped: [String]) {
        guard !stopped.isEmpty else { return toast("dictation.toast.cancelled", key: Dictation.cancelToastKey, seconds: 1.2) }
        island.toast(Loc.t("dictation.toast.cancelled", table: "Dictation"), key: Dictation.cancelToastKey,
                     seconds: Dictation.undoSeconds,
                     actionTitle: Loc.t("dictation.toast.undo", table: "Dictation"), action: { [weak self] in
            guard let self = self else { return }
            for id in stopped where self.cancelledTakes[id] != nil { self.retry(id, via: "undo_cancel") }
        })
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
        let e = DictationEntry(id: take.id, time: take.started, app: AppNames.name(for: take.bundle ?? take.front?.bundleIdentifier, running: take.front),
                               bundle: take.bundle ?? take.front?.bundleIdentifier, duration: take.duration, raw: "",
                               polished: nil, text: "", model: nil, fellBack: false, reason: "asr_failed:\(f.code)",
                               insert: "none", audio: "audio/\(take.wav.lastPathComponent)")
        DictationHistory.shared.append(e)
        DictationHistoryWindow.shared.reloadIfOpen()
        take.failure = f.code
        failedTakes[take.id] = take
        // only the last few stay in memory (an older one is retried from the history)
        if failedTakes.count > 5, let old = failedTakes.values.min(by: { $0.started < $1.started }) { failedTakes[old.id] = nil }
        leave(take)
        emit(["event": "dictation_text", "id": take.id, "ok": false, "asr_error": f.code])
        guard f == .noModel else { return toastFailed(take.id, f) }
        // what is missing, asked again (never assumed): the key-down then refuses only while it really is missing
        refreshSpeechModels { [weak self] in
            guard let self = self else { return }
            if let m = self.speechModels, m.ready {
                // there now (a download finished meanwhile, a race): just Retry
                return self.toastFailed(take.id, .failed("model_missing"))
            }
            self.noSpeechModel(kept: true)
        }
    }

    /// "Recognition failed · recording kept" (or "too slow"), with Retry.
    private func toastFailed(_ id: String, _ f: DictationASRFailure) {
        island.toast(Loc.t(f == .timedOut ? "dictation.toast.asr_slow" : "dictation.toast.asr_failed", table: "Dictation"),
                     key: Dictation.failedToastKey(id), seconds: 8,
                     actionTitle: Loc.t("dictation.toast.retry", table: "Dictation"), action: { [weak self] in
            self?.retry(id, via: "island")
        })
    }

    /// No speech model on this Mac (or no VAD — the small file every take goes through): the island says which, and
    /// its button gets it through the app's one download manager (`getSpeechModel`); while that download runs, how far
    /// it is, with Show. `kept`: a take failed for it, and its recording was kept (Retry comes once it is in:
    /// modelArrived). The list not read (or unreadable): no size to offer — the models' page instead.
    func noSpeechModel(kept: Bool = false) {
        emit(["event": "dictation_no_model", "missing": speechModels?.missing ?? [], "kept": kept])
        MainActor.assumeIsolated {
            let dl = ModelDownloads.shared
            // one at a time (Dictation.modelToastKey): the newest says what is true now, and the model arriving replaces it
            guard let j = DictationModels.shared.dictationJob else {
                return island.toast(Loc.t("dictation.toast.no_model_plain", table: "Dictation"), key: Dictation.modelToastKey,
                                    seconds: 6, actionTitle: Loc.t("dictation.toast.no_model.settings", table: "Dictation")) {
                    SpeechPane.showDictationModels()
                }
            }
            if dl.queue.contains(j.id) {
                let p = dl.progress(j.id) ?? (0, j.sizeMB)
                return island.toast(Loc.t("dictation.toast.model_downloading", table: "Dictation", modelSize(p.done),
                                          modelSize(max(p.total, j.sizeMB))), key: Dictation.modelToastKey, seconds: 6,
                                    actionTitle: Loc.t("dictation.toast.model_downloading.action", table: "Dictation")) {
                    ModelDownloads.showProgress()
                }
            }
            let vad = self.speechModels?.onlyVADMissing ?? (j.sizeMB == DictationModels.vadMB)
            let text = kept ? Loc.t(vad ? "dictation.toast.no_vad.kept" : "dictation.toast.no_model.kept", table: "Dictation")
                : vad ? Loc.t("dictation.toast.no_vad", table: "Dictation")
                : Loc.t("dictation.toast.no_model", table: "Dictation", modelSize(j.sizeMB))
            island.toast(text, key: Dictation.modelToastKey, seconds: 8,
                         actionTitle: Loc.t("dictation.toast.no_model.action", table: "Dictation")) {
                Dictation.getSpeechModel(from: "island")
            }
        }
    }

    /// The speech model (or the VAD) is there now: the newest take that failed for lack of it gets Retry on the
    /// island — not pasted by itself minutes later into whatever has the focus.
    func modelArrived() {
        let waiting = failedTakes.values.filter { $0.failure == DictationASRFailure.noModel.code }
        guard let take = waiting.max(by: { $0.started < $1.started }) else {
            return island.dropToasts(key: Dictation.modelToastKey)      // "Download…" is moot now
        }
        emit(["event": "dictation_model_arrived", "retry": take.id])
        // in place of a "no model · Download…" still showing or waiting
        island.toast(Loc.t("dictation.toast.model_ready", table: "Dictation"), key: Dictation.modelToastKey, seconds: 8,
                     actionTitle: Loc.t("dictation.toast.retry", table: "Dictation"), action: { [weak self] in
            self?.retry(take.id, via: "model_ready")
        })
    }

    /// Retry a take whose recognition failed (the island's button, the history's): the whole recording again, then
    /// pasted like any take — into the app it started in, else copied (from the history: always copied).
    func retry(_ id: String, via: String) {
        let take = failedTakes.removeValue(forKey: id) ?? cancelledTakes.removeValue(forKey: id) ?? historyTake(id)
        island.dropToasts(key: Dictation.failedToastKey(id))      // its Retry is being done
        guard let take = take, FileManager.default.fileExists(atPath: take.wav.path) else {
            emit(["event": "dictation_retry", "id": id, "result": "no_audio", "via": via])
            return toast("dictation.toast.retry_gone", key: Dictation.failedToastKey(id))
        }
        take.cancelled = false
        take.failure = nil
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
            var sent = false, sendWanted = false
            if take.sendAfterPaste {
                take.sendAfterPaste = false
                if result == .pasted { self.pressReturn(after: "paste"); sent = true } else {
                    // left on the clipboard (another app in front now, a password field, Blurt in front …): Return
                    // would send without it — said with "copied" below, in one line
                    emit(["event": "dictation_send", "result": "skipped", "why": appChanged ? "app_changed" : "not_pasted", "after": "paste"])
                    sendWanted = true
                    if result != .copied { self.sendSkipped("not_pasted") }
                }
            }
            // the Dictation Lab's "keep the audio of the next N dictations" (record.dictation.lab_keep_next): only the
            // audio, never the text around the cursor
            let labKeep = Dictation.labKeepNext > 0
            if labKeep { Dictation.set("lab_keep_next", Dictation.labKeepNext - 1) }
            let keep = Dictation.keepAudio || labKeep
            if !keep { try? FileManager.default.removeItem(at: take.wav) }
            var entry = DictationEntry(id: id, time: take.started, app: AppNames.name(for: bundle, running: app),
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
            // copied (and, after a double tap, not sent): one line that says both — "Not sent" used to be replaced in the
            // same frame by "Copied — paste with ⌘V" (same key), so the user never learned the message didn't go
            if let k = DictationCopyToast.key(copied: result == .copied, appChanged: appChanged, sendWanted: sendWanted) {
                self.toast(k, key: Dictation.toastKey, seconds: appChanged || sendWanted ? 4 : 2.4,
                           icon: DictationCopyToast.checked(k) ? .check : nil)
            } else if result == .pasted, !DictationInsert.lastPasteConfirmed {
                // pasted into a focus Accessibility couldn't confirm as text (WeChat & co.): in case it didn't land
                island.toast(Loc.t("dictation.toast.pasted_unsure", table: "Dictation"), key: Dictation.toastKey,
                             actionTitle: Loc.t("dictation.toast.copy_again", table: "Dictation"), action: {
                    DictationInsert.copy(text)
                    emit(["event": "dictation_copy_again", "id": id])
                })
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
            // ⌥⇧L pressed while this take was on its way: it meant this take (never a later one)
            if let via = self.reformatAfterPaste.delivered(id) { self.reformatLast(via: via) }
            self.pump()
        }
    }

    // MARK: what the island says around a take

    /// A double tap's Return didn't go in: why, so the user doesn't think the message went.
    func sendSkipped(_ why: String?) {
        switch why {
        case "no_accessibility"?:
            island.toast(Loc.t("dictation.toast.not_sent.ax", table: "Dictation"), key: Dictation.toastKey,
                         actionTitle: Loc.t("dictation.toast.set_up", table: "Dictation"), action: {
                Dictation.shared.openSetup(from: "island")
            })
        case "secure_input"?: toast("dictation.toast.not_sent.secure", key: Dictation.toastKey, seconds: 3)
        case "not_pasted"?: toast("dictation.toast.not_sent.copied", key: Dictation.toastKey, seconds: 3)
        default: toast("dictation.toast.not_sent", key: Dictation.toastKey, seconds: 2.4)
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
            self.toast(key, Dictation.keyShort, key: "dictation.miss", seconds: 4)
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
            return notice("dictation.toast.no_polish", button: "dictation.toast.no_model.get", action: { Dictation.getPolishModel(from: "island") })
        }
        // the recommended speech model isn't there: a weaker one ran (it may not know the user's words)
        // (not when the model that ran is the one the user chose)
        if let m = speechModels, m.weakerModelRan(r.asrModel), let used = r.asrModel, Dictation.onceADay("asr_fallback") {
            emit(["event": "dictation_notice", "notice": "asr_fallback", "model": used])
            return notice("dictation.toast.weaker_asr", button: "dictation.toast.no_model.action", action: { Dictation.getSpeechModel(from: "island") })
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
            case .send: self.toast("dictation.tip.send", Dictation.keyShort, key: Dictation.tipToastKey, seconds: 3, passive: true)
            case .list: self.toast("dictation.tip.list", key: Dictation.tipToastKey, seconds: 3, passive: true)
            case .reformat: self.toast("dictation.tip.reformat", hk(.reformat), key: Dictation.tipToastKey, seconds: 3, passive: true)
            }
        }
    }

    /// `button`: "Download…" when it opens Settings, "Download" when the download just starts (the speech model).
    private func notice(_ key: String, button: String, action: @escaping () -> Void) {
        // not a reply to what the user just did: it waits behind any reply (ToastQueue's passive lines)
        var t = Island.Toast(text: Loc.t(key, table: "Dictation"),
                             actionTitle: Loc.t(button, table: "Dictation"), action: action)
        t.seconds = 6
        t.key = Dictation.noticeToastKey
        t.passive = true
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

    /// The one way dictation gets its speech model (the island's Download, the welcome line, the Dictation page's
    /// failed take, the weaker-model notice): one job in the app's one download manager (ModelDownloads) for what is
    /// missing (DictationModels.dictationJob ← DictationSpeechModels.toGet): the configured model when that one is
    /// missing, else the recommended one; only the VAD → the selected model's setup, which brings just that (0.6 MB),
    /// without changing the choice. The island then says it started, with Show; once it is in, the key works and a
    /// take that failed for it is offered again (modelArrived). Nothing known to get: the models' page.
    static func getSpeechModel(from source: String) {
        MainActor.assumeIsolated {
            let m = DictationModels.shared
            Task { @MainActor in
                if m.asr == nil { await m.load() }
                guard let j = m.dictationJob else {
                    emit(["event": "dictation_get_model", "kind": "asr", "from": source, "model": NSNull()])
                    return SpeechPane.showDictationModels()
                }
                emit(["event": "dictation_get_model", "kind": "asr", "from": source, "model": j.id, "size_mb": j.sizeMB,
                      "choose": j.select])
                ModelDownloads.shared.download([j], via: "dictation")
                island.toast(Loc.t("dictation.toast.model_started", table: "Dictation", modelSize(j.sizeMB), Dictation.keyShort),
                             key: Dictation.modelToastKey, seconds: 5,
                             actionTitle: Loc.t("dictation.toast.model_downloading.action", table: "Dictation")) {
                    ModelDownloads.showProgress()
                }
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
                self?.setSpeechModels(a.dictionary)
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
            return Array(self.takes.keys) + Array(self.cancelledTakes.keys) + (self.listening || self.precapturing ? [self.entryID] : [])
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
