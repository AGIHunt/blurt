// Dictation styles (docs/design/dictation-styles.md §3): a small fixed set, picked per take by rules, never by a model.
//
//   verbatim     the speech model's text with its punctuation; no polish
//   light        the default everywhere: today's polish (fillers, stutters, self-corrections, punctuation). Never a
//                list, never a tone change
//   structured   light + spoken ordinal enumerations rendered as a numbered list (DictationList, deterministic, < 5 ms)
//   auto         light, and the list only when the renderer is confident (≥ 3 ordinal markers in order). Ships off
//
// The app's category (chat / code / mail / notes) shapes light a little (DictationStyleVariant): chat keeps
// sentence-final particles and drops the full stop of a one-sentence message, code and terminals get one line.
// Which style a take gets (DictationStyleRouter): explicit this take (⇧, the island, Fn+⇧) > the app's own setting >
// its category's > the global default (light). No spoken commands: "make a list" / 「列个清单」 is content (people
// dictate instructions to AI agents), never a switch. Config record.dictation.styles:
//   {"chat": "light", "notes": "auto", "apps": {"com.apple.Notes": "structured"}, "learned": ["com.apple.Notes"]}
// (set as one dictionary: bundle ids have dots, which Config's dotted keys would split). Unset = the smart defaults.
import Foundation

public enum DictationStyle: String, CaseIterable, Hashable {
    case verbatim, light, structured, auto

    /// polish runs for it (verbatim types what the speech model wrote)
    public var polishes: Bool { self != .verbatim }
    /// the list renderer runs, and how many ordinal markers it needs (nil: never)
    public var listMarkers: Int? {
        switch self {
        case .structured: return DictationList.askedMarkers
        case .auto: return DictationList.autoMarkers
        default: return nil
        }
    }
    /// Reformat-last's cycle: verbatim → light → structured → verbatim (auto reformats as structured)
    public var next: DictationStyle {
        switch self {
        case .verbatim: return .light
        case .light: return .structured
        case .structured, .auto: return .verbatim
        }
    }
}

public enum DictationAppCategory: String, CaseIterable, Hashable {
    case chat, code, mail, notes, other

    /// The app a take goes into → its category. Exact bundle ids first, then the bundle id's own parts ("feishu" in
    /// com.bytedance.macos.feishu, "jetbrains" in com.jetbrains.pycharm): never a substring, so 1Password isn't Word.
    public static func of(bundle: String?) -> DictationAppCategory {
        guard let b = bundle?.lowercased(), !b.isEmpty else { return .other }
        if let c = exact[b] { return c }
        let parts = Set(b.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" }).map(String.init))
        for (c, names) in parts_ where !parts.isDisjoint(with: names) { return c }
        return .other
    }

    static let exact: [String: DictationAppCategory] = [
        // chat
        "com.tencent.xinwechat": .chat, "com.tencent.qq": .chat, "com.tinyspeck.slackmacgap": .chat,
        "ru.keepcoder.telegram": .chat, "com.apple.mobilesms": .chat, "com.hnc.discord": .chat,
        "net.whatsapp.whatsapp": .chat, "com.alibaba.dingtalkmac": .chat, "com.microsoft.teams2": .chat,
        "com.microsoft.teams": .chat, "org.whispersystems.signal-desktop": .chat, "com.facebook.archon": .chat,
        "com.electron.lark": .chat, "com.bytedance.lark": .chat, "com.tencent.wework": .chat,
        // code and terminals
        "com.apple.terminal": .code, "com.googlecode.iterm2": .code, "dev.warp.warp-stable": .code,
        "com.microsoft.vscode": .code, "com.microsoft.vscodeinsiders": .code, "com.todesktop.230313mzl4w4u92": .code,
        "com.apple.dt.xcode": .code, "com.mitchellh.ghostty": .code, "net.kovidgoyal.kitty": .code,
        "org.alacritty": .code, "io.alacritty": .code, "co.zeit.hyper": .code, "dev.zed.zed": .code,
        "com.exafunction.windsurf": .code, "com.sublimetext.4": .code, "com.github.wez.wezterm": .code,
        "com.panic.nova": .code, "com.barebones.bbedit": .code,
        // mail
        "com.apple.mail": .mail, "com.microsoft.outlook": .mail, "com.readdle.smartemail-mac": .mail,
        "com.superhuman.electron": .mail, "it.bloop.airmail2": .mail, "com.mimestream.mimestream": .mail,
        "com.netease.mailmaster": .mail,
        // notes and documents
        "com.apple.notes": .notes, "md.obsidian": .notes, "notion.id": .notes, "net.shinyfrog.bear": .notes,
        "com.apple.iwork.pages": .notes, "com.microsoft.word": .notes, "com.lukilabs.lukiapp": .notes,
        "com.logseq.logseq": .notes, "abnerworks.typora": .notes, "com.ulyssesapp.mac": .notes,
        "com.apple.textedit": .notes, "com.evernote.evernote": .notes, "com.youdao.note.youdaonotemac": .notes,
    ]
    static let parts_: [(DictationAppCategory, Set<String>)] = [
        (.chat, ["wechat", "xinwechat", "feishu", "lark", "dingtalk", "slack", "telegram", "discord", "whatsapp", "signal",
                 "teams", "wework", "messenger"]),
        (.code, ["terminal", "iterm2", "warp", "vscode", "jetbrains", "xcode", "ghostty", "kitty", "alacritty", "zed",
                 "windsurf", "sublimetext", "wezterm"]),
        (.mail, ["mail", "outlook", "mailmaster", "airmail", "spark", "superhuman"]),
        (.notes, ["notes", "obsidian", "notion", "bear", "logseq", "typora", "ulysses", "evernote", "craft"]),
    ]
}

/// record.dictation.styles: what the user chose. Missing = the smart default (light, with the category's variant).
public struct DictationStyleConfig: Equatable {
    public var categories: [DictationAppCategory: DictationStyle] = [:]
    public var apps: [String: DictationStyle] = [:]
    /// apps whose style came from a learned suggestion the user accepted (Settings shows and resets them)
    public var learned: Set<String> = []
    /// the global default (unset = light)
    public var fallback: DictationStyle?

    /// Every default stays light: chat / code / mail / notes only change light's variant (DictationStyleVariant).
    public static let smartDefault = DictationStyle.light

    public init() {}

    public init(json: [String: Any]?) {
        guard let o = json else { return }
        for c in DictationAppCategory.allCases { if let s = (o[c.rawValue] as? String).flatMap(DictationStyle.init) { categories[c] = s } }
        for (b, v) in o["apps"] as? [String: Any] ?? [:] { if let s = (v as? String).flatMap(DictationStyle.init) { apps[b] = s } }
        learned = Set(o["learned"] as? [String] ?? [])
        fallback = (o["default"] as? String).flatMap(DictationStyle.init)
    }

    /// nil when nothing is chosen (the key goes away)
    public var json: [String: Any]? {
        var o: [String: Any] = [:]
        for (c, s) in categories { o[c.rawValue] = s.rawValue }
        if !apps.isEmpty { o["apps"] = apps.mapValues(\.rawValue) }
        let l = learned.filter { apps[$0] != nil }
        if !l.isEmpty { o["learned"] = l.sorted() }
        if let f = fallback { o["default"] = f.rawValue }
        return o.isEmpty ? nil : o
    }

    public func style(for c: DictationAppCategory) -> DictationStyle { categories[c] ?? fallback ?? DictationStyleConfig.smartDefault }
}

public enum DictationStyleSource: String, Hashable {
    /// ⇧ during the take, a click on the island, Fn+⇧ as the start press
    case shift, island, chord
    case app, category
    case `default`
}

/// Rules, not a classifier (§3.4): explicit this take > the app > its category > the global default.
public enum DictationStyleRouter {
    public struct Decision: Equatable {
        public var style: DictationStyle
        public var source: DictationStyleSource
        public var category: DictationAppCategory
        /// what the app / category / default alone would give (⇧ toggles away from it and back)
        public var base: DictationStyle
    }

    public static func decide(explicit: (style: DictationStyle, source: DictationStyleSource)? = nil,
                              config: DictationStyleConfig, bundle: String?) -> Decision {
        let cat = DictationAppCategory.of(bundle: bundle)
        let base: (DictationStyle, DictationStyleSource)
        if let b = bundle, let s = config.apps[b] { base = (s, .app) }
        else if let s = config.categories[cat] { base = (s, .category) }
        else { base = (config.fallback ?? DictationStyleConfig.smartDefault, .default) }
        if let e = explicit { return Decision(style: e.style, source: e.source, category: cat, base: base.0) }
        return Decision(style: base.0, source: base.1, category: cat, base: base.0)
    }

    /// ⇧ / the island: Structured, or back from it to the take's own style (light when that was a list style too).
    public static func toggled(_ current: DictationStyle, base: DictationStyle) -> DictationStyle {
        guard current == .structured else { return .structured }
        return base == .structured || base == .auto ? .light : base
    }
}

/// Category variants of light (§3.1). Deterministic, after polish and the stitch guard, before the fit at the cursor.
public enum DictationStyleVariant {
    /// sentence-final particles chat keeps (polish.py's repair puts back the ones polish dropped: variant "chat")
    public static let chatParticles: Set<Character> = ["吧", "呢", "啊", "哈", "嘛", "呀", "啦", "哦", "噢", "咯", "呗"]

    /// → the text for this category, and what changed ("final_stop", "blank_lines", "one_line").
    public static func apply(_ text: String, category: DictationAppCategory, structured: Bool) -> (text: String, changes: [String]) {
        var t = text
        var changes: [String] = []
        switch category {
        case .chat:
            let squeezed = t.replacingOccurrences(of: #"\n[ \t]*\n[\n \t]*"#, with: "\n", options: .regularExpression)
            if squeezed != t { t = squeezed; changes.append("blank_lines") }
            if !structured, let s = dropFinalStop(t) { t = s; changes.append("final_stop") }
        case .code:
            if !structured, t.contains("\n") {
                t = oneLine(t)
                changes.append("one_line")
            }
        default: break
        }
        return (t, changes)
    }

    /// A one-sentence message without its closing 。 / . (questions and exclamations keep theirs). nil: nothing to do.
    public static func dropFinalStop(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last, last == "。" || last == "." else { return nil }
        if t.hasSuffix("...") || t.hasSuffix("。。") { return nil }
        let body = t.dropLast()
        // another sentence end inside (not a decimal point or an abbreviation's dot between letters)
        let inner = body.enumerated().contains { i, c in
            if "。！？!?\n".contains(c) { return true }
            if c == "." {
                let next = body.index(body.startIndex, offsetBy: i + 1, limitedBy: body.endIndex)
                return next.map { $0 < body.endIndex && body[$0] == " " } ?? false
            }
            return false
        }
        return inner ? nil : String(body)
    }

    /// Line breaks out (terminals, editors, Claude Code: a multi-line paste collapses into "[Pasted N lines]"): a
    /// space between Latin words, nothing between CJK characters.
    public static func oneLine(_ text: String) -> String {
        var out = ""
        for (i, part) in text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }).enumerated() {
            if i > 0, let a = out.last, let b = part.first {
                out += isCJK(a) || isCJK(b) || "，。！？：；、".contains(a) ? "" : " "
            }
            out += part
        }
        return out
    }

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }
}
