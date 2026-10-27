// The rows above the main window's item list, from the keyboard (micro 15): the "Unfiled captures" and "Recently
// dragged out" banners, then the running jobs. ↑ on the first item walks up into them, ↑ / ↓ walk them, ↓ from the
// last one is the first item again; ↩ on a banner does what its click does. Ids are the app's ("banner:captures",
// a job's id) — this only decides where the cursor goes.
import Foundation

public enum TopRows {
    public enum Move: Equatable {
        /// not ours: the list moves its own selection
        case pass
        /// nowhere to go (the top, or no items below)
        case beep
        case row(String)
        case firstItem
    }

    /// `rows`: the visible rows above the list, top to bottom; `current`: the one the cursor is on (nil = it's in the
    /// list, on `fromRow`); `d`: -1 up, +1 down.
    public static func step(_ rows: [String], current: String?, by d: Int, fromRow: Int, hasItems: Bool) -> Move {
        if let cur = current, let k = rows.firstIndex(of: cur) {
            let n = k + d
            if n < 0 { return .beep }
            if n >= rows.count { return hasItems ? .firstItem : .beep }
            return .row(rows[n])
        }
        guard d < 0, fromRow <= 0, let last = rows.last else { return .pass }
        return .row(last)
    }
}
