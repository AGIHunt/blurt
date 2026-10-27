// K10: the app's strings, from per-package tables — Sources/BlurtApp/Resources/{en,zh-Hans}.lproj/<Table>.strings
// (plurals in the same-named .stringsdict). record.py build copies the .lproj folders into Contents/Resources; a
// `swift build` binary run from the source tree finds them next to the sources.
//   Loc.t("main.place.inbox", table: "Main")                     → "Inbox" / "待处理"
//   Loc.t("main.open.failed", table: "Main", name)            → %@ / %ld placeholders, String(format:locale:)
//   Loc.plural("main.items.count", table: "Main", count: n)       → .stringsdict (count is the first argument)
// Language: config `lang` = auto (default: the system's first preferred language, zh-* → zh-Hans, anything else → en) |
// en | zh | zh-Hans; `Loc.setting` (the app's --lang) wins. A key missing from the language falls back to en, then to
// the key itself, so a gap shows up as "main.inbox.title" rather than an empty label.
import Foundation

public enum Loc {
    /// The supported UI languages, in fallback order.
    public static let languages = ["en", "zh-Hans"]

    /// An explicit choice for this process (the app's --lang), else nil = config `lang`.
    public static var setting: String? { didSet { cache.removeAll(); resolved = nil } }

    /// "en" | "zh-Hans" — resolved once per process: changing `lang` in Settings applies the next time Blurt opens,
    /// so nothing re-rendered in the meantime comes out in the other language (a half-translated window).
    public static var language: String {
        if let l = resolved { return l }
        let l = normalize(setting ?? (Config.shared["lang"] as? String) ?? "auto")
        resolved = l
        return l
    }
    private static var resolved: String?

    /// An explicit language (--lang, or config `lang` other than auto) also for the system frameworks' own strings — the
    /// Open panel, the sidebar button, standard menu items, alert buttons — so an English UI on a Chinese Mac (or the
    /// other way round) isn't half one language. Only for this process (the argument domain; nothing is persisted), and
    /// before anything has loaded a localized resource. Auto leaves the system's choice alone.
    public static func applyToSystemStrings() {
        let raw = setting ?? (Config.shared["lang"] as? String) ?? "auto"
        guard raw.lowercased() != "auto" else { return }
        var d = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        d["AppleLanguages"] = [normalize(raw)]
        UserDefaults.standard.setVolatileDomain(d, forName: UserDefaults.argumentDomain)
    }

    public static func normalize(_ raw: String) -> String {
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

    /// A text from data that carries its own translations (agents.json: {"en": …, "zh": …}): the UI language, then en.
    public static func pick(_ texts: [String: String]) -> String? {
        let keys = language == "zh-Hans" ? ["zh-Hans", "zh", "en"] : [language, "en"]
        return keys.lazy.compactMap { texts[$0] }.first
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

    /// A key in one given language, nil when that language doesn't have it (Settings search matches both languages).
    public static func string(_ key: String, table: String, language lang: String) -> String? {
        guard let b = bundle(lang) else { return nil }
        let s = b.localizedString(forKey: key, value: missing, table: table)
        return s == missing ? nil : s
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

    /// A list row's date, the way Mail sets it: the time today ("10:42"), "Yesterday", the weekday this week ("Mon"),
    /// "Oct 24" this year, a short date before that. One short token at a fixed width, never "1 min. ago" on every row.
    static func listDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        var cal = calendar
        cal.locale = locale
        let key = locale.identifier + "|" + cal.timeZone.identifier
        if listFormatters.key != key { listFormatters = (key, [:]) }
        func f(_ name: String, _ make: (DateFormatter) -> Void) -> DateFormatter {
            if let d = listFormatters.cache[name] { return d }
            let d = DateFormatter()
            d.locale = locale
            d.calendar = cal
            d.timeZone = cal.timeZone
            make(d)
            listFormatters.cache[name] = d
            return d
        }
        if cal.isDate(date, inSameDayAs: now) || date > now {
            return f("time") { $0.dateStyle = .none; $0.timeStyle = .short }.string(from: date)
        }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 99
        if days == 1 {
            // the system's own word for it ("Yesterday" / "昨天"): a relative formatter says it of the real yesterday
            return f("yesterday") { $0.dateStyle = .medium; $0.timeStyle = .none; $0.doesRelativeDateFormatting = true }
                .string(from: Date().addingTimeInterval(-86_400))
        }
        if days < 7 { return f("weekday") { $0.setLocalizedDateFormatFromTemplate("EEE") }.string(from: date) }
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            return f("monthday") { $0.setLocalizedDateFormatFromTemplate("MMMd") }.string(from: date)
        }
        return f("short") { $0.dateStyle = .short; $0.timeStyle = .none }.string(from: date)
    }
    private static var listFormatters: (key: String, cache: [String: DateFormatter]) = ("", [:])

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
