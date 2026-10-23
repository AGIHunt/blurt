// What a shot card hands to other apps as files, and how long a card that was dragged out stays findable (v0.8.1).
//
// The report: a snap card (picture + note) dragged into Claude — the desktop app, Chromium/Electron — showed "2" on the
// drag badge, but only the picture arrived. A web app's drop handler gets `dataTransfer.files` and a separate
// `getData('text/plain')`; when there are files it attaches them and ignores the loose text. And the card had left its
// thread, so the note was gone. Now the note can travel as a file too:
//   • <stem>.png        the picture (inked if marked) — its note also in the PNG's own "Description" (an iTXt chunk:
//                       UTF-8, what Preview / exiftool / an image pipeline read); never relied on, it just doesn't hurt.
//   • <stem>-备注.md     the note and nothing else — line breaks kept, no heading, no image line (v0.8.2: the image line
//                       was noise wherever the .md was opened; the picture travels next to it anyway).
// stem = "<Screenshot>-HHMMSS" in the UI language ("截图-153012"), from when it was captured; one folder per capture,
// so two captures in the same second never collide. CardPasteboard says which pasteboard item carries what, per kind
// of app (CardDropTarget.swift: v0.8.2, the .md only goes where it is needed).
//
// A card dragged out and taken by another app is "taken", not discarded: it leaves its thread but stays findable for
// TakenCaptures.keepDays (the island's right-click "Recently Taken", the main window), then housekeeping trashes it.

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

/// Which pasteboard item carries what, for a card dragged out or copied (click). Each item is one "thing" to the
/// receiving app; the order is the order things arrive in.
public enum CardPasteboard {
    public struct Item: Equatable {
        /// a file (public.file-url): the picture, or the note's .md
        public var file: URL?
        /// the picture's bytes ride along (a drag: PNG; a copy: PNG + TIFF) for apps that take image data, not files
        public var imageData: Bool = false
        /// the picture as RTFD (an attachment): what a rich AppKit text view reads before file names, so it inserts the
        /// picture and still reads the note's text from the next item
        public var rtfd: Bool = false
        /// plain text (public.utf8-plain-text)
        public var text: String?
        /// the capture's own type (dev.blurt.capture), for a drop on a project in the island
        public var tag: Bool = false

        public init(file: URL? = nil, imageData: Bool = false, rtfd: Bool = false, text: String? = nil, tag: Bool = false) {
            self.file = file; self.imageData = imageData; self.rtfd = rtfd; self.text = text; self.tag = tag
        }
    }

    /// A drag into an app of class `target` (DropTargets; the table is in CardDropTarget.swift). Two items for a shot
    /// with a note — the count is fixed when the drag starts, what item 2 is depends on the app it lands in:
    ///  • web / unknown: (1) the picture, file + PNG; (2) the note's .md file, and the note as text on the same item.
    ///  • text: (1) the picture, file + PNG + RTFD; (2) the note as text only — no .md.
    ///  • terminal: (1) the picture's file; (2) the .md's file — paths only, the note's text never reaches a shell.
    ///  • finder: (1) the picture, file + PNG; (2) the .md file.
    /// The text is CardTransfer.dragText (one line, no control characters): which app reads it first is the app under
    /// the pointer at that moment, not always the one it lands in. No note file (it couldn't be written): the text as
    /// the second item (a terminal: nothing). A voice card: its words, nothing else, for every app.
    public static func drag(for target: DropClass, image: URL?, noteFile: URL?, note: String?) -> [Item] {
        let text = CardTransfer.dragText(note)
        guard let img = image else { return text.map { [Item(text: $0, tag: true)] } ?? [] }
        var items: [Item]
        switch target {
        case .terminal: items = [Item(file: img)]
        case .text: items = [Item(file: img, imageData: true, rtfd: true)]
        case .web, .finder, .unknown: items = [Item(file: img, imageData: true)]
        }
        if text != nil {
            switch (target, noteFile) {
            case (.web, let f?), (.unknown, let f?): items.append(Item(file: f, text: text))
            case (.finder, let f?), (.terminal, let f?): items.append(Item(file: f))
            case (.text, _), (.web, nil), (.unknown, nil), (.finder, nil): items.append(Item(text: text))
            case (.terminal, nil): break
            }
        }
        items[0].tag = true
        return items
    }

    /// A copy (a click on the card): the picture, the note's .md and the note as text — the app it will be pasted into
    /// isn't known, so the unknown-app layout — but the text keeps the note's line breaks (pasting is the user's own
    /// act, at a place they chose).
    public static func copy(image: URL?, noteFile: URL?, note: String?) -> [Item] {
        var items: [Item] = []
        if let img = image { items.append(Item(file: img, imageData: true)) }
        let text = CardNote.clean(note)
        if let f = noteFile, image != nil, text != nil { items.append(Item(file: f, text: text)) }
        else if let t = text { items.append(Item(text: t)) }
        return items
    }
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
}
