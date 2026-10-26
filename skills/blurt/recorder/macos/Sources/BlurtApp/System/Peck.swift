// The completion chick (K7 / K8): when an item reaches "to verify" (an agent says it's fixed) or "done" (you confirmed
// it), the island shows one quiet line with the chick beside it — never a window of its own, never one per item: news
// within 10 s of each other becomes one line ("3 items to verify"). Click = that item (or the inbox).
//
// The chick is the mascot, the brand's chick in colour (Icons/Mascot.swift, drawn and moved in code):
//   to verify   it spots a bug, pounces on it, the bug goes in a sparkle, a happy hop back (`peck`)
//   done        two happy hops, wings up, ^ ^ eyes, sparkles (`happy`)
// Reduce Motion: the clip's still moment.
import AppKit
import BlurtCore

/// "Fixed" news: the chick in the island. One line per 10 s, however many items arrived in it.
final class PeckCard: NSObject {
    static let shared = PeckCard()
    private var pending: [(title: String, uid: String, state: String)] = []
    private var flush: DispatchWorkItem?
    private var lastShown: CFTimeInterval = -100
    var leadIn: Double = 0.15          // tests that record the screen want a longer one

    /// `state`: "to_verify" (an agent says it's handled) | "done" (you confirmed it).
    func play(title: String, detail: String, uid: String, state: String = "to_verify") {
        pending.append((title, uid, state))
        emit(["event": "peck", "uid": uid, "title": title, "state": state])
        flush?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.show() }
        flush = w
        // the first one shows right away; more within the next 10 s gather into one line
        let wait = CACurrentMediaTime() - lastShown > 10 ? 0.4 : 10 - (CACurrentMediaTime() - lastShown)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
    }

    private func show() {
        guard !pending.isEmpty else { return }
        let items = pending
        pending = []
        lastShown = CACurrentMediaTime()
        let done = items.allSatisfy { $0.state == "done" }
        // two lines: what it is about (the item's title, or how many), then the state in words with its mark — ✓ done
        // in ok green, "!" to verify in attention amber, as the main list marks them (never the animation alone)
        let state = Loc.t(done ? "capture.peck.state_done" : "capture.peck.state_verify", table: "Capture")
        let text: String
        if items.count == 1 {
            text = items[0].title + "\n" + state
        } else {
            text = Loc.plural(done ? "capture.peck.done_many" : "capture.peck.verify_many", table: "Capture", count: items.count)
                + "\n" + Loc.t("capture.peck.open_inbox", table: "Capture")
        }
        let clip: MascotClip = done ? .happy : .peck
        let chick = MascotView(clip: clip, size: 34, backdrop: .dark)
        chick.show(clip, frame: 0)
        let uid = items.count == 1 ? items[0].uid : nil
        var t = Island.Toast(text: text, actionTitle: nil, action: {
            if let u = uid { _ = URLRouter.handle(URL(string: "blurt://item/\(u)")!) } else { AppEnvironment.mainWindow?.showInbox() }
        })
        t.art = chick
        if items.count == 1 {
            t.detailMark = done ? ("checkmark", BrandColor.Island.ok) : ("exclamationmark", BrandColor.Island.attn)
        }
        t.seconds = max(3.4, (MascotLibrary.shared.clip(clip)?.duration ?? 2) + leadIn + 1)
        island.toast(t)
        MenuGlyph.shared.hop()
        DispatchQueue.main.asyncAfter(deadline: .now() + leadIn) { chick.play(clip) }
    }

    /// The clip at 12 fps as 80 pt PNGs (× `scale` pixels) on a light or dark backdrop (docs / tests make GIFs of them).
    static func renderFrames(to dir: URL, clip: MascotClip = .peck, scale: CGFloat = 2, dark: Bool = false) -> Int {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bg = dark ? CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) : CGColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1)
        let frames = MascotLibrary.shared.timelineFrames(clip, points: 80, scale: scale, dark: dark, backdrop: bg)
        for (i, f) in frames.enumerated() {
            let rep = NSBitmapImageRep(cgImage: f)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(String(format: "f%03d.png", i)))
        }
        return frames.count
    }
}
