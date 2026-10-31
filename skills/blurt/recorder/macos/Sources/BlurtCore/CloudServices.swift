// Settings → Models (docs/design/system.md §3.4; dictation.md §Cloud polish): the cloud services the user connected and
// which model does each text job — polish, translate, Copy Text from Screen — as data. The app keeps the keys (login
// Keychain); this file is the part without side effects: the presets (their addresses: the only hosts a key ever goes
// to), a service's stored shape, the key's first sanity check, and the one-time migration from the single "cloud
// polish" service (record.dictation.cloud_polish) to this. Which models a job offers is the curated list's
// (CloudCurated.swift, since 2026-10-31); the open-list code below (a /models answer read into CloudModelInfo, which
// models fit a job, the newest default, CloudRouting.resolve) is v1's rule, kept only to pin v1 setups' Auto jobs.
//
// record.cloud = {"v": 2,
//                 "services": [{"id", "preset", "region"?, "base_url"?, "name"?}],     id = the Keychain account
//                 "jobs": {"polish" | "translate" | "vision": "local" | {"service", "model"}}}   absent = Auto
//
// The presets' addresses and protocols were read from each service's docs on 2026-10-31 (the report in
// docs/design/first-minute-speech.md §10.1). DeepSeek and Model Studio are the curated list's services today; the others
// are offered for a Custom Model.
import Foundation

public enum CloudRegion: String, CaseIterable, Hashable {
    case china, global

    /// The system region's pick: mainland China → the China address, anywhere else → the international one.
    public static func forSystem(_ regionCode: String?) -> CloudRegion { regionCode == "CN" ? .china : .global }
}

public enum CloudProtocol: String, Hashable { case openai, anthropic }

/// One model of a service's list: what the list said about it (nil = it didn't say).
public struct CloudModelInfo: Hashable {
    public let id: String
    public var name: String?
    /// seconds since 1970, from the list's `created` / `created_at`
    public var created: Double?
    /// it takes images (the list's input modalities, supports_image_in, capabilities.image_input)
    public var vision: Bool?
    /// it answers in text (false: the list says it makes images, audio or embeddings only)
    public var text: Bool?

    public init(id: String, name: String? = nil, created: Double? = nil, vision: Bool? = nil, text: Bool? = nil) {
        self.id = id; self.name = name; self.created = created; self.vision = vision; self.text = text
    }

    public init?(json o: [String: Any]) {
        guard let id = o["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        name = o["name"] as? String
        created = o["created"] as? Double ?? (o["created"] as? Int).map(Double.init)
        vision = o["vision"] as? Bool
        text = o["text"] as? Bool
    }

    public var json: [String: Any] {
        var o: [String: Any] = ["id": id]
        if let n = name { o["name"] = n }
        if let c = created { o["created"] = c }
        if let v = vision { o["vision"] = v }
        if let t = text { o["text"] = t }
        return o
    }
}

public struct CloudEndpoint: Hashable {
    public let region: CloudRegion?
    public let baseURL: String
    /// where a key is made
    public let keyPage: String
    /// the ids the docs named, newest first — only for a service whose API has no model list
    public let known: [CloudModelInfo]

    public init(_ region: CloudRegion?, _ baseURL: String, key keyPage: String, known: [CloudModelInfo] = []) {
        self.region = region; self.baseURL = baseURL; self.keyPage = keyPage; self.known = known
    }
}

public struct CloudPreset: Hashable, Identifiable {
    public let id: String
    public let api: CloudProtocol
    /// one address, or a China and an international one; none: the user's own (Custom)
    public let endpoints: [CloudEndpoint]
    /// its key also recognises speech in Blurt (Model Studio's qwen3-asr-flash, OpenAI's transcription)
    public let speech: Bool
    /// every chat model it lists takes images, when the list itself doesn't say
    public let allSeeImages: Bool
    /// a pasted key that starts like this is this service's (only prefixes no other service uses)
    public let keyPrefixes: [String]

    public var custom: Bool { endpoints.isEmpty }
    /// it only recognises speech (no text models): its Test is a short clip, it takes no base URL
    public var speechOnly: Bool { id == VolcengineSpeech.preset }
    /// its credential is an App ID + Access Token pair (VolcengineSpeech), not one API key
    public var pairCredential: Bool { id == VolcengineSpeech.preset }
    /// DeepSeek: listed first, marked Recommended, and the one price the app shows (it is cheap: the founder)
    public var recommended: Bool { id == "deepseek" }
    public var regional: Bool { endpoints.count > 1 }

    public func endpoint(_ region: CloudRegion?) -> CloudEndpoint? {
        endpoints.first { $0.region == region } ?? endpoints.first
    }

    /// In the order the app lists them (and Auto prefers them): DeepSeek first, then the services by where most of
    /// their users are, the user's own last.
    public static let all: [CloudPreset] = {
        func m(_ id: String, vision: Bool? = nil) -> CloudModelInfo { CloudModelInfo(id: id, vision: vision, text: true) }
        return [
            CloudPreset(id: "deepseek", api: .openai, endpoints: [
                CloudEndpoint(nil, "https://api.deepseek.com", key: "https://platform.deepseek.com/api_keys"),
            ], speech: false, allSeeImages: false, keyPrefixes: []),
            // Alibaba Cloud Model Studio (阿里云百炼): Beijing, or Singapore for an international account — a key works
            // only in its own region
            CloudPreset(id: "dashscope", api: .openai, endpoints: [
                CloudEndpoint(.china, "https://dashscope.aliyuncs.com/compatible-mode/v1",
                              key: "https://bailian.console.aliyun.com/?tab=model#/api-key"),
                CloudEndpoint(.global, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
                              key: "https://modelstudio.console.alibabacloud.com/?tab=model#/api-key"),
            ], speech: true, allSeeImages: false, keyPrefixes: []),
            // ByteDance: Volcengine Ark (火山方舟) in China, BytePlus ModelArk elsewhere; the model field takes the
            // model's own id. No list with an API key (the console's ListFoundationModels needs AK/SK signing).
            CloudPreset(id: "volcengine", api: .openai, endpoints: [
                CloudEndpoint(.china, "https://ark.cn-beijing.volces.com/api/v3",
                              key: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey",
                              known: ["doubao-seed-2-1-pro-260915", "doubao-seed-2-1-lite-260915", "doubao-seed-2-1-turbo-260628",
                                      "doubao-seed-2-0-lite-260428", "doubao-seed-2-0-mini-260428"].map { m($0, vision: true) }),
                CloudEndpoint(.global, "https://ark.ap-southeast.bytepluses.com/api/v3",
                              key: "https://console.byteplus.com/ark/region:ark+ap-southeast-1/apiKey",
                              known: ["dola-seed-2-1-turbo-260628", "seed-2-0-pro-260328"].map { m($0, vision: true) }),
            ], speech: false, allSeeImages: true, keyPrefixes: []),
            // ByteDance's Volcengine Speech (火山引擎豆包语音): speech recognition only, mainland China — Seed-ASR 2.0
            // streamed while the user talks (VolcengineSpeech.swift). Its credential is an App ID + Access Token pair,
            // made in the speech console; the address is the websocket transcribe.py opens (not editable).
            CloudPreset(id: VolcengineSpeech.preset, api: .openai, endpoints: [
                CloudEndpoint(.china, "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream",
                              key: "https://console.volcengine.com/speech/app"),
            ], speech: true, allSeeImages: false, keyPrefixes: []),
            CloudPreset(id: "moonshot", api: .openai, endpoints: [
                CloudEndpoint(.china, "https://api.moonshot.cn/v1", key: "https://platform.kimi.com/"),
                CloudEndpoint(.global, "https://api.moonshot.ai/v1", key: "https://platform.kimi.ai/"),
            ], speech: false, allSeeImages: false, keyPrefixes: []),
            // Zhipu: no model list at all
            CloudPreset(id: "zhipu", api: .openai, endpoints: [
                CloudEndpoint(.china, "https://open.bigmodel.cn/api/paas/v4", key: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys",
                              known: zhipuKnown),
                CloudEndpoint(.global, "https://api.z.ai/api/paas/v4", key: "https://z.ai/manage-apikey/apikey-list", known: zhipuKnown),
            ], speech: false, allSeeImages: false, keyPrefixes: []),
            CloudPreset(id: "minimax", api: .openai, endpoints: [
                CloudEndpoint(.china, "https://api.minimax.cn/v1", key: "https://platform.minimax.cn/",
                              known: [m("MiniMax-M3.1-Flash", vision: true), m("MiniMax-M3", vision: true)]),
                CloudEndpoint(.global, "https://api.minimax.io/v1", key: "https://platform.minimax.io/",
                              known: [m("MiniMax-M3.1-Flash", vision: true), m("MiniMax-M3", vision: true)]),
            ], speech: false, allSeeImages: false, keyPrefixes: []),
            CloudPreset(id: "xiaomi", api: .openai, endpoints: [
                CloudEndpoint(nil, "https://api.xiaomimimo.com/v1", key: "https://platform.xiaomimimo.com/",
                              known: [m("mimo-v2.6-flash", vision: true), m("mimo-v2.6-pro", vision: true), m("mimo-v2.5", vision: true),
                                      m("mimo-v2.5-pro", vision: false)]),
            ], speech: false, allSeeImages: false, keyPrefixes: []),
            CloudPreset(id: "openai", api: .openai, endpoints: [
                CloudEndpoint(nil, "https://api.openai.com/v1", key: "https://platform.openai.com/api-keys"),
            ], speech: true, allSeeImages: true, keyPrefixes: ["sk-proj-", "sk-svcacct-", "sk-admin-"]),
            CloudPreset(id: "anthropic", api: .anthropic, endpoints: [
                CloudEndpoint(nil, "https://api.anthropic.com", key: "https://platform.claude.com/settings/keys"),
            ], speech: false, allSeeImages: true, keyPrefixes: ["sk-ant-"]),
            CloudPreset(id: "gemini", api: .openai, endpoints: [
                CloudEndpoint(nil, "https://generativelanguage.googleapis.com/v1beta/openai", key: "https://aistudio.google.com/apikey"),
            ], speech: false, allSeeImages: true, keyPrefixes: ["AIza"]),
            CloudPreset(id: "openrouter", api: .openai, endpoints: [
                CloudEndpoint(nil, "https://openrouter.ai/api/v1", key: "https://openrouter.ai/keys"),
            ], speech: false, allSeeImages: false, keyPrefixes: ["sk-or-"]),
            CloudPreset(id: "custom-openai", api: .openai, endpoints: [], speech: false, allSeeImages: false, keyPrefixes: []),
            CloudPreset(id: "custom-anthropic", api: .anthropic, endpoints: [], speech: false, allSeeImages: false, keyPrefixes: []),
        ]
    }()

    private static let zhipuKnown: [CloudModelInfo] = [
        ("glm-5.3", false), ("glm-5.3-flash", true), ("glm-5.3-flashx", false), ("glm-4.7-flashx", false), ("glm-4.7-flash", false),
        ("glm-4.6v", true), ("glm-4.6v-flashx", true), ("glm-4.6v-flash", true),
    ].map { CloudModelInfo(id: $0.0, vision: $0.1, text: true) }

    public static func preset(_ id: String) -> CloudPreset? { all.first { $0.id == id } }

    /// The service a pasted key belongs to, when its start says so (sk-ant-, sk-or-, AIza…); nil when it doesn't —
    /// most services' keys start with a bare "sk-", and the key is never tried on a service to find out (it would go
    /// to a company it wasn't made for).
    public static func detect(key: String) -> String? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { p in p.keyPrefixes.contains { k.hasPrefix($0) } }?.id
    }
}

/// What a pasted key can't be: nil when it looks like a key. Never says the key back.
public enum CloudKeyCheck {
    public enum Problem: String { case empty, spaces, characters }
    public static func problem(_ key: String) -> Problem? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { return .empty }
        if k.unicodeScalars.contains(where: { $0.properties.isWhitespace }) { return .spaces }
        // printable ASCII only: an HTTP header can't carry "ç" (⌥C in the field: the founder's key, 2026-10-31)
        if k.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value > 0x7E }) { return .characters }
        return nil
    }
}

/// One service the user connected. `id` is its Keychain account (service "Blurt Cloud Polish"): the preset's id for a
/// preset — the accounts cloud polish already used (deepseek, dashscope, openai, anthropic), so the keys carry over —
/// and "custom-N" for the user's own.
public struct CloudService: Hashable, Identifiable {
    public var id: String
    public var preset: String
    public var region: CloudRegion?
    /// "" = the preset's address for the region
    public var baseURL: String
    /// a custom service's name ("" = its host)
    public var name: String

    public init(id: String, preset: String, region: CloudRegion? = nil, baseURL: String = "", name: String = "") {
        self.id = id; self.preset = preset; self.region = region; self.baseURL = baseURL; self.name = name
    }

    public init?(json o: [String: Any]) {
        guard let id = o["id"] as? String, !id.isEmpty, let p = o["preset"] as? String, CloudPreset.preset(p) != nil else { return nil }
        self.init(id: id, preset: p, region: (o["region"] as? String).flatMap(CloudRegion.init(rawValue:)),
                  baseURL: o["base_url"] as? String ?? "", name: o["name"] as? String ?? "")
    }

    public var json: [String: Any] {
        var o: [String: Any] = ["id": id, "preset": preset]
        if let r = region { o["region"] = r.rawValue }
        let b = baseURL.trimmingCharacters(in: .whitespaces)
        if !b.isEmpty { o["base_url"] = b }
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { o["name"] = n }
        return o
    }

    public var info: CloudPreset { CloudPreset.preset(preset) ?? CloudPreset.all.last! }
    public var api: CloudProtocol { info.api }
    public var endpoint: CloudEndpoint? { info.endpoint(region) }
    public var effectiveBaseURL: String {
        let b = baseURL.trimmingCharacters(in: .whitespaces)
        return b.isEmpty ? endpoint?.baseURL ?? "" : b
    }
    /// the address's host ("api.example.com"), what a custom service is called when it has no name
    public var host: String { URL(string: effectiveBaseURL)?.host ?? effectiveBaseURL }
    /// the ids the docs named, for a service whose list can't be read (only at the preset's own address)
    public var known: [CloudModelInfo] {
        let b = baseURL.trimmingCharacters(in: .whitespaces)
        return b.isEmpty || b == endpoint?.baseURL ? endpoint?.known ?? [] : []
    }

    /// The URL of the service's model list and the headers it needs (the key added by the caller).
    public var modelsURL: URL? {
        let base = effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return nil }
        if api == .anthropic { return URL(string: base.hasSuffix("/v1") ? base + "/models?limit=1000" : base + "/v1/models?limit=1000") }
        return URL(string: base + "/models")
    }

    /// A free id for a new service of this preset: the preset's own, else "<preset>-2", "-3"…; custom ones "custom-1"…
    public static func newID(preset: String, taken: Set<String>) -> String {
        let stem = preset.hasPrefix("custom") ? "custom" : preset
        if !preset.hasPrefix("custom"), !taken.contains(stem) { return stem }
        var n = preset.hasPrefix("custom") ? 1 : 2
        while taken.contains("\(stem)-\(n)") { n += 1 }
        return "\(stem)-\(n)"
    }
}

/// The text jobs a connected service's model can do (the speech jobs keep their own settings: asr.*).
public enum CloudJob: String, CaseIterable, Hashable {
    case polish, translate, vision
}

/// One job's choice: Auto (the best connected service, else this Mac), this Mac, or one service's model ("" = the
/// service's default for the job).
public enum CloudJobChoice: Hashable {
    case auto, local
    case cloud(service: String, model: String)

    public init(json: Any?) {
        if let s = json as? String, s == "local" { self = .local; return }
        if let o = json as? [String: Any], let s = o["service"] as? String, !s.isEmpty {
            self = .cloud(service: s, model: o["model"] as? String ?? ""); return
        }
        self = .auto
    }

    /// nil = Auto (the key is left out)
    public var json: Any? {
        switch self {
        case .auto: return nil
        case .local: return "local"
        case .cloud(let s, let m):
            let t = m.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? ["service": s] : ["service": s, "model": t]
        }
    }
}

/// record.cloud as a whole.
public struct CloudSetup: Hashable {
    /// 2: Auto takes only curated models (CloudCurated.swift); v1 setups had their Auto jobs pinned on the way
    public static let version = 2
    public var services: [CloudService] = []
    public var jobs: [CloudJob: CloudJobChoice] = [:]

    public init(services: [CloudService] = [], jobs: [CloudJob: CloudJobChoice] = [:]) {
        self.services = services; self.jobs = jobs
    }

    public init(json o: [String: Any]?) {
        services = (o?["services"] as? [[String: Any]] ?? []).compactMap(CloudService.init(json:))
        let j = o?["jobs"] as? [String: Any] ?? [:]
        for job in CloudJob.allCases {
            let c = CloudJobChoice(json: j[job.rawValue])
            if c != .auto { jobs[job] = c }
        }
    }

    public var json: [String: Any] {
        var j: [String: Any] = [:]
        for (k, v) in jobs { if let x = v.json { j[k.rawValue] = x } }
        return ["v": CloudSetup.version, "services": services.map(\.json), "jobs": j]
    }

    public func choice(_ job: CloudJob) -> CloudJobChoice { jobs[job] ?? .auto }
    public func service(_ id: String) -> CloudService? { services.first { $0.id == id } }
}

// MARK: - model lists

public enum CloudModelList {
    /// A /models answer read into models: OpenAI's shape ({"data": [{"id", "created"}]}) and its relatives — DeepSeek's
    /// input_modalities, Moonshot's supports_image_in, OpenRouter's architecture, Anthropic's created_at and
    /// capabilities, Gemini's "models/" prefix. nil: not a list.
    public static func parse(_ data: Data) -> [CloudModelInfo]? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let rows = (o["data"] ?? o["models"]) as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return rows.compactMap { r -> CloudModelInfo? in
            guard var id = (r["id"] as? String) ?? (r["name"] as? String), !id.isEmpty else { return nil }
            if id.hasPrefix("models/") { id = String(id.dropFirst("models/".count)) }     // Gemini
            var m = CloudModelInfo(id: id)
            if let n = r["display_name"] as? String ?? r["displayName"] as? String { m.name = n }
            else if let n = r["name"] as? String, n != id, !n.hasPrefix("models/") { m.name = n }
            if let c = r["created"] as? Double { m.created = c }
            else if let c = r["created"] as? Int { m.created = Double(c) }
            else if let s = r["created_at"] as? String { m.created = (iso.date(from: s) ?? isoFrac.date(from: s))?.timeIntervalSince1970 }
            else if let c = r["created_at"] as? Double { m.created = c }
            // what it takes in, and what it gives back
            let arch = r["architecture"] as? [String: Any]
            let inputs = (r["input_modalities"] as? [String]) ?? (arch?["input_modalities"] as? [String])
            let outputs = (r["output_modalities"] as? [String]) ?? (arch?["output_modalities"] as? [String])
            if let i = inputs { m.vision = i.contains("image") }
            if let v = r["supports_image_in"] as? Bool { m.vision = v }
            if let caps = r["capabilities"] as? [String: Any] {
                if let v = caps["image_input"] as? Bool { m.vision = v }
                else if let v = (caps["image_input"] as? [String: Any])?["supported"] as? Bool { m.vision = v }
                else if let v = caps["vision"] as? Bool { m.vision = v }
            }
            if let out = outputs { m.text = out.contains("text") }
            return m
        }
    }

    // what fits a job

    /// Parts of an id that mean the model doesn't chat: embeddings, speech, pictures and video, moderation, search.
    static let notChat = ["embed", "tts", "asr", "transcribe", "whisper", "audio", "realtime", "speech", "voice", "music",
                          "dall-e", "image", "imagen", "sora", "veo", "video", "wanx", "wan2", "flux", "seedream", "seedance",
                          "seededit", "kolors", "cosyvoice", "paraformer", "sensevoice", "fun-asr", "gte-", "bge-", "rerank",
                          "moderation", "guard", "search", "deep-research", "computer-use", "babbage", "davinci", "lyria", "aqa"]
    /// …and ones that read pictures but are a poor choice for text alone
    static let pictureOnly = ["-vl", "vl-", "ocr", "omni", "vision"]

    static func tokens(_ id: String) -> [String] {
        id.lowercased().split(whereSeparator: { "-_./:".contains($0) }).map(String.init)
    }

    /// Takes images: the list says so; or, where the list says nothing, the service's models all do, or the id names a
    /// reading model (…-vl, …vision, …ocr, …omni), or it was measured reading screenshots.
    public static func seesImages(_ m: CloudModelInfo, preset: CloudPreset?) -> Bool {
        if let v = m.vision { return v }
        let id = m.id.lowercased()
        if preset?.allSeeImages == true { return true }
        if pictureOnly.contains(where: { id.contains($0) }) { return true }
        return preset.map { note(.vision, preset: $0.id, model: m.id) != nil } ?? false
    }

    public static func fits(_ m: CloudModelInfo, _ job: CloudJob, preset: CloudPreset?) -> Bool {
        if m.text == false { return false }
        let id = m.id.lowercased()
        if notChat.contains(where: { id.contains($0) }) { return false }
        switch job {
        case .polish, .translate: return !pictureOnly.contains(where: { id.contains($0) })
        case .vision: return seesImages(m, preset: preset)
        }
    }

    /// The models for a job, newest first: by the list's dates where it has them, else by version (qwen3.8 before
    /// qwen3.6); a dated snapshot is left out when its plain name is in the list too.
    public static func suitable(_ models: [CloudModelInfo], _ job: CloudJob, preset: CloudPreset?) -> [CloudModelInfo] {
        let ids = Set(models.map(\.id))
        let fit = models.filter { fits($0, job, preset: preset) && !isSnapshot($0.id, of: ids) }
        var seen = Set<String>()
        return newestFirst(fit).filter { seen.insert($0.id).inserted }
    }

    public static func newestFirst(_ models: [CloudModelInfo]) -> [CloudModelInfo] {
        models.enumerated().sorted { a, b in
            switch (a.element.created, b.element.created) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                // no dates (or the same one): the higher version first, then the list's own order
                let c = naturalCompare(a.element.id, b.element.id)
                return c != 0 ? c > 0 : a.offset < b.offset
            }
        }.map(\.element)
    }

    /// "qwen3.8-flash" > "qwen3.6-flash", "glm-5.3" > "glm-4.7": digits compared as numbers. -1, 0, 1.
    public static func naturalCompare(_ a: String, _ b: String) -> Int {
        let x = Array(a.lowercased().unicodeScalars), y = Array(b.lowercased().unicodeScalars)
        var i = 0, j = 0
        func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 48 && s.value <= 57 }
        while i < x.count && j < y.count {
            if isDigit(x[i]) && isDigit(y[j]) {
                var n = 0.0, m = 0.0
                while i < x.count && isDigit(x[i]) { n = n * 10 + Double(x[i].value - 48); i += 1 }
                while j < y.count && isDigit(y[j]) { m = m * 10 + Double(y[j].value - 48); j += 1 }
                if n != m { return n < m ? -1 : 1 }
            } else {
                if x[i] != y[j] { return x[i].value < y[j].value ? -1 : 1 }
                i += 1; j += 1
            }
        }
        return x.count - i == y.count - j ? 0 : (x.count - i < y.count - j ? -1 : 1)
    }

    /// "qwen3.6-flash-2026-04-16" when "qwen3.6-flash" is listed; "doubao-seed-2-1-lite-260915" stays (no plain name).
    static func isSnapshot(_ id: String, of ids: Set<String>) -> Bool {
        let date = try? NSRegularExpression(pattern: #"-(\d{4}-\d{2}-\d{2}|\d{4,8})$"#)
        guard let r = date?.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)), let range = Range(r.range, in: id) else { return false }
        return ids.contains(String(id[..<range.lowerBound]))
    }

    /// The smaller, faster tier of a family (flash, lite, mini, turbo, haiku…): what a job run on every dictation wants.
    static let fastTier = ["flash", "lite", "mini", "nano", "turbo", "haiku", "fast", "speed", "highspeed", "air", "small"]
    static func fast(_ id: String) -> Bool { tokens(id).contains { t in fastTier.contains { t.hasPrefix($0) } } }

    /// The model a job uses on a service when none was picked: the one measured for it while the list still has it
    /// (DeepSeek, Model Studio), else the newest suitable model of the fast tier, else the newest suitable one. `models`
    /// nil: no list read yet — the measured one, else the docs' first (Ark, Zhipu, MiniMax), else nothing.
    public static func defaultModel(_ job: CloudJob, preset: CloudPreset, models: [CloudModelInfo]?) -> String? {
        let measured = measuredDefault(job, preset: preset.id)
        guard let all = models else { return measured }
        let fit = suitable(all, job, preset: preset)
        if let m = measured, all.contains(where: { $0.id == m }) { return m }
        return fit.first { fast($0.id) }?.id ?? fit.first?.id
    }

    // what was measured (first-minute-speech.md §2.5): only on these two services, only these ids

    static func measuredDefault(_ job: CloudJob, preset: String) -> String? {
        switch (preset, job) {
        case ("deepseek", _): return "deepseek-flash"
        case ("dashscope", .vision): return "qwen3.6-flash"
        case ("dashscope", _): return "deepseek-v4.1-flash"
        default: return nil
        }
    }

    /// The measured line's string key (Dictation table) for a model, nil when it wasn't measured.
    public static func note(_ job: CloudJob, preset: String, model: String) -> String? {
        switch (job, preset, model) {
        case (.polish, "deepseek", "deepseek-flash"): return "dictation.cloud.model.note.polish.deepseek_flash"
        case (.polish, "dashscope", "deepseek-v4.1-flash"): return "dictation.cloud.model.note.polish.ds41"
        case (.polish, "dashscope", "qwen3.8-flash"): return "dictation.cloud.model.note.polish.qwen38"
        case (.polish, "dashscope", "qwen3.6-flash"): return "dictation.cloud.model.note.polish.qwen36"
        case (.polish, "dashscope", "qwen-flash"): return "dictation.cloud.model.note.polish.qwen_flash"
        case (.polish, "dashscope", "qwen-plus"): return "dictation.cloud.model.note.polish.qwen_plus"
        case (.translate, "deepseek", "deepseek-flash"): return "dictation.cloud.model.note.translate.deepseek_flash"
        case (.translate, "dashscope", "deepseek-v4.1-flash"): return "dictation.cloud.model.note.translate.ds41"
        case (.translate, "dashscope", "qwen3.8-flash"): return "dictation.cloud.model.note.translate.qwen38"
        case (.translate, "dashscope", "qwen3.6-flash"): return "dictation.cloud.model.note.translate.qwen36"
        case (.vision, "deepseek", "deepseek-flash"): return "dictation.cloud.model.note.vision.deepseek_flash"
        case (.vision, "dashscope", "qwen3.6-flash"): return "dictation.cloud.model.note.vision.qwen36"
        case (.vision, "dashscope", "qwen3.5-flash"): return "dictation.cloud.model.note.vision.qwen35"
        case (.vision, "dashscope", "qwen3-vl-plus"): return "dictation.cloud.model.note.vision.qwen3_vl_plus"
        case (.vision, "dashscope", "qwen3.5-ocr"): return "dictation.cloud.model.note.vision.qwen35_ocr"
        case (.vision, "dashscope", "qwen-vl-ocr"): return "dictation.cloud.model.note.vision.qwen_vl_ocr"
        default: return nil
        }
    }
}

// MARK: - which model does a job

public enum CloudRoute: Hashable {
    case local
    case cloud(service: String, model: String)

    public var service: String? { if case .cloud(let s, _) = self { return s }; return nil }
    public var model: String? { if case .cloud(_, let m) = self { return m }; return nil }
}

public enum CloudRouting {
    /// The connected services (a key in the Keychain) in the order Auto tries them: the presets' order, the user's own
    /// after them in the order they were added.
    public static func ranked(_ services: [CloudService]) -> [CloudService] {
        let order = Dictionary(uniqueKeysWithValues: CloudPreset.all.enumerated().map { ($1.id, $0) })
        return services.enumerated().sorted { a, b in
            let x = order[a.element.preset] ?? .max, y = order[b.element.preset] ?? .max
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    /// Where a job goes. `connected`: the services with a key; `models`: a service's list (nil: not read yet — its
    /// known ids stand in). Auto: the first connected service with a model for the job, else this Mac. A picked
    /// service that is gone (removed, its key deleted) → this Mac, never another company's service.
    public static func resolve(_ job: CloudJob, choice: CloudJobChoice, connected: [CloudService],
                               models: (CloudService) -> [CloudModelInfo]?) -> CloudRoute {
        func listed(_ s: CloudService) -> [CloudModelInfo]? {
            if let m = models(s) { return m }
            return s.known.isEmpty ? nil : s.known
        }
        switch choice {
        case .local: return .local
        case .cloud(let id, let model):
            guard let s = connected.first(where: { $0.id == id }) else { return .local }
            if !model.isEmpty { return .cloud(service: id, model: model) }
            guard let d = CloudModelList.defaultModel(job, preset: s.info, models: listed(s)) else { return .local }
            return .cloud(service: id, model: d)
        case .auto:
            for s in ranked(connected) {
                if let d = CloudModelList.defaultModel(job, preset: s.info, models: listed(s)) { return .cloud(service: s.id, model: d) }
            }
            return .local
        }
    }
}

// MARK: - from one "cloud polish" service (≤ v1.0.7)

public enum CloudMigration {
    /// record.cloud from what an earlier version kept: record.dictation.cloud_polish ({"on", "provider", "base_url",
    /// "model", "translate_model", "vision_model"}), the two translate switches (record.dictation.translate.cloud,
    /// record.screen_text.translate.cloud) and ⌥C's second reading (record.screen_text.refine: off | local | cloud).
    /// `keys`: the old providers with a key in the Keychain (deepseek, dashscope, openai, anthropic); `speechKey`: a
    /// Model Studio key saved for cloud speech only.
    /// Nothing changes for the user: every service with a key is connected (same Keychain account), and a job that
    /// was on the cloud stays on that service and model, one that wasn't stays on this Mac — Auto only where the
    /// user had no service at all.
    public static func migrate(dictation: [String: Any], screenText: [String: Any], keys: Set<String>, speechKey: Bool) -> CloudSetup {
        let old = dictation["cloud_polish"] as? [String: Any] ?? [:]
        let provider = old["provider"] as? String ?? "deepseek"
        let baseURL = (old["base_url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        var setup = CloudSetup()
        var have = keys
        if speechKey { have.insert("dashscope") }
        for p in ["deepseek", "dashscope", "openai", "anthropic"] where have.contains(p) {
            // the address the user typed belongs to the provider they had on
            let url = p == provider ? baseURL : ""
            var s = CloudService(id: p, preset: p)
            switch p {
            case "openai", "anthropic":
                // "OpenAI-compatible" / "Anthropic-compatible" with another address: the user's own service
                let own = p == "openai" ? "https://api.openai.com" : "https://api.anthropic.com"
                if !url.isEmpty && !url.hasPrefix(own) { s = CloudService(id: p, preset: "custom-\(p)", baseURL: url) }
            case "dashscope":
                if url.contains("dashscope-intl") { s.region = .global }
                else { s.region = .china }
                if !url.isEmpty, CloudPreset.preset("dashscope")?.endpoints.contains(where: { $0.baseURL == url }) == false { s.baseURL = url }
            default:
                if !url.isEmpty, url != CloudPreset.preset(p)?.endpoints.first?.baseURL { s.baseURL = url }
            }
            setup.services.append(s)
        }
        let active = setup.services.contains { $0.id == provider } && keys.contains(provider)
        guard !setup.services.isEmpty else { return setup }

        func model(_ k: String) -> String { (old[k] as? String ?? "").trimmingCharacters(in: .whitespaces) }
        // polish: on → that service (and its model); off → this Mac, as before
        let on = old["on"] as? Bool ?? false
        setup.jobs[.polish] = on && active ? .cloud(service: provider, model: model("model")) : .local
        // translate: the cloud translated when a key was there and a switch let it (the model: translate's, else polish's)
        let dictationCloud = (dictation["translate"] as? [String: Any])?["cloud"] as? Bool ?? true
        let screenCloud = ((screenText["translate"] as? [String: Any])?["cloud"] as? Bool) ?? dictationCloud
        let tm = model("translate_model").isEmpty ? model("model") : model("translate_model")
        setup.jobs[.translate] = active && (dictationCloud || screenCloud) ? .cloud(service: provider, model: tm) : .local
        // Copy Text from Screen: the cloud when ⌥C read again in the cloud, this Mac when it read here; off: Auto
        switch screenText["refine"] as? String {
        case "cloud":
            setup.jobs[.vision] = active ? .cloud(service: provider, model: model("vision_model")) : .local
        case "local": setup.jobs[.vision] = .local
        default: break
        }
        return setup
    }
}
