// The completion chick (K7 / K8): when an item reaches "to verify" (an agent says it's fixed) or "done" (you confirmed
// it), the island shows one quiet line with the chick beside it — never a window of its own, never one per item: news
// within 10 s of each other becomes one line ("3 items to verify"). Click = that item (or the inbox).
//
// The chick is the colour mascot (Icons/Mascot.swift, frame animations):
//   to verify   it pecks a ladybug, which vanishes with a sparkle (`peck`)
//   done        a happy hop, wings up, sparkles (`happy`)
// Reduce Motion: the clip's still frame.
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
        let text: String
        if items.count == 1 {
            text = Loc.t(done ? "capture.peck.done_one" : "capture.peck.verify_one", table: "Capture", items[0].title)
        } else {
            text = Loc.plural(done ? "capture.peck.done_many" : "capture.peck.verify_many", table: "Capture", count: items.count)
        }
        let clip: MascotClip = done ? .happy : .peck
        let chick = MascotView(clip: clip, size: 50)
        chick.show(clip, frame: 0)
        let uid = items.count == 1 ? items[0].uid : nil
        var t = Island.Toast(text: text, actionTitle: nil, action: {
            if let u = uid { _ = URLRouter.handle(URL(string: "blurt://item/\(u)")!) } else { AppEnvironment.mainWindow?.showInbox() }
        })
        t.art = chick
        t.seconds = max(3.4, (MascotLibrary.shared.clip(clip)?.duration ?? 2) + leadIn + 1)
        island.toast(t)
        MenuGlyph.shared.hop()
        DispatchQueue.main.asyncAfter(deadline: .now() + leadIn) { chick.play(clip) }
    }

    /// The clip's frames in timeline order as PNGs on a light or dark backdrop (docs / tests make GIFs of them).
    static func renderFrames(to dir: URL, clip: MascotClip = .peck, scale: CGFloat = 1, dark: Bool = false) -> Int {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let frames = MascotLibrary.shared.timelineFrames(clip)
        for (i, f) in frames.enumerated() {
            let w = Int(CGFloat(f.width) * scale), h = Int(CGFloat(f.height) * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            ctx.setFillColor(dark ? CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) : CGColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(f, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let img = ctx.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(String(format: "f%03d.png", i)))
        }
        return frames.count
    }
}
