//! What a card dragged out of the island carries, the parts that don't need Windows (card_drag_win.rs does the OLE
//! drag): where its files live, which kind of window it lands on, and the one line a terminal gets.
//!
//!  • files: the captioned copy and the note's .md go next to the session, `<session>/out/<NNN>/` (the Mac's
//!    CardExport layout), not to %TEMP%: an agent in a terminal may read the picture long after the drop, and
//!    housekeeping trashes that folder with the card when its 7 days in History are over.
//!  • a terminal that takes a text drop (Windows Terminal — where cmd, PowerShell, WSL, Claude Code and Codex run on
//!    Windows 11 — and mintty: Git Bash, MSYS2, Cygwin) gets one line of text, `"<picture path>" <note>`: the
//!    picture's absolute path in double quotes, then the note with its line breaks flattened to spaces and every
//!    control character out — so each picture stays next to its own words and a drop at a prompt never runs anything.
//!    Not a file drop: the terminal would type the path and the note would arrive apart from it, on the clipboard.
//!  • a terminal that takes only file drops keeps the file drop (the terminal types the path) and the note goes on
//!    the clipboard, as for any app that can't take both: a text-only drag would be refused there and the card would
//!    fly back. The classic console window (conhost: ConsoleWindowClass, WM_DROPFILES), Alacritty (winit takes
//!    files only), and until one is seen taking text, WezTerm, Hyper, Tabby, Warp, ConEmu and the rest of the
//!    dictation table of terminals.
//!
//! Pure: tests below.
#![cfg_attr(not(windows), allow(dead_code))]

use std::path::{Path, PathBuf};

/// The kind of window a card is dropped on, as far as what the drag carries goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    /// a terminal that takes a text drop: the picture's path and the note, one line of text
    Terminal,
    /// a terminal that takes only file drops (the classic console, Alacritty…): the picture as a file, as Other
    FilesOnly,
    /// everything else: the picture as a file (Explorer, chat apps, editors)
    Other,
}

/// Terminals whose window takes a text drop (executable stems): Windows Terminal (its drop handler pastes text),
/// mintty.
const TEXT_DROP: &[&str] = &["windowsterminal", "mintty"];

/// The window class of the classic console (conhost.exe draws it for cmd, PowerShell, any console program; its
/// owner pid is the program's, not conhost's).
pub const CONSOLE_CLASS: &str = "ConsoleWindowClass";

/// Which kind of window: by the top-level window's class (the classic console), then its process's executable
/// (TEXT_DROP; the dictation table of terminals for the rest: wezterm-gui.exe, alacritty.exe, Hyper.exe, Tabby.exe,
/// Warp.exe…).
pub fn target(exe: Option<&str>, class: Option<&str>) -> Target {
    if class == Some(CONSOLE_CLASS) {
        return Target::FilesOnly;
    }
    if exe.map(crate::dictation::apps::stem).is_some_and(|s| TEXT_DROP.contains(&s.as_str())) {
        return Target::Terminal;
    }
    if crate::dictation::apps::is_terminal(exe) {
        return Target::FilesOnly;
    }
    Target::Other
}

/// The note on one line: control characters (line breaks, tabs, escapes, C1, U+2028 / U+2029) split it, each piece
/// trimmed, empty ones dropped, joined with spaces.
pub fn one_line(note: &str) -> String {
    note.split(|c: char| c.is_control() || c == '\u{2028}' || c == '\u{2029}')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// A Windows path as one argument: in double quotes (a path can't hold one; any control character is left out).
pub fn quoted(path: &Path) -> String {
    let p: String = path.to_string_lossy().chars().filter(|c| !c.is_control() && *c != '"').collect();
    format!("\"{p}\"")
}

/// What a terminal gets for a card: `"<picture path>" <note>` — the note on the same line; no note: the path alone.
pub fn terminal_line(picture: &Path, note: Option<&str>) -> String {
    let words = note.map(one_line).unwrap_or_default();
    if words.is_empty() {
        quoted(picture)
    } else {
        format!("{} {words}", quoted(picture))
    }
}

/// Where card `n`'s files for other apps live: `<session>/out/<NNN>/` (housekeeping trashes it with the card).
pub fn out_dir(session: &Path, n: u32) -> PathBuf {
    session.join("out").join(format!("{n:03}"))
}

/// "截图-153012" / "Screenshot-153012": the prefix in the UI language, then the time on `hms` ("HHMMSS").
pub fn stem(zh: bool, hms: &str) -> String {
    format!("{}-{hms}", if zh { "截图" } else { "Screenshot" })
}

/// The .md's name next to the picture: "截图-153012-备注.md" / "Screenshot-153012-note.md".
pub fn note_name(zh: bool, hms: &str) -> String {
    format!("{}-{}.md", stem(zh, hms), if zh { "备注" } else { "note" })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_terminal_by_its_executable_the_console_by_its_class() {
        for exe in ["WindowsTerminal.exe", "mintty.exe"] {
            assert_eq!(target(Some(exe), Some("CASCADIA_HOSTING_WINDOW_CLASS")), Target::Terminal, "{exe}");
            assert_eq!(target(Some(&format!(r"C:\Program Files\X\{exe}")), None), Target::Terminal, "{exe}");
        }
        // terminals that take only files: a text-only drag would be refused there
        for exe in ["alacritty.exe", "wezterm-gui.exe", "Hyper.exe", "Tabby.exe", "Warp.exe", "ConEmu64.exe", "OpenConsole.exe"] {
            assert_eq!(target(Some(exe), Some("Window Class")), Target::FilesOnly, "{exe}");
        }
        // the classic console: its window's pid is the console program's (cmd, PowerShell, claude.exe…)
        for exe in ["cmd.exe", "powershell.exe", "pwsh.exe", "conhost.exe", "claude.exe", "node.exe", "WindowsTerminal.exe"] {
            assert_eq!(target(Some(exe), Some(CONSOLE_CLASS)), Target::FilesOnly, "{exe}");
        }
        for exe in ["explorer.exe", "chrome.exe", "WeChat.exe", "Code.exe", "notepad.exe"] {
            assert_eq!(target(Some(exe), Some("Chrome_WidgetWin_1")), Target::Other, "{exe}");
        }
        assert_eq!(target(None, None), Target::Other);
    }

    #[test]
    fn the_path_is_quoted_and_the_note_follows_on_one_line() {
        let p = Path::new(r"C:\Users\Ana Li\.blurt\sessions\2026-11-12\out\003\截图-144012.png");
        assert_eq!(
            terminal_line(p, Some("结账按钮被挡住了\r\nthe banner covers it\n\n  see the logo ")),
            "\"C:\\Users\\Ana Li\\.blurt\\sessions\\2026-11-12\\out\\003\\截图-144012.png\" 结账按钮被挡住了 the banner covers it see the logo"
        );
        assert_eq!(terminal_line(p, None), format!("\"{}\"", p.display()));
        assert_eq!(terminal_line(p, Some(" \n ")), format!("\"{}\"", p.display()));
    }

    #[test]
    fn nothing_in_the_line_runs_at_a_prompt() {
        let line = terminal_line(Path::new(r"C:\a\b.png"), Some("dir\r\n\u{1b}[201~del /q *\u{7}\u{2028}x\ty\u{9b}z"));
        assert!(!line.chars().any(|c| c.is_control() || c == '\u{2028}'), "{line:?}");
        assert_eq!(line, "\"C:\\a\\b.png\" dir [201~del /q * x y z");
        // a quote or a control character can't get into the path's quotes
        assert_eq!(quoted(Path::new("C:\\a\"b\nc.png")), "\"C:\\abc.png\"");
    }

    #[test]
    fn files_live_next_to_the_session() {
        assert_eq!(out_dir(Path::new("/h/.blurt/sessions/s1"), 3), Path::new("/h/.blurt/sessions/s1/out/003"));
        assert_eq!(out_dir(Path::new("/s"), 1234), Path::new("/s/out/1234"));
        assert_eq!(stem(true, "153012"), "截图-153012");
        assert_eq!(note_name(false, "153012"), "Screenshot-153012-note.md");
        assert_eq!(note_name(true, "153012"), "截图-153012-备注.md");
    }

    #[test]
    fn one_line_matches_the_voice_card_drop() {
        assert_eq!(one_line("call Ana\nabout pricing"), "call Ana about pricing");
        assert_eq!(one_line(" \n\u{1b}\n "), "");
    }
}
