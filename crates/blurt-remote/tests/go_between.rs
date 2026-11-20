//! The go-between end to end (docs/design/remote-go-between.md): the real host and the Rust test phone through
//! `BUDGET=1 node tools/remote-relay/server.js`, the relay with the public go-between's limits (16 KiB a message, 96 KiB a
//! connection, 24 KiB in any 5 s, then 4003).
//!
//!  • the session opens through it, the direct path opens, both ends move their stream onto it, and keys, a pong and far more
//!    than the budget arrive after the move with nothing closed for being over it;
//!  • a phone from before the go-between isn't offered it; with UDP blocked the host says `noDirect` after 8 s and closes.
//!
//! Skipped (with a line saying so) where node, the `ws` package or the relay's budget mode isn't there.

use std::net::SocketAddr;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use blurt_remote::host::{Backend, Button, CursorShape, Input, ScrollPhase, SystemMove};
use blurt_remote::phone::{pair, Event, Options, Phone};
use blurt_remote::server::GoBetweenProblem;
use blurt_remote::store::FileKeyStore;
use blurt_remote::wire::{Candidate, Chord, SessionInfo, ToMac, ToPhone};
use blurt_remote::{App, Host, HostConfig};

#[derive(Clone, Default)]
struct Lines(Arc<Mutex<Vec<String>>>);

impl Lines {
    fn push(&self, s: String) {
        self.0.lock().unwrap().push(s);
    }
    async fn wait(&self, what: &str) -> Vec<String> {
        for _ in 0..200 {
            if self.0.lock().unwrap().iter().any(|l| l.contains(what)) {
                return std::mem::take(&mut self.0.lock().unwrap());
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("never saw {what:?}: {:?}", self.0.lock().unwrap());
    }
}

struct TestInput(Lines);

impl Input for TestInput {
    fn can_control(&self) -> bool {
        true
    }
    fn key(&mut self, name: &str, mods: u8, down: Option<bool>) {
        self.0.push(format!("key {name} {mods} {down:?}"));
    }
    fn set_held(&mut self, mods: u8) {
        self.0.push(format!("held {mods}"));
    }
    fn text(&mut self, t: &str) {
        self.0.push(format!("text {}", t.len()));
    }
    fn button(&mut self, _: Button, _: bool, _: u32) {}
    fn move_by(&mut self, dx: f64, dy: f64) {
        self.0.push(format!("move {dx} {dy}"));
    }
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
        "linux"
    }
    fn display_aspect(&self) -> f64 {
        1.6
    }
    fn now(&self) -> f64 {
        0.0
    }
    fn keep_awake(&mut self, _: bool, _: bool) {}
}

struct Quiet;
impl App for Quiet {}

/// The relay in budget mode on a free port, or None (and why) when it can't run here.
struct Relay(Child, u16);

impl Drop for Relay {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn ws_module(repo: &std::path::Path) -> Option<std::path::PathBuf> {
    // the relay's own node_modules, or the web workspace's copy of `ws` (no install needed for a test)
    if repo.join("tools/remote-relay/node_modules/ws").exists() {
        return None;
    }
    let pnpm = repo.join("web/node_modules/.pnpm");
    std::fs::read_dir(&pnpm).ok()?.flatten().map(|e| e.path()).find(|p| p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("ws@8"))).map(|p| p.join("node_modules"))
}

async fn relay() -> Result<Relay, String> {
    let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let server = repo.join("tools/remote-relay/server.js");
    let port = std::net::TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?.local_addr().unwrap().port();
    let mut c = Command::new("node");
    c.arg(&server).env("BUDGET", "1").env("HOST", "127.0.0.1").env("PORT", port.to_string()).stdout(Stdio::null()).stderr(Stdio::null());
    if let Some(p) = ws_module(&repo) {
        c.env("NODE_PATH", p);
    }
    let child = c.spawn().map_err(|e| format!("node: {e}"))?;
    let r = Relay(child, port);
    // up, and in budget mode: GET / says so
    for _ in 0..50 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        if let Ok(mut s) = tokio::net::TcpStream::connect(("127.0.0.1", port)).await {
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            let _ = s.write_all(b"GET / HTTP/1.0\r\nHost: x\r\n\r\n").await;
            let mut b = vec![];
            let _ = tokio::time::timeout(Duration::from_secs(2), s.read_to_end(&mut b)).await;
            return if String::from_utf8_lossy(&b).contains("blurt go-between") { Ok(r) } else { Err("the relay has no budget mode yet".into()) };
        }
    }
    Err("the relay didn't start (node, or its ws package, missing?)".into())
}

async fn until<T>(f: impl Fn() -> Option<T>) -> T {
    for _ in 0..400 {
        if let Some(x) = f() {
            return x;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("never");
}

/// A host whose go-between is the local relay, and a phone paired with it on the local network (then gone).
async fn paired(meet: &str, input: Lines) -> (Host, std::path::PathBuf, String, Vec<u8>) {
    let dir = std::env::temp_dir().join(format!("blurt-remote-meet-{}", blurt_remote::crypto::new_id()));
    let h = Host::start(
        HostConfig { dir: dir.clone(), name: "Studio PC".into(), version: "1.0.27".into(), test_answer: Some(true), port: 0, go_between: Some(meet.into()) },
        Box::new(TestBackend(TestInput(input))),
        Box::new(FileKeyStore::new(dir.join("keys.json"))),
        Box::new(Quiet),
    );
    assert!(h.status().relay.go_between, "on by default");
    h.show_pairing(true);
    let (link, port) = until(|| h.status().pairing.map(|p| (p.url, h.status().port))).await;
    assert!(link.contains(&format!("r={meet}")), "the code carries the go-between: {link}");
    let at: SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();
    let (phone, device, key, _) = pair(&link, at).await.expect("paired");
    h.show_pairing(false);
    drop(phone);
    until(|| h.status().connected.is_none().then_some(())).await;
    (h, dir, device, key)
}

/// Away: through the go-between, once the host's waiting connection is in the room.
async fn away(meet: &str, device: &str, key: &[u8], opts: Options) -> (Phone, SessionInfo) {
    for _ in 0..50 {
        if let Ok(mut p) = Phone::connect_relay_with(meet, device, key, opts.clone()).await {
            let info = p.wait(Duration::from_secs(5), |m| if let ToPhone::Session(i) = m { Some(i.clone()) } else { None }).await.expect("session");
            return (p, info);
        }
        tokio::time::sleep(Duration::from_millis(200)).await; // 4001: the host isn't there yet
    }
    panic!("never got through the go-between");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_session_meets_moves_to_udp_and_stays_off_the_go_between() {
    let r = match relay().await {
        Ok(r) => r,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    // BLURT_TEST_MEET=wss://meet.blurt.work runs this one against the deployed go-between
    let meet = std::env::var("BLURT_TEST_MEET").unwrap_or_else(|_| format!("ws://127.0.0.1:{}", r.1));
    let input = Lines::default();
    let (h, dir, device, key) = paired(&meet, input.clone()).await;

    let (mut phone, mut info) = away(&meet, &device, &key, Options::go_between()).await;
    assert_eq!(
        info.features.as_deref(),
        Some(&["move".to_string(), "viewer".to_string()][..])
    );
    assert_eq!(info.relay.as_deref(), Some(meet.as_str()), "offered to a phone that can move");
    assert!(!info.candidates.is_empty() || cfg!(not(target_os = "macos")), "the LAN's addresses go in every session");
    until(|| h.status().connected.filter(|c| c.route == "goBetween")).await;

    // the direct path: every candidate, and loopback (this machine may have no LAN address)
    info.candidates.push(Candidate { host: "127.0.0.1".into(), port: info.udp_port });
    phone.open_direct(&info).await.unwrap();
    let mut seen = (false, false);
    let t0 = std::time::Instant::now();
    while !(seen.0 && seen.1) && t0.elapsed() < Duration::from_secs(5) {
        match phone.next(Duration::from_secs(5)).await {
            Some(Event::Control(ToPhone::UdpOk)) => seen.0 = true,
            Some(Event::Control(ToPhone::StreamMoved)) => seen.1 = true,
            Some(Event::Closed) | None => panic!("closed before the move"),
            _ => {}
        }
    }
    assert_eq!(seen, (true, true), "udpOK, then the host's streamMoved");
    until(|| phone.moved().then_some(())).await;
    until(|| h.status().connected.filter(|c| c.route == "direct")).await;

    // keys after the move: over UDP, in order
    phone.send(&ToMac::Key { chord: Chord::new(8, "C"), down: None }).await;
    assert_eq!(input.wait("held 0").await, ["held 8", "key C 0 None", "held 0"]);
    // the host's stream moved too: a pong comes back over it
    phone.send(&ToMac::Ping(42.0)).await;
    let pong = phone.wait(Duration::from_secs(3), |m| if let ToPhone::Pong(t) = m { Some(*t) } else { None }).await;
    assert_eq!(pong, Some(42.0));
    // far over the budget (96 KiB a connection, 16 KiB a message): none of it goes through the go-between
    for _ in 0..4 {
        phone.send(&ToMac::Text("x".repeat(40_000))).await;
    }
    let mut texts = 0;
    for _ in 0..200 {
        texts += std::mem::take(&mut *input.0.lock().unwrap()).iter().filter(|l| *l == "text 40000").count();
        if texts == 4 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert_eq!(texts, 4, "160 KB of text after the move, all of it");
    phone.send(&ToMac::Key { chord: Chord::new(0, "Escape"), down: None }).await;
    input.wait("key Escape").await;
    assert_eq!(phone.close_code(), None, "nothing closed for the budget");
    assert_eq!(h.status().relay.go_between_problem, None);
    assert_eq!(h.status().connected.map(|c| c.route), Some("direct"));

    // gone: 6 s without a datagram after the move ends it on the host
    drop(phone);
    until(|| h.status().connected.is_none().then_some(())).await;
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_old_phone_isnt_offered_it_and_no_direct_path_ends_the_session() {
    let r = match relay().await {
        Ok(r) => r,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let meet = format!("ws://127.0.0.1:{}", r.1);
    let (h, dir, device, key) = paired(&meet, Lines::default()).await;

    // a phone from before the go-between: its session names no relay, so it forgets this one
    let (old, info) = away(
        &meet,
        &device,
        &key,
        Options {
            features: None,
            go_between: true,
            ..Options::default()
        },
    )
    .await;
    assert_eq!(info.relay, None);
    drop(old);
    until(|| h.status().connected.is_none().then_some(())).await;

    // UDP blocked: no datagram ever, and 8 s after the session the host gives up
    let (mut phone, _) = away(&meet, &device, &key, Options::go_between()).await;
    let t0 = std::time::Instant::now();
    let said = phone.wait(Duration::from_secs(12), |m| matches!(m, ToPhone::NoDirect).then_some(())).await;
    assert!(said.is_some(), "noDirect");
    let after = t0.elapsed();
    assert!(after >= Duration::from_millis(7500) && after < Duration::from_secs(10), "{after:?}");
    // then it closes, and Settings says why until a session works
    assert!(matches!(phone.next(Duration::from_secs(3)).await, Some(Event::Closed) | None));
    until(|| (h.status().relay.go_between_problem == Some(GoBetweenProblem::NoDirect)).then_some(())).await;
    assert!(h.status().connected.is_none());
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test(flavor = "multi_thread")]
async fn away_an_overlay_address_wins_over_the_go_between() {
    let r = match relay().await {
        Ok(r) => r,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let meet = format!("ws://127.0.0.1:{}", r.1);
    let (h, dir, device, key) = paired(&meet, Lines::default()).await;
    let port = h.status().port;

    // the phone keeps the candidates a session names: the overlay addresses among them are tried over TCP next time
    let (first, _) = away(&meet, &device, &key, Options::go_between()).await;
    let kept = first.candidates();
    drop(first);
    until(|| h.status().connected.is_none().then_some(())).await;
    let tailscale = Candidate { host: "100.101.102.103".into(), port: 1 };
    let lan = Candidate { host: "192.168.1.20".into(), port: 1 };
    let public = Candidate { host: "203.0.113.5".into(), port: 1 };
    let t = blurt_remote::phone::overlay_targets(&[tailscale, lan, public], port);
    assert_eq!(t, [format!("100.101.102.103:{port}").parse().unwrap(), format!("192.168.1.20:{port}").parse::<SocketAddr>().unwrap()]);
    assert_eq!(blurt_remote::phone::path_label(t[0]), "Tailscale");
    let _ = kept;

    // an address that answers (loopback standing in for the overlay's) and the go-between: both work, the overlay wins
    tokio::time::sleep(Duration::from_millis(800)).await; // the host's waiting connection back in the room
    let at: SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();
    let (mut p, label) = Phone::connect_away(Some(&meet), &[at], &device, &key, Options::go_between()).await.expect("away");
    assert_eq!(label, "Overlay network");
    let info = p.wait(Duration::from_secs(5), |m| if let ToPhone::Session(i) = m { Some(i.clone()) } else { None }).await.expect("session");
    assert!(!info.candidates.is_empty() || cfg!(not(target_os = "macos")));
    until(|| h.status().connected.filter(|c| c.route == "local")).await; // loopback isn't an overlay address on the host's side
    drop(p);
    until(|| h.status().connected.is_none().then_some(())).await;

    // nothing answers there (a closed port): the go-between carries it
    let closed: SocketAddr = {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        l.local_addr().unwrap()
    };
    tokio::time::sleep(Duration::from_millis(800)).await;
    let (_p, label) = Phone::connect_away(Some(&meet), &[closed], &device, &key, Options::go_between()).await.expect("away");
    assert_eq!(label, "relay");
    until(|| h.status().connected.filter(|c| c.route == "goBetween")).await;
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}

/// "Busy today": a go-between that refuses the upgrade (429, Cloudflare's 1015) is said so in Settings, and not asked again in a
/// loop: the next try waits 30 s.
#[tokio::test(flavor = "multi_thread")]
async fn a_busy_go_between_is_said_and_not_retried_in_a_loop() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let meet = format!("ws://{}", l.local_addr().unwrap());
    let asked = Arc::new(Mutex::new(0usize));
    let a2 = asked.clone();
    tokio::spawn(async move {
        while let Ok((mut s, _)) = l.accept().await {
            let mut b = [0u8; 2048];
            let n = s.read(&mut b).await.unwrap_or(0);
            if String::from_utf8_lossy(&b[..n]).contains("/v1/") {
                *a2.lock().unwrap() += 1;
            }
            let _ = s.write_all(b"HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
        }
    });
    let dir = std::env::temp_dir().join(format!("blurt-remote-busy-{}", blurt_remote::crypto::new_id()));
    let h = Host::start(
        HostConfig { dir: dir.clone(), name: "Studio PC".into(), version: "1.0.27".into(), test_answer: Some(true), port: 0, go_between: Some(meet.clone()) },
        Box::new(TestBackend(TestInput(Lines::default()))),
        Box::new(FileKeyStore::new(dir.join("keys.json"))),
        Box::new(Quiet),
    );
    // a code showing: the host waits in its room, and is refused
    h.show_pairing(true);
    until(|| (h.status().relay.go_between_problem == Some(GoBetweenProblem::Busy)).then_some(())).await;
    tokio::time::sleep(Duration::from_secs(3)).await;
    let n = *asked.lock().unwrap();
    assert!((1..=2).contains(&n), "asked {n} times in 3 s"); // the code and the code before it, once each
    // the switch off: nothing asks, and nothing is said about it
    h.set_go_between(false);
    assert!(!h.status().relay.go_between);
    assert_eq!(h.status().relay.go_between_problem, None);
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}

/// 2026-11-20, the office: the owner's relay was dead, and with a relay of one's own set nothing else was tried. Now, after two
/// failures in a row, the host waits at the go-between as well and says so; the relay answering again ends that.
#[tokio::test(flavor = "multi_thread")]
async fn a_dead_own_relay_falls_back_to_the_go_between() {
    let r = match relay().await {
        Ok(r) => r,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let meet = format!("ws://127.0.0.1:{}", r.1);
    let (h, dir, device, key) = paired(&meet, Lines::default()).await;
    // nothing listens on port 9
    h.set_relay(Some("ws://127.0.0.1:9")).unwrap();
    until(|| h.status().relay.fallback.then_some(())).await;
    assert_eq!(h.status().relay.reachable, Some(false));

    let (phone, _) = away(&meet, &device, &key, Options::go_between()).await;
    until(|| h.status().connected.filter(|c| c.route == "goBetween")).await;
    drop(phone);
    until(|| h.status().connected.is_none().then_some(())).await;

    // a working relay: the go-between is let go
    h.set_relay(Some(&meet)).unwrap();
    until(|| (!h.status().relay.fallback && h.status().relay.reachable == Some(true)).then_some(())).await;
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}

/// The computer cards' states (remote-1.1.md §1): a peek says the host is waiting in its room; once it's gone, since when.
#[tokio::test(flavor = "multi_thread")]
async fn a_peek_says_whether_the_host_waits_and_since_when_it_left() {
    let r = match relay().await {
        Ok(r) => r,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let meet = format!("ws://127.0.0.1:{}", r.1);
    let (h, dir, _device, key) = paired(&meet, Lines::default()).await;
    let room = blurt_remote::relay::room(&key);
    let (m, rm) = (meet.clone(), room.clone());
    let peek = move || {
        let (m, rm) = (m.clone(), rm.clone());
        async move { tokio::task::spawn_blocking(move || blurt_remote::relay::peek(&m, &rm)).await.unwrap() }
    };
    for _ in 0..100 {
        if peek().await.is_some_and(|p| p.host) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert_eq!(peek().await.map(|p| p.host), Some(true), "its waiting connection is in the room");
    h.stop();
    let mut gone = None;
    for _ in 0..100 {
        // gone, and its leaving written down (the relay sees it closing a moment before its close comes in)
        gone = peek().await.filter(|p| !p.host && p.seen.is_some());
        if gone.is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let p = gone.expect("gone from the room");
    assert!(p.seen.is_some() && p.asleep.is_none(), "{p:?}");
    tokio::task::spawn_blocking(move || drop(h)).await.unwrap();
    let _ = std::fs::remove_dir_all(dir);
}
