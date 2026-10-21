// K10: the app's strings, from per-package tables — Sources/BlurtApp/Resources/{en,zh-Hans}.lproj/<Table>.strings
// (plurals in the same-named .stringsdict). record.py build copies the .lproj folders into Contents/Resources; a
// `swift build` binary run from the source tree finds them next to the sources.
//   Loc.t("main.inbox.title", table: "Main")                     → "Inbox" / "收件箱"
//   Loc.t("main.items.selected", table: "Main", name)            → %@ / %ld placeholders, String(format:locale:)
//   Loc.plural("main.items.count", table: "Main", count: n)      → .stringsdict (count is the first argument)
// Language: config `lang` = auto (default: the system's first preferred language, zh-* → zh-Hans, anything else → en) |
// en | zh | zh-Hans; `Loc.setting` (the app's --lang) wins. A key missing from the language falls back to en, then to
// the key itself, so a gap shows up as "main.inbox.title" rather than an empty label.
import Foundation

public enum Loc {
    /// The supported UI languages, in fallback order.
    public static let languages = ["en", "zh-Hans"]

    /// An explicit choice for this process (the app's --lang), else nil = config `lang`.
    public static var setting: String? { didSet { cache.removeAll() } }

    /// "en" | "zh-Hans"
    public static var language: String {
        let raw = setting ?? (Config.shared["lang"] as? String) ?? "auto"
        return normalize(raw)
    }

    static func normalize(_ raw: String) -> String {
        switch raw.lowercased() {
        case "en", "en-us", "en-gb": return "en"
        case "zh", "zh-hans", "zh-cn", "zh_cn", "zh-sg": return "zh-Hans"
        default: return (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
        }
    }

    /// The UI language with the user's region: dates, numbers and plural rules follow the language, separators and
    /// calendars the region (en_DE gets 22.10.2026, zh-Hans_US gets 2026/10/22).
    public static var locale: Locale {
        let region: String? = {
            if #available(macOS 13, *) { return Locale.current.region?.identifier }
            return Locale.current.regionCode
        }()
        return Locale(identifier: language + (region.map { "_" + $0 } ?? ""))
    }

    /// true for zh-Hans: callers that build sentences around names use it to pick spacing / punctuation.
    public static var isChinese: Bool { language == "zh-Hans" }

    public static func t(_ key: String, table: String = "Common", _ args: CVarArg...) -> String {
        format(string(key, table: table), args)
    }

    /// `count` comes first in the format's arguments, `args` after it.
    public static func plural(_ key: String, table: String = "Common", count: Int, _ args: CVarArg...) -> String {
        format(string(key, table: table), [count] + args)
    }

    /// The raw format string (no arguments applied).
    public static func string(_ key: String, table: String = "Common") -> String {
        for lang in [language, "en"] {
            guard let b = bundle(lang) else { continue }
            let s = b.localizedString(forKey: key, value: missing, table: table)
            if s != missing { return s }
        }
        return key
    }

    /// Whether a key exists in the current language (tests, optional strings).
    public static func has(_ key: String, table: String = "Common") -> Bool {
        bundle(language).map { $0.localizedString(forKey: key, value: missing, table: table) != missing } ?? false
    }

    public static func format(_ fmt: String, _ args: [CVarArg]) -> String {
        args.isEmpty && !fmt.contains("%") ? fmt : String(format: fmt, locale: locale, arguments: args)
    }

    private static let missing = "\u{1}missing\u{1}"
    private static var cache: [String: Bundle] = [:]
    private static let lock = NSLock()

    /// The folders that may hold <lang>.lproj: $BLURT_L10N_DIR (tests), the app bundle's Resources, the source tree.
    static var searchRoots: [URL] {
        var roots: [URL] = []
        if let d = ProcessInfo.processInfo.environment["BLURT_L10N_DIR"] { roots.append(URL(fileURLWithPath: d)) }
        if let r = Bundle.main.resourceURL { roots.append(r) }
        // Sources/BlurtCore/Loc.swift → Sources/BlurtApp/Resources
        roots.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BlurtApp/Resources"))
        return roots
    }

    static func bundle(_ lang: String) -> Bundle? {
        lock.lock(); defer { lock.unlock() }
        if let b = cache[lang] { return b }
        for root in searchRoots {
            let dir = root.appendingPathComponent("\(lang).lproj")
            if FileManager.default.fileExists(atPath: dir.path), let b = Bundle(path: dir.path) {
                cache[lang] = b
                return b
            }
        }
        return nil
    }
}

// MARK: - formatting in the UI language

public extension Loc {
    /// "2 min ago" / "2 分钟前"; "just now" under a minute.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(date.timeIntervalSince(now)) < 60 { return t("time.just_now") }
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    /// Medium date + short time, "Today" / "Yesterday" where it applies.
    static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }

    /// 0:42, 12:05, 1:02:03 — positional, the way media players show it everywhere.
    static func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        f.unitsStyle = .positional
        f.zeroFormattingBehavior = .pad
        var cal = Calendar.current
        cal.locale = locale
        f.calendar = cal
        return f.string(from: max(0, seconds.rounded())) ?? "0:00"
    }

    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        return f.string(from: n as NSNumber) ?? "\(n)"
    }

    /// 0.4 → "40%" / "40%"
    static func percent(_ x: Double) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .percent
        f.maximumFractionDigits = 0
        return f.string(from: x as NSNumber) ?? "\(Int(x * 100))%"
    }

    /// A list of names joined the way the language does it ("A, B and C" / "A、B 和 C").
    static func list(_ items: [String]) -> String {
        let f = ListFormatter()
        f.locale = locale
        return f.string(from: items) ?? items.joined(separator: ", ")
    }
}
