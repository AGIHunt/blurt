// Things dropped on the island hang as cards (v1.0.23, docs/design/drag-drop.md §3) — the island isn't only for snaps:
//  • a picture (a file, a browser's image, image data) → a picture card, like a snap: copied in, turned upright
//    (EXIF), its long side at most 6000 px, written as the card's PNG off the main thread
//  • any other file (a PDF, a video, a document) → a file card: its picture is the file's Quick Look thumbnail (else
//    its icon) with its name under it; the card refers to the file (shots.jsonl "ref" + a bookmark) and never moves,
//    writes or trashes it. A file in a temporary place (FilePlace) is copied into the batch first: it would be gone.
//  • text, a link → a text card
// One thing dropped: the note bubble opens beside it without taking the keyboard (NoteBubble.passive). Several: they
// hang in the order they came.

import AppKit
import BlurtCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

extension Snapper {
    /// Hang what `d` brought as cards (Unassigned, whatever the current project: "hang it" is what was asked);
    /// `project`: filed straight into that project instead (dropped on a project of the island's drawer).
    func hang(_ d: DropIn, into project: String? = nil) {
        guard Capability.cards.isOn else { return }          // no cards with Cards off: nothing hangs
        let inbox = ProjectStore.shared.inbox
        let b = openBatch(for: inbox)
        var made: [Shot] = []
        let group = DispatchGroup()
        let one = d.images.count + d.files.count + (d.text == nil ? 0 : 1) == 1
        emit(["event": "drop_hang", "images": d.images.count, "files": d.files.count, "text": d.text != nil, "project": project ?? NSNull()])
        for u in d.images {
            group.enter()
            let n = b.reserve()
            DropCards.picture(u) { img in
                guard let img else {
                    // a picture CGImageSource can't read (an SVG, a RAW it doesn't know): a file card, never lost
                    DropCards.fileCard(u, batch: b, n: n) { face, ref, mark in
                        defer { group.leave() }
                        guard let face else { return }
                        let s = b.add(n: n, image: face, scale: 2, region: CGRect(x: 0, y: 0, width: face.width / 2, height: face.height / 2),
                                      t: nil, ref: ref, refBookmark: mark)
                        s.region = []
                        made.append(s)
                    }
                    return
                }
                defer { group.leave() }
                let scale: CGFloat = 2
                let sz = CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
                let s = b.add(n: n, image: img, scale: scale, region: CGRect(origin: .zero, size: sz), t: nil)
                s.region = []
                made.append(s)
            }
        }
        for u in d.files {
            group.enter()
            let n = b.reserve()
            DropCards.fileCard(u, batch: b, n: n) { img, ref, mark in
                defer { group.leave() }
                guard let img else { return }
                let s = b.add(n: n, image: img, scale: 2, region: CGRect(x: 0, y: 0, width: img.width / 2, height: img.height / 2), t: nil,
                              ref: ref, refBookmark: mark)
                s.region = []
                made.append(s)
            }
        }
        if let t = d.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            made.append(b.addText(n: b.reserve(), text: t, project: nil))
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let shots = made.sorted { $0.n < $1.n }
            guard !shots.isEmpty else { return NSSound.beep() }
            if let p = project {
                for s in shots { hanging.catchCapture(s, from: nil) }
                self.assign(shots, to: p)
                return
            }
            for s in shots { hanging.catchCapture(s, from: nil); self.settled(s) }
            hanging.show(peek: 2.5)
            if one, let s = shots.first {
                // a note for it, offered: the bubble opens beside the card but leaves the keyboard where it is
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard s.isCard, !NoteBubble.shared.isOpen else { return }
                    NoteBubble.shared.begin(s, mode: .edit, passive: true)
                }
            }
        }
    }
}

enum DropCards {
    /// The picture at `u`, upright (EXIF) and at most `maxPixels` on its long side; off the main thread.
    static let maxPixels = 6000

    static func picture(_ u: URL, done: @escaping (CGImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var img: CGImage?
            if let src = CGImageSourceCreateWithURL(u as CFURL, nil) {
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                             kCGImageSourceShouldCacheImmediately: true]
                img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }
            DispatchQueue.main.async { done(img) }
        }
    }

    /// A file card's picture (its thumbnail with its name under it), the path it refers to (a copy in the batch when
    /// the file sits in a temporary place) and a bookmark of it.
    static func fileCard(_ u: URL, batch b: ShotBatch, n: Int, done: @escaping (CGImage?, String, String?) -> Void) {
        guard FilePlace.isTemporary(u) else { return face(u, name: u.lastPathComponent, done) }
        // a file in a temporary place: copied next to the card first, off the main thread (a long screen recording)
        let dir = b.dir.appendingPathComponent("files/\(ShotBatch.name(n))", isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent(u.lastPathComponent)
            let ok = (try? FileManager.default.copyItem(at: u, to: dst)) != nil
            DispatchQueue.main.async { face(ok ? dst : u, name: u.lastPathComponent, done) }
        }
    }

    private static func face(_ ref: URL, name: String, _ done: @escaping (CGImage?, String, String?) -> Void) {
        let mark = (try? ref.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil))?.base64EncodedString()
        let size = CGSize(width: 150, height: 120)
        let req = QLThumbnailGenerator.Request(fileAt: ref, size: CGSize(width: 140, height: 84), scale: 2,
                                               representationTypes: [.thumbnail, .icon])
        var finished = false
        let finish = { (thumb: CGImage?) in
            guard !finished else { return }
            finished = true
            let icon = thumb ?? NSWorkspace.shared.icon(forFile: ref.path).cgImage(forProposedRect: nil, context: nil, hints: nil)
            done(render(icon, name: name, size: size), ref.path, mark)
        }
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            let cg = rep?.cgImage
            DispatchQueue.main.async { finish(cg) }
        }
        // a file Quick Look takes long over (a big video, a disk asleep): its icon after 2 s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(nil) }
    }

    /// The card's face for a file: a light sheet, the thumbnail fitted in it, the name on a dark band at the bottom
    /// (middle cut), 2x.
    static func render(_ thumb: CGImage?, name: String, size: CGSize) -> CGImage? {
        let w = Int(size.width * 2), h = Int(size.height * 2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let band: CGFloat = 46
        if let t = thumb {
            let box = CGRect(x: 16, y: band + 12, width: CGFloat(w) - 32, height: CGFloat(h) - band - 24)
            let k = min(box.width / CGFloat(t.width), box.height / CGFloat(t.height))
            let r = CGRect(x: box.midX - CGFloat(t.width) * k / 2, y: box.midY - CGFloat(t.height) * k / 2,
                           width: CGFloat(t.width) * k, height: CGFloat(t.height) * k)
            ctx.interpolationQuality = .high
            ctx.draw(t, in: r)
        }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 0.92))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: Int(band)))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        para.alignment = .center
        let text = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 21, weight: .medium),
                                                                 .foregroundColor: NSColor.white, .paragraphStyle: para])
        text.draw(with: NSRect(x: 12, y: 10, width: CGFloat(w) - 24, height: 28), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
