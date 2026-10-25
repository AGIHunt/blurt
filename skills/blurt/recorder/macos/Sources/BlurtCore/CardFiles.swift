// What a shot card hands to other apps as files, and how long a card that was dragged out stays findable (v0.8.1).
//
// The report (v0.8.1): a snap card (picture + note) dragged into Claude — the desktop app, Chromium/Electron — showed
// "2" on the drag badge, but only the picture arrived. A web app's drop handler gets `dataTransfer.files` and a
// separate `getData('text/plain')`; when there are files it attaches them and ignores the loose text. The note then
// travelled as a .md file next to the picture — until v0.8.5, when the note is pasted into the composer after the
// picture instead (CardDropTarget.swift has the table) and the .md is an option (record.drag_note_file, off) and
// what a terminal gets:
//   • <stem>.png        the picture (inked if marked) — its note also in the PNG's own "Description" (an iTXt chunk:
//                       UTF-8, what Preview / exiftool / an image pipeline read); never relied on, it just doesn't hurt.
//   • <stem>-备注.md     the note and nothing else — line breaks kept, no heading, no image line (v0.8.2: the image line
//                       was noise wherever the .md was opened; the picture travels next to it anyway).
// stem = "<Screenshot>-HHMMSS" in the UI language ("截图-153012"), from when it was captured; one folder per capture,
// so two captures in the same second never collide. CardPasteboard says which pasteboard item carries what.
//
// A card dragged out and taken by another app is "taken", not discarded: it leaves its thread but stays findable for
// TakenCaptures.keepDays (the island's right-click "Recently Taken", the main window), then housekeeping trashes it.
// Its rows (and VoiceOver) name it by when it was taken, as the Mac writes times (CaptureTime: 12/24-hour, the day
// for anything before today).

import Foundation

public enum CardFiles {
    /// "截图-153012": the prefix ("Screenshot" / "截图"), then the local time it was captured.
    public static func stem(prefix: String, wall: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute, .second], from: wall)
        return safeName(prefix) + "-" + String(format: "%02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    public static func imageName(stem: String) -> String { stem + ".png" }

    /// "截图-153012-备注.md" / "Screenshot-153012-note.md"
    public static func noteName(stem: String, noteWord: String) -> String { stem + "-" + safeName(noteWord) + ".md" }

    /// The .md: the note as it was typed / said — line breaks kept, nothing added (no heading, no image line). Ends
    /// with one newline.
    public static func markdown(note: String) -> String {
        note.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// A file name piece without what a file system or a shell-quoting app might trip over.
    public static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}").union(.controlCharacters).union(.newlines)
        let kept = s.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
        let t = kept.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "capture" : t
    }
}

/// The note inside the PNG itself: an iTXt "Description" chunk (UTF-8, uncompressed) — ImageIO reads it as
/// kCGImagePropertyPNGDescription. Inserted before the first IDAT; an older Description (tEXt / iTXt / zTXt) is replaced.
public enum PNGText {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// `png` with `text` as its `keyword` chunk; nil if `png` isn't a PNG.
    public static func withText(_ png: Data, keyword: String = "Description", text: String) -> Data? {
        let bytes = [UInt8](png)
        guard bytes.count > 8, Array(bytes[0..<8]) == signature else { return nil }
        var out = Data(signature)
        var i = 8
        var inserted = false
        let kw = Array(keyword.utf8.prefix(79))
        while i + 8 <= bytes.count {
            let len = Int(UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3]))
            let type = String(bytes: bytes[i + 4..<i + 8], encoding: .ascii) ?? ""
            let end = i + 12 + len
            guard end <= bytes.count else { return nil }
            let body = bytes[i + 8..<i + 8 + len]
            let isOld = ["tEXt", "iTXt", "zTXt"].contains(type) && Array(body.prefix(kw.count + 1)) == kw + [0]
            // before the image data (ImageIO reads text chunks only up to the first IDAT), else before IEND
            if type == "IDAT" || type == "IEND", !inserted {
                // iTXt: keyword, 0, compression flag 0, method 0, language tag "", 0, translated keyword "", 0, text
                var data = kw + [0, 0, 0, 0, 0]
                data += Array(text.utf8)
                out.append(chunk("iTXt", data))
                inserted = true
            }
            if !isOld { out.append(contentsOf: bytes[i..<end]) }
            i = end
            if type == "IEND" { break }
        }
        return inserted ? out : nil
    }

    /// The `keyword` text chunk's text (tEXt or uncompressed iTXt), nil if there is none.
    public static func text(_ png: Data, keyword: String = "Description") -> String? {
        let bytes = [UInt8](png)
        guard bytes.count > 8, Array(bytes[0..<8]) == signature else { return nil }
        let kw = Array(keyword.utf8) + [0]
        var i = 8
        while i + 8 <= bytes.count {
            let len = Int(UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3]))
            let type = String(bytes: bytes[i + 4..<i + 8], encoding: .ascii) ?? ""
            guard i + 12 + len <= bytes.count else { return nil }
            let body = Array(bytes[i + 8..<i + 8 + len])
            if body.starts(with: kw) {
                if type == "tEXt" { return String(bytes: body[kw.count...], encoding: .isoLatin1) }
                if type == "iTXt", body.count >= kw.count + 2, body[kw.count] == 0 {
                    var j = kw.count + 2
                    for _ in 0..<2 { while j < body.count, body[j] != 0 { j += 1 }; j += 1 }   // language tag, translated keyword
                    return j <= body.count ? String(decoding: body[j...], as: UTF8.self) : nil
                }
            }
            if type == "IEND" { break }
            i += 12 + len
        }
        return nil
    }

    static func chunk(_ type: String, _ data: [UInt8]) -> Data {
        var d = Data()
        let n = UInt32(data.count)
        d.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        let td = Array(type.utf8) + data
        d.append(contentsOf: td)
        let c = crc32(td)
        d.append(contentsOf: [UInt8(c >> 24), UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF)])
        return d
    }

    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

/// Which pasteboard item carries what, for cards copied (a click, Copy All) or one card dragged out. A copy is rich
/// content (v0.8.3), the way copying a picture-and-text message in WeChat or Notes does; a drag is rich only into a
/// rich app, the picture alone elsewhere (v0.8.5). Each item is one "thing" to the receiving app; the order is the
/// order things arrive in.
///
/// The rich flavours (CardRich in the app; the HTML here, CardPasteboard.html) carry every card of the payload, in
/// order — the picture, then its note:
///   public.html            <img src="data:image/png;base64,…"> then <p>the note</p>: Chromium / Electron editors
///                          (Feishu / Lark, Claude, Slack, Notion…) and WebKit read HTML on paste and on drop
///   com.apple.flat-rtfd    the picture as an attachment, then the note: what an AppKit text view (Notes, TextEdit,
///                          Mail) reads first. Not WeChat 4 (Qt: it takes the TIFF and nothing else), and a web
///                          composer that sees a pasted image uploads it and drops the rest — so ⌘V in a chat app
///                          pastes the picture and the note one after the other (CardSmartPaste.swift)
///   public.rtf             the notes alone (RTF has no pictures): what Chromium turns into HTML when there is none
/// next to them the picture's bytes (PNG; a copy adds TIFF) and the notes as plain text.
///
/// Measured with our own stand-ins (rlab: a rich NSTextView, a WKWebView contenteditable, a terminal pad, a file pad):
///  • the NSTextView reads RTFD before anything else, on paste and on drop: picture and note, whatever else is there.
///    It does not add a later item's file (no second picture, no .md attachment) — but it does add a later item's text
///    (the note twice), so no item after the rich one carries text.
///  • WebKit: with a file URL anywhere on the pasteboard a paste exposes "Files" and the HTML but no text/plain, and
///    its default insertion inserts nothing; without one it renders the <img> (data: URLs up to 27 MB tested) and the
///    note. So a single card's copy carries no file URL.
///  • Chromium (from its clipboard_mac source, not measured here): HTML from public.html; files from every item's file
///    URL; image/png ("image.png") only when there are no files — one picture, the first item's.
public enum CardPasteboard {
    /// One card as it travels: its picture (a shot; nil for a voice card), its note, the note's .md (if written).
    public struct Card: Equatable {
        public var image: URL?
        public var note: String?
        public var noteFile: URL?
        public init(image: URL?, note: String?, noteFile: URL? = nil) {
            self.image = image; self.note = note; self.noteFile = noteFile
        }
    }

    public struct Item: Equatable {
        /// a file (public.file-url): a picture, or the note's .md
        public var file: URL?
        /// this picture's bytes: PNG (a drag) / PNG + TIFF (a copy)
        public var image: URL?
        /// the payload's cards as rich text: HTML, RTFD, RTF
        public var rich: Bool = false
        /// plain text (public.utf8-plain-text)
        public var text: String?
        /// the capture's own type (dev.blurt.capture), for a drop on a project in the island — and, alone, an item
        /// no other app reads (a drag's second item when the app takes everything from the first)
        public var tag: Bool = false

        public init(file: URL? = nil, image: URL? = nil, rich: Bool = false, text: String? = nil, tag: Bool = false) {
            self.file = file; self.image = image; self.rich = rich; self.text = text; self.tag = tag
        }
    }

    /// One card dragged into an app of class `target` (DropTargets; the table is in CardDropTarget.swift):
    ///  • rich (Notes, TextEdit, Mail…): the rich item — the picture's file, its bytes, the rich text, the note as one
    ///    line (CardTransfer.dragText) — and an inert second item: the text view takes picture and note from the RTFD.
    ///  • chat (browsers, Electron apps, WeChat, QQ, any other app) and the Finder: the picture alone (its file and
    ///    bytes) — no HTML, no RTFD, no text, so every composer ends up with the picture and nothing else; the note is
    ///    pasted after the drop (CardSmartPaste.swift). Then the note's .md only with `attachNote`
    ///    (record.drag_note_file), else an inert item.
    ///  • terminal: the picture's path and the .md's path, nothing else (no text ever reaches a shell; Claude Code and
    ///    Codex read the .md).
    /// The number of items is fixed when the drag starts (the badge counts them), so a shot with a note always has two
    /// — the second inert where it carries nothing. A voice card: its words (one line), nothing else, for every app.
    public static func drag(for target: DropClass, card: Card, attachNote: Bool = false) -> [Item] {
        let text = CardTransfer.dragText(card.note)
        guard let img = card.image else { return text.map { [Item(text: $0, tag: true)] } ?? [] }
        let first: Item
        switch target {
        case .terminal: first = Item(file: img, tag: true)
        case .chat, .finder: first = Item(file: img, image: img, tag: true)
        case .rich: first = Item(file: img, image: img, rich: true, text: text, tag: true)
        }
        guard text != nil else { return [first] }
        let md = card.noteFile.map { Item(file: $0) }
        switch target {
        case .terminal: return [first, md ?? Item(tag: true)]
        case .chat, .finder: return [first, attachNote ? md ?? Item(tag: true) : Item(tag: true)]
        case .rich: return [first, Item(tag: true)]
        }
    }

    /// A copy (a click on a card, a ⌘-click selection, Copy All): one rich item with every card, in order — the first
    /// picture's bytes, the rich text, the notes as text with their line breaks (pasting is the user's own act, at a
    /// place they chose). No file URL for a single picture (WebKit then pastes nothing: see above); with two or more,
    /// each picture's file too (the first on the rich item, the others an item each), or Chromium editors would see
    /// only the first one. A voice card alone is its words.
    public static func copy(_ cards: [Card]) -> [Item] {
        let notes = cards.compactMap { CardNote.clean($0.note) }
        let text = notes.isEmpty ? nil : notes.joined(separator: "\n\n")
        let images = cards.compactMap(\.image)
        guard let first = images.first else { return text.map { [Item(text: $0)] } ?? [] }
        if images.count < copyFilesFrom { return [Item(image: first, rich: true, text: text)] }
        return [Item(file: first, image: first, rich: true, text: text)] + images.dropFirst().map { Item(file: $0) }
    }

    /// From how many pictures a copy also carries their files (1: always; Int.max: never) — the one knob to turn if a
    /// real app's copy (WeChat's, say) turns out to do it the other way.
    public static let copyFilesFrom = 2

    // MARK: the HTML

    /// One card in the HTML: its picture as a data: URL (`mime`, its bytes, its size in points) and its note.
    public struct HTMLPart: Equatable {
        public var image: (mime: String, data: Data, width: Int, height: Int)?
        public var note: String?
        public init(image: (mime: String, data: Data, width: Int, height: Int)?, note: String?) { self.image = image; self.note = note }
        public static func == (a: HTMLPart, b: HTMLPart) -> Bool {
            a.note == b.note && a.image?.mime == b.image?.mime && a.image?.data == b.image?.data
                && a.image?.width == b.image?.width && a.image?.height == b.image?.height
        }
    }

    /// The cards as an HTML fragment, the way a browser copies one: a charset first (WebKit guesses Latin-1 without
    /// it), then per card `<p><img …></p>` and the note as `<p>` with `<br>` between its lines.
    public static func html(_ parts: [HTMLPart]) -> String {
        var s = "<meta charset=\"utf-8\">"
        for p in parts {
            if let i = p.image {
                s += "<p><img src=\"data:\(i.mime);base64,\(i.data.base64EncodedString())\" width=\"\(i.width)\" height=\"\(i.height)\"></p>"
            }
            if let n = CardNote.clean(p.note) {
                let lines = n.components(separatedBy: .newlines).map(escape)
                s += "<p>" + lines.joined(separator: "<br>") + "</p>"
            }
        }
        return s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A picture bigger than this goes into the HTML as a JPEG (the PNG still travels as a file / PNG): a data: URL
    /// several MB long makes some editors slow to paste (WebKit rendered 27 MB in the stand-in).
    public static let htmlPNGLimit = 3 << 20
}

/// A card dragged out into another app, and taken there: off its thread, but not gone — kept `keepDays`, then trashed.
public enum TakenCaptures {
    public static let keepDays: Double = 7
    static var keep: Double { keepDays * 86400 }

    /// Still in "Recently Taken" (`taken` and `now`: seconds since 1970).
    public static func isRecent(taken: Double, now: Double) -> Bool { now - taken < keep }
    /// Past its days: housekeeping moves its files to the Trash.
    public static func isExpired(taken: Double, now: Double) -> Bool { !isRecent(taken: taken, now: now) }
    /// Days left before it goes (rounded up; 0 when expired).
    public static func daysLeft(taken: Double, now: Double) -> Int { max(0, Int(ceil((keep - (now - taken)) / 86400))) }
    /// A row says how long it stays only near the end (the panel's footer says "7 days" once for all of them).
    public static func saysDaysLeft(_ days: Int) -> Bool { days <= 1 }
}

/// When a capture was taken, as its plain name says it ("Snap · 7:03 PM", "Snap · Oct 24, 7:03 PM"): the time as the
/// user's Mac writes it (12- or 24-hour, the region's order), and the day too for anything before today.
public enum CaptureTime {
    public static func label(_ date: Date, now: Date, locale: Locale, calendar: Calendar = .current) -> String {
        var cal = calendar
        cal.locale = locale
        let f = DateFormatter()
        f.locale = locale
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.setLocalizedDateFormatFromTemplate(cal.isDate(date, inSameDayAs: now) ? "jm" : "MMMdjm")
        return f.string(from: date)
    }
}
