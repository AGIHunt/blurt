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
        // a 3 s piece: not before 3 s, and only with the server's CPU still for 2 s
        XCTAssertFalse(DictationASRFailure.hung(waited: 2.5, audioSeconds: 3, cpuIdle: 2.5))
        XCTAssertTrue(DictationASRFailure.hung(waited: 3.1, audioSeconds: 3, cpuIdle: 2.1))
        XCTAssertFalse(DictationASRFailure.hung(waited: 12, audioSeconds: 3, cpuIdle: 0))      // busy: waited for
        // a 20 s piece gets 10 s
        XCTAssertFalse(DictationASRFailure.hung(waited: 8, audioSeconds: 20, cpuIdle: 8))
        XCTAssertTrue(DictationASRFailure.hung(waited: 10, audioSeconds: 20, cpuIdle: 8))
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
}
