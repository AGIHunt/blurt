//! Files a viewer sends (docs/design/remote-1.1.md §6): written to the Downloads folder as "<name>.part" while they arrive, then renamed
//! (a number added when the name is taken). On Windows the file gets the Mark of the Web (the Zone.Identifier stream a browser's
//! download has), so it's never run without the usual warning. A session that ends mid-file leaves nothing behind.
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::wire::ToPhone;

pub const MAX_SIZE: i64 = 4 << 30;
pub const PROGRESS_EVERY: i64 = 1 << 20;

struct File {
    id: String,
    name: String,
    size: i64,
    part: PathBuf,
    out: std::fs::File,
    written: i64,
    told: i64,
}

pub struct Receiver {
    dir: PathBuf,
    file: Option<File>,
}

/// What to tell the sender, and a name once saved.
pub struct Said {
    pub msg: Option<ToPhone>,
    pub saved: Option<String>,
}

impl Receiver {
    pub fn new(dir: PathBuf) -> Receiver {
        Receiver { dir, file: None }
    }

    pub fn begin(&mut self, id: &str, name: &str, size: i64, locked: bool) -> Option<ToPhone> {
        self.drop_file();
        let fail = |why: &str| Some(ToPhone::FileFailed { id: id.into(), why: why.into() });
        if locked {
            return fail("locked");
        }
        if !(0..=MAX_SIZE).contains(&size) {
            return fail("too_big");
        }
        let name = clean(name);
        let part = self.dir.join(format!("{name}.part"));
        let _ = std::fs::create_dir_all(&self.dir);
        match std::fs::File::create(&part) {
            Ok(out) => {
                self.file = Some(File { id: id.into(), name, size, part, out, written: 0, told: 0 });
                None
            }
            Err(e) if e.raw_os_error() == Some(28) || e.raw_os_error() == Some(112) => fail("space"),
            Err(_) => fail("write"),
        }
    }

    pub fn chunk(&mut self, id: &str, data: &[u8]) -> Option<ToPhone> {
        let f = self.file.as_mut().filter(|f| f.id == id)?;
        if f.written + data.len() as i64 > f.size || f.out.write_all(data).is_err() {
            self.drop_file();
            return Some(ToPhone::FileFailed { id: id.into(), why: "write".into() });
        }
        f.written += data.len() as i64;
        if f.written - f.told >= PROGRESS_EVERY {
            f.told = f.written;
            return Some(ToPhone::FileProgress { id: id.into(), bytes: f.written });
        }
        None
    }

    pub fn end(&mut self, id: &str) -> Said {
        let Some(f) = self.file.take().filter(|f| f.id == id) else { return Said { msg: None, saved: None } };
        let fail = |why: &str| Said { msg: Some(ToPhone::FileFailed { id: id.into(), why: why.into() }), saved: None };
        drop(f.out);
        if f.written != f.size {
            let _ = std::fs::remove_file(&f.part);
            return fail("write");
        }
        let dest = unique(&self.dir.join(&f.name));
        if std::fs::rename(&f.part, &dest).is_err() {
            let _ = std::fs::remove_file(&f.part);
            return fail("write");
        }
        mark_downloaded(&dest);
        let saved = dest.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or(f.name);
        Said { msg: Some(ToPhone::FileSaved { id: id.into(), name: saved.clone() }), saved: Some(saved) }
    }

    /// The session ended, or another file began: a file not finished goes.
    pub fn drop_file(&mut self) {
        if let Some(f) = self.file.take() {
            drop(f.out);
            let _ = std::fs::remove_file(&f.part);
        }
    }
}

impl Drop for Receiver {
    fn drop(&mut self) {
        self.drop_file();
    }
}

/// A name to write under: no folders, no hidden or empty names, nothing Windows can't hold.
pub fn clean(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("");
    let mut n: String = base.chars().map(|c| if "<>:\"|?*".contains(c) || c.is_control() { '-' } else { c }).collect();
    n = n.trim().trim_start_matches('.').trim_end_matches(['.', ' ']).to_string();
    if n.is_empty() {
        n = "file".into();
    }
    n.chars().take(200).collect()
}

fn unique(p: &Path) -> PathBuf {
    if !p.exists() {
        return p.to_path_buf();
    }
    let stem = p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = p.extension().map(|e| e.to_string_lossy().into_owned());
    for i in 2.. {
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

/// Windows: the Mark of the Web (zone 3, the Internet), as a browser's download has. Elsewhere nothing: the file isn't executable.
fn mark_downloaded(p: &Path) {
    if cfg!(windows) {
        let mut ads = p.as_os_str().to_owned();
        ads.push(":Zone.Identifier");
        let _ = std::fs::write(PathBuf::from(ads), b"[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=about:internet\r\n");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_kept_inside_downloads() {
        assert_eq!(clean("../../etc/passwd"), "passwd");
        assert_eq!(clean("C:\\Windows\\evil.exe"), "evil.exe");
        assert_eq!(clean(".bashrc"), "bashrc");
        assert_eq!(clean("a:b?.txt"), "a-b-.txt");
        assert_eq!(clean("   "), "file");
    }

    #[test]
    fn a_file_arrives_whole_or_not_at_all() {
        let dir = std::env::temp_dir().join(format!("blurt-incoming-{}", crate::crypto::new_id()));
        let mut r = Receiver::new(dir.clone());
        assert!(r.begin("1", "notes.txt", 5, false).is_none());
        assert!(r.chunk("1", b"hel").is_none());
        assert!(r.chunk("1", b"lo").is_none());
        let s = r.end("1");
        assert_eq!(s.saved.as_deref(), Some("notes.txt"));
        assert_eq!(std::fs::read(dir.join("notes.txt")).unwrap(), b"hello");
        // the same name again: a number added
        r.begin("2", "notes.txt", 1, false);
        r.chunk("2", b"x");
        assert_eq!(r.end("2").saved.as_deref(), Some("notes 2.txt"));
        // cut short: nothing left
        r.begin("3", "big.bin", 10, false);
        r.chunk("3", b"abc");
        drop(r);
        assert!(!dir.join("big.bin.part").exists() && !dir.join("big.bin").exists());
        // locked: refused
        let mut r = Receiver::new(dir.clone());
        assert!(matches!(r.begin("4", "x", 1, true), Some(ToPhone::FileFailed { .. })));
        let _ = std::fs::remove_dir_all(dir);
    }
}
