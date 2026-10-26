// The island while recording (it replaced the HUD): snaps fly into it, its snap button pauses for a note, it counts
// the items live.py spots (<session>/live/drafts.jsonl) and shows the live caption line under itself
// (live/transcript.jsonl). Nothing pops up while recording (K4) — only the counts change.
import AppKit
import BlurtCore

/// Tests only: the fake recording whose frame BLURT_TEST_FRAME showed (it never calls stop()).
private var testFrameRecorder: Recorder?

/// The moment a take ends (Finish, ⌥⇧S): the left ear's red dot turns, in place, into the ok check on a filled disc
/// (centred where the dot was) beside the take's length at the time's own x ("✓ 0:42"), the ears keeping their width,
/// for 1.6 s — dictation's "Sent" — and only then does a toast take the island ("Filed to Atlas Web · Change": where
/// the take went; Island.canShowToast holds it back meanwhile); then the ears settle to what is next (the hatching
/// egg while it is organised, the cards). Not for a discarded or restarted take: nothing was kept.
enum RecordingDone {
    private static var until: CFTimeInterval = 0
    private static var shown = ""
    static var text: String? { CACurrentMediaTime() < until ? shown : nil }
    /// The take's end was said in the ears a moment ago: its saved line ("✓ Saved 0:42", Island.doneMoment) would
    /// say the same thing twice, so it is left out (a failure still gets its toast).
    static var saidRecently: Bool { until > 0 && CACurrentMediaTime() < until + 6 }
    static func show(_ length: String) {
        shown = length
        until = CACurrentMediaTime() + 1.6
        emit(["event": "rec_done_moment", "length": length, "seconds": 1.6])
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: Loc.t("capture.rec.done_ax", table: "Capture", length),
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        // the ears go back once the moment is over, even with nothing else moving
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.65) { island.refresh(); island.wake() }
    }
}

/// The open recording island's pen hint ("[⌃] Hold for the pen  [⌃⇧] Box  [⌃⌥] Ellipse"): the first three takes only
/// (HintBudget); after that the pen is in the island's ··· menu with its key, and the keys still work.
var penHintThisTake = false

extension Island {
    func recordingStarted(_ r: Recorder, on s: NSScreen?) {
        if !started { start() }
        if let s = s { moveTo(s) }
        penHintThisTake = r.penKey != nil && HintBudget.take("pen")
        let session = URL(fileURLWithPath: opts.out).deletingLastPathComponent()
        watch = RecordingWatch(session: session)
        r.snaps?.onLanded = { [weak self] s in self?.snapLanded(s) }
        hanging.recordingStarted()
        recordingChanged()
        // visual checks (test commands only): BLURT_TEST_FRAME=1 gives `fakerecording` the recorded area's frame too
        // (`pause` / `resume` turn it into the paused dashes and back)
        let env = ProcessInfo.processInfo.environment
        if env["BLURT_TEST_COMMANDS"] == "1", env["BLURT_TEST_FRAME"] == "1", r.border == nil {
            r.showFrame()
            testFrameRecorder = r
        }
    }

    func recordingStopping(_ ended: Recorder? = nil) {
        if let r = ended ?? rec, !r.discard, r.sessionStart.isValid { RecordingDone.show(Island.clock(r.elapsed())) }
        testFrameRecorder?.hideFrame()
        testFrameRecorder = nil
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
        let nb = NoteBubble.shared
        // one pause per note session (BlurtCore RecordingNotes): the bubble switching to another snap of this take
        // keeps the session's resume — the bubble it replaces must not resume the take under the new one
        let open = nb.isOpen && nb.mode == .recording && nb.recordingResume != nil
        let plan = RecordingNotes.open(alreadyOpen: open, carriedResume: nb.recordingResume ?? false, paused: r.isPaused)
        nb.recordingResume = nil
        nb.onClose = nil
        if plan.pause { r.togglePause() }
        nb.recordingShots = snaps.batch.live
        nb.begin(s, mode: .recording, anchor: { [weak self] in self?.frameOnScreen })
        let resume = plan.resumeOnClose
        nb.recordingResume = resume
        nb.onClose = { [weak r] in
            NoteBubble.shared.recordingResume = nil
            guard resume, let r = r, !r.stopping, r.isPaused else { return }
            r.togglePause()
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

    /// Dictation started, moved on (transcribing, polishing) or ended: the ears follow; the island stays closed.
    func dictationChanged() {
        if !started { start() }
        if Dictation.shared.busy, Dictation.shared.phase == .listening {
            moveTo(screenUnderPointer)
            // the ears say it's listening: an island left open (by a key, or the pointer on it) makes way for them
            if open, drawer == nil, !isConfirmingDiscard { setOpen(false) }
        }
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
        emit(["event": "project", "current": ProjectStore.shared.currentID ?? "inbox"])
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
