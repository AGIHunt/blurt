import XCTest
@testable import BlurtCore

/// Settings → Models from the top (2026-11-16): every service in Add Cloud Model, what a service is used for, and
/// dictation on a speech service only by a click.
final class CloudServiceUseTests: XCTestCase {
    let curated = ["deepseek", "dashscope", "volcengine-speech"]

    func testTheSheetOffersEveryServiceCuratedFirstCompatibleLast() {
        let ids = CloudServiceUse.offered(curated: curated, taken: []).map(\.id)
        XCTAssertEqual(Array(ids.prefix(3)), curated)
        XCTAssertTrue(ids.contains("moonshot") && ids.contains("openai") && ids.contains("openrouter"))
        XCTAssertEqual(Array(ids.suffix(2)), ["custom-openai", "custom-anthropic"])
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testAddedServicesLeaveTheListButCompatibleEndpointsStay() {
        let ids = CloudServiceUse.offered(curated: curated, taken: ["deepseek", "openai", "custom-openai"]).map(\.id)
        XCTAssertFalse(ids.contains("deepseek"))
        XCTAssertFalse(ids.contains("openai"))
        XCTAssertTrue(ids.contains("custom-openai"))
        // the one picked now stays, however it stands
        XCTAssertTrue(CloudServiceUse.offered(curated: curated, taken: ["openai"], keep: "openai").map(\.id).contains("openai"))
    }

    func testDividersAfterCuratedAndBeforeCompatible() {
        let l = CloudServiceUse.offered(curated: curated, taken: [])
        let d = CloudServiceUse.dividers(l, curated: curated)
        XCTAssertTrue(d.contains(3))
        XCTAssertTrue(d.contains(l.count - 2))
        // every curated one added: no divider at the top
        let rest = CloudServiceUse.offered(curated: curated, taken: Set(curated))
        XCTAssertFalse(CloudServiceUse.dividers(rest, curated: curated).contains(0))
    }

    func testAnUntestedServiceAsksForAModelAndStartsOnPolishAndTranslate() {
        XCTAssertFalse(CloudServiceUse.needsModel("deepseek", curated: curated))
        XCTAssertTrue(CloudServiceUse.needsModel("moonshot", curated: curated))
        XCTAssertTrue(CloudServiceUse.needsModel("custom-openai", curated: curated))
        XCTAssertEqual(CloudServiceUse.defaultJobs, [.polish, .translate])
    }

    func testOnlySpeechServicesOfferDictationAndOnlyWhenAllowed() {
        XCTAssertTrue(CloudServiceUse.offersDictation(preset: "dashscope", recognizer: "qwen3-asr-1.7b-mlx", localOnly: false))
        XCTAssertTrue(CloudServiceUse.offersDictation(preset: "volcengine-speech", recognizer: nil, localOnly: false))
        XCTAssertFalse(CloudServiceUse.offersDictation(preset: "deepseek", recognizer: nil, localOnly: false))
        XCTAssertFalse(CloudServiceUse.offersDictation(preset: "openai", recognizer: nil, localOnly: false))
        XCTAssertFalse(CloudServiceUse.offersDictation(preset: "dashscope", recognizer: nil, localOnly: true))
        XCTAssertFalse(CloudServiceUse.offersDictation(preset: "dashscope", recognizer: "qwen3-asr-flash", localOnly: false))
    }

    func testUsesListDictationThenTheJobsOnThisService() {
        let routes: [CloudJob: CloudRoute] = [.polish: .cloud(service: "ds", model: ""), .translate: .cloud(service: "ds", model: "x"),
                                              .vision: .cloud(service: "other", model: "")]
        XCTAssertEqual(CloudServiceUse.uses(serviceID: "ds", preset: "dashscope", routes: routes, recognizer: "qwen3-asr-flash"),
                       [.dictation, .job(.polish), .job(.translate)])
        XCTAssertEqual(CloudServiceUse.uses(serviceID: "v", preset: "volcengine-speech", routes: routes, recognizer: "qwen3-asr-flash"), [])
        XCTAssertEqual(CloudServiceUse.list(["听写润色", "翻译"], chinese: true), "听写润色、翻译")
        XCTAssertEqual(CloudServiceUse.list(["Polish", "Translation"], chinese: false), "Polish, Translation")
    }
}
