//! Windows Defender Firewall and Blurt on the phone (docs/design/remote-windows.md §Firewall). On a network Windows files as Public,
//! or after a cancelled prompt, the firewall drops the phone's connections without a word: Settings → Phone has to say so, and offer
//! the fix. Part of remote.rs (Settings → Phone's `firewall` and `remote_allow_firewall`).
//!
//!  • the check reads the firewall through INetFwPolicy2 (COM, no administrator): which profiles are active, whether the firewall is
//!    on in them, and the inbound rules for this exe. Blocked: any active profile with the firewall on that blocks this exe's TCP or
//!    UDP, or has no rule allowing both (the default for inbound is to block). Run when the host starts listening, when Settings
//!    shows the code, and when the network's profile changes (polled every 10 s while listening: one cheap COM call).
//!  • the fix runs the doc's netsh lines elevated, only on the owner's click: one UAC prompt (ShellExecuteExW "runas"), waited for,
//!    then the check again. Declined: still "blocked", no error.
//!  • off Windows: always "ok".

#![cfg_attr(not(windows), allow(dead_code))]

use std::sync::Mutex;

/// "ok", "blocked" or "unknown" (the check couldn't read the firewall).
static STATE: Mutex<&'static str> = Mutex::new(if cfg!(windows) { "unknown" } else { "ok" });

pub fn state() -> &'static str {
    *STATE.lock().unwrap()
}

/// The check, now (blocking: COM, a few ms to a few hundred). True if the answer changed.
pub fn recheck() -> bool {
    let now = check();
    let mut s = STATE.lock().unwrap();
    let changed = *s != now;
    *s = now;
    changed
}

/// The name of the rule `allow` adds (and the uninstaller removes).
pub const RULE: &str = "Blurt (phone)";

/// An inbound rule as the decision needs it.
#[derive(Clone, Debug, PartialEq)]
pub struct Rule {
    pub program: String,
    pub enabled: bool,
    pub inbound: bool,
    /// NET_FW_PROFILE2 bits (Domain 1, Private 2, Public 4; all = 0x7fffffff)
    pub profiles: i32,
    /// 6 TCP, 17 UDP, 256 any
    pub protocol: i32,
    pub allow: bool,
}

/// One active profile: whether the firewall is on, blocks everything inbound, and its default for inbound.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Profile {
    pub bit: i32,
    pub enabled: bool,
    pub block_all: bool,
    pub default_allow: bool,
}

/// %VAR% in a rule's program path, expanded (rules may be written so), and compared without case or slash differences.
fn same_program(rule: &str, exe: &str) -> bool {
    let mut out = String::new();
    let mut rest = rule;
    while let Some(i) = rest.find('%') {
        out.push_str(&rest[..i]);
        let after = &rest[i + 1..];
        match after.find('%') {
            Some(j) => {
                let name = &after[..j];
                out.push_str(&std::env::var(name).unwrap_or_else(|_| format!("%{name}%")));
                rest = &after[j + 1..];
            }
            None => {
                out.push_str(&rest[i..]);
                rest = "";
            }
        }
    }
    out.push_str(rest);
    let norm = |s: &str| s.trim().replace('/', "\\").to_lowercase();
    !rule.trim().is_empty() && norm(&out) == norm(exe)
}

/// "ok" or "blocked", from the active profiles and every rule.
pub fn decide(profiles: &[Profile], rules: &[Rule], exe: &str) -> &'static str {
    let covers = |r: &Rule, proto: i32| r.protocol == 256 || r.protocol == proto;
    for p in profiles.iter().filter(|p| p.enabled) {
        if p.block_all {
            return "blocked";
        }
        let mine: Vec<&Rule> =
            rules.iter().filter(|r| r.enabled && r.inbound && r.profiles & p.bit != 0 && same_program(&r.program, exe)).collect();
        for proto in [6, 17] {
            // a block rule wins over any allow
            if mine.iter().any(|r| !r.allow && covers(r, proto)) {
                return "blocked";
            }
            if !p.default_allow && !mine.iter().any(|r| r.allow && covers(r, proto)) {
                return "blocked";
            }
        }
    }
    "ok"
}

/// The elevated command: the doc's two netsh lines (any rule for this exe, a block a cancelled prompt left included, then the
/// allow rule), in one cmd so one UAC prompt covers both. None: a path cmd would read as something else.
pub fn allow_command(exe: &str) -> Option<String> {
    if exe.is_empty() || exe.contains(['"', '&', '|', '^', '<', '>', '%', '\n', '\r']) {
        return None;
    }
    Some(format!(
        "/d /s /c \"netsh advfirewall firewall delete rule name=all program=\"{exe}\" dir=in & \
         netsh advfirewall firewall add rule name=\"{RULE}\" dir=in action=allow program=\"{exe}\" enable=yes profile=private,public\""
    ))
}

#[cfg(not(windows))]
fn check() -> &'static str {
    "ok"
}

#[cfg(not(windows))]
pub fn allow() {}

/// The profile types active now (for noticing a change cheaply); None off Windows or on failure.
#[cfg(not(windows))]
pub fn current_profiles() -> Option<i32> {
    None
}

#[cfg(windows)]
mod win {
    use windows::core::{Interface, BSTR, PCWSTR};
    use windows::Win32::Foundation::{CloseHandle, WAIT_OBJECT_0};
    use windows::Win32::NetworkManagement::WindowsFirewall::{
        INetFwPolicy2, INetFwRule, NetFwPolicy2, NET_FW_ACTION_ALLOW, NET_FW_PROFILE_TYPE2, NET_FW_RULE_DIR_IN,
    };
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, IDispatch, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
    use windows::Win32::System::Ole::IEnumVARIANT;
    use windows::Win32::System::Threading::{GetExitCodeProcess, WaitForSingleObject};
    use windows::Win32::System::Variant::VARIANT;
    use windows::Win32::UI::Shell::{ShellExecuteExW, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW};
    use windows::Win32::UI::WindowsAndMessaging::SW_HIDE;

    use super::{Profile, Rule};

    /// COM on this thread for as long as it lives.
    struct Com;
    impl Com {
        fn init() -> Option<Com> {
            unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_ok().then_some(Com)
        }
    }
    impl Drop for Com {
        fn drop(&mut self) {
            unsafe { CoUninitialize() };
        }
    }

    fn policy() -> Option<INetFwPolicy2> {
        unsafe { CoCreateInstance(&NetFwPolicy2, None, CLSCTX_INPROC_SERVER) }.ok()
    }

    pub fn exe() -> String {
        std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()
    }

    pub fn current_profiles() -> Option<i32> {
        let _com = Com::init()?;
        unsafe { policy()?.CurrentProfileTypes() }.ok()
    }

    pub fn read() -> Option<(Vec<Profile>, Vec<Rule>)> {
        let _com = Com::init()?;
        let p = policy()?;
        unsafe {
            let current = p.CurrentProfileTypes().ok()?;
            let mut profiles = vec![];
            for bit in [1, 2, 4] {
                if current & bit == 0 {
                    continue;
                }
                let t = NET_FW_PROFILE_TYPE2(bit);
                profiles.push(Profile {
                    bit,
                    enabled: p.get_FirewallEnabled(t).ok()?.as_bool(),
                    block_all: p.get_BlockAllInboundTraffic(t).map(|v| v.as_bool()).unwrap_or(false),
                    default_allow: p.get_DefaultInboundAction(t).map(|a| a == NET_FW_ACTION_ALLOW).unwrap_or(false),
                });
            }
            let e: IEnumVARIANT = p.Rules().ok()?._NewEnum().ok()?.cast().ok()?;
            let mut rules = vec![];
            loop {
                let mut v = [VARIANT::default()];
                let mut n = 0u32;
                if e.Next(&mut v, &mut n).is_err() || n == 0 {
                    break;
                }
                let Ok(d) = IDispatch::try_from(&v[0]) else { continue };
                let Ok(r) = d.cast::<INetFwRule>() else { continue };
                let program = r.ApplicationName().map(|b: BSTR| b.to_string()).unwrap_or_default();
                if program.is_empty() {
                    continue; // a rule for every program, or a service: not about this exe
                }
                rules.push(Rule {
                    program,
                    enabled: r.Enabled().map(|b| b.as_bool()).unwrap_or(false),
                    inbound: r.Direction().map(|d| d == NET_FW_RULE_DIR_IN).unwrap_or(false),
                    profiles: r.Profiles().unwrap_or(0),
                    protocol: r.Protocol().unwrap_or(256),
                    allow: r.Action().map(|a| a == NET_FW_ACTION_ALLOW).unwrap_or(false),
                });
            }
            Some((profiles, rules))
        }
    }

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    /// cmd.exe with the netsh lines, elevated: Windows' own UAC prompt. Waits for it (or for the prompt being declined).
    pub fn run_elevated(params: &str) {
        let _com = Com::init();
        let (verb, file, params) = (wide("runas"), wide("cmd.exe"), wide(params));
        let mut info = SHELLEXECUTEINFOW {
            cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
            fMask: SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC,
            lpVerb: PCWSTR(verb.as_ptr()),
            lpFile: PCWSTR(file.as_ptr()),
            lpParameters: PCWSTR(params.as_ptr()),
            nShow: SW_HIDE.0,
            ..Default::default()
        };
        // declined: ERROR_CANCELLED, and nothing to wait for
        if unsafe { ShellExecuteExW(&mut info) }.is_err() || info.hProcess.is_invalid() {
            return;
        }
        unsafe {
            if WaitForSingleObject(info.hProcess, 120_000) == WAIT_OBJECT_0 {
                let mut code = 0u32;
                let _ = GetExitCodeProcess(info.hProcess, &mut code);
                if code != 0 {
                    eprintln!("blurt remote: the firewall rule's netsh ended with {code}");
                }
            }
            let _ = CloseHandle(info.hProcess);
        }
    }
}

#[cfg(windows)]
fn check() -> &'static str {
    match win::read() {
        Some((profiles, rules)) => decide(&profiles, &rules, &win::exe()),
        None => "unknown",
    }
}

#[cfg(windows)]
pub fn current_profiles() -> Option<i32> {
    win::current_profiles()
}

/// The owner clicked Allow…: the rule, through one UAC prompt, then the check again.
#[cfg(windows)]
pub fn allow() {
    match allow_command(&win::exe()) {
        Some(p) => win::run_elevated(&p),
        None => eprintln!("blurt remote: this exe's path can't go on a command line safely; the firewall rule wasn't added"),
    }
    recheck();
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXE: &str = r"C:\Users\Ann Lee\AppData\Local\Blurt\blurt.exe";

    fn public_on() -> Vec<Profile> {
        vec![Profile { bit: 4, enabled: true, block_all: false, default_allow: false }]
    }

    fn rule(protocol: i32, profiles: i32, allow: bool) -> Rule {
        Rule { program: EXE.to_uppercase(), enabled: true, inbound: true, profiles, protocol, allow }
    }

    #[test]
    fn no_rule_on_a_public_network_is_blocked() {
        assert_eq!(decide(&public_on(), &[], EXE), "blocked");
        // the firewall off for it: fine
        let off = vec![Profile { bit: 4, enabled: false, block_all: false, default_allow: false }];
        assert_eq!(decide(&off, &[], EXE), "ok");
    }

    #[test]
    fn the_rule_netsh_adds_allows_both_protocols() {
        assert_eq!(decide(&public_on(), &[rule(256, 2 | 4, true)], EXE), "ok");
        // a Private-only rule (the prompt's default) doesn't cover a Public network
        assert_eq!(decide(&public_on(), &[rule(256, 2, true)], EXE), "blocked");
        // TCP and UDP from two rules, as the prompt makes them
        assert_eq!(decide(&public_on(), &[rule(6, 0x7fffffff, true), rule(17, 0x7fffffff, true)], EXE), "ok");
        assert_eq!(decide(&public_on(), &[rule(6, 4, true)], EXE), "blocked", "UDP missing");
    }

    #[test]
    fn a_block_rule_wins_and_other_programs_dont_count() {
        assert_eq!(decide(&public_on(), &[rule(256, 4, true), rule(17, 4, false)], EXE), "blocked");
        let other = Rule { program: r"C:\Other\app.exe".into(), ..rule(256, 4, true) };
        assert_eq!(decide(&public_on(), &[other], EXE), "blocked");
        let disabled = Rule { enabled: false, ..rule(256, 4, true) };
        assert_eq!(decide(&public_on(), &[disabled], EXE), "blocked");
        let all = vec![Profile { bit: 4, enabled: true, block_all: true, default_allow: false }];
        assert_eq!(decide(&all, &[rule(256, 4, true)], EXE), "blocked", "block all inbound");
    }

    #[test]
    fn the_command_is_the_docs_two_lines() {
        let c = allow_command(EXE).unwrap();
        assert!(c.starts_with("/d /s /c \"netsh advfirewall firewall delete rule name=all program=\""));
        assert!(c.contains(&format!("add rule name=\"Blurt (phone)\" dir=in action=allow program=\"{EXE}\" enable=yes profile=private,public")));
        assert_eq!(allow_command(r"C:\a&b\blurt.exe"), None);
        assert!(same_program("%NO_SUCH_VAR_X%\\a.exe", "%no_such_var_x%\\A.EXE"));
    }
}
