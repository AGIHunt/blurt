// Captures outside a recording (docs/design/next-round.md K7): ⌥⇧A stills, ⌥⇧V voice inputs, and (optionally) the
// system's own screenshots. Each one is a line in the current store's open shots batch, <store>/sessions/<ts>-shots/.
//
//  • a current project is set → the capture belongs to it (project_by capture): it flies up, a claw catches it and
//    pulls it into the island, and it is processed — captures within 8 s of each other become one process job.
//  • current = auto → the capture goes to the inbox store unassigned, and hangs on a claw as a card until the user
//    drags it onto a project in the island (assign + process), onto "Unassigned", or lets the AI sort every card.
// Processing goes through AppEnvironment.process(session, captures, project) — AgentHub's process jobs (K4).

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
    private(set) var cardBatches: [ShotBatch] = []       // inbox batches with cards still hanging
    private var queued: [String: (batch: ShotBatch, project: String, ns: [Int], timer: Timer)] = [:]
    private var collectTimer: Timer?
    private var collectSeen = Set<String>()
    /// captures closer together than this become one process job (K7)
    static let mergeWindow: TimeInterval = 8

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
        if p.isInbox, !cardBatches.contains(where: { $0 === b }) { cardBatches.append(b) }
        b.onChange = { claws.refresh() }
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
            claws.catchCapture(shot, from: ns)
            if withNote { NoteBubble.shared.begin(shot, mode: .listen) } else { self.settled(shot); self.restoreFocus() }
        }
    }

    func playShutter() {
        guard recordConfig()["snap_sound"] as? Bool ?? true else { return }
        let p = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if FileManager.default.fileExists(atPath: p) { NSSound(contentsOfFile: p, byReference: true)?.play() }
    }

    // MARK: voice inputs

    /// A finished voice input (VoiceInput.swift): its wav is at shots/NNN.wav of `batch`.
    func voiceFinished(batch b: ShotBatch, n: Int, duration: Double, project: String?) {
        let s = b.addVoice(n: n, duration: duration, project: project)
        emit(["event": "voice", "n": n, "session": b.dir.path, "duration": duration, "project": project ?? NSNull()])
        if project == nil { claws.catchCapture(s, from: island.frameOnScreen) } else { settled(s) }
        transcribe(s)
    }

    /// K9's fast path (`transcribe.py note`); without it the card just says "Voice note" and the agent transcribes.
    private func transcribe(_ s: Shot) {
        guard let wav = s.voiceURL else { return }
        Task {
            let r = try? await ScriptRunner.shared.json("transcribe.py", ["note", wav.path, "--language", "auto"], timeout: 120)
            let text = (r?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                emit(["event": "voice_text", "n": s.n, "ok": text != nil])
                guard let t = text, !t.isEmpty, !s.deleted else { return }
                s.said = t
                s.batch?.save(s)
                claws.update(s)
            }
        }
    }

    // MARK: where a capture goes once it is complete

    /// The note bubble closed (or there was none): a capture with a project is pulled into the island and queued.
    func settled(_ s: Shot) {
        guard !s.deleted, let p = s.project, s.assignedBy == "capture", let b = s.batch else { return }
        claws.pullIn(s)
        queue(b, project: p, n: s.n, after: Snapper.mergeWindow)
    }

    /// A card dropped on a project (or "inbox" = Unassigned) in the island.
    func assign(_ s: Shot, to project: String) {
        guard s.isCard, let b = s.batch else { return }
        b.assign(s, project: project, by: "user")
        emit(["event": "assign", "n": s.n, "session": b.dir.path, "project": project])
        claws.pullIn(s)
        queue(b, project: project, n: s.n, after: 1.2)
    }

    /// "Let AI sort": every card is processed, one process job per batch, routed per item (K2).
    func aiSort() {
        let all = cards
        guard !all.isEmpty else { return }
        NoteBubble.shared.commit()
        var by: [ObjectIdentifier: (ShotBatch, [Int])] = [:]
        for s in all {
            guard let b = s.batch else { continue }
            b.assign(s, project: nil, by: "ai")
            by[ObjectIdentifier(b), default: (b, [])].1.append(s.n)
        }
        claws.pullInAll(all)
        for (b, ns) in by.values {
            emit(["event": "ai_sort", "session": b.dir.path, "captures": ns])
            island.expectProcess(session: b.dir, captures: ns)
            process(b, ns, project: nil)
        }
    }

    func delete(_ s: Shot) {
        if NoteBubble.shared.shot === s { NoteBubble.shared.cancel() }
        claws.drop(s)
        s.batch?.delete(s)
    }

    func deleteAllCards() {
        NoteBubble.shared.cancel()
        for (i, s) in cards.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(i)) { self.delete(s) }
        }
    }

    private func queue(_ b: ShotBatch, project: String, n: Int, after: TimeInterval) {
        let key = b.dir.path + "\u{1}" + project
        var ns = [n]
        if let q = queued[key] { q.timer.invalidate(); ns = q.ns + [n] }
        island.expectProcess(session: b.dir, captures: ns)
        let t = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in
            guard let self = self, let q = self.queued.removeValue(forKey: key) else { return }
            self.process(q.batch, q.ns, project: q.project)
        }
        queued[key] = (b, project, ns, t)
    }

    private func process(_ b: ShotBatch, _ ns: [Int], project: String?) {
        b.sync {
            emit(["event": "process", "session": b.dir.path, "captures": ns, "project": project ?? NSNull()])
            AppEnvironment.process?(b.dir, ns, project)
        }
    }

    /// Cards come back after a restart: every inbox batch of the last 30 days with unassigned captures.
    func restore() {
        let root = ProjectStore.shared.inbox.store.appendingPathComponent("sessions")
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("-shots") }
            .filter { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) > cutoff }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for d in dirs {
            guard let b = ShotBatch.load(d), b.live.contains(where: \.isCard) else { continue }
            b.onChange = { claws.refresh() }
            cardBatches.append(b)
        }
        claws.refresh(quiet: true)
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
            claws.catchCapture(shot, from: nil)
            settled(shot)
        }
    }

    private func isScreenCapture(_ url: URL) -> Bool {
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let v = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool { return v }
        let n = url.lastPathComponent.lowercased()
        return n.hasPrefix("screenshot") || n.hasPrefix("screen shot") || n.hasPrefix("截屏") || n.hasPrefix("屏幕快照")
    }
}

let snapper = Snapper()
