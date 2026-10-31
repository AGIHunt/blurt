// BlurtCore/CloudCurated.swift: Settings → Models' curated choices — the list read strictly (a tampered one can't add a
// service or a host), the options per job, where a job goes, the recommendation over a model Blurt didn't measure,
// record.cloud v1's pinning, and a Custom Model's save gate.
import XCTest
@testable import BlurtCore

final class CloudCuratedTests: XCTestCase {
    let deepseek = CloudService(id: "deepseek", preset: "deepseek")
    let ms = CloudService(id: "dashscope", preset: "dashscope", region: .china)
    let msIntl = CloudService(id: "dashscope", preset: "dashscope", region: .global)
    let kimi = CloudService(id: "moonshot", preset: "moonshot", region: .china)

    /// skills/blurt/scripts/curated_models.json, as the app bundles it
    var bundled: CuratedList {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        let data = try! Data(contentsOf: u.appendingPathComponent("scripts/curated_models.json"))
        return CuratedList.parse(data)!
    }

    func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    func list(_ jobs: [String: Any], updated: String = "2026-10-31") -> CuratedList? {
        CuratedList.parse(json(["schema": 1, "updated": updated, "jobs": jobs]))
    }

    func row(_ service: String, _ model: String, regions: [String]? = nil, note: String? = nil) -> [String: Any] {
        var r: [String: Any] = ["service": service, "model": model, "name": model.uppercased(), "measured": "2026-10-31"]
        if let g = regions { r["regions"] = g }
        if let n = note { r["note"] = n }
        return r
    }

    // MARK: the bundled list

    func testTheBundledListIsTheMeasuredChoicesBestFirst() {
        let l = bundled
        XCTAssertEqual(l.options(CuratedJob.polish).map(\.model), ["deepseek-v4.1-flash", "deepseek-flash"])
        XCTAssertEqual(l.options(CuratedJob.polish).map(\.service), ["dashscope", "deepseek"])
        XCTAssertEqual(l.options(CuratedJob.translate).map(\.model), ["deepseek-v4.1-flash", "deepseek-flash"])
        XCTAssertEqual(l.options(CuratedJob.vision).map(\.model), ["qwen3.6-flash", "deepseek-flash"])
        XCTAssertEqual(l.options(CuratedJob.speech).map(\.model), ["qwen3-asr-flash"])
        XCTAssertEqual(l.services, ["dashscope", "deepseek"])
        XCTAssertEqual(l.options(CuratedJob.polish).first?.name, "DeepSeek V4.1 Flash")
        XCTAssertEqual(l.options(CuratedJob.polish).first?.noteKey, "dictation.cloud.model.note.polish.ds41")
        for job in CuratedJob.allCases { XCTAssertLessThanOrEqual(l.options(job).count, 3, job.rawValue) }
    }

    // MARK: read strictly

    func testABadFileIsNilSoTheLastGoodOneStays() {
        XCTAssertNil(CuratedList.parse(Data("not json".utf8)))
        XCTAssertNil(CuratedList.parse(json(["schema": 2, "updated": "2026-11-01", "jobs": ["polish": [row("deepseek", "deepseek-flash")]]])))
        XCTAssertNil(CuratedList.parse(json(["schema": 1, "updated": "soon", "jobs": ["polish": [row("deepseek", "deepseek-flash")]]])))
        XCTAssertNil(list(["polish": [row("evil", "m")]]), "nothing valid in it")
        XCTAssertNil(list([:]))
        XCTAssertNil(CuratedList.parse(Data(repeating: 0x20, count: 70_000)))
    }

    func testAServiceTheAppDoesntKnowOrTheUsersOwnIsDropped() {
        let l = list(["polish": [row("evil-host", "m1"), row("custom-openai", "m2"), row("deepseek", "deepseek-flash")]])!
        XCTAssertEqual(l.options(CuratedJob.polish).map(\.service), ["deepseek"])
    }

    func testAnAddressInTheListIsNeverRead() {
        var r = row("deepseek", "deepseek-flash")
        r["base_url"] = "https://attacker.example/v1"
        r["host"] = "attacker.example"
        let o = list(["polish": [r]])!.options(CuratedJob.polish)[0]
        // the request goes to the preset's address from this build, whatever the list says
        XCTAssertTrue(o.runs(on: deepseek))
        XCTAssertEqual(deepseek.effectiveBaseURL, "https://api.deepseek.com")
    }

    func testOddFieldsDropTheOptionNotTheList() {
        let l = list(["polish": [
            row("deepseek", "bad model id"), row("deepseek", ""), row("deepseek", "ok-1", note: "Not A Key!"),
            ["service": "deepseek", "model": "no-name", "measured": "2026-10-31"],
            ["service": "deepseek", "model": "no-date", "name": "x"],
            row("dashscope", "elsewhere", regions: ["mars"]),
            row("deepseek", "kept", note: "polish.deepseek_flash"),
        ]])!
        XCTAssertEqual(l.options(CuratedJob.polish).map(\.model), ["kept"])
    }

    func testSpeechOnlyOnAServiceThatRecognisesSpeech() {
        let l = list(["speech": [row("deepseek", "deepseek-flash"), row("dashscope", "qwen3-asr-flash")]])!
        XCTAssertEqual(l.options(CuratedJob.speech).map(\.service), ["dashscope"])
    }

    func testRegionsAreTheServicesOwnAndAShortListStaysShort() {
        let l = list(["polish": [row("dashscope", "a", regions: ["global", "mars"]), row("deepseek", "b", regions: ["china"]),
                                 row("dashscope", "a"), row("deepseek", "c"), row("deepseek", "d"), row("deepseek", "e"), row("deepseek", "f")]])!
        XCTAssertEqual(l.options(CuratedJob.polish).map(\.model), ["a", "b", "c", "d"], "duplicates out, four at most")
        XCTAssertEqual(l.options(CuratedJob.polish)[0].regions, [.global])
        XCTAssertEqual(l.options(CuratedJob.polish)[1].regions, [], "DeepSeek has one address: regions don't apply")
        XCTAssertFalse(l.options(CuratedJob.polish)[0].runs(on: ms))
        XCTAssertTrue(l.options(CuratedJob.polish)[0].runs(on: msIntl))
    }

    func testTheNewerListWinsTheFetchedOneOnATie() {
        let a = list(["polish": [row("deepseek", "a")]], updated: "2026-10-31")!
        let b = list(["polish": [row("deepseek", "b")]], updated: "2026-11-02")!
        let c = list(["polish": [row("deepseek", "c")]], updated: "2026-10-31")!
        XCTAssertEqual(CuratedList.newer(a, b), b)
        XCTAssertEqual(CuratedList.newer(b, a), b)
        XCTAssertEqual(CuratedList.newer(a, c), a)
        XCTAssertEqual(CuratedList.newer(nil, c), c)
        XCTAssertNil(CuratedList.newer(nil, nil))
    }

    func testFetchedAtMostOnceADay() {
        let now = Date()
        XCTAssertTrue(CuratedList.refreshDue(last: nil, now: now))
        XCTAssertFalse(CuratedList.refreshDue(last: now.addingTimeInterval(-3_600), now: now))
        XCTAssertTrue(CuratedList.refreshDue(last: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(CuratedList.refreshDue(last: now.addingTimeInterval(3_600), now: now), "a clock set back")
    }

    // MARK: where a job goes

    func testAutoTakesTheFirstCuratedModelOnAConnectedServiceElseThisMac() {
        let l = bundled
        XCTAssertEqual(CuratedRouting.resolve(.polish, choice: .auto, connected: [], list: l), .local)
        XCTAssertEqual(CuratedRouting.resolve(.polish, choice: .auto, connected: [deepseek], list: l), .cloud(service: "deepseek", model: "deepseek-flash"))
        XCTAssertEqual(CuratedRouting.resolve(.polish, choice: .auto, connected: [deepseek, ms], list: l), .cloud(service: "dashscope", model: "deepseek-v4.1-flash"))
        XCTAssertEqual(CuratedRouting.resolve(.vision, choice: .auto, connected: [ms], list: l), .cloud(service: "dashscope", model: "qwen3.6-flash"))
        XCTAssertEqual(CuratedRouting.resolve(.vision, choice: .auto, connected: [deepseek], list: l), .cloud(service: "deepseek", model: "deepseek-flash"))
        // a service Blurt didn't measure is never chosen for the user
        XCTAssertEqual(CuratedRouting.resolve(.polish, choice: .auto, connected: [kimi], list: l), .local)
        XCTAssertEqual(CuratedRouting.resolve(.polish, choice: .auto, connected: [], list: .empty), .local)
    }

    func testAPickedServiceTakesItsCuratedModelAndAPickedModelStays() {
        let l = bundled
        XCTAssertEqual(CuratedRouting.resolve(.translate, choice: .cloud(service: "dashscope", model: ""), connected: [deepseek, ms], list: l),
                       .cloud(service: "dashscope", model: "deepseek-v4.1-flash"))
        XCTAssertEqual(CuratedRouting.resolve(.polish, choice: .cloud(service: "dashscope", model: "qwen3.8-27b"), connected: [ms], list: l),
                       .cloud(service: "dashscope", model: "qwen3.8-27b"))
        XCTAssertEqual(CuratedRouting.resolve(.polish, choice: .cloud(service: "moonshot", model: "kimi-k3"), connected: [kimi], list: l),
                       .cloud(service: "moonshot", model: "kimi-k3"))
        XCTAssertEqual(CuratedRouting.resolve(.polish, choice: .cloud(service: "moonshot", model: ""), connected: [kimi], list: l), .local)
        XCTAssertEqual(CuratedRouting.resolve(.polish, choice: .cloud(service: "dashscope", model: ""), connected: [deepseek], list: l), .local, "gone")
        XCTAssertEqual(CuratedRouting.resolve(.polish, choice: .local, connected: [deepseek], list: l), .local)
    }

    // MARK: the recommendation

    func testAModelBlurtDidntMeasureGetsTheRecommendationOnItsOwnKey() {
        let l = bundled
        // the founder's polish setting (dictation-eval §4.3): qwen3.8-27b on Model Studio
        let r = CuratedRouting.recommendation(.polish, route: .cloud(service: "dashscope", model: "qwen3.8-27b"), connected: [ms], list: l)
        XCTAssertEqual(r?.option.model, "deepseek-v4.1-flash")
        XCTAssertEqual(r?.option.name, "DeepSeek V4.1 Flash")
        XCTAssertEqual(r?.service?.id, "dashscope")
        // only another company's key: the recommendation needs its key first
        let k = CuratedRouting.recommendation(.polish, route: .cloud(service: "moonshot", model: "kimi-k3"), connected: [kimi], list: l)
        XCTAssertEqual(k?.option.service, "dashscope")
        XCTAssertNil(k?.service)
        let d = CuratedRouting.recommendation(.polish, route: .cloud(service: "moonshot", model: "kimi-k3"), connected: [kimi, deepseek], list: l)
        XCTAssertEqual(d?.service?.id, "deepseek")
    }

    func testNothingIsRecommendedOverAMeasuredChoice() {
        let l = bundled
        XCTAssertNil(CuratedRouting.recommendation(.polish, route: .local, connected: [ms], list: l))
        XCTAssertNil(CuratedRouting.recommendation(.polish, route: .cloud(service: "deepseek", model: "deepseek-flash"), connected: [deepseek, ms], list: l),
                     "DeepSeek's own is curated too, though Model Studio's comes first")
        XCTAssertNil(CuratedRouting.recommendation(.vision, route: .cloud(service: "dashscope", model: "qwen3.6-flash"), connected: [ms], list: l))
        XCTAssertNotNil(CuratedRouting.recommendation(.vision, route: .cloud(service: "dashscope", model: "deepseek-v4.1-flash"), connected: [ms], list: l),
                        "curated for polish, not for reading screenshots")
    }

    // MARK: record.cloud v1

    func testV1AutoJobsOnAnUnmeasuredModelArePinnedTheRestStay() {
        let l = bundled
        let v1 = CloudSetup(services: [kimi, ms], jobs: [.polish: .cloud(service: "dashscope", model: "qwen3.8-27b")])
        let legacy: (CloudJob) -> CloudRoute = { job in
            switch job {
            case .polish: return .cloud(service: "dashscope", model: "qwen3.8-27b")
            case .translate: return .cloud(service: "moonshot", model: "kimi-k3")          // Auto took Kimi's newest
            case .vision: return .cloud(service: "dashscope", model: "qwen3.6-flash")     // curated already
            }
        }
        let v2 = CuratedMigration.pin(v1, connected: [kimi, ms], list: l, legacy: legacy)
        XCTAssertEqual(v2.choice(.polish), .cloud(service: "dashscope", model: "qwen3.8-27b"))
        XCTAssertEqual(v2.choice(.translate), .cloud(service: "moonshot", model: "kimi-k3"))
        XCTAssertEqual(v2.choice(.vision), .auto)
        XCTAssertEqual(v2.json["v"] as? Int, 2)
        XCTAssertEqual(CuratedMigration.pin(v1, connected: [], list: l, legacy: { _ in .local }), v1)
    }

    // MARK: Custom Model

    func testACustomModelIsCheckedBeforeItIsTried() {
        XCTAssertEqual(CloudCustom.problem(baseURL: "http://api.example.com/v1", model: "m", typedKey: "sk-1", keySaved: false), .address)
        XCTAssertNil(CloudCustom.problem(baseURL: "http://127.0.0.1:8080/v1", model: "m", typedKey: "sk-1", keySaved: false), "a server on this Mac")
        XCTAssertEqual(CloudCustom.problem(baseURL: "https://api.moonshot.cn/v1", model: " ", typedKey: "sk-1", keySaved: false), .model)
        XCTAssertEqual(CloudCustom.problem(baseURL: "https://api.moonshot.cn/v1", model: "kimi k3", typedKey: "sk-1", keySaved: false), .model)
        XCTAssertEqual(CloudCustom.problem(baseURL: "https://api.moonshot.cn/v1", model: "kimi-k3", typedKey: "", keySaved: false), .key(.empty))
        XCTAssertEqual(CloudCustom.problem(baseURL: "https://api.moonshot.cn/v1", model: "kimi-k3", typedKey: "sk-1ç", keySaved: false), .key(.characters))
        XCTAssertNil(CloudCustom.problem(baseURL: "https://api.moonshot.cn/v1", model: "kimi-k3", typedKey: "", keySaved: true))
        XCTAssertNil(CloudCustom.problem(baseURL: "https://openrouter.ai/api/v1", model: "moonshotai/kimi-k3", typedKey: "sk-or-1", keySaved: false))
    }

    func testACustomModelIsSavedOnlyWhenItsJobsTestPassed() {
        XCTAssertEqual(CloudCustom.outcome(["ok": true, "ms": 800]), .save)
        XCTAssertEqual(CloudCustom.outcome(["ok": false, "code": "vision"]), .refuse(code: "vision"))
        XCTAssertEqual(CloudCustom.outcome(["ok": false, "code": "empty"]), .refuse(code: "empty"))
        XCTAssertEqual(CloudCustom.outcome(["ok": false]), .refuse(code: "failed"))
        XCTAssertEqual(CloudCustom.outcome(nil), .refuse(code: "failed"))
    }
}
