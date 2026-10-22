// The island while recording (it replaced the HUD): snaps fly into it, its snap button pauses for a note, it counts
// the items live.py spots (<session>/live/drafts.jsonl) and shows the live caption line under itself
// (live/transcript.jsonl). Nothing pops up while recording (K4) — only the counts change.
import AppKit
import BlurtCore

extension Island {
    func recordingStarted(_ r: Recorder, on s: NSScreen?) {
        if !started { start() }
        if let s = s { moveTo(s) }
        let session = URL(fileURLWithPath: opts.out).deletingLastPathComponent()
        watch = RecordingWatch(session: session)
        r.snaps?.onLanded = { [weak self] s in self?.snapLanded(s) }
        recordingChanged()
    }

    func recordingStopping() {
        watch?.stop()
        watch = nil
        if NoteBubble.shared.isOpen, NoteBubble.shared.mode == .recording { NoteBubble.shared.commit() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.recordingChanged() }
        recordingChanged()
    }

    var spottedCount: Int { watch?.drafts.order.count ?? 0 }

    /// The island's snap button: a still of this moment, then the recording pauses while its note is open.
    func snapWithNote() {
        guard let r = rec else { return }
        r.snap(via: "island") { [weak self] shot in self?.openRecordingNotes(at: shot) }
    }

    /// The notes for this take's snaps (the "notes" command; the snap button lands here with its new shot).
    func openRecordingNotes(at shot: Shot? = nil) {
        guard let r = rec, let snaps = r.snaps, let s = shot ?? snaps.batch.live.last else { return }
        let wasPaused = r.isPaused
        if !wasPaused { r.togglePause() }
        let nb = NoteBubble.shared
        nb.recordingShots = snaps.batch.live
        nb.begin(s, mode: .recording, anchor: { [weak self] in self?.frameOnScreen })
        nb.onClose = { [weak r] in
            guard let r = r, !r.stopping else { return }
            if !wasPaused && r.isPaused { r.togglePause() }
        }
        refresh()
    }

    /// A snap while recording: its thumbnail flies from the recorded area into the island's right ear.
    private func snapLanded(_ s: Shot) {
        guard let r = rec, let thumb = s.thumb else { return }
        let f = frameOnScreen
        let to = NSRect(x: f.maxX - Island.earW + 8, y: f.maxY - 22, width: 26, height: 18)
        flyImage(thumb, from: toNS(r.region), to: to, duration: 0.5, polaroid: false, shrinkAway: true) { [weak self] in
            self?.bump()
            self?.refresh()
        }
    }

    func voiceChanged() {
        if !started { start() }
        if VoiceInput.shared.active { moveTo(screenUnderPointer); setOpen(true) } else { setOpen(false) }
        refresh()
    }

    func projectChanged() {
        ProjectStore.shared.reload()
        // a change in the middle of a take: that session now belongs to the new project (K2)
        if let r = rec, r.sessionStart.isValid {
            let meta = URL(fileURLWithPath: opts.out).deletingLastPathComponent().appendingPathComponent("meta.json")
            var m = (try? JSONSerialization.jsonObject(with: Data(contentsOf: meta))) as? [String: Any] ?? [:]
            m["project"] = ProjectStore.shared.currentID ?? NSNull()
            if let d = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: meta) }
        }
        emit(["event": "project", "current": ProjectStore.shared.currentID ?? "auto"])
        refresh()
    }

    func dismissToast() {
        clearToast()
        refresh()
    }
}

/// Follows a recording's live/ sidecar: the drafts live.py spots and the latest caption line.
final class RecordingWatch {
    let drafts: DraftsWatcher
    private let transcript: JSONLTail
    private let caption = CaptionPanel()
    private var timer: Timer?
    private var last = ""
    private var pending: String?

    init(session: URL) {
        drafts = DraftsWatcher(session: session)
        transcript = JSONLTail(session.appendingPathComponent("live/transcript.jsonl"))
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let before = drafts.order.count
        drafts.poll()
        if drafts.order.count != before { island.refresh() }
        if let l = transcript.poll().last, let text = l["text"] as? String { pending = text }
        // a sentence that closes while paused is shown on resume rather than dropped
        guard liveCaptionOn, let text = pending, let r = island.rec, !r.isPaused else { return }
        pending = nil
        guard text != last else { return }
        last = text
        caption.show(text, under: island.frameOnScreen)
    }

    func stop() {
        timer?.invalidate()
        caption.close()
    }
}
