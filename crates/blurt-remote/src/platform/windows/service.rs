//! Blurt's Windows system service (docs/design/remote-1.1.md §2): `blurt-remote-service.exe`, one binary in three roles.
//!
//!   install / uninstall   (elevated, from Blurt's Settings) copy this binary to %ProgramFiles%\Blurt Remote, register it as the
//!                         LocalSystem service "BlurtRemote" (automatic start, restarted when it fails), allow software Ctrl+Alt+Del
//!                         for services, start it; or stop it, remove it and the copy.
//!   run                   the service (session 0, no network): keeps the agent running in the console session, and again after
//!                         each logon, logoff and user switch.
//!   agent                 LocalSystem in the console session, no network: the Windows backend on whichever desktop has the input,
//!                         served over \\.\pipe\blurt-remote-agent to one host at a time (agent.rs). Only a process in the console
//!                         session, or this service's own binary (the standby host), may connect.
//!
//! The copy in Program Files matters: Blurt itself installs per user, and a service started from a folder its user can write to
//! would hand SYSTEM to anything that replaced the file.
use std::ffi::c_void;
use std::os::windows::io::FromRawHandle;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::time::Duration;

use ::windows::core::{w, HSTRING, PCWSTR, PWSTR};
use ::windows::Win32::Foundation::{CloseHandle, GetLastError, ERROR_PIPE_CONNECTED, HANDLE, HLOCAL, LocalFree};
use ::windows::Win32::Security::Authorization::{ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
use ::windows::Win32::Security::{
    DuplicateTokenEx, SecurityImpersonation, SetTokenInformation, TokenPrimary, TokenSessionId, PSECURITY_DESCRIPTOR,
    SECURITY_ATTRIBUTES, TOKEN_ACCESS_MASK, TOKEN_ALL_ACCESS,
};
use ::windows::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_INBOUND, PIPE_ACCESS_OUTBOUND};
use ::windows::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, GetNamedPipeClientProcessId, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE,
    PIPE_WAIT,
};
use ::windows::Win32::System::RemoteDesktop::{ProcessIdToSessionId, WTSGetActiveConsoleSessionId};
use ::windows::Win32::System::Services::{
    ChangeServiceConfig2W, CloseServiceHandle, ControlService, CreateServiceW, DeleteService, OpenSCManagerW, OpenServiceW,
    RegisterServiceCtrlHandlerExW, QueryServiceStatus, SetServiceStatus, StartServiceCtrlDispatcherW, StartServiceW, SC_ACTION, SC_ACTION_RESTART,
    SC_MANAGER_ALL_ACCESS, SC_MANAGER_CONNECT, SERVICE_ACCEPT_SESSIONCHANGE, SERVICE_ACCEPT_STOP, SERVICE_ALL_ACCESS, SERVICE_AUTO_START,
    SERVICE_CONFIG_DESCRIPTION, SERVICE_CONFIG_FAILURE_ACTIONS, SERVICE_CONTROL_STOP, SERVICE_DESCRIPTIONW, SERVICE_ERROR_NORMAL,
    SERVICE_FAILURE_ACTIONSW, SERVICE_RUNNING, SERVICE_START_PENDING, SERVICE_STATUS, SERVICE_STATUS_HANDLE, SERVICE_STOPPED,
    SERVICE_QUERY_STATUS, SERVICE_STOP_PENDING, SERVICE_TABLE_ENTRYW, SERVICE_WIN32_OWN_PROCESS,
};
use ::windows::Win32::System::Threading::{
    CreateProcessAsUserW, GetCurrentProcess, GetExitCodeProcess, OpenProcess, OpenProcessToken, QueryFullProcessImageNameW,
    TerminateProcess, CREATE_NO_WINDOW, CREATE_UNICODE_ENVIRONMENT, PROCESS_INFORMATION, PROCESS_NAME_WIN32,
    PROCESS_QUERY_LIMITED_INFORMATION, STARTUPINFOW,
};

pub const NAME: &str = "BlurtRemote";
/// Two pipes, one each way: a synchronous pipe handle serializes its reads and writes, so one pipe read on one thread while frames
/// are written on another would stall both. Requests go in on PIPE, answers and frames come out on PIPE_OUT.
pub const PIPE: &str = r"\\.\pipe\blurt-remote-agent";
pub const PIPE_OUT: &str = r"\\.\pipe\blurt-remote-agent-out";
const STILL_ACTIVE: u32 = 259;

/// `blurt-remote-service.exe <role>`: the process's exit code.
pub fn main(args: &[String]) -> i32 {
    match args.first().map(String::as_str) {
        Some("install") => report(install()),
        Some("uninstall") => report(uninstall()),
        Some("run") => run_service(),
        Some("agent") => {
            agent();
            0
        }
        Some("standby") => {
            standby();
            0
        }
        _ => {
            eprintln!("usage: blurt-remote-service install | uninstall | run | agent");
            2
        }
    }
}

fn report(r: Result<(), String>) -> i32 {
    match r {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("{e}");
            1
        }
    }
}

/// Where the service lives: %ProgramFiles%\Blurt Remote\blurt-remote-service.exe (only administrators can write there).
pub fn installed_path() -> PathBuf {
    let pf = std::env::var_os("ProgramFiles").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(r"C:\Program Files"));
    pf.join("Blurt Remote").join("blurt-remote-service.exe")
}

/// %ProgramData%\Blurt Remote: the standby host's copy of this computer (standby.json, SYSTEM only) and its working folder (standby\,
/// SYSTEM and LocalService).
fn data_dir() -> PathBuf {
    std::env::var_os("ProgramData").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(r"C:\ProgramData")).join("Blurt Remote")
}

fn icacls(path: &Path, grants: &[&str]) {
    let mut a = vec![path.display().to_string(), "/inheritance:r".to_string()];
    for g in grants {
        a.push("/grant:r".into());
        a.push((*g).into());
    }
    let _ = std::process::Command::new("icacls").args(&a).output();
}

/// Copies an earlier install moved aside while they still ran; one still running stays for next time.
fn remove_old_copies(dest: &Path) {
    let Ok(list) = std::fs::read_dir(dest.parent().unwrap()) else { return };
    for e in list.flatten() {
        if e.file_name().to_string_lossy().starts_with("blurt-remote-service.old-") {
            let _ = std::fs::remove_file(e.path());
        }
    }
}

/// Whether the service is installed and running (Settings' switch): asked of the Service Control Manager, which any user may.
/// Not the pipe: it takes one client, and while this app is that client it reads as busy.
pub fn agent_running() -> bool {
    unsafe {
        let Ok(scm) = OpenSCManagerW(None, None, SC_MANAGER_CONNECT) else { return false };
        let on = match OpenServiceW(scm, &HSTRING::from(NAME), SERVICE_QUERY_STATUS) {
            Ok(s) => {
                let mut st = SERVICE_STATUS::default();
                let r = QueryServiceStatus(s, &mut st).is_ok() && st.dwCurrentState == SERVICE_RUNNING;
                let _ = CloseServiceHandle(s);
                r
            }
            Err(_) => false,
        };
        let _ = CloseServiceHandle(scm);
        on
    }
}

/// The agent's pipe is there (a busy one too: ERROR_PIPE_BUSY): its process still holds the binary.
fn pipe_up() -> bool {
    match std::fs::metadata(PIPE) {
        Ok(_) => true,
        Err(e) => e.raw_os_error() == Some(231),
    }
}

// ------------------------------------------------------------------ install

fn install() -> Result<(), String> {
    let me = std::env::current_exe().map_err(|e| e.to_string())?;
    let dest = installed_path();
    let _ = uninstall_service(); // an older one goes first (its binary may be in use)
    std::fs::create_dir_all(dest.parent().unwrap()).map_err(|e| format!("{}: {e}", dest.display()))?;
    remove_old_copies(&dest);
    if me != dest {
        let mut copied = std::fs::copy(&me, &dest).map(|_| ());
        for _ in 0..10 {
            if copied.is_ok() {
                break;
            }
            std::thread::sleep(Duration::from_millis(300));
            copied = std::fs::copy(&me, &dest).map(|_| ());
        }
        if copied.is_err() {
            // the old one still runs (its agent serving the session that approved this prompt): a running exe can't be overwritten
            // but can be renamed; the renamed copy goes at the next install or uninstall
            let old = dest.with_file_name(format!("blurt-remote-service.old-{}.exe", std::process::id()));
            std::fs::rename(&dest, &old).map_err(|e| format!("move aside {}: {e}", dest.display()))?;
            std::fs::copy(&me, &dest).map_err(|e| format!("copy to {}: {e}", dest.display()))?;
        }
    }
    // services may press Ctrl+Alt+Del in software (SendSAS): 1 = services, 3 = services and accessibility apps
    let _ = std::process::Command::new("reg")
        .args(["add", r"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System", "/v", "SoftwareSASGeneration", "/t", "REG_DWORD", "/d", "3", "/f"])
        .output();
    unsafe {
        let scm = OpenSCManagerW(None, None, SC_MANAGER_ALL_ACCESS).map_err(|e| format!("Service Control Manager: {e}"))?;
        let cmd = HSTRING::from(format!("\"{}\" run", dest.display()));
        let svc = CreateServiceW(
            scm,
            &HSTRING::from(NAME),
            w!("Blurt Remote Control"),
            SERVICE_ALL_ACCESS,
            SERVICE_WIN32_OWN_PROCESS,
            SERVICE_AUTO_START,
            SERVICE_ERROR_NORMAL,
            &cmd,
            None,
            None,
            None,
            None,
            None,
        );
        let svc = match svc {
            Ok(s) => s,
            Err(e) => {
                let _ = CloseServiceHandle(scm);
                return Err(format!("CreateService: {e}"));
            }
        };
        let mut desc = SERVICE_DESCRIPTIONW {
            lpDescription: PWSTR(
                HSTRING::from("Lets your paired devices reach this PC at the lock and login screens and in UAC prompts.").as_ptr() as *mut u16,
            ),
        };
        let _ = ChangeServiceConfig2W(svc, SERVICE_CONFIG_DESCRIPTION, Some(&mut desc as *mut _ as *const c_void));
        let mut actions = [
            SC_ACTION { Type: SC_ACTION_RESTART, Delay: 2000 },
            SC_ACTION { Type: SC_ACTION_RESTART, Delay: 5000 },
            SC_ACTION { Type: SC_ACTION_RESTART, Delay: 30000 },
        ];
        let mut fa = SERVICE_FAILURE_ACTIONSW {
            dwResetPeriod: 86400,
            lpRebootMsg: PWSTR::null(),
            lpCommand: PWSTR::null(),
            cActions: actions.len() as u32,
            lpsaActions: actions.as_mut_ptr(),
        };
        let _ = ChangeServiceConfig2W(svc, SERVICE_CONFIG_FAILURE_ACTIONS, Some(&mut fa as *mut _ as *const c_void));
        // the standby host (the login screen) takes connections on the local network too
        let _ = std::process::Command::new("netsh")
            .args(["advfirewall", "firewall", "add", "rule", "name=Blurt Remote (service)", "dir=in", "action=allow", &format!("program={}", dest.display()), "enable=yes", "profile=any"])
            .output();
        let started = StartServiceW(svc, None);
        let _ = CloseServiceHandle(svc);
        let _ = CloseServiceHandle(scm);
        started.map_err(|e| format!("StartService: {e}"))
    }
}

fn uninstall_service() -> Result<(), String> {
    unsafe {
        let scm = OpenSCManagerW(None, None, SC_MANAGER_ALL_ACCESS).map_err(|e| e.to_string())?;
        let svc = match OpenServiceW(scm, &HSTRING::from(NAME), SERVICE_ALL_ACCESS) {
            Ok(s) => s,
            Err(_) => {
                let _ = CloseServiceHandle(scm);
                return Ok(());
            }
        };
        let mut st = SERVICE_STATUS::default();
        let _ = ControlService(svc, SERVICE_CONTROL_STOP, &mut st);
        let r = DeleteService(svc).map_err(|e| e.to_string());
        let _ = CloseServiceHandle(svc);
        let _ = CloseServiceHandle(scm);
        // the service and its agent let go of the binary
        for _ in 0..50 {
            if !pipe_up() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        r
    }
}

fn uninstall() -> Result<(), String> {
    uninstall_service()?;
    let _ = std::process::Command::new("netsh").args(["advfirewall", "firewall", "delete", "rule", "name=Blurt Remote (service)"]).output();
    // the standby host's keys and devices are SYSTEM's and LocalService's alone: an administrator takes them over to remove them
    let data = data_dir();
    if data.exists() {
        let d = data.display().to_string();
        let _ = std::process::Command::new("icacls").args([d.as_str(), "/setowner", "*S-1-5-32-544", "/t", "/c", "/q"]).output();
        let _ = std::process::Command::new("icacls").args([d.as_str(), "/reset", "/t", "/c", "/q"]).output();
        let _ = std::fs::remove_dir_all(&data);
    }
    let dest = installed_path();
    remove_old_copies(&dest);
    for _ in 0..30 {
        if std::fs::remove_file(&dest).is_ok() || !dest.exists() {
            break;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    let _ = std::fs::remove_dir(dest.parent().unwrap());
    // run from that copy (the app's uninstaller does): a running exe can't remove itself, so a hidden cmd does once this exits
    let dir = dest.parent().unwrap();
    if dir.exists() {
        use std::os::windows::process::CommandExt;
        let d = dir.display().to_string();
        let _ = std::process::Command::new("cmd")
            .raw_arg(format!("/d /c ping -n 3 127.0.0.1 >nul & del /f /q \"{d}\\blurt-remote-service*.exe\" & rmdir \"{d}\""))
            .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
            .spawn();
    }
    Ok(())
}

// ------------------------------------------------------------------ the service

static STOP: AtomicBool = AtomicBool::new(false);
static mut STATUS: SERVICE_STATUS_HANDLE = SERVICE_STATUS_HANDLE(std::ptr::null_mut());

fn run_service() -> i32 {
    let name = HSTRING::from(NAME);
    let table = [
        SERVICE_TABLE_ENTRYW { lpServiceName: PWSTR(name.as_ptr() as *mut u16), lpServiceProc: Some(service_main) },
        SERVICE_TABLE_ENTRYW::default(),
    ];
    match unsafe { StartServiceCtrlDispatcherW(table.as_ptr()) } {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("not started by the Service Control Manager: {e}");
            1
        }
    }
}

fn set_status(state: u32) {
    let st = SERVICE_STATUS {
        dwServiceType: SERVICE_WIN32_OWN_PROCESS,
        dwCurrentState: ::windows::Win32::System::Services::SERVICE_STATUS_CURRENT_STATE(state),
        dwControlsAccepted: if state == SERVICE_RUNNING.0 { SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SESSIONCHANGE } else { 0 },
        dwWin32ExitCode: 0,
        dwServiceSpecificExitCode: 0,
        dwCheckPoint: 0,
        dwWaitHint: if state == SERVICE_RUNNING.0 { 0 } else { 5000 },
    };
    unsafe {
        #[allow(static_mut_refs)]
        let _ = SetServiceStatus(STATUS, &st);
    }
}

unsafe extern "system" fn handler(control: u32, _event: u32, _data: *mut c_void, _ctx: *mut c_void) -> u32 {
    const SESSIONCHANGE: u32 = 0x0E;
    match control {
        c if c == SERVICE_CONTROL_STOP => {
            set_status(SERVICE_STOP_PENDING.0);
            STOP.store(true, SeqCst);
            0
        }
        // a logon, logoff or switch: the supervisor sees the console session change within a second
        SESSIONCHANGE => 0,
        _ => 0,
    }
}

unsafe extern "system" fn service_main(_argc: u32, _argv: *mut PWSTR) {
    let name = HSTRING::from(NAME);
    match RegisterServiceCtrlHandlerExW(&name, Some(handler), None) {
        Ok(h) => STATUS = h,
        Err(_) => return,
    }
    set_status(SERVICE_START_PENDING.0);
    set_status(SERVICE_RUNNING.0);
    supervise();
    set_status(SERVICE_STOPPED.0);
}

/// Keeps one agent running in the console session (logon, logoff and user switches move it), and the standby host while no one is
/// logged in there.
fn supervise() {
    let me = std::env::current_exe().unwrap_or_default();
    let d = data_dir();
    let _ = std::fs::create_dir_all(d.join("standby"));
    icacls(&d, &["*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F"]);
    icacls(&d.join("standby"), &["*S-1-5-18:(OI)(CI)F", "*S-1-5-19:(OI)(CI)M"]);
    let mut child: Option<(HANDLE, u32)> = None;
    let mut standby: Option<HANDLE> = None;
    while !STOP.load(SeqCst) {
        // the standby host: only at the login screen (no one logged in at the console), and only once the user's Blurt has said
        // who this computer is (standby.json)
        let console = unsafe { WTSGetActiveConsoleSessionId() };
        let want = console != 0xFFFF_FFFF && !logged_in(console) && d.join("standby.json").exists();
        let running = standby.is_some_and(|h| unsafe {
            let mut code = 0u32;
            GetExitCodeProcess(h, &mut code).is_ok() && code == STILL_ACTIVE
        });
        if standby.is_some() && (!want || !running) {
            let h = standby.take().unwrap();
            unsafe {
                let _ = TerminateProcess(h, 0);
                let _ = CloseHandle(h);
            }
        }
        if standby.is_none() && want {
            if let Ok(src) = std::fs::read_to_string(d.join("standby.json")) {
                prepare_standby(&d.join("standby"), &src);
                standby = launch_as_local_service(&me, "standby");
            }
        }
        let console = unsafe { WTSGetActiveConsoleSessionId() };
        let alive = child.is_some_and(|(h, _)| unsafe {
            let mut code = 0u32;
            GetExitCodeProcess(h, &mut code).is_ok() && code == STILL_ACTIVE
        });
        let wrong_session = child.is_some_and(|(_, s)| s != console);
        if child.is_some() && (!alive || wrong_session) {
            let (h, _) = child.take().unwrap();
            unsafe {
                let _ = TerminateProcess(h, 0);
                let _ = CloseHandle(h);
            }
        }
        if child.is_none() && console != 0xFFFF_FFFF {
            child = launch_in_session(&me, "agent", console).map(|h| (h, console));
        }
        std::thread::sleep(Duration::from_millis(1000));
    }
    for h in child.map(|(h, _)| h).into_iter().chain(standby) {
        unsafe {
            let _ = TerminateProcess(h, 0);
            let _ = CloseHandle(h);
        }
    }
}

/// Someone is logged in at the console (its user name isn't empty).
fn logged_in(session: u32) -> bool {
    use ::windows::Win32::System::RemoteDesktop::{WTSFreeMemory, WTSQuerySessionInformationW, WTSUserName, WTS_CURRENT_SERVER_HANDLE};
    unsafe {
        let mut buf = PWSTR::null();
        let mut len = 0u32;
        if WTSQuerySessionInformationW(Some(WTS_CURRENT_SERVER_HANDLE), session, WTSUserName, &mut buf, &mut len).is_err() {
            return true; // can't tell: leave it to the user's Blurt
        }
        let name = buf.to_string().unwrap_or_default();
        WTSFreeMemory(buf.0 as *mut c_void);
        !name.is_empty()
    }
}

/// The standby host's folder from the user's snapshot: host.json (this computer's id and settings), devices.json, keys.json.
fn prepare_standby(dir: &Path, snapshot: &str) {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(snapshot) else { return };
    let _ = std::fs::write(dir.join("host.json"), serde_json::to_vec_pretty(&v["host"]).unwrap_or_default());
    let _ = std::fs::write(dir.join("devices.json"), serde_json::to_vec_pretty(&v["devices"]).unwrap_or_default());
    let keys: serde_json::Map<String, serde_json::Value> = v["keys"]
        .as_object()
        .map(|m| m.iter().map(|(id, k)| (format!("remote-{id}"), k.clone())).collect())
        .unwrap_or_default();
    let _ = std::fs::write(dir.join("keys.json"), serde_json::to_vec(&keys).unwrap_or_default());
}

/// This binary with `role` as LocalService in session 0 (no desktop, no rights beyond its folder and the network).
fn launch_as_local_service(exe: &Path, role: &str) -> Option<HANDLE> {
    use ::windows::Win32::Security::{LogonUserW, LOGON32_LOGON_SERVICE, LOGON32_PROVIDER_DEFAULT};
    unsafe {
        let mut tok = HANDLE::default();
        LogonUserW(w!("LocalService"), w!("NT AUTHORITY"), None, LOGON32_LOGON_SERVICE, LOGON32_PROVIDER_DEFAULT, &mut tok).ok()?;
        let si = STARTUPINFOW { cb: std::mem::size_of::<STARTUPINFOW>() as u32, ..Default::default() };
        let mut cmd: Vec<u16> = format!("\"{}\" {role}\0", exe.display()).encode_utf16().collect();
        let mut pi = PROCESS_INFORMATION::default();
        let ok = CreateProcessAsUserW(Some(tok), None, Some(PWSTR(cmd.as_mut_ptr())), None, None, false, CREATE_NO_WINDOW, None, None, &si, &mut pi);
        let _ = CloseHandle(tok);
        ok.ok()?;
        let _ = CloseHandle(pi.hThread);
        Some(pi.hProcess)
    }
}

// ------------------------------------------------------------------ the standby host

/// At the login screen: this computer's host, as the user's Blurt would be, over the agent's pipe. Pairs nothing new.
fn standby() {
    let dir = data_dir().join("standby");
    let backend = loop {
        if let Some(p) = connect_plain() {
            break p;
        }
        std::thread::sleep(Duration::from_secs(1));
    };
    let h = crate::server::Host::start(
        crate::server::HostConfig {
            dir: dir.clone(),
            name: crate::server::computer_name(),
            version: env!("CARGO_PKG_VERSION").into(),
            test_answer: Some(false),
            port: 0,
            go_between: None,
        },
        Box::new(backend),
        Box::new(crate::store::FileKeyStore::new(dir.join("keys.json"))),
        Box::new(Quiet),
    );
    loop {
        std::thread::sleep(Duration::from_secs(60));
        let _ = &h;
    }
}

/// The standby host tells no one anything: there's no one logged in to tell.
struct Quiet;
impl crate::server::App for Quiet {}

/// The agent over the pipe with no clipboard (the standby host has no user).
fn connect_plain() -> Option<crate::agent::Proxy> {
    let (w, r) = open_pipes()?;
    crate::agent::Proxy::connect(Box::new(r), Box::new(w), Box::new(|| {}), super::monitors::now, None).ok()
}

/// This binary with `role`, as LocalSystem in session `session` (its desktop winsta0\default; the agent moves itself to the input
/// desktop). The process's handle.
fn launch_in_session(exe: &Path, role: &str, session: u32) -> Option<HANDLE> {
    unsafe {
        let mut own = HANDLE::default();
        OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS, &mut own).ok()?;
        let mut dup = HANDLE::default();
        let r = DuplicateTokenEx(own, TOKEN_ACCESS_MASK(0x0200_0000), None, SecurityImpersonation, TokenPrimary, &mut dup);
        let _ = CloseHandle(own);
        r.ok()?;
        let s = session;
        if SetTokenInformation(dup, TokenSessionId, &s as *const u32 as *const c_void, 4).is_err() {
            let _ = CloseHandle(dup);
            return None;
        }
        let mut desktop: Vec<u16> = "winsta0\\default\0".encode_utf16().collect();
        let si = STARTUPINFOW {
            cb: std::mem::size_of::<STARTUPINFOW>() as u32,
            lpDesktop: PWSTR(desktop.as_mut_ptr()),
            ..Default::default()
        };
        let mut cmd: Vec<u16> = format!("\"{}\" {role}\0", exe.display()).encode_utf16().collect();
        let mut pi = PROCESS_INFORMATION::default();
        let ok = CreateProcessAsUserW(
            Some(dup),
            None,
            Some(PWSTR(cmd.as_mut_ptr())),
            None,
            None,
            false,
            CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
            None,
            None,
            &si,
            &mut pi,
        );
        let _ = CloseHandle(dup);
        ok.ok()?;
        let _ = CloseHandle(pi.hThread);
        Some(pi.hProcess)
    }
}

// ------------------------------------------------------------------ the agent

/// Serves the pipe until the process is ended (the service ends it at a session change).
fn agent() {
    super::desktop::set_agent();
    let mut backend = super::backend();
    let own = std::env::current_exe().ok();
    loop {
        let (Some(i), Some(o)) = (pipe_instance(PIPE, PIPE_ACCESS_INBOUND), pipe_instance(PIPE_OUT, PIPE_ACCESS_OUTBOUND)) else {
            std::thread::sleep(Duration::from_secs(1));
            continue;
        };
        let close = |hs: &[HANDLE]| {
            for h in hs {
                unsafe {
                    let _ = CloseHandle(*h);
                }
            }
        };
        // the client opens the requests pipe, then the answers pipe: both from the same process, and one it may serve
        let pid_in = accept(i);
        let pid_out = pid_in.and_then(|_| accept(o));
        if pid_in.is_none() || pid_in != pid_out || !allowed(pid_in.unwrap(), own.as_deref()) {
            close(&[i, o]);
            continue;
        }
        let mut reader = unsafe { std::fs::File::from_raw_handle(i.0) };
        let writer = unsafe { std::fs::File::from_raw_handle(o.0) };
        let save = |snapshot: &str| save_standby(snapshot);
        crate::agent::serve(&mut reader, Box::new(writer), backend.as_mut(), Some(&save));
    }
}

/// Waits for a client on this pipe instance: its process id.
fn accept(h: HANDLE) -> Option<u32> {
    unsafe {
        let connected = ConnectNamedPipe(h, None);
        if connected.is_err() && GetLastError() != ERROR_PIPE_CONNECTED {
            return None;
        }
        let mut pid = 0u32;
        GetNamedPipeClientProcessId(h, &mut pid).ok()?;
        Some(pid)
    }
}

/// The user's Blurt said who this computer is and which devices are paired: kept for the login screen, readable by SYSTEM only.
fn save_standby(snapshot: &str) {
    if serde_json::from_str::<serde_json::Value>(snapshot).is_err() {
        return;
    }
    let d = data_dir();
    let _ = std::fs::create_dir_all(&d);
    let f = d.join("standby.json");
    if std::fs::write(&f, snapshot).is_ok() {
        icacls(&f, &["*S-1-5-18:F"]);
    }
}

/// The pipe, open to SYSTEM, interactive users and LocalService (the standby host), never to another machine.
fn pipe_instance(name: &str, access: ::windows::Win32::Storage::FileSystem::FILE_FLAGS_AND_ATTRIBUTES) -> Option<HANDLE> {
    unsafe {
        let mut sd = PSECURITY_DESCRIPTOR::default();
        ConvertStringSecurityDescriptorToSecurityDescriptorW(w!("D:P(A;;GA;;;SY)(A;;GRGW;;;IU)(A;;GRGW;;;LS)"), SDDL_REVISION_1, &mut sd, None)
            .ok()?;
        let sa = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: sd.0,
            bInheritHandle: false.into(),
        };
        let h = CreateNamedPipeW(
            &HSTRING::from(name),
            access | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            1 << 20,
            1 << 20,
            0,
            Some(&sa),
        );
        let _ = LocalFree(Some(HLOCAL(sd.0)));
        (!h.is_invalid()).then_some(h)
    }
}

/// Who may drive the screen: a process in the console session (the person at this PC, or their Blurt), or this service's own
/// binary (the standby host, LocalService, at the login screen).
fn allowed(pid: u32, own: Option<&Path>) -> bool {
    unsafe {
        let mut session = 0u32;
        let console = WTSGetActiveConsoleSessionId();
        if ProcessIdToSessionId(pid, &mut session).is_ok() && session == console {
            return true;
        }
        let Ok(p) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return false };
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(p, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len).is_ok();
        let _ = CloseHandle(p);
        ok && own.is_some_and(|o| PathBuf::from(String::from_utf16_lossy(&buf[..len as usize])) == o)
    }
}

/// The host's side: the agent over the pipe, as a `Backend`; the clipboard stays this user's own. None when the service isn't there.
pub fn connect() -> Option<crate::agent::Proxy> {
    let (w, r) = open_pipes()?;
    crate::agent::Proxy::connect(Box::new(r), Box::new(w), Box::new(|| {}), super::monitors::now, Some(Box::new(OwnClipboard))).ok()
}

/// The requests pipe (written) and the answers pipe (read), in that order (the agent accepts them so).
fn open_pipes() -> Option<(std::fs::File, std::fs::File)> {
    let w = std::fs::OpenOptions::new().write(true).open(PIPE).ok()?;
    let r = (0..50).find_map(|_| {
        std::fs::OpenOptions::new().read(true).open(PIPE_OUT).ok().or_else(|| {
            std::thread::sleep(Duration::from_millis(20));
            None
        })
    })?;
    Some((w, r))
}

/// The user's clipboard (the agent, as SYSTEM, has none of theirs).
struct OwnClipboard;

impl crate::host::Input for OwnClipboard {
    fn can_control(&self) -> bool {
        false
    }
    fn key(&mut self, _: &str, _: u8, _: Option<bool>) {}
    fn set_held(&mut self, _: u8) {}
    fn text(&mut self, _: &str) {}
    fn button(&mut self, _: crate::host::Button, _: bool, _: u32) {}
    fn move_by(&mut self, _: f64, _: f64) {}
    fn move_to(&mut self, _: f64, _: f64) {}
    fn scroll(&mut self, _: f64, _: f64, _: crate::host::ScrollPhase) {}
    fn system(&mut self, _: crate::host::SystemMove) {}
    fn release_all(&mut self) {}
    fn pointer(&self) -> Option<(f64, f64)> {
        None
    }
    fn cursor_shape(&mut self) -> Option<crate::host::CursorShape> {
        None
    }
    fn clipboard(&mut self) -> Option<String> {
        super::clipboard::get_text()
    }
    fn set_clipboard(&mut self, text: &str) {
        let _ = super::clipboard::set_text(text);
    }
}

#[allow(dead_code)]
fn _unused(_: PCWSTR) {}
