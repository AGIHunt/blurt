// Where a shot card is being dropped, and what that kind of app needs besides the rich item (v0.8.2, v0.8.3).
//
// v0.8.3: a card's first item is the same rich item everywhere but a terminal — its picture's file and bytes, the
// picture and note as HTML and RTFD, the note as one line of text (CardPasteboard) — the way a WeChat or Notes copy of a
// picture-and-text message carries both. What still depends on the app is the second item, and that is why the app
// under the pointer still picks the payload (HangingCards / CardDrag.swift):
//
//   class      apps                                                  item 1                    item 2
//   web        Claude desktop, Chrome & Chromium browsers, Safari,   rich (file, PNG, HTML,    the note's .md file
//              Firefox, Slack, VS Code, Cursor, Notion, Discord,     RTFD, RTF, text)
//              Feishu / Lark, Obsidian, Figma… any Electron app
//   text       WeChat, QQ, Messages, Notes, TextEdit, Mail,          rich                      — (an inert item)
//              Telegram, WhatsApp, Pages, Keynote, Stickies
//   terminal   Terminal, iTerm2, Ghostty, Warp, kitty, WezTerm,      the picture's file only   the .md file
//              Alacritty, Hyper, Tabby
//   finder     the Finder (and the Desktop)                          rich                      the .md file
//   unknown    anything else                                         rich                      the .md file
//
// Why, measured with our own stand-ins (a rich NSTextView, a WKWebView contenteditable, pads that log what they get):
//  • a rich NSTextView reads RTFD before anything else (then RTF, HTML, file names, plain text), on a drop as on a
//    paste: from the rich item it inserts the picture and the note, and it adds a later item's text (the note twice)
//    but not a later item's file. The v0.8.2 report — a picture plus a .md attachment in WeChat — came from a payload
//    without RTFD, so a text app still never gets the .md.
//  • WeChat and QQ (v0.8.4, SingleFlavourApps in CardSmartPaste.swift) stay in the text row for the drag itself, but
//    their composer takes one thing per drop — the picture (WeChat 4 is Qt: no RTFD, and HTML loses to the image) —
//    so the app types the note in after the drop, and DragReceipt counts the drop as "picture only" when it couldn't.
//  • a web app attaches the files and drops the text and the HTML when there are files (WebKit here; Chromium measured
//    in v0.8.1): for the note to arrive it has to be a file, the .md.
//  • a terminal types the file paths it gets; with no text on the pasteboard it can never type the note.
//  • unknown: the rich item and the .md reach the note in every stand-in (RTFD where a text view reads, the .md where
//    files win). At worst an extra .md.
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

/// What happens after a shot card was dropped into another app (Snapper.takeOut): whether the note also goes on the
/// clipboard, and what the island says.
public enum DragReceipt {
    /// The safety net (record.drag_copy_note): the note goes on the clipboard only where the app may have kept just the
    /// picture — a web app, the Finder, an app we don't know, or a drop we aren't sure about (it landed in a different
    /// kind of app than the pasteboard was last written for). A text app took the picture and the note from the rich
    /// item, a terminal both paths: the clipboard is left alone (v0.8.3; it used to be overwritten quietly).
    /// `pictureOnly`: it landed in a single-flavour app (WeChat, QQ: SingleFlavourApps) and the note wasn't typed in
    /// after the picture (DragFollowUp: off, no Accessibility, or it couldn't) — the picture alone went in.
    public static func copiesNote(delivered: DropClass?, pictureOnly: Bool = false) -> Bool {
        if pictureOnly { return true }
        switch delivered {
        case .text?, .terminal?: return false
        case .web?, .finder?, .unknown?, nil: return true
        }
    }

    /// The Capture table key. `delivered`: the class whose payload the app got (nil: not sure); `hasNote`: a shot with
    /// a note; `noteCopied`: the safety net put the note on the clipboard.
    ///  • text: the picture and the note went in — nothing to paste;
    ///  • terminal: both paths went in — no ⌘V either (that would paste the note at a shell prompt);
    ///  • web / finder: the picture and the note's file — ⌘V pastes the note if the app kept only the picture;
    ///  • an app we don't know (it may have read the rich item, or the files) or not sure: "note copied, ⌘V to paste".
    ///  • a single-flavour app (WeChat, QQ): the note typed in after the picture → "picture and note"; not typed in →
    ///    "picture" (and "note copied, ⌘V to paste" when the safety net copied it).
    public static func toastKey(delivered: DropClass?, hasNote: Bool, noteCopied: Bool, pictureOnly: Bool = false) -> String {
        guard hasNote else { return "capture.taken_out" }
        if pictureOnly { return noteCopied ? "capture.taken_out_picture_note" : "capture.taken_out_picture" }
        switch delivered {
        case .text?: return "capture.taken_out_text"
        case .terminal?: return "capture.taken_out_paths"
        case .web?, .finder?: return noteCopied ? "capture.taken_out_files_note" : "capture.taken_out_files"
        case .unknown?, nil: return noteCopied ? "capture.taken_out_note" : "capture.taken_out"
        }
    }
}
