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
//!  • an agent app — a desktop agent or an AI IDE whose agent reads files on this PC (AGENTS: Codex, WorkBuddy,
//!    QoderWork, Cursor, Trae…, plus the programs the user added in Settings → General → Cards → Agents…) — gets
//!    the same line as a text-drop terminal while record.agent_drag is "paths" (the default; the Mac's choice):
//!    with several cards dropped in a row, each picture's path stays next to its own note (as files, Codex and
//!    Claude Code lost which note went with which picture). "same": an agent gets what any other app gets.
//!    An explicit list, not names matched by a rule: a name doesn't say whether the app reads local files (Kimi vs
//!    Kimi Code, Doubao vs DoubaoWork). record.agent_apps keeps only the user's changes to the built-in list,
//!    `{stem: true}` added, `{stem: false}` a built-in switched off (`changing`).
//!
//! Pure: tests below.
#![cfg_attr(not(windows), allow(dead_code))]

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

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

/// Desktop agents and AI IDEs whose agent reads files on this PC (executable stems): a card dragged into one is the
/// picture's path and its note, as in a terminal. WorkBuddy, QoderWork, Qoder, Kimi Code, DoubaoWork (豆包工作),
/// Cursor, Windsurf, Trae, Trae CN, Antigravity, Kiro, Codex. Not Claude (claude.exe is the desktop app's cloud chat
/// and its Code tab in one window, which can't be told apart here), ChatGPT, Kimi or Doubao (cloud chats: the
/// picture has to travel as a file). The exact Windows executable names are guesses from the Mac's app names, not
/// yet seen on a PC: the user's own list (Agents… → Add Program…) is the way out when one is wrong.
pub const AGENTS: &[&str] =
    &["workbuddy", "qoderwork", "qoder", "kimi code", "doubaowork", "cursor", "windsurf", "trae", "trae cn", "antigravity", "kiro", "codex"];

/// The agent apps in effect (executable stems).
pub type Agents = BTreeSet<String>;

/// The agent apps a card goes into as path + note, from the config's `record` object: none when record.agent_drag
/// is "same"; else (paths: the default, also unset or unknown) the built-in list with the user's additions
/// (record.agent_apps `true`) and without the built-ins switched off (`false`).
pub fn agents(record: Option<&Value>) -> Agents {
    if record.and_then(|r| r.get("agent_drag")).and_then(Value::as_str) == Some("same") {
        return Agents::new();
    }
    let changes = record.and_then(|r| r.get("agent_apps")).and_then(Value::as_object);
    let said = |id: &str| changes.and_then(|c| c.get(id)).and_then(Value::as_bool);
    let mut out: Agents = AGENTS.iter().filter(|id| said(id) != Some(false)).map(|id| id.to_string()).collect();
    out.extend(changes.into_iter().flatten().filter(|(_, v)| v.as_bool() == Some(true)).map(|(k, _)| k.to_lowercase()));
    out
}

/// record.agent_apps after the user switches `id` on or off (Settings' Agents… sheet): only changes to the built-in
/// list are kept — a built-in switched off is `false`, back on its key goes; a program added is `true`, removed its
/// key goes.
pub fn changing(changes: &Map<String, Value>, id: &str, on: bool) -> Map<String, Value> {
    let id = id.trim().to_lowercase();
    let mut out = changes.clone();
    if id.is_empty() {
        return out;
    }
    match (AGENTS.contains(&id.as_str()), on) {
        (true, true) | (false, false) => out.remove(&id),
        (true, false) => out.insert(id, Value::Bool(false)),
        (false, true) => out.insert(id, Value::Bool(true)),
    };
    out
}

/// The Agents… sheet's rows: every built-in (on unless switched off), then the programs the user added, by name.
pub fn listing(changes: Option<&Map<String, Value>>) -> Vec<(String, bool, bool)> {
    let said = |id: &str| changes.and_then(|c| c.get(id)).and_then(Value::as_bool);
    let mut rows: Vec<(String, bool, bool)> = AGENTS.iter().map(|id| (id.to_string(), true, said(id) != Some(false))).collect();
    let added: BTreeSet<String> = changes
        .into_iter()
        .flatten()
        .filter(|(k, v)| v.as_bool() == Some(true) && !AGENTS.contains(&k.to_lowercase().as_str()))
        .map(|(k, _)| k.to_lowercase())
        .collect();
    rows.extend(added.into_iter().map(|id| (id, false, true)));
    rows
}

/// A program the user picked in Add Program… as its id: the executable's stem ("Cursor.exe" → "cursor"); a
/// shortcut the dialog didn't follow, by its own name ("Trae CN.lnk" → "trae cn"). Anything else: None.
pub fn program_id(path: &Path) -> Option<String> {
    let path = path.to_string_lossy();
    let name = path.rsplit(['\\', '/']).next()?.to_lowercase();
    let id = name.strip_suffix(".exe").or_else(|| name.strip_suffix(".lnk"))?.trim();
    (!id.is_empty()).then(|| id.to_string())
}

/// Which kind of window: by the top-level window's class (the classic console), then its process's executable
/// (TEXT_DROP; `agents`, the agent apps in effect; the dictation table of terminals for the rest: wezterm-gui.exe,
/// alacritty.exe, Hyper.exe, Tabby.exe, Warp.exe…).
pub fn target(exe: Option<&str>, class: Option<&str>, agents: &Agents) -> Target {
    if class == Some(CONSOLE_CLASS) {
        return Target::FilesOnly;
    }
    let stem = exe.map(crate::dictation::apps::stem);
    if stem.as_deref().is_some_and(|s| TEXT_DROP.contains(&s) || agents.contains(s)) {
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
    use serde_json::json;

    #[test]
    fn a_terminal_by_its_executable_the_console_by_its_class() {
        let none = Agents::new();
        for exe in ["WindowsTerminal.exe", "mintty.exe"] {
            assert_eq!(target(Some(exe), Some("CASCADIA_HOSTING_WINDOW_CLASS"), &none), Target::Terminal, "{exe}");
            assert_eq!(target(Some(&format!(r"C:\Program Files\X\{exe}")), None, &none), Target::Terminal, "{exe}");
        }
        // terminals that take only files: a text-only drag would be refused there
        for exe in ["alacritty.exe", "wezterm-gui.exe", "Hyper.exe", "Tabby.exe", "Warp.exe", "ConEmu64.exe", "OpenConsole.exe"] {
            assert_eq!(target(Some(exe), Some("Window Class"), &none), Target::FilesOnly, "{exe}");
        }
        // the classic console: its window's pid is the console program's (cmd, PowerShell, claude.exe…)
        for exe in ["cmd.exe", "powershell.exe", "pwsh.exe", "conhost.exe", "claude.exe", "node.exe", "WindowsTerminal.exe"] {
            assert_eq!(target(Some(exe), Some(CONSOLE_CLASS), &none), Target::FilesOnly, "{exe}");
        }
        for exe in ["explorer.exe", "chrome.exe", "WeChat.exe", "Code.exe", "notepad.exe"] {
            assert_eq!(target(Some(exe), Some("Chrome_WidgetWin_1"), &none), Target::Other, "{exe}");
        }
        assert_eq!(target(None, None, &none), Target::Other);
    }

    fn record(v: Value) -> Option<Value> {
        Some(v)
    }

    #[test]
    fn an_agent_app_gets_the_terminal_line() {
        let built_in = agents(None);
        assert_eq!(built_in.len(), AGENTS.len());
        for exe in [r"C:\Users\a\AppData\Local\Programs\cursor\Cursor.exe", "Codex.exe", "WorkBuddy.exe", "Kimi Code.exe", "Trae CN.exe", "kiro.exe"] {
            assert_eq!(target(Some(exe), Some("Chrome_WidgetWin_1"), &built_in), Target::Terminal, "{exe}");
        }
        // cloud chats and the Claude desktop app (its chat and its Code tab are one window) get the picture
        for exe in ["claude.exe", "ChatGPT.exe", "Kimi.exe", "Doubao.exe", "Code.exe", "chrome.exe", "explorer.exe"] {
            assert_eq!(target(Some(exe), Some("Chrome_WidgetWin_1"), &built_in), Target::Other, "{exe}");
        }
        // the classic console is FilesOnly whatever its program, an agent's too
        for exe in ["codex.exe", "cursor.exe", "claude.exe"] {
            assert_eq!(target(Some(exe), Some(CONSOLE_CLASS), &built_in), Target::FilesOnly, "{exe}");
        }
        // a terminal that takes only files stays that way
        assert_eq!(target(Some("alacritty.exe"), Some("Window Class"), &built_in), Target::FilesOnly);
    }

    #[test]
    fn the_user_adds_and_switches_off_agents() {
        let r = record(json!({"agent_apps": {"cursor": false, "Zed": true, "myagent": true, "trae": true, "odd": "yes"}}));
        let a = agents(r.as_ref());
        assert!(!a.contains("cursor") && a.contains("zed") && a.contains("myagent") && a.contains("trae") && !a.contains("odd"));
        assert_eq!(target(Some("Cursor.exe"), None, &a), Target::Other);
        assert_eq!(target(Some("zed.exe"), None, &a), Target::Terminal);
        // "paths" and anything unknown: the list; "same": none at all
        assert_eq!(agents(record(json!({"agent_drag": "paths"})).as_ref()).len(), AGENTS.len());
        assert_eq!(agents(record(json!({"agent_drag": 3})).as_ref()).len(), AGENTS.len());
        let same = agents(record(json!({"agent_drag": "same", "agent_apps": {"zed": true}})).as_ref());
        assert!(same.is_empty());
        assert_eq!(target(Some("Codex.exe"), None, &same), Target::Other);
        assert_eq!(target(Some("WindowsTerminal.exe"), None, &same), Target::Terminal);
    }

    #[test]
    fn only_changes_to_the_built_in_list_are_kept() {
        let empty = Map::new();
        let off = changing(&empty, "cursor", false);
        assert_eq!(Value::Object(off.clone()), json!({"cursor": false}));
        assert!(changing(&off, "Cursor", true).is_empty());
        assert!(changing(&empty, "cursor", true).is_empty());
        let added = changing(&off, "Zed", true);
        assert_eq!(Value::Object(added.clone()), json!({"cursor": false, "zed": true}));
        assert_eq!(Value::Object(changing(&added, "zed", false)), json!({"cursor": false}));
        assert!(changing(&empty, "zed", false).is_empty());
        assert!(changing(&empty, "  ", true).is_empty());
        // the sheet: built-ins first, in order, then the added ones
        let rows = listing(Some(&added));
        assert_eq!(rows.len(), AGENTS.len() + 1);
        assert_eq!(rows[0], ("workbuddy".to_string(), true, true));
        assert!(rows.contains(&("cursor".to_string(), true, false)));
        assert_eq!(rows.last().unwrap(), &("zed".to_string(), false, true));
        assert!(listing(None).iter().all(|(_, b, on)| *b && *on));
    }

    #[test]
    fn a_picked_program_is_its_stem() {
        assert_eq!(program_id(Path::new(r"C:\Users\a\AppData\Local\Programs\Zed\Zed.exe")).as_deref(), Some("zed"));
        assert_eq!(program_id(Path::new(r"C:\ProgramData\Start Menu\Trae CN.lnk")).as_deref(), Some("trae cn"));
        assert_eq!(program_id(Path::new("/x/notes.txt")), None);
        assert_eq!(program_id(Path::new(".exe")), None);
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
