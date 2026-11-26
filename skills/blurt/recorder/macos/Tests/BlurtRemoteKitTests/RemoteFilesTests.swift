// The shared file engine (RemoteFiles.swift): a sender and a receiver wired back to back, through a drop and a resume, a stop on either
// end, a clip, a locked receiver, a batch, and the limits (docs/design/remote-files.md).
import XCTest
@testable import BlurtRemoteKit

final class RemoteFilesTests: XCTestCase {
    private var dir: URL!
    /// the receivers made, kept for the test's length (the sender holds its receiver weakly)
    private var held: [RemoteFileReceiver] = []

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-files-test-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func file(_ name: String, _ size: Int) -> URL {
        let u = dir.appendingPathComponent("src").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        var d = Data(count: size)
        for i in 0..<size { d[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        try! d.write(to: u)
        return u
    }

    /// A pipe between the two: `up` false drops every message, as a dead session does.
    private final class Pipe: @unchecked Sendable {
        var up = true
        var cutAfter: Int?   // bytes of chunks, then the pipe drops
        var chunked = 0
        /// seconds per chunk, as a slow network
        var delay: TimeInterval = 0
        let lock = NSLock()
    }

    private func pair(resume: Bool = true, pipe: Pipe = Pipe()) -> (RemoteFileSender, RemoteFileReceiver, URL) {
        let out = dir.appendingPathComponent("Downloads/Blurt")
        let r = RemoteFileReceiver(parts: dir.appendingPathComponent("parts"), folder: { out }, resumes: resume)
        held.append(r)
        var s: RemoteFileSender!
        s = RemoteFileSender(send: { [weak r] m in
            pipe.lock.lock(); defer { pipe.lock.unlock() }
            guard pipe.up, let r else { return false }
            if case .chunk = m, pipe.delay > 0 { Thread.sleep(forTimeInterval: pipe.delay) }
            if case let .chunk(_, d) = m, let cut = pipe.cutAfter {
                if pipe.chunked >= cut { pipe.up = false; return false }
                pipe.chunked += d.count
            }
            r.heard(m, from: "phone-1") { a in DispatchQueue.global().async { s.heard(a) } }
            return true
        }, ready: { pipe.up }, peerResumes: { resume })
        s.pollInterval = 0.002
        return (s, r, out)
    }

    private func wait(_ what: String, _ timeout: TimeInterval = 10, _ ok: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !ok() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(ok(), what)
    }

    func testABatchArrivesWholeAndInOrder() throws {
        let (s, _, out) = pair()
        let a = file("a.txt", 5), b = file("b.bin", RemoteFiles.chunk * 3 + 17), c = file("a.txt".replacingOccurrences(of: "a", with: "c"), 0)
        s.add([a, b, c])
        wait("all three saved") { s.transfers.allSatisfy { $0.state == .done } }
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("b.bin")), try Data(contentsOf: b))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("c.txt")).count, 0)
        XCTAssertEqual(s.transfers.map(\.index), [1, 2, 3])
        XCTAssertEqual(s.transfers.map(\.count), [3, 3, 3])
    }

    func testANameInUseGetsANumber() {
        let (s, _, out) = pair()
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: out.appendingPathComponent("a.txt").path, contents: Data())
        s.add([file("a.txt", 3)])
        wait("saved as a 2.txt") { FileManager.default.fileExists(atPath: out.appendingPathComponent("a 2.txt").path) }
    }

    func testADropPausesAndTheSameFileGoesOnFromWhereItWas() throws {
        let pipe = Pipe()
        pipe.cutAfter = RemoteFiles.chunk * 30   // ~5.6 MB of 12 MB
        let (s, r, out) = pair(pipe: pipe)
        let big = file("big.mov", RemoteFiles.chunk * 64)
        s.add([big])
        wait("paused after the drop") { s.transfers.first?.state == .paused }
        s.connection(up: false)
        r.suspend(device: "phone-1")
        XCTAssertEqual(s.transfers.first?.state, .paused)
        XCTAssertEqual(r.current.first?.state, .paused)
        let had = r.current.first?.done ?? 0
        XCTAssertGreaterThan(had, 0)
        // back: the rest only
        pipe.lock.withLock { pipe.cutAfter = nil; pipe.chunked = 0; pipe.up = true }
        s.connection(up: true)
        wait("saved") { s.transfers.first?.state == .done }
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("big.mov")), try Data(contentsOf: big))
        XCTAssertLessThanOrEqual(pipe.chunked, RemoteFiles.chunk * 64 - had + RemoteFiles.chunk, "only what was missing went again")
    }

    func testAPartKeptOverAnHourIsGone() {
        let pipe = Pipe()
        pipe.cutAfter = RemoteFiles.chunk * 4
        let (s, r, _) = pair(pipe: pipe)
        s.add([file("x.zip", RemoteFiles.chunk * 40)])
        wait("dropped") { !pipe.up }
        r.suspend(device: "phone-1")
        XCTAssertEqual(r.current.count, 1)
        r.now = { Date().addingTimeInterval(RemoteFiles.keepParts + 1) }
        r.expire()
        XCTAssertTrue(r.current.isEmpty)
    }

    func testStopOnTheSenderDeletesThePart() {
        let pipe = Pipe()
        pipe.delay = 0.005
        let (s, r, out) = pair(pipe: pipe)
        let t = s.add([file("slow.bin", RemoteFiles.chunk * 200)])[0]
        wait("going") { (r.current.first?.done ?? 0) > 0 }
        s.stop(t.id)
        wait("part gone") { r.current.isEmpty }
        XCTAssertEqual(s.transfers.first?.state, .failed("stopped"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("slow.bin").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("parts").path).count, 0)
    }

    func testStopOnTheReceiverStopsTheSender() {
        let pipe = Pipe()
        pipe.delay = 0.005
        let (s, r, _) = pair(pipe: pipe)
        let t = s.add([file("slow.bin", RemoteFiles.chunk * 200)])[0]
        wait("going") { (r.current.first?.done ?? 0) > 0 }
        r.stop(t.id, from: "phone-1") { a in s.heard(a) }
        wait("stopped") { s.transfers.first?.state == .failed("stopped") }
    }

    func testAClipGoesToTheClipboardNotTheFolder() {
        let (s, r, out) = pair()
        var got: (String, Data)?
        r.onClip = { u, n, _ in got = (n, (try? Data(contentsOf: u)) ?? Data()) }
        s.add([file("Image.png", 1000)], clip: true)
        wait("clip heard") { got != nil }
        XCTAssertEqual(got?.0, "Image.png")
        XCTAssertEqual(got?.1.count, 1000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("Image.png").path))
    }

    func testALockedReceiverTakesNothing() {
        let (s, r, _) = pair()
        r.locked = { true }
        s.add([file("a.txt", 3)])
        wait("refused") { s.transfers.first?.state == .failed("locked") }
    }

    func testAnOlderReceiverWithoutResumeStillGetsTheFile() throws {
        let (s, _, out) = pair(resume: false)
        let f = file("doc.pdf", RemoteFiles.chunk * 25 + 1)
        s.add([f])
        wait("saved") { s.transfers.first?.state == .done }
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("doc.pdf")), try Data(contentsOf: f))
    }

    func testTheWindowFollowsTheRate() {
        XCTAssertEqual(RemoteFiles.window(rate: nil, resumes: true), RemoteFiles.minWindow)
        XCTAssertEqual(RemoteFiles.window(rate: 1_500_000, resumes: true), 750_000, "half a second of a slow link")
        XCTAssertEqual(RemoteFiles.window(rate: 50_000_000, resumes: true), RemoteFiles.window, "capped on a fast one")
        XCTAssertEqual(RemoteFiles.window(rate: 1_500_000, resumes: false), RemoteFiles.window, "an older peer acks every 1 MiB")
    }

    func testNamesAreCleaned() {
        XCTAssertEqual(RemoteFiles.clean("../secret/.bashrc"), "bashrc")
        XCTAssertEqual(RemoteFiles.clean("C:\\Users\\me\\报告.pdf"), "报告.pdf")
        XCTAssertEqual(RemoteFiles.clean("a:b.txt"), "a-b.txt")
        XCTAssertEqual(RemoteFiles.clean("  "), "file")
    }

    func testAFolderIsZipped() throws {
        let f = dir.appendingPathComponent("Lessons")
        try FileManager.default.createDirectory(at: f.appendingPathComponent("week 1"), withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: f.appendingPathComponent("week 1/plan.txt"))
        let out = RemoteFiles.prepare([f, file("a.txt", 1)])
        XCTAssertEqual(out.map(\.lastPathComponent), ["Lessons.zip", "a.txt"])
        let head = try Data(contentsOf: out[0]).prefix(2)
        XCTAssertEqual(Array(head), [0x50, 0x4B], "a zip")
    }
}
