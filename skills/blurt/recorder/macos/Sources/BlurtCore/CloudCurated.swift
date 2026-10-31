// Settings → Models' curated choices (the founder, 2026-10-31: official, measured choices instead of each service's
// open model list — users couldn't tell which models see images, think for seconds, rewrite or fail). Each job offers
// This Mac and the few cloud models Blurt measured for it (docs/design/dictation-eval-2026-10-31.md §2.3, §6.3;
// first-minute-speech.md §2.5, §10.5); any other model is a Custom Model the user adds, marked "Not tested by Blurt".
//
// The list is data: scripts/curated_models.json in the skill (bundled with the app), refreshed from
// https://blurt.work/models/curated.json (site/models/curated.json) at most once a day; the newer of the two by its
// "updated" date wins. Schema 1:
//
//   {"schema": 1, "updated": "YYYY-MM-DD",
//    "jobs": {"polish" | "translate" | "vision" | "speech": [            best first; This Mac is always offered too
//        {"service": "<preset id>", "model": "<model id>", "name": "<shown name>",
//         "regions": ["china", "global"]?,       absent: every region the service has
//         "note": "<note key>"?,                 Dictation.strings "dictation.cloud.model.note.<note>"
//         "measured": "YYYY-MM-DD"}]}}
//
// Read strictly: a service that isn't one of the app's own presets is dropped, and the list never names an address —
// the request goes to the preset's address from this app, so a tampered list can't send a key to a new host. A bad
// file (not JSON, another schema, nothing valid in it) is nil: the caller keeps the last good list.
import Foundation

/// The jobs the curated list covers: the three text jobs and dictation's cloud recognition.
public enum CuratedJob: String, CaseIterable, Hashable {
    case polish, translate, vision, speech

    public init(_ job: CloudJob) {
        switch job {
        case .polish: self = .polish
        case .translate: self = .translate
        case .vision: self = .vision
        }
    }
}

public struct CuratedOption: Hashable {
    /// a preset id (CloudPreset.all)
    public let service: String
    public let model: String
    /// what people see ("DeepSeek V4.1 Flash")
    public let name: String
    /// empty: every region the service has
    public let regions: [CloudRegion]
    /// the measured line's key under "dictation.cloud.model.note." (nil: none)
    public let note: String?
    /// "YYYY-MM-DD"
    public let measured: String

    public init(service: String, model: String, name: String, regions: [CloudRegion] = [], note: String? = nil, measured: String) {
        self.service = service; self.model = model; self.name = name; self.regions = regions; self.note = note
        self.measured = measured
    }

    /// It runs on this connected service: the same preset, in a region it is offered in.
    public func runs(on s: CloudService) -> Bool {
        guard s.preset == service else { return false }
        guard !regions.isEmpty, s.info.regional else { return true }
        return regions.contains(s.region ?? s.endpoint?.region ?? .china)
    }

    /// The note's whole string key (Dictation table).
    public var noteKey: String? { note.map { "dictation.cloud.model.note." + $0 } }
}

public struct CuratedList: Hashable {
    public static let schema = 1
    /// "YYYY-MM-DD"
    public let updated: String
    public let jobs: [CuratedJob: [CuratedOption]]

    public init(updated: String, jobs: [CuratedJob: [CuratedOption]]) { self.updated = updated; self.jobs = jobs }

    public static let empty = CuratedList(updated: "0000-00-00", jobs: [:])

    public func options(_ job: CuratedJob) -> [CuratedOption] { jobs[job] ?? [] }
    public func options(_ job: CloudJob) -> [CuratedOption] { options(CuratedJob(job)) }

    /// The services the user connects with just a key, in the order they first appear (polish first): the ones Add
    /// Service offers. Every other preset is a Custom Model's.
    public var services: [String] {
        var out: [String] = []
        for j in CuratedJob.allCases { for o in options(j) where !out.contains(o.service) { out.append(o.service) } }
        return out
    }

    /// The curated option a job's model on a service is, nil when it isn't one.
    public func option(_ job: CloudJob, on s: CloudService, model: String) -> CuratedOption? {
        options(job).first { $0.model == model && $0.runs(on: s) }
    }

    /// The newer list by its "updated" date; the first on a tie (the one fetched from the site, over the bundled one).
    public static func newer(_ a: CuratedList?, _ b: CuratedList?) -> CuratedList? {
        guard let a = a else { return b }
        guard let b = b else { return a }
        return b.updated > a.updated ? b : a
    }

    // MARK: reading it

    /// At most this many options per job: the point is a short list.
    public static let maxPerJob = 4

    public static func parse(_ data: Data) -> CuratedList? {
        guard data.count <= 64 * 1024,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["schema"] as? Int) == schema,
              let updated = o["updated"] as? String, isDate(updated),
              let jobs = o["jobs"] as? [String: Any] else { return nil }
        var out: [CuratedJob: [CuratedOption]] = [:]
        for job in CuratedJob.allCases {
            guard let rows = jobs[job.rawValue] as? [Any] else { continue }
            var list: [CuratedOption] = []
            for case let r as [String: Any] in rows {
                guard let opt = option(r, job: job), !list.contains(where: { $0.service == opt.service && $0.model == opt.model }) else { continue }
                list.append(opt)
                if list.count == maxPerJob { break }
            }
            if !list.isEmpty { out[job] = list }
        }
        return out.isEmpty ? nil : CuratedList(updated: updated, jobs: out)
    }

    /// One option, or nil when anything in it is off: a service the app has no preset for (or the user's own), a
    /// model id or name that isn't plain, regions the service doesn't have, a speech model on a service that doesn't
    /// recognise speech. Any other field (an address, above all) is never read.
    static func option(_ r: [String: Any], job: CuratedJob) -> CuratedOption? {
        guard let service = r["service"] as? String, let p = CloudPreset.preset(service), !p.custom,
              job != .speech || p.speech,
              let model = r["model"] as? String, CloudCustom.validModelID(model),
              let name = (r["name"] as? String)?.trimmingCharacters(in: .whitespaces), plain(name, max: 60),
              let measured = r["measured"] as? String, isDate(measured) else { return nil }
        var regions: [CloudRegion] = []
        if let rs = r["regions"] {
            guard let list = rs as? [String] else { return nil }
            let have = Set(p.endpoints.compactMap(\.region))
            regions = list.compactMap(CloudRegion.init(rawValue:)).filter { have.contains($0) }
            // named regions, none of them the service's: offered nowhere
            if regions.isEmpty && p.regional { return nil }
            if !p.regional { regions = [] }
        }
        var note: String?
        if let n = r["note"] {
            guard let s = n as? String, s.range(of: #"^[a-z0-9_]{1,30}(\.[a-z0-9_]{1,30}){0,2}$"#, options: .regularExpression) != nil else { return nil }
            note = s
        }
        return CuratedOption(service: service, model: model, name: name, regions: regions, note: note, measured: measured)
    }

    static func isDate(_ s: String) -> Bool { s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }

    /// Printable, no control characters, not too long.
    static func plain(_ s: String, max: Int) -> Bool {
        !s.isEmpty && s.count <= max && !s.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }
    }

    /// Fetched from the site at most once a day (at launch, when Settings → Models opens).
    public static func refreshDue(last: Date?, now: Date = Date()) -> Bool {
        guard let l = last else { return true }
        return now.timeIntervalSince(l) >= 86_400 || now < l
    }
}

// MARK: - where a job goes

public enum CuratedRouting {
    /// Where a job goes. Auto: the first curated option whose service is connected, else this Mac — never a model
    /// Blurt didn't measure. A service picked with no model: its curated model for the job, else this Mac. A picked
    /// model stays whatever it is (a Custom Model, or one kept from an earlier setup). A service that is gone → this Mac.
    public static func resolve(_ job: CloudJob, choice: CloudJobChoice, connected: [CloudService], list: CuratedList) -> CloudRoute {
        switch choice {
        case .local: return .local
        case .cloud(let id, let model):
            guard let s = connected.first(where: { $0.id == id }) else { return .local }
            if !model.isEmpty { return .cloud(service: id, model: model) }
            guard let o = list.options(job).first(where: { $0.runs(on: s) }) else { return .local }
            return .cloud(service: id, model: o.model)
        case .auto:
            for o in list.options(job) {
                if let s = connected.first(where: o.runs(on:)) { return .cloud(service: s.id, model: o.model) }
            }
            return .local
        }
    }

    /// What a job row recommends instead of a model Blurt didn't measure: the first curated option on a connected
    /// service (Switch moves the job there), else the first one (Switch adds its key first). nil while the job runs
    /// on this Mac or on a curated option — nothing is ever suggested over a choice Blurt measured.
    public struct Pick: Hashable {
        public let option: CuratedOption
        /// the connected service to switch to (nil: its key must be added first)
        public let service: CloudService?
    }

    public static func recommendation(_ job: CloudJob, route: CloudRoute, connected: [CloudService], list: CuratedList) -> Pick? {
        guard case .cloud(let id, let model) = route, let s = connected.first(where: { $0.id == id }),
              list.option(job, on: s, model: model) == nil else { return nil }
        for o in list.options(job) {
            if let c = connected.first(where: o.runs(on:)) { return Pick(option: o, service: c) }
        }
        return list.options(job).first.map { Pick(option: $0, service: nil) }
    }
}

// MARK: - from the open lists (record.cloud v1)

public enum CuratedMigration {
    /// record.cloud v1 → 2: a job on Auto that ran on a model the curated list doesn't have (Auto used to take a
    /// connected service's newest model) keeps it, pinned — nothing changes under anyone. `legacy`: the job's route by
    /// the v1 rule (CloudRouting.resolve over the cached model lists). Every other job stays as it was.
    public static func pin(_ setup: CloudSetup, connected: [CloudService], list: CuratedList, legacy: (CloudJob) -> CloudRoute) -> CloudSetup {
        var s = setup
        for job in CloudJob.allCases where setup.choice(job) == .auto {
            guard case .cloud(let id, let model) = legacy(job), !model.isEmpty,
                  let svc = connected.first(where: { $0.id == id }), list.option(job, on: svc, model: model) == nil else { continue }
            s.jobs[job] = .cloud(service: id, model: model)
        }
        return s
    }
}

// MARK: - a Custom Model

/// Advanced → Custom Model: any service's model for one job, by its id. Nothing is saved until the job's own test
/// passes (polish: one sentence; translate: one sentence; Copy Text from Screen: a small picture with text; speech: a
/// short clip) — a model that fails is never put on a job.
public enum CloudCustom {
    public enum Problem: Hashable { case address, model, key(CloudKeyCheck.Problem) }

    /// A model id as services write them: letters, digits and . _ - : / (OpenRouter's "vendor/model"), up to 100.
    public static func validModelID(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,99}$"#, options: .regularExpression) != nil
    }

    /// An address a key may go to: https, or http only to this Mac (a local server).
    public static func validAddress(_ s: String) -> Bool {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), let host = u.host, !host.isEmpty else { return false }
        if u.scheme == "https" { return true }
        return u.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// What keeps Save from even testing: the address, the model id, the key (none typed and none saved, or one no key
    /// can be). nil: Save may test.
    public static func problem(baseURL: String, model: String, typedKey: String, keySaved: Bool) -> Problem? {
        if !validAddress(baseURL) { return .address }
        if !validModelID(model.trimmingCharacters(in: .whitespaces)) { return .model }
        let k = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { return keySaved ? nil : .key(.empty) }
        return CloudKeyCheck.problem(k).map(Problem.key)
    }

    public enum Outcome: Hashable { case save, refuse(code: String) }

    /// The test's answer decides: saved only when it passed (`{"ok": true}`), else refused with its reason's code.
    public static func outcome(_ check: [String: Any]?) -> Outcome {
        guard let c = check else { return .refuse(code: "failed") }
        if c["ok"] as? Bool == true { return .save }
        return .refuse(code: (c["code"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "failed")
    }
}
