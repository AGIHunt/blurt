// What a shot card hands to other apps (v0.8.1; BlurtCore CardFiles has the why): the files a drag or a copy carries,
// written next to the capture, and the pasteboard items built from BlurtCore CardPasteboard's layout.
//
//   <batch>/out/<NNN>/截图-153012.png       the picture (inked if marked) with the note in its PNG Description — and,
//                                            with record.drag_caption on, the note burned in as a strip under it (a
//                                            copy: the capture itself stays clean)
//   <batch>/out/<NNN>/截图-153012-备注.md   the note, then ![截图](截图-153012.png)
// Written again on every drag / copy (the note may have been edited); they live as long as the capture does — taken
// captures keep them for their 7 days (an app that took the file may read it late) and they go to the Trash with it.
//
// After a drop that another app took, the note also goes on the clipboard (record.drag_copy_note, default on): if that
// app kept only the picture, ⌘V brings the words back. The clipboard as it was is kept, and Undo puts it back while
// nothing else has been copied since (DragClipboard).

import AppKit
import BlurtCore
import UniformTypeIdentifiers

enum CardExport {
    struct Files { var image: URL?; var note: URL? }

    /// record.drag_caption: the dragged / copied picture gets the note burned in under it (off by default).
    static var burnCaption: Bool { recordConfig()["drag_caption"] as? Bool ?? false }
    /// record.drag_copy_note: after a card with a note is dragged out, the note goes on the clipboard (on by default).
    static var copyNoteAfterDrag: Bool { recordConfig()["drag_copy_note"] as? Bool ?? true }

    /// The picture and the note's .md for `s` (a shot), freshly written; a voice card has none (it is its words).
    static func prepare(_ s: Shot) -> Files {
        guard s.kind == .shot, let b = s.batch, let src = s.bestURL, src.pathExtension.lowercased() == "png" else { return Files() }
        let dir = b.outDir(s)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = CardFiles.stem(prefix: Loc.t("capture.file.shot", table: "Capture"), wall: Date(timeIntervalSince1970: s.wall))
        let imgURL = dir.appendingPathComponent(CardFiles.imageName(stem: stem))
        let note = s.words
        // stale names (the language changed, the note went away) don't linger next to the new ones
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f != imgURL {
            try? fm.removeItem(at: f)
        }
        var image: URL? = nil
        if var data = try? Data(contentsOf: src) {
            if burnCaption, let n = note, let img = loadCGImage(src), let cap = captioned(img, note: n),
               let d = pngData(cap, scale: s.scale) { data = d }
            if let n = note, let d = PNGText.withText(data, text: n) { data = d }
            if (try? data.write(to: imgURL, options: .atomic)) != nil { image = imgURL }
        }
        if image == nil { image = src }          // couldn't write the copy: the capture's own file
        var noteURL: URL? = nil
        if let n = note {
            let u = dir.appendingPathComponent(CardFiles.noteName(stem: stem, noteWord: Loc.t("capture.file.note", table: "Capture")))
            let md = CardFiles.markdown(note: n, imageName: image?.lastPathComponent, imageLabel: Loc.t("capture.file.shot", table: "Capture"))
            if (try? md.write(to: u, atomically: true, encoding: .utf8)) != nil { noteURL = u }
        }
        return Files(image: image, note: noteURL)
    }

    /// CardPasteboard items → NSPasteboardItems. `copy`: the picture's bytes as PNG + TIFF (a paste); else PNG (a drag).
    /// `tag`: the capture's own type on the first item ("<batch dir>\n<n>"), for a drop on a project in the island.
    static func pasteboardItems(_ items: [CardPasteboard.Item], copy: Bool, tag: String?) -> [NSPasteboardItem] {
        items.map { it in
            let p = NSPasteboardItem()
            if let f = it.file { p.setString(f.absoluteString, forType: .fileURL) }
            if it.imageData, let f = it.file, let d = try? Data(contentsOf: f) {
                p.setData(d, forType: .png)
                if copy, let tiff = NSImage(data: d)?.tiffRepresentation { p.setData(tiff, forType: .tiff) }
            }
            if let t = it.text { p.setString(t, forType: .string) }
            if it.tag, let t = tag { p.setString(t, forType: capturePasteboardType) }
            return p
        }
    }

    static func tag(_ s: Shot) -> String? { s.batch.map { "\($0.dir.path)\n\(s.n)" } }

    /// What dragging `s` out carries (BlurtCore CardPasteboard.drag).
    static func dragItems(_ s: Shot) -> [NSPasteboardItem] {
        let f = prepare(s)
        let layout = CardPasteboard.drag(image: f.image, noteFile: f.note, note: s.copyText)
        let items = pasteboardItems(layout, copy: false, tag: tag(s))
        return items.isEmpty ? [{ let p = NSPasteboardItem(); if let t = tag(s) { p.setString(t, forType: capturePasteboardType) }; return p }()] : items
    }

    /// A click's copy of `s`: the same things as a drag, the text with its line breaks (CardPasteboard.copy).
    @discardableResult
    static func copy(_ s: Shot, to pb: NSPasteboard = capturePasteboard) -> Bool {
        let f = prepare(s)
        let items = pasteboardItems(CardPasteboard.copy(image: f.image, noteFile: f.note, note: s.copyText), copy: true, tag: nil)
        guard !items.isEmpty else { return false }
        pb.clearContents()
        return pb.writeObjects(items)
    }

    // MARK: the caption strip (record.drag_caption)

    /// `img` with a strip under it holding `note` (white on near-black, the system font at ~2.2 % of the width, at most
    /// 6 lines). nil if it can't be drawn.
    static func captioned(_ img: CGImage, note: String) -> CGImage? {
        let w = img.width, h = img.height
        let fontSize = max(14, CGFloat(w) * 0.022)
        let pad = fontSize * 0.9
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.97, alpha: 1), .paragraphStyle: para]
        let text = NSAttributedString(string: note, attributes: attrs)
        let textW = CGFloat(w) - 2 * pad
        let lineH = ceil(font.ascender - font.descender + font.leading)
        let measured = ceil(text.boundingRect(with: NSSize(width: textW, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let textH = min(measured, lineH * 6)
        let strip = Int(ceil(textH + 2 * pad))
        guard let ctx = CGContext(data: nil, width: w, height: h + strip, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: strip))
        ctx.draw(img, in: CGRect(x: 0, y: strip, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(with: NSRect(x: pad, y: pad, width: textW, height: textH), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

/// The clipboard before the safety net wrote a dragged card's note on it, so Undo can give it back.
struct DragClipboard {
    let items: [[(NSPasteboard.PasteboardType, Data)]]
    let changeCount: Int

    /// The note on `pb` as plain text (its line breaks kept); the clipboard as it was kept (up to 32 MB of it).
    static func putNote(_ note: String, on pb: NSPasteboard) -> DragClipboard? {
        var saved: [[(NSPasteboard.PasteboardType, Data)]] = []
        var size = 0
        for it in pb.pasteboardItems ?? [] {
            var one: [(NSPasteboard.PasteboardType, Data)] = []
            for t in it.types {
                guard let d = it.data(forType: t) else { continue }
                size += d.count
                one.append((t, d))
            }
            saved.append(one)
        }
        pb.clearContents()
        guard pb.setString(note, forType: .string) else { return nil }
        return DragClipboard(items: size <= 32 << 20 ? saved : [], changeCount: pb.changeCount)
    }

    /// Undo: what was there before — only if the clipboard still holds our note (nothing copied since).
    func restore(_ pb: NSPasteboard) {
        guard pb.changeCount == changeCount else { return }
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { one in
            let p = NSPasteboardItem()
            for (t, d) in one { p.setData(d, forType: t) }
            return p
        })
    }
}
