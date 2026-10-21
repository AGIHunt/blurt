// Read-only view of ~/.blurt/index.db (contract C3, docs/contracts/index-schema.sql). Owned by WP5 (mac-main-window);
// this is the WP4-gate stub: types and signatures only.
import Foundation

public struct WorkspaceRow: Hashable {
    public var id: String, path: String, name: String, kind: String    // kind: default | repo
    public var sessions: Int, openItems: Int
    public init(id: String, path: String, name: String, kind: String, sessions: Int = 0, openItems: Int = 0) {
        self.id = id; self.path = path; self.name = name; self.kind = kind; self.sessions = sessions; self.openItems = openItems
    }
}

public struct SessionRow: Hashable {
    public var id: String, workspaceID: String, dir: String, mode: String    // mode: video | shots
    public var title: String?, created: Double?, itemCount: Int, processed: Bool, processing: Bool, reviewed: Bool
    public init(id: String, workspaceID: String, dir: String, mode: String, title: String? = nil, created: Double? = nil,
                itemCount: Int = 0, processed: Bool = false, processing: Bool = false, reviewed: Bool = false) {
        self.id = id; self.workspaceID = workspaceID; self.dir = dir; self.mode = mode; self.title = title; self.created = created
        self.itemCount = itemCount; self.processed = processed; self.processing = processing; self.reviewed = reviewed
    }
}

/// C3 ItemRow
public struct ItemRow: Hashable {
    public var uid: String, sessionID: String, sessionDir: String, itemID: String, kind: String, title: String
    public var status: String, fixState: String?, severity: String?, primaryFrame: String?, updated: Double, snippet: String?
    public init(uid: String, sessionID: String, sessionDir: String, itemID: String, kind: String, title: String, status: String,
                fixState: String? = nil, severity: String? = nil, primaryFrame: String? = nil, updated: Double = 0, snippet: String? = nil) {
        self.uid = uid; self.sessionID = sessionID; self.sessionDir = sessionDir; self.itemID = itemID; self.kind = kind
        self.title = title; self.status = status; self.fixState = fixState; self.severity = severity
        self.primaryFrame = primaryFrame; self.updated = updated; self.snippet = snippet
    }
}

public struct SessionQuery {
    public var workspace: String?, state: String?     // state: unprocessed | processing | unreviewed | reviewed
    public var limit = 200, offset = 0
    public init(workspace: String? = nil, state: String? = nil, limit: Int = 200, offset: Int = 0) {
        self.workspace = workspace; self.state = state; self.limit = limit; self.offset = offset
    }
}

public struct ItemQuery {
    public var text: String?                          // ≥ 3 chars: FTS5 trigram; 1–2: LIKE; nil/empty: filters only
    public var kinds: [String] = [], statuses: [String] = [], fixStates: [String] = []
    public var workspace: String?, session: String?
    public var sort = "updated"                       // updated | created | t_start
    public var limit = 50, offset = 0
    public init(text: String? = nil, kinds: [String] = [], statuses: [String] = [], fixStates: [String] = [],
                workspace: String? = nil, session: String? = nil, sort: String = "updated", limit: Int = 50, offset: Int = 0) {
        self.text = text; self.kinds = kinds; self.statuses = statuses; self.fixStates = fixStates
        self.workspace = workspace; self.session = session; self.sort = sort; self.limit = limit; self.offset = offset
    }
}

public enum IndexError: Error { case notImplemented, open(String), query(String) }

public final class IndexReader {
    public init(url: URL = BlurtPaths.indexDB) throws { throw IndexError.notImplemented }
    public func workspaces() throws -> [WorkspaceRow] { [] }
    public func sessions(_ q: SessionQuery) throws -> [SessionRow] { [] }
    public func items(_ q: ItemQuery) throws -> [ItemRow] { [] }
    public func count(_ q: ItemQuery) throws -> Int { 0 }
}
