// Items in Spotlight: title, what the user said, kind / state, and the primary frame as the thumbnail. Choosing a
// result opens the item (NSUserActivity CSSearchableItemActionType → URLRouter, like blurt://item/<uid>).
// Source: index.db (read-only). Reindexed at launch and a few seconds after any items.json changes (FixWatcher).
// BLURT_SPOTLIGHT_DOMAIN (tests) replaces the domain identifier, so test entries can be removed on their own.
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers
import BlurtCore

final class Spotlight {
    static let shared = Spotlight()
    static var domain: String { ProcessInfo.processInfo.environment["BLURT_SPOTLIGHT_DOMAIN"] ?? "dev.blurt.items" }

    var enabled: Bool { Config.shared["spotlight"] as? Bool ?? true }
    private var indexed = Set<String>()
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "blurt.spotlight")
    private(set) var lastCount = 0

    /// Debounced full refresh (cheap: one query, upserts).
    func refreshSoon(_ delay: Double = 3) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func refresh(completion: ((Int, Error?) -> Void)? = nil) {
        guard enabled, CSSearchableIndex.isIndexingAvailable() else { completion?(0, nil); return }
        queue.async {
            let rows = IndexLookup.items()
            let items = rows.map(Spotlight.searchable)
            let now = Set(rows.map(\.uid))
            let gone = self.indexed.subtracting(now)
            let idx = CSSearchableIndex.default()
            let finish: (Error?) -> Void = { err in
                self.indexed = now
                self.lastCount = items.count
                DispatchQueue.main.async { completion?(items.count, err) }
            }
            let index = { idx.indexSearchableItems(items) { err in finish(err) } }
            if gone.isEmpty { index() } else { idx.deleteSearchableItems(withIdentifiers: Array(gone)) { _ in index() } }
        }
    }

    /// Everything in our domain (Settings → Privacy "Remove from Spotlight", and tests).
    func removeAll(completion: ((Error?) -> Void)? = nil) {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Spotlight.domain]) { err in
            self.indexed = []
            DispatchQueue.main.async { completion?(err) }
        }
    }

    static func searchable(_ r: IndexedItem) -> CSSearchableItem {
        let a = CSSearchableItemAttributeSet(contentType: UTType.text)
        a.title = r.title.isEmpty ? r.itemID : r.title
        let kind = kindLabel(r.kind)
        let ws = (r.workspacePath as NSString).lastPathComponent
        var desc = [kind, ws].joined(separator: " · ")
        if r.fixState == "fixed" { desc += L(" · 已修", " · fixed") }
        if !r.quote.isEmpty { desc += "\n“\(r.quote)”" }
        a.contentDescription = desc
        a.textContent = r.quote
        a.keywords = ["blurt", "口喷鸡", r.kind, kind, ws]
        a.displayName = a.title
        if let f = r.primaryFrame, FileManager.default.fileExists(atPath: f) { a.thumbnailURL = URL(fileURLWithPath: f) }
        a.contentModificationDate = Date(timeIntervalSince1970: r.updated)
        a.relatedUniqueIdentifier = nil
        let item = CSSearchableItem(uniqueIdentifier: r.uid, domainIdentifier: domain, attributeSet: a)
        item.expirationDate = .distantFuture
        return item
    }

    static func kindLabel(_ k: String) -> String {
        switch k {
        case "issue": return L("问题", "Issue")
        case "idea": return L("想法", "Idea")
        case "note": return L("笔记", "Note")
        case "task": return L("待办", "Task")
        default: return k
        }
    }

    /// CSSearchQuery over our own index (the acceptance test: an item's title is found).
    func search(_ text: String, completion: @escaping ([String]) -> Void) {
        let esc = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let q = CSSearchQuery(queryString: "title == \"*\(esc)*\"cd", attributes: ["title"])
        var found: [String] = []
        q.foundItemsHandler = { items in found += items.map(\.uniqueIdentifier) }
        q.completionHandler = { _ in DispatchQueue.main.async { completion(found) } }
        q.start()
    }
}

// Spotlight result chosen → open the item. An extension so the shell's AppDelegate needs no change.
extension App {
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let uid = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        return URLRouter.handle(URL(string: "blurt://item/\(uid)")!)
    }
}
