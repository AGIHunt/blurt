// Undo for Settings → Storage's Move to Trash (Settings/PrivacyStoragePanes.swift): each item goes back from the Trash
// to where it was. A folder the app made again meanwhile (tmp, build) takes the trashed folder's contents back beside
// what is in it now (nothing there is overwritten); an item that can't come back (the Trash was emptied, a name now
// taken) is reported, so the pane says so instead of a silent Undo. Unit-tested in Tests/BlurtCoreTests/TrashRestoreTests.
import Foundation

public enum TrashRestore {
    /// `moved`: original location → where it is in the Trash. Returns the originals that are back (whole, or merged
    /// into a folder made again) and the ones that aren't.
    public static func restore(_ moved: [URL: URL], fm: FileManager = .default) -> (back: [URL], missing: [URL]) {
        var back: [URL] = [], missing: [URL] = []
        for (orig, trashed) in moved.sorted(by: { $0.key.path < $1.key.path }) {
            guard fm.fileExists(atPath: trashed.path) else { missing.append(orig); continue }
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: orig.path, isDirectory: &isDir) {
                if (try? fm.moveItem(at: trashed, to: orig)) != nil { back.append(orig) } else { missing.append(orig) }
                continue
            }
            // the place is taken again: a folder made anew takes the old contents back, anything else stays put
            var trashedIsDir: ObjCBool = false
            guard isDir.boolValue, fm.fileExists(atPath: trashed.path, isDirectory: &trashedIsDir), trashedIsDir.boolValue,
                  let kids = try? fm.contentsOfDirectory(atPath: trashed.path) else { missing.append(orig); continue }
            var all = true
            for k in kids {
                let to = orig.appendingPathComponent(k)
                if fm.fileExists(atPath: to.path) || (try? fm.moveItem(at: trashed.appendingPathComponent(k), to: to)) == nil { all = false }
            }
            if all { try? fm.removeItem(at: trashed); back.append(orig) } else { missing.append(orig) }
        }
        return (back, missing)
    }
}
