// What a shot card hands to other apps as files, and how long a card that was dragged out stays findable (v0.8.1).
//
// The report: a snap card (picture + note) dragged into Claude — the desktop app, Chromium/Electron — showed "2" on the
// drag badge, but only the picture arrived. A web app's drop handler gets `dataTransfer.files` and a separate
// `getData('text/plain')`; when there are files it attaches them and ignores the loose text. And the card had left its
// thread, so the note was gone. Now the note travels as a file too:
//   • <stem>.png        the picture (inked if marked) — its note also in the PNG's own "Description" (an iTXt chunk:
//                       UTF-8, what Preview / exiftool / an image pipeline read); never relied on, it just doesn't hurt.
//   • <stem>-note.md    the note, line breaks kept, then a Markdown image line pointing at the picture next to it — so
//                       an agent that reads the .md (a terminal drop types both paths) finds the picture too.
// stem = "<Screenshot>-HHMMSS" in the UI language ("截图-153012"), from when it was captured; one folder per capture,
// so two captures in the same second never collide. CardPasteboard says which pasteboard item carries what.
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

    /// The .md: the note as it was typed / said (line breaks kept, nothing else touched), a blank line, and the picture
    /// beside it as a Markdown image (relative: the two files share a folder). Ends with one newline.
    public static func markdown(note: String, imageName: String?, imageLabel: String) -> String {
        var out = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let img = imageName {
            // <…> keeps a name with spaces or brackets a valid link
            out += "\n\n![\(imageLabel.replacingOccurrences(of: "]", with: ""))](<\(img)>)"
        }
        return out + "\n"
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
        /// plain text (public.utf8-plain-text)
        public var text: String?
        /// the capture's own type (dev.blurt.capture), for a drop on a project in the island
        public var tag: Bool = false

        public init(file: URL? = nil, imageData: Bool = false, text: String? = nil, tag: Bool = false) {
            self.file = file; self.imageData = imageData; self.text = text; self.tag = tag
        }
    }

    /// A drag: (1) the picture — file + PNG; (2) the note — its .md file *and* the note as text on the same item. A web
    /// app (Chromium, Electron: Claude, Slack…) gets two files and the text; the Finder two files (no text clipping —
    /// there is no item that is only text); a text-only target the text; a terminal both paths. The text is
    /// CardTransfer.dragText (one line, no control characters): the drop may land at a shell prompt. No note file
    /// (the note couldn't be written): the text alone as the second item. A voice card: its words, nothing else.
    public static func drag(image: URL?, noteFile: URL?, note: String?) -> [Item] {
        var items: [Item] = []
        if let img = image { items.append(Item(file: img, imageData: true)) }
        let text = CardTransfer.dragText(note)
        if let f = noteFile, image != nil, text != nil { items.append(Item(file: f, text: text)) }
        else if let t = text { items.append(Item(text: t)) }
        if !items.isEmpty { items[0].tag = true }
        return items
    }

    /// A copy (a click on the card): the same two things, so ⌘V gives what a drop gives — but the text keeps the note's
    /// line breaks (pasting is the user's own act, at a place they chose).
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
