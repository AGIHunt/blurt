//! Which kind of app a take goes into, by its executable (the Mac's BlurtCore `DictationAppCategory`, keyed by bundle
//! id there): chat apps get the "chat" variant of polish (tone words stay) and the double-tap-to-send tip, terminals the
//! "terminal" variant (a shell command said there stays a command — the Mac's `polishVariant`). A table of programs,
//! not rules about language. Also the other dictation apps whose notice the island gives (Typeless, Wispr Flow).
//! Pure: tests below.

/// What kind of app an executable is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Category {
    Chat,
    Code,
    Mail,
    Notes,
    Other,
}

impl Category {
    pub fn as_str(self) -> &'static str {
        match self {
            Category::Chat => "chat",
            Category::Code => "code",
            Category::Mail => "mail",
            Category::Notes => "notes",
            Category::Other => "other",
        }
    }
}

/// "WeChat.exe" / "C:\…\WeChat.exe" / "wechat" → "wechat": the file name without ".exe", lower case.
pub fn stem(exe: &str) -> String {
    let name = exe.rsplit(['\\', '/']).next().unwrap_or(exe).to_lowercase();
    name.strip_suffix(".exe").unwrap_or(&name).to_string()
}

const CHAT: &[&str] = &[
    "wechat", "weixin", "qq", "tim", "wxwork", "dingtalk", "feishu", "lark", "slack", "teams", "ms-teams", "telegram",
    "discord", "whatsapp", "signal", "line", "skype", "zoom", "messenger", "wecom",
];
/// terminals: command lines and the terminal apps that host them (also code)
const TERMINALS: &[&str] = &[
    "windowsterminal", "wt", "openconsole", "conhost", "cmd", "powershell", "pwsh", "powershell_ise", "wezterm-gui",
    "wezterm", "alacritty", "hyper", "mintty", "tabby", "warp", "conemu", "conemu64", "kitty", "ghostty", "putty",
    "mobaxterm", "termius", "fluent terminal",
    // Linux (the executable's name: /proc/<pid>/exe)
    "ptyxis", "gnome-terminal-server", "kgx", "konsole", "xterm", "uxterm", "foot", "footclient", "tilix", "terminator",
    "xfce4-terminal", "lxterminal", "mate-terminal", "qterminal", "urxvt", "st", "blackbox", "terminology", "rio",
];
const CODE: &[&str] = &[
    "code", "code - insiders", "cursor", "windsurf", "zed", "devenv", "idea64", "pycharm64", "webstorm64", "clion64",
    "goland64", "rider64", "rustrover64", "phpstorm64", "datagrip64", "studio64", "sublime_text", "notepad++", "trae",
    "kiro", "codium", "idea", "pycharm", "webstorm", "clion", "goland", "rider", "rustrover", "sublime_text_4",
];
const MAIL: &[&str] = &["outlook", "olk", "thunderbird", "mailmaster", "foxmail", "hxoutlook"];
const NOTES: &[&str] = &[
    "obsidian", "notion", "winword", "onenote", "typora", "logseq", "joplin", "evernote", "yinxiangbiji", "wps",
];

pub fn category(exe: Option<&str>) -> Category {
    let Some(e) = exe.map(stem).filter(|s| !s.is_empty()) else {
        return Category::Other;
    };
    let e = e.as_str();
    if CHAT.contains(&e) {
        Category::Chat
    } else if TERMINALS.contains(&e) || CODE.contains(&e) {
        Category::Code
    } else if MAIL.contains(&e) {
        Category::Mail
    } else if NOTES.contains(&e) {
        Category::Notes
    } else {
        Category::Other
    }
}

/// A terminal: polish gets the "terminal" variant.
pub fn is_terminal(exe: Option<&str>) -> bool {
    exe.map(stem).is_some_and(|e| TERMINALS.contains(&e.as_str()))
}

/// Polish's variant of light for an app: "terminal" (commands stay commands), "chat" (tone words stay), or None.
pub fn polish_variant(exe: Option<&str>) -> Option<&'static str> {
    if is_terminal(exe) {
        return Some("terminal");
    }
    (category(exe) == Category::Chat).then_some("chat")
}

/// The other dictation apps (process stems → the name the island says). Their Windows executables as installed
/// (unverified on a real install: "Typeless.exe", "Wispr Flow.exe").
const CLASH_APPS: &[(&str, &str)] = &[("typeless", "Typeless"), ("wispr flow", "Wispr Flow"), ("wisprflow", "Wispr Flow")];

/// The names of the other dictation apps among `running` executables, once each, in a fixed order.
pub fn clash_apps<S: AsRef<str>>(running: &[S]) -> Vec<String> {
    let stems: Vec<String> = running.iter().map(|r| stem(r.as_ref())).collect();
    let mut out: Vec<String> = vec![];
    for (s, name) in CLASH_APPS {
        if stems.iter().any(|x| x == s) && !out.iter().any(|o| o == name) {
            out.push(name.to_string());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_by_executable() {
        assert_eq!(category(Some("WeChat.exe")), Category::Chat);
        assert_eq!(category(Some(r"C:\Program Files\Slack\slack.exe")), Category::Chat);
        assert_eq!(category(Some("ms-teams.exe")), Category::Chat);
        assert_eq!(category(Some("Code.exe")), Category::Code);
        assert_eq!(category(Some("WindowsTerminal.exe")), Category::Code);
        assert_eq!(category(Some("OUTLOOK.EXE")), Category::Mail);
        assert_eq!(category(Some("WINWORD.EXE")), Category::Notes);
        assert_eq!(category(Some("chrome.exe")), Category::Other);
        assert_eq!(category(Some("")), Category::Other);
        assert_eq!(category(None), Category::Other);
        // whole names only: no substring matches (1Password isn't Word, QQMusic isn't QQ)
        assert_eq!(category(Some("QQMusic.exe")), Category::Other);
        assert_eq!(category(Some("codex.exe")), Category::Other);
    }

    #[test]
    fn the_terminal_variant() {
        for t in ["WindowsTerminal.exe", "powershell.exe", "pwsh.exe", "cmd.exe", "conhost.exe", "OpenConsole.exe", "wezterm-gui.exe", "alacritty.exe"] {
            assert!(is_terminal(Some(t)), "{t}");
            assert_eq!(polish_variant(Some(t)), Some("terminal"), "{t}");
        }
        assert_eq!(polish_variant(Some("Code.exe")), None); // an editor: plain light
        assert_eq!(polish_variant(Some("WeChat.exe")), Some("chat"));
        assert_eq!(polish_variant(Some("notepad.exe")), None);
        assert_eq!(polish_variant(None), None);
        for t in ["ptyxis", "gnome-terminal-server", "/usr/bin/kitty", "konsole"] {
            assert!(is_terminal(Some(t)), "{t}"); // Linux names
        }
        assert!(!is_terminal(Some("gnome-text-editor")));
    }

    #[test]
    fn other_dictation_apps() {
        assert_eq!(clash_apps(&["explorer.exe", "Typeless.exe"]), vec!["Typeless"]);
        assert_eq!(clash_apps(&["Wispr Flow.exe", "typeless.exe", "WisprFlow.exe"]), vec!["Typeless", "Wispr Flow"]);
        assert!(clash_apps(&["flow.exe", "chrome.exe"]).is_empty());
        assert!(clash_apps::<&str>(&[]).is_empty());
    }
}
