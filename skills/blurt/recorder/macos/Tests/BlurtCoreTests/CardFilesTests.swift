// BlurtCore/CardFiles.swift: what a shot card hands out (the picture with its note inside, the note as .md), which
// pasteboard item carries what (the drop into Claude that kept only the picture; per kind of app: CardDropTargetTests),
// and how long a taken card is kept.
import ImageIO
import XCTest
@testable import BlurtCore

final class CardFilesTests: XCTestCase {
    // MARK: names and the .md

    func testStemAndNames() {
        let utc = TimeZone(identifier: "UTC")!
        let wall = Date(timeIntervalSince1970: 1_792_766_412)          // 14:40:12 UTC
        let stem = CardFiles.stem(prefix: "截图", wall: wall, timeZone: utc)
        XCTAssertEqual(stem, "截图-144012")
        XCTAssertEqual(CardFiles.imageName(stem: stem), "截图-144012.png")
        XCTAssertEqual(CardFiles.noteName(stem: stem, noteWord: "备注"), "截图-144012-备注.md")
        XCTAssertEqual(CardFiles.noteName(stem: CardFiles.stem(prefix: "Screenshot", wall: wall, timeZone: utc), noteWord: "note"),
                       "Screenshot-144012-note.md")
        XCTAssertEqual(CardFiles.safeName("a/b:c\nd"), "a-b-c-d")
        XCTAssertEqual(CardFiles.safeName("  "), "capture")
    }

    /// v0.8.2: the .md is the note and nothing else — the image line was noise wherever the file was opened.
    func testMarkdownIsJustTheNote() {
        let md = CardFiles.markdown(note: "  结账按钮被挡住了\nthe banner covers it \n")
        XCTAssertEqual(md, "结账按钮被挡住了\nthe banner covers it\n")
        XCTAssertFalse(md.contains("!["))
        XCTAssertFalse(md.hasPrefix("#"))
        XCTAssertEqual(CardFiles.markdown(note: "x"), "x\n")
    }

    // MARK: the note inside the PNG

    func testPNGDescriptionRoundTripsAndImageIOReadsIt() throws {
        let png = try XCTUnwrap(Self.tinyPNG())
        let note = "结账按钮被挡住了\nthe banner covers it"
        let tagged = try XCTUnwrap(PNGText.withText(png, text: note))
        XCTAssertEqual(PNGText.text(tagged), note)
        // ImageIO (Preview, Finder's Get Info, every image pipeline on the Mac) sees it, and the picture still decodes
        let src = try XCTUnwrap(CGImageSourceCreateWithData(tagged as CFData, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let pngProps = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        XCTAssertEqual(pngProps?[kCGImagePropertyPNGDescription] as? String, note)
        // written again (the note was edited): one Description, the new one
        let again = try XCTUnwrap(PNGText.withText(tagged, text: "edited"))
        XCTAssertEqual(PNGText.text(again), "edited")
        XCTAssertEqual(again.count, tagged.count - note.utf8.count + "edited".utf8.count, "the old chunk is gone")
        XCTAssertNil(PNGText.withText(Data("not a png".utf8), text: "x"))
        XCTAssertNil(PNGText.text(png))
    }

    func testCRC32() {
        XCTAssertEqual(PNGText.crc32(Array("IEND".utf8)), 0xAE42_6082)       // every PNG's last chunk
        XCTAssertEqual(PNGText.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    static func tinyPNG() -> Data? {
        guard let ctx = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        guard let img = ctx.makeImage() else { return nil }
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? d as Data : nil
    }

    // MARK: which item carries what

    let img = URL(fileURLWithPath: "/s/out/003/截图-144012.png")
    let md = URL(fileURLWithPath: "/s/out/003/截图-144012-备注.md")

    /// The report: Claude (Electron) took the files and dropped the loose text. For a web app (and an app we don't know)
    /// the note is a file of its own, and the text rides on that file's item.
    func testDragOfASnapWithANoteIntoAWebApp() {
        for c in [DropClass.web, .unknown] {
            XCTAssertEqual(CardPasteboard.drag(for: c, image: img, noteFile: md, note: "see the header\nthe logo overlaps"), [
                CardPasteboard.Item(file: img, imageData: true, tag: true),
                CardPasteboard.Item(file: md, text: "see the header · the logo overlaps"),
            ], "\(c)")
        }
    }

    func testDragTextIsSafeForATerminal() {
        let items = CardPasteboard.drag(for: .web, image: img, noteFile: md, note: "ls\n\u{1B}[201~rm -rf ~\r")
        XCTAssertEqual(items[1].text, "ls · [201~rm -rf ~")
        XCTAssertEqual(CardPasteboard.drag(for: .text, image: img, noteFile: md, note: "ls\n\u{1B}[201~rm -rf ~\r")[1].text,
                       "ls · [201~rm -rf ~", "every class gets the one-line form: the app that reads it may not be the one it lands in")
    }

    func testDragWithoutANote() {
        for c in DropClass.allCases {
            let first = CardPasteboard.drag(for: c, image: img, noteFile: nil, note: nil)
            XCTAssertEqual(first.count, 1, "\(c)")
            XCTAssertEqual(first[0].file, img)
            XCTAssertTrue(first[0].tag)
            XCTAssertEqual(CardPasteboard.drag(for: c, image: img, noteFile: nil, note: " \n "), first, "\(c)")
        }
    }

    func testDragWhenTheNoteFileCouldNotBeWritten() {
        XCTAssertEqual(CardPasteboard.drag(for: .web, image: img, noteFile: nil, note: "words"),
                       [CardPasteboard.Item(file: img, imageData: true, tag: true), CardPasteboard.Item(text: "words")])
        XCTAssertEqual(CardPasteboard.drag(for: .terminal, image: img, noteFile: nil, note: "words"),
                       [CardPasteboard.Item(file: img, tag: true)], "a terminal never gets the note as text")
    }

    /// A voice card is text that happened to be spoken: its words, no audio file, no .md — whatever the app.
    func testDragOfAVoiceCard() {
        for c in DropClass.allCases {
            XCTAssertEqual(CardPasteboard.drag(for: c, image: nil, noteFile: nil, note: "call Ana\nabout pricing"),
                           [CardPasteboard.Item(text: "call Ana · about pricing", tag: true)], "\(c)")
            XCTAssertEqual(CardPasteboard.drag(for: c, image: nil, noteFile: md, note: "words"), [CardPasteboard.Item(text: "words", tag: true)])
            XCTAssertEqual(CardPasteboard.drag(for: c, image: nil, noteFile: nil, note: nil), [])
        }
    }

    /// A click copies what a drag carries — the text with its line breaks (pasting is the user's own act).
    func testCopyMatchesTheDrag() {
        XCTAssertEqual(CardPasteboard.copy(image: img, noteFile: md, note: " see the header\nthe logo overlaps "), [
            CardPasteboard.Item(file: img, imageData: true),
            CardPasteboard.Item(file: md, text: "see the header\nthe logo overlaps"),
        ])
        XCTAssertEqual(CardPasteboard.copy(image: nil, noteFile: nil, note: "a\nb"), [CardPasteboard.Item(text: "a\nb")])
        XCTAssertEqual(CardPasteboard.copy(image: img, noteFile: nil, note: nil), [CardPasteboard.Item(file: img, imageData: true)])
    }

    // MARK: taken: 7 days

    func testTakenIsKeptSevenDays() {
        let t = 1_792_766_412.0
        XCTAssertTrue(TakenCaptures.isRecent(taken: t, now: t))
        XCTAssertTrue(TakenCaptures.isRecent(taken: t, now: t + 7 * 86400 - 1))
        XCTAssertFalse(TakenCaptures.isRecent(taken: t, now: t + 7 * 86400))
        XCTAssertTrue(TakenCaptures.isExpired(taken: t, now: t + 8 * 86400))
        XCTAssertEqual(TakenCaptures.daysLeft(taken: t, now: t), 7)
        XCTAssertEqual(TakenCaptures.daysLeft(taken: t, now: t + 6.5 * 86400), 1)
        XCTAssertEqual(TakenCaptures.daysLeft(taken: t, now: t + 9 * 86400), 0)
    }
}
