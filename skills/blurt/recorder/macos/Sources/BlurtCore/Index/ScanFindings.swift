// What an `index.py scan` found that people should hear about, each file once per app run: item files that can't be
// read ("unreadable": the row stays, its detail says so) and files that couldn't be indexed at all ("skipped": the
// list keeps showing what it had). A file that stays broken is said the first time, not on every scan; the raw error
// of a skipped file goes to the log only (ScanReport in the app).
import Foundation

public struct ScanFindings: Equatable {
    public struct File: Equatable {
        public let path: String
        public let uid: String?
        public let id: String?
        public init(path: String, uid: String? = nil, id: String? = nil) { self.path = path; self.uid = uid; self.id = id }
    }

    public var unreadable: [File] = []
    public var skipped: [File] = []
    public var isEmpty: Bool { unreadable.isEmpty && skipped.isEmpty }

    /// Paths already said this run.
    public struct Told { public var paths = Set<String>(); public init() {} }

    /// The findings of one scan result that haven't been said yet; marks them said.
    public static func fresh(in report: [String: Any], told: inout Told) -> ScanFindings {
        func files(_ key: String) -> [File] {
            (report[key] as? [[String: Any]] ?? []).compactMap { o in
                guard let p = o["path"] as? String, told.paths.insert(p).inserted else { return nil }
                return File(path: p, uid: o["uid"] as? String, id: o["id"] as? String)
            }
        }
        let unreadable = files("unreadable")
        return ScanFindings(unreadable: unreadable, skipped: files("skipped"))
    }
}
