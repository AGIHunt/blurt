//! Recording through `record.py start --engine ffmpeg --status-jsonl` (§5 C8): this module spawns it, turns its
//! stdout into [`StatusEvent`]s and controls it through the session's `.cmd` file — the same channel as
//! `record.py stop|pause|resume|snap|discard`, so a take started here can also be stopped from the chat.

use crate::region::Region;
use crate::status::StatusEvent;
use std::collections::VecDeque;
use std::ffi::OsString;
use std::fmt;
use std::fs::OpenOptions;
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// How to run `record.py`: `program args… record.py <subcommand> …`.
#[derive(Debug, Clone)]
pub struct Launcher {
    pub program: PathBuf,
    /// Everything before record.py's own arguments, ending with the path to record.py.
    pub args: Vec<OsString>,
}

impl Launcher {
    /// `uv run -q record.py …` (resolves record.py's inline dependencies; needed for the microphone).
    pub fn uv(uv: impl Into<PathBuf>, record_py: impl AsRef<Path>) -> Self {
        let args = vec!["run".into(), "-q".into(), record_py.as_ref().as_os_str().to_owned()];
        Self { program: uv.into(), args }
    }

    /// `python record.py …` — enough without a microphone (`--no-mic` needs only the standard library + ffmpeg).
    pub fn python(python: impl Into<PathBuf>, record_py: impl AsRef<Path>) -> Self {
        Self { program: python.into(), args: vec![record_py.as_ref().as_os_str().to_owned()] }
    }

    /// uv on PATH, else `~/.blurt/bin/uv` (where onboarding installs it), else python3 / python on PATH.
    pub fn detect(record_py: impl AsRef<Path>) -> Option<Self> {
        let exe = |n: &str| if cfg!(windows) { format!("{n}.exe") } else { n.to_string() };
        if let Some(uv) = which(&exe("uv")) {
            return Some(Self::uv(uv, record_py));
        }
        let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from);
        if let Some(uv) = home.map(|h| h.join(".blurt").join("bin").join(exe("uv"))).filter(|p| p.is_file()) {
            return Some(Self::uv(uv, record_py));
        }
        ["python3", "python"].iter().find_map(|p| which(&exe(p))).map(|py| Self::python(py, record_py))
    }
}

fn which(name: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?).map(|d| d.join(name)).find(|p| p.is_file())
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum Mic {
    /// The default (non-virtual) input device.
    #[default]
    Default,
    /// Name substring or index, as `record.py devices` lists them.
    Named(String),
    /// Video only.
    None,
}

#[derive(Debug, Clone)]
pub struct CaptureOptions {
    pub launcher: Launcher,
    pub session: PathBuf,
    /// Physical px of the virtual desktop; `None` = the whole screen.
    pub region: Option<Region>,
    pub screen: Option<u32>,
    pub mic: Mic,
    pub fps: Option<u32>,
    pub max_width: Option<u32>,
    pub max_minutes: Option<f64>,
    /// Extra environment for record.py (e.g. BLURT_HOME).
    pub env: Vec<(OsString, OsString)>,
}

impl CaptureOptions {
    pub fn new(launcher: Launcher, session: impl Into<PathBuf>) -> Self {
        Self {
            launcher,
            session: session.into(),
            region: None,
            screen: None,
            mic: Mic::Default,
            fps: None,
            max_width: None,
            max_minutes: None,
            env: Vec::new(),
        }
    }

    /// The full argv after the program (for logs and tests).
    pub fn args(&self) -> Vec<OsString> {
        let mut a = self.launcher.args.clone();
        let s = |v: &str| OsString::from(v);
        a.extend([s("start"), s("--engine"), s("ffmpeg"), s("--session")]);
        a.push(self.session.as_os_str().to_owned());
        if let Some(r) = self.region {
            a.push(s(&format!("--region={}", r.even()))); // `=`: argparse would take "-10,…" for an option
        }
        if let Some(n) = self.screen {
            a.extend([s("--screen"), s(&n.to_string())]);
        }
        match &self.mic {
            Mic::Default => {}
            Mic::Named(m) => a.extend([s("--mic"), s(m)]),
            Mic::None => a.push(s("--no-mic")),
        }
        if let Some(v) = self.fps {
            a.extend([s("--fps"), s(&v.to_string())]);
        }
        if let Some(v) = self.max_width {
            a.extend([s("--max-width"), s(&v.to_string())]);
        }
        if let Some(v) = self.max_minutes {
            a.extend([s("--max-minutes"), s(&v.to_string())]);
        }
        a.push(s("--status-jsonl"));
        a
    }
}

#[derive(Debug)]
pub enum CaptureError {
    Io(io::Error),
    /// The recorder ended without a final status line (stderr tail).
    Recorder(String),
    Timeout,
}

impl fmt::Display for CaptureError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CaptureError::Io(e) => write!(f, "recorder: {e}"),
            CaptureError::Recorder(m) => write!(f, "recorder failed: {m}"),
            CaptureError::Timeout => write!(f, "recorder did not finish in time"),
        }
    }
}

impl std::error::Error for CaptureError {}

impl From<io::Error> for CaptureError {
    fn from(e: io::Error) -> Self {
        CaptureError::Io(e)
    }
}

/// Where a take is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CaptureState {
    Starting,
    Recording,
    Paused,
    Finished,
}

type Listener = Box<dyn FnMut(&StatusEvent) + Send>;

#[derive(Default)]
struct Shared {
    state: Option<CaptureState>,
    last_final: Option<StatusEvent>,
    stderr: VecDeque<String>,
}

/// A running `record.py` take. Dropping it while it records sends `stop` (the take is kept, never lost).
pub struct CaptureHandle {
    child: Option<Child>,
    session: PathBuf,
    shared: Arc<Mutex<Shared>>,
    readers: Vec<JoinHandle<()>>,
}

/// Spawns the recorder. `on_event` is called from a reader thread for every status line, in order.
pub fn start(opts: &CaptureOptions, on_event: impl FnMut(&StatusEvent) + Send + 'static) -> Result<CaptureHandle, CaptureError> {
    std::fs::create_dir_all(&opts.session)?;
    let session = std::fs::canonicalize(&opts.session)?;
    let mut opts = opts.clone();
    opts.session = session.clone();
    let mut cmd = Command::new(&opts.launcher.program);
    cmd.args(opts.args())
        .envs(opts.env.iter().map(|(k, v)| (k, v)))
        // status lines carry paths: UTF-8 whatever the console code page (Windows pipes default to it)
        .env("PYTHONIOENCODING", "utf-8")
        .env("PYTHONUTF8", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW: no console flashing up
    }
    let mut child = cmd.spawn()?;
    let shared = Arc::new(Mutex::new(Shared { state: Some(CaptureState::Starting), ..Default::default() }));
    let stdout = child.stdout.take().expect("piped");
    let stderr = child.stderr.take().expect("piped");
    let mut listener: Listener = Box::new(on_event);
    let sh = shared.clone();
    let out_reader = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            let Some(ev) = StatusEvent::parse(&line) else { continue };
            {
                let mut s = sh.lock().unwrap();
                match &ev {
                    StatusEvent::Started { .. } | StatusEvent::Resumed { .. } => s.state = Some(CaptureState::Recording),
                    StatusEvent::Paused { .. } => s.state = Some(CaptureState::Paused),
                    e if e.is_final() => {
                        s.state = Some(CaptureState::Finished);
                        s.last_final = Some(e.clone());
                    }
                    _ => {}
                }
            }
            listener(&ev);
        }
    });
    let sh = shared.clone();
    let err_reader = thread::spawn(move || {
        for line in BufReader::new(stderr).lines() {
            let Ok(line) = line else { break };
            let mut s = sh.lock().unwrap();
            s.stderr.push_back(line);
            if s.stderr.len() > 40 {
                s.stderr.pop_front();
            }
        }
    });
    Ok(CaptureHandle { child: Some(child), session, shared, readers: vec![out_reader, err_reader] })
}

impl CaptureHandle {
    pub fn session(&self) -> &Path {
        &self.session
    }

    pub fn pid(&self) -> Option<u32> {
        self.child.as_ref().map(|c| c.id())
    }

    pub fn state(&self) -> CaptureState {
        self.shared.lock().unwrap().state.unwrap_or(CaptureState::Starting)
    }

    /// Appends one command to `<session>/.cmd` in a single write (record.py polls it every 100 ms).
    pub fn send(&self, command: &str) -> io::Result<()> {
        let mut f = OpenOptions::new().create(true).append(true).open(self.session.join(".cmd"))?;
        f.write_all(format!("{command}\n").as_bytes())
    }

    pub fn pause(&self) -> io::Result<()> {
        self.send("pause")
    }

    pub fn resume(&self) -> io::Result<()> {
        self.send("resume")
    }

    /// A full-resolution still now → `shots/NNN.png`; a `Snap` event follows once it is on disk.
    pub fn snap(&self) -> io::Result<()> {
        self.send("snap")
    }

    /// Asks the recorder to finish and keep the take; [`CaptureHandle::wait`] returns the `Stopped` line.
    pub fn stop(&self) -> io::Result<()> {
        self.send("stop")
    }

    pub fn discard(&self) -> io::Result<()> {
        self.send("discard")
    }

    /// The recorder process has exited.
    pub fn is_finished(&mut self) -> bool {
        !matches!(self.child.as_mut().map(|c| c.try_wait()), Some(Ok(None)))
    }

    /// Waits for the recorder to exit; returns its final line (`Stopped` / `Discarded` / `Error`).
    pub fn wait(&mut self, timeout: Duration) -> Result<StatusEvent, CaptureError> {
        let t0 = Instant::now();
        let child = self.child.as_mut().ok_or(CaptureError::Timeout)?;
        loop {
            if child.try_wait()?.is_some() {
                break;
            }
            if t0.elapsed() > timeout {
                return Err(CaptureError::Timeout);
            }
            thread::sleep(Duration::from_millis(50));
        }
        for r in self.readers.drain(..) {
            let _ = r.join();
        }
        self.child = None;
        let s = self.shared.lock().unwrap();
        match &s.last_final {
            Some(e) => Ok(e.clone()),
            None => Err(CaptureError::Recorder(s.stderr.iter().cloned().collect::<Vec<_>>().join("\n"))),
        }
    }

    /// `stop` + `wait`.
    pub fn stop_and_wait(&mut self, timeout: Duration) -> Result<StatusEvent, CaptureError> {
        self.stop()?;
        self.wait(timeout)
    }

    /// Last lines the recorder wrote to stderr (diagnostics).
    pub fn stderr_tail(&self) -> String {
        self.shared.lock().unwrap().stderr.iter().cloned().collect::<Vec<_>>().join("\n")
    }

    /// Hard stop (the take is lost); for a recorder that no longer reacts.
    pub fn kill(&mut self) -> io::Result<()> {
        match self.child.as_mut() {
            Some(c) => c.kill(),
            None => Ok(()),
        }
    }
}

impl Drop for CaptureHandle {
    fn drop(&mut self) {
        if !self.is_finished() {
            let _ = self.stop();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn argv() {
        let mut o = CaptureOptions::new(Launcher::uv("uv", "/s/record.py"), "/tmp/s");
        o.region = Some(Region::new(-10, 20, 321, 241));
        o.mic = Mic::None;
        o.fps = Some(15);
        let a: Vec<String> = o.args().into_iter().map(|s| s.into_string().unwrap()).collect();
        assert_eq!(
            a.join(" "),
            "run -q /s/record.py start --engine ffmpeg --session /tmp/s --region=-10,20,320,240 --no-mic --fps 15 --status-jsonl"
        );
        let p = Launcher::python("python3", "/s/record.py");
        assert_eq!(p.args, vec![OsString::from("/s/record.py")]);
    }
}
