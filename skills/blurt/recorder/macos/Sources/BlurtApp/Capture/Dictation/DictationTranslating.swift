// Translate mode in the app (docs/design/dictation-translate.md; the rules are BlurtCore's DictationTranslate):
//
//  • at the key-down the app in front says whether the take starts translated (Settings' list of apps; none by
//    default); while talking ⌘ alone, or a click on the island's left half, turns it on or off (the trigger's
//    `.translate`). The right ear shows the translate glyph after the style's while it is on; the first two times it
//    is turned on, a line says into what. Nothing can translate (no cloud model set up, no local polish model): the
//    line says what is needed, with Settings, and it stays off;
//  • at key-up, after Structured's pass: one `translate` request to the polish server (the prompt ⌥T uses) over the
//    text in its style, into the other language of the one the speech model heard (or Settings' fixed target), with
//    the user's words; the cloud model when it is set up and Settings lets it, the local one as its fall-back.
//    polish.py's guard refuses what is plainly no translation; a refusal or a failure types the take as said, and the
//    island says so;
//  • the history keeps what was said (`translate.said`) beside what was typed.
// Test hooks: `dictation translate …` (DictationTestHooks.swift).
import AppKit
import BlurtCore

extension Dictation {
    /// This take's translation while it listens: on, how it was turned on, how often it was switched.
    struct TranslateState {
        var on = false
        /// app (the app is in the list) | command (⌘) | island
        var source = "app"
        var toggles = 0
    }

    static var translateConfig: DictationTranslateConfig { DictationTranslateConfig(json: settings["translate"] as? [String: Any]) }
    static func setTranslateConfig(_ c: DictationTranslateConfig) { set("translate", c.json) }

    /// The cloud model for translation: the one set up for cloud polish, with its key — whether cloud polish itself is
    /// on or not (as ⌥T's), when Settings lets the cloud translate. nil: the local model.
    static var translateCloud: [String: Any]? {
        guard translateConfig.cloud else { return nil }
        return ScreenTextRefine.cloudPayload
    }

    /// What would translate a take now.
    var translateEngine: DictationTranslateRoute.Engine {
        DictationTranslateRoute.engine(cloudReady: ScreenTextRefine.cloudPayload != nil, useCloud: Dictation.translateConfig.cloud,
                                       localModel: polishModel != nil)
    }

    /// While listening: the take will be translated (the island's ear shows it).
    var listeningTranslate: Bool { phase == .listening && translating.on }

    /// A take begins: translated from the start in the apps the user listed.
    func beginTranslate(bundle: String?) {
        let on = Dictation.translateConfig.startsOn(bundle: bundle) && translateEngine != .none
        translating = TranslateState(on: on, source: "app", toggles: 0)
        if on { warmTranslator() }
    }

    /// ⌘ alone / the island's left half while listening: this take translated, or not.
    func toggleTranslate(via: String) {
        guard phase == .listening else { return }
        let engine = translateEngine
        if !translating.on, engine == .none {
            // nothing on this Mac can translate: say what it takes, with the way there — and stay as said
            emit(["event": "dictation_translate", "action": "unavailable", "via": via, "id": entryID])
            var t = Island.Toast(text: Loc.t("dictation.translate.toast.unavailable", table: "Dictation"),
                                 actionTitle: Loc.t("dictation.translate.toast.setup", table: "Dictation"), action: {
                AppEnvironment.settings?.show(pane: "speech/speech.cloud_polish")
            })
            t.key = Dictation.styleToastKey
            t.seconds = 6
            island.toast(t)
            return
        }
        translating.on.toggle()
        translating.toggles += 1
        if translating.on { translating.source = via }
        island.refresh()
        emit(["event": "dictation_translate", "action": "toggle", "via": via, "on": translating.on, "engine": engine.rawValue,
              "id": entryID])
        if translating.on { warmTranslator() }
        // the ear's glyph says it is on; the line explains it the first couple of times only (as Structured's)
        let shown = Dictation.settings["translate_hint_shown"] as? Int ?? 0
        guard DictationTranslateHint.says(shown: shown) else { return }
        if translating.on { Dictation.set("translate_hint_shown", shown + 1) }
        let target = Dictation.translateConfig.target
        if !translating.on { toast("dictation.translate.toast.off", key: Dictation.styleToastKey, seconds: 3) }
        else if target == .auto { toast("dictation.translate.toast.on.auto", key: Dictation.styleToastKey, seconds: 3) }
        else { toast("dictation.translate.toast.on.into", Dictation.languageName(target), key: Dictation.styleToastKey, seconds: 3) }
    }

    /// A target language in the app's own language ("日语", "Japanese").
    static func languageName(_ t: DictationTranslateTarget) -> String {
        Loc.locale.localizedString(forIdentifier: t.rawValue) ?? t.endonym
    }

    /// The user's own language: what a take already in the target language is translated into (the system's first).
    static var homeLanguage: String { DictationTranslateRoute.home(Locale.preferredLanguages) }

    /// The polish server up for the key-up's translation: with the local model loaded when that is what translates;
    /// without a local model it serves the cloud alone (polish.py never downloads one).
    func warmTranslator() {
        guard !WarmServer.running("polish-serve"), polishServer?.isRunning != true else { return }
        if polishModel != nil { warmPolish(); return }
        guard Dictation.translateCloud != nil else { return }
        polishServer = WarmSpawn.start("polish.py", ["serve"], server: "polish-serve")
    }

    /// What the stream needs at key-up to translate this take (nil: it isn't translated).
    func translateJob(style: DictationStyle) -> DictationStream.TranslateJob? {
        guard translating.on else { return nil }
        let engine = translateEngine
        guard engine != .none else { return nil }
        return DictationStream.TranslateJob(setting: Dictation.translateConfig.target, style: style,
                                            cloud: engine == .cloud ? Dictation.translateCloud : nil, engine: engine,
                                            source: translating.source, toggles: translating.toggles)
    }

    /// polish.py `translate` for a dictation (its words, its guard): the warm server, else the CLI (the key on stdin).
    /// Blocking: off the main thread. nil: no answer at all.
    static func translate(_ text: String, target: String, vocab: [[String: Any]], cloud: [String: Any]?,
                          loadBudget: Double) -> [String: Any]? {
        var req: [String: Any] = ["text": text, "target": target, "vocab": vocab, "spoken": true, "check": true]
        if let c = cloud { req["cloud"] = c }
        let limit = (cloud == nil ? 0 : DictationCloud.requestBudget(chars: text.count) * 2) + structureTimeout
        let until = Date().addingTimeInterval(min(loadBudget, 3))
        while !WarmServer.running("polish-serve") && Date() < until { usleep(50_000) }
        if WarmServer.running("polish-serve"), let r = WarmServer.call("polish-serve", req.merging(["cmd": "translate"]) { $1 },
                                                                         timeout: limit + loadBudget + 1) {
            return r
        }
        // no server (yet): the CLI loads what it needs itself
        guard let body = try? JSONSerialization.data(withJSONObject: req) else { return nil }
        var r: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        Task {
            r = try? await ScriptRunner.shared.json("polish.py", ["translate", "--stdin", "--no-server"], stdin: body,
                                                    timeout: limit + 30)
            sem.signal()
        }
        sem.wait()
        return r
    }

    // MARK: after the paste

    /// The take was translated by the local model while no cloud is set up: once ever, the island says the cloud does
    /// it better. The take went in as said (a refusal, a failure): said, every time.
    func afterTranslate(_ rec: DictationTranslateRecord) {
        if rec.fellBack {
            toast("dictation.translate.toast.failed", key: Dictation.toastKey, seconds: 4)
            emit(["event": "dictation_translate", "action": "fell_back", "reason": rec.reason ?? ""])
            return
        }
        let said = Dictation.settings["translate_cloud_hint"] as? Bool ?? false
        let engine = DictationTranslateRoute.Engine(rawValue: rec.engine) ?? .none
        guard DictationTranslateRoute.suggestsCloud(engine: engine, cloudReady: ScreenTextRefine.cloudPayload != nil,
                                                    useCloud: Dictation.translateConfig.cloud, alreadySaid: said) else { return }
        Dictation.set("translate_cloud_hint", true)
        var t = Island.Toast(text: Loc.t("dictation.translate.toast.cloud_hint", table: "Dictation"),
                             actionTitle: Loc.t("dictation.translate.toast.setup", table: "Dictation"), action: {
            AppEnvironment.settings?.show(pane: "speech/speech.cloud_polish")
        })
        t.key = Dictation.noticeToastKey
        t.passive = true
        t.seconds = 8
        island.toast(t)
    }

    /// An app the user keeps translating by hand: asked once whether to translate there from now on.
    func checkTranslateSuggestion(bundle: String?) {
        guard let b = bundle else { return }
        var cfg = Dictation.translateConfig
        guard DictationTranslateLearn.suggest(entries: DictationHistory.shared.load(), bundle: b, config: cfg) else { return }
        cfg.asked.insert(b)
        Dictation.setTranslateConfig(cfg)
        let name = AppNames.name(for: b, running: nil) ?? b
        emit(["event": "dictation_translate", "action": "suggest", "bundle": b])
        var t = Island.Toast(text: Loc.t("dictation.translate.toast.suggest", table: "Dictation", name),
                             actionTitle: Loc.t("dictation.translate.toast.suggest.yes", table: "Dictation"), action: {
            var c = Dictation.translateConfig
            c.apps.insert(b)
            Dictation.setTranslateConfig(c)
            emit(["event": "dictation_translate", "action": "suggest_accepted", "bundle": b])
        })
        t.key = Dictation.noticeToastKey
        t.seconds = 10
        island.toast(t)
    }
}
