// Blurt: written by hand in place of SwiftTerm's SwiftTermBuildInfoPlugin (a build-tool plugin that runs git at build
// time). The vendored copy is a fixed release, so the values are constants. Terminal.swift reports them in XTVERSION.

/// Source-control information for this SwiftTerm build.
public enum SwiftTermBuildInfo {
    public static let branch: String? = nil
    public static let tag: String? = "v1.20.0"
    public static let commit: String? = "5d14406844143538cd8f8851d2d8a67c1fe443e5"
    public static let hasUncommittedChanges: Bool? = false
    public static let version: String = "v1.20.0"
}
