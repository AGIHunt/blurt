// Folders inside a store (<store>/sessions/<ts>[-shots|-voice] and its shots/) are made only while the folder that
// holds the store is there (v0.9-fix2 review). A project folder that was moved or renamed must never come back at
// its old path: the app used to keep the open shots batch by project id, so after Locate… the next snap still wrote
// into the old <folder>/.blurt/sessions/…-shots — creating the old folder again, and captures.py then found a folder
// there and made a second store with the same project id (a "ghost"). Now:
//   • the open batch is kept by its store's path (`batchKey`) — a relocated project has a new store, so a new batch;
//   • a kept batch is reused only while its folder is still on disk under that store (`stillUsable`);
//   • every folder made below a store goes through `make`, which refuses (and makes nothing) when the folder holding
//     the store is gone.
import Foundation

public enum StoreFolders {
    /// The key an open batch is kept under: the project's store, spelled one way (symlinks resolved where they exist).
    public static func batchKey(_ store: URL) -> String { store.resolvingSymlinksInPath().standardizedFileURL.path }

    /// A batch folder kept from earlier is still the right one for `store`: it is inside <store>/sessions and on disk.
    public static func stillUsable(_ batchDir: URL, store: URL) -> Bool {
        let d = batchKey(batchDir), s = batchKey(store.appendingPathComponent("sessions"))
        return d.hasPrefix(s + "/") && FileManager.default.fileExists(atPath: batchDir.path)
    }

    /// The store `dir` lies in: the folder above its nearest "sessions" ancestor (nil: not inside a store's sessions).
    public static func store(of dir: URL) -> URL? {
        var u = dir.standardizedFileURL
        while u.path != "/" {
            if u.lastPathComponent == "sessions" { return u.deletingLastPathComponent() }
            u.deleteLastPathComponent()
        }
        return nil
    }

    /// Makes `dir` with any missing parents — but inside a project's store (<folder>/.blurt), only while that project
    /// folder is still there. Unassigned's store (the workspace's inbox) is always made. False when refused or failed.
    @discardableResult
    public static func make(_ dir: URL) -> Bool {
        let fm = FileManager.default
        if let store = store(of: dir), store.lastPathComponent == ".blurt",
           !fm.fileExists(atPath: store.deletingLastPathComponent().path) { return false }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return false }
        return true
    }
}
