// Agent-assisted model setup (docs/design/agent-setup.md): the user's own coding agent (Claude Code, Codex, Kimi, Gemini
// CLI…) sets up Blurt's speech, polish, translate and screen-text models through `scripts/setup.py`, which talks to
// the running app over a local control socket. The app keeps every key: it tests it, stores it in the login Keychain
// and never sends one back. This file is the part without side effects:
//
//   AgentSetup          where the socket is, the protocol's limits, the setup session's project id
//   AgentSetupOp        the operations, and which ones change something (they need a grant)
//   AgentSetupRequest   one request read strictly (a key only on `connect`, a curated service only)
//   AgentSetupGrant     who may change things: a token the app gave the session it started, or the user's Allow
//                       (a time window), never a peer of another user (checked on the socket: getpeereid)
//   AgentSetupPeer      which agent is asking, from the requesting process's ancestors (for the Allow question)
//   AgentSetupChoice    `use <job> <option>` read against the curated list and the connected services
//   AgentSetupSteps     the live list Settings → Models and onboarding show while an agent works
//   AgentSetupJSON      the pieces of `status` that are plain data
//
// Protocol: one JSON object per line in, one per line out, then the connection closes. Every answer has "ok"; a
// failure has "code" and "error" (English, for the agent; the agent explains it to the user in their language).
import CryptoKit
import Foundation

public enum AgentSetup {
    /// v1: hello, status, connect, test, use, download, verify (agent-setup.md §2)
    public static let protocolVersion = 1
    /// a request is a line of JSON at most this long (a key is ~100 bytes; nothing else is big)
    public static let maxRequest = 64 * 1024
    /// Sessions' project id for a setup session (Sessions shows it under its own name, not Unassigned)
    public static let project = "blurt-setup"
    /// sockaddr_un.sun_path holds 104 bytes with its terminating zero
    public static let maxSocketPath = 103

    /// $BLURT_HOME/run/control.sock; when a home's path makes that too long for a socket address (a deep test
    /// folder): /tmp/blurt-<uid>/<12 hex of sha256(home)>.sock — the folder made 0700 and checked to be this user's by
    /// whoever binds. setup.py computes the same path (agent-setup.md §1).
    public static func socketPath(home: URL, uid: uid_t = getuid()) -> String {
        let p = home.appendingPathComponent("run/control.sock").path
        if p.utf8.count <= maxSocketPath { return p }
        let digest = SHA256.hash(data: Data(home.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "/tmp/blurt-\(uid)/\(digest.prefix(12)).sock"
    }
}

public enum AgentSetupOp: String, CaseIterable, Hashable {
    case hello, status, connect, test, use, download, verify

    /// It changes a setting, stores a key, spends a request on a paid service or runs the models: only with a grant.
    public var needsGrant: Bool { self != .hello && self != .status }
}

/// A request the app refuses, with the code the agent reads and one English sentence.
public struct AgentSetupError: Error, Equatable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var json: [String: Any] { ["ok": false, "code": code, "error": message] }
}

/// One request, read strictly: unknown fields are ignored, a field of the wrong type is an error, and a secret is
/// read only for `connect` (anywhere else it is refused, so a key never rides along unnoticed).
public struct AgentSetupRequest {
    public enum Secret: Equatable {
        case key(String)
        /// Volcengine Speech's pair
        case pair(appID: String, token: String)
    }

    public let op: AgentSetupOp
    public let token: String?
    /// connect: the preset; test: the service id (or its preset)
    public let preset: String?
    public let region: CloudRegion?
    public let secret: Secret?
    public let service: String?
    /// use: polish | translate | vision | dictation
    public let job: String?
    public let option: String?
    /// use: a model Blurt didn't measure (it is tested on the job first, as Settings' Custom Model)
    public let custom: Bool
    /// download: a dictation model id ("recommended": the one recommended for this Mac)
    public let model: String?
    /// verify: the language of the spoken clip ("en", "zh"; nil: the user's first)
    public let language: String?

    public static func parse(_ o: [String: Any]) -> Result<AgentSetupRequest, AgentSetupError> {
        guard let opName = o["op"] as? String else { return .failure(AgentSetupError("bad_request", "missing op")) }
        guard let op = AgentSetupOp(rawValue: opName) else { return .failure(AgentSetupError("unknown_op", "unknown op \(opName)")) }
        func str(_ k: String) -> Result<String?, AgentSetupError> {
            guard let v = o[k], !(v is NSNull) else { return .success(nil) }
            guard let s = v as? String else { return .failure(AgentSetupError("bad_request", "\(k) must be a string")) }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(t.isEmpty ? nil : t)
        }
        var fields: [String: String] = [:]
        for k in ["token", "preset", "region", "service", "job", "option", "model", "language"] {
            switch str(k) {
            case .failure(let e): return .failure(e)
            case .success(let v): if let v = v { fields[k] = v }
            }
        }
        var region: CloudRegion?
        if let r = fields["region"] {
            guard let x = CloudRegion(rawValue: r) else { return .failure(AgentSetupError("bad_region", "region must be china or global")) }
            region = x
        }
        var secret: Secret?
        let hasSecret = o["key"] != nil || o["app_id"] != nil || o["access_token"] != nil
        if hasSecret {
            guard op == .connect else { return .failure(AgentSetupError("bad_request", "a key is only taken by connect")) }
            if let k = o["key"] {
                guard let s = k as? String else { return .failure(AgentSetupError("bad_request", "key must be a string")) }
                secret = .key(s)
            } else {
                guard let a = o["app_id"] as? String, let t = o["access_token"] as? String else {
                    return .failure(AgentSetupError("bad_request", "app_id and access_token must both be strings"))
                }
                secret = .pair(appID: a, token: t)
            }
        }
        if let c = o["custom"], !(c is Bool) { return .failure(AgentSetupError("bad_request", "custom must be true or false")) }
        return .success(AgentSetupRequest(op: op, token: fields["token"], preset: fields["preset"], region: region, secret: secret,
                                          service: fields["service"], job: fields["job"], option: fields["option"],
                                          custom: o["custom"] as? Bool ?? false, model: fields["model"], language: fields["language"]))
    }

    /// connect: what can be checked before anything is sent — a curated service (`offered`: Add Service's list; the
    /// list never names an address, so a key only ever goes to a preset's own host), its region, and a key that can
    /// be one (Volcengine Speech: the App ID and the token). The region a regional service takes when none was given:
    /// `systemRegion`.
    public func connectPlan(offered: [String], systemRegion: CloudRegion) -> Result<(preset: CloudPreset, region: CloudRegion?, credential: String), AgentSetupError> {
        guard let id = preset else { return .failure(AgentSetupError("bad_request", "connect needs a preset")) }
        guard let p = CloudPreset.preset(id), !p.custom else { return .failure(AgentSetupError("unknown_preset", "unknown service \(id)")) }
        guard offered.contains(id) else {
            return .failure(AgentSetupError("not_curated", "\(id) is not one of the services Blurt measured (\(offered.joined(separator: ", "))); add other services in Settings → Models → Custom Model"))
        }
        var r: CloudRegion?
        if p.regional {
            r = region ?? systemRegion
        } else if let given = region, let only = p.endpoints.first?.region, given != only {
            return .failure(AgentSetupError("bad_region", "\(id) is only offered in \(only.rawValue)"))
        }
        switch secret {
        case nil:
            return .failure(AgentSetupError("no_key", p.pairCredential ? "send the App ID and Access Token on stdin" : "send the API key on stdin"))
        case .key(let k)?:
            guard !p.pairCredential else { return .failure(AgentSetupError("no_key", "\(id) takes an App ID and an Access Token")) }
            if let problem = CloudKeyCheck.problem(k) { return .failure(AgentSetupError("bad_key", Self.keyWords(problem))) }
            return .success((p, r, k.trimmingCharacters(in: .whitespacesAndNewlines)))
        case .pair(let a, let t)?:
            guard p.pairCredential else { return .failure(AgentSetupError("bad_key", "\(id) takes one API key")) }
            switch VolcengineSpeech.problem(appID: a, token: t) {
            case .appID?: return .failure(AgentSetupError("bad_key", "the App ID should be letters and digits"))
            case .token(let k)?: return .failure(AgentSetupError("bad_key", Self.keyWords(k)))
            case nil: return .success((p, r, VolcengineSpeech.credential(appID: a, token: t)))
            }
        }
    }

    static func keyWords(_ p: CloudKeyCheck.Problem) -> String {
        switch p {
        case .empty: return "the key is empty"
        case .spaces: return "the key has spaces in it; copy it again"
        case .characters: return "the key has characters no key has; copy it again"
        }
    }
}

// MARK: - who may change things

/// Changes need a grant. The session the app started ("Set Up with Agent…") carries a token (its environment); any
/// other process of this user — the user's own agent in their own terminal — gets one when the user clicks Allow
/// in Blurt, for a while. A peer of another user never gets this far (the socket checks its uid).
public struct AgentSetupGrant {
    /// a token lives as long as its session, at most this long
    public static let sessionTTL: TimeInterval = 2 * 3600
    /// Allow opens changes to this user's processes for this long
    public static let approvalTTL: TimeInterval = 30 * 60

    public private(set) var tokens: [String: Date] = [:]
    public private(set) var approvedUntil: Date?

    public init() {}

    /// A new token for a session the app starts (32 random bytes, hex).
    public mutating func issue(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let ok = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        if !ok { for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) } }
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        tokens[t] = now.addingTimeInterval(Self.sessionTTL)
        return t
    }

    public mutating func revoke(_ token: String) { tokens[token] = nil }

    public mutating func approve(now: Date = Date()) { approvedUntil = now.addingTimeInterval(Self.approvalTTL) }

    /// Stop: no token and no window left.
    public mutating func revokeAll() { tokens = [:]; approvedUntil = nil }

    /// Changes are allowed: a live token (compared in constant time), or the user's Allow still running.
    public func allows(token: String?, now: Date = Date()) -> Bool {
        if let until = approvedUntil, now < until { return true }
        guard let t = token, !t.isEmpty else { return false }
        var found = false
        for (k, exp) in tokens where now < exp {
            if Self.same(k, t) { found = true }
        }
        return found
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in x.indices { d |= x[i] ^ y[i] }
        return d == 0
    }
}

/// Which agent is asking: the requesting process and its ancestors, nearest first, each as its executable path then
/// its arguments (setup.py → uv → zsh → claude). An agent is known by agents.json's `bins` — the executable's own name
/// (codex, claude) or, for a script run by node / python / bun, its first argument's name (gemini, opencode).
public enum AgentSetupPeer {
    public static func agent(chain: [[String]], bins: [(id: String, bins: [String])]) -> String? {
        let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "env"]
        for argv in chain {
            guard let exe = argv.first else { continue }
            var names = [base(exe)]
            if argv.count > 1 { names.append(base(argv[1])) }
            if interpreters.contains(names[0]), argv.count > 2 { names.append(base(argv[2])) }
            for n in names {
                if let hit = bins.first(where: { $0.bins.contains(n) }) { return hit.id }
            }
        }
        return nil
    }

    static func base(_ p: String) -> String {
        let last = p.split(separator: "/").last.map(String.init) ?? p
        return last.hasSuffix(".js") ? String(last.dropLast(3)) : last
    }
}

// MARK: - use <job> <option>

public enum AgentSetupChoice: Equatable {
    case text(CloudJob, CloudJobChoice)
    /// dictation's recogniser (cloud polish: polish to the cloud over the local model)
    case dictation(DictationChoice)
    /// dictation back to the recommended recogniser (nothing pinned)
    case dictationAuto

    /// The jobs `use` takes: the three text jobs and dictation.
    public static let jobs = ["polish", "translate", "vision", "dictation"]

    /// `option` for a text job: auto · local · <service id or preset> (its curated model for the job) ·
    /// <service>:<model> (a curated model, or with `custom` any model — tested on the job before it is saved). For
    /// dictation: auto or a DictationChoice id (apple-speech, qwen3-asr-0.6b-mlx, fun-asr-nano-mlx, qwen3-asr-1.7b-mlx,
    /// cloud-polish, qwen3-asr-flash, volcengine-seedasr). `needsTest`: a custom model, saved only when the job's own
    /// test passes. Only connected services (a key in the Keychain): never one the agent made up.
    public static func parse(job: String, option: String, custom: Bool, connected: [CloudService],
                             list: CuratedList) -> Result<(choice: AgentSetupChoice, needsTest: Bool), AgentSetupError> {
        let opt = option.trimmingCharacters(in: .whitespaces)
        if job == "dictation" {
            if opt == "auto" { return .success((.dictationAuto, false)) }
            guard let c = DictationChoice(rawValue: opt) else {
                return .failure(AgentSetupError("unknown_option", "dictation takes auto or one of: \(DictationChoice.allCases.map(\.rawValue).joined(separator: ", "))"))
            }
            return .success((.dictation(c), false))
        }
        guard let j = CloudJob(rawValue: job) else {
            return .failure(AgentSetupError("unknown_job", "job must be one of: \(jobs.joined(separator: ", "))"))
        }
        if opt == "auto" { return .success((.text(j, .auto), false)) }
        if opt == "local" { return .success((.text(j, .local), false)) }
        let parts = opt.split(separator: ":", maxSplits: 1).map(String.init)
        let who = parts[0]
        // a service by its id, else the first connected one of that preset
        guard let s = connected.first(where: { $0.id == who }) ?? connected.first(where: { $0.preset == who }) else {
            return .failure(AgentSetupError("not_connected", "\(who) is not connected; run connect first"))
        }
        if s.info.speechOnly { return .failure(AgentSetupError("unknown_option", "\(s.id) only recognises speech")) }
        if parts.count == 1 {
            guard list.options(j).contains(where: { $0.runs(on: s) }) else {
                return .failure(AgentSetupError("no_option", "Blurt has no measured \(job) model on \(s.id); pass service:model with --custom"))
            }
            return .success((.text(j, .cloud(service: s.id, model: "")), false))
        }
        let model = parts[1]
        // a curated model is kept as the service alone (Settings does the same): a better one in the list reaches the user
        if list.option(j, on: s, model: model) != nil { return .success((.text(j, .cloud(service: s.id, model: "")), false)) }
        guard custom else {
            return .failure(AgentSetupError("not_curated", "\(model) is not a model Blurt measured for \(job) on \(s.id); pass --custom to test and use it anyway"))
        }
        guard CloudCustom.validModelID(model) else { return .failure(AgentSetupError("bad_model", "not a model id: \(model)")) }
        return .success((.text(j, .cloud(service: s.id, model: model)), true))
    }
}

// MARK: - the live list

/// What the agent did, as Settings → Models and onboarding list it while it works: one row per thing (a service
/// connected, a job's model, a download, the test dictation) — a later report about the same thing replaces it.
public struct AgentSetupStep: Hashable, Identifiable {
    public enum Kind: String { case connect, use, download, verify }
    public enum State: String { case running, done, failed }
    public let kind: Kind
    /// the service id, the job, the model id; "" for verify
    public let subject: String
    public var state: State
    /// what the row names: the service's name, the model's name (the app's words)
    public var name: String
    public var id: String { kind.rawValue + ":" + subject }

    public init(_ kind: Kind, _ subject: String, _ state: State, name: String) {
        self.kind = kind; self.subject = subject; self.state = state; self.name = name
    }
}

public struct AgentSetupSteps: Equatable {
    public private(set) var steps: [AgentSetupStep] = []
    public init() {}

    /// A report: replaces the row for the same thing in place (its order is when it first happened).
    public mutating func record(_ s: AgentSetupStep) {
        if let i = steps.firstIndex(where: { $0.id == s.id }) { steps[i] = s } else { steps.append(s) }
    }

    public mutating func clear() { steps = [] }

    public var failed: Bool { steps.contains { $0.state == .failed } }
    public var running: Bool { steps.contains { $0.state == .running } }
}

// MARK: - status, as data

public enum AgentSetupJSON {
    /// A job's choice as `status` says it: "auto" | "local" | {"service", "model"?}
    public static func choice(_ c: CloudJobChoice) -> Any {
        switch c {
        case .auto: return "auto"
        case .local: return "local"
        case .cloud(let s, let m): return m.isEmpty ? ["service": s] as [String: Any] : ["service": s, "model": m]
        }
    }

    /// Where a job runs now: {"where": "local"} or {"where": "cloud", "service", "model", "curated"}
    public static func route(_ r: CloudRoute, job: CloudJob, setup: CloudSetup, list: CuratedList) -> [String: Any] {
        switch r {
        case .local: return ["where": "local"]
        case .cloud(let s, let m):
            var o: [String: Any] = ["where": "cloud", "service": s, "model": m]
            if let svc = setup.service(s), let opt = list.option(job, on: svc, model: m) { o["name"] = opt.name; o["curated"] = true }
            else { o["curated"] = false }
            return o
        }
    }

    /// One curated option: `option` is what `use` takes ("deepseek:deepseek-flash"); `connected`: the service id it
    /// would run on now (nil: its key isn't in yet — connect its preset first).
    public static func option(_ o: CuratedOption, connected: [CloudService], note: String?) -> [String: Any] {
        var out: [String: Any] = ["option": "\(o.service):\(o.model)", "service": o.service, "model": o.model, "name": o.name,
                                  "measured": o.measured]
        if !o.regions.isEmpty { out["regions"] = o.regions.map(\.rawValue) }
        if let n = note { out["note"] = n }
        out["connected"] = connected.first(where: o.runs(on:)).map { $0.id } ?? NSNull()
        return out
    }

    /// One dictation choice's measured facts (DictationChoices; docs/design/dictation-eval-2026-10-31.md): the level
    /// (3–5 stars, never an error count), the language levels that were measured, the delay, cost and what leaves the
    /// Mac, and whether it runs here.
    public static func facts(_ f: DictationFacts, fit: DictationChoices.Fit, recommended: Bool, inUse: Bool) -> [String: Any] {
        var o: [String: Any] = ["option": f.choice.rawValue, "level": DictationChoices.level(f.mixed),
                                "levels": f.languages.mapValues { DictationChoices.level($0) },
                                "delay_s": [f.delay.lowerBound, f.delay.upperBound], "download_mb": f.downloadMB,
                                "recommended": recommended, "in_use": inUse]
        switch f.cost {
        case .free: o["cost"] = ["kind": "free"]
        case .perDictation(let cny, let usd): o["cost"] = ["kind": "per_dictation", "cny": cny, "usd": usd]
        case .perHour(let cny, let usd): o["cost"] = ["kind": "per_hour", "cny": cny, "usd": usd]
        }
        switch f.leaves {
        case .nothing: o["uploads"] = "nothing"
        case .text: o["uploads"] = "text"
        case .voice: o["uploads"] = "voice"; o["to"] = "dashscope"
        case .voiceToVolcengine: o["uploads"] = "voice"; o["to"] = "volcengine-speech"
        }
        switch fit {
        case .fits: o["fits"] = true
        case .needsKey: o["fits"] = true; o["needs"] = "key"
        case .needsMemory(let gb): o["fits"] = false; o["needs"] = "memory_\(gb)gb"
        case .needsAppleSilicon: o["fits"] = false; o["needs"] = "apple_silicon"
        case .needsMacOS26: o["fits"] = false; o["needs"] = "macos_26"
        }
        return o
    }
}

// MARK: verify

public enum AgentSetupVerify {
    /// How much of `said` came back in `heard`, 0…1: one minus the edit distance over the length — by character for
    /// Chinese and Japanese, by word otherwise; case, punctuation and spaces ignored.
    public static func match(said: String, heard: String) -> Double {
        let a = units(said), b = units(heard)
        guard !a.isEmpty else { return b.isEmpty ? 1 : 0 }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            if !b.isEmpty {
                for j in 1...b.count {
                    cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                }
            }
            prev = cur
        }
        return max(0, 1 - Double(prev[b.count]) / Double(a.count))
    }

    static func units(_ s: String) -> [String] {
        let folded = s.lowercased().unicodeScalars.map { c -> String in
            CharacterSet.punctuationCharacters.contains(c) || CharacterSet.symbols.contains(c) ? " " : String(c)
        }.joined()
        var out: [String] = []
        var word = ""
        for ch in folded {
            let cjk = ch.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }
            if cjk { if !word.isEmpty { out.append(word); word = "" }; out.append(String(ch)) }
            else if ch.isWhitespace { if !word.isEmpty { out.append(word); word = "" } }
            else { word.append(ch) }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    /// The clip `say` speaks for a language ("zh…": Chinese, else English), and the voice locale to look for.
    public static func phrase(_ language: String) -> (text: String, locale: String) {
        if language.lowercased().hasPrefix("zh") { return ("今天下午三点开会，记得带上电脑和会议记录。", "zh_CN") }
        return ("Let's meet at three this afternoon, and please bring the laptop and the notes.", "en_US")
    }
}

