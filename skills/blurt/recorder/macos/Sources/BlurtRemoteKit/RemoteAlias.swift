// A name the user gives a paired device or computer on this machine (docs/design/remote-1.1.md §6): a local display name only. It is
// kept beside the record, shown before the device's own name, never sent to the other side, and the record's id never changes with it.
import Foundation

public enum RemoteAlias {
    /// as long as a device's own name may be (a hello's name is cut there too)
    public static let maxLength = 64

    /// What a rename keeps, from what was typed: nil (the device's own name again) for an empty field or one that says just that name.
    public static func typed(_ text: String, own name: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != name else { return nil }
        return String(t.prefix(maxLength))
    }

    /// The name to show: the user's, else the device's own.
    public static func shown(_ name: String, alias: String?) -> String {
        guard let a = alias, !a.isEmpty else { return name }
        return a
    }
}
