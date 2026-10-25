// An app's name for people: "TextEdit", never "com.apple.TextEdit". Records keep the bundle id for lookups (icons,
// per-app styles); what the UI shows comes from here — the running app's localized name, else the installed app's
// display name, else the stored text. A stored name that is really a bundle id (older history rows) is resolved too.
import AppKit
import BlurtCore

enum AppNames {
    private static var cache: [String: String] = [:]

    /// The display name for an app known by `name` and/or `bundle`; nil when only an id is known and no installed app
    /// answers to it (the caller says "Unknown app" — never the id).
    static func display(name: String?, bundle: String?) -> String? {
        if let n = name, !n.isEmpty, !looksLikeBundleID(n) { return n }
        for id in [bundle, name].compactMap({ $0 }) where looksLikeBundleID(id) {
            if let n = resolve(id) { return n }
        }
        return nil
    }

    /// `display`, or "Unknown app" in words.
    static func displayOrUnknown(name: String?, bundle: String?) -> String {
        display(name: name, bundle: bundle) ?? Loc.t("main.dictation.unknown_app", table: "Main")
    }

    /// The name to store for a take: the running app's name when it is that app, else the installed app's name; nil
    /// when neither knows it (the bundle id is stored beside it anyway — never as the name).
    static func name(for bundle: String?, running: NSRunningApplication?) -> String? {
        if let r = running, bundle == nil || r.bundleIdentifier == bundle, let n = r.localizedName, !n.isEmpty { return n }
        return bundle.flatMap(resolve)
    }

    static func looksLikeBundleID(_ s: String) -> Bool { AppIdentity.looksLikeBundleID(s) }

    static func resolve(_ bundle: String) -> String? {
        if let n = cache[bundle] { return n }
        var n = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName
        if n == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            n = (Bundle(url: url)?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        if let n = n { cache[bundle] = n }
        return n
    }
}
