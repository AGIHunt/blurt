// BlurtCore/WarmServer.swift, ProcessProbe.swift, DictationASRFailure.hung: telling a warm model server that works from
// one that is stuck (v0.9 dogfood: a stuck server from an app long gone made every dictation wait ~20 s, relaunches
// included), and a request in flight that will never be answered.
import Foundation
import XCTest
@testable import BlurtCore

final class WarmServerTests: XCTestCase {
    let rec = WarmServer.Record(pid: 4242, port: 50000, token: "t", parent: 100, started: Date(timeIntervalSince1970: 1000))
    let argv = ["/Users/me/.cache/uv/python3", "/skill/scripts/transcribe.py", "serve", "--preload", "--parent", "100"]

    func verdict(record: WarmServer.Record?? = nil, alive: Bool = true, argv: [String]?? = nil, started: Date? = Date(timeIntervalSince1970: 998),
                 answered: Bool = false, cpu: Double? = 0, parentAlive: Bool = false) -> WarmServer.Health {
        WarmServer.verdict(record: record ?? rec, alive: alive, argv: argv ?? self.argv, script: "transcribe.py",
                           processStarted: started, answered: answered, cpu: cpu, parentAlive: parentAlive)
    }

    func testAServerThatAnswersOrWorksIsLeftAlone() {
        XCTAssertEqual(verdict(answered: true), .answers)
        // no answer within the ping, but its CPU moves: a model loading, a long decode, another request first
        XCTAssertEqual(verdict(cpu: 0.3), .working)
        // nothing can be told (the command line or the CPU unreadable): never ended on a guess
        XCTAssertEqual(verdict(argv: .some(nil)), .working)
        XCTAssertEqual(verdict(cpu: nil), .working)
    }

    func testStaleFiles() {
        XCTAssertEqual(verdict(record: .some(nil)), .gone)
        XCTAssertEqual(verdict(alive: false), .gone)
        // the pid now belongs to something else: the file goes, the process is not touched
        XCTAssertEqual(verdict(argv: ["/bin/zsh"]), .notAServer)
        XCTAssertEqual(verdict(argv: ["python3", "/skill/scripts/polish.py", "serve"]), .notAServer)
        XCTAssertEqual(verdict(started: Date(timeIntervalSince1970: 1300)), .notAServer)        // started after its file
    }

    func testAStuckServer() {
        // alive, a server of ours, no answer, no CPU: stuck — orphaned when the app that started it is gone
        XCTAssertEqual(verdict(), .stuck(orphaned: true))
        XCTAssertEqual(verdict(parentAlive: true), .stuck(orphaned: false))
    }

    func testTheRunFileIsRead() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)")
        setenv("BLURT_HOME", home.path, 1)
        defer { unsetenv("BLURT_HOME"); try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("run"), withIntermediateDirectories: true)
        let o: [String: Any] = ["pid": Int(getpid()), "port": 50123, "token": "abc", "parent": 1, "started": "2026-10-25T20:00:00+08:00"]
        try JSONSerialization.data(withJSONObject: o).write(to: WarmServer.infoURL("asr-serve"))
        let r = try XCTUnwrap(WarmServer.record("asr-serve"))
        XCTAssertEqual(r.pid, getpid())
        XCTAssertEqual(r.parent, 1)
        XCTAssertNotNil(r.started)
        // the file goes only while it names that process
        WarmServer.forget("asr-serve", pid: 1)
        XCTAssertNotNil(WarmServer.record("asr-serve"))
        WarmServer.forget("asr-serve", pid: getpid())
        XCTAssertNil(WarmServer.record("asr-serve"))
        XCTAssertEqual(WarmServer.health("asr-serve", script: "transcribe.py"), .gone)
    }

    func testTheProcessProbeReadsItsOwnProcess() throws {
        let me = getpid()
        XCTAssertTrue(ProcessProbe.alive(me))
        XCTAssertFalse(ProcessProbe.alive(-1))
        XCTAssertNotNil(ProcessProbe.started(me))
        let a = try XCTUnwrap(ProcessProbe.arguments(me))
        XCTAssertEqual(a.count, CommandLine.arguments.count)
        let c0 = try XCTUnwrap(ProcessProbe.cpuSeconds(me))
        var x = 0.0
        for i in 0..<3_000_000 { x += sqrt(Double(i)) }
        XCTAssertGreaterThan(x, 0)
        XCTAssertGreaterThan(try XCTUnwrap(ProcessProbe.cpuSeconds(me)), c0)
    }

    func testAHangIsToldByTheServersBehaviour() {
        // not before 3 s, and only with the server's CPU still for 2 s — whatever the audio's length
        XCTAssertFalse(DictationASRFailure.hung(waited: 2.5, cpuIdle: 2.5))
        XCTAssertTrue(DictationASRFailure.hung(waited: 3.1, cpuIdle: 2.1))
        XCTAssertFalse(DictationASRFailure.hung(waited: 12, cpuIdle: 0))      // busy: waited for
        // a 20 s take is given up on at 3 s too (review: waiting half the audio held a stopped server's take 9.5 s)
        XCTAssertTrue(DictationASRFailure.hung(waited: 3.0, cpuIdle: 3.0))
        XCTAssertFalse(DictationASRFailure.hung(waited: 30, cpuIdle: 0.4))    // a long decode keeps its CPU moving
        // the old limit stays the ceiling
        XCTAssertEqual(DictationASRFailure.serverTimeout(audioSeconds: 20), 45)
    }

    func testCPUWatchCountsTheStillTime() {
        // a process that sleeps (this test's own CPU moves, so a child that does nothing: `sleep`)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        XCTAssertNoThrow(try p.run())
        defer { p.terminate() }
        usleep(200_000)
        let w = CPUWatch(pid: p.processIdentifier, now: Date())
        XCTAssertEqual(w.idle(now: Date()), 0, accuracy: 0.3)
        let later = Date().addingTimeInterval(3)
        XCTAssertGreaterThan(w.idle(now: later), 2.5)
    }

    /// A server whose run file says its model is loading (transcribe.py serve_loading) is never stuck: the first
    /// dictation's server was ended mid-load (no CPU while the load waited on the disk) and the model loaded twice
    func testALoadingServerIsWorkingNotStuck() {
        XCTAssertEqual(WarmServer.verdict(record: rec, alive: true, argv: argv, script: "transcribe.py",
                                          processStarted: Date(timeIntervalSince1970: 998), answered: false, cpu: 0,
                                          parentAlive: true, loading: true), .working)
        // still not a server, loading or not: the file is stale
        XCTAssertEqual(WarmServer.verdict(record: rec, alive: true, argv: ["/bin/zsh"], script: "transcribe.py",
                                          processStarted: Date(timeIntervalSince1970: 998), answered: false, cpu: 0,
                                          parentAlive: true, loading: true), .notAServer)
        var r = rec
        let now = Date(timeIntervalSince1970: 2000)
        XCTAssertFalse(WarmServer.loading(r, now: now))
        r.loadingSince = now.addingTimeInterval(-20)
        XCTAssertTrue(WarmServer.loading(r, now: now))
        // loading for longer than any load takes: judged like any server
        r.loadingSince = now.addingTimeInterval(-(WarmServer.loadTrusted + 1))
        XCTAssertFalse(WarmServer.loading(r, now: now))
        XCTAssertEqual(DictationASRFailure.serverTimeout(audioSeconds: 4, loading: true), 15 + 6 + DictationASRFailure.loadAllowance)
    }

    func testTheRunFileSaysWhileItsModelLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("run"), withIntermediateDirectories: true)
        let was = getenv("BLURT_HOME").map { String(cString: $0) }
        setenv("BLURT_HOME", dir.path, 1)
        defer {
            if let w = was { setenv("BLURT_HOME", w, 1) } else { unsetenv("BLURT_HOME") }
            try? FileManager.default.removeItem(at: dir)
        }
        let f = dir.appendingPathComponent("run/x.json")
        try #"{"pid": 4242, "port": 50000, "token": "t", "started": "2026-11-21T10:00:00+08:00", "loading_since": "2026-11-21T10:00:01+08:00"}"#
            .write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(WarmServer.record("x")?.loadingSince, ISO8601DateFormatter().date(from: "2026-11-21T10:00:01+08:00"))
        try #"{"pid": 4242, "port": 50000, "token": "t", "started": "2026-11-21T10:00:00+08:00"}"#
            .write(to: f, atomically: true, encoding: .utf8)
        XCTAssertNil(WarmServer.record("x")?.loadingSince)
        XCTAssertFalse(WarmServer.loading("x"))
    }

    /// PolishWait: the Polish time limit holds once the model is loaded; a load is waited for only when it may be ahead
    func testPolishWaitsTheLimitOnceTheModelIsLoaded() {
        // the dogfood case: a loaded server, stopped mid-take, held the text 3 + 12 + 1 = 16 s
        XCTAssertEqual(PolishWait.decide(loaded: true, health: nil, timeout: 3, loadBudget: 12), .wait(4))
        XCTAssertEqual(PolishWait.decide(loaded: true, health: nil, timeout: 3, loadBudget: 12, extra: 5), .wait(9))
        // the model still loading (the preload, or none loaded yet): the load is waited for
        XCTAssertEqual(PolishWait.decide(loaded: false, health: nil, timeout: 3, loadBudget: 12), .wait(16))
        // no answer to the ping: busy (a cold load in the loop, another request) is waited for; stuck is not asked
        XCTAssertEqual(PolishWait.decide(loaded: nil, health: .working, timeout: 3, loadBudget: 12), .wait(16))
        XCTAssertEqual(PolishWait.decide(loaded: nil, health: .stuck(orphaned: false), timeout: 3, loadBudget: 12), .giveUp)
        XCTAssertEqual(PolishWait.decide(loaded: nil, health: .gone, timeout: 3, loadBudget: 12), .giveUp)
    }
}
