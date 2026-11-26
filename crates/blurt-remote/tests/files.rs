//! The clipboard and files from this host to a phone (docs/design/remote-files.md), on loopback against the Rust test phone, whose end
//! is the same engine a viewer runs (files::Receiver): copied text, a copied image as a `clip` file, copied files as a batch (a folder
//! zipped), the bar's Send Files…, a file that resumes after the phone drops mid-way, and a phone's own `clip` image pasted here.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use blurt_remote::files::{self, FileAnswer, FileOut, Hooks, Receiver};
use blurt_remote::host::{Backend, Button, Clip, Copied, CursorShape, Input, ScrollPhase, SystemMove};
use blurt_remote::phone::{pair, Event, Options, Phone};
use blurt_remote::store::FileKeyStore;
use blurt_remote::wire::{ToMac, ToPhone};
use blurt_remote::{App, Host, HostConfig};

#[derive(Clone, Default)]
struct Board {
    copied: Arc<Mutex<Option<Copied>>>,
    pasted: Arc<Mutex<Vec<Clip>>>,
    said: Arc<Mutex<Vec<String>>>,
}

struct TestInput(Board);

impl Input for TestInput {
    fn can_control(&self) -> bool {
        true
    }
    fn key(&mut self, _: &str, _: u8, _: Option<bool>) {}
    fn set_held(&mut self, _: u8) {}
    fn text(&mut self, _: &str) {}
    fn button(&mut self, _: Button, _: bool, _: u32) {}
    fn move_by(&mut self, _: f64, _: f64) {}
    fn move_to(&mut self, _: f64, _: f64) {}
    fn scroll(&mut self, _: f64, _: f64, _: ScrollPhase) {}
    fn system(&mut self, _: SystemMove) {}
    fn release_all(&mut self) {}
    fn pointer(&self) -> Option<(f64, f64)> {
        None
    }
    fn cursor_shape(&mut self) -> Option<CursorShape> {
        None
    }
    fn copied(&mut self) -> Copied {
        self.0.copied.lock().unwrap().clone().unwrap_or(Copied::Empty)
    }
    fn paste_clip(&mut self, c: &Clip) -> bool {
        self.0.pasted.lock().unwrap().push(c.clone());
        true
    }
}

struct TestBackend(TestInput);

impl Backend for TestBackend {
    fn input(&mut self) -> &mut dyn Input {
        &mut self.0
    }
    fn screen(&mut self) -> Option<&mut dyn blurt_remote::host::Screen> {
        None
    }
    fn platform(&self) -> &'static str {
        "windows"
    }
    fn display_aspect(&self) -> f64 {
        1.5
    }
    fn now(&self) -> f64 {
        0.0
    }
    fn keep_awake(&mut self, _: bool, _: bool) {}
}

struct TestApp(Board);

impl App for TestApp {
    fn clipboard_sent(&self, to: &str) {
        self.0.said.lock().unwrap().push(format!("clipboard sent to {to}"));
    }
    fn files_received(&self, from: &str, count: usize, _: &std::path::Path) {
        self.0.said.lock().unwrap().push(format!("{count} files from {from}"));
    }
}

async fn until<T>(what: &str, f: impl Fn() -> Option<T>) -> T {
    for _ in 0..400 {
        if let Some(x) = f() {
            return x;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("never: {what}");
}

fn data(n: usize) -> Vec<u8> {
    (0..n).map(|i| (i.wrapping_mul(131) % 251) as u8).collect()
}

/// The phone's end: its receiver, what it got on its clipboard, the chunk bytes it took.
struct PhoneEnd {
    r: Receiver,
    clips: Arc<Mutex<Vec<(String, Vec<u8>)>>>,
    folder: PathBuf,
}

impl PhoneEnd {
    fn new(dir: &std::path::Path) -> PhoneEnd {
        let clips: Arc<Mutex<Vec<(String, Vec<u8>)>>> = Arc::default();
        let c = clips.clone();
        let hooks = Hooks { clip: Box::new(move |p, n, _| c.lock().unwrap().push((n.into(), std::fs::read(p).unwrap()))), ..Hooks::default() };
        let folder = dir.join("phone/Blurt Remote");
        PhoneEnd { r: Receiver::new(dir.join("phone/parts"), folder.clone(), true, hooks), clips, folder }
    }

    /// Reads the phone's messages for `secs`, giving file messages to the receiver (and its answers back) until `done` holds. → the
    /// other messages seen, and the chunk bytes taken. `cut`: after this many chunk bytes, stop reading (the caller drops the phone).
    async fn pump(&self, phone: &mut Phone, secs: u64, cut: Option<usize>, done: impl Fn(&PhoneEnd, &[ToPhone]) -> bool) -> (Vec<ToPhone>, usize) {
        let mut seen = vec![];
        let mut taken = 0usize;
        let end = tokio::time::Instant::now() + Duration::from_secs(secs);
        while tokio::time::Instant::now() < end {
            if done(self, &seen) || cut.is_some_and(|c| taken >= c) {
                break;
            }
            let Some(e) = phone.next(Duration::from_millis(50)).await else { continue };
            let Event::Control(m) = e else {
                if matches!(e, Event::Closed) {
                    break;
                }
                continue;
            };
            match m.file_out() {
                Some(o) => {
                    if let FileOut::Chunk { data, .. } = &o {
                        taken += data.len();
                    }
                    let mut out = vec![];
                    self.r.heard(o, "host", &mut |a: FileAnswer| out.push(a));
                    for a in out {
                        phone.send(&ToMac::from(a)).await;
                    }
                }
                None => seen.push(m),
            }
        }
        (seen, taken)
    }
}

fn files_phone() -> Options {
    Options { features: Some(vec!["move".into(), "files".into(), "resume".into()]), ..Options::default() }
}

async fn paired(dir: &std::path::Path, board: &Board) -> (Host, SocketAddr, String, Vec<u8>) {
    let h = Host::start(
        HostConfig { dir: dir.into(), name: "Office PC".into(), version: "1.1.5".into(), test_answer: Some(true), port: 0, go_between: Some(String::new()) },
        Box::new(TestBackend(TestInput(board.clone()))),
        Box::new(FileKeyStore::new(dir.join("keys.json"))),
        Box::new(TestApp(board.clone())),
    );
    h.set_downloads(Some(dir.join("Downloads/Blurt")));
    h.show_pairing(true);
    let (link, port) = until("a code", || h.status().pairing.map(|p| (p.url, h.status().port))).await;
    let at: SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();
    let (phone, device, key, info) = pair(&link, at).await.expect("paired");
    let f = info.features.unwrap_or_default();
    for x in ["files", "resume", "clipboard"] {
        assert!(f.iter().any(|y| y == x), "the session lists {x}: {f:?}");
    }
    drop(phone);
    h.show_pairing(false);
    (h, at, device, key)
}

async fn connect(at: SocketAddr, device: &str, key: &[u8], h: &Host) -> Phone {
    let mut p = Phone::connect_with(at, device, key, files_phone()).await.expect("connected");
    p.wait(Duration::from_secs(5), |m| matches!(m, ToPhone::Session(_)).then_some(())).await.expect("session");
    until("connected", || h.status().connected.filter(|c| c.id == device)).await;
    p
}

#[tokio::test(flavor = "multi_thread")]
async fn copied_text_an_image_and_files_come_to_the_phone() {
    let dir = std::env::temp_dir().join(format!("blurt-files-host-{}", blurt_remote::crypto::new_id()));
    let board = Board::default();
    let (h, at, device, key) = paired(&dir, &board).await;
    let mut phone = connect(at, &device, &key, &h).await;
    let end = PhoneEnd::new(&dir);

    // nothing copied
    phone.send(&ToMac::GetClipboard).await;
    let why = phone.wait(Duration::from_secs(3), |m| if let ToPhone::ClipboardNone { why } = m { Some(why.clone()) } else { None }).await;
    assert_eq!(why.as_deref(), Some("empty"));

    // text: the same message a viewer hears, and the bar says it went (never what)
    *board.copied.lock().unwrap() = Some(Copied::Text("Q4 报价 copied".into()));
    phone.send(&ToMac::GetClipboard).await;
    let t = phone.wait(Duration::from_secs(3), |m| if let ToPhone::Clipboard(t) = m { Some(t.clone()) } else { None }).await;
    assert_eq!(t.as_deref(), Some("Q4 报价 copied"));
    until("the bar", || board.said.lock().unwrap().iter().any(|l| l == "clipboard sent to Test Phone").then_some(())).await;

    // text longer than a message: a clip file, Text.txt
    let long = "长".repeat(30_000);
    *board.copied.lock().unwrap() = Some(Copied::Text(long.clone()));
    phone.send(&ToMac::GetClipboard).await;
    end.pump(&mut phone, 10, None, |e, _| !e.clips.lock().unwrap().is_empty()).await;
    let c = end.clips.lock().unwrap().remove(0);
    assert_eq!((c.0.as_str(), c.1), ("Text.txt", long.into_bytes()));

    // an image: a clip file, Image.png
    let png = blurt_remote::platform::pixels::png(4, 3, vec![200; 48]).unwrap();
    *board.copied.lock().unwrap() = Some(Copied::Image(png.clone()));
    phone.send(&ToMac::GetClipboard).await;
    end.pump(&mut phone, 10, None, |e, _| !e.clips.lock().unwrap().is_empty()).await;
    let c = end.clips.lock().unwrap().remove(0);
    assert_eq!((c.0.as_str(), c.1), ("Image.png", png));
    assert!(!end.folder.join("Image.png").exists(), "a clip is saved nowhere");

    // files and a folder: one batch, the folder zipped
    let src = dir.join("src");
    std::fs::create_dir_all(src.join("Lessons/week 1")).unwrap();
    std::fs::write(src.join("Q4 报价单.xlsx"), data(300_000)).unwrap();
    std::fs::write(src.join("作业 3.jpg"), data(5)).unwrap();
    std::fs::write(src.join("Lessons/week 1/plan.txt"), b"hi").unwrap();
    *board.copied.lock().unwrap() = Some(Copied::Files(vec![src.join("Q4 报价单.xlsx"), src.join("作业 3.jpg"), src.join("Lessons")]));
    phone.send(&ToMac::GetClipboard).await;
    end.pump(&mut phone, 10, None, |e, _| e.folder.join("Lessons.zip").exists()).await;
    assert_eq!(std::fs::read(end.folder.join("Q4 报价单.xlsx")).unwrap(), data(300_000));
    assert_eq!(std::fs::read(end.folder.join("作业 3.jpg")).unwrap(), data(5));
    assert_eq!(&std::fs::read(end.folder.join("Lessons.zip")).unwrap()[..2], b"PK");

    // more than 1,000 files: said, nothing sent
    *board.copied.lock().unwrap() = Some(Copied::Files(vec![src.join("作业 3.jpg"); files::MAX_COUNT + 1]));
    phone.send(&ToMac::GetClipboard).await;
    let why = phone.wait(Duration::from_secs(3), |m| if let ToPhone::ClipboardNone { why } = m { Some(why.clone()) } else { None }).await;
    assert_eq!(why.as_deref(), Some("too_big"));

    // the connection log counts it, never what it was
    until("the log", || h.connections().last().filter(|c| c.clipboard >= 4 && c.sent >= 3).map(|_| ())).await;

    // the phone's own image: onto this computer's clipboard and pasted, saved nowhere
    let png2 = blurt_remote::platform::pixels::png(2, 2, vec![9; 16]).unwrap();
    phone.send(&ToMac::FileBegin { id: "p1".into(), name: "Image.png".into(), size: png2.len() as i64, clip: Some(true), index: None, count: None, total: None }).await;
    let at0 = phone.wait(Duration::from_secs(3), |m| if let ToPhone::FileProgress { id, bytes } = m { (id == "p1").then_some(*bytes) } else { None }).await;
    assert_eq!(at0, Some(0), "a host that resumes answers every begin at once");
    phone.send(&ToMac::FileChunk { id: "p1".into(), data: png2.clone() }).await;
    phone.send(&ToMac::FileEnd { id: "p1".into() }).await;
    phone.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::FileSaved { id, .. } if id == "p1").then_some(())).await.expect("saved");
    until("pasted", || board.pasted.lock().unwrap().first().cloned()).await;
    assert_eq!(board.pasted.lock().unwrap()[0], Clip::Image(png2));
    assert!(!dir.join("Downloads/Blurt/Image.png").exists());

    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_file_sent_from_the_bar_goes_on_after_the_phone_drops() {
    let dir = std::env::temp_dir().join(format!("blurt-files-resume-{}", blurt_remote::crypto::new_id()));
    let board = Board::default();
    let (h, at, device, key) = paired(&dir, &board).await;
    let mut phone = connect(at, &device, &key, &h).await;
    let end = PhoneEnd::new(&dir);
    let size = files::CHUNK * 64; // 12 MB
    let src = dir.join("src/课堂录像.mov");
    std::fs::create_dir_all(src.parent().unwrap()).unwrap();
    std::fs::write(&src, data(size)).unwrap();
    assert!(h.send_files(vec![src.clone()]));

    // about 40 % in, the phone goes (a tunnel)
    let (_, first) = end.pump(&mut phone, 10, Some(size * 2 / 5), |_, _| false).await;
    assert!(first >= size * 2 / 5 && first < size, "{first}");
    drop(phone);
    end.r.suspend("host", None);
    until("gone", || h.status().connected.is_none().then_some(())).await;

    // back: the begin again with the same id, and only the rest
    let mut phone = connect(at, &device, &key, &h).await;
    let (_, rest) = end.pump(&mut phone, 20, None, |e, _| e.folder.join("课堂录像.mov").exists()).await;
    assert_eq!(std::fs::read(end.folder.join("课堂录像.mov")).unwrap(), data(size));
    assert!(rest <= size - first + files::WINDOW as usize, "only what was missing went again: {rest} of {size}, {first} before");
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}
