// BlurtCore/AgentSetup.swift and ControlSocket.swift (docs/design/agent-setup.md): the socket's path (the same rule as
// setup.py: tests/fixtures/agent_setup_socket.jsonl), requests read strictly (a key only on connect, only for a curated
// service), the grant (a session's token, the user's Allow, nothing else), which agent asks, `use` read against the
// curated list, the live list, status's data — and the socket itself: this user only, 0600, one line each way.
import XCTest
@testable import BlurtCore

final class AgentSetupTests: XCTestCase {
    let deepseek = CloudService(id: "deepseek", preset: "deepseek")
    let ms = CloudService(id: "dashscope", preset: "dashscope", region: .china)
    let volc = CloudService(id: "volcengine-speech", preset: "volcengine-speech", region: .china)
    let kimi = CloudService(id: "moonshot", preset: "moonshot", region: .china)

    var root: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { u.deleteLastPathComponent() }
        return u
    }

    var bundled: CuratedList {
        CuratedList.parse(try! Data(contentsOf: root.appendingPathComponent("skills/blurt/scripts/curated_models.json")))!
    }

    // MARK: where the socket is

    func testTheSocketPathIsTheSameRuleAsSetupPy() throws {
        let text = try String(contentsOf: root.appendingPathComponent("tests/fixtures/agent_setup_socket.jsonl"), encoding: .utf8)
        var n = 0
        for line in text.split(separator: "\n") {
            let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let path = AgentSetup.socketPath(home: URL(fileURLWithPath: o["home"] as! String), uid: uid_t(o["uid"] as! Int))
            XCTAssertEqual(path, o["socket"] as? String)
            XCTAssertLessThanOrEqual(path.utf8.count, AgentSetup.maxSocketPath)
            n += 1
        }
        XCTAssertEqual(n, 2)
    }

    // MARK: requests

    func req(_ o: [String: Any]) -> Result<AgentSetupRequest, AgentSetupError> { AgentSetupRequest.parse(o) }

    func testRequestsAreReadStrictly() {
        XCTAssertEqual(try? req(["op": "status"]).get().op, .status)
        if case .failure(let e) = req(["op": "rm"]) { XCTAssertEqual(e.code, "unknown_op") } else { XCTFail() }
        if case .failure(let e) = req([:]) { XCTAssertEqual(e.code, "bad_request") } else { XCTFail() }
        if case .failure(let e) = req(["op": "use", "job": 3]) { XCTAssertEqual(e.code, "bad_request") } else { XCTFail() }
        if case .failure(let e) = req(["op": "connect", "region": "mars"]) { XCTAssertEqual(e.code, "bad_region") } else { XCTFail() }
        // a key rides only on connect
        if case .failure(let e) = req(["op": "test", "service": "deepseek", "key": "sk-1"]) { XCTAssertEqual(e.code, "bad_request") } else { XCTFail() }
        XCTAssertEqual(try? req(["op": "use", "job": "polish", "option": "x", "custom": true]).get().custom, true)
        XCTAssertFalse(AgentSetupOp.status.needsGrant)
        XCTAssertFalse(AgentSetupOp.hello.needsGrant)
        XCTAssertTrue([AgentSetupOp.connect, .test, .use, .download, .verify].allSatisfy(\.needsGrant))
    }

    func plan(_ o: [String: Any], offered: [String] = ["dashscope", "deepseek", "volcengine-speech"]) -> Result<(preset: CloudPreset, region: CloudRegion?, credential: String), AgentSetupError> {
        var x = o; x["op"] = "connect"
        return try! req(x).get().connectPlan(offered: offered, systemRegion: .global)
    }

    func code<T>(_ r: Result<T, AgentSetupError>) -> String? { if case .failure(let e) = r { return e.code }; return nil }

    func testConnectTakesOnlyACuratedServiceAndAKeyThatCanBeOne() throws {
        let ok = try plan(["preset": "deepseek", "key": " sk-abc123 \n"]).get()
        XCTAssertEqual(ok.preset.id, "deepseek")
        XCTAssertNil(ok.region)
        XCTAssertEqual(ok.credential, "sk-abc123")
        // a regional service: the system's region unless given
        XCTAssertEqual(try plan(["preset": "dashscope", "key": "sk-1"]).get().region, .global)
        XCTAssertEqual(try plan(["preset": "dashscope", "key": "sk-1", "region": "china"]).get().region, .china)
        // not offered, unknown, custom: refused before anything is sent
        XCTAssertEqual(code(plan(["preset": "moonshot", "key": "sk-1"])), "not_curated")
        XCTAssertEqual(code(plan(["preset": "evil", "key": "sk-1"])), "unknown_preset")
        XCTAssertEqual(code(plan(["preset": "custom-openai", "key": "sk-1"])), "unknown_preset")
        XCTAssertEqual(code(plan(["preset": "deepseek"])), "no_key")
        XCTAssertEqual(code(plan(["preset": "deepseek", "key": "sk 1"])), "bad_key")
        XCTAssertEqual(code(plan(["preset": "deepseek", "key": "sk-ç"])), "bad_key")
        // Volcengine Speech: the pair, in mainland China only
        let v = try plan(["preset": "volcengine-speech", "app_id": "123456", "access_token": "tok-1"]).get()
        XCTAssertEqual(v.credential, "123456:tok-1")
        XCTAssertEqual(code(plan(["preset": "volcengine-speech", "key": "sk-1"])), "no_key")
        XCTAssertEqual(code(plan(["preset": "volcengine-speech", "app_id": "12 34", "access_token": "t"])), "bad_key")
        XCTAssertEqual(code(plan(["preset": "volcengine-speech", "app_id": "1", "access_token": "t", "region": "global"])), "bad_region")
        XCTAssertEqual(code(plan(["preset": "deepseek", "app_id": "1", "access_token": "t"])), "bad_key")
    }

    func testAnErrorNeverSaysTheKeyBack() {
        let secret = "sk-supersecret 123"
        guard case .failure(let e) = plan(["preset": "deepseek", "key": secret]) else { return XCTFail() }
        XCTAssertFalse(e.message.contains("supersecret"))
        XCTAssertFalse("\(e.json)".contains("supersecret"))
    }

    // MARK: the grant

    func testOnlyALiveTokenOrTheUsersAllowGrantsChanges() {
        var g = AgentSetupGrant()
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(g.allows(token: nil, now: now))
        let t = g.issue(now: now)
        XCTAssertEqual(t.count, 64)
        XCTAssertTrue(g.allows(token: t, now: now))
        XCTAssertFalse(g.allows(token: String(t.dropLast()) + "0", now: now))
        XCTAssertFalse(g.allows(token: "", now: now))
        XCTAssertFalse(g.allows(token: t, now: now.addingTimeInterval(AgentSetupGrant.sessionTTL + 1)))
        g.revoke(t)
        XCTAssertFalse(g.allows(token: t, now: now))
        g.approve(now: now)
        XCTAssertTrue(g.allows(token: nil, now: now.addingTimeInterval(60)))
        XCTAssertFalse(g.allows(token: nil, now: now.addingTimeInterval(AgentSetupGrant.approvalTTL + 1)))
        let t2 = g.issue(now: now)
        g.revokeAll()
        XCTAssertFalse(g.allows(token: t2, now: now))
        XCTAssertFalse(g.allows(token: nil, now: now))
        XCTAssertNotEqual(g.issue(now: now), g.issue(now: now))
    }

    // MARK: who asks

    func testTheAskingAgentIsFoundAmongTheAncestors() {
        let bins: [(id: String, bins: [String])] = [("claude", ["claude"]), ("codex", ["codex"]), ("gemini", ["gemini"])]
        XCTAssertEqual(AgentSetupPeer.agent(chain: [["/usr/bin/python3", "setup.py", "status"], ["/opt/homebrew/bin/uv", "run"],
                                                    ["/bin/zsh", "-c", "uv run setup.py"],
                                                    ["/Users/a/.local/share/claude/versions/2.1/claude", "--settings", "x"]], bins: bins), "claude")
        XCTAssertEqual(AgentSetupPeer.agent(chain: [["/bin/zsh"], ["/usr/local/bin/node", "/usr/local/lib/node_modules/@google/gemini-cli/bin/gemini", "-i"]], bins: bins), "gemini")
        XCTAssertEqual(AgentSetupPeer.agent(chain: [["/bin/zsh"], ["/opt/homebrew/bin/codex", "exec"]], bins: bins), "codex")
        XCTAssertNil(AgentSetupPeer.agent(chain: [["/bin/zsh"], ["/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"]], bins: bins))
    }

    // MARK: use

    func use(_ job: String, _ option: String, custom: Bool = false, connected: [CloudService]? = nil) -> Result<(choice: AgentSetupChoice, needsTest: Bool), AgentSetupError> {
        AgentSetupChoice.parse(job: job, option: option, custom: custom, connected: connected ?? [deepseek, ms, volc], list: bundled)
    }

    func testUseTakesCuratedModelsOnConnectedServices() throws {
        XCTAssertEqual(try use("polish", "auto").get().choice, .text(.polish, .auto))
        XCTAssertEqual(try use("vision", "local").get().choice, .text(.vision, .local))
        // a service by id or preset: its curated model (kept as the service alone, as Settings does)
        XCTAssertEqual(try use("polish", "deepseek").get().choice, .text(.polish, .cloud(service: "deepseek", model: "")))
        XCTAssertEqual(try use("translate", "dashscope:deepseek-v4.1-flash").get().choice, .text(.translate, .cloud(service: "dashscope", model: "")))
        XCTAssertFalse(try use("polish", "deepseek:deepseek-flash").get().needsTest)
        // not measured: refused unless custom, then tested before it is saved
        XCTAssertEqual(code(use("polish", "deepseek:deepseek-reasoner")), "not_curated")
        let c = try use("polish", "deepseek:deepseek-reasoner", custom: true).get()
        XCTAssertEqual(c.choice, .text(.polish, .cloud(service: "deepseek", model: "deepseek-reasoner")))
        XCTAssertTrue(c.needsTest)
        XCTAssertEqual(code(use("polish", "deepseek:bad model", custom: true)), "bad_model")
        // only connected services; never a speech-only one for a text job; a connected service with no measured model
        XCTAssertEqual(code(use("polish", "openrouter")), "not_connected")
        XCTAssertEqual(code(use("polish", "volcengine-speech")), "unknown_option")
        XCTAssertEqual(code(use("polish", "moonshot", connected: [kimi])), "no_option")
        XCTAssertEqual(code(use("summarize", "local")), "unknown_job")
    }

    func testUseDictationTakesTheComparisonsChoices() throws {
        XCTAssertEqual(try use("dictation", "auto").get().choice, .dictationAuto)
        XCTAssertEqual(try use("dictation", "qwen3-asr-1.7b-mlx").get().choice, .dictation(.qwenLarge))
        XCTAssertEqual(try use("dictation", "cloud-polish").get().choice, .dictation(.cloudPolish))
        XCTAssertEqual(try use("dictation", "volcengine-seedasr").get().choice, .dictation(.volcengine))
        XCTAssertEqual(code(use("dictation", "whisper")), "unknown_option")
    }

    // MARK: the live list

    func testTheLiveListKeepsOneRowPerThing() {
        var s = AgentSetupSteps()
        s.record(AgentSetupStep(.connect, "deepseek", .running, name: "DeepSeek"))
        s.record(AgentSetupStep(.use, "polish", .done, name: "DeepSeek V4.1 Flash"))
        s.record(AgentSetupStep(.connect, "deepseek", .done, name: "DeepSeek"))
        XCTAssertEqual(s.steps.map(\.id), ["connect:deepseek", "use:polish"])
        XCTAssertEqual(s.steps[0].state, .done)
        XCTAssertFalse(s.failed)
        s.record(AgentSetupStep(.verify, "", .failed, name: ""))
        XCTAssertTrue(s.failed)
        // a second attempt at something already over moves to where it happens (dogfood: a test dictation run again
        // at the end sat above the connect)
        s.record(AgentSetupStep(.use, "dictation", .done, name: "x"))
        s.record(AgentSetupStep(.verify, "", .running, name: ""))
        XCTAssertEqual(s.steps.map(\.id), ["connect:deepseek", "use:polish", "use:dictation", "verify:"])
        s.record(AgentSetupStep(.verify, "", .done, name: ""))
        XCTAssertEqual(s.steps.last?.state, .done)
        XCTAssertEqual(s.steps.count, 4)
        s.clear()
        XCTAssertTrue(s.steps.isEmpty)
    }

    func testOnboardingShowsTheLatestRowsAndKeepsAFailedOne() {
        // dogfood 2026-10-31: seven rows pushed onboarding's Back / Next out of its window
        var s = AgentSetupSteps()
        s.record(AgentSetupStep(.connect, "dashscope", .failed, name: "Model Studio"))
        s.record(AgentSetupStep(.connect, "deepseek", .done, name: "DeepSeek"))
        for j in ["polish", "translate", "vision", "dictation"] { s.record(AgentSetupStep(.use, j, .done, name: "x")) }
        s.record(AgentSetupStep(.verify, "", .running, name: ""))
        XCTAssertEqual(s.latest(3).map(\.id), ["connect:dashscope", "use:dictation", "verify:"])
        XCTAssertEqual(s.latest(10).count, 7)
        var two = AgentSetupSteps()
        two.record(AgentSetupStep(.connect, "deepseek", .done, name: "DeepSeek"))
        XCTAssertEqual(two.latest(3).map(\.id), ["connect:deepseek"])
    }

    // MARK: status

    func testStatusDataSaysChoicesRoutesAndOptions() {
        XCTAssertEqual(AgentSetupJSON.choice(.auto) as? String, "auto")
        XCTAssertEqual(AgentSetupJSON.choice(.cloud(service: "deepseek", model: "")) as? [String: String], ["service": "deepseek"])
        let setup = CloudSetup(services: [deepseek, ms])
        let r = AgentSetupJSON.route(.cloud(service: "deepseek", model: "deepseek-flash"), job: .polish, setup: setup, list: bundled)
        XCTAssertEqual(r["name"] as? String, "DeepSeek V4.1 Flash")
        XCTAssertEqual(r["curated"] as? Bool, true)
        let o = AgentSetupJSON.option(bundled.options(CloudJob.polish)[0], connected: [deepseek], note: "Accurate")
        XCTAssertEqual(o["option"] as? String, "dashscope:deepseek-v4.1-flash")
        XCTAssertTrue(o["connected"] is NSNull)
        XCTAssertEqual(AgentSetupJSON.option(bundled.options(CloudJob.polish)[1], connected: [deepseek], note: nil)["connected"] as? String, "deepseek")
        let f = AgentSetupJSON.facts(DictationChoices.facts(.qwenLarge), fit: .needsMemory(16), recommended: false, inUse: false)
        XCTAssertEqual(f["level"] as? Int, 5)
        XCTAssertEqual(f["fits"] as? Bool, false)
        XCTAssertEqual(f["needs"] as? String, "memory_16gb")
        XCTAssertEqual(f["uploads"] as? String, "nothing")
        let v = AgentSetupJSON.facts(DictationChoices.facts(.volcengine), fit: .needsKey, recommended: false, inUse: false)
        XCTAssertEqual(v["uploads"] as? String, "voice")
        XCTAssertEqual(v["to"] as? String, "volcengine-speech")
        XCTAssertNil(f["mixed"], "never an error rate")
    }

    // MARK: verify

    func testVerifyMatchesWhatWasSaidByWordOrCharacter() {
        XCTAssertEqual(AgentSetupVerify.match(said: "Let's meet at three.", heard: "let's meet at three"), 1)
        XCTAssertEqual(AgentSetupVerify.match(said: "one two three four", heard: "one two tree four"), 0.75, accuracy: 0.001)
        XCTAssertEqual(AgentSetupVerify.match(said: "今天下午三点开会。", heard: "今天下午三点开会"), 1)
        XCTAssertEqual(AgentSetupVerify.match(said: "今天下午三点开会", heard: "今天下午四点开会"), 0.875, accuracy: 0.001)
        XCTAssertEqual(AgentSetupVerify.match(said: "hello", heard: ""), 0)
        XCTAssertEqual(AgentSetupVerify.phrase("zh-Hans").locale, "zh_CN")
        XCTAssertEqual(AgentSetupVerify.phrase("de").locale, "en_US")
    }

    func testTheAncestryStartsAtTheProcessItself() {
        let chain = ProcessProbe.ancestry(getpid())
        XCTAssertFalse(chain.isEmpty)
        XCTAssertEqual(ProcessProbe.arguments(getpid()), chain.first)
        XCTAssertNotNil(ProcessProbe.parent(getpid()))
    }

    // MARK: the socket

    func tempDir() -> URL {
        // short: a socket path holds 104 bytes
        let d = URL(fileURLWithPath: "/tmp/bst-\(getpid())-\(Int.random(in: 0..<1_000_000))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testTheSocketAnswersThisUserOneLineEachWay() throws {
        let dir = tempDir().appendingPathComponent("run")
        let path = dir.appendingPathComponent("control.sock").path
        let s = ControlSocket(path: path) { req, peer in ["ok": true, "op": req["op"] ?? "", "uid": Int(peer.uid), "pid": Int(peer.pid)] }
        try s.start()
        defer { s.stop() }
        let a = ControlSocket.call(path, ["op": "status"], timeout: 5)
        XCTAssertEqual(a?["op"] as? String, "status")
        XCTAssertEqual(a?["uid"] as? Int, Int(getuid()))
        XCTAssertEqual(a?["pid"] as? Int, Int(getpid()))
        // private: the folder 0700, the socket 0600
        let dattr = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dattr[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let fattr = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(((fattr[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o600)
        // a second app on the same home leaves it alone
        let other = ControlSocket(path: path) { _, _ in [:] }
        XCTAssertThrowsError(try other.start()) { XCTAssertEqual($0 as? ControlSocket.StartError, .inUse) }
        XCTAssertEqual(ControlSocket.call(path, ["op": "hello"], timeout: 5)?["op"] as? String, "hello")
    }

    func testABadRequestIsAnsweredNotDropped() throws {
        let path = tempDir().appendingPathComponent("c.sock").path
        let s = ControlSocket(path: path) { _, _ in ["ok": true] }
        try s.start()
        defer { s.stop() }
        // raw lines: not JSON, and one far too long
        func raw(_ bytes: Data) -> [String: Any]? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var addr = sockaddr_un()
            XCTAssertTrue(ControlSocket.fill(&addr, path))
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            XCTAssertEqual(ok, 0)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress!, $0.count, 0) }
            guard case .line(let d) = ControlSocket.readLine(fd, max: 1 << 20, timeout: 5) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        XCTAssertEqual(raw(Data("nope\n".utf8))?["code"] as? String, "bad_request")
        XCTAssertEqual(raw(Data(repeating: 0x61, count: AgentSetup.maxRequest + 10) + Data([0x0A]))?["code"] as? String, "too_long")
    }

    func testAStaleSocketFileIsReplacedAndStopRemovesIt() throws {
        let path = tempDir().appendingPathComponent("c.sock").path
        FileManager.default.createFile(atPath: path, contents: Data("old".utf8))
        let s = ControlSocket(path: path) { _, _ in ["ok": true] }
        try s.start()
        XCTAssertEqual(ControlSocket.call(path, ["op": "hello"], timeout: 5)?["ok"] as? Bool, true)
        s.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertNil(ControlSocket.call(path, ["op": "hello"], timeout: 1))
    }

    func testAFolderOpenToOthersIsClosedAndALinkRefused() throws {
        let base = tempDir()
        let open = base.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        chmod(open.path, 0o777)
        try ControlSocket.privateFolder(open.path)
        XCTAssertEqual(((try FileManager.default.attributesOfItem(atPath: open.path))[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: open)
        XCTAssertThrowsError(try ControlSocket.privateFolder(link.path))
    }
}
