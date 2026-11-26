//! Files and the clipboard's content between any two ends (docs/design/remote-files.md, remote-protocol.md §Clipboard and files): the
//! Windows / Linux port of BlurtRemoteKit/RemoteFiles.swift, for this host and the desktop app's viewer. A sender goes one file at a
//! time, a chunk at a time, never more than `WINDOW` past what the receiver says it has written; a receiver writes a part, keeps it an
//! hour if the session drops, and goes on from there when the same file begins again. Nothing here knows which way the wire's enums
//! point: callers map `FileOut` and `FileAnswer` onto ToMac / ToPhone (the `From` impls below).
//!
//! Files land in the folder the caller names (Downloads/Blurt), with the Mark of the Web on Windows so they never run without the
//! usual warning. Names lose any folder part, `:` and leading dots; a name in use gets " 2", " 3" ….
use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::wire::{ToMac, ToPhone};

pub const CHUNK: usize = 192 * 1024;
/// at most this much past the receiver's last progress: with a peer that doesn't resume (which says how far it has got every 1 MiB)
/// always, otherwise the most the window grows to
pub const WINDOW: i64 = 4 << 20;
/// a peer that resumes keeps only about `WINDOW_MILLISECONDS` of the measured rate unacknowledged, at least this: the control messages
/// sent behind file data (pings, keys) wait no longer than that (Android measured drops every 2.5 s at 1.5 MB/s with a fixed 4 MiB)
pub const MIN_WINDOW: i64 = 512 << 10;
pub const WINDOW_MILLISECONDS: i64 = 500;
/// a receiver that resumes says how far it has got this often; one that doesn't, every `OLD_PROGRESS_EVERY`
pub const PROGRESS_EVERY: i64 = 256 << 10;
pub const OLD_PROGRESS_EVERY: i64 = 1 << 20;

/// How much may be unacknowledged now, from the rate the receiver's progress shows (bytes/s; None before any), for a peer that resumes
/// (RemoteFiles.window(rate:resumes:)).
pub fn window(rate: Option<f64>, resumes: bool) -> i64 {
    if !resumes {
        return WINDOW;
    }
    match rate {
        Some(r) if r > 0.0 => ((r * WINDOW_MILLISECONDS as f64 / 1000.0) as i64).clamp(MIN_WINDOW, WINDOW),
        _ => MIN_WINDOW,
    }
}
pub const MAX_SIZE: i64 = 4 << 30;
pub const MAX_COUNT: usize = 1000;
/// an image the phone pastes
pub const MAX_CLIP_IMAGE: i64 = 20 << 20;
/// a dropped file's part waits this long for the same file to begin again
pub const KEEP_PARTS: Duration = Duration::from_secs(3600);
/// a sender that sees `resume` waits this long for the receiver to say where to start
pub const RESUME_WAIT: Duration = Duration::from_secs(10);
/// the receiver keeps this much free beyond the file
pub const SPARE: i64 = 256 << 20;
/// a phone on mobile data asks before more than this goes either way
pub const ASK_ON_CELLULAR: i64 = 100_000_000;
/// a receiver that hasn't moved for this long while the sender waits on it: given up (`other`)
const STALLED: Duration = Duration::from_secs(60);

pub const IMAGE_EXTENSIONS: [&str; 10] = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"];

fn ext(name: &str) -> String {
    Path::new(name).extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default()
}

pub fn is_image(name: &str) -> bool {
    IMAGE_EXTENSIONS.contains(&ext(name).as_str())
}

/// A name to write under: no folders, no `:` (nor anything else Windows can't hold), no control characters, no hidden or empty names,
/// at most 200 characters (RemoteFiles.clean, plus Windows' own rules).
pub fn clean(name: &str) -> String {
    let base = name.replace('\\', "/");
    let base = base.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    let n: String = base
        .chars()
        .filter(|c| !c.is_control())
        .map(|c| if "<>:\"|?*".contains(c) { '-' } else { c })
        .collect();
    let n = n.trim().trim_start_matches('.').trim_end_matches(['.', ' ']).trim();
    if n.is_empty() {
        return "file".into();
    }
    n.chars().take(200).collect()
}

/// `p`, or the first of "name 2.ext", "name 3.ext" … not taken.
pub fn unique(p: &Path) -> PathBuf {
    if !p.exists() {
        return p.to_path_buf();
    }
    let stem = p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = p.extension().map(|e| e.to_string_lossy().into_owned());
    for i in 2..100_000 {
        let n = match &ext {
            Some(e) => format!("{stem} {i}.{e}"),
            None => format!("{stem} {i}"),
        };
        let c = p.with_file_name(n);
        if !c.exists() {
            return c;
        }
    }
    p.to_path_buf()
}

/// `want`, or "name 2.ext", "name 3.ext" …: the first that doesn't exist.
fn candidate(want: &Path, i: u32) -> PathBuf {
    if i < 2 {
        return want.to_path_buf();
    }
    let stem = want.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    match want.extension() {
        Some(e) => want.with_file_name(format!("{stem} {i}.{}", e.to_string_lossy())),
        None => want.with_file_name(format!("{stem} {i}")),
    }
}

/// Puts the file at `from` in place at `want` under a name nothing else holds, never over a file made meanwhile: a hard link (no-replace,
/// and atomic), or where the volume can't (another volume, FAT), a file created new and copied into. The caller deletes `from`.
fn place(from: &Path, want: &Path) -> Option<PathBuf> {
    let mut links = true;
    for i in 1..100_000 {
        let c = candidate(want, i);
        if links {
            match std::fs::hard_link(from, &c) {
                Ok(()) => return Some(c),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(_) => links = false,
            }
        }
        match std::fs::OpenOptions::new().write(true).create_new(true).open(&c) {
            Ok(mut out) => {
                let ok = std::fs::File::open(from).and_then(|mut f| std::io::copy(&mut f, &mut out)).is_ok();
                if ok {
                    return Some(c);
                }
                drop(out);
                let _ = std::fs::remove_file(&c);
                return None;
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => return None,
        }
    }
    None
}

/// Windows: the Mark of the Web (zone 3, the Internet), as a browser's download has. Elsewhere nothing: the file isn't executable.
pub fn mark_downloaded(p: &Path) {
    if cfg!(windows) {
        let mut ads = p.as_os_str().to_owned();
        ads.push(":Zone.Identifier");
        let _ = std::fs::write(PathBuf::from(ads), b"[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=about:internet\r\n");
    }
}

/// Free bytes on the volume holding `p` (i64::MAX when it can't be told).
pub fn free_space(p: &Path) -> i64 {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let Ok(c) = std::ffi::CString::new(p.as_os_str().as_bytes()) else { return i64::MAX };
        let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statvfs(c.as_ptr(), &mut s) } == 0 {
            return (s.f_bavail as u128 * s.f_frsize as u128).min(i64::MAX as u128) as i64;
        }
        i64::MAX
    }
    #[cfg(windows)]
    {
        use ::windows::core::HSTRING;
        use ::windows::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
        let mut free = 0u64;
        if unsafe { GetDiskFreeSpaceExW(&HSTRING::from(p.as_os_str()), Some(&mut free), None, None) }.is_ok() {
            return free.min(i64::MAX as u64) as i64;
        }
        i64::MAX
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = p;
        i64::MAX
    }
}

/// A folder as a zip file (stored, not compressed: what's in folders is mostly compressed already, and it's quick), named after it,
/// in a temporary folder of its own. None: it can't be read, or the zip can't be written.
pub fn zip_folder(folder: &Path) -> Option<PathBuf> {
    let name = folder.file_name()?.to_string_lossy().into_owned();
    let dir = std::env::temp_dir().join(format!("blurt-zip-{}", crate::crypto::new_id()));
    std::fs::create_dir_all(&dir).ok()?;
    let dest = dir.join(format!("{}.zip", clean(&name)));
    let out = std::fs::File::create(&dest).ok()?;
    let mut z = zip::ZipWriter::new(std::io::BufWriter::new(out));
    let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored).large_file(true);
    fn walk(z: &mut zip::ZipWriter<std::io::BufWriter<std::fs::File>>, at: &Path, inside: &str, opts: zip::write::SimpleFileOptions) -> Option<()> {
        let mut list: Vec<_> = std::fs::read_dir(at).ok()?.filter_map(|e| e.ok()).collect();
        list.sort_by_key(|e| e.file_name());
        for e in list {
            let n = format!("{inside}{}", e.file_name().to_string_lossy());
            let t = e.file_type().ok()?;
            if t.is_symlink() {
                continue; // nothing from outside the folder
            }
            if t.is_dir() {
                z.add_directory(format!("{n}/"), opts).ok()?;
                walk(z, &e.path(), &format!("{n}/"), opts)?;
            } else if t.is_file() {
                z.start_file(n, opts).ok()?;
                let mut f = std::fs::File::open(e.path()).ok()?;
                std::io::copy(&mut f, z).ok()?;
            }
        }
        Some(())
    }
    let ok = walk(&mut z, folder, &format!("{}/", clean(&name)), opts).is_some() && z.finish().is_ok();
    if !ok {
        let _ = std::fs::remove_dir_all(&dir);
        return None;
    }
    Some(dest)
}

/// What a sender sends for what the user picked: folders become zip files (temporary: deleted once sent), files stay. A folder that
/// can't be zipped is left out. Synchronous: run it off the UI's thread.
pub fn prepare(paths: &[PathBuf]) -> Vec<(PathBuf, bool)> {
    paths
        .iter()
        .filter_map(|p| match std::fs::metadata(p) {
            Ok(m) if m.is_dir() => zip_folder(p).map(|z| (z, true)),
            Ok(_) => Some((p.clone(), false)),
            Err(_) => None,
        })
        .collect()
}

/// The bytes these would send: files as they are, folders as everything in them (their zip stores, not compresses). Links aren't
/// followed.
pub fn size_of(paths: &[PathBuf]) -> i64 {
    fn walk(p: &Path, depth: u32) -> i64 {
        match std::fs::symlink_metadata(p) {
            Ok(m) if m.is_dir() && depth < 64 => std::fs::read_dir(p).map(|d| d.flatten().map(|e| walk(&e.path(), depth + 1)).sum()).unwrap_or(0),
            Ok(m) if m.is_file() => m.len() as i64,
            _ => 0,
        }
    }
    paths.iter().map(|p| walk(p, 0)).sum()
}

/// Bytes a second from what moved lately: None until two samples 0.2 s apart.
fn rate(samples: &[(Instant, i64)]) -> Option<f64> {
    let (first, last) = (samples.first()?, samples.last()?);
    let span = last.0.duration_since(first.0).as_secs_f64();
    if span < 0.2 || last.1 <= first.1 {
        return None;
    }
    Some((last.1 - first.1) as f64 / span)
}

/// Seconds left from what moved lately: None until 2 s of progress.
fn left(samples: &[(Instant, i64)], size: i64) -> Option<f64> {
    let (first, last) = (samples.first()?, samples.last()?);
    let span = last.0.duration_since(first.0).as_secs_f64();
    if span < 2.0 || last.1 <= first.1 {
        return None;
    }
    let rate = (last.1 - first.1) as f64 / span;
    Some((size - last.1).max(0) as f64 / rate)
}

fn sample(samples: &mut Vec<(Instant, i64)>, bytes: i64) {
    let now = Instant::now();
    samples.push((now, bytes));
    samples.retain(|s| now.duration_since(s.0) <= Duration::from_secs(5));
}

// ------------------------------------------------------------------ what goes on the wire

/// A file's begin, either way: ToMac.fileBegin / ToPhone.fileBegin.
#[derive(Clone, Debug, PartialEq)]
pub struct FileInfo {
    pub id: String,
    pub name: String,
    pub size: i64,
    pub clip: bool,
    pub index: Option<i64>,
    pub count: Option<i64>,
    pub total: Option<i64>,
}

/// What a sender puts on the wire.
#[derive(Clone, Debug, PartialEq)]
pub enum FileOut {
    Begin(FileInfo),
    Chunk { id: String, data: Vec<u8> },
    End { id: String },
}

/// What a receiver answers.
#[derive(Clone, Debug, PartialEq)]
pub enum FileAnswer {
    Progress { id: String, bytes: i64 },
    Saved { id: String, name: String },
    Failed { id: String, why: String },
}

impl From<FileOut> for ToMac {
    fn from(o: FileOut) -> ToMac {
        match o {
            FileOut::Begin(i) => ToMac::FileBegin { id: i.id, name: i.name, size: i.size, clip: i.clip.then_some(true), index: i.index, count: i.count, total: i.total },
            FileOut::Chunk { id, data } => ToMac::FileChunk { id, data },
            FileOut::End { id } => ToMac::FileEnd { id },
        }
    }
}

impl From<FileAnswer> for ToMac {
    fn from(a: FileAnswer) -> ToMac {
        match a {
            FileAnswer::Progress { id, bytes } => ToMac::FileProgress { id, bytes },
            FileAnswer::Saved { id, name } => ToMac::FileSaved { id, name },
            FileAnswer::Failed { id, why } => ToMac::FileFailed { id, why },
        }
    }
}

impl From<FileOut> for ToPhone {
    fn from(o: FileOut) -> ToPhone {
        match o {
            FileOut::Begin(i) => ToPhone::FileBegin { id: i.id, name: i.name, size: i.size, clip: i.clip.then_some(true), index: i.index, count: i.count, total: i.total },
            FileOut::Chunk { id, data } => ToPhone::FileChunk { id, data },
            FileOut::End { id } => ToPhone::FileEnd { id },
        }
    }
}

impl From<FileAnswer> for ToPhone {
    fn from(a: FileAnswer) -> ToPhone {
        match a {
            FileAnswer::Progress { id, bytes } => ToPhone::FileProgress { id, bytes },
            FileAnswer::Saved { id, name } => ToPhone::FileSaved { id, name },
            FileAnswer::Failed { id, why } => ToPhone::FileFailed { id, why },
        }
    }
}

impl ToMac {
    /// A file going to the host, as the engine sees it (None for anything else).
    pub fn file_out(&self) -> Option<FileOut> {
        Some(match self.clone() {
            ToMac::FileBegin { id, name, size, clip, index, count, total } => FileOut::Begin(FileInfo { id, name, size, clip: clip == Some(true), index, count, total }),
            ToMac::FileChunk { id, data } => FileOut::Chunk { id, data },
            ToMac::FileEnd { id } => FileOut::End { id },
            _ => return None,
        })
    }
    /// The phone's or viewer's answer to a file from the host.
    pub fn file_answer(&self) -> Option<FileAnswer> {
        Some(match self.clone() {
            ToMac::FileProgress { id, bytes } => FileAnswer::Progress { id, bytes },
            ToMac::FileSaved { id, name } => FileAnswer::Saved { id, name },
            ToMac::FileFailed { id, why } => FileAnswer::Failed { id, why },
            _ => return None,
        })
    }
}

impl ToPhone {
    /// A file from the host, as the engine sees it.
    pub fn file_out(&self) -> Option<FileOut> {
        Some(match self.clone() {
            ToPhone::FileBegin { id, name, size, clip, index, count, total } => FileOut::Begin(FileInfo { id, name, size, clip: clip == Some(true), index, count, total }),
            ToPhone::FileChunk { id, data } => FileOut::Chunk { id, data },
            ToPhone::FileEnd { id } => FileOut::End { id },
            _ => return None,
        })
    }
    /// The host's answer to a file sent to it.
    pub fn file_answer(&self) -> Option<FileAnswer> {
        Some(match self.clone() {
            ToPhone::FileProgress { id, bytes } => FileAnswer::Progress { id, bytes },
            ToPhone::FileSaved { id, name } => FileAnswer::Saved { id, name },
            ToPhone::FileFailed { id, why } => FileAnswer::Failed { id, why },
            _ => return None,
        })
    }
}

// ------------------------------------------------------------------ a transfer, for a list or a card

#[derive(Clone, Debug, PartialEq)]
pub enum State {
    /// not begun: behind another file, or until the session is up (and its stream has moved)
    Waiting,
    Going,
    /// the session dropped: it goes on from `done` when it's back
    Paused,
    Done,
    /// "space", "too_big", "write", "locked", "read", "stopped", "other"
    Failed(String),
}

/// One transfer as a list or a card shows it, either way.
#[derive(Clone, Debug, PartialEq)]
pub struct Transfer {
    pub id: String,
    pub name: String,
    pub size: i64,
    /// written at the other end (sending) or here (receiving)
    pub done: i64,
    pub incoming: bool,
    pub clip: bool,
    pub state: State,
    pub index: Option<i64>,
    pub count: Option<i64>,
    /// receiving: where it was saved; sending: the file read
    pub path: Option<PathBuf>,
    pub seconds_left: Option<f64>,
}

impl Transfer {
    pub fn is_over(&self) -> bool {
        matches!(self.state, State::Done | State::Failed(_))
    }

    /// For a webview: `{id, name, size, done, incoming, clip, state, why?, index?, count?, path?, secondsLeft?}`.
    pub fn to_json(&self) -> Value {
        let (state, why) = match &self.state {
            State::Waiting => ("waiting", None),
            State::Going => ("going", None),
            State::Paused => ("paused", None),
            State::Done => ("done", None),
            State::Failed(w) => ("failed", Some(w.clone())),
        };
        json!({"id": self.id, "name": self.name, "size": self.size, "done": self.done, "incoming": self.incoming, "clip": self.clip,
               "state": state, "why": why, "index": self.index, "count": self.count,
               "path": self.path.as_ref().map(|p| p.to_string_lossy().into_owned()), "secondsLeft": self.seconds_left})
    }
}

// ------------------------------------------------------------------ sending

type SendFn = Box<dyn Fn(FileOut) -> bool + Send + Sync>;
type AskFn = Box<dyn Fn() -> bool + Send + Sync>;
type ChangeFn = Box<dyn Fn(&Transfer) + Send + Sync>;

struct Item {
    t: Transfer,
    source: PathBuf,
    /// a temporary file (a zip, a clipboard's image) to delete once over
    temporary: bool,
    /// the batch's bytes, said with each of its begins
    total: Option<i64>,
    acked: Option<i64>,
    heard_since: bool,
    samples: Vec<(Instant, i64)>,
    paused_at: Option<Instant>,
}

struct SendState {
    items: Vec<Item>,
    running: bool,
    up: bool,
}

struct SendInner {
    st: Mutex<SendState>,
    cv: Condvar,
    send: SendFn,
    ready: AskFn,
    peer_resumes: AskFn,
    change: ChangeFn,
}

/// Sends files one at a time, in the order asked, on a thread of its own. `send` puts a message on the wire and says false when there's
/// no session to put it on; `ready` says whether files may go now (a session is up and, on the public connection service, its stream
/// has moved); `peer_resumes`: the receiver named `resume`. Call `heard` with the receiver's answers and `connection` when the session
/// drops or is back.
#[derive(Clone)]
pub struct Sender {
    inner: Arc<SendInner>,
}

impl Sender {
    pub fn new(
        send: impl Fn(FileOut) -> bool + Send + Sync + 'static,
        ready: impl Fn() -> bool + Send + Sync + 'static,
        peer_resumes: impl Fn() -> bool + Send + Sync + 'static,
        change: impl Fn(&Transfer) + Send + Sync + 'static,
    ) -> Sender {
        Sender {
            inner: Arc::new(SendInner {
                st: Mutex::new(SendState { items: vec![], running: false, up: true }),
                cv: Condvar::new(),
                send: Box::new(send),
                ready: Box::new(ready),
                peer_resumes: Box::new(peer_resumes),
                change: Box::new(change),
            }),
        }
    }

    pub fn transfers(&self) -> Vec<Transfer> {
        self.inner.st.lock().unwrap().items.iter().map(|i| i.t.clone()).collect()
    }

    /// Queue files: (path, temporary: delete once over). `clip`: the clipboard's content (one file). Folders must already be zipped
    /// (`prepare`). Returns the transfers made, in order.
    pub fn add(&self, files: Vec<(PathBuf, bool)>, clip: bool) -> Vec<Transfer> {
        let sizes: Vec<i64> = files.iter().map(|(p, _)| std::fs::metadata(p).map(|m| m.len() as i64).unwrap_or(-1)).collect();
        let total: i64 = sizes.iter().map(|s| (*s).max(0)).sum();
        let many = files.len() > 1;
        let count = files.len() as i64;
        let made: Vec<Item> = files
            .into_iter()
            .zip(sizes)
            .enumerate()
            .map(|(i, ((p, temporary), size))| Item {
                t: Transfer {
                    id: crate::crypto::new_id(),
                    name: p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "file".into()),
                    size: size.max(0),
                    done: 0,
                    incoming: false,
                    clip,
                    state: State::Waiting,
                    index: many.then_some(i as i64 + 1),
                    count: many.then_some(count),
                    path: Some(p.clone()),
                    seconds_left: None,
                },
                source: p,
                temporary,
                total: many.then_some(total),
                acked: None,
                heard_since: false,
                samples: vec![],
                paused_at: None,
            })
            .collect();
        let out: Vec<Transfer> = made.iter().map(|i| i.t.clone()).collect();
        self.inner.st.lock().unwrap().items.extend(made);
        for t in &out {
            (self.inner.change)(t);
        }
        self.kick();
        out
    }

    /// × on one transfer, or on all of them (None).
    pub fn stop(&self, id: Option<&str>) {
        let mut changed = vec![];
        let mut ends = vec![];
        {
            let mut st = self.inner.st.lock().unwrap();
            for it in st.items.iter_mut().filter(|i| id.is_none_or(|x| i.t.id == x) && !i.t.is_over()) {
                if matches!(it.t.state, State::Going | State::Paused) {
                    ends.push(it.t.id.clone());
                }
                it.t.state = State::Failed("stopped".into());
                it.t.seconds_left = None;
                changed.push(it.t.clone());
            }
        }
        self.inner.cv.notify_all();
        // the receiver deletes what it had: a short end
        for e in ends {
            (self.inner.send)(FileOut::End { id: e });
        }
        for t in &changed {
            (self.inner.change)(t);
        }
        self.clean_up();
    }

    /// Done and failed ones leave the list.
    pub fn clear(&self) {
        self.inner.st.lock().unwrap().items.retain(|i| !i.t.is_over());
    }

    /// A paused or failed transfer goes again (Continue): from where the receiver has it, if it kept it.
    pub fn again(&self, id: &str) {
        let t = {
            let mut st = self.inner.st.lock().unwrap();
            let Some(it) = st.items.iter_mut().find(|i| i.t.id == id) else { return };
            if it.t.state == State::Done || it.t.state == State::Failed("stopped".into()) || !it.source.exists() {
                return;
            }
            it.t.state = State::Waiting;
            it.paused_at = None;
            it.t.clone()
        };
        (self.inner.change)(&t);
        self.kick();
    }

    pub fn heard(&self, a: FileAnswer) {
        let t = {
            let mut st = self.inner.st.lock().unwrap();
            let id = match &a {
                FileAnswer::Progress { id, .. } | FileAnswer::Saved { id, .. } | FileAnswer::Failed { id, .. } => id.clone(),
            };
            let Some(it) = st.items.iter_mut().find(|i| i.t.id == id && !i.t.is_over()) else { return };
            match a {
                FileAnswer::Progress { bytes, .. } => {
                    it.acked = Some(bytes);
                    it.heard_since = true;
                    it.t.done = bytes.min(it.t.size);
                    sample(&mut it.samples, bytes);
                    it.t.seconds_left = left(&it.samples, it.t.size);
                }
                FileAnswer::Saved { .. } => {
                    it.t.state = State::Done;
                    it.t.done = it.t.size;
                    it.t.seconds_left = None;
                }
                FileAnswer::Failed { why, .. } => {
                    it.t.state = State::Failed(why);
                    it.t.seconds_left = None;
                }
            }
            it.t.clone()
        };
        self.inner.cv.notify_all();
        (self.inner.change)(&t);
        if t.is_over() {
            self.clean_up();
        }
    }

    /// The session dropped (false) or is back (true). Dropped: the file going pauses where the receiver had it; back: paused ones go
    /// on by themselves, as long as they paused less than an hour ago.
    pub fn connection(&self, up: bool) {
        let mut changed = vec![];
        {
            let mut st = self.inner.st.lock().unwrap();
            st.up = up;
            for it in st.items.iter_mut() {
                if !up && it.t.state == State::Going {
                    it.t.state = State::Paused;
                    it.t.seconds_left = None;
                    it.paused_at = Some(Instant::now());
                    it.samples.clear();
                    changed.push(it.t.clone());
                } else if up && it.t.state == State::Paused {
                    it.t.state = if it.paused_at.is_some_and(|p| p.elapsed() > KEEP_PARTS) { State::Failed("other".into()) } else { State::Waiting };
                    changed.push(it.t.clone());
                }
            }
        }
        self.inner.cv.notify_all();
        for t in &changed {
            (self.inner.change)(t);
        }
        if up {
            self.kick();
        }
    }

    fn kick(&self) {
        {
            let mut st = self.inner.st.lock().unwrap();
            if st.running {
                return;
            }
            st.running = true;
        }
        let me = self.clone();
        let _ = std::thread::Builder::new().name("blurt-files-out".into()).spawn(move || me.run());
    }

    fn next(&self) -> Option<String> {
        let st = self.inner.st.lock().unwrap();
        if !st.up {
            return None;
        }
        st.items.iter().find(|i| i.t.state == State::Waiting).map(|i| i.t.id.clone())
    }

    fn run(&self) {
        while let Some(id) = self.next() {
            // the session must be up (and its stream moved) before a byte goes
            let since = Instant::now();
            while !(self.inner.ready)() {
                if !self.inner.st.lock().unwrap().up || since.elapsed() > Duration::from_secs(600) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            if !(self.inner.ready)() {
                break;
            }
            self.one(&id);
        }
        let again = {
            let mut st = self.inner.st.lock().unwrap();
            st.running = false;
            st.up && st.items.iter().any(|i| i.t.state == State::Waiting)
        };
        // something queued while the loop was ending, or not ready yet: look again shortly
        if again {
            let me = self.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(250));
                me.kick();
            });
        }
    }

    fn with<T>(&self, id: &str, f: impl FnOnce(&mut Item) -> T) -> Option<T> {
        let mut st = self.inner.st.lock().unwrap();
        st.items.iter_mut().find(|i| i.t.id == id).map(f)
    }

    fn publish(&self, id: &str) {
        if let Some(t) = self.with(id, |i| i.t.clone()) {
            (self.inner.change)(&t);
        }
    }

    /// Waits (on the receiver's answers) while `wait` holds, at most `most`. → whether it still holds.
    fn wait_while(&self, id: &str, most: Duration, wait: impl Fn(&Item) -> bool) -> bool {
        let end = Instant::now() + most;
        let mut st = self.inner.st.lock().unwrap();
        loop {
            let Some(it) = st.items.iter().find(|i| i.t.id == id) else { return false };
            if !wait(it) {
                return false;
            }
            let now = Instant::now();
            if now >= end {
                return true;
            }
            st = self.inner.cv.wait_timeout(st, (end - now).min(Duration::from_millis(200))).unwrap().0;
        }
    }

    fn one(&self, id: &str) {
        let Some((info, source)) = self.with(id, |it| {
            if it.t.state != State::Waiting {
                return None;
            }
            it.t.state = State::Going;
            it.acked = None;
            it.heard_since = false;
            it.samples.clear();
            let t = &it.t;
            Some((FileInfo { id: t.id.clone(), name: t.name.clone(), size: t.size, clip: t.clip, index: t.index, count: t.count, total: it.total }, it.source.clone()))
        })
        .flatten() else { return };
        self.publish(id);
        if info.size > MAX_SIZE {
            return self.finish(id, State::Failed("too_big".into()), false);
        }
        let Ok(mut f) = std::fs::File::open(&source) else { return self.finish(id, State::Failed("read".into()), false) };
        if !(self.inner.send)(FileOut::Begin(info.clone())) {
            return self.pause(id);
        }
        let mut sent = 0i64;
        let resumes = (self.inner.peer_resumes)();
        if resumes {
            // where the receiver has it: 0 for a new file
            if self.wait_while(id, RESUME_WAIT, |i| !i.heard_since && i.t.state == State::Going) {
                return self.finish(id, State::Failed("other".into()), true);
            }
            let Some((state, acked)) = self.with(id, |i| (i.t.state.clone(), i.acked)) else { return };
            if state != State::Going {
                return;
            }
            sent = acked.unwrap_or(0).clamp(0, info.size);
            if sent > 0 && f.seek(SeekFrom::Start(sent as u64)).is_err() {
                return self.finish(id, State::Failed("read".into()), true);
            }
        } else {
            self.with(id, |i| i.acked = Some(0));
        }
        let mut buf = vec![0u8; CHUNK];
        loop {
            // never more than WINDOW past what the receiver has written; a minute without it moving and it's given up
            if self.wait_while(id, STALLED, |i| i.t.state == State::Going && sent - i.acked.unwrap_or(0) > window(rate(&i.samples), resumes)) {
                return self.finish(id, State::Failed("other".into()), true);
            }
            match self.with(id, |i| i.t.state.clone()) {
                Some(State::Going) => {}
                // paused (the session dropped), stopped here (the short end went in stop) or refused there
                _ => return,
            }
            let n = match f.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(_) => return self.finish(id, State::Failed("read".into()), true),
            };
            if !(self.inner.send)(FileOut::Chunk { id: id.to_string(), data: buf[..n].to_vec() }) {
                return self.pause(id);
            }
            sent += n as i64;
        }
        if !(self.inner.send)(FileOut::End { id: id.to_string() }) {
            return self.pause(id);
        }
        // then the receiver's saved or failed; a drop before it pauses it, and the begin again finds it whole
        while self.wait_while(id, Duration::from_secs(1), |i| i.t.state == State::Going) {
            if !self.inner.st.lock().unwrap().up {
                break;
            }
        }
    }

    fn pause(&self, id: &str) {
        let t = self.with(id, |i| {
            if i.t.state != State::Going {
                return None;
            }
            i.t.state = State::Paused;
            i.paused_at = Some(Instant::now());
            i.t.seconds_left = None;
            Some(i.t.clone())
        });
        if let Some(Some(t)) = t {
            (self.inner.change)(&t);
        }
    }

    /// Over here: `wire` sends a short end so the receiver deletes its part.
    fn finish(&self, id: &str, s: State, wire: bool) {
        let t = self.with(id, |i| {
            i.t.state = s;
            i.t.seconds_left = None;
            i.t.clone()
        });
        if wire {
            (self.inner.send)(FileOut::End { id: id.to_string() });
        }
        if let Some(t) = t {
            (self.inner.change)(&t);
        }
        self.clean_up();
    }

    fn clean_up(&self) {
        let gone: Vec<PathBuf> = self.inner.st.lock().unwrap().items.iter().filter(|i| i.temporary && i.t.is_over()).map(|i| i.source.clone()).collect();
        for p in gone {
            let _ = std::fs::remove_file(&p);
            // a zip's or a clip's own temporary folder
            if let Some(d) = p.parent().filter(|d| d.file_name().is_some_and(|n| n.to_string_lossy().starts_with("blurt-"))) {
                let _ = std::fs::remove_dir(d);
            }
        }
    }
}

/// A temporary file holding `bytes` under `name` (the clipboard's image or long text), in a folder of its own: deleted once sent.
pub fn temporary(name: &str, bytes: &[u8]) -> Option<PathBuf> {
    let dir = std::env::temp_dir().join(format!("blurt-clip-{}", crate::crypto::new_id()));
    std::fs::create_dir_all(&dir).ok()?;
    let p = dir.join(name);
    std::fs::write(&p, bytes).ok()?;
    Some(p)
}

// ------------------------------------------------------------------ receiving

struct Part {
    device: String,
    id: String,
    name: String,
    size: i64,
    clip: bool,
    path: PathBuf,
    out: Option<std::fs::File>,
    written: i64,
    told: i64,
    index: Option<i64>,
    count: Option<i64>,
    kept_since: Option<Instant>,
    samples: Vec<(Instant, i64)>,
}

pub type SavedFn = Box<dyn Fn(&Path, &str) + Send + Sync>;
pub type ClipFn = Box<dyn Fn(&Path, &str, &str) + Send + Sync>;
pub type ReceiveChangeFn = Box<dyn Fn(&Transfer, &str) + Send + Sync>;
/// Clip files a test end got: (name, bytes).
pub type Clips = Arc<Mutex<Vec<(String, Vec<u8>)>>>;

/// What a receiver asks of the end it runs in. Called outside its locks.
pub struct Hooks {
    /// the screen is locked: nothing is taken
    pub locked: Box<dyn Fn() -> bool + Send + Sync>,
    /// a finished file, moved to its place (`device`: who sent it): notify (not for clip ones)
    pub saved: SavedFn,
    /// a `clip` file arrived (its part, its name, the device): put it on the clipboard. The part is deleted after this returns
    pub clip: ClipFn,
    pub change: ReceiveChangeFn,
}

impl Default for Hooks {
    fn default() -> Hooks {
        Hooks { locked: Box::new(|| false), saved: Box::new(|_, _| {}), clip: Box::new(|_, _, _| {}), change: Box::new(|_, _| {}) }
    }
}

/// Writes files as they arrive. Parts live in `parts` (this end's own folder); a finished file moves to `folder` under a name not
/// taken. One receiver serves every device a host knows (parts are keyed by device), or every computer a viewer shows.
pub struct Receiver {
    parts: Mutex<HashMap<String, Part>>,
    parts_dir: PathBuf,
    folder: PathBuf,
    /// answers every begin with where to start
    pub resumes: bool,
    hooks: Hooks,
}

impl Receiver {
    pub fn new(parts: PathBuf, folder: PathBuf, resumes: bool, hooks: Hooks) -> Receiver {
        let _ = std::fs::create_dir_all(&parts);
        // parts from an earlier run: their sessions can't come back
        if let Ok(old) = std::fs::read_dir(&parts) {
            for e in old.flatten() {
                if e.path().extension().is_some_and(|x| x == "part") {
                    let _ = std::fs::remove_file(e.path());
                }
            }
        }
        Receiver { parts: Mutex::new(HashMap::new()), parts_dir: parts, folder, resumes, hooks }
    }

    pub fn folder(&self) -> &Path {
        &self.folder
    }

    fn key(device: &str, id: &str) -> String {
        format!("{device}\u{1F}{id}")
    }

    /// One message about a file from `device`; `answer` goes back on the same session.
    pub fn heard(&self, m: FileOut, device: &str, answer: &mut dyn FnMut(FileAnswer)) {
        match m {
            FileOut::Begin(i) => self.begin(i, device, answer),
            FileOut::Chunk { id, data } => self.chunk(&id, &data, device, answer),
            FileOut::End { id } => self.end(&id, device, answer),
        }
    }

    fn begin(&self, i: FileInfo, device: &str, answer: &mut dyn FnMut(FileAnswer)) {
        self.expire();
        let k = Self::key(device, &i.id);
        let name = clean(&i.name);
        // locked: nothing is taken, not even the rest of a kept part (which stays for when it's open again)
        if (self.hooks.locked)() {
            return answer(FileAnswer::Failed { id: i.id.clone(), why: "locked".into() });
        }
        // the same file again after a drop: go on from what's written
        if self.resumes {
            let resumed = (|| {
                let mut parts = self.parts.lock().unwrap();
                let p = parts.get_mut(&k).filter(|p| p.name == name && p.size == i.size)?;
                if p.out.is_none() {
                    match std::fs::OpenOptions::new().append(true).open(&p.path) {
                        Ok(f) => {
                            let at = f.metadata().map(|m| m.len() as i64).unwrap_or(0);
                            p.out = Some(f);
                            p.written = at;
                            p.told = at;
                        }
                        Err(_) => {
                            parts.remove(&k);
                            return None;
                        }
                    }
                }
                p.kept_since = None;
                Some(Self::transfer(p, State::Going, None))
            })();
            if let Some(t) = resumed {
                answer(FileAnswer::Progress { id: i.id.clone(), bytes: t.done });
                (self.hooks.change)(&t, device);
                return;
            }
        }
        // another file from this device doesn't touch its others: a viewer's second window has the same device id and sends at the
        // same time. A part a sender gives up without an end waits as a dropped session's does, from when that session ends
        let fail = |answer: &mut dyn FnMut(FileAnswer), why: &str| answer(FileAnswer::Failed { id: i.id.clone(), why: why.into() });
        let cap = if i.clip { MAX_CLIP_IMAGE.max(64 << 20) } else { MAX_SIZE };
        if i.size < 0 || i.size > cap {
            return fail(answer, "too_big");
        }
        if !i.clip {
            let _ = std::fs::create_dir_all(&self.folder);
            if i.size >= free_space(&self.folder).saturating_sub(SPARE) {
                return fail(answer, "space");
            }
        }
        let path = self.parts_dir.join(format!("{}.part", crate::crypto::new_id()));
        let _ = std::fs::create_dir_all(&self.parts_dir);
        let out = match std::fs::File::create(&path) {
            Ok(f) => f,
            Err(e) if e.raw_os_error() == Some(28) || e.raw_os_error() == Some(112) => return fail(answer, "space"),
            Err(_) => return fail(answer, "write"),
        };
        let p = Part {
            device: device.into(),
            id: i.id.clone(),
            name,
            size: i.size,
            clip: i.clip,
            path,
            out: Some(out),
            written: 0,
            told: 0,
            index: i.index,
            count: i.count,
            kept_since: None,
            samples: vec![],
        };
        let t = Self::transfer(&p, State::Going, None);
        self.parts.lock().unwrap().insert(k, p);
        if self.resumes {
            answer(FileAnswer::Progress { id: i.id.clone(), bytes: 0 });
        }
        (self.hooks.change)(&t, device);
    }

    fn chunk(&self, id: &str, data: &[u8], device: &str, answer: &mut dyn FnMut(FileAnswer)) {
        let k = Self::key(device, id);
        let mut parts = self.parts.lock().unwrap();
        // under the lock: a part a stop or a drop has just closed (or kept) takes nothing more
        let Some(p) = parts.get_mut(&k).filter(|p| p.kept_since.is_none()) else { return };
        let Some(out) = p.out.as_mut() else { return };
        if p.written + data.len() as i64 > p.size || out.write_all(data).is_err() {
            let p = parts.remove(&k).unwrap();
            drop(parts);
            let _ = std::fs::remove_file(&p.path);
            answer(FileAnswer::Failed { id: id.into(), why: "write".into() });
            (self.hooks.change)(&Self::transfer(&p, State::Failed("write".into()), None), device);
            return;
        }
        p.written += data.len() as i64;
        if p.written - p.told >= if self.resumes { PROGRESS_EVERY } else { OLD_PROGRESS_EVERY } {
            p.told = p.written;
            sample(&mut p.samples, p.written);
            let (bytes, t) = (p.written, Self::transfer(p, State::Going, None));
            drop(parts);
            answer(FileAnswer::Progress { id: id.into(), bytes });
            (self.hooks.change)(&t, device);
        }
    }

    fn end(&self, id: &str, device: &str, answer: &mut dyn FnMut(FileAnswer)) {
        let k = Self::key(device, id);
        let Some(mut p) = self.parts.lock().unwrap().remove(&k) else { return };
        if let Some(f) = p.out.take() {
            let _ = f.sync_all();
        }
        // short: the sender stopped it
        if p.written != p.size {
            let _ = std::fs::remove_file(&p.path);
            answer(FileAnswer::Failed { id: id.into(), why: "stopped".into() });
            return (self.hooks.change)(&Self::transfer(&p, State::Failed("stopped".into()), None), device);
        }
        if p.clip {
            (self.hooks.clip)(&p.path, &p.name, device);
            let _ = std::fs::remove_file(&p.path);
            answer(FileAnswer::Saved { id: id.into(), name: p.name.clone() });
            return (self.hooks.change)(&Self::transfer(&p, State::Done, None), device);
        }
        let _ = std::fs::create_dir_all(&self.folder);
        let placed = place(&p.path, &self.folder.join(&p.name));
        let _ = std::fs::remove_file(&p.path);
        let Some(dest) = placed else {
            answer(FileAnswer::Failed { id: id.into(), why: "write".into() });
            return (self.hooks.change)(&Self::transfer(&p, State::Failed("write".into()), None), device);
        };
        mark_downloaded(&dest);
        (self.hooks.saved)(&dest, device);
        let name = dest.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or(p.name.clone());
        answer(FileAnswer::Saved { id: id.into(), name });
        (self.hooks.change)(&Self::transfer(&p, State::Done, Some(dest)), device);
    }

    /// × here: the file stops and its part goes; the sender hears `stopped`.
    pub fn stop(&self, id: &str, device: &str, answer: &mut dyn FnMut(FileAnswer)) {
        let Some(mut p) = self.parts.lock().unwrap().remove(&Self::key(device, id)) else { return };
        p.out = None;
        let _ = std::fs::remove_file(&p.path);
        answer(FileAnswer::Failed { id: id.into(), why: "stopped".into() });
        (self.hooks.change)(&Self::transfer(&p, State::Failed("stopped".into()), None), device);
    }

    /// The session with `device` ended: parts wait an hour for it (or go, without resume, and clip ones always).
    pub fn suspend(&self, device: &str, except: Option<&str>) {
        let mut paused = vec![];
        {
            let mut parts = self.parts.lock().unwrap();
            let keys: Vec<String> = parts.iter().filter(|(_, p)| p.device == device && Some(p.id.as_str()) != except && p.kept_since.is_none()).map(|(k, _)| k.clone()).collect();
            for k in keys {
                let p = parts.get_mut(&k).unwrap();
                p.out = None;
                if self.resumes && !p.clip {
                    p.kept_since = Some(Instant::now());
                    paused.push(Self::transfer(p, State::Paused, None));
                } else {
                    let p = parts.remove(&k).unwrap();
                    let _ = std::fs::remove_file(&p.path);
                }
            }
        }
        for t in &paused {
            (self.hooks.change)(t, device);
        }
    }

    /// Parts kept longer than an hour go.
    pub fn expire(&self) {
        self.expire_at(Instant::now());
    }

    fn expire_at(&self, now: Instant) {
        let mut parts = self.parts.lock().unwrap();
        parts.retain(|_, p| {
            let keep = p.kept_since.is_none_or(|t| now.saturating_duration_since(t) <= KEEP_PARTS);
            if !keep {
                let _ = std::fs::remove_file(&p.path);
            }
            keep
        });
    }

    /// What's being received or kept, for a list (device, transfer).
    pub fn current(&self) -> Vec<(String, Transfer)> {
        self.parts
            .lock()
            .unwrap()
            .values()
            .map(|p| (p.device.clone(), Self::transfer(p, if p.kept_since.is_none() { State::Going } else { State::Paused }, None)))
            .collect()
    }

    fn transfer(p: &Part, s: State, saved: Option<PathBuf>) -> Transfer {
        let going = s == State::Going;
        let done = if s == State::Done { p.size } else { p.written };
        Transfer {
            id: p.id.clone(),
            name: saved.as_ref().and_then(|d| d.file_name()).map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| p.name.clone()),
            size: p.size,
            done,
            incoming: true,
            clip: p.clip,
            state: s,
            index: p.index,
            count: p.count,
            path: saved,
            seconds_left: if going { left(&p.samples, p.size) } else { None },
        }
    }
}

impl Drop for Receiver {
    fn drop(&mut self) {
        for p in self.parts.lock().unwrap().drain().map(|(_, p)| p) {
            drop(p.out);
            let _ = std::fs::remove_file(&p.path);
        }
    }
}

// ------------------------------------------------------------------ tests: a sender and a receiver back to back

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicI64, Ordering::SeqCst};

    struct Dir(PathBuf);
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn dir() -> Dir {
        let d = std::env::temp_dir().join(format!("blurt-files-test-{}", crate::crypto::new_id()));
        std::fs::create_dir_all(&d).unwrap();
        Dir(d)
    }

    fn file(d: &Path, name: &str, size: usize) -> PathBuf {
        let p = d.join("src").join(name);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        let data: Vec<u8> = (0..size).map(|i| (i.wrapping_mul(31).wrapping_add(7)) as u8).collect();
        std::fs::write(&p, data).unwrap();
        p
    }

    /// The wire between the two: `up` false drops every message, as a dead session does.
    #[derive(Default)]
    struct Pipe {
        up: AtomicBool,
        /// bytes of chunks, then the pipe drops (-1: never)
        cut_after: AtomicI64,
        chunked: AtomicI64,
        /// ms per chunk, as a slow network
        delay: AtomicI64,
    }

    struct Pair {
        s: Sender,
        r: Arc<Receiver>,
        out: PathBuf,
        pipe: Arc<Pipe>,
        clips: Clips,
        locked: Arc<AtomicBool>,
    }

    fn pair(d: &Path, resume: bool) -> Pair {
        let out = d.join("Downloads/Blurt");
        let clips: Clips = Arc::default();
        let locked = Arc::new(AtomicBool::new(false));
        let hooks = Hooks {
            locked: Box::new({
                let l = locked.clone();
                move || l.load(SeqCst)
            }),
            clip: Box::new({
                let c = clips.clone();
                move |p, n, _| c.lock().unwrap().push((n.to_string(), std::fs::read(p).unwrap_or_default()))
            }),
            ..Hooks::default()
        };
        let r = Arc::new(Receiver::new(d.join("parts"), out.clone(), resume, hooks));
        let pipe = Arc::new(Pipe { up: AtomicBool::new(true), cut_after: AtomicI64::new(-1), ..Pipe::default() });
        let slot: Arc<Mutex<Option<Sender>>> = Arc::default();
        let s = Sender::new(
            {
                let (r, pipe, slot) = (Arc::downgrade(&r), pipe.clone(), slot.clone());
                move |m| {
                    let Some(r) = r.upgrade() else { return false };
                    if !pipe.up.load(SeqCst) {
                        return false;
                    }
                    if let FileOut::Chunk { data, .. } = &m {
                        let d = pipe.delay.load(SeqCst);
                        if d > 0 {
                            std::thread::sleep(Duration::from_millis(d as u64));
                        }
                        let cut = pipe.cut_after.load(SeqCst);
                        if cut >= 0 && pipe.chunked.load(SeqCst) >= cut {
                            pipe.up.store(false, SeqCst);
                            return false;
                        }
                        pipe.chunked.fetch_add(data.len() as i64, SeqCst);
                    }
                    let slot = slot.clone();
                    r.heard(m, "phone-1", &mut |a| {
                        // answers come back on another thread, as from the network
                        let slot = slot.clone();
                        std::thread::spawn(move || {
                            if let Some(s) = slot.lock().unwrap().clone() {
                                s.heard(a)
                            }
                        });
                    });
                    true
                }
            },
            {
                let pipe = pipe.clone();
                move || pipe.up.load(SeqCst)
            },
            move || resume,
            |_| {},
        );
        *slot.lock().unwrap() = Some(s.clone());
        Pair { s, r, out, pipe, clips, locked }
    }

    fn wait(what: &str, ok: impl Fn() -> bool) {
        let end = Instant::now() + Duration::from_secs(10);
        while !ok() && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(ok(), "{what}");
    }

    #[test]
    fn a_batch_arrives_whole_and_in_order() {
        let d = dir();
        let p = pair(&d.0, true);
        let (a, b, c) = (file(&d.0, "a.txt", 5), file(&d.0, "b.bin", CHUNK * 3 + 17), file(&d.0, "c.txt", 0));
        p.s.add(vec![(a, false), (b.clone(), false), (c, false)], false);
        wait("all three saved", || p.s.transfers().iter().all(|t| t.state == State::Done));
        assert_eq!(std::fs::read(p.out.join("b.bin")).unwrap(), std::fs::read(&b).unwrap());
        assert_eq!(std::fs::read(p.out.join("c.txt")).unwrap().len(), 0);
        assert_eq!(p.s.transfers().iter().map(|t| t.index).collect::<Vec<_>>(), vec![Some(1), Some(2), Some(3)]);
        assert_eq!(p.s.transfers().iter().map(|t| t.count).collect::<Vec<_>>(), vec![Some(3); 3]);
    }

    #[test]
    fn a_name_in_use_gets_a_number() {
        let d = dir();
        let p = pair(&d.0, true);
        std::fs::create_dir_all(&p.out).unwrap();
        std::fs::write(p.out.join("a.txt"), b"").unwrap();
        p.s.add(vec![(file(&d.0, "a.txt", 3), false)], false);
        wait("saved as a 2.txt", || p.out.join("a 2.txt").exists());
    }

    #[test]
    fn a_drop_pauses_and_the_same_file_goes_on_from_where_it_was() {
        let d = dir();
        let p = pair(&d.0, true);
        p.pipe.cut_after.store((CHUNK * 30) as i64, SeqCst);
        let big = file(&d.0, "big.mov", CHUNK * 64);
        p.s.add(vec![(big.clone(), false)], false);
        wait("paused after the drop", || p.s.transfers()[0].state == State::Paused);
        p.s.connection(false);
        p.r.suspend("phone-1", None);
        assert_eq!(p.s.transfers()[0].state, State::Paused);
        let cur = p.r.current();
        assert_eq!(cur[0].1.state, State::Paused);
        let had = cur[0].1.done;
        assert!(had > 0);
        // back: the rest only
        p.pipe.cut_after.store(-1, SeqCst);
        p.pipe.chunked.store(0, SeqCst);
        p.pipe.up.store(true, SeqCst);
        p.s.connection(true);
        wait("saved", || p.s.transfers()[0].state == State::Done);
        assert_eq!(std::fs::read(p.out.join("big.mov")).unwrap(), std::fs::read(&big).unwrap());
        assert!(p.pipe.chunked.load(SeqCst) <= (CHUNK * 64) as i64 - had + CHUNK as i64, "only what was missing went again");
    }

    #[test]
    fn a_part_kept_over_an_hour_is_gone() {
        let d = dir();
        let p = pair(&d.0, true);
        p.pipe.cut_after.store((CHUNK * 4) as i64, SeqCst);
        p.s.add(vec![(file(&d.0, "x.zip", CHUNK * 40), false)], false);
        wait("dropped", || !p.pipe.up.load(SeqCst));
        p.r.suspend("phone-1", None);
        assert_eq!(p.r.current().len(), 1);
        p.r.expire_at(Instant::now() + KEEP_PARTS + Duration::from_secs(1));
        assert!(p.r.current().is_empty());
        assert_eq!(std::fs::read_dir(d.0.join("parts")).unwrap().count(), 0);
    }

    #[test]
    fn stop_on_the_sender_deletes_the_part() {
        let d = dir();
        let p = pair(&d.0, true);
        p.pipe.delay.store(5, SeqCst);
        let t = p.s.add(vec![(file(&d.0, "slow.bin", CHUNK * 200), false)], false).remove(0);
        wait("going", || p.r.current().first().is_some_and(|c| c.1.done > 0));
        p.s.stop(Some(&t.id));
        wait("part gone", || p.r.current().is_empty());
        assert_eq!(p.s.transfers()[0].state, State::Failed("stopped".into()));
        assert!(!p.out.join("slow.bin").exists());
        assert_eq!(std::fs::read_dir(d.0.join("parts")).unwrap().count(), 0);
    }

    #[test]
    fn stop_on_the_receiver_stops_the_sender() {
        let d = dir();
        let p = pair(&d.0, true);
        p.pipe.delay.store(5, SeqCst);
        let t = p.s.add(vec![(file(&d.0, "slow.bin", CHUNK * 200), false)], false).remove(0);
        wait("going", || p.r.current().first().is_some_and(|c| c.1.done > 0));
        let s = p.s.clone();
        p.r.stop(&t.id, "phone-1", &mut |a| s.heard(a));
        wait("stopped", || p.s.transfers()[0].state == State::Failed("stopped".into()));
    }

    #[test]
    fn a_clip_goes_to_the_clipboard_not_the_folder() {
        let d = dir();
        let p = pair(&d.0, true);
        p.s.add(vec![(file(&d.0, "Image.png", 1000), false)], true);
        wait("clip heard", || !p.clips.lock().unwrap().is_empty());
        let c = p.clips.lock().unwrap()[0].clone();
        assert_eq!((c.0.as_str(), c.1.len()), ("Image.png", 1000));
        assert!(!p.out.join("Image.png").exists());
        wait("done", || p.s.transfers()[0].state == State::Done);
    }

    #[test]
    fn a_locked_receiver_takes_nothing() {
        let d = dir();
        let p = pair(&d.0, true);
        p.locked.store(true, SeqCst);
        p.s.add(vec![(file(&d.0, "a.txt", 3), false)], false);
        wait("refused", || p.s.transfers()[0].state == State::Failed("locked".into()));
    }

    #[test]
    fn two_senders_under_one_device_send_at_the_same_time() {
        // a viewer's two windows: one device id, two senders, one receiver
        let d = dir();
        let p = pair(&d.0, true);
        p.pipe.delay.store(1, SeqCst);
        let r = Arc::downgrade(&p.r);
        let slot: Arc<Mutex<Option<Sender>>> = Arc::default();
        let second = Sender::new(
            {
                let slot = slot.clone();
                move |m| {
                    let Some(r) = r.upgrade() else { return false };
                    if matches!(m, FileOut::Chunk { .. }) {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    let slot = slot.clone();
                    r.heard(m, "phone-1", &mut |a| {
                        let slot = slot.clone();
                        std::thread::spawn(move || {
                            if let Some(s) = slot.lock().unwrap().clone() {
                                s.heard(a)
                            }
                        });
                    });
                    true
                }
            },
            || true,
            || true,
            |_| {},
        );
        *slot.lock().unwrap() = Some(second.clone());
        let (a, b) = (file(&d.0, "one.bin", CHUNK * 30), file(&d.0, "two.bin", CHUNK * 30 + 5));
        p.s.add(vec![(a.clone(), false)], false);
        second.add(vec![(b.clone(), false)], false);
        wait("both saved", || p.s.transfers()[0].state == State::Done && second.transfers()[0].state == State::Done);
        assert_eq!(std::fs::read(p.out.join("one.bin")).unwrap(), std::fs::read(&a).unwrap());
        assert_eq!(std::fs::read(p.out.join("two.bin")).unwrap(), std::fs::read(&b).unwrap());
    }

    #[test]
    fn a_kept_part_waits_while_locked_and_goes_on_after() {
        let d = dir();
        let p = pair(&d.0, true);
        p.pipe.cut_after.store((CHUNK * 4) as i64, SeqCst);
        let f = file(&d.0, "x.bin", CHUNK * 20);
        p.s.add(vec![(f.clone(), false)], false);
        wait("dropped", || !p.pipe.up.load(SeqCst));
        p.r.suspend("phone-1", None);
        p.s.connection(false);
        p.locked.store(true, SeqCst);
        p.pipe.cut_after.store(-1, SeqCst);
        p.pipe.up.store(true, SeqCst);
        p.s.connection(true);
        wait("refused while locked", || p.s.transfers()[0].state == State::Failed("locked".into()));
        assert_eq!(p.r.current().len(), 1, "the part is kept");
        assert_eq!(p.r.current()[0].1.state, State::Paused);
    }

    #[test]
    fn a_file_made_meanwhile_is_never_replaced() {
        let d = dir();
        let src = file(&d.0, "a.txt", 3);
        let want = d.0.join("out/a.txt");
        std::fs::create_dir_all(want.parent().unwrap()).unwrap();
        std::fs::write(&want, b"mine").unwrap();
        std::fs::write(d.0.join("out/a 2.txt"), b"mine too").unwrap();
        assert_eq!(place(&src, &want), Some(d.0.join("out/a 3.txt")));
        assert_eq!(std::fs::read(&want).unwrap(), b"mine");
        assert_eq!(std::fs::read(d.0.join("out/a 3.txt")).unwrap(), std::fs::read(&src).unwrap());
    }

    #[test]
    fn an_older_receiver_without_resume_still_gets_the_file() {
        let d = dir();
        let p = pair(&d.0, false);
        let f = file(&d.0, "doc.pdf", CHUNK * 25 + 1);
        p.s.add(vec![(f.clone(), false)], false);
        wait("saved", || p.s.transfers()[0].state == State::Done);
        assert_eq!(std::fs::read(p.out.join("doc.pdf")).unwrap(), std::fs::read(&f).unwrap());
    }

    #[test]
    fn an_older_receiver_drops_the_part_with_the_session() {
        let d = dir();
        let p = pair(&d.0, false);
        p.pipe.cut_after.store((CHUNK * 4) as i64, SeqCst);
        p.s.add(vec![(file(&d.0, "x.bin", CHUNK * 40), false)], false);
        wait("dropped", || !p.pipe.up.load(SeqCst));
        p.r.suspend("phone-1", None);
        assert!(p.r.current().is_empty());
    }

    #[test]
    fn the_window_follows_the_rate_with_a_peer_that_resumes() {
        assert_eq!(window(None, true), MIN_WINDOW);
        assert_eq!(window(Some(1_500_000.0), true), 750_000);
        assert_eq!(window(Some(50e6), true), WINDOW);
        assert_eq!(window(Some(1_500_000.0), false), WINDOW, "an older peer: fixed, as before");
        let t = Instant::now();
        assert_eq!(rate(&[(t, 0), (t + Duration::from_millis(100), 1 << 20)]), None, "less than 0.2 s");
        assert_eq!(rate(&[(t, 0), (t + Duration::from_millis(500), 750_000)]), Some(1_500_000.0));
    }

    #[test]
    fn names_are_cleaned() {
        assert_eq!(clean("../secret/.bashrc"), "bashrc");
        assert_eq!(clean("C:\\Users\\me\\报告.pdf"), "报告.pdf");
        assert_eq!(clean("a:b.txt"), "a-b.txt");
        assert_eq!(clean("  "), "file");
        assert_eq!(clean("tab\there.txt"), "tabhere.txt");
        assert_eq!(clean("C:\\Windows\\evil.exe"), "evil.exe");
        assert_eq!(clean("a?b*.txt"), "a-b-.txt");
    }

    #[test]
    fn a_folder_is_zipped() {
        let d = dir();
        let f = d.0.join("Lessons");
        std::fs::create_dir_all(f.join("week 1")).unwrap();
        std::fs::write(f.join("week 1/plan.txt"), b"hi").unwrap();
        let a = file(&d.0, "a.txt", 1);
        let out = prepare(&[f, a]);
        assert_eq!(out.iter().map(|(p, _)| p.file_name().unwrap().to_string_lossy().into_owned()).collect::<Vec<_>>(), vec!["Lessons.zip", "a.txt"]);
        assert_eq!(out.iter().map(|(_, t)| *t).collect::<Vec<_>>(), vec![true, false]);
        let head = std::fs::read(&out[0].0).unwrap();
        assert_eq!(&head[..2], b"PK", "a zip");
        let _ = std::fs::remove_dir_all(out[0].0.parent().unwrap());
    }
}
