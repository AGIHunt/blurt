// BlurtCore/CloudServices.swift: Settings → Models' cloud services and which model does each text job — the presets, a
// /models answer read and filtered for a job (newest first), the defaults, Auto, and the migration from the one
// "cloud polish" service of v1.0.7 and before.
import XCTest
@testable import BlurtCore

final class CloudServicesTests: XCTestCase {
    // MARK: presets

    func testPresetsSpeakAProtocolPolishCanSendAndDeepSeekLeads() {
        XCTAssertEqual(CloudPreset.all.first?.id, "deepseek")
        XCTAssertTrue(CloudPreset.all.first!.recommended)
        XCTAssertEqual(CloudPreset.all.filter(\.recommended).count, 1)
        XCTAssertEqual(Set(CloudPreset.all.map(\.id)).count, CloudPreset.all.count)
        for p in CloudPreset.all {
            XCTAssertTrue([.openai, .anthropic].contains(p.api), p.id)
            for e in p.endpoints {
                // a speech-only service's address is the websocket transcribe.py opens
                XCTAssertTrue(e.baseURL.hasPrefix(p.speechOnly ? "wss://" : "https://"), "\(p.id) \(e.baseURL)")
                XCTAssertFalse(e.baseURL.hasSuffix("/"), "\(p.id): base URLs end without a slash (polish_cloud adds the path)")
                XCTAssertNotNil(URL(string: e.keyPage), p.id)
            }
            // a China and an international address, or one
            if p.regional { XCTAssertEqual(Set(p.endpoints.compactMap(\.region)), Set(CloudRegion.allCases), p.id) }
        }
        XCTAssertEqual(CloudPreset.all.filter(\.custom).map(\.id), ["custom-openai", "custom-anthropic"])
        // the regions the founder asked for
        for id in ["dashscope", "volcengine", "moonshot", "zhipu", "minimax"] { XCTAssertTrue(CloudPreset.preset(id)!.regional, id) }
        // speech: Model Studio, Volcengine Speech and OpenAI only (transcribe.py speaks those); Volcengine Speech does
        // nothing else and takes an App ID + Access Token pair
        XCTAssertEqual(CloudPreset.all.filter(\.speech).map(\.id), ["dashscope", "volcengine-speech", "openai"])
        XCTAssertEqual(CloudPreset.all.filter(\.speechOnly).map(\.id), ["volcengine-speech"])
        XCTAssertEqual(CloudPreset.all.filter(\.pairCredential).map(\.id), ["volcengine-speech"])
        XCTAssertFalse(CloudPreset.preset("volcengine-speech")!.regional)
    }

    func testTheSystemRegionPicksTheAddress() {
        XCTAssertEqual(CloudRegion.forSystem("CN"), .china)
        XCTAssertEqual(CloudRegion.forSystem("US"), .global)
        XCTAssertEqual(CloudRegion.forSystem(nil), .global)
        let ms = CloudPreset.preset("dashscope")!
        XCTAssertEqual(ms.endpoint(.china)?.baseURL, "https://dashscope.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(ms.endpoint(.global)?.baseURL, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(CloudPreset.preset("deepseek")!.endpoint(.china)?.baseURL, "https://api.deepseek.com")
    }

    func testAKeyNamesItsServiceOnlyWhenItsStartIsUnique() {
        XCTAssertEqual(CloudPreset.detect(key: "sk-ant-api03-abc"), "anthropic")
        XCTAssertEqual(CloudPreset.detect(key: " sk-or-v1-abc\n"), "openrouter")
        XCTAssertEqual(CloudPreset.detect(key: "AIzaSyabc"), "gemini")
        XCTAssertEqual(CloudPreset.detect(key: "sk-proj-abc"), "openai")
        // DeepSeek, Model Studio, Moonshot, MiMo… all start with sk-: not guessed
        XCTAssertNil(CloudPreset.detect(key: "sk-0123456789abcdef"))
        XCTAssertNil(CloudPreset.detect(key: ""))
    }

    func testAKeyWithCharactersNoHeaderCarriesIsRefused() {
        XCTAssertNil(CloudKeyCheck.problem("  sk-abc123 \n"))
        XCTAssertEqual(CloudKeyCheck.problem("   "), .empty)
        XCTAssertEqual(CloudKeyCheck.problem("sk-abc 123"), .spaces)
        // the founder's key, 2026-10-31: two "ç" as ⌥C types them (c + U+0327)
        XCTAssertEqual(CloudKeyCheck.problem("sk-abc" + "c\u{0327}c\u{0327}"), .characters)
        XCTAssertEqual(CloudKeyCheck.problem("sk-abcç"), .characters)
    }

    // MARK: services

    func testAServiceRoundTripsAndKnowsItsAddress() {
        let s = CloudService(id: "dashscope", preset: "dashscope", region: .global)
        XCTAssertEqual(CloudService(json: s.json), s)
        XCTAssertEqual(s.effectiveBaseURL, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(s.modelsURL?.absoluteString, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models")
        let a = CloudService(id: "anthropic", preset: "anthropic")
        XCTAssertEqual(a.modelsURL?.absoluteString, "https://api.anthropic.com/v1/models?limit=1000")
        let own = CloudService(id: "custom-1", preset: "custom-openai", baseURL: " https://llm.example.com/v1/ ")
        XCTAssertEqual(own.host, "llm.example.com")
        XCTAssertEqual(own.modelsURL?.absoluteString, "https://llm.example.com/v1/models")
        XCTAssertNil(CloudService(json: ["id": "x", "preset": "nonesuch"]))
        // a typed address at the preset's own place keeps the docs' ids; another address doesn't
        XCTAssertFalse(CloudService(id: "zhipu", preset: "zhipu", region: .china).known.isEmpty)
        XCTAssertTrue(CloudService(id: "zhipu", preset: "zhipu", baseURL: "https://proxy.example.com/v4").known.isEmpty)
    }

    func testNewServicesTakeTheirPresetsIdOnce() {
        XCTAssertEqual(CloudService.newID(preset: "deepseek", taken: []), "deepseek")
        XCTAssertEqual(CloudService.newID(preset: "openai", taken: ["openai"]), "openai-2")
        XCTAssertEqual(CloudService.newID(preset: "custom-openai", taken: ["custom-1"]), "custom-2")
        XCTAssertEqual(CloudService.newID(preset: "custom-anthropic", taken: []), "custom-1")
    }

    func testTheSetupRoundTripsAndAutoIsLeftOut() {
        var s = CloudSetup(services: [CloudService(id: "deepseek", preset: "deepseek")])
        s.jobs[.polish] = .cloud(service: "deepseek", model: "")
        s.jobs[.translate] = .local
        let j = s.json
        XCTAssertEqual((j["jobs"] as? [String: Any])?.keys.sorted(), ["polish", "translate"])
        XCTAssertEqual(CloudSetup(json: j), s)
        XCTAssertEqual(CloudSetup(json: j).choice(.vision), .auto)
        XCTAssertEqual(CloudJobChoice(json: ["service": "deepseek", "model": "deepseek-flash"]), .cloud(service: "deepseek", model: "deepseek-flash"))
        XCTAssertEqual(CloudJobChoice(json: "nonsense"), .auto)
    }

    // MARK: lists

    func json(_ s: String) -> Data { Data(s.utf8) }

    func testListsOfEveryShapeAreRead() throws {
        // OpenAI: created, no capabilities
        let openai = try XCTUnwrap(CloudModelList.parse(json(#"{"object":"list","data":[{"id":"gpt-6-luna","created":1790000000,"owned_by":"openai"}]}"#)))
        XCTAssertEqual(openai, [CloudModelInfo(id: "gpt-6-luna", created: 1_790_000_000)])
        // DeepSeek: no date, input modalities
        let ds = try XCTUnwrap(CloudModelList.parse(json(#"{"data":[{"id":"deepseek-flash","input_modalities":["text","image"],"output_modalities":["text"]},{"id":"deepseek-v4-pro","input_modalities":["text"]}]}"#)))
        XCTAssertEqual(ds.map(\.vision), [true, false])
        XCTAssertEqual(ds.first?.text, true)
        // Moonshot
        let kimi = try XCTUnwrap(CloudModelList.parse(json(#"{"data":[{"id":"kimi-k3","created":1780000000,"supports_image_in":true}]}"#)))
        XCTAssertEqual(kimi.first?.vision, true)
        // OpenRouter: architecture
        let or = try XCTUnwrap(CloudModelList.parse(json(#"{"data":[{"id":"x/img","name":"Img","created":1,"architecture":{"input_modalities":["text"],"output_modalities":["image"]}}]}"#)))
        XCTAssertEqual(or.first?.text, false)
        XCTAssertEqual(or.first?.name, "Img")
        // Anthropic: created_at, display_name, capabilities
        let claude = try XCTUnwrap(CloudModelList.parse(json(#"{"data":[{"id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5","created_at":"2026-09-01T00:00:00Z","capabilities":{"image_input":{"supported":true}}}],"has_more":false}"#)))
        XCTAssertEqual(claude.first?.name, "Claude Haiku 5.5")
        XCTAssertEqual(claude.first?.vision, true)
        XCTAssertNotNil(claude.first?.created)
        // Gemini through its OpenAI layer: "models/…"
        let gem = try XCTUnwrap(CloudModelList.parse(json(#"{"object":"list","data":[{"id":"models/gemini-3.8-flash","object":"model"}]}"#)))
        XCTAssertEqual(gem.first?.id, "gemini-3.8-flash")
        XCTAssertNil(CloudModelList.parse(json(#"{"error":{"message":"no"}}"#)))
        XCTAssertNil(CloudModelList.parse(json("not json")))
        // the cache's own form
        let m = CloudModelInfo(id: "a", name: "A", created: 2, vision: true, text: true)
        XCTAssertEqual(CloudModelInfo(json: m.json), m)
    }

    func testAJobListsOnlyModelsThatFitNewestFirst() {
        let ms = CloudPreset.preset("dashscope")!
        let list = ["qwen3.6-flash", "qwen3.8-flash", "qwen3.6-flash-2026-04-16", "text-embedding-v4", "qwen3-asr-flash",
                    "qwen3-vl-plus", "qwen-vl-ocr", "wanx2.1-t2i-plus", "qwen3-tts-flash", "deepseek-v4.1-flash", "qwen3.8-omni-flash"]
            .map { CloudModelInfo(id: $0) }
        let polish = CloudModelList.suitable(list, .polish, preset: ms).map(\.id)
        XCTAssertEqual(polish, ["qwen3.8-flash", "qwen3.6-flash", "deepseek-v4.1-flash"])
        let vision = CloudModelList.suitable(list, .vision, preset: ms).map(\.id)
        // measured readers (qwen3.6-flash) and ids that name reading; never speech, embeddings or picture makers
        XCTAssertEqual(Set(vision), ["qwen3.6-flash", "qwen3-vl-plus", "qwen-vl-ocr", "qwen3.8-omni-flash"])
        // the list's own dates win over the names
        let dated = [CloudModelInfo(id: "kimi-k2.6", created: 300), CloudModelInfo(id: "kimi-k3", created: 200)]
        XCTAssertEqual(CloudModelList.suitable(dated, .polish, preset: CloudPreset.preset("moonshot")).map(\.id), ["kimi-k2.6", "kimi-k3"])
        // a service whose models all read pictures, and one whose list says which
        XCTAssertEqual(CloudModelList.suitable([CloudModelInfo(id: "claude-haiku-5-5")], .vision, preset: CloudPreset.preset("anthropic")).count, 1)
        XCTAssertEqual(CloudModelList.suitable([CloudModelInfo(id: "deepseek-v4-pro", vision: false)], .vision, preset: CloudPreset.preset("deepseek")).count, 0)
        XCTAssertEqual(CloudModelList.suitable([CloudModelInfo(id: "img", text: false)], .polish, preset: nil).count, 0)
    }

    func testVersionsCompareAsNumbers() {
        XCTAssertEqual(CloudModelList.naturalCompare("qwen3.8-flash", "qwen3.6-flash"), 1)
        XCTAssertEqual(CloudModelList.naturalCompare("glm-4.7", "glm-5.3"), -1)
        XCTAssertEqual(CloudModelList.naturalCompare("gemini-3.10-flash", "gemini-3.8-flash"), 1)
        XCTAssertEqual(CloudModelList.naturalCompare("a", "a"), 0)
    }

    func testTheDefaultIsTheMeasuredOneWhileListedElseTheNewestFastOne() {
        let ds = CloudPreset.preset("deepseek")!, ms = CloudPreset.preset("dashscope")!
        let dsList = [CloudModelInfo(id: "deepseek-flash", vision: true), CloudModelInfo(id: "deepseek-v4-pro", vision: false)]
        XCTAssertEqual(CloudModelList.defaultModel(.polish, preset: ds, models: dsList), "deepseek-flash")
        XCTAssertEqual(CloudModelList.defaultModel(.vision, preset: ds, models: dsList), "deepseek-flash")
        // no list yet: the measured one
        XCTAssertEqual(CloudModelList.defaultModel(.vision, preset: ms, models: nil), "qwen3.6-flash")
        XCTAssertEqual(CloudModelList.defaultModel(.translate, preset: ms, models: nil), "deepseek-v4.1-flash")
        // the measured model left the list: the newest fast one
        let msList = ["qwen3.9-max", "qwen3.9-flash", "qwen3.8-flash"].map { CloudModelInfo(id: $0) }
        XCTAssertEqual(CloudModelList.defaultModel(.polish, preset: ms, models: msList), "qwen3.9-flash")
        // Kimi: no measurement, nothing stale: the list's newest of the fast tier
        let kimi = CloudPreset.preset("moonshot")!
        let kList = [CloudModelInfo(id: "kimi-k3.1-pro", created: 300), CloudModelInfo(id: "kimi-k3.1-pro-highspeed", created: 299),
                     CloudModelInfo(id: "kimi-k3", created: 200), CloudModelInfo(id: "kimi-k2-turbo", created: 100)]
        XCTAssertEqual(CloudModelList.defaultModel(.polish, preset: kimi, models: kList), "kimi-k3.1-pro-highspeed")
        // no fast tier at all: the newest
        XCTAssertEqual(CloudModelList.defaultModel(.polish, preset: kimi, models: [CloudModelInfo(id: "a-1", created: 1), CloudModelInfo(id: "a-2", created: 2)]), "a-2")
        // nothing known and no list: none (the user picks one)
        XCTAssertNil(CloudModelList.defaultModel(.polish, preset: kimi, models: nil))
        XCTAssertNil(CloudModelList.defaultModel(.vision, preset: kimi, models: [CloudModelInfo(id: "kimi-k3", vision: false)]))
    }

    func testMeasuredNotesAreOnlyForWhatWasMeasured() {
        XCTAssertEqual(CloudModelList.note(.polish, preset: "dashscope", model: "deepseek-v4.1-flash"), "dictation.cloud.model.note.polish.ds41")
        XCTAssertNil(CloudModelList.note(.polish, preset: "openrouter", model: "deepseek-flash"))
        XCTAssertNil(CloudModelList.note(.polish, preset: "dashscope", model: "qwen3.9-flash"))
    }

    // MARK: Auto

    let deepseek = CloudService(id: "deepseek", preset: "deepseek")
    let kimi = CloudService(id: "moonshot", preset: "moonshot", region: .global)
    let ms = CloudService(id: "dashscope", preset: "dashscope", region: .china)

    func testAutoTakesTheBestConnectedServiceElseThisMac() {
        let lists: [String: [CloudModelInfo]] = ["moonshot": [CloudModelInfo(id: "kimi-k3", created: 1, vision: true)]]
        let models: (CloudService) -> [CloudModelInfo]? = { lists[$0.id] }
        XCTAssertEqual(CloudRouting.resolve(.polish, choice: .auto, connected: [], models: models), .local)
        // DeepSeek before Kimi whatever the order they were added in
        XCTAssertEqual(CloudRouting.resolve(.polish, choice: .auto, connected: [kimi, deepseek], models: models),
                       .cloud(service: "deepseek", model: "deepseek-flash"))
        XCTAssertEqual(CloudRouting.resolve(.polish, choice: .auto, connected: [kimi], models: models), .cloud(service: "moonshot", model: "kimi-k3"))
        // Kimi's list not read yet and nothing measured there: this Mac until it is
        XCTAssertEqual(CloudRouting.resolve(.polish, choice: .auto, connected: [kimi], models: { _ in nil }), .local)
        // Zhipu has no list: the docs' ids stand in
        let glm = CloudService(id: "zhipu", preset: "zhipu", region: .china)
        XCTAssertEqual(CloudRouting.resolve(.vision, choice: .auto, connected: [glm], models: { _ in nil }), .cloud(service: "zhipu", model: "glm-5.3-flash"))
        // Copy Text from Screen skips a service that can't read pictures
        let noEyes: (CloudService) -> [CloudModelInfo]? = { $0.id == "deepseek" ? [CloudModelInfo(id: "deepseek-v4-pro", vision: false)] : lists[$0.id] }
        XCTAssertEqual(CloudRouting.resolve(.vision, choice: .auto, connected: [deepseek, kimi], models: noEyes), .cloud(service: "moonshot", model: "kimi-k3"))
    }

    func testAPickedServiceStaysAndAGoneOneFallsBackToThisMac() {
        XCTAssertEqual(CloudRouting.resolve(.translate, choice: .cloud(service: "dashscope", model: "qwen3.8-flash"), connected: [deepseek, ms], models: { _ in nil }),
                       .cloud(service: "dashscope", model: "qwen3.8-flash"))
        XCTAssertEqual(CloudRouting.resolve(.translate, choice: .cloud(service: "dashscope", model: ""), connected: [deepseek, ms], models: { _ in nil }),
                       .cloud(service: "dashscope", model: "deepseek-v4.1-flash"))
        // removed: this Mac, never another company's service
        XCTAssertEqual(CloudRouting.resolve(.translate, choice: .cloud(service: "dashscope", model: ""), connected: [deepseek], models: { _ in nil }), .local)
        XCTAssertEqual(CloudRouting.resolve(.polish, choice: .local, connected: [deepseek], models: { _ in nil }), .local)
    }

    // MARK: migration

    func testCloudPolishOnCarriesOverAsItWas() {
        let d: [String: Any] = ["cloud_polish": ["on": true, "provider": "deepseek"], "translate": ["cloud": true]]
        let s = CloudMigration.migrate(dictation: d, screenText: ["refine": "cloud"], keys: ["deepseek"], speechKey: false)
        XCTAssertEqual(s.services, [CloudService(id: "deepseek", preset: "deepseek")])
        XCTAssertEqual(s.choice(.polish), .cloud(service: "deepseek", model: ""))
        XCTAssertEqual(s.choice(.translate), .cloud(service: "deepseek", model: ""))
        XCTAssertEqual(s.choice(.vision), .cloud(service: "deepseek", model: ""))
    }

    func testModelStudioWithItsModelsAndTheSpeechKey() {
        let d: [String: Any] = ["cloud_polish": ["on": true, "provider": "dashscope", "model": "qwen3.8-flash", "translate_model": "qwen3.6-flash",
                                                 "vision_model": "qwen3-vl-plus", "base_url": "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"]]
        let s = CloudMigration.migrate(dictation: d, screenText: ["refine": "local", "translate": ["cloud": false]], keys: ["dashscope"], speechKey: true)
        XCTAssertEqual(s.services, [CloudService(id: "dashscope", preset: "dashscope", region: .global)])
        XCTAssertEqual(s.choice(.polish), .cloud(service: "dashscope", model: "qwen3.8-flash"))
        // dictation's translate switch was on (the default): the cloud translated, with translate's own model
        XCTAssertEqual(s.choice(.translate), .cloud(service: "dashscope", model: "qwen3.6-flash"))
        XCTAssertEqual(s.choice(.vision), .local)
    }

    func testCloudPolishOffStaysOnThisMacAndASpeechOnlyKeyChangesNoTextJob() {
        let off = CloudMigration.migrate(dictation: ["cloud_polish": ["on": false, "provider": "deepseek"], "translate": ["cloud": false]],
                                         screenText: ["translate": ["cloud": false]], keys: ["deepseek"], speechKey: false)
        XCTAssertEqual(off.choice(.polish), .local)
        XCTAssertEqual(off.choice(.translate), .local)
        XCTAssertEqual(off.choice(.vision), .auto)         // ⌥C read nothing again: Auto when it is turned on
        // only a Model Studio key for cloud speech: connected (speech keeps working), every text job where it was
        let speech = CloudMigration.migrate(dictation: [:], screenText: [:], keys: [], speechKey: true)
        XCTAssertEqual(speech.services.map(\.id), ["dashscope"])
        XCTAssertEqual(speech.choice(.polish), .local)
        XCTAssertEqual(speech.choice(.translate), .local)
    }

    func testOwnAddressesBecomeCustomServicesOnTheSameKeychainAccount() {
        let d: [String: Any] = ["cloud_polish": ["on": true, "provider": "openai", "base_url": "https://llm.example.com/v1", "model": "my-model"]]
        let s = CloudMigration.migrate(dictation: d, screenText: [:], keys: ["openai", "anthropic"], speechKey: false)
        XCTAssertEqual(s.services, [CloudService(id: "openai", preset: "custom-openai", baseURL: "https://llm.example.com/v1"),
                                    CloudService(id: "anthropic", preset: "anthropic")])
        XCTAssertEqual(s.choice(.polish), .cloud(service: "openai", model: "my-model"))
        XCTAssertEqual(s.choice(.translate), .cloud(service: "openai", model: "my-model"))
    }

    func testNoKeyNoServiceEverythingAuto() {
        let s = CloudMigration.migrate(dictation: ["cloud_polish": ["on": true, "provider": "deepseek"]], screenText: ["refine": "cloud"],
                                       keys: [], speechKey: false)
        XCTAssertEqual(s, CloudSetup())
    }
}
