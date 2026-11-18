// Where a shot card is being dropped, and what that kind of app gets (v0.8.2–v0.8.4; one rule since v0.8.5).
//
// v0.8.5 — the report: a card (picture + note) dragged into DeepSeek's chat box in a browser arrived as the picture
// and a "-备注.md" file. A web page's composer (DeepSeek, ChatGPT, Claude…) and an Electron one (Claude desktop,
// Feishu, Slack…) treat a drop with files as uploads and ignore the text, which is why the .md existed; but a file
// is not what anyone wants in a chat. The rule now is the one WeChat got in v0.8.4: **the picture, then the text**.
// The drop carries the picture as its only file, and Blurt pastes the note into the same composer right after
// (CardSmartPaste.swift: DragFollowUp, FollowUpFocus). A click-copy's ⌘V does the same (smart paste: picture, then
// note). The .md is an option (record.drag_note_file, off).
// A terminal (and Claude Code / Codex running in it) gets each picture paired with its own words: a drop is
// one line of text, `'<picture path>' <note>`; a ⌘V after a click-copy is one such line per card. With several
// pictures and several notes nothing gets out of order (the .md next to a path left the agent to match them up).
//
//   class      apps                                          drop                              ⌘V after a click-copy
//   rich       Notes, TextEdit, Mail, Pages, Keynote,        one rich item: picture + note     one rich paste (as it
//              Stickies, Messages, Telegram (macOS),         (RTFD) — nothing else             was): picture + note
//              WhatsApp
//   chat       browsers, Electron apps (Claude, Feishu,      the picture alone (its file);     picture, then note (a
//              Slack, Notion…), WeChat, QQ, code editors,    then Blurt pastes the note in     sequence of pastes;
//              and every app no table names                  after it — never in a code        several cards: image,
//                                                            editor (see below); + the .md     note, image, note…)
//                                                            if record.drag_note_file is on.
//                                                            WeChat / QQ: the rich item (v0.9,
//                                                            DragLanding), then the note
//   terminal   Terminal, iTerm2, Ghostty, Warp, kitty,       one line of text: the picture's   one line per card:
//              WezTerm, Alacritty, Hyper, Tabby              path (shell-quoted where needed)  path, then note (smart
//                                                            then the note, its lines joined   paste; else untouched)
//                                                            with spaces — no file, no .md,
//                                                            never a newline
//   finder     the Finder (and the Desktop)                  the picture file (+ the .md if    untouched
//                                                            record.drag_note_file is on)
//
// Why rich apps keep the one rich item: an AppKit text view reads RTFD before anything else, on a drop as on a paste,
// and inserts picture and note at once — no Accessibility, no timing, nothing to go wrong (measured with our
// NSTextView stand-in since v0.8.3). Two steps there would only add a way to fail.
// Why chat gets the picture alone, without the HTML / RTFD / text it used to carry: a composer that took the HTML
// (a plain contenteditable, a Qt view's text) would then get the note twice; with the picture alone every chat
// target ends up the same — the picture, then exactly one note. An app we don't know is a chat app here; the note is
// pasted after the drop only where Accessibility confirms an editable text focus (FollowUpFocus: an image editor
// would turn a paste into a text layer), else it goes to the clipboard like everywhere the follow-up can't run.
//
// Which app: the tables by bundle id. ComposerKind (how the follow-up puts the caret after the picture) is the only
// place the engine matters: WeChat / QQ are Qt (⌘↓: their dropped picture is left selected, and Accessibility can't
// say so); browsers and Electron apps are web content (found by their bundle, Contents/Frameworks/Electron
// Framework.framework, when no table names them): the selection decides; anything else is a native app.
// v0.8.7 — code editors (VS Code and its forks Cursor / Windsurf / VSCodium, Zed, Xcode, JetBrains IDEs, Sublime,
// Nova…) are their own kind, `editor`: a drop that lands on the editor rather than its AI chat panel leaves the
// focus in source code, and "the editable text under the drop point, else the nearest" is the code buffer. So
// Blurt never pastes there by itself: the picture goes in as the drop, the note goes on the clipboard ("⌘V to paste
// the note"), and a voice card gets the editor's own text drop. A ⌘V after a click-copy is the user's own paste and
// still runs the sequence where they put the caret.
// v1.0.21 — agents: desktop apps whose agent works on this Mac's files (the Codex app in Codex mode, Claude Code in
// the Claude app, WorkBuddy, QoderWork, Kimi Code, DoubaoWork, and the AI IDEs: Cursor, Windsurf, Trae, Qoder,
// Antigravity, Kiro) got the chat layout — the picture as an attachment, the note after it — so with several cards
// nothing said which picture went with which words (user report, 1.0.20). They now get a terminal's payload: the
// picture's path, then its note, one line per card; the agent reads the picture from the path. Setting
// record.agent_drag ("paths", the default; "same": as every other app, the Cards box's other choice). A chat that runs
// in the cloud (Kimi, Doubao, ChatGPT mode, a Claude chat) can't read a path and keeps the chat layout; in the Codex
// and Claude apps the window decides (AgentWindow.isAgent: its web page's address, its mode button).
// Which apps (v1.0.26): one list with the agents — every agents.json entry with a `drop` for macOS and its `app`
// bundle ids (AgentDropList, the same rule as agents.py drop_targets and the Windows app's card_drop.rs), the user's
// own agents (record.agent_defs: Settings → Agents → Dragging Cards → Edit… → Add App…), minus the ones switched off
// (record.agent_drop.<id> = false). v1.0.21's record.agent_apps (bundle id → on / off) still counts until the list
// is next edited, which moves it to the new keys (AgentDropList.migrate). Not rules on app names: a name doesn't say
// whether the app reads this Mac's files (Kimi / Kimi Code, 豆包 / 豆包工作 differ by one word).

import CoreGraphics
import Foundation

public enum DropClass: String, CaseIterable {
    case rich, chat, terminal, finder

    /// The names older test scripts used: web / unknown → chat, text → rich.
    public init?(legacy s: String) {
        switch s {
        case "web", "unknown": self = .chat
        case "text": self = .rich
        default: self.init(rawValue: s)
        }
    }
}

/// How the note's paste after a drop finds its place (FollowUpFocus): what kind of composer it is.
public enum ComposerKind: String, CaseIterable {
    /// a browser or an Electron app: web content
    case web
    /// WeChat, QQ (Qt): the dropped picture stays selected; ⌘↓ first
    case qt
    /// an AppKit / UIKit app
    case native
    /// a code editor (VS Code family, Zed, Xcode, JetBrains…): the focus may be source code — no paste of its own
    case editor
}

public enum DropTargets {
    public static let finder: Set<String> = ["com.apple.finder"]

    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "dev.warp.Warp-Preview", "dev.warp.Warp-Beta", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty",
        "io.alacritty", "co.zeit.hyper", "org.tabby",
    ]

    /// Rich text views that take a picture and its text together from one RTFD item.
    public static let richApps: Set<String> = [
        "com.apple.MobileSMS", "com.apple.Notes", "com.apple.TextEdit", "com.apple.mail", "ru.keepcoder.Telegram",
        "net.whatsapp.WhatsApp", "com.apple.iWork.Pages", "com.apple.iWork.Keynote", "com.apple.Stickies",
    ]

    /// Browsers and Electron apps (the bundle check finds other Electron apps): web content, for the caret only.
    public static let webApps: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.operasoftware.OperaGX", "company.thebrowser.Browser",
        "company.thebrowser.dia", "ai.perplexity.comet", "com.openai.atlas", "net.imput.helium",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.kagi.kagimacOS",
        "com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "notion.id", "com.hnc.Discord", "com.electron.lark", "com.bytedance.lark",
        "com.electron.feishu", "com.bytedance.feishu", "com.bytedance.macos.feishu", "com.bytedance.macos.lark",
        "md.obsidian", "com.figma.Desktop", "com.linear",
    ]

    /// Feishu / Lark, every bundle id its builds have used (the installed Lark.app is com.electron.lark). Chromium
    /// based but not Electron ("Lark Framework"), and it answers Accessibility for its web content only when a screen
    /// reader asks (its framework knows AXEnhancedUserInterface, not AXManualAccessibility). v0.9 report: a text drop
    /// on its chat area is taken and nothing goes in (VoiceCardDrop.swallowsTextDrop), and after a picture's drop the
    /// note didn't arrive either (FollowUpFocus.Facts.needsText).
    public static let feishu: Set<String> = [
        "com.electron.lark", "com.bytedance.lark", "com.electron.feishu", "com.bytedance.feishu", "com.bytedance.macos.feishu",
        "com.bytedance.macos.lark",
    ]

    public static func isFeishu(_ bundleID: String?) -> Bool { bundleID.map(feishu.contains) ?? false }

    /// Code editors: their focus after a drop may well be a source file (DragFollowUp never pastes there).
    public static let codeEditors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.vscodium.VSCodiumInsiders",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.apple.dt.Xcode",
        "com.sublimetext.4", "com.sublimetext.3", "com.panic.Nova", "com.google.android.studio", "com.trae.app", "dev.kiro.desktop",
    ]

    /// A code editor: the table, or a JetBrains IDE (IntelliJ, PyCharm, WebStorm, GoLand, Fleet…).
    public static func isCodeEditor(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return codeEditors.contains(id) || id.hasPrefix("com.jetbrains.")
    }

    /// The class of the app `bundleID` — the tables only (no file system: the smart-paste tap asks this too).
    /// `agent`: the window is an agent's and agents get paths (AgentWindow; the caller decides): a terminal's payload.
    public static func classify(bundleID: String?, agent: Bool = false) -> DropClass {
        guard let id = bundleID else { return .chat }
        if agent { return .terminal }
        if finder.contains(id) { return .finder }
        if terminals.contains(id) { return .terminal }
        if richApps.contains(id) { return .rich }
        return .chat
    }

    /// What kind of composer the app `bundleID` (its bundle at `appURL`, for the Electron check) has.
    public static func composer(bundleID: String?, appURL: URL?, fileManager: FileManager = .default) -> ComposerKind {
        if SingleFlavourApps.contains(bundleID) { return .qt }
        if isCodeEditor(bundleID) { return .editor }
        if let id = bundleID, webApps.contains(id) { return .web }
        if let u = appURL, isElectron(u, fileManager: fileManager) { return .web }
        return .native
    }

    /// An Electron app: its bundle carries Electron's framework.
    public static func isElectron(_ appURL: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: appURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }
}

/// A desktop app whose agent works on this Mac's files (v1.0.21): there a card is the picture's path and its note, as
/// in a terminal (record.agent_drag, "paths" by default). Some apps are agents throughout; the Codex and Claude apps
/// only in some windows, decided from what Accessibility shows of the window.
public enum AgentWindow {
    /// the Codex app (shipped as ChatGPT: Codex and chat modes), the Claude app (chats, and Claude Code in its Code tab)
    public static let codex = "com.openai.codex"
    public static let claude = "com.anthropic.claudefordesktop"
    public static let hosts: Set<String> = [codex, claude]
    /// agents in every window: desktop agents (WorkBuddy, QoderWork, Kimi Code, DoubaoWork) and AI IDEs, whose chat
    /// panel's agent reads files (Cursor, Windsurf, Trae, Trae CN, Qoder, Antigravity, Kiro). Not the plain editors
    /// (VS Code, Zed, Xcode, JetBrains: `editor`, as before) and not cloud chats (Kimi, Doubao: chat).
    public static let apps: Set<String> = [
        "com.tencent.workbuddy.mac", "com.qoder.work", "com.kimi.code.desktop", "com.work.pc.doubao",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.trae.app", "cn.trae.app", "com.qoder.ide",
        "com.google.antigravity", "dev.kiro.desktop",
    ]
    public static let builtIn = hosts.union(apps)
    /// agents whose drop lands in their own message box, never a terminal: several cards may go in as several lines
    /// there. The AI IDEs (Cursor, Windsurf…) aren't: a drop may land in their built-in terminal, where a newline runs
    /// the line — they get the terminal's one line.
    public static let composers: Set<String> = hosts.union(["com.tencent.workbuddy.mac", "com.qoder.work", "com.kimi.code.desktop",
                                                            "com.work.pc.doubao"])

    /// The apps a card goes into as path + note: the list (AgentDropList.targets) when agents.json is at hand, else
    /// the built-in fallback with v1.0.21's changes (record.agent_apps).
    public static func list(record: [String: Any], registry: [[String: Any]]?) -> Set<String> {
        guard let reg = registry else { return list(record["agent_apps"] as? [String: Bool] ?? [:]) }
        return Set(AgentDropList.targets(registry: reg, record: record).filter(\.on).flatMap(\.ids))
    }

    /// Of `list(record:registry:)`, the ones with a composer of their own (drop "composer").
    public static func composers(record: [String: Any], registry: [[String: Any]]?) -> Set<String> {
        guard let reg = registry else { return composers }
        return Set(AgentDropList.targets(registry: reg, record: record).filter { $0.on && $0.drop == "composer" }.flatMap(\.ids))
    }

    /// record.agent_drag: "paths" (default, also when unset or unknown) or "same" (as every other app).
    public static func getsPaths(setting: String?) -> Bool { setting != "same" }

    /// The agents' apps with the user's changes (record.agent_apps: bundle id → true: added / kept, false: off).
    public static func list(_ changes: [String: Bool]) -> Set<String> {
        var s = builtIn
        for (id, on) in changes { if on { s.insert(id) } else { s.remove(id) } }
        return s
    }

    /// Of the list, the apps that are agents only in some windows (the rest are agents throughout).
    public static func checksWindow(_ id: String) -> Bool { hosts.contains(id) }

    /// record.agent_apps after switching `id` on or off: a built-in app's own state is no change (nil: left out).
    public static func changing(_ changes: [String: Bool], _ id: String, on: Bool) -> [String: Bool] {
        var c = changes
        c[id] = builtIn.contains(id) == on ? nil : on
        return c
    }

    /// What Accessibility shows of a window: the addresses of its web pages (AXWebArea's AXURL), and the labels of its
    /// pop-up buttons (AXDescription / AXTitle), as far as a short walk from the window goes.
    public struct Facts: Equatable {
        public var urls: [String]
        public var popUps: [String]
        public init(urls: [String] = [], popUps: [String] = []) { self.urls = urls; self.popUps = popUps }
    }

    /// The window is an agent's: in the Claude app, a page of Claude Code (claude.ai/epitaxy/…, its Code tab; a chat
    /// is claude.ai/chat/…); in the Codex app, the mode switch says Codex ("Switch mode, current mode: Codex"; in
    /// chat mode it names ChatGPT). Anything else, or nothing found: not an agent (the chat layout, as before).
    public static func isAgent(bundleID: String?, _ f: Facts) -> Bool {
        switch bundleID {
        case claude?:
            return f.urls.contains { u in
                guard let c = URLComponents(string: u), let h = c.host, h == "claude.ai" || h.hasSuffix(".claude.ai") else { return false }
                return c.path.hasPrefix("/epitaxy") || c.path.hasPrefix("/code")
            }
        case codex?:
            return f.popUps.contains { l in
                let s = l.lowercased().trimmingCharacters(in: .whitespaces)
                return (s.contains("mode") || s.contains("模式")) && s.hasSuffix("codex")
            }
        default: return false
        }
    }
}

/// One app agent a card can be dragged into (agents.json `drop`, or the user's own), as Settings lists it.
public struct DropAgent: Equatable, Identifiable {
    /// the agent's id (agents.json / record.agent_defs), or a bundle id from v1.0.21's record.agent_apps
    public var agent: String
    public var name: String
    /// its macOS bundle ids
    public var ids: [String]
    /// "composer" (one line per card) | "terminal" (one line)
    public var drop: String
    public var on: Bool
    /// the user's own (Remove, not a switch)
    public var custom: Bool
    public var id: String { agent }
    public init(agent: String, name: String, ids: [String], drop: String, on: Bool, custom: Bool) {
        self.agent = agent; self.name = name; self.ids = ids; self.drop = drop; self.on = on; self.custom = custom
    }
}

/// The card-drag targets from agents.json and the config (agents.py drop_targets / migrate_agent_apps, card_drop.rs:
/// one rule on three platforms). Pure: the registry's `agents` array and config.json's `record` object come in.
public enum AgentDropList {
    /// agents.json's agents with record.agent_defs merged in (a known id: its fields over the registry's; a new id:
    /// added after the registry's, in id order) — agents.py definitions().
    public static func definitions(registry: [[String: Any]], record: [String: Any]) -> [[String: Any]] {
        var out = registry
        let defs = record["agent_defs"] as? [String: Any] ?? [:]
        for k in defs.keys.sorted() {
            guard let v = defs[k] as? [String: Any] else { continue }
            if let i = out.firstIndex(where: { $0["id"] as? String == k }) {
                out[i].merge(v) { _, new in new }
                out[i]["id"] = k
            } else {
                var d = v
                d["id"] = k
                if d["name"] == nil { d["name"] = k }
                out.append(d)
            }
        }
        return out
    }

    static func isPath(_ s: String) -> Bool { s.hasPrefix("~") || s.hasPrefix("$") || s.contains("/") || s.contains("\\") }

    /// A def's macOS app ids (bundle ids; paths left out).
    public static func appIDs(_ d: [String: Any]) -> [String] {
        let v = (d["app"] as? [String: Any])?["macos"]
        let all = (v as? [String]) ?? (v as? String).map { [$0] } ?? []
        return all.filter { !isPath($0) }
    }

    /// `drop` for macOS: a string for every OS, or {os: kind}.
    public static func dropKind(_ d: [String: Any]) -> String? {
        let v = (d["drop"] as? [String: Any])?["macos"] ?? d["drop"]
        guard let k = v as? String, k == "composer" || k == "terminal" else { return nil }
        return k
    }

    public static func targets(registry: [[String: Any]], record: [String: Any]) -> [DropAgent] {
        let off = Set((record["agent_drop"] as? [String: Any] ?? [:]).filter { ($0.value as? Bool) == false }.keys)
        let legacy = (record["agent_apps"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
        var out: [DropAgent] = []
        var seen = Set<String>()
        for d in definitions(registry: registry, record: record) {
            guard let id = d["id"] as? String, let kind = dropKind(d) else { continue }
            let ids = appIDs(d)
            guard !ids.isEmpty else { continue }
            let on = !off.contains(id) && !ids.contains { legacy[$0] == false }
            out.append(DropAgent(agent: id, name: d["name"] as? String ?? id, ids: ids, drop: kind, on: on,
                                 custom: d["custom"] as? Bool ?? false))
            seen.formUnion(ids)
        }
        for (k, v) in legacy.sorted(by: { $0.key < $1.key }) where v && !seen.contains(k) {
            out.append(DropAgent(agent: k, name: k, ids: [k], drop: "terminal", on: true, custom: true))
        }
        return out
    }

    /// "My Agent" → "my-agent" (letters and digits of any script kept), unique among `taken` — agents.py custom_id.
    public static func customID(_ name: String, taken: Set<String>) -> String {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        var base = ""
        var dash = false
        for ch in lower {
            if ch.isLetter || ch.isNumber || ch == "_" { base.append(ch); dash = false }
            else if !dash { base.append("-"); dash = true }
        }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if base.isEmpty { base = "agent" }
        var out = base, i = 2
        while taken.contains(out) { out = "\(base)-\(i)"; i += 1 }
        return out
    }

    /// A user's own app (Add App…) as a record.agent_defs entry: a card-drag target only.
    public static func customDef(name: String, bundleID: String) -> [String: Any] {
        ["name": name, "bins": [String](), "headless": false, "custom": true, "connect": false,
         "app": ["macos": [bundleID]], "drop": "terminal"]
    }

    /// record.agent_apps (v1.0.21) → the new keys, as the `record` values to write (NSNull = remove): an app switched
    /// off → its agent in agent_drop = false; an app the user added → a custom agent with that bundle id. nil when
    /// there is nothing to move. agents.py migrate_agent_apps.
    public static func migrate(registry: [[String: Any]], record: [String: Any]) -> [String: Any]? {
        guard let legacy = record["agent_apps"] as? [String: Any] else { return nil }
        let defs = definitions(registry: registry, record: record)
        var byApp: [String: String] = [:]
        for d in defs { if let id = d["id"] as? String { for a in appIDs(d) { byApp[a] = id } } }
        var drop = record["agent_drop"] as? [String: Any] ?? [:]
        var userDefs = record["agent_defs"] as? [String: Any] ?? [:]
        var taken = Set(defs.compactMap { $0["id"] as? String })
        for k in legacy.keys.sorted() {
            guard let v = legacy[k] as? Bool else { continue }
            if !v, let a = byApp[k] { drop[a] = false }
            else if v, byApp[k] == nil {
                let short = k.split(separator: ".").last.map(String.init) ?? k
                let id = customID(short, taken: taken)
                taken.insert(id)
                userDefs[id] = customDef(name: short, bundleID: k)
            }
        }
        var patch: [String: Any] = ["agent_apps": NSNull()]
        if !drop.isEmpty { patch["agent_drop"] = drop }
        if !userDefs.isEmpty { patch["agent_defs"] = userDefs }
        return patch
    }

    /// agents.json's `agents`: the skill's (BlurtPaths.scripts), else the copy in the app. Re-read when the file changes.
    public static func loadRegistry(bundle: Bundle = .main) -> [[String: Any]]? {
        var urls = [BlurtPaths.scripts.appendingPathComponent("agents.json")]
        if let u = bundle.url(forResource: "agents", withExtension: "json") { urls.append(u) }
        lock.lock(); defer { lock.unlock() }
        for u in urls {
            guard let m = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date else { continue }
            if let c = cached, c.url == u, c.at == m { return c.agents }
            guard let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let list = o["agents"] as? [[String: Any]] else { continue }
            cached = (u, m, list)
            return list
        }
        return nil
    }
    private static let lock = NSLock()
    private static var cached: (url: URL, at: Date, agents: [[String: Any]])?
}

/// The app under a drag, as far as what the drag carries goes (CardPasteboard.drag(into:)): its class, its kind of
/// composer, and whether Blurt pastes a voice card's words there itself (then the drag leaves them off).
///  • a shot card into WeChat / QQ (chat, Qt): the rich item, as in v0.8.4 — their composer puts the picture in from
///    it, then Blurt pastes the note. A file alone (the chat layout) is what v0.8.5 gave them, and from then on only
///    the picture arrived (v0.9 report): WeChat 4 is Qt and reads no public.png, so a drag of the picture alone is a
///    bare file URL to it — a file to send, not a picture in the message being typed.
///  • a voice card over a Feishu / Lark window, when Blurt can paste (VoiceCardDrop.withholdsWords): no words on the
///    drag, only the capture's tag. Feishu takes a text drop on its chat area and does nothing with it (v0.9 report),
///    so there Blurt always pastes them itself. Every other app keeps its own text drop.
public struct DragLanding: Equatable {
    public var cls: DropClass
    public var kind: ComposerKind?
    public var wordsWithheld: Bool
    /// an agent's own window (the Claude app's Code tab, the Codex app, Cursor…), not a terminal: several cards may go
    /// in as several lines (its composer is a text box; at a shell prompt a newline would run the line)
    public var lines: Bool

    public init(cls: DropClass, kind: ComposerKind? = nil, wordsWithheld: Bool = false, lines: Bool = false) {
        self.cls = cls; self.kind = kind; self.wordsWithheld = wordsWithheld; self.lines = lines
    }

    /// Where a drag over the app `bundleID` (`kind`: its composer) lands; `voice`: a voice card; `canPaste`: smart paste
    /// is on and Accessibility granted (the follow-up paste can run).
    public static func of(bundleID: String?, kind: ComposerKind, voice: Bool, canPaste: Bool) -> DragLanding {
        let cls = DropTargets.classify(bundleID: bundleID)
        return DragLanding(cls: cls, kind: kind,
                           wordsWithheld: voice && VoiceCardDrop.withholdsWords(bundleID: bundleID, cls: cls, kind: kind,
                                                                                canPaste: canPaste))
    }
}

/// What happens after a shot card was dropped into another app (Snapper.takeOut): what went in, whether the note
/// also goes on the clipboard (the safety net, record.drag_copy_note), and what the island says.
public enum DragReceipt {
    public enum Outcome: String, Equatable {
        /// picture and note: a rich app took both from the rich item, or a chat app got the note pasted after the picture
        case both
        /// the picture went in, the note didn't: a chat app where the follow-up couldn't run (or the app never read
        /// the note), the Finder without the .md
        case pictureOnly = "picture_only"
        /// a terminal: the picture's path and the note, one line of text
        case paths
        /// the Finder with the .md (record.drag_note_file)
        case files
        /// not sure: it landed in another kind of app than the pasteboard was last written for
        case unsure
    }

    /// `delivered`: the class whose payload the app got (nil: not sure); `notePasted`: the follow-up pasted the note
    /// and the app read it; `noteFile`: the .md went with the drag.
    public static func outcome(delivered: DropClass?, notePasted: Bool, noteFile: Bool) -> Outcome {
        switch delivered {
        case .rich?: return .both
        case .chat?: return notePasted ? .both : .pictureOnly
        case .terminal?: return .paths
        case .finder?: return noteFile ? .files : .pictureOnly
        case nil: return .unsure
        }
    }

    /// The follow-up paste of a card's note, by one rule with voice cards and smart paste (VoiceCardDrop.outcome):
    /// keys sent but the read unconfirmed counts as pasted ("picture and note", never "⌘V to paste": a second copy),
    /// and the note goes on the clipboard quietly as the safety net (`quietCopy`).
    public static func followUp(_ p: VoiceCardDrop.Pasted) -> (notePasted: Bool, quietCopy: Bool) {
        (p != .notSent, p == .unconfirmed)
    }

    /// The safety net: the note goes on the clipboard only where it didn't go in (picture only, or not sure). A rich
    /// app, a chat app that got the note pasted, a terminal (path and note went in; ⌘V would paste at a prompt) and
    /// the Finder with the .md leave the clipboard alone.
    public static func copiesNote(_ o: Outcome) -> Bool { o == .pictureOnly || o == .unsure }

    /// The Capture table key. `hasNote`: a shot with a note; `noteCopied`: the safety net put it on the clipboard;
    /// `noteFile`: the .md went too.
    ///  • both: "Dragged out · picture and note" (nothing to paste) · paths: "… picture path and note" (no ⌘V)
    ///  • files: "… picture and note file" (the Finder with the .md)
    ///  • picture only: "… picture · note copied, ⌘V to paste" ("… picture and note file · …" when the .md went too)
    ///  • not sure: "Dragged out · note copied, ⌘V to paste"
    /// `noAccessibility` (BA-54: a card dropped into Claude without Accessibility left the picture alone, and the toast
    /// only said the note was copied): the note wasn't pasted because Accessibility is missing, and the toast says so
    /// (once a session, with Allow…) — "… Note copied, ⌘V to paste" over "Blurt needs Accessibility to paste it".
    public static func toastKey(_ o: Outcome, hasNote: Bool, noteCopied: Bool, noteFile: Bool = false,
                                noAccessibility: Bool = false) -> String {
        guard hasNote else { return "capture.taken_out" }
        if noAccessibility, o == .pictureOnly, !noteFile {
            return noteCopied ? "capture.taken_out_no_ax" : "capture.taken_out_picture_no_ax"
        }
        switch o {
        case .both: return "capture.taken_out_text"
        case .paths: return "capture.taken_out_paths"
        case .files: return "capture.taken_out_files"
        case .pictureOnly:
            if noteFile { return noteCopied ? "capture.taken_out_files_note" : "capture.taken_out_files" }
            return noteCopied ? "capture.taken_out_picture_note" : "capture.taken_out_picture"
        case .unsure: return noteCopied ? "capture.taken_out_note" : "capture.taken_out"
        }
    }

    /// A main window row dragged out (BA-22): the list says something only when there is something to do — its text
    /// is on the clipboard ("Text copied, ⌘V to paste"), or Accessibility is missing (`noAccessibility`, as for a
    /// card). Taken whole (a rich app, the pasted text, a terminal, the Finder): nil — the row stays, nothing to undo.
    public static func itemToastKey(_ o: Outcome, noteCopied: Bool, noAccessibility: Bool = false) -> String? {
        if noAccessibility, o == .pictureOnly { return noteCopied ? "capture.item_out_no_ax" : "capture.item_out_picture_no_ax" }
        return noteCopied ? "capture.item_out_note" : nil
    }
}

/// The composer that received a drop, among the editable text areas of the window it landed on (Accessibility, in
/// screen coordinates): the one under the drop point, else the nearest — a chat page's whole area is often its drop
/// zone, and its one composer is at the bottom.
public enum ComposerPick {
    public static func nearest(_ frames: [CGRect], to p: CGPoint) -> Int? {
        var best: (i: Int, d: CGFloat)?
        for (i, r) in frames.enumerated() where r.width > 1 && r.height > 1 {
            let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
            let d = hypot(dx, dy)
            if best == nil || d < best!.d { best = (i, d) }
        }
        return best?.i
    }
}

/// The window a drag is over (CardDrag's DropProbe): the frontmost one under the point in CGWindowList's z-order that
/// can take a drop. v1.0.23 — user report: cards dragged into Claude Code / Codex lost their note (the picture alone).
/// On macOS 26.5 Notification Center keeps a full-screen, fully transparent window (layer 21, alpha 1) above every
/// app, and the probe took it for the app under the pointer: every drop was "Notification Center", a chat app with no
/// composer, so agents never got path + note and chat apps never got the note pasted. Windows at or above the Dock's
/// level + 1 (Notification Center, the menu bar and its items, the drag image, the cursor) are never drop targets,
/// and neither are the system's overlay processes at any level.
public enum DropWindows {
    public struct Window: Equatable {
        public var pid: Int
        public var bundleID: String?
        public var ownerName: String?
        public var layer: Int
        public var alpha: Double
        /// in CG coordinates (top-left origin)
        public var bounds: CGRect
        /// one of ours that takes the pointer (not the cards' panel during a drag)
        public var oursTakesMouse: Bool
        public init(pid: Int, bundleID: String? = nil, ownerName: String? = nil, layer: Int = 0, alpha: Double = 1,
                    bounds: CGRect, oursTakesMouse: Bool = true) {
            self.pid = pid; self.bundleID = bundleID; self.ownerName = ownerName; self.layer = layer; self.alpha = alpha
            self.bounds = bounds; self.oursTakesMouse = oursTakesMouse
        }
    }

    public enum Pick: Equatable {
        /// another app's window
        case app(Int)
        /// one of Blurt's own windows (the main window, the island, a note): an in-app drop
        case ours
        case nothing
    }

    /// above the Dock (kCGDockWindowLevel = 20): Notification Center (21), the menu bar (24/25), pop-up menus, the drag
    public static let maxLayer = 20
    /// processes whose windows float over the apps without ever taking a drop
    public static let overlays: Set<String> = [
        "com.apple.notificationcenterui", "com.apple.controlcenter", "com.apple.WindowManager", "com.apple.Spotlight",
        "com.apple.screencaptureui", "com.apple.TextInputMenuAgent", "com.apple.TextInputUI.xpc.CursorUIViewService",
    ]

    /// `windows` front to back (CGWindowList order), `q` in CG coordinates, `me` Blurt's pid.
    public static func pick(_ windows: [Window], at q: CGPoint, me: Int) -> Pick {
        for w in windows {
            guard w.alpha > 0.01, w.ownerName != "Window Server", w.bounds.contains(q) else { continue }
            if w.pid == me {
                // ours at any level below the drag image (the island sits over the menu bar)
                guard w.layer < 500 else { continue }
                if w.oursTakesMouse { return .ours }
                continue            // the cards' panel during a drag: the drop goes to what is under it
            }
            guard w.layer <= maxLayer else { continue }
            if let id = w.bundleID, overlays.contains(id) { continue }
            return .app(w.pid)
        }
        return .nothing
    }
}
