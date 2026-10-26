// Where a shot card is being dropped, and what that kind of app gets (v0.8.2–v0.8.4; one rule since v0.8.5).
//
// v0.8.5 — the report: a card (picture + note) dragged into DeepSeek's chat box in a browser arrived as the picture
// and a "-备注.md" file. A web page's composer (DeepSeek, ChatGPT, Claude…) and an Electron one (Claude desktop,
// Feishu, Slack…) treat a drop with files as uploads and ignore the text, which is why the .md existed; but a file
// is not what anyone wants in a chat. The rule now is the one WeChat got in v0.8.4: **the picture, then the text**.
// The drop carries the picture as its only file, and Blurt pastes the note into the same composer right after
// (CardSmartPaste.swift: DragFollowUp, FollowUpFocus). A click-copy's ⌘V does the same (smart paste: picture, then
// note). The .md is an option (record.drag_note_file, off) — and still what a terminal gets.
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
//   terminal   Terminal, iTerm2, Ghostty, Warp, kitty,       the picture's path and the        untouched
//              WezTerm, Alacritty, Hyper, Tabby              .md's path (Claude Code / Codex
//                                                            read it) — never the note's text
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
    public static func classify(bundleID: String?) -> DropClass {
        guard let id = bundleID else { return .chat }
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

    public init(cls: DropClass, kind: ComposerKind? = nil, wordsWithheld: Bool = false) {
        self.cls = cls; self.kind = kind; self.wordsWithheld = wordsWithheld
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
        /// a terminal: both paths
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

    /// The safety net: the note goes on the clipboard only where it didn't go in (picture only, or not sure). A rich
    /// app, a chat app that got the note pasted, a terminal (both paths; ⌘V would paste at a prompt) and the Finder
    /// with the .md leave the clipboard alone.
    public static func copiesNote(_ o: Outcome) -> Bool { o == .pictureOnly || o == .unsure }

    /// The Capture table key. `hasNote`: a shot with a note; `noteCopied`: the safety net put it on the clipboard;
    /// `noteFile`: the .md went too.
    ///  • both: "Dragged out · picture and note" (nothing to paste) · paths: "… picture and note paths" (no ⌘V)
    ///  • files: "… picture and note file" (the Finder with the .md)
    ///  • picture only: "… picture · note copied, ⌘V to paste" ("… picture and note file · …" when the .md went too)
    ///  • not sure: "Dragged out · note copied, ⌘V to paste"
    public static func toastKey(_ o: Outcome, hasNote: Bool, noteCopied: Bool, noteFile: Bool = false) -> String {
        guard hasNote else { return "capture.taken_out" }
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
