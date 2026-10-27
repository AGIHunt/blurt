// Whether a stored app label is really a bundle id ("com.apple.TextEdit") rather than a name for people. Mechanical:
// reverse-DNS shape — at least two dots, no spaces, only letters, digits and . - _. The app's AppNames resolves such a
// label to the installed app's name before showing it.
public enum AppIdentity {
    public static func looksLikeBundleID(_ s: String) -> Bool {
        !s.contains(" ") && s.split(separator: ".", omittingEmptySubsequences: false).count >= 3
            && !s.hasPrefix(".") && !s.hasSuffix(".")
            && s.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }
}
