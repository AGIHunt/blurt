// Captures outside a recording (docs/design/next-round.md K7): ⌥⇧A stills, ⌥⇧V voice notes, and (optionally) the
// system's own screenshots. Each one is a line in the current store's open shots batch, <store>/sessions/<ts>-shots/.
//
// v0.7 token diet — an agent runs only when the user asks for one, once per batch:
//  • a current project is set and the capture has a note (typed, or spoken and transcribed here) → it is filed
//    straight away by captures.py, no agent, no tokens: it flies up, a thread reels it into the island, and the island
//    says where it went ("Filed to ordo-platform · OP-14 · Change" — Change picks another project: Refile.swift). The
//    item carries `enrich: pending` for a later AI fill-in.
//  • v0.9: with a project, a capture without a note is filed there too ("Screenshot 14:32") — the island said "Goes to
//    <project>" and the guide promises every capture goes straight in. Only a spoken note whose words couldn't be had
//    hangs as a card, remembering its project ("intended_project"): Retry files it there (BlurtCore CaptureRoute).
//  • no current project (the user picked none; Blurt never guesses one) → it hangs from the island on a thread, as a
//    card, until the user drags it — or its ⌘-click selection — onto a project in the island (filed there the same
//    way, no agent), onto "Unassigned", picks Move To ▸ in its menu, or has the cards organized: "Organize" (into the
//    current project when there is one; otherwise into Unassigned, the run suggesting a project per item that the
//    user accepts with a click) — one agent run per batch with the cards' processing model (the cheapest).
//  • Esc in the note bubble clears what was typed first, then discards the capture (Trash, with Undo for 5 s, as a voice
//    note's); ⏎ keeps it without a note.
//  • Screen Recording missing → the snap doesn't open the picker: the island says so, Open Settings starts the guide.
//    macOS says it is on but ScreenCaptureKit refuses (an older build's grant) → "re-allow Screen Recording", the guide
//    in its re-add form (BlurtCore ScreenGrant). A recording asks the same way (ScreenHelp; no alert).
//  • quitting (App.applicationShouldTerminate → prepareForQuit) saves the open note, finishes a voice note, waits a
//    moment for words and filings, and flushes shots.jsonl; what still waits is picked up at the next launch (restore).
//  • Delete / Delete All on cards: no question, "Deleted · Undo" for 5 s; the files stay until then (CardDelete).
// Agent runs go through AppEnvironment.process(session, captures, project) — AgentHub's process jobs (K4).

import AppKit
import BlurtCore
import Carbon.HIToolbox

/// One spelling for a folder however it was reached (/tmp vs /private/tmp, symlinks): realpath when it exists.
func canonicalPath(_ u: URL) -> String {
    guard let r = realpath(u.path, nil) else { return u.standardizedFileURL.path }
    defer { free(r) }
    return String(cString: r)
}

/// A snap batch: a -shots folder, or snaps with no video — unless meta.json says it's a recording whose video was
/// deleted (VideoRetention.stamp).
func isShotsSession(_ dir: URL) -> Bool {
    dir.lastPathComponent.hasSuffix("-shots") || FileManager.default.fileExists(atPath: dir.appendingPathComponent("shots.jsonl").path)
        && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("recording.mp4").path) && !VideoRetention.isRecording(dir)
}

/// The prompt for an unattended run on a shots session (nil for recordings: App.process keeps its own).
func shotsPrompt(_ dir: URL) -> String? {
    guard isShotsSession(dir) else { return nil }
    return Loc.t("capture.prompt.shots", table: "Capture", dir.path)
}

final class Snapper {
    var prevApp: NSRunningApplication?
    var app: App? { NSApp.delegate as? App }
    private var open: [String: ShotBatch] = [:]          // project id → its store's collecting -shots batch
    private(set) var cardBatches: [ShotBatch] = []       // batches with cards still hanging
    private var collectTimer: Timer?
    private var collectSeen = Set<String>()

    /// Every card, oldest first.
    var cards: [Shot] { cardBatches.flatMap { $0.live.filter(\.isCard) }.sorted { ($0.wall, $0.n) < ($1.wall, $1.n) } }

    // MARK: entry points

    /// ⌥⇧A when not recording. While a note is open: save it, then take the next shot.
    func hotkey() {
        guard let app = app, app.resident, app.rec == nil else { return }
        if app.picker != nil { return }
        if NoteBubble.shared.isOpen { NoteBubble.shared.commit() }
        guard !app.busy else { return }
        pick()
    }

    func rememberFrontApp() {
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != getpid() { prevApp = f }
    }

    func restoreFocus() {
        if let p = prevApp, !p.isTerminated { p.activate() }
    }

    func pick(preselect: CGRect? = nil) {
        guard let app = app else { return }
        // no Screen Recording: say so before an area is dragged for nothing
        guard Snapper.screenAllowed else {
            emit(["event": "snap_failed", "screen_recording": false, "stage": "picker"])
            return ScreenHelp.show(.snap, grant: .missing)
        }
        rememberFrontApp()
        app.busy = true
        let p = PickerController()
        p.snapMode = true
        p.onDone = { [weak self, weak app] r in
            unregisterHotkey(.pickEnter); unregisterHotkey(.pickEsc); unregisterHotkey(.pickFull); unregisterHotkey(.pickLast)
            app?.picker = nil
            app?.busy = false
            guard let r = r else { self?.restoreFocus(); return }
            setRecordConfig("last_snap_region", [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)])
            self?.capture(r)
        }
        app.picker = p
        registerHotkey(.pickEnter, key: kVK_Return, mods: 0)
        registerHotkey(.pickEsc, key: kVK_Escape, mods: 0)
        registerHotkey(.pickFull, key: kVK_ANSI_F, mods: 0)
        if let r = recordConfig()["last_snap_region"] as? [Double], r.count == 4 {
            opts.lastRegion = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        } else {
            opts.lastRegion = lastRegionFromConfig()
        }
        // L = the last area, like F and ⏎ — only when there is one (the hint says it only then too)
        if opts.lastRegion != nil { registerHotkey(.pickLast, key: kVK_ANSI_L, mods: 0) }
        p.show(preselect: preselect)
    }

    /// Screen Recording as a snap sees it: allowed, or a test still stands in for the screen.
    static var screenAllowed: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["BLURT_TEST_COMMANDS"] == "1", let still = env["BLURT_TEST_STILL"], still != "none" { return true }
        return SystemAccess.granted(.screen)
    }

    // MARK: batches

    /// Where a capture goes now: the current project, or the inbox (as a card) when the user picked none.
    var target: Project { ProjectStore.shared.current ?? ProjectStore.shared.inbox }

    /// The store's open shots batch: the newest `-shots` session still collecting and under 12 h old, else a new one.
    func openBatch(for p: Project) -> ShotBatch {
        let key = p.id
        if let b = open[key] { return b }
        let root = p.store.appendingPathComponent("sessions")
        let recent = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("-shots") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        if let d = recent.first, let b = cardBatches.first(where: { canonicalPath($0.dir) == canonicalPath(d) }) ?? ShotBatch.load(d),
           (b.meta["state"] as? String ?? "collecting") == "collecting", b.meta["source"] == nil,
           Date().timeIntervalSince1970 - (b.shots.first?.wall ?? Date().timeIntervalSince1970) < 12 * 3600 {
            return adopt(b, key: key, project: p)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = root.appendingPathComponent(f.string(from: Date()) + "-shots")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("shots"), withIntermediateDirectories: true)
        let b = ShotBatch(dir: dir, inRecording: false)
        b.writeMeta(project: .some(p.isInbox ? nil : p.id))
        return adopt(b, key: key, project: p)
    }

    private func adopt(_ b: ShotBatch, key: String, project p: Project) -> ShotBatch {
        open[key] = b
        if !cardBatches.contains(where: { $0 === b }) { cardBatches.append(b) }      // any capture may become a card
        b.onChange = { hanging.refresh() }
        return b
    }

    // MARK: stills

    /// `region`: global top-left points. Also used directly by tests (`snapregion x,y,w,h`).
    func capture(_ region: CGRect, withNote: Bool = true) {
        let ns = toNS(region)
        captureStill(rect: region, showsCursor: false) { [weak self] img, scale in
            guard let self = self else { return }
            guard let img = img else {
                self.snapFailed()
                self.restoreFocus()
                return
            }
            shutterFlash(ns)
            self.playShutter()
            let p = self.target
            let b = self.openBatch(for: p)
            let n = b.reserve()
            let shot = b.add(n: n, image: img, scale: scale, region: region, t: nil, project: p.isInbox ? nil : p.id)
            emit(["event": "snap", "n": n, "file": shot.file ?? "", "session": b.dir.path, "project": shot.project ?? NSNull()])
            hanging.catchCapture(shot, from: ns)
            if withNote { NoteBubble.shared.begin(shot, mode: .listen) } else { self.settled(shot); self.restoreFocus() }
        }
    }

    /// No picture came back. Without Screen Recording access that is why: "Open Settings" starts the permission guide.
    /// With access, ScreenCaptureKit is asked once more: refused = a stale grant (an older build's: "re-allow Screen
    /// Recording", the guide's re-add form) — else a passing failure, "try again" (BlurtCore ScreenGrant).
    private func snapFailed() {
        let allowed = SystemAccess.granted(.screen)
        guard allowed else {
            emit(["event": "snap_failed", "screen_recording": false])
            return ScreenHelp.show(.snap, grant: .missing)
        }
        ScreenHelp.probe { ok in
            let grant = ScreenGrant.diagnose(preflight: true, probe: ok)
            emit(["event": "snap_failed", "screen_recording": true, "probe": ok, "grant": grant.rawValue])
            ScreenHelp.show(.snap, grant: grant)
        }
    }

    func playShutter() {
        guard recordConfig()["snap_sound"] as? Bool ?? true else { return }
        let p = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if FileManager.default.fileExists(atPath: p) { NSSound(contentsOfFile: p, byReference: true)?.play() }
    }

    // MARK: voice notes

    /// A finished voice note (VoiceInput.swift): its wav is at shots/NNN.wav of `batch`. The words are its note:
    /// with a project it is filed once they are transcribed; without words (or a project) it hangs as a card.
    /// `stream`: the pieces transcribed while it was said — its last piece is all that is left (else the whole wav).
    func voiceFinished(batch b: ShotBatch, n: Int, duration: Double, project: String?, stream: VoiceNoteStream? = nil) {
        let s = b.addVoice(n: n, duration: duration, project: project)
        if let st = stream { streamed[ObjectIdentifier(s)] = st }
        emit(["event": "voice", "n": n, "session": b.dir.path, "duration": duration, "project": project ?? NSNull(),
              "streamed": stream != nil])
        if project == nil {
            hanging.catchCapture(s, from: island.frameOnScreen)
            transcribe(s) { _ in }
        } else {
            transcribe(s) { [weak self] _ in self?.settled(s) }
        }
    }

    /// K9's fast path (`transcribe.py note`) → `said`. Every kept voice wav goes through here (v0.8: a shot with typed
    /// text and a spoken note used to skip it — the card showed a mic and no words): words → `said`; no speech in it
    /// (a cough, the room, a note abandoned for typing) → the voice note is dropped (wav and mark), nothing more to
    /// do; failed → "Couldn't transcribe" on the card, Retry in its menu (an agent handed the cards transcribes too).
    /// One run per capture at a time: a second caller waits for the first.
    private func transcribe(_ s: Shot, then: @escaping (String?) -> Void) {
        guard s.voice != nil, s.said == nil, let wav = s.voiceURL else { return then(s.said) }
        guard FileManager.default.fileExists(atPath: wav.path) else {
            // the wav is gone (trashed by hand, a half-written note): nothing to transcribe, nothing to show
            if s.kind == .shot { dropVoice(s, reason: "missing") } else { s.transcription = .failed; hanging.update(s) }
            return then(nil)
        }
        let key = ObjectIdentifier(s)
        if pendingWords[key] != nil { pendingWords[key]?.append(then); return }
        pendingWords[key] = [then]
        let take = wordsTake[key] ?? 0
        s.transcription = .pending
        hanging.update(s)
        if let st = streamed.removeValue(forKey: key) {
            // a voice note transcribed while it was said: only its last piece is left
            let t0 = CACurrentMediaTime()
            st.finish { [weak self] text in
                let t = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                emit(["event": "voice_stream_done", "n": s.n, "ok": text != nil, "chars": t?.count ?? 0,
                      "ms": Int((CACurrentMediaTime() - t0) * 1000)])
                guard let self = self else { return }
                if let t = t, !t.isEmpty { self.wordsArrived(s, t, key: key, take: take, via: "stream") }
                else { self.transcribeWhole(s, wav, key: key, take: take) }
            }
            return
        }
        transcribeWhole(s, wav, key: key, take: take)
    }

    /// The whole wav → its words: the warm speech server when it runs or is starting (the snap's note bubble and ⌥⇧V
    /// start it as they begin listening: VoiceInput.warmSpeechModel), else `transcribe.py note` (a cold model load).
    private func transcribeWhole(_ s: Shot, _ wav: URL, key: ObjectIdentifier, take: Int) {
        let fail = Snapper.testFailWords()
        DispatchQueue.global(qos: .userInitiated).async {
            if let d = Snapper.testWordsDelay { Thread.sleep(forTimeInterval: d) }
            let r = fail ? nil : VoiceInput.transcribePiece(wav, prior: "")
            let text = (r?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self.wordsArrived(s, text, key: key, take: take, via: "whole") }
        }
    }

    /// The words of `s` are in (nil: transcription failed; "": no speech in it). `take`: which recording they are of
    /// (the words of a take since replaced by a re-record are dropped: voiceReplaced).
    private func wordsArrived(_ s: Shot, _ text: String?, key: ObjectIdentifier, take: Int, via: String) {
        guard take == wordsTake[key] ?? 0 else {
            return emit(["event": "voice_text_stale", "n": s.n, "via": via])
        }
        emit(["event": "voice_text", "n": s.n, "ok": text != nil, "empty": text?.isEmpty ?? false, "via": via,
              "wall": Date().timeIntervalSince1970])
        let quiet = quietWords.remove(key) != nil
        if !s.deleted {
            if let t = text, !t.isEmpty {
                s.said = t
                s.transcription = .idle
                s.batch?.save(s)
            } else if text != nil {
                s.transcription = .idle
                if s.kind == .shot { dropVoice(s, reason: "no_speech") } else {
                    // a voice note the speech model found no words in: kept as audio, "No words recognized · Retry"
                    s.said = ""
                    s.batch?.save(s)
                    if !quiet { wordsToast(s, "capture.voice.no_words") }
                }
            } else {
                s.transcription = .failed
                // the cards may be tucked away: the island says it, with Retry (the card's menu has it too)
                if !quiet { wordsToast(s, "capture.voice.words_failed") }
            }
            hanging.update(s)
        } else if s.transcription == .pending {
            s.transcription = .idle
        }
        for f in pendingWords.removeValue(forKey: key) ?? [] { f(s.said) }
    }

    /// "Couldn't turn the note into words · Retry" / "No words recognized · Retry".
    private func wordsToast(_ s: Shot, _ key: String) {
        var t = Island.Toast(text: Loc.t(key, table: "Capture"), actionTitle: Loc.t("capture.retry", table: "Capture")) { [weak self] in
            self?.retryWords(s)
        }
        t.seconds = 8
        // one per capture (Island's ToastQueue): two notes that failed each keep their Retry — keyless toasts with the
        // same text would take each other's place
        t.key = Snapper.wordsToastKey(s)
        island.toast(t)
    }
    static func wordsToastKey(_ s: Shot) -> String { "capture.words.\(ObjectIdentifier(s).hashValue)" }
    /// transcriptions started at launch (restore): no toast each — the cards show it
    private var quietWords = Set<ObjectIdentifier>()
    private var pendingWords: [ObjectIdentifier: [(String?) -> Void]] = [:]
    /// how many times a capture's recording was replaced (Edit Note's re-record): words of an older take are stale
    private var wordsTake: [ObjectIdentifier: Int] = [:]

    /// The note bubble's live stream for `s` (its words were transcribed while they were said): the card's words come
    /// from it — only its last piece is left.
    func attach(_ st: VoiceNoteStream, to s: Shot) { streamed[ObjectIdentifier(s)] = st }

    /// `s`'s words (they may already be coming), then `then` with them (nil: none / failed).
    func fetchWords(_ s: Shot, then: @escaping (String?) -> Void) { transcribe(s, then: then) }

    /// The bubble dropped `s`'s voice (abandoned for typing): words still coming for it are not its words.
    func forgetWords(_ s: Shot) {
        let key = ObjectIdentifier(s)
        wordsTake[key, default: 0] += 1
        streamed.removeValue(forKey: key)?.cancel()
        s.transcription = .idle
        for f in pendingWords.removeValue(forKey: key) ?? [] { f(nil) }
    }

    /// An edit kept a re-record over `s`'s voice (its `said` is nil again). Words still coming for the old take are
    /// dropped when they land, and whoever waited for them gets the new take's words instead.
    func voiceReplaced(_ s: Shot) {
        let key = ObjectIdentifier(s)
        wordsTake[key, default: 0] += 1
        streamed.removeValue(forKey: key)
        s.transcription = .idle
        guard let waiting = pendingWords.removeValue(forKey: key) else { return }
        emit(["event": "voice_replaced", "n": s.n, "waiting": waiting.count])
        transcribe(s) { t in waiting.forEach { $0(t) } }
    }
    /// voice notes whose pieces were transcribed while they were said (VoiceNoteStream), until their words are in
    private var streamed: [ObjectIdentifier: VoiceNoteStream] = [:]
    /// Scripted checks (test commands only): BLURT_TEST_WORDS_DELAY=SECS holds every transcription back that long, so
    /// a voice card can be dragged before its words are there.
    static let testWordsDelay: Double? = {
        let env = ProcessInfo.processInfo.environment
        return env["BLURT_TEST_COMMANDS"] == "1" ? env["BLURT_TEST_WORDS_DELAY"].flatMap(Double.init) : nil
    }()
    /// Scripted checks (test commands only): BLURT_TEST_WORDS_FAIL=N — the first N transcriptions fail.
    private static var testFailsLeft: Int = {
        let env = ProcessInfo.processInfo.environment
        return env["BLURT_TEST_COMMANDS"] == "1" ? env["BLURT_TEST_WORDS_FAIL"].flatMap(Int.init) ?? 0 : 0
    }()
    private static func testFailWords() -> Bool {
        guard testFailsLeft > 0 else { return false }
        testFailsLeft -= 1
        return true
    }

    /// A shot's spoken note that holds no words: the wav goes, and with it the mic mark — the shot keeps its typed note.
    private func dropVoice(_ s: Shot, reason: String) {
        if let u = s.voiceURL { try? FileManager.default.removeItem(at: u) }
        s.voice = nil
        s.said = nil
        s.transcription = .idle
        s.batch?.save(s)
        emit(["event": "voice_dropped", "n": s.n, "reason": reason])
    }

    /// "Retry Transcription" (a card's menu, after "Couldn't transcribe").
    func retryWords(_ s: Shot) {
        guard s.voice != nil, CardNote.clean(s.said) == nil, !s.deleted else { return }
        if s.said != nil { s.said = nil }             // "No words recognized": ask again
        if s.transcription == .failed { s.transcription = .idle }
        island.dropToasts(key: Snapper.wordsToastKey(s))       // its Retry is being done
        emit(["event": "voice_retry", "n": s.n, "intended_project": s.intendedProject ?? NSNull()])
        transcribe(s) { [weak self] _ in self?.settled(s) }
    }

    /// The words of every spoken note among `shots` that has none yet (a card dragged onto a project while its words
    /// were still coming), then `then` — so the item gets them as its title and quote, not "Screenshot 14:32".
    private func words(for shots: [Shot], then: @escaping () -> Void) {
        let need = shots.filter(\.needsWords)
        guard !need.isEmpty else { return then() }
        var left = need.count
        for s in need {
            transcribe(s) { _ in left -= 1; if left == 0 { then() } }
        }
    }

    // MARK: where a capture goes once it is complete

    /// The note bubble closed (or there was none), or a capture's words came in: where it goes now (BlurtCore
    /// CaptureRoute). With a project it is filed without an agent — with its note, or without one; a spoken note is
    /// transcribed first (also next to typed text: the item gets both). Its words couldn't be had and nothing was
    /// typed → a card that remembers the project (Retry files it there). Auto: a card, its words fetched for it.
    func settled(_ s: Shot) {
        guard !s.deleted, let b = s.batch else { return }
        let filing = s.assignedBy == "capture" ? s.project : nil
        // no words: the transcription failed, or a voice note held none (a shot's empty voice was dropped already)
        let noWords = s.transcription == .failed || (s.kind == .voice && s.voice != nil && s.said?.isEmpty == true)
        let route = CaptureRoute.decide(project: filing, intended: s.intendedProject, isCard: s.isCard, needsWords: s.needsWords,
                                        noWords: noWords, hasNote: s.words != nil)
        switch route {
        case .transcribeFirst:
            // a card's words in auto mode: for the card, a copy and the item it becomes; otherwise routed again after
            if filing == nil && s.intendedProject == nil { transcribe(s) { _ in } }
            else { transcribe(s) { [weak self] _ in self?.settled(s) } }
        case .file(let p):
            if filing == nil { b.assign(s, project: p, by: "capture") }      // a card filed where it was taken for
            file([s], in: b, project: p)
        case .cardKeepingProject(let p):
            hangAsCard(s, keeping: p)
        case .card, .none:
            break
        }
    }

    /// Taken with a project, but its words couldn't be had: a card until Retry gets them, then it is filed there.
    private func hangAsCard(_ s: Shot, keeping p: String) {
        guard let b = s.batch else { return }
        b.release(s, keeping: p)
        emit(["event": "card", "n": s.n, "session": b.dir.path, "reason": "no_words", "intended_project": p])
        if hanging.screenRect(of: s) == nil { hanging.catchCapture(s, from: island.frameOnScreen) }
        hanging.refresh()
    }

    /// Captures → items with captures.py: the note is the item, no agent, no tokens. A process job (K4) all the
    /// same, so the island hatches it and the main window lists it (usage: 0 tokens).
    func file(_ shots: [Shot], in b: ShotBatch, project: String) {
        let ns = shots.map(\.n)
        for s in shots { hanging.pullIn(s) }
        island.expectProcess(session: b.dir, captures: ns)
        filing += 1
        words(for: shots) { b.sync { self.write(shots, in: b, project: project) } }
    }
    /// filings under way (prepareForQuit waits for them a moment)
    private var filing = 0

    private func write(_ shots: [Shot], in b: ShotBatch, project: String) {
        let ns = shots.map(\.n)
        do {
            let job = JobWriter(type: .process, project: project, session: b.dir, title: T("job.title.filed"))
            job.setCaptures(ns)
            job.step("prepare", .done)
            job.step("write", .running)
            emit(["event": "file", "session": b.dir.path, "captures": ns, "project": project, "job": job.id])
            Task {
                var r: [String: Any]?
                var why: String?
                do {
                    r = try await ScriptRunner.shared.json("captures.py", ["file", b.dir.path, "--captures"] + ns.map(String.init)
                                                            + ["--project", project], timeout: 120)
                } catch { why = "\(error)" }
                await MainActor.run {
                    let made = r?["items"] as? [[String: Any]] ?? []
                    job.setItems(made.compactMap { $0["uid"] as? String })
                    job.setUsage(tokens: 0, agent: nil, model: nil, effort: nil)
                    job.step("write", r == nil ? .failed : .done)
                    for st in ["transcribe", "frames"] { job.step(st, .skipped) }
                    job.finish(r == nil ? .failed : .done, error: why.map { JobError(code: "io", message: $0, hintKey: nil) })
                    self.filing = max(0, self.filing - 1)
                    emit(["event": "filed", "job": job.id, "items": made.compactMap { $0["id"] as? String }, "tokens": 0])
                    guard let first = made.first else { return }
                    self.announceFiled(project: project, id: first["id"] as? String, uids: made.compactMap { $0["uid"] as? String })
                }
            }
        }
    }

    /// One quiet line in the island: "Filed to ordo-platform · OP-14 · Change" (the project's key badge in its
    /// colour); Change picks another project for what was just filed (Refile).
    private func announceFiled(project: String, id: String?, uids: [String]) {
        let store = ProjectStore.shared
        let p = project == "inbox" ? store.inbox : store.project(id: project)
        let name = p?.name ?? project
        let ids = (id ?? "") + (uids.count > 1 ? " +\(uids.count - 1)" : "")
        var t = Island.Toast(text: Loc.t("capture.filed", table: "Capture", name, ids), actionTitle: Loc.t("capture.change", table: "Capture")) {
            Refile.items(uids, from: project)
        }
        t.badge = p.map { ($0.key, ProjectLook.color($0)) }
        island.toast(t)
    }

    /// A card dropped on a project (or "inbox" = Unassigned) in the island: filed there, like a capture with a note.
    func assign(_ s: Shot, to project: String) { assign([s], to: project) }

    /// Cards — one, or a ⌘-click selection — onto a project (Move To ▸, a drop on the island): each batch's filed in
    /// one go, the user's own choice (assigned_by "user").
    func assign(_ shots: [Shot], to project: String) {
        var by: [ObjectIdentifier: (ShotBatch, [Shot])] = [:]
        var order: [ObjectIdentifier] = []
        for s in shots where s.isCard {
            guard let b = s.batch else { continue }
            b.assign(s, project: project, by: "user")
            let k = ObjectIdentifier(b)
            if by[k] == nil { order.append(k) }
            by[k, default: (b, [])].1.append(s)
        }
        for k in order {
            guard let (b, ss) = by[k] else { continue }
            emit(["event": "assign", "n": ss.map(\.n), "session": b.dir.path, "project": project])
            file(ss, in: b, project: project)
        }
    }

    /// The cards, to an agent — one run per batch, with the cards' processing model. `project` set ("Organize" with
    /// a current project): they all go there; nil: into Unassigned, the run told the projects so it can suggest one
    /// per item (nothing moves — "Looks like X · Move" in the main window). `shots`: just these (a card's own
    /// "Organize", a drop on Organize); nil: every hanging card (the island's Organize, "Organize All Cards").
    func handToAI(project: String? = nil, shots: [Shot]? = nil) {
        let all = (shots ?? cards).filter(\.isCard)
        guard !all.isEmpty else { return }
        NoteBubble.shared.commit()
        // the cards come off the notch only once an agent can take them: none usable → they stay, and the island says why
        agentReady { [weak self] ok in
            guard let self = self else { return }
            guard ok else {
                emit(["event": "organize_no_agent", "captures": all.map(\.n)])
                var t = Island.Toast(text: Loc.t("capture.sort.no_agent", table: "Capture"),
                                     actionTitle: Loc.t("capture.sort.set_up", table: "Capture")) {
                    AppEnvironment.settings?.show(pane: SettingsPane.agents.rawValue)
                }
                t.seconds = 8
                return island.toast(t)
            }
            self.giveToAI(all.filter(\.isCard), project: project)
        }
    }

    /// Is any coding agent usable now (AgentHub's cached check)? Tests: BLURT_TEST_AGENTS=none|ready; a stubbed
    /// process (BLURT_TEST_PROCESS) counts as ready.
    private func agentReady(_ then: @escaping (Bool) -> Void) {
        let env = ProcessInfo.processInfo.environment
        if env["BLURT_TEST_COMMANDS"] == "1", let t = env["BLURT_TEST_AGENTS"] { return then(t != "none") }
        if env["BLURT_TEST_PROCESS"] != nil { return then(true) }
        let hub = AgentHub.shared
        hub.check(hub.order()) { st in then(st.contains { $0.state.usable }) }
    }

    private func giveToAI(_ all: [Shot], project: String?) {
        guard !all.isEmpty else { return }
        var by: [ObjectIdentifier: (ShotBatch, [Int])] = [:]
        for s in all {
            guard let b = s.batch else { continue }
            b.assign(s, project: project, by: project == nil ? "ai" : "user")
            by[ObjectIdentifier(b), default: (b, [])].1.append(s.n)
        }
        hanging.pullInAll(all)
        for (b, ns) in by.values {
            emit(["event": "organize", "session": b.dir.path, "captures": ns, "project": project ?? NSNull()])
            island.expectProcess(session: b.dir, captures: ns)
            process(b, ns, project: project)
        }
    }

    /// Delete (a card's ×, its menu, ⌫ on a card with the keyboard on it): no question first — it falls off its thread
    /// and the island says "Deleted · Undo" for a few seconds. Its files stay where they are a little longer than that
    /// (CardDelete.recycleAfter), then go to the Trash; Undo puts the card back on its thread. Deletes while that Undo
    /// is offered join it (BlurtCore CardUndo): "Deleted N cards · Undo" brings back every one of them.
    func delete(_ s: Shot) { delete([s]) }

    /// "Delete All N Cards" (the island's menu, the overview): every hanging card, one Undo for all of them.
    func deleteAllCards() {
        NoteBubble.shared.cancel()
        delete(cards)
    }

    private static let deleteToast = "cards.delete"
    /// What the delete Undo showing now would bring back, and where each one's files went in the Trash.
    private var undoable = CardUndo<Shot>()
    private var trashedFiles: [ObjectIdentifier: [URL: URL]] = [:]

    private func delete(_ shots: [Shot]) {
        for s in shots where NoteBubble.shared.shot === s { NoteBubble.shared.cancel() }
        // (a fresh shot's bubble discards it itself, with its own Undo)
        let gone = shots.filter { !$0.deleted && $0.batch != nil }
        guard !gone.isEmpty else { return }
        let live = island.toastLive(key: Snapper.deleteToast)
        if !live { trashedFiles = [:] }
        let all = undoable.add(gone, live: live)
        for s in gone {
            hanging.drop(s)
            s.batch?.delete(s, recycleAfter: CardDelete.recycleAfter) { [weak self] moved in self?.trashedFiles[ObjectIdentifier(s)] = moved }
        }
        emit(["event": "delete", "captures": gone.map(\.n), "undo": all.map(\.n),
              "sessions": Array(Set(gone.compactMap { $0.batch?.dir.path }))])
        let text = all.count == 1 ? Loc.t("capture.card.deleted", table: "Capture")
                                  : Loc.plural("capture.card.deleted_n", table: "Capture", count: all.count)
        var t = Island.Toast(text: text, actionTitle: Loc.t("capture.undo", table: "Capture")) { [weak self] in self?.undelete() }
        t.seconds = CardDelete.undoSeconds
        t.overOpen = true               // the island may be open over the cards: the Undo shows at once all the same
        t.key = Snapper.deleteToast     // a delete while it shows joins it, and the toast says so
        island.toast(t)
    }

    /// Undo of a delete: back on their threads, where they hung (the cards keep the order they were taken in).
    private func undelete() {
        let back = undoable.take().filter(\.deleted)
        for s in back { s.batch?.undelete(s, from: trashedFiles.removeValue(forKey: ObjectIdentifier(s)) ?? [:]) }
        emit(["event": "undo_delete", "captures": back.map(\.n)])
        hanging.refresh()
        hanging.show(peek: 2.5)
    }

    /// Esc in the note bubble: this capture goes to the Trash; "Discarded · Undo" for 5 s (as long as a discarded voice
    /// note's) brings it back (with what was typed, said and drawn), and it then goes where it would have gone.
    func discard(_ s: Shot) {
        guard let b = s.batch else { return }
        hanging.drop(s)
        emit(["event": "discard", "n": s.n, "session": b.dir.path])
        b.delete(s) { [weak self] trashed in
            var t = Island.Toast(text: Loc.t("capture.discarded", table: "Capture"), actionTitle: Loc.t("capture.undo", table: "Capture")) {
                self?.undoDiscard(s, trashed: trashed)
            }
            t.seconds = VoiceInput.undoSeconds
            island.toast(t)
        }
    }

    // MARK: taken — dragged out and dropped in another app (v0.8.1)

    /// A card dragged out and dropped in another app: it has done its job, so it leaves its thread — but it is "taken",
    /// not discarded: its files stay where they are (the app may read them late) and it is in Recently Taken (the
    /// island's right-click menu, the main window) for 7 days, where it can be copied, dragged out again or put back;
    /// then housekeeping trashes it (expireTaken).
    /// `delivered`: the kind of app whose payload the drop got (nil: not sure); `noteFile`: the .md went with it;
    /// `landed` / `at`: the app it was dropped into and where (a screen point). A chat app (a browser, an Electron
    /// app, WeChat, QQ…) got the picture alone: the note is then pasted in after it (DragNoteFollowUp,
    /// record.smart_paste) — never in a code editor, whose focus may be source code. Where the note didn't go in after
    /// all (a code editor, the follow-up couldn't run, the app didn't read it, the Finder, not sure), the note goes on
    /// the clipboard (record.drag_copy_note; BlurtCore DragReceipt) and the
    /// toast says "⌘V to paste"; a rich app (it took the note from the rich item) and a terminal (both paths) leave the
    /// clipboard alone. "Undo" in the toast puts the card back on its thread (and the clipboard as it was, if nothing
    /// was copied since). `fromPanel`: dragged out of Recently Taken again (it is already off its thread; its days
    /// start over).
    func takeOut(_ s: Shot, fromPanel: Bool = false, delivered: DropClass? = nil, noteFile: Bool = false, landed: DropTarget? = nil,
                 at p: NSPoint? = nil) {
        guard let b = s.batch, !s.deleted else { return }
        if NoteBubble.shared.shot === s { NoteBubble.shared.cancel() }
        if !fromPanel { hanging.takeAway(s) }
        b.take(s, at: Snapper.now)
        takenChanged()
        let plan = DragFollowUp.plan(delivered: delivered,
                                     card: CardPasteboard.Card(image: s.kind == .shot ? s.bestURL : nil, note: s.copyText),
                                     enabled: SmartPaste.enabled, accessibility: SmartPaste.accessibility,
                                     secureInput: !DictationInsert.testMode && IsSecureEventInputEnabled(), kind: landed?.kind)
        if s.kind == .shot, s.copyText != nil {
            emit(["event": "drag_note_plan", "n": s.n, "bundle": landed?.bundleID ?? NSNull(), "kind": landed?.kind.rawValue ?? NSNull(),
                  "plan": "\(plan)"])
        }
        if case .pasteNote(let note) = plan, let t = landed {
            DragNoteFollowUp.run(note: note, target: t, at: p ?? NSEvent.mouseLocation) { [weak self] pasted in
                self?.tookOut(s, b, fromPanel: fromPanel, delivered: delivered, noteFile: noteFile, notePasted: pasted)
            }
            return
        }
        tookOut(s, b, fromPanel: fromPanel, delivered: delivered, noteFile: noteFile, notePasted: false)
    }

    /// A voice card let go of over a chat app's window (VoiceCardDrop): the app took the drop (its message box), or
    /// Blurt pastes the words into that window's composer — the shot cards' follow-up (DragNoteFollowUp: the window
    /// forward, the composer focused, one paste, the clipboard back). Can't: the words on the clipboard. Either way the
    /// card has been used ("Pasted into Claude · Undo").
    func takeOutVoice(_ s: Shot, fromPanel: Bool = false, landed t: DropTarget, at p: NSPoint, accepted: Bool) {
        guard let b = s.batch, !s.deleted else { return }
        if NoteBubble.shared.shot === s { NoteBubble.shared.cancel() }
        if !fromPanel { hanging.takeAway(s) }
        b.take(s, at: Snapper.now)
        takenChanged()
        let app = DropProbe.appName(t) ?? "App"
        let plan = VoiceCardDrop.plan(cls: t.cls, kind: t.kind, accepted: accepted, words: s.copyText, enabled: SmartPaste.enabled,
                                      accessibility: SmartPaste.accessibility,
                                      secureInput: !DictationInsert.testMode && IsSecureEventInputEnabled())
        emit(["event": "voice_drop_plan", "n": s.n, "bundle": t.bundleID ?? NSNull(), "kind": t.kind.rawValue, "app": app,
              "accepted": accepted, "plan": "\(plan)"])
        let done = { [weak self] (pasted: Bool, copy: String?) in
            guard let self = self else { return }
            let saved = copy.flatMap { DragClipboard.putNote($0, on: capturePasteboard) }
            let key = saved != nil ? "capture.voice_drop.copied" : pasted ? "capture.voice_drop.pasted" : "capture.taken_out"
            emit(["event": "take_out", "n": s.n, "session": b.dir.path, "voice": true, "pasted": pasted, "note_copied": saved != nil,
                  "accepted": accepted, "from_panel": fromPanel, "app": app, "toast": key])
            var toast = Island.Toast(text: Loc.t(key, table: "Capture", app),
                                     actionTitle: fromPanel ? nil : Loc.t("capture.undo", table: "Capture")) { [weak self] in
                saved?.restore(capturePasteboard)
                self?.putBack(s)
            }
            if fromPanel { toast.action = nil }
            toast.seconds = saved != nil ? 5 : 4
            island.toast(toast)
        }
        switch plan {
        case .none: done(accepted, nil)
        case .copy(let w): done(false, w)
        case .paste(let w):
            DragNoteFollowUp.run(note: w, target: t, at: p) { pasted in done(pasted, pasted ? nil : w) }
        }
    }

    /// The rest of a take-out: the safety-net copy of the note, and the toast saying what went in.
    private func tookOut(_ s: Shot, _ b: ShotBatch, fromPanel: Bool, delivered: DropClass?, noteFile: Bool, notePasted: Bool) {
        let hasNote = s.kind == .shot && s.copyText != nil
        let outcome = DragReceipt.outcome(delivered: delivered, notePasted: notePasted, noteFile: noteFile)
        let note = hasNote && CardExport.copyNoteAfterDrag && DragReceipt.copiesNote(outcome) ? s.copyText : nil
        let saved = note.flatMap { DragClipboard.putNote($0, on: capturePasteboard) }
        let key = DragReceipt.toastKey(outcome, hasNote: hasNote, noteCopied: saved != nil, noteFile: noteFile)
        emit(["event": "take_out", "n": s.n, "session": b.dir.path, "note_copied": saved != nil, "from_panel": fromPanel,
              "delivered": delivered?.rawValue ?? NSNull(), "note_pasted": notePasted, "note_file": noteFile,
              "outcome": outcome.rawValue, "toast": key])
        var t = Island.Toast(text: Loc.t(key, table: "Capture"),
                             actionTitle: fromPanel ? nil : Loc.t("capture.undo", table: "Capture")) { [weak self] in
            saved?.restore(capturePasteboard)
            self?.putBack(s)
        }
        if fromPanel { t.action = nil }
        t.seconds = saved != nil ? 5 : 4
        island.toast(t)
    }

    /// Back on its thread (Undo after a drag-out, "Put Back" in Recently Taken): a card again. `from`: where it flies
    /// up from (a row of the panel, screen rect).
    func putBack(_ s: Shot, from: NSRect? = nil) {
        guard let b = s.batch, !s.deleted, s.taken != nil else { return }
        b.untake(s)
        emit(["event": "put_back", "n": s.n, "session": b.dir.path])
        if !cardBatches.contains(where: { $0 === b }) { b.onChange = { hanging.refresh() }; cardBatches.append(b) }
        hanging.catchCapture(s, from: from)
        takenChanged()
    }

    /// Recently Taken: captures dragged out in the last 7 days, newest first.
    var recentlyTaken: [Shot] {
        let now = Snapper.now
        return cardBatches.flatMap { $0.live.filter { s in s.taken.map { TakenCaptures.isRecent(taken: $0, now: now) } ?? false } }
            .sorted { ($0.taken ?? 0, $0.n) > ($1.taken ?? 0, $1.n) }
    }

    /// Housekeeping: a capture taken 7+ days ago goes to the Trash (files, its out/ folder; `{"n","deleted":true}`).
    @discardableResult
    func expireTaken() -> Int {
        let now = Snapper.now
        var n = 0
        for b in cardBatches {
            for s in b.live where s.taken.map({ TakenCaptures.isExpired(taken: $0, now: now) }) ?? false {
                b.delete(s)
                emit(["event": "taken_expired", "n": s.n, "session": b.dir.path])
                n += 1
            }
        }
        if n > 0 { takenChanged() }
        return n
    }

    private func takenChanged() {
        NotificationCenter.default.post(name: .blurtTakenChanged, object: nil, userInfo: ["count": recentlyTaken.count])
        TakenPanel.shared.reload()
    }

    /// Now (seconds since 1970) — scripted checks move the clock (test command `clock SECONDS`) to see 7 days pass.
    static var now: Double { Date().timeIntervalSince1970 + clockOffset }
    static var clockOffset: Double = 0
    private var expiryTimer: Timer?

    /// A voice note's words, if they are not there yet (a card dragged before they were written down).
    func wantWords(_ s: Shot) {
        guard s.voice != nil, s.said == nil else { return }
        if s.transcription == .failed { s.transcription = .idle }      // asked again: one more try
        transcribe(s) { _ in }
    }

    private func undoDiscard(_ s: Shot, trashed: [URL: URL]) {
        guard let b = s.batch, s.deleted else { return }
        b.undelete(s, from: trashed)
        emit(["event": "undo_discard", "n": s.n, "session": b.dir.path])
        hanging.catchCapture(s, from: nil)
        settled(s)
    }

    private func process(_ b: ShotBatch, _ ns: [Int], project: String?) {
        b.sync {
            emit(["event": "process", "session": b.dir.path, "captures": ns, "project": project ?? NSNull()])
            _ = AppEnvironment.process?(b.dir, ns, project)
        }
    }

    /// Cards come back after a restart: every shots batch with unassigned captures, however old (a card waits until
    /// the user does something with it; v0.8.6 looked at the last 30 days only and older cards vanished) — in the
    /// inbox, and in the projects (captures taken there without a note). Only a batch whose shots.jsonl still holds a
    /// card is loaded (BlurtCore CardBatches: its pictures are read only then).
    func restore() {
        let store = ProjectStore.shared
        let dirs = ([store.inbox] + store.projects).flatMap { p -> [URL] in
            let root = p.store.appendingPathComponent("sessions")
            return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasSuffix("-shots") }
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var unsettled: [Shot] = []
        for d in dirs where !cardBatches.contains(where: { canonicalPath($0.dir) == canonicalPath(d) }) {
            let raw = (try? String(contentsOf: d.appendingPathComponent("shots.jsonl"), encoding: .utf8)) ?? ""
            // left half-done by a quit or a crash (v0.9): a project capture never filed, a voice note's wav without its line
            let filed = Set((Snapper.batchJSON(d)["local"] as? [String: Any])?.keys.map { $0 } ?? [])
            let unfiled = CaptureRestore.unfiled(jsonl: raw, filed: filed)
            var files = (try? FileManager.default.contentsOfDirectory(atPath: d.appendingPathComponent("shots").path)) ?? []
            // voice notes cancelled with Esc whose Undo a quit cut short: discarded, as the user asked
            if files.contains(where: VoiceDiscard.isParked) {
                VoiceDiscard.sweep(d.appendingPathComponent("shots"))
                files.removeAll(where: VoiceDiscard.isParked)
            }
            let orphans = CaptureRestore.orphanVoices(files: files, known: Set(CaptureRestore.fold(raw).keys))
            // cards, and captures dragged out (Recently Taken — or past their days, for expireTaken)
            guard CardBatches.holdsCards(jsonl: raw) || !unfiled.isEmpty || !orphans.isEmpty,
                  let b = ShotBatch.load(d) ?? (orphans.isEmpty ? nil : ShotBatch(dir: d, inRecording: false)) else { continue }
            VoiceRetake.sweep(d.appendingPathComponent("shots"))
            let back = orphans.compactMap { recoverVoice($0, in: b) }
            let pending = unfiled.compactMap { n in b.live.first { $0.n == n } } + back
            guard b.live.contains(where: { $0.isCard || $0.taken != nil }) || !pending.isEmpty else { continue }
            b.onChange = { hanging.refresh() }
            cardBatches.append(b)
            if !pending.isEmpty { emit(["event": "restore_unsettled", "session": d.path, "unfiled": unfiled, "voices": orphans]) }
            unsettled += pending
        }
        hanging.refresh(quiet: true)
        expireTaken()
        takenChanged()
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.expireTaken() }
        // a spoken note left without words (the app quit first, or an older version skipped it): its words now — or,
        // if it holds none, it is dropped — and a capture left on its way into a project goes on there. One after
        // another (not a model process per card at launch).
        let wanting = cards.filter(\.needsWords)
        settleInTurn(wanting + unsettled.filter { u in !wanting.contains { $0 === u } })
    }

    private func settleInTurn(_ shots: [Shot]) {
        guard let s = shots.first else { return }
        let next = { [weak self] in self?.settleInTurn(Array(shots.dropFirst())) }
        guard s.needsWords else { settled(s); next(); return }
        quietWords.insert(ObjectIdentifier(s))
        transcribe(s) { [weak self] _ in self?.settled(s); next() }
    }

    /// A voice note's wav that never got its shots.jsonl line (Blurt quit or crashed while it listened): its header is
    /// written from the file's size (BlurtCore WavRepair) and it comes back — into the batch's project, else as a card.
    private func recoverVoice(_ n: Int, in b: ShotBatch) -> Shot? {
        let url = b.shotsDir.appendingPathComponent("\(ShotBatch.name(n)).wav")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              let fh = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 8192)
        guard let start = WavRepair.dataStart(header: head), size > start else { return nil }
        if let fixed = WavRepair.repair(header: head, fileSize: size) {
            try? fh.seek(toOffset: 0)
            fh.write(fixed)
        }
        let seconds = Double(size - start) / (NoteVoice.rate * 2)       // 16 kHz, 16-bit mono (NoteVoice)
        let project = b.meta["project"] as? String
        emit(["event": "voice_recovered", "n": n, "session": b.dir.path, "seconds": (seconds * 10).rounded() / 10,
              "project": project ?? NSNull()])
        let s = b.addVoice(n: n, duration: seconds, project: project)
        if project == nil { hanging.catchCapture(s, from: island.frameOnScreen) }
        return s
    }

    /// batch.json of a session ({} when there is none): its "local" ids say which captures captures.py filed.
    static func batchJSON(_ dir: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("batch.json")))) as? [String: Any] ?? [:]
    }

    // MARK: quitting

    /// Blurt is quitting: the open note is saved, a voice note finished (its wav closed, its line written), words and
    /// filings under way get a moment (`cap`), and every batch's shots.jsonl is flushed — then `done`. What is still
    /// on its way is picked up at the next launch (restore).
    func prepareForQuit(cap: Double = 3, _ done: @escaping () -> Void) {
        VoiceInput.shared.finishForQuit()
        NoteBubble.shared.commitNow()
        let until = Date().addingTimeInterval(cap)
        emit(["event": "quit_wait", "words": pendingWords.count, "filing": filing])
        // a run-loop timer in the common modes, not the main queue: AppKit waits for the reply in a modal loop, and
        // a quit that came from a main-queue block (a signal, a scripted command) never gets the main queue back
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return done() }
            guard (self.pendingWords.isEmpty && self.filing == 0) || Date() >= until else { return }
            t.invalidate()
            emit(["event": "quit_ready", "words": self.pendingWords.count, "filing": self.filing])
            for b in self.cardBatches + Array(self.open.values) { b.flush() }       // every shots.jsonl line is on disk
            done()
        }
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: the system's own screenshots (⌘⇧3/4/5), optional

    var collecting: Bool { recordConfig()["collect_system_shots"] as? Bool ?? false }

    func screenshotFolder() -> URL {
        let d = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let p = (d.map { ($0 as NSString).expandingTildeInPath }).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        return URL(fileURLWithPath: p ?? (NSHomeDirectory() + "/Desktop"))
    }

    func syncCollector() {
        collectTimer?.invalidate()
        collectTimer = nil
        guard collecting else { return }
        let folder = screenshotFolder()
        let since = Date()
        collectSeen = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        collectTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.scanScreenshots(folder, since: since) }
    }

    private func scanScreenshots(_ folder: URL, since: Date) {
        guard let app = app, app.rec == nil else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where !collectSeen.contains(name) {
            collectSeen.insert(name)
            let url = folder.appendingPathComponent(name)
            guard ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased()), !name.hasPrefix("."),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attrs[.creationDate] as? Date ?? .distantPast) >= since, isScreenCapture(url),
                  let img = loadCGImage(url) else { continue }
            let p = target
            let b = openBatch(for: p)
            let n = b.reserve()
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let sz = CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
            let shot = b.add(n: n, image: img, scale: scale, region: CGRect(origin: .zero, size: sz), t: nil, project: p.isInbox ? nil : p.id)
            shot.region = []        // unknown: taken by the system
            hanging.catchCapture(shot, from: nil)
            settled(shot)
        }
    }

    private func isScreenCapture(_ url: URL) -> Bool {
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let v = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool { return v }
        // Spotlight not indexed yet: the name macOS gives a screenshot in the user's language
        let n = url.lastPathComponent.lowercased()
        return Self.screenshotPrefixes.contains { n.hasPrefix($0) }
    }

    private static let screenshotPrefixes = [
        "screenshot", "screen shot", "截屏", "屏幕快照", "螢幕截圖", "スクリーンショット", "스크린샷", "bildschirmfoto",
        "capture d’écran", "capture d'écran", "captura de pantalla", "captura de tela", "schermata", "schermafbeelding",
        "skärmavbild", "skærmbillede", "skjermbilde", "näyttökuva", "zrzut ekranu", "снимок экрана", "ekran resmi",
    ]
}

let snapper = Snapper()
