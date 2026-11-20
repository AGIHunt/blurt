//! The agent's desktops (docs/design/remote-1.1.md §2): as LocalSystem in the console session it may draw from and type into whichever
//! desktop has the input — Default, Winlogon (the lock and login screens), the UAC prompt — but each thread sees only the desktop it's
//! on. Before capturing or sending input it moves onto the one that has the input now. A normal (user) host never does this.
use std::cell::RefCell;
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};

use ::windows::Win32::Foundation::HANDLE;
use ::windows::Win32::System::StationsAndDesktops::{
    CloseDesktop, GetUserObjectInformationW, OpenInputDesktop, SetThreadDesktop, DESKTOP_ACCESS_FLAGS, DESKTOP_CONTROL_FLAGS, HDESK,
    UOI_NAME,
};

static AGENT: AtomicBool = AtomicBool::new(false);

/// This process is the service's agent: capture by DXGI on the input desktop (Windows.Graphics.Capture can't see the secure ones),
/// input on it too.
pub fn set_agent() {
    AGENT.store(true, SeqCst);
}

pub fn agent() -> bool {
    AGENT.load(SeqCst)
}

/// The agent's own notes (%ProgramData%\Blurt Remote\agent.log, kept short): desktop moves and capture losses. Agent only.
pub fn note(msg: &str) {
    if !agent() {
        return;
    }
    use std::io::Write;
    let p = std::env::var_os("ProgramData").map(std::path::PathBuf::from).unwrap_or_default().join("Blurt Remote").join("agent.log");
    if std::fs::metadata(&p).is_ok_and(|m| m.len() > 1 << 20) {
        let _ = std::fs::remove_file(&p);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&p) {
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
        let _ = writeln!(f, "{t:.3} {:?} {msg}", std::thread::current().id());
    }
}

thread_local! {
    /// the desktop this thread is on now, and its name
    static ON: RefCell<Option<(HDESK, String)>> = const { RefCell::new(None) };
    /// when this thread last looked whether the input moved (`input_moved`)
    static LOOKED: std::cell::Cell<Option<std::time::Instant>> = const { std::cell::Cell::new(None) };
}

/// The input went to another desktop than this thread's (Ctrl+Alt+Del or a UAC prompt to the secure desktop, and back): a capture made
/// on the old one gets nothing more and must be made again. Looks at most every 250 ms. Agent only.
pub fn input_moved() -> bool {
    if !agent() {
        return false;
    }
    let now = std::time::Instant::now();
    if LOOKED.get().is_some_and(|t| now.duration_since(t) < std::time::Duration::from_millis(250)) {
        return false;
    }
    LOOKED.set(Some(now));
    let Some(input) = input_name() else { return false };
    ON.with(|o| o.borrow().as_ref().is_some_and(|(_, on)| *on != input))
}

/// The input desktop's name: "Default", "Winlogon", "Screen-saver"…; None when it can't be opened (a user host on the secure desktop).
pub fn input_name() -> Option<String> {
    unsafe {
        let d = OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_ACCESS_FLAGS(0x0001)).ok()?;
        let n = name(d);
        let _ = CloseDesktop(d);
        n
    }
}

unsafe fn name(d: HDESK) -> Option<String> {
    let mut buf = [0u16; 128];
    let mut needed = 0u32;
    GetUserObjectInformationW(HANDLE(d.0), UOI_NAME, Some(buf.as_mut_ptr().cast()), (buf.len() * 2) as u32, Some(&mut needed)).ok()?;
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    Some(String::from_utf16_lossy(&buf[..len]))
}

/// Moves the calling thread onto the desktop that has the input, if it isn't there already. True when it moved (a capture made on
/// the old desktop must be made again). Agent only; a thread with windows or hooks of its own can't move and stays.
pub fn follow_input() -> bool {
    if !agent() {
        return false;
    }
    unsafe {
        const GENERIC_ALL: u32 = 0x1000_0000;
        let Ok(d) = OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_ACCESS_FLAGS(GENERIC_ALL)) else { return false };
        let Some(n) = name(d) else {
            let _ = CloseDesktop(d);
            return false;
        };
        let same = ON.with(|o| o.borrow().as_ref().is_some_and(|(_, on)| *on == n));
        if same {
            let _ = CloseDesktop(d);
            return false;
        }
        if let Err(e) = SetThreadDesktop(d) {
            note(&format!("can't move to {n}: {e}"));
            let _ = CloseDesktop(d);
            return false;
        }
        note(&format!("moved to {n}"));
        // the one it was on can go now (closing the thread's own desktop would fail)
        if let Some((old, _)) = ON.with(|o| o.borrow_mut().replace((d, n))) {
            let _ = CloseDesktop(old);
        }
        true
    }
}
