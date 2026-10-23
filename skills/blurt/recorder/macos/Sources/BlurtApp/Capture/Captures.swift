// Captures outside a recording (docs/design/next-round.md K7): ⌥⇧A stills, ⌥⇧V voice inputs, and (optionally) the
// system's own screenshots. Each one is a line in the current store's open shots batch, <store>/sessions/<ts>-shots/.
//
// v0.7 token diet — an agent runs only when the user asks for one, once per batch:
//  • a current project is set and the capture has a note (typed, or spoken and transcribed here) → it is filed
//    straight away by captures.py, no agent, no tokens: it flies up, a thread reels it into the island, and the island
//    says where it went ("Filed to ordo-platform · OP-14"). The item carries `enrich: pending` for a later AI fill-in.
//  • no note (or no project: current = auto) → it hangs from the island on a thread, as a card, until the user drags
//    it onto a project in the island (filed there the same way, no agent), onto "Unassigned", or hands the cards to
//    the AI: "Organize" (into the current project) / "Let AI sort" — one agent run with the processing model.
//  • Esc in the note bubble discards the capture (Trash, with Undo for 3 s); ⏎ keeps it without a note (→ a card).
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

func isShotsSession(_ dir: URL) -> Bool {
    dir.lastPathComponent.hasSuffix("-shots") || FileManager.default.fileExists(atPath: dir.appendingPathComponent("shots.jsonl").path)
        && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("recording.mp4").path)
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
        rememberFrontApp()
        app.busy = true
        let p = PickerController()
        p.snapMode = true
        p.onDone = { [weak self, weak app] r in
            unregisterHotkey(.pickEnter); unregisterHotkey(.pickEsc); unregisterHotkey(.pickFull)
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
        p.show(preselect: preselect)
    }

    // MARK: batches

    /// Where a capture goes now: the current project, or the inbox (as a card) when the current project is auto.
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
                AppEnvironment.island?.toast(Loc.t("capture.snap.no_permission", table: "Capture"), actionTitle: nil, action: nil)
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

    func playShutter() {
        guard recordConfig()["snap_sound"] as? Bool ?? true else { return }
        let p = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if FileManager.default.fileExists(atPath: p) { NSSound(contentsOfFile: p, byReference: true)?.play() }
    }

    // MARK: voice inputs

    /// A finished voice input (VoiceInput.swift): its wav is at shots/NNN.wav of `batch`. The words are its note:
    /// with a project it is filed once they are transcribed; without words (or a project) it hangs as a card.
    func voiceFinished(batch b: ShotBatch, n: Int, duration: Double, project: String?) {
        let s = b.addVoice(n: n, duration: duration, project: project)
        emit(["event": "voice", "n": n, "session": b.dir.path, "duration": duration, "project": project ?? NSNull()])
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
        s.transcription = .pending
        hanging.update(s)
        Task {
            if let d = Snapper.testWordsDelay { try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) }
            var r = try? await ScriptRunner.shared.json("transcribe.py", ["note", wav.path, "--language", "auto"], timeout: 120)
            if Snapper.testFailWords() { r = nil }
            let ok = r.map { ($0["ok"] as? Bool) ?? true } ?? false
            let text = ok ? (r?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            await MainActor.run {
                emit(["event": "voice_text", "n": s.n, "ok": text != nil, "empty": text?.isEmpty ?? false])
                if !s.deleted {
                    if let t = text, !t.isEmpty {
                        s.said = t
                        s.transcription = .idle
                        s.batch?.save(s)
                    } else if text != nil {
                        s.transcription = .idle
                        if s.kind == .shot { self.dropVoice(s, reason: "no_speech") } else { s.said = ""; s.batch?.save(s) }
                    } else {
                        s.transcription = .failed
                    }
                    hanging.update(s)
                } else if s.transcription == .pending {
                    s.transcription = .idle
                }
                for f in self.pendingWords.removeValue(forKey: key) ?? [] { f(s.said) }
            }
        }
    }
    private var pendingWords: [ObjectIdentifier: [(String?) -> Void]] = [:]
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
        guard s.voice != nil, s.said == nil else { return }
        if s.transcription == .failed { s.transcription = .idle }
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

    /// The note bubble closed (or there was none). With a project and a note it is filed now, without an agent; a
    /// spoken note is transcribed first (also next to typed text: the item gets both). No note → it lets go of the
    /// project and hangs as a card.
    func settled(_ s: Shot) {
        guard !s.deleted else { return }
        let filing = s.project != nil && s.assignedBy == "capture"
        // a card (auto mode) with a spoken note: its words now, for the card, a copy and the item it becomes
        if !filing, s.needsWords { transcribe(s) { _ in } }
        guard filing, let p = s.project, let b = s.batch else { return }
        if s.needsWords { return transcribe(s) { [weak self] _ in self?.settled(s) } }
        if s.words != nil { return file([s], in: b, project: p) }
        hangAsCard(s)       // nothing typed, and the words couldn't be had here: a card (an agent transcribes it later)
    }

    /// Captured with a project but nothing said about it: not worth filing on its own — a card, like in auto mode.
    private func hangAsCard(_ s: Shot) {
        guard let b = s.batch else { return }
        b.release(s)
        emit(["event": "card", "n": s.n, "session": b.dir.path, "reason": "no_note"])
        if hanging.screenRect(of: s) == nil { hanging.catchCapture(s, from: island.frameOnScreen) }
        hanging.refresh()
    }

    /// Captures → items with captures.py: the note is the item, no agent, no tokens. A process job (K4) all the
    /// same, so the island hatches it and the main window lists it (usage: 0 tokens).
    func file(_ shots: [Shot], in b: ShotBatch, project: String) {
        let ns = shots.map(\.n)
        for s in shots { hanging.pullIn(s) }
        island.expectProcess(session: b.dir, captures: ns)
        words(for: shots) { b.sync { self.write(shots, in: b, project: project) } }
    }

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
                    for st in ["transcribe", "frames", "route"] { job.step(st, .skipped) }
                    job.finish(r == nil ? .failed : .done, error: why.map { JobError(code: "io", message: $0, hintKey: nil) })
                    emit(["event": "filed", "job": job.id, "items": made.compactMap { $0["id"] as? String }, "tokens": 0])
                    guard let first = made.first else { return }
                    self.announceFiled(project: project, id: first["id"] as? String, count: made.count)
                }
            }
        }
    }

    /// One quiet line in the island: "Filed to ordo-platform · OP-14" (the project's key badge in its colour).
    private func announceFiled(project: String, id: String?, count: Int) {
        let store = ProjectStore.shared
        let p = project == "inbox" ? store.inbox : store.project(id: project)
        let name = p?.name ?? project
        let ids = (id ?? "") + (count > 1 ? " +\(count - 1)" : "")
        var t = Island.Toast(text: Loc.t("capture.filed", table: "Capture", name, ids), actionTitle: nil, action: nil)
        t.badge = p.map { ($0.key, ProjectLook.color($0)) }
        island.toast(t)
    }

    /// A card dropped on a project (or "inbox" = Unassigned) in the island: filed there, like a capture with a note.
    func assign(_ s: Shot, to project: String) {
        guard s.isCard, let b = s.batch else { return }
        b.assign(s, project: project, by: "user")
        emit(["event": "assign", "n": s.n, "session": b.dir.path, "project": project])
        file([s], in: b, project: project)
    }

    /// The cards, to an agent — one run per batch, with the processing model. `project` set ("Organize"): they all
    /// go there; nil ("Let AI sort"): routed per item (K2).
    func handToAI(project: String? = nil) {
        let all = cards
        guard !all.isEmpty else { return }
        NoteBubble.shared.commit()
        var by: [ObjectIdentifier: (ShotBatch, [Int])] = [:]
        for s in all {
            guard let b = s.batch else { continue }
            b.assign(s, project: project, by: project == nil ? "ai" : "user")
            by[ObjectIdentifier(b), default: (b, [])].1.append(s.n)
        }
        hanging.pullInAll(all)
        for (b, ns) in by.values {
            emit(["event": project == nil ? "ai_sort" : "organize", "session": b.dir.path, "captures": ns, "project": project ?? NSNull()])
            island.expectProcess(session: b.dir, captures: ns)
            process(b, ns, project: project)
        }
    }

    func delete(_ s: Shot) {
        if NoteBubble.shared.shot === s { NoteBubble.shared.cancel() }
        guard !s.deleted else { return }        // a fresh shot's bubble discards it itself (with Undo)
        hanging.drop(s)
        s.batch?.delete(s)
    }

    /// Esc in the note bubble: this capture goes to the Trash; "Discarded · Undo" for 3 s brings it back (with what
    /// was typed or said), and it then goes where a capture without Esc would have gone.
    func discard(_ s: Shot) {
        guard let b = s.batch else { return }
        hanging.drop(s)
        emit(["event": "discard", "n": s.n, "session": b.dir.path])
        b.delete(s) { [weak self] trashed in
            var t = Island.Toast(text: Loc.t("capture.discarded", table: "Capture"), actionTitle: Loc.t("capture.undo", table: "Capture")) {
                self?.undoDiscard(s, trashed: trashed)
            }
            t.seconds = 3
            island.toast(t)
        }
    }

    // MARK: taken — dragged out and dropped in another app (v0.8.1)

    /// A card dragged out and dropped in another app: it has done its job, so it leaves its thread — but it is "taken",
    /// not discarded: its files stay where they are (the app may read them late) and it is in Recently Taken (the
    /// island's right-click menu, the main window) for 7 days, where it can be copied, dragged out again or put back;
    /// then housekeeping trashes it (expireTaken). With a note, the note also goes on the clipboard
    /// (record.drag_copy_note) where the app may have kept only the picture — not a text app (it took the note from the
    /// rich item) or a terminal (both paths): ⌘V brings the words back (BlurtCore DragReceipt.copiesNote). The toast
    /// says what went in (`delivered` is the kind of app whose payload the drop got, nil if not sure) — no "⌘V to
    /// paste" where the words went in directly or into a terminal. "Undo" in the toast puts the card back on its
    /// thread (and the clipboard as it was, if nothing was copied since).
    /// `fromPanel`: dragged out of Recently Taken again (it is already off its thread; its days start over).
    func takeOut(_ s: Shot, fromPanel: Bool = false, delivered: DropClass? = nil) {
        guard let b = s.batch, !s.deleted else { return }
        if NoteBubble.shared.shot === s { NoteBubble.shared.cancel() }
        if !fromPanel { hanging.takeAway(s) }
        b.take(s, at: Snapper.now)
        let note = s.kind == .shot && CardExport.copyNoteAfterDrag && DragReceipt.copiesNote(delivered: delivered) ? s.copyText : nil
        let saved = note.flatMap { DragClipboard.putNote($0, on: capturePasteboard) }
        let key = DragReceipt.toastKey(delivered: delivered, hasNote: s.kind == .shot && s.copyText != nil, noteCopied: saved != nil)
        emit(["event": "take_out", "n": s.n, "session": b.dir.path, "note_copied": saved != nil, "from_panel": fromPanel,
              "delivered": delivered?.rawValue ?? NSNull(), "toast": key])
        takenChanged()
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

    func deleteAllCards() {
        NoteBubble.shared.cancel()
        for (i, s) in cards.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(i)) { self.delete(s) }
        }
    }

    private func process(_ b: ShotBatch, _ ns: [Int], project: String?) {
        b.sync {
            emit(["event": "process", "session": b.dir.path, "captures": ns, "project": project ?? NSNull()])
            AppEnvironment.process?(b.dir, ns, project)
        }
    }

    /// Cards come back after a restart: every shots batch of the last 30 days with unassigned captures — in the inbox,
    /// and in the projects (captures taken there without a note).
    func restore() {
        let store = ProjectStore.shared
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let dirs = ([store.inbox] + store.projects).flatMap { p -> [URL] in
            let root = p.store.appendingPathComponent("sessions")
            return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.hasSuffix("-shots") }
                .filter { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) > cutoff }
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for d in dirs where !cardBatches.contains(where: { canonicalPath($0.dir) == canonicalPath(d) }) {
            // cards, and captures dragged out (Recently Taken — or past their days, for expireTaken)
            guard let b = ShotBatch.load(d), b.live.contains(where: { $0.isCard || $0.taken != nil }) else { continue }
            b.onChange = { hanging.refresh() }
            cardBatches.append(b)
        }
        hanging.refresh(quiet: true)
        expireTaken()
        takenChanged()
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.expireTaken() }
        // a spoken note left without words (the app quit first, or an older version skipped it): its words now — or,
        // if it holds none, it is dropped. One after another (not a model process per card at launch).
        transcribeInTurn(cards.filter(\.needsWords))
    }

    private func transcribeInTurn(_ shots: [Shot]) {
        guard let s = shots.first else { return }
        transcribe(s) { [weak self] _ in self?.transcribeInTurn(Array(shots.dropFirst())) }
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
