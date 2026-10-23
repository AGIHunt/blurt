// Where a shot card is being dropped, and what that kind of app handles best (v0.8.2).
//
// The report: a card dropped into WeChat arrived as the picture *plus a Markdown file attachment* (the note, and an
// image line pointing at the picture). WeChat — like Notes, Messages, TextEdit, any AppKit text view — takes a picture
// and text together; the .md was there only for web apps. Those (Chromium / Electron: the Claude desktop app, Chrome,
// Slack, VS Code…) attach the files and ignore loose text when there are files, so for them the note has to be a file.
// One payload can't suit both, so the app under the pointer picks it (HangingCards / CardDrag.swift):
//
//   class      apps                                                  item 1 (picture)          item 2 (note)
//   web        Claude desktop, Chrome & Chromium browsers, Safari,   file + PNG                .md file + text
//              Firefox, Slack, VS Code, Cursor, Notion, Discord,
//              Feishu / Lark, Obsidian, Figma… any Electron app
//   text       WeChat, QQ, Messages, Notes, TextEdit, Mail,          file + PNG + RTFD(picture) text only — no .md
//              Telegram, WhatsApp, Pages, Keynote, Stickies
//   terminal   Terminal, iTerm2, Ghostty, Warp, kitty, WezTerm,      file                      .md file — no text
//              Alacritty, Hyper, Tabby
//   finder     the Finder (and the Desktop)                          file + PNG                .md file
//   unknown    anything else                                         file + PNG                .md file + text
//
// Why these, measured with our own stand-ins (an NSTextView, a WKWebView page, a pad that logs what it gets):
//  • a rich NSTextView prefers RTFD > RTF > HTML > file names, and plain text only after those: given [picture file,
//    text] it inserts the picture and drops the text; given [picture file, .md file] it inserts two attachments (the
//    WeChat report). With an RTFD of the picture on item 1 and the note as text on item 2 it inserts both. A plain text
//    view takes the text.
//  • a web page (WebKit here; Chromium measured in v0.8.1) attaches the files and gets "" for the text.
//  • a terminal types the file paths it gets; with no text on the pasteboard it can never type the note.
//  • unknown: the web layout reaches the note in every stand-in (a file where files win, the text where text wins);
//    the text layout loses it in a web app. So an app we don't know gets the files — at worst an extra .md.
// Which app: Electron apps are found by their bundle (Contents/Frameworks/Electron Framework.framework) when no table
// names them; the tables win (QQ is in the text row by request even though recent builds ship Electron).

import Foundation

public enum DropClass: String, CaseIterable {
    case web, text, terminal, finder, unknown
}

public enum DropTargets {
    public static let finder: Set<String> = ["com.apple.finder"]

    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "dev.warp.Warp-Preview", "dev.warp.Warp-Beta", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty",
        "io.alacritty", "co.zeit.hyper", "org.tabby",
    ]

    /// Apps whose drop target takes a picture and text together (AppKit / UIKit text views, chat composers).
    public static let textApps: Set<String> = [
        "com.tencent.xinWeChat", "com.tencent.qq", "com.apple.MobileSMS", "com.apple.Notes", "com.apple.TextEdit",
        "com.apple.mail", "ru.keepcoder.Telegram", "org.telegram.desktop", "net.whatsapp.WhatsApp",
        "com.apple.iWork.Pages", "com.apple.iWork.Keynote", "com.apple.Stickies",
    ]

    /// Web engines and Electron apps that keep the files and drop loose text (the bundle check finds other Electron apps).
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
        "com.electron.feishu", "com.bytedance.feishu", "md.obsidian", "com.figma.Desktop", "com.linear",
    ]

    /// The class of the app `bundleID` (its bundle at `appURL`, for the Electron check).
    public static func classify(bundleID: String?, appURL: URL?, fileManager: FileManager = .default) -> DropClass {
        if let id = bundleID {
            if finder.contains(id) { return .finder }
            if terminals.contains(id) { return .terminal }
            if textApps.contains(id) { return .text }
            if webApps.contains(id) { return .web }
        }
        if let u = appURL, isElectron(u, fileManager: fileManager) { return .web }
        return .unknown
    }

    /// An Electron app: its bundle carries Electron's framework.
    public static func isElectron(_ appURL: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: appURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }
}

/// What the island says after a shot card was dropped into another app (Snapper.takeOut).
public enum DragReceipt {
    /// The Capture table key. `delivered`: the class whose payload the app got (nil: not sure — the drop landed in a
    /// different kind of app than the one the pasteboard was last written for); `hasNote`: a shot with a note;
    /// `noteCopied`: the safety net put the note on the clipboard (record.drag_copy_note).
    ///  • text: the picture and the words went in — no "⌘V to paste" (the clipboard still has the note, quietly);
    ///  • terminal: both paths went in — no ⌘V either (that would paste the note at a shell prompt);
    ///  • web / finder / unknown: the picture and the note's file — ⌘V pastes the note if the app kept only the picture;
    ///  • not sure: "note copied, ⌘V to paste", as before.
    public static func toastKey(delivered: DropClass?, hasNote: Bool, noteCopied: Bool) -> String {
        guard hasNote else { return "capture.taken_out" }
        switch delivered {
        case .text?: return "capture.taken_out_text"
        case .terminal?: return "capture.taken_out_paths"
        case .web?, .finder?, .unknown?: return noteCopied ? "capture.taken_out_files_note" : "capture.taken_out_files"
        case nil: return noteCopied ? "capture.taken_out_note" : "capture.taken_out"
        }
    }
}
