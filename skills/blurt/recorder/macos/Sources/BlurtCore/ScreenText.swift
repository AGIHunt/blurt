// Copy text from the screen (⌥C, docs/design/screen-text.md): the area the user drew → the text in it, the way it
// would read if they had selected and copied it. Apple's Vision reads the lines (the engine Bob's "silent screenshot
// OCR" uses, ~0.1–0.2 s on a few lines); everything after that is geometry, never language rules:
//
//  • what the edge cut — a line whose glyphs reach the top or bottom row of the picture and that shows less than a
//    whole line's height (Vision reads the top half of 两类数据采集方案 as 网关数掂米果力条…), and a character narrower
//    than its neighbours whose ink touches the left or right column (半个「生」→ 三);
//  • rows — the pieces on one baseline, a gap wider than a line's height between two of them is a column (a tab);
//  • blocks — rows closer than a line's height; a block with two or more multi-column rows is a table;
//  • wrapping — a row continues the one before when the first word of it would not have fit at the end of that one
//    (the classic reflow test): a wrapped paragraph or list item is one line again, a path broken at a hyphen too;
//  • preformatted blocks — rows starting at different x (code) or mostly not wrapped (a terminal) keep their lines,
//    indented by the block's character pitch;
//  • list markers — a lone symbol and a space at a row's start (•, ◎ for a check icon, 。 for a hollow bullet) is
//    "- ", nested by x; "2.ordo" gets its space back;
//  • spacing — CJK and Latin are joined with a space only when the capture itself does so; full-width punctuation
//    with no CJK on either side is ASCII again (Vision writes "（etl_nightly_v2）" and "：：" in code).
//
// The measured set (tests/fixtures/screen-text, 17 crops of Bob's cases and more, Retina): Vision's own lines as Bob
// pastes them 15.5 % characters wrong, 5/17 laid out right; this 0.7 %, 16/17. What is left is Vision misreading
// (Lprivate, @ for 0, [ as I): the optional second pass (screen_text.py) is for that.
import CoreGraphics
import Foundation
import Vision

public enum ScreenText {
    /// One line Vision read: its text, its box and each character's box (pixels, top-left origin; nil = none given).
    public struct Piece: Equatable {
        public var text: String
        public var box: CGRect
        public var chars: [CGRect?]
        /// Vision's confidence in the line (0…1; it says 0.3 of lines it read right too — only compared between readings)
        public var confidence: Float
        public init(text: String, box: CGRect, chars: [CGRect?] = [], confidence: Float = 1) {
            self.text = text; self.box = box; self.chars = chars; self.confidence = confidence
        }
    }

    /// The picture's pixels as grey levels, for the edge tests (which pixels are ink, which are the background).
    public struct Gray {
        public let width: Int, height: Int
        let px: [UInt8]
        /// The background: the median of the border's pixels.
        public let background: Int

        public init?(_ image: CGImage) {
            let w = image.width, h = image.height
            guard w > 0, h > 0,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = ctx.data else { return nil }
            px = Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: w * h), count: w * h))
            width = w; height = h
            var border: [UInt8] = []
            for x in 0..<w { border.append(px[x]); border.append(px[(h - 1) * w + x]) }
            for y in 0..<h { border.append(px[y * w]); border.append(px[y * w + w - 1]) }
            border.sort()
            background = Int(border[border.count / 2])
        }

        func ink(_ x: Int, _ y: Int) -> Bool { abs(Int(px[y * width + x]) - background) > 60 }

        /// The share of row y's pixels between x0 and x1 that are ink.
        func row(_ y: Int, _ x0: CGFloat, _ x1: CGFloat) -> Double {
            let a = max(0, Int(x0)), b = min(width, Int(x1))
            guard b > a, y >= 0, y < height else { return 0 }
            return Double((a..<b).filter { ink($0, y) }.count) / Double(b - a)
        }

        func column(_ x: Int, _ y0: CGFloat, _ y1: CGFloat) -> Double {
            let a = max(0, Int(y0)), b = min(height, Int(y1))
            guard b > a, x >= 0, x < width else { return 0 }
            return Double((a..<b).filter { ink(x, $0) }.count) / Double(b - a)
        }
    }

    // MARK: - Reading

    /// Vision's lines in `image`, best first-candidate each, with character boxes. Chinese (simplified, then
    /// traditional) and English — the reading every measurement here was made with; `detect`: Vision picks the
    /// language itself (Japanese, Korean, Cyrillic, accents), the second reading `text(in:)` asks for when the first
    /// one plainly missed text. `words` are the user's own terms (Settings → Dictation's word list) for its language
    /// correction.
    /// `enlarge`: Vision reads the picture twice the size with a margin of its background (a selection of a few
    /// characters: on an 82 × 54 px crop of 「、貼り」 it read 「，貼」, enlarged 「、貼り」); boxes come back in the picture's own pixels.
    /// `languages`: the list Vision is given, the first one weighing most (the first reading's: Chinese and English).
    public static func read(_ image: CGImage, words: [String] = [], languages: [String] = ScreenText.firstLanguages,
                            detect: Bool = false, enlarge: Bool = false) throws -> [Piece] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = detect
        let supported = (try? req.supportedRecognitionLanguages()) ?? []
        req.recognitionLanguages = languages.filter { supported.isEmpty || supported.contains($0) }
        if !words.isEmpty { req.customWords = Array(words.prefix(200)) }
        let scale: CGFloat = enlarge ? 2 : 1, pad: CGFloat = enlarge ? 16 : 0
        let seen = enlarge ? (enlarged(image, scale: Int(scale), pad: Int(pad)) ?? image) : image
        try VNImageRequestHandler(cgImage: seen).perform([req])
        let W = CGFloat(seen.width), H = CGFloat(seen.height)
        func px(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * W / scale - pad, y: (1 - r.maxY) * H / scale - pad, width: r.width * W / scale, height: r.height * H / scale)
        }
        return (req.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first, !c.string.isEmpty else { return nil }
            let s = c.string
            var chars: [CGRect?] = []
            var i = s.startIndex
            while i < s.endIndex {
                let j = s.index(after: i)
                let b = (try? c.boundingBox(for: i..<j))?.boundingBox
                chars.append(b.map(px).flatMap { $0.width > 0 ? $0 : nil })
                i = j
            }
            return Piece(text: s, box: px(o.boundingBox), chars: chars, confidence: c.confidence)
        }
    }

    /// `image` `scale` times the size inside a `pad`-pixel margin (unscaled) of its own background.
    static func enlarged(_ image: CGImage, scale: Int, pad: Int) -> CGImage? {
        guard let g = Gray(image) else { return nil }
        let w = (image.width + 2 * pad) * scale, h = (image.height + 2 * pad) * scale
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bg = CGFloat(g.background) / 255
        ctx.setFillColor(CGColor(red: bg, green: bg, blue: bg, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: pad * scale, y: pad * scale, width: image.width * scale, height: image.height * scale))
        return ctx.makeImage()
    }

    public static let firstLanguages = ["zh-Hans", "zh-Hant", "en-US"]

    /// The other readings, when the first missed text or the selection is small: Vision detecting the language, and
    /// Japanese or Korean first (on a tight crop of 「貼り」 detection read nothing and Japanese first read it at every
    /// size; with Chinese first, Japanese kana and Korean are read as nothing or as look-alikes, "G9").
    static let otherReadings: [(languages: [String], detect: Bool)] = [
        (firstLanguages, true), (["ja-JP", "zh-Hans", "en-US"], false), (["ko-KR", "en-US"], false),
    ]

    /// A selection this small (its shorter side, pixels) gets the other readings whatever the first found — a few
    /// characters read wrongly cover the ink as well as right ones — and one of them enlarged.
    static let smallSide = 160

    // MARK: - A second reading (2026-11-16)
    //
    // With Chinese and English asked for, Vision returns nothing for a line of Japanese kana or Korean (⌥T on
    // 「はい、そうです」 said "no text"), only the kanji of a mixed Japanese line (会議は明日の… → 会議 明日の…), and look-alikes
    // for a few characters ("G9" for 「貼り」). Other readings — Vision detecting the language, Japanese first, Korean first
    // — read them, but each costs a pass (98 → 177 ms on the fixture set for one), and detection changed one Chinese
    // comma after an English word to ", ". So the tuned reading goes first, and the others only when the first plainly
    // missed text — geometry, as the rest of this file: a line of ink, away from the edges, with less than 85 % of its ink
    // columns under what was read; nothing left at all; or a small selection, where wrong characters cover the ink as
    // well as right ones. Another reading wins when it covers clearly more, or as much with clearly more confidence.
    // (Cyrillic and Vietnamese on a large selection still come back as Latin look-alikes: nothing says so.)

    /// One band of rows with ink: its rows and the x-extent of its ink (pixels).
    struct Band: Equatable { var y0: Int, y1: Int, x0: Int, x1: Int }

    /// The picture's bands of ink rows taller than `minH` (rules and underlines are thinner).
    static func bands(_ g: Gray, minH: Int = 6) -> [Band] {
        var rows: [(Int, Int)?] = []
        for y in 0..<g.height {
            var a = -1, b = -1, n = 0
            for x in 0..<g.width where g.ink(x, y) { n += 1; if a < 0 { a = x }; b = x }
            rows.append(n >= 2 ? (a, b) : nil)
        }
        var out: [Band] = []
        var cur: Band?
        for (y, r) in rows.enumerated() {
            if let (a, b) = r {
                if var c = cur { c.y1 = y; c.x0 = min(c.x0, a); c.x1 = max(c.x1, b); cur = c } else { cur = Band(y0: y, y1: y, x0: a, x1: b) }
            } else if let c = cur {
                if c.y1 - c.y0 + 1 >= minH { out.append(c) }
                cur = nil
            }
        }
        if let c = cur, c.y1 - c.y0 + 1 >= minH { out.append(c) }
        return out
    }

    /// Per band, the share of its ink columns (columns with ink in the band's rows: a table's gaps don't count) under
    /// the lines that overlap it vertically by a third of the band or more.
    static func coverage(_ pieces: [Piece], _ bands: [Band], _ g: Gray) -> [Double] {
        bands.map { b in
            let h = CGFloat(b.y1 - b.y0 + 1)
            let over = pieces.filter { p in min(p.box.maxY, CGFloat(b.y1 + 1)) - max(p.box.minY, CGFloat(b.y0)) >= h / 3 }.map(\.box)
            var ink = 0, covered = 0
            for x in b.x0...b.x1 where (b.y0...b.y1).contains(where: { g.ink(x, $0) }) {
                ink += 1
                if over.contains(where: { CGFloat(x) >= $0.minX - 1 && CGFloat(x) <= $0.maxX + 1 }) { covered += 1 }
            }
            return ink == 0 ? 1 : Double(covered) / Double(ink)
        }
    }

    /// The first reading plainly missed text: a band of ink, away from the top and bottom edges (a line the edge cut is
    /// left out on purpose), with less than 85 % of its ink under a line. (Vision's confidence says nothing here: it
    /// gives 0.3 to lines it read right.)
    static func missed(_ bands: [Band], coverage: [Double], height: Int) -> Bool {
        zip(bands, coverage).contains { b, c in b.y0 > 0 && b.y1 < height - 1 && c < 0.85 }
    }

    /// Keep another reading over the one so far? It covers clearly more of the ink, or as much with clearly more
    /// confidence (a few characters read as look-alikes cover the ink too: 「貼り」 → "G9").
    static func prefers(_ b: (coverage: [Double], pieces: [Piece]), over a: (coverage: [Double], pieces: [Piece])) -> Bool {
        let ca = a.coverage.reduce(0, +), cb = b.coverage.reduce(0, +)
        if cb > ca + 0.1 { return true }
        guard cb >= ca - 0.1, !b.pieces.isEmpty else { return false }
        let fa = a.pieces.map(\.confidence).min() ?? 0, fb = b.pieces.map(\.confidence).min() ?? 0
        return fb > fa + 0.2
    }

    /// The whole fast path: read (a second time with Vision detecting the language when the first plainly missed
    /// text), then lay out. ms = Vision's time; `second`: the second reading ran / was kept.
    public static func text(in image: CGImage, words: [String] = []) throws
        -> (text: String, pieces: [Piece], ms: Int, second: (ran: Bool, kept: Bool)) {
        let t0 = Date()
        var pieces = try read(image, words: words)
        guard let gray = Gray(image) else {
            return (pieces.map(\.text).joined(separator: "\n"), pieces, Int(Date().timeIntervalSince(t0) * 1000), (false, false))
        }
        let bs = bands(gray)
        let cov = coverage(pieces, bs, gray)
        var second = (ran: false, kept: false)
        var out = layout(pieces, gray)
        // also when nothing at all is left of the first reading: a selection drawn tight around a line touches the
        // edges, and the edge rule above skips it (⌥T on 「、貼り」 said "no text")
        let small = min(image.width, image.height) <= smallSide
        if !bs.isEmpty && (small || missed(bs, coverage: cov, height: gray.height) || out.isEmpty) {
            second.ran = true
            var best = (coverage: cov, pieces: pieces, text: out)
            var tries = otherReadings.map { (languages: $0.languages, detect: $0.detect, enlarge: false) }
            if small { tries.append((firstLanguages, true, true)) }
            for t in tries {
                let again = try read(image, words: words, languages: t.languages, detect: t.detect, enlarge: t.enlarge)
                let c = coverage(again, bs, gray), text2 = layout(again, gray)
                if text2.isEmpty { continue }
                if prefers((c, again), over: (best.coverage, best.pieces)) || best.text.isEmpty { best = (c, again, text2) }
            }
            if best.text != out || best.pieces != pieces {
                pieces = best.pieces
                out = best.text
                second.kept = true
            }
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        return (out, pieces, ms, second)
    }

    // MARK: - Layout

    static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(v) || (0xFF00...0xFFEF).contains(v) || (0xF900...0xFAFF).contains(v)
    }
    static func isCJKPunct(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x303F).contains(v) || (0xFF00...0xFF65).contains(v)
    }

    /// What goes between the end of `a` and the start of `b` when a line wrapped (or two pieces sit side by side).
    static func joiner(_ a: String, _ b: String, cjkSpace: Bool) -> String {
        guard let x = a.last, let y = b.first else { return "" }
        if "-/_".contains(x) || isCJKPunct(x) || isCJKPunct(y) || ",.;:!?)]}%".contains(y) { return "" }
        if isCJK(x) && isCJK(y) { return "" }
        if isCJK(x) || isCJK(y) { return cjkSpace ? " " : "" }
        return " "
    }

    /// the marks that are never a word's start: a bullet even with no space after it ("-", "*", "–", "。", "·" are)
    static let solidBullets: Set<Character> = ["•", "◦", "○", "◎", "▪", "■", "●", "◆", "◇", "►", "▸", "✓", "✔", "☐", "☑"]   // glyph-ok: OCR input, never shown
    static let bulletMarks: Set<Character> = ["•", "◦", "○", "◎", "。", "·", "▪", "■", "●", "◆", "◇", "►", "▸", "✓", "✔", "☐", "☑", "*", "–", "-"]   // glyph-ok: what Vision reads a list's bullet or check icon as (OCR input, never shown)

    /// "- rest" for a lone symbol and a space at the start, "N. rest" for a number or letter with . ) 、 (its space put
    /// back); nil when the row starts with neither.
    static func marker(_ s: String) -> (text: String, bullet: Bool)? {
        let a = Array(s)
        if a.count >= 3, bulletMarks.contains(a[0]), a[1] == " " {
            return ("- " + String(a.dropFirst(2)).trimmingCharacters(in: .whitespaces), true)
        }
        // a bullet glyph that is never text is one even when Vision dropped the space after it ("•日志已经附在工单里")
        if a.count >= 2, solidBullets.contains(a[0]), !a[1].isWhitespace {
            return ("- " + String(a.dropFirst()).trimmingCharacters(in: .whitespaces), true)
        }
        var i = 0
        while i < a.count, i < 3, a[i].isASCII, a[i].isNumber { i += 1 }
        if i == 0, a.count > 3, a[0].isASCII, a[0].isLetter, ".)".contains(a[1]), a[2] == " " { i = 1 }   // "a. x", never "e.g."
        guard i > 0, i < a.count, ".)、".contains(a[i]) else { return nil }
        let rest = String(a[(i + 1)...]).trimmingCharacters(in: .whitespaces)
        guard let f = rest.first, !f.isNumber else { return nil }     // 10.5, 1.2.3: a number, not a list
        return (String(a[...i]) + " " + rest, false)
    }

    struct Row {
        var pieces: [Piece]
        var text = "", cols = 1, x: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0, h: CGFloat = 0
        var bullet = false, numbered = false
        var center: CGFloat { (top + bottom) / 2 }
    }

    /// The width of the first word of a piece (its first character for CJK), from the character boxes.
    static func firstWordWidth(_ p: Piece) -> CGFloat {
        let t = Array(p.text)
        guard !t.isEmpty, p.chars.count == t.count else { return p.box.height }
        var i = 1
        if !isCJK(t[0]) { while i < t.count, !t[i].isWhitespace, !isCJK(t[i]) { i += 1 } }
        guard let a = p.chars[0], let b = p.chars[i - 1] else { return p.box.height }
        return b.maxX - a.minX
    }

    public static func layout(_ input: [Piece], _ ink: Gray) -> String {
        let W = CGFloat(ink.width), H = CGFloat(ink.height)
        guard !input.isEmpty else { return "" }
        // a line's height: the median over characters of the lines the edges don't touch (short labels count less)
        let inner = input.filter { $0.box.minY > 3 && $0.box.maxY < H - 3 }
        let hs = (inner.isEmpty ? input : inner).flatMap { p in Array(repeating: p.box.height, count: max(1, p.text.count)) }.sorted()
        let lineH = hs[hs.count / 2]
        // a line's ink height (rows with ink in its x-span, a little above and below its box): what an edge cut
        // takes away, whatever box Vision guessed for the part it saw
        func inkHeight(_ b: CGRect, to edgeTop: Bool? = nil) -> CGFloat {
            let pad = 0.3 * lineH
            let y0 = edgeTop == true ? 0 : max(0, Int(b.minY - pad)), y1 = edgeTop == false ? ink.height : min(ink.height, Int(b.maxY + pad))
            let rows = (y0..<max(y0, y1)).filter { ink.row($0, b.minX, b.maxX) > 0.01 }
            guard let f = rows.first, let l = rows.last else { return 0 }
            return CGFloat(l - f + 1)
        }
        let fullInk: CGFloat? = {
            let h = inner.map { inkHeight($0.box) }.filter { $0 > 0 }.sorted()
            return h.isEmpty ? nil : h[h.count / 2]
        }()

        var kept: [Piece] = []
        for p in input {
            let b = p.box
            // 1. cut by the top or bottom edge
            // near an edge (Vision's box may stop short of it) with glyphs on the edge row
            let topCut = b.minY <= 0.5 * lineH && ink.row(0, b.minX, b.maxX) > 0.02
            let bottomCut = b.maxY >= H - 0.5 * lineH && ink.row(ink.height - 1, b.minX, b.maxX) > 0.02
            if topCut || bottomCut {
                if let full = fullInk {
                    if inkHeight(b, to: topCut) < 0.9 * full { continue }
                } else if b.height < 0.9 * lineH { continue }
            }
            // 2. a character cut by the left or right edge
            var t = Array(p.text), ch = p.chars
            if ch.count == t.count, !t.isEmpty {
                func narrow(_ i: Int) -> Bool {
                    let same = zip(t, ch).compactMap { a, c in c.flatMap { isCJK(a) == isCJK(t[i]) ? $0.width : nil } }.sorted()
                    guard same.count >= 3, let w = ch[i]?.width else { return true }
                    return w < 0.8 * same[same.count / 2]
                }
                if let c = ch[0], c.minX <= 6, ink.column(0, b.minY, b.maxY) > 0.02, narrow(0) { t.removeFirst(); ch.removeFirst() }
                if let c = ch.last ?? nil, !t.isEmpty, c.maxX >= W - 6, ink.column(ink.width - 1, b.minY, b.maxY) > 0.02, narrow(t.count - 1) {
                    t.removeLast(); ch.removeLast()
                }
            }
            let lead = t.prefix { $0.isWhitespace }.count, trail = t.reversed().prefix { $0.isWhitespace }.count
            guard t.count - lead - trail > 0 else { continue }
            let core = Array(t[lead..<(t.count - trail)])
            let coreChars = ch.count == t.count ? Array(ch[lead..<(t.count - trail)]) : []
            kept.append(Piece(text: String(core), box: b, chars: coreChars))
        }
        guard !kept.isEmpty else { return "" }

        // 3. CJK ↔ Latin spacing as the capture itself writes it
        let all = kept.map(\.text).joined(separator: " ")
        let spaced = all.matches(#"\p{Han} [A-Za-z0-9/]|[A-Za-z0-9] \p{Han}"#), tight = all.matches(#"\p{Han}[A-Za-z0-9/]|[A-Za-z0-9]\p{Han}"#)
        let cjkSpace = spaced >= tight

        // 4. rows
        var rows: [Row] = []
        for p in kept.sorted(by: { ($0.box.midY, $0.box.minX) < ($1.box.midY, $1.box.minX) }) {
            if var last = rows.last, abs(p.box.midY - last.center) < 0.5 * min(p.box.height, last.h) {
                last.pieces.append(p); rows[rows.count - 1] = last; continue
            }
            var r = Row(pieces: [p]); r.top = p.box.minY; r.bottom = p.box.maxY; r.h = p.box.height
            rows.append(r)
        }
        for i in rows.indices {
            var r = rows[i]
            r.pieces.sort { $0.box.minX < $1.box.minX }
            r.top = r.pieces.map(\.box.minY).min()!; r.bottom = r.pieces.map(\.box.maxY).max()!
            r.h = r.pieces.map(\.box.height).max()!
            var s = r.pieces[0].text
            for (a, b) in zip(r.pieces, r.pieces.dropFirst()) {
                if b.box.minX - a.box.maxX > 0.9 * r.h { s += "\t" + b.text; r.cols += 1 } else { s += joiner(s, b.text, cjkSpace: cjkSpace) + b.text }
            }
            r.x = r.pieces[0].box.minX; r.right = r.pieces.last!.box.maxX
            if r.cols == 1, let m = marker(s) { s = m.text; r.bullet = m.bullet; r.numbered = !m.bullet }
            r.text = s
            rows[i] = r
        }

        // 5. blocks
        var blocks: [[Row]] = [[rows[0]]]
        for (p, r) in zip(rows, rows.dropFirst()) {
            let tableRow = p.cols > 1 && r.cols == p.cols
            if r.top - p.bottom > 0.9 * max(p.h, r.h) && !tableRow { blocks.append([r]) } else { blocks[blocks.count - 1].append(r) }
        }
        let right = rows.map(\.right).max()!
        var out: [String] = []
        for b in blocks {
            if b.filter({ $0.cols > 1 }).count >= 2 { out.append(b.map(\.text).joined(separator: "\n")); continue }
            let wrapped = zip(b, b.dropFirst()).map { p, r in p.right + firstWordWidth(r.pieces[0]) + 0.3 * p.h >= right }
            let xs = b.map(\.x), minX = xs.min()!
            // a list is never preformatted (its items are new rows, not unwrapped ones; Vision may miss one marker)
            let list = b.contains { $0.bullet || $0.numbered }
            let varied = xs.max()! - minX > 1.2 * lineH
            let pre = !list && b.count >= 2 && (varied || (b.count >= 3 && Double(wrapped.filter { $0 }.count) < 0.5 * Double(wrapped.count)))
            if pre {
                let widths = b.map { $0.right - $0.x }.sorted(), counts = b.map { CGFloat($0.text.count) }.sorted()
                let pitch = widths[widths.count / 2] / max(1, counts[counts.count / 2])
                out.append(b.map { String(repeating: " ", count: max(0, Int((($0.x - minX) / pitch).rounded()))) + $0.text }.joined(separator: "\n"))
                continue
            }
            let bulletX = b.filter(\.bullet).map(\.x).min()
            var lines: [String] = []
            for (i, r) in b.enumerated() {
                var t = r.text
                if r.bullet, let bx = bulletX, r.x > bx + 0.8 * r.h { t = "  " + t }
                if let last = lines.last, i > 0, !r.bullet, !r.numbered, wrapped[i - 1], r.cols == 1 {
                    lines[lines.count - 1] = last + joiner(last, t, cjkSpace: cjkSpace) + t
                } else { lines.append(t) }
            }
            out.append(fillMissingNumbers(lines).joined(separator: "\n"))
        }
        return asciiPunctuation(out.joined(separator: "\n\n"))
    }

    /// An item between "1." and "3." with no number of its own: Vision missed its "2." (a small marker in a low-resolution
    /// capture); it gets it back. Only a gap of exactly one, so a paragraph between two items is never numbered.
    static func fillMissingNumbers(_ lines: [String]) -> [String] {
        func number(_ s: String) -> Int? {
            let d = s.prefix { $0.isASCII && $0.isNumber }
            guard !d.isEmpty, s.dropFirst(d.count).hasPrefix(". ") else { return nil }
            return Int(d)
        }
        var out = lines
        for i in lines.indices.dropFirst().dropLast() where number(lines[i]) == nil && marker(lines[i]) == nil {
            if let a = number(lines[i - 1]), number(lines[i + 1]) == a + 2 { out[i] = "\(a + 1). " + lines[i] }
        }
        return out
    }

    /// Full-width punctuation with no CJK character on either side (spaces skipped) → its ASCII form.
    static func asciiPunctuation(_ s: String) -> String {
        let fw: Set<Character> = ["（", "）", "［", "］", "｛", "｝", "：", "；", "，", "！", "？", "＂", "＇"]
        var a = Array(s)
        func ok(_ i: Int, _ step: Int) -> Bool {
            var j = i + step
            while j >= 0, j < a.count, a[j] == " " || a[j] == "\t" { j += step }
            return j < 0 || j >= a.count || a[j] == "\n" || !isCJK(a[j]) || fw.contains(a[j])
        }
        // ("？sort=price": a space before it and ASCII right after — a query string, not a Chinese question)
        func spacedBeforeASCII(_ i: Int) -> Bool {
            i > 0 && a[i - 1] == " " && i + 1 < a.count && a[i + 1].isASCII && !a[i + 1].isWhitespace
        }
        for i in a.indices where fw.contains(a[i]) && ((ok(i, -1) && ok(i, 1)) || spacedBeforeASCII(i)) {
            if let v = a[i].unicodeScalars.first?.value, let u = UnicodeScalar(v - 0xFEE0) { a[i] = Character(u) }
        }
        return String(a)
    }
}

private extension String {
    func matches(_ pattern: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(in: self, range: NSRange(startIndex..., in: self)) ?? 0
    }
}
