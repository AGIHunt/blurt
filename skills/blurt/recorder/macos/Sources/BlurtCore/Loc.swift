// K10 localisation (G0 stub, owner P4): string tables in <bundle>/Resources/{en,zh-Hans}.lproj/<Table>.strings, plurals
// in the same-named .stringsdict. Keys are dotted lowercase English ("capture.voice.listening"); a key missing from the
// interface language falls back to en, then to the key itself.
import Foundation

public enum Loc {
    /// "en" | "zh-Hans" — follows BlurtLocale.lang (config `lang` / --lang / the system's preferred language).
    public static var language: String { BlurtLocale.lang.hasPrefix("zh") ? "zh-Hans" : "en" }

    /// Interface language + the system's region, for dates, numbers and plurals.
    public static var locale: Locale {
        let region = Locale.current.regionCode
        return Locale(identifier: region.map { "\(language)_\($0)" } ?? language)
    }

    public static func t(_ key: String, table: String = "Common", _ args: CVarArg...) -> String {
        format(lookup(key, table: table), args)
    }

    public static func plural(_ key: String, table: String = "Common", count: Int, _ args: CVarArg...) -> String {
        format(lookup(key, table: table), [count] + args)
    }

    // MARK: lookup

    private static var bundles: [String: Bundle] = [:]
    private static let lock = NSLock()

    /// Bundle.main's lproj, or $BLURT_LOC_DIR/<lang>.lproj (a `swift build` binary has no Resources folder).
    static func bundle(_ lang: String) -> Bundle? {
        lock.lock(); defer { lock.unlock() }
        if let b = bundles[lang] { return b }
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["BLURT_LOC_DIR"] { dirs.append(URL(fileURLWithPath: env)) }
        if let r = Bundle.main.resourceURL { dirs.append(r) }
        for d in dirs {
            let p = d.appendingPathComponent("\(lang).lproj")
            if let b = Bundle(path: p.path) { bundles[lang] = b; return b }
        }
        return nil
    }

    private static let missing = "\u{0}missing"

    static func lookup(_ key: String, table: String) -> String {
        for lang in [language, "en"] {
            if let b = bundle(lang) {
                let v = b.localizedString(forKey: key, value: missing, table: table)
                if v != missing { return v }
            }
        }
        return key
    }

    private static func format(_ f: String, _ args: [CVarArg]) -> String {
        args.isEmpty ? f : String(format: f, locale: locale, arguments: args)
    }
}
