// What a shot card hands to other apps (v0.8.1; BlurtCore CardFiles has the why): the files a drag or a copy carries,
// written next to the capture, and the pasteboard items built from BlurtCore CardPasteboard's layout (a drag's items
// follow the app under the pointer: CardDrag.swift). A copy is rich — the pictures and notes as HTML, RTFD and RTF
// (CardRich), like a WeChat or Notes copy of a picture-and-text message — so ⌘V into Notes or Mail brings both at
// once; in a chat app (browsers, Electron apps, WeChat, QQ…) the ⌘V becomes picture, then note (SmartPaste.swift; a
// copy is armed for it here). The flavours and their order on an item are one list (CardExport.flavours), to match a
// real app's copy if one is measured.
//
//   <batch>/out/<NNN>/截图-153012.png       the picture (inked if marked) with the note in its PNG Description — and,
//                                            with record.drag_caption on, the note burned in as a strip under it (a
//                                            copy: the capture itself stays clean)
//   <batch>/out/<NNN>/截图-153012-备注.md   the note, and nothing else (v0.8.2): what a terminal gets next to the
//                                            picture's path, and — record.drag_note_file, off — a chat app or the
//                                            Finder too
// Written again on every drag / copy (the note may have been edited); they live as long as the capture does — taken
// captures keep them for their 7 days (an app that took the file may read it late) and they go to the Trash with it.
//
// After a drop that another app took, the note also goes on the clipboard (record.drag_copy_note, default on) where
// it didn't go in (BlurtCore DragReceipt.copiesNote: the picture alone — the paste after it couldn't run — or not
// sure): ⌘V brings the words back. The clipboard as it was is kept, and Undo puts it back while nothing else has been
// copied since (DragClipboard).

import AppKit
import BlurtCore
import UniformTypeIdentifiers

enum CardExport {
    struct Files { var image: URL?; var note: URL? }

    /// record.drag_caption: the dragged / copied picture gets the note burned in under it (off by default).
    static var burnCaption: Bool { recordConfig()["drag_caption"] as? Bool ?? false }
    /// record.drag_copy_note: after a card with a note is dragged out and its note didn't go in, the note goes on the
    /// clipboard (on by default).
    static var copyNoteAfterDrag: Bool { recordConfig()["drag_copy_note"] as? Bool ?? true }
    /// record.drag_note_file: a card dragged into a chat app or the Finder also carries its note as a .md file (off by
    /// default; a terminal always gets the .md's path).
    static var attachNoteFile: Bool { recordConfig()["drag_note_file"] as? Bool ?? false }

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
            let md = CardFiles.markdown(note: n)
            if (try? md.write(to: u, atomically: true, encoding: .utf8)) != nil { noteURL = u }
        }
        return Files(image: image, note: noteURL)
    }

    /// The flavours an item can carry, in the order they are put on it: the richest first (an app that takes the first
    /// type it knows gets picture and note), the file last but the capture's own tag.
    enum Flavour: CaseIterable { case rtfd, html, rtf, png, tiff, text, file, tag }
    static let flavours: [Flavour] = Flavour.allCases

    static func type(_ f: Flavour) -> NSPasteboard.PasteboardType {
        switch f {
        case .rtfd: return .rtfd
        case .html: return .html
        case .rtf: return .rtf
        case .png: return .png
        case .tiff: return .tiff
        case .text: return .string
        case .file: return .fileURL
        case .tag: return capturePasteboardType
        }
    }

    /// The flavours `it` carries (`copy`: TIFF next to the PNG; `tag`: there is a tag to give).
    static func flavours(_ it: CardPasteboard.Item, copy: Bool, tag: Bool) -> [Flavour] {
        flavours.filter { f in
            switch f {
            case .rtfd, .html, .rtf: return it.rich
            case .png: return it.image != nil
            case .tiff: return copy && it.image != nil
            case .text: return it.text != nil
            case .file: return it.file != nil
            case .tag: return it.tag && tag
            }
        }
    }

    /// One flavour of `it`, as data (nil: none to give).
    static func data(_ f: Flavour, of it: CardPasteboard.Item, rich: CardRich?, tag: String?) -> Data? {
        switch f {
        case .rtfd: return it.rich ? rich?.rtfd : nil
        case .html: return it.rich ? rich.map { Data($0.html.utf8) } : nil
        case .rtf: return it.rich ? rich?.rtf : nil
        case .png: return it.image.flatMap { try? Data(contentsOf: $0) }
        case .tiff: return it.image.flatMap { try? Data(contentsOf: $0) }.flatMap { NSBitmapImageRep(data: $0)?.tiffRepresentation(using: .lzw, factor: 0) }
        case .text: return it.text.map { Data($0.utf8) }
        case .file: return it.file.map { Data($0.absoluteString.utf8) }
        case .tag: return it.tag ? tag.map { Data($0.utf8) } : nil
        }
    }

    /// CardPasteboard items → NSPasteboardItems, written at once. `copy`: the picture's bytes as PNG + TIFF (a paste);
    /// else PNG (a drag). `tag`: the capture's own type ("<batch dir>\n<n>"), for a drop on a project in the island.
    static func pasteboardItems(_ items: [CardPasteboard.Item], rich: CardRich?, copy: Bool, tag: String?) -> [NSPasteboardItem] {
        items.map { it in
            let p = NSPasteboardItem()
            for f in flavours(it, copy: copy, tag: tag != nil) {
                if let d = data(f, of: it, rich: rich, tag: tag) { p.setData(d, forType: type(f)) }
            }
            return p
        }
    }

    static func tag(_ s: Shot) -> String? { s.batch.map { "\($0.dir.path)\n\(s.n)" } }

    /// A shot or voice card as it travels (its files freshly written).
    static func card(_ s: Shot) -> (CardPasteboard.Card, CardRich.Part) {
        let f = prepare(s)
        return (CardPasteboard.Card(image: f.image, note: s.copyText, noteFile: f.note),
                CardRich.Part(image: f.image, note: s.copyText, scale: s.scale))
    }

    /// What dragging `s` out over the app `landing` describes carries (BlurtCore CardPasteboard.drag(into:)), written at
    /// once — for tests (`carddrag`); a real drag is lazy and follows the pointer (CardDrag).
    static func dragItems(_ s: Shot, into landing: DragLanding) -> [NSPasteboardItem] {
        let (c, part) = card(s)
        let items = pasteboardItems(CardPasteboard.drag(into: landing, card: c, attachNote: attachNoteFile), rich: CardRich([part]),
                                    copy: false, tag: tag(s))
        return items.isEmpty ? [{ let p = NSPasteboardItem(); if let t = tag(s) { p.setString(t, forType: capturePasteboardType) }; return p }()] : items
    }

    /// A copy of `shots`, in order (a click: one; a ⌘-click selection or Copy All: several) — one rich item with every
    /// picture and note, the notes as text with their line breaks (CardPasteboard.copy). Returns the items written.
    /// On the clipboard, the copy is armed for smart paste (SmartPaste.swift): ⌘V in a chat app within 2 minutes pastes
    /// each picture and then its note, and writes this copy back afterwards.
    @discardableResult
    static func copy(_ shots: [Shot], to pb: NSPasteboard = capturePasteboard) -> [NSPasteboardItem]? {
        let cards = shots.map(card)
        let layout = CardPasteboard.copy(cards.map(\.0))
        let rich = CardRich(cards.map(\.1))
        let write = { () -> [NSPasteboardItem]? in
            let items = pasteboardItems(layout, rich: rich, copy: true, tag: nil)
            guard !items.isEmpty else { return nil }
            pb.clearContents()
            return pb.writeObjects(items) ? items : nil
        }
        guard let items = write() else { return nil }
        if pb === capturePasteboard { SmartPaste.shared.armed(cards: cards.map(\.0)) { write() != nil } }
        return items
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

/// The rich flavours of a payload — every card, in order: HTML (the picture as a data: URL, then the note), RTFD (the
/// picture as an attachment, then the note), RTF (the notes) — built when first asked for, once.
final class CardRich {
    struct Part { var image: URL?; var note: String?; var scale: CGFloat }
    let parts: [Part]
    init(_ parts: [Part]) { self.parts = parts }

    lazy var html: String = CardPasteboard.html(parts.map { p in
        CardPasteboard.HTMLPart(image: p.image.flatMap { CardRich.htmlImage($0, scale: p.scale) }, note: p.note)
    })

    lazy var rtfd: Data? = {
        let s = attributed(withPictures: true)
        return s.length == 0 ? nil : s.rtfd(from: NSRange(location: 0, length: s.length), documentAttributes: [:])
    }()

    lazy var rtf: Data? = {
        let s = attributed(withPictures: false)
        return s.length == 0 ? nil : s.rtf(from: NSRange(location: 0, length: s.length), documentAttributes: [:])
    }()

    /// The picture for the HTML: the PNG, or — past CardPasteboard.htmlPNGLimit — a JPEG of it; its size in points.
    static func htmlImage(_ u: URL, scale: CGFloat) -> (mime: String, data: Data, width: Int, height: Int)? {
        guard let d = try? Data(contentsOf: u), let rep = NSBitmapImageRep(data: d) else { return nil }
        let k = max(1, scale)
        let w = Int((CGFloat(rep.pixelsWide) / k).rounded()), h = Int((CGFloat(rep.pixelsHigh) / k).rounded())
        if d.count > CardPasteboard.htmlPNGLimit, let j = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
            return ("image/jpeg", j, w, h)
        }
        return ("image/png", d, w, h)
    }

    /// Picture, line break, note — the cards one after another (a blank line between them). No colour: the receiving
    /// app's own text colour (dark mode) applies.
    private func attributed(withPictures: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        for p in parts {
            var piece: [NSAttributedString] = []
            if withPictures, let u = p.image, let w = try? FileWrapper(url: u, options: .immediate) {
                w.preferredFilename = u.lastPathComponent
                let a = NSTextAttachment(fileWrapper: w)
                if let rep = w.regularFileContents.flatMap(NSBitmapImageRep.init(data:)) {
                    let k = max(1, p.scale)
                    a.bounds = CGRect(x: 0, y: 0, width: CGFloat(rep.pixelsWide) / k, height: CGFloat(rep.pixelsHigh) / k)
                }
                piece.append(NSAttributedString(attachment: a))
            }
            if let n = CardNote.clean(p.note) { piece.append(NSAttributedString(string: n, attributes: font)) }
            guard !piece.isEmpty else { continue }
            if out.length > 0 { out.append(NSAttributedString(string: "\n\n", attributes: font)) }
            for (i, x) in piece.enumerated() {
                if i > 0 { out.append(NSAttributedString(string: "\n", attributes: font)) }
                out.append(x)
            }
        }
        return out
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
