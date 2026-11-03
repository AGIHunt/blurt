// The curated model list (BlurtCore CloudCurated.swift: the schema and every rule): the skill's
// scripts/curated_models.json, bundled with the app, and the copy fetched from https://blurt.work/models/curated.json
// (site/models/curated.json) into $BLURT_HOME/curated-models.json — the newer of the two by its "updated" date.
//
// Fetched at launch and when Settings → Models opens, at most once a day (a day after the last answer from the site;
// offline: next time). Nothing is sent but the GET (no cookies, no cache, no key). A file that doesn't read as a list
// (not JSON, another schema, nothing valid in it) is dropped and the last good one stays; a valid one names only the
// app's own services, never an address (the request goes to the preset's address from this build).
import Foundation
import BlurtCore

enum CuratedModels {
    static let url = URL(string: "https://blurt.work/models/curated.json")!

    private static let lock = NSLock()
    private static var cached: CuratedList?
    private static var fetching = false
    private static let checkedKey = "BlurtCuratedModelsCheckedAt"

    private static var fetchedFile: URL { BlurtPaths.home.appendingPathComponent("curated-models.json") }
    private static var bundledFile: URL { BlurtPaths.scripts.appendingPathComponent("curated_models.json") }

    /// The list in use: the newer of the fetched and the bundled one (empty only when neither reads: every job then
    /// offers This Mac alone).
    static var list: CuratedList {
        lock.lock()
        if let c = cached { lock.unlock(); return c }
        lock.unlock()
        let fetched = (try? Data(contentsOf: fetchedFile)).flatMap(CuratedList.parse)
        let bundled = (try? Data(contentsOf: bundledFile)).flatMap(CuratedList.parse)
        let l = CuratedList.newer(fetched, bundled) ?? .empty
        lock.lock(); cached = l; lock.unlock()
        return l
    }

    private static func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fetching { return false }
        fetching = true
        return true
    }
    private static func end() { lock.lock(); fetching = false; lock.unlock() }
    private static func forget() { lock.lock(); cached = nil; lock.unlock() }

    /// Fetch the site's copy when the last answer is a day old. Test builds never fetch.
    static func refreshIfDue() {
        guard !CloudStore.Key.testBuild else { return }
        let last = UserDefaults.standard.object(forKey: checkedKey) as? Date
        guard CuratedList.refreshDue(last: last) else { return }
        guard begin() else { return }
        Task.detached(priority: .utility) {
            defer { end() }
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 10
            cfg.httpCookieStorage = nil
            cfg.urlCache = nil
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: cfg)
            defer { session.finishTasksAndInvalidate() }
            guard let (data, resp) = try? await session.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return }       // offline, or the site down: next time
            UserDefaults.standard.set(Date(), forKey: checkedKey)
            guard let fresh = CuratedList.parse(data) else {
                emit(["event": "curated_models", "action": "refused", "bytes": data.count])
                return
            }
            let before = list
            try? data.write(to: fetchedFile, options: .atomic)
            forget()
            if list != before {
                emit(["event": "curated_models", "action": "updated", "updated": fresh.updated])
                CloudStore.didChange()
            }
        }
    }
}
