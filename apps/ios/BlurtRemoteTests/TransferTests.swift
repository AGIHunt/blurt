// The Transfer sheet's model (Files/Transfers.swift, docs/design/remote-files.md): what each row says, the list's order and what's kept
// between runs, the question before 100 MB on mobile data either way, and the share extension's outbox.
import BlurtRemoteKit
import XCTest
@testable import BlurtRemote

final class TransferTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-tests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// What the model did to the engine, for the tests to read.
    private final class Calls {
        var queued: [([URL], Bool, Bool, Set<URL>)] = []
        var released: [String] = []
        var heldOut: [Bool] = []
        var stoppedOut: [String] = []
        var stoppedIn: [String] = []
        var again: [String] = []
        var asked = 0
    }

    private func model(mobile: Bool = false, ready: Bool = true, active: Bool = true, peer: (String, String)? = ("pc-1", "Office PC"),
                       store: URL? = nil, outbox: Outbox? = nil, resumes: Bool = true) -> (Transfers, Calls) {
        let c = Calls()
        let env = Transfers.Env(peer: { peer.map { (id: $0.0, name: $0.1) } }, mobileData: { mobile }, meeting: { false }, ready: { ready },
                                askClipboard: { c.asked += 1 },
                                queue: { c.queued.append(($0, $1, $2, $3)) }, release: { c.released.append($0) }, holdOut: { c.heldOut.append($0) },
                                peerResumes: { resumes },
                                stopOut: { c.stoppedOut.append($0) }, stopIn: { c.stoppedIn.append($0) }, again: { c.again.append($0) },
                                active: { active })
        return (Transfers(store: store ?? dir.appendingPathComponent("transfers.json"), outbox: outbox, env: env), c)
    }

    private func file(_ name: String, _ size: Int, in folder: URL? = nil) -> URL {
        let d = folder ?? dir.appendingPathComponent("src", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let u = d.appendingPathComponent(name)
        try! Data(count: size).write(to: u)
        return u
    }

    private func row(_ phase: TransferRow.Phase, incoming: Bool = false, done: Int = 0, size: Int = 10_000_000, index: Int? = nil, count: Int? = nil,
                     left: Double? = nil) -> TransferRow {
        TransferRow(id: "r", wire: "w", name: "Q4 报价单.xlsx", size: size, done: done, incoming: incoming, phase: phase, index: index, count: count,
                    peer: "Office PC", at: Date(), secondsLeft: left)
    }

    // MARK: what a row says

    func testAGoingRowSaysWhereWhatsDoneAndTimeLeftOnlyOnceItKnows() {
        let s = TransferWords.size
        XCTAssertEqual(TransferWords.line(row(.going, done: 3_000_000)), "To Office PC · \(s(3_000_000)) of \(s(10_000_000))")
        XCTAssertEqual(TransferWords.line(row(.going, incoming: true, done: 3_000_000)), "From Office PC · \(s(3_000_000)) of \(s(10_000_000))")
        let batch = TransferWords.line(row(.going, done: 3_000_000, index: 2, count: 5, left: 125))
        XCTAssertTrue(batch.hasPrefix("2 of 5 · To Office PC · "), batch)
        XCTAssertTrue(batch.hasSuffix(" left"), batch)
        XCTAssertTrue(batch.contains(TransferWords.duration(125)), batch)
        // a batch of one has no place in it
        XCTAssertFalse(TransferWords.line(row(.going, index: 1, count: 1)).contains("1 of 1"))
    }

    func testEachStateSaysItsOwnLine() {
        XCTAssertEqual(TransferWords.line(row(.waiting)), "Waiting")
        XCTAssertEqual(TransferWords.line(row(.waiting), meeting: true), "Connecting directly…", "the public connection service before the move")
        XCTAssertEqual(TransferWords.line(row(.compressing)), "Compressing…")
        XCTAssertEqual(TransferWords.line(row(.paused)), "Paused. Resumes when reconnected.")
        XCTAssertEqual(TransferWords.line(row(.paused), canContinue: true), "Paused", "Continue beside it says the rest")
        XCTAssertEqual(TransferWords.line(row(.paused), canContinue: true, away: true), "Resumes when Blurt is open.")
        XCTAssertEqual(TransferWords.line(row(.preparing)), "Preparing…")
        var older = row(.done)
        older.toDownloads = true
        XCTAssertEqual(TransferWords.line(older), "Saved to Downloads on Office PC", "a computer without resume saves in Downloads")
        XCTAssertEqual(TransferWords.line(row(.done)), "Saved to Downloads/Blurt on Office PC")
        XCTAssertEqual(TransferWords.line(row(.done, incoming: true)), "Saved to Files › Blurt")
        XCTAssertEqual(TransferWords.line(row(.failed("stopped"))), "Stopped")
        XCTAssertEqual(TransferWords.line(row(.failed("stopped"), incoming: true)), "Stopped")
        XCTAssertEqual(TransferWords.line(row(.failed("space"))), "Not sent: not enough space on that computer.")
        XCTAssertEqual(TransferWords.line(row(.failed("too_big"))), "Not sent: larger than 4 GB.")
        XCTAssertEqual(TransferWords.line(row(.failed("locked"))), "Not sent: that computer is locked.")
        XCTAssertEqual(TransferWords.line(row(.failed("other"))), "Not sent.")
        XCTAssertEqual(TransferWords.line(row(.failed("space"), incoming: true)), "Not received: not enough space on this device.")
        XCTAssertEqual(TransferWords.line(row(.failed("write"), incoming: true)), "Not received.")
    }

    func testNothingCopiedSaysWhy() {
        XCTAssertEqual(TransferWords.nothing("empty", name: "Office PC"), "Nothing is copied on Office PC.")
        XCTAssertEqual(TransferWords.nothing("locked", name: "Office PC"), "Office PC is locked.")
        XCTAssertEqual(TransferWords.nothing("too_big", name: "Office PC"), "Too many files are copied on Office PC. Copy up to 1,000 at a time.")
        XCTAssertEqual(TransferWords.nothing("too_large", name: "Office PC"), "A file copied on Office PC is larger than 4 GB.")
        XCTAssertEqual(TransferWords.nothing("unsupported", name: "Office PC"), "Can’t get this kind of item from Office PC.")
        XCTAssertEqual(TransferWords.firstWords("  Hello\n\nworld  "), "Hello world")
        XCTAssertEqual(TransferWords.firstWords(String(repeating: "a", count: 80)), String(repeating: "a", count: 60) + "…")
    }

    func testALineWrapsOnlyAtItsDotsAndNeverStartsOrEndsWithOne() {
        let l = TransferRowView.breaksAtDots("2 of 3 · To Studio PC · 148 MB of 412 MB · 3 min left")
        XCTAssertEqual(l.count, 4, "whole, then broken at each dot from the last")
        XCTAssertFalse(l[0].contains("\n"))
        for t in l {
            for line in t.split(separator: "\n") {
                XCTAssertFalse(line.hasPrefix("·") || line.hasSuffix("·") || line.hasSuffix("\u{00A0}"), String(line))
            }
            XCTAssertFalse(t.contains(" "), "no plain space to break at: \(t)")
        }
        XCTAssertTrue(l[1].hasSuffix("3\u{2060}\u{00A0}\u{2060}m\u{2060}i\u{2060}n\u{2060}\u{00A0}\u{2060}l\u{2060}e\u{2060}f\u{2060}t"), "3 min left whole, on its own line")
    }

    // MARK: the clipboard, only when asked

    func testNothingTheComputerSendsUnaskedReachesTheClipboard() {
        let (t, c) = model()
        t.clipData(Data("unasked".utf8), name: "Text.txt")
        t.clipText("unasked")
        t.clipNone("empty")
        XCTAssertNil(t.said, "ignored: nobody asked")
        t.getCopied()
        XCTAssertEqual(c.asked, 1)
        XCTAssertTrue(t.getting)
        t.clipNone("empty")
        XCTAssertEqual(t.said?.title, "Nothing is copied on Office PC.")
        XCTAssertFalse(t.getting, "the first answer uses the question up")
        t.dismissSaid()
        t.clipText("a second answer")
        XCTAssertNil(t.said)
        // files beginning are the answer too; a drop clears the question
        t.getCopied()
        t.filesAnswered()
        XCTAssertFalse(t.getting)
        t.getCopied()
        t.sessionDown()
        t.clipData(Data("late".utf8), name: "Text.txt")
        XCTAssertNil(t.said)
        XCTAssertEqual(Transfers.askedFor, 30)
        // asked, a clip file's text lands
        t.getCopied()
        t.clipData(Data("Q4 报价单 第一版".utf8), name: "Text.txt")
        XCTAssertEqual(t.said?.title, "Copied")
        XCTAssertEqual(t.said?.detail, "Q4 报价单 第一版")
    }

    // MARK: mobile data

    func testOnlyMoreThan100MBOnMobileDataAsks() {
        XCTAssertFalse(Transfers.asksFirst(bytes: 100_000_000, mobileData: true))
        XCTAssertTrue(Transfers.asksFirst(bytes: 100_000_001, mobileData: true))
        XCTAssertFalse(Transfers.asksFirst(bytes: 4_000_000_000, mobileData: false), "Wi-Fi never asks")
    }

    func testABigBatchFromTheComputerWaitsForAYesOnce() {
        let (t, c) = model(mobile: true)
        let first = RemoteFileInfo(id: "a", name: "片段 1.mov", size: 90_000_000, index: 1, count: 2, total: 180_000_000)
        XCTAssertEqual(t.admit(first), .hold)
        XCTAssertEqual(t.asking?.incoming, true)
        XCTAssertEqual(t.asking?.bytes, 180_000_000, "the batch's bytes, not the file's")
        t.answer(t.asking!, yes: true)
        XCTAssertNil(t.asking)
        XCTAssertEqual(c.released, ["a"], "its progress said, so the computer goes on")
        // the rest of the same batch isn't asked about again
        XCTAssertEqual(t.admit(RemoteFileInfo(id: "b", name: "片段 2.mov", size: 90_000_000, index: 2, count: 2, total: 180_000_000)), .go)
        // small, or on Wi-Fi: straight in
        XCTAssertEqual(t.admit(RemoteFileInfo(id: "c", name: "作业 3.jpg", size: 2_000_000)), .go)
        XCTAssertEqual(model(mobile: false).0.admit(RemoteFileInfo(id: "d", name: "big.zip", size: 900_000_000)), .go)
    }

    func testNoStopsTheBatchAndAGiveUpIsntFedLater() {
        let (t, c) = model(mobile: true)
        let i = RemoteFileInfo(id: "a", name: "片段 1.mov", size: 300_000_000, index: 1, count: 2, total: 600_000_000)
        XCTAssertEqual(t.admit(i), .hold)
        t.answer(t.asking!, yes: false)
        XCTAssertEqual(c.stoppedIn, ["a"], "its part goes and the computer hears stopped")
        XCTAssertEqual(t.admit(RemoteFileInfo(id: "b", name: "片段 2.mov", size: 300_000_000, index: 2, count: 2, total: 600_000_000)), .refuse)
        // the computer gives up waiting (a minute) before the answer: the question goes with it, and nothing is released after
        let (u, d) = model(mobile: true)
        XCTAssertEqual(u.admit(i), .hold)
        XCTAssertTrue(u.heldEnded("a"))
        XCTAssertNil(u.asking, "the alert closes")
        XCTAssertFalse(u.heldEnded("a"))
        XCTAssertTrue(d.released.isEmpty)
        // a session that drops takes the question with it
        let (v, _) = model(mobile: true)
        XCTAssertEqual(v.admit(i), .hold)
        v.sessionDown()
        XCTAssertNil(v.asking)
    }

    func testAFileGoingOnAfterADropAsksOnlyAboutWhatsLeft() {
        let (t, _) = model(mobile: true)
        t.changed(RemoteTransfer(id: "a", name: "片段 1.mov", size: 300_000_000, done: 250_000_000, incoming: true, state: .paused))
        XCTAssertEqual(t.admit(RemoteFileInfo(id: "a", name: "片段 1.mov", size: 300_000_000)), .go, "50 MB left")
        let (u, _) = model(mobile: true)
        u.changed(RemoteTransfer(id: "a", name: "片段 1.mov", size: 300_000_000, done: 50_000_000, incoming: true, state: .paused))
        XCTAssertEqual(u.admit(RemoteFileInfo(id: "a", name: "片段 1.mov", size: 300_000_000)), .hold)
        XCTAssertEqual(u.asking?.bytes, 250_000_000)
        // while asked about it's written but not said: the row waits
        u.changed(RemoteTransfer(id: "a", name: "片段 1.mov", size: 300_000_000, done: 52_000_000, incoming: true, state: .going))
        XCTAssertEqual(u.rows.first?.phase, .waiting)
    }

    func testSendingThatGoesOnOverMobileDataWithMoreThan100MBLeftAsksAgain() {
        let (t, c) = model(mobile: true)
        t.changed(RemoteTransfer(id: "p", name: "片段.mov", size: 300_000_000, done: 50_000_000, incoming: false, state: .paused))
        t.onMobileData()
        XCTAssertEqual(c.heldOut, [true], "nothing goes until the answer")
        XCTAssertEqual(t.asking?.incoming, false)
        XCTAssertEqual(t.asking?.bytes, 250_000_000, "what's left")
        t.answer(t.asking!, yes: true)
        XCTAssertEqual(c.heldOut, [true, false])
        t.onMobileData()
        XCTAssertNil(t.asking, "a yes isn't asked again at the next drop")
        // no: what was going stops
        let (u, d) = model(mobile: true)
        u.changed(RemoteTransfer(id: "p", name: "片段.mov", size: 300_000_000, done: 50_000_000, incoming: false, state: .paused))
        u.onMobileData()
        u.answer(u.asking!, yes: false)
        XCTAssertEqual(d.stoppedOut, ["p"])
        XCTAssertEqual(d.heldOut, [true, false])
        // less than 100 MB left, or Wi-Fi: no question
        let (w, e) = model(mobile: true)
        w.changed(RemoteTransfer(id: "p", name: "片段.mov", size: 300_000_000, done: 250_000_000, incoming: false, state: .paused))
        w.onMobileData()
        XCTAssertNil(w.asking)
        XCTAssertTrue(e.heldOut.isEmpty)
    }

    func testSendingMoreThan100MBOnMobileDataAsksAndNoDeletesWhatWasMadeForIt() {
        let (t, c) = model(mobile: true)
        let big = file("片段.mov", 0)
        try! FileHandle(forWritingTo: big).truncate(atOffset: 150_000_000)
        t.send([big], temporary: true)
        XCTAssertTrue(c.queued.isEmpty, "held for the question")
        XCTAssertEqual(t.asking?.incoming, false)
        XCTAssertEqual(t.asking?.title, "Send \(TransferWords.size(150_000_000)) over mobile data?")
        t.answer(t.asking!, yes: false)
        XCTAssertTrue(c.queued.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: big.path), "a temporary copy goes")
        // yes: queued as it was asked
        let other = file("作业 3.jpg", 0)
        try! FileHandle(forWritingTo: other).truncate(atOffset: 120_000_000)
        t.send([other])
        t.answer(t.asking!, yes: true)
        XCTAssertEqual(c.queued.first?.0, [other])
        // small: no question
        let (s, sc) = model(mobile: true)
        s.send([file("small.txt", 10)])
        XCTAssertNil(s.asking)
        XCTAssertEqual(sc.queued.count, 1)
    }

    // MARK: the list

    func testRowsFollowTheEngineNewestFirstBatchesInOrderClipsLeftOut() {
        let (t, _) = model()
        let a = RemoteTransfer(id: "a", name: "作业 1.jpg", size: 100, incoming: false, index: 1, count: 2)
        let b = RemoteTransfer(id: "b", name: "作业 2.jpg", size: 100, incoming: false, index: 2, count: 2)
        t.changed(a)
        t.changed(b)
        var later = RemoteTransfer(id: "z", name: "Q4 报价单.xlsx", size: 100, incoming: true)
        t.changed(later)
        XCTAssertEqual(t.rows.map(\.name), ["Q4 报价单.xlsx", "作业 1.jpg", "作业 2.jpg"])
        XCTAssertEqual(t.rows[1].peer, "Office PC")
        later.state = .done
        later.done = 100
        later.url = URL(fileURLWithPath: "/x/Q4 报价单 2.xlsx")
        later.name = "Q4 报价单 2.xlsx"
        t.changed(later)
        XCTAssertEqual(t.rows[0].phase, .done)
        XCTAssertEqual(t.rows[0].file, "Q4 报价单 2.xlsx", "the name it was saved under")
        t.changed(RemoteTransfer(id: "c", name: "Image.png", size: 100, incoming: false, clip: true))
        XCTAssertEqual(t.rows.count, 3, "the clipboard's content isn't a file in the list")
    }

    func testFinishedRowsAreKeptForNextTimeUpToFifty() {
        let store = dir.appendingPathComponent("kept.json")
        let (t, _) = model(store: store)
        for i in 0..<60 { t.changed(RemoteTransfer(id: "\(i)", name: "f\(i)", size: 1, done: 1, incoming: false, state: .done)) }
        t.changed(RemoteTransfer(id: "going", name: "still going", size: 10, incoming: false, state: .going))
        let (next, _) = model(store: store)
        XCTAssertEqual(next.rows.count, 50)
        XCTAssertEqual(next.rows.first?.name, "f59", "newest first")
        XCTAssertFalse(next.rows.contains { $0.name == "still going" }, "only what's over is kept")
    }

    func testContinueIsForThisRunsOutgoingFilesThatCanGoOn() {
        let (t, _) = model()
        t.changed(RemoteTransfer(id: "p", name: "片段.mov", size: 10, incoming: false, state: .paused))
        t.changed(RemoteTransfer(id: "o", name: "a", size: 10, incoming: false, state: .failed("other")))
        t.changed(RemoteTransfer(id: "s", name: "b", size: 10, incoming: false, state: .failed("stopped")))
        t.changed(RemoteTransfer(id: "g", name: "c", size: 10, incoming: false, state: .failed("too_big")))
        t.changed(RemoteTransfer(id: "i", name: "d", size: 10, incoming: true, state: .paused))
        let by = Dictionary(uniqueKeysWithValues: t.rows.map { ($0.wire, t.canContinue($0)) })
        XCTAssertEqual(by, ["p": true, "o": true, "s": false, "g": false, "i": false])
    }

    func testStopGoesToTheRightEnd() {
        let (t, c) = model()
        t.changed(RemoteTransfer(id: "out", name: "a", size: 10, incoming: false, state: .going))
        t.changed(RemoteTransfer(id: "in", name: "b", size: 10, incoming: true, state: .going))
        t.rows.forEach(t.stop)
        XCTAssertEqual(c.stoppedOut, ["out"])
        XCTAssertEqual(c.stoppedIn, ["in"])
    }

    /// The model on the real engine: a sender into a receiver, through what Transfers queues, to Saved.
    func testAFileGoesThroughTheEngineToSaved() {
        let received = dir.appendingPathComponent("Downloads/Blurt", isDirectory: true)
        let r = RemoteFileReceiver(parts: dir.appendingPathComponent("parts"), folder: { received })
        var sender: RemoteFileSender!
        let (t, c) = model()
        sender = RemoteFileSender(send: { m in
            r.heard(m, from: "phone") { a in DispatchQueue.global().async { sender.heard(a) } }
            return true
        }, ready: { true }, peerResumes: { true })
        sender.onChange = { x in DispatchQueue.main.async { t.changed(x) } }
        let src = file("Q4 报价单.xlsx", 3_000_000)
        t.send([src])
        XCTAssertEqual(c.queued.count, 1)
        sender.add(c.queued[0].0)
        let end = Date().addingTimeInterval(10)
        while t.rows.first?.phase != .done, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(t.rows.first?.phase, .done)
        XCTAssertEqual(t.rows.first.map { TransferWords.line($0) }, "Saved to Downloads/Blurt on Office PC")
        XCTAssertEqual((try? Data(contentsOf: received.appendingPathComponent("Q4 报价单.xlsx")))?.count, 3_000_000)
    }

    // MARK: the share extension's outbox

    private func share(_ box: Outbox, to computer: String, _ names: [String], at: Date = Date()) -> URL {
        let f = box.open()!
        let got = names.compactMap { box.add(file($0, 100), to: f) }
        box.seal(f, for: Outbox.Target(id: computer, name: computer == "pc-1" ? "Office PC" : "MacBook Pro"), files: got, now: at)
        return f
    }

    func testTheOutboxGivesEachComputerItsOwnAndDropsWhatsOverAnHourOld() {
        let box = Outbox(root: dir.appendingPathComponent("Outbox"))
        _ = share(box, to: "pc-1", ["作业 3.jpg", "作业 3.jpg"])
        _ = share(box, to: "pc-1", ["old.pdf"], at: Date().addingTimeInterval(-3700))
        _ = share(box, to: "mac-2", ["片段.mov"])
        let half = box.open()!          // being filled by the extension right now: not touched
        _ = box.add(file("half.png", 10), to: half)
        let into = dir.appendingPathComponent("outgoing")
        let got = box.take(for: "pc-1", into: into)
        XCTAssertEqual(got.map { $0.map(\.lastPathComponent) }, [["作业 3.jpg", "作业 3 2.jpg"]], "same names kept apart; the old one dropped")
        XCTAssertTrue(got[0].allSatisfy { FileManager.default.fileExists(atPath: $0.path) && $0.path.hasPrefix(into.path) })
        XCTAssertEqual(box.waiting().map(\.entry.computer), ["mac-2"], "another computer's share waits for it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: half.path))
        XCTAssertTrue(box.take(for: "pc-1", into: into).isEmpty, "taken once")
    }

    func testTheAppPicksUpOnlyWhenOpenAndConnectedToThatComputer() {
        let box = Outbox(root: dir.appendingPathComponent("Outbox"))
        _ = share(box, to: "pc-1", ["作业 3.jpg"])
        let (away, ac) = model(active: false, outbox: box)
        away.pickUp()
        XCTAssertTrue(ac.queued.isEmpty, "not while out of sight")
        let (other, oc) = model(peer: ("mac-2", "MacBook Pro"), outbox: box)
        other.pickUp()
        XCTAssertTrue(oc.queued.isEmpty, "not to another computer")
        XCTAssertEqual(other.rows.map(\.line), ["Waiting"], "what waits is in the list")
        XCTAssertEqual(other.rows.first?.peer, "Office PC")
        let (t, c) = model(outbox: box)
        t.pickUp()
        XCTAssertEqual(c.queued.count, 1)
        XCTAssertEqual(c.queued[0].0.map(\.lastPathComponent), ["作业 3.jpg"])
        XCTAssertTrue(c.queued[0].2, "deleted once sent")
        XCTAssertTrue(t.rows.isEmpty, "the engine's rows take over from here")
    }

    func testStoppingAWaitingShareTakesItOutOfTheOutbox() {
        let box = Outbox(root: dir.appendingPathComponent("Outbox"))
        _ = share(box, to: "pc-1", ["a.jpg", "b.jpg"])
        let (t, _) = model(ready: false, outbox: box)
        t.refreshOutbox()
        XCTAssertEqual(t.rows.count, 2)
        t.stop(t.rows[0])
        XCTAssertEqual(t.rows.count, 1)
        t.stop(t.rows[0])
        XCTAssertTrue(box.waiting().isEmpty, "an empty share goes")
    }
}

private extension TransferRow {
    var line: String { TransferWords.line(self) }
}
