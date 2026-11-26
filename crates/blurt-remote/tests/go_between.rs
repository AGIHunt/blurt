//! The go-between end to end (docs/design/remote-go-between.md): the real host and the Rust test phone through
//! `BUDGET=1 node tools/remote-relay/server.js`, the relay with the public go-between's limits (16 KiB a message, 96 KiB a
//! connection, 24 KiB in any 5 s, then 4003).
//!
//!  • the session opens through it, the direct path opens, both ends move their stream onto it, and keys, a pong and far more
//!    than the budget arrive after the move with nothing closed for being over it;
//!  • a phone from before the go-between isn't offered it; with UDP blocked the host says `noDirect` after 8 s and closes.
//!
//!  • with no direct path, the session goes on at Blurt's public relay (`node tools/remote-relay/public.js`, tickets from the
//!    go-between): keys and Opus voice pass, the picture waits for a lease and is Data Saver's; one lease (`LEASES=1`) is busy for a
//!    second computer until the first gives it back; a dead relay is the no-direct line, at once on the host, within 5 s on the phone.
//!
//! Skipped (with a line saying so) where node, the `ws` package or the relay's budget mode isn't there.

use std::net::SocketAddr;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use blurt_remote::host::{
    Backend, Button, Crop, CursorShape, EncodedFrame, FrameSink, Input, Screen, ScreenConfig, ScreenInfo, ScrollPhase, SystemMove,
};
use blurt_remote::phone::{pair, Event, Options, Phone, Watch, Weather};
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

/// A screen that sends nothing and writes down what it was asked for: (width, height, bitrate, fps) of each start, and stops.
/// (width, height, bitrate, fps)
type Start = (u32, u32, u32, u32);

#[derive(Clone, Default)]
struct Asked(Arc<Mutex<Vec<Start>>>, Arc<Mutex<usize>>);

struct TestScreen(Asked);

impl Screen for TestScreen {
    fn start(&mut self, c: &ScreenConfig, _: FrameSink) -> Result<ScreenInfo, String> {
        self.0 .0.lock().unwrap().push((c.width, c.height, c.bitrate, c.fps));
        Ok(ScreenInfo { width: 1440.0, height: 900.0, codec: "h264".into() })
    }
    fn set_crop(&mut self, _: Crop) {}
    fn set_rate(&mut self, _: u32, _: u32) {}
    fn keyframe(&mut self) {}
    fn refresh(&mut self) {}
    fn stop(&mut self) {
        *self.0 .1.lock().unwrap() += 1;
    }
}

struct TestBackend(TestInput, Option<TestScreen>);

impl Backend for TestBackend {
    fn input(&mut self) -> &mut dyn Input {
        &mut self.0
    }
    fn screen(&mut self) -> Option<&mut dyn blurt_remote::host::Screen> {
        self.1.as_mut().map(|s| s as &mut dyn Screen)
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
    node("server.js", &[("BUDGET", "1".into())], "blurt go-between").await
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

/// `tools/remote-relay/<script>` on a free port with these settings, once `GET /` answers with `says`.
async fn node(script: &str, env: &[(&str, String)], says: &str) -> Result<Relay, String> {
    let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let server = repo.join("tools/remote-relay").join(script);
    if !server.exists() {
        return Err(format!("no {script} here"));
    }
    let port = free_port();
    let mut c = Command::new("node");
    c.arg(&server).env("HOST", "127.0.0.1").env("PORT", port.to_string()).stdout(Stdio::null()).stderr(Stdio::null());
    for (k, v) in env {
        c.env(k, v);
    }
    if let Some(p) = ws_module(&repo) {
        c.env("NODE_PATH", p);
    }
    let child = c.spawn().map_err(|e| format!("node: {e}"))?;
    let r = Relay(child, port);
    // up, and the right one: GET / says so
    for _ in 0..50 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        if let Ok(mut s) = tokio::net::TcpStream::connect(("127.0.0.1", port)).await {
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            let _ = s.write_all(b"GET / HTTP/1.0\r\nHost: x\r\n\r\n").await;
            let mut b = vec![];
            let _ = tokio::time::timeout(Duration::from_secs(2), s.read_to_end(&mut b)).await;
            return if String::from_utf8_lossy(&b).contains(says) { Ok(r) } else { Err(format!("{script} isn't the one this test needs")) };
        }
    }
    Err("the relay didn't start (node, or its ws package, missing?)".into())
}

/// Blurt's public relay (`public.js`, `LEASES` at once) and a go-between that gives tickets to it, sharing a secret: (go-between,
/// public relay). `public_at`: the address the go-between names instead (a dead one).
async fn public_pair(leases: u32, public_at: Option<String>) -> Result<(Relay, Relay), String> {
    public_pair_with(leases, public_at, &[]).await
}

/// The same, with more of the public relay's settings (its budgets, say).
async fn public_pair_with(leases: u32, public_at: Option<String>, more: &[(&str, String)]) -> Result<(Relay, Relay), String> {
    let secret = blurt_remote::crypto::base64url(&blurt_remote::crypto::new_key());
    let mut env = vec![("TICKET_SECRETS", secret.clone()), ("LEASES", leases.to_string())];
    env.extend(more.iter().cloned());
    let public = node("public.js", &env, "blurt relay").await?;
    let named = public_at.unwrap_or_else(|| format!("ws://127.0.0.1:{}", public.1));
    let meet = node("server.js", &[("BUDGET", "1".into()), ("TICKET_SECRET", secret), ("PUBLIC_RELAY", named)], "blurt go-between").await?;
    Ok((meet, public))
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
    paired_with(meet, None, input, None).await
}

/// The same, with Blurt's public relay let in at `public` and a screen that writes down what it's asked.
async fn paired_with(meet: &str, public: Option<&str>, input: Lines, screen: Option<Asked>) -> (Host, std::path::PathBuf, String, Vec<u8>) {
    paired_on(meet, public, Box::new(TestBackend(TestInput(input), screen.map(TestScreen)))).await
}

/// The same, with any backend.
async fn paired_on(meet: &str, public: Option<&str>, backend: Box<dyn Backend>) -> (Host, std::path::PathBuf, String, Vec<u8>) {
    let dir = std::env::temp_dir().join(format!("blurt-remote-meet-{}", blurt_remote::crypto::new_id()));
    let h = Host::start(
        HostConfig {
            dir: dir.clone(),
            name: "Studio PC".into(),
            version: "1.0.27".into(),
            test_answer: Some(true),
            port: 0,
            go_between: Some(meet.into()),
            public_relay: public.map(String::from),
        },
        backend,
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
        Some(&["move", "viewer", "publicRelay", "opus"].map(String::from)[..])
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

/// The phone leaves a moved session and is back before the host has noticed (6 s of no datagrams): the room has the host in it again, and
/// the session is the same device's new one (docs/design/remote.md §Coming back; before, it was out of the room for 9 s).
#[tokio::test(flavor = "multi_thread")]
async fn a_phone_back_at_once_finds_the_host_in_the_room() {
    let r = match relay().await {
        Ok(r) => r,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let meet = format!("ws://127.0.0.1:{}", r.1);
    let (h, dir, device, key) = paired(&meet, Lines::default()).await;
    for round in 0..2 {
        let (mut phone, mut info) = away(&meet, &device, &key, Options::go_between()).await;
        info.candidates.push(Candidate { host: "127.0.0.1".into(), port: info.udp_port });
        phone.open_direct(&info).await.unwrap();
        let t0 = std::time::Instant::now();
        while !phone.moved() && t0.elapsed() < Duration::from_secs(5) {
            let _ = phone.next(Duration::from_millis(100)).await;
        }
        assert!(phone.moved(), "round {round}");
        until(|| h.status().connected.filter(|c| c.route == "direct")).await;
        // gone with no goodbye but the WebSocket's end
        drop(phone);
        let left = std::time::Instant::now();
        loop {
            match Phone::connect_relay_with(&meet, &device, &key, Options::go_between()).await {
                Ok(mut p) => {
                    let s = p.wait(Duration::from_secs(5), |m| matches!(m, ToPhone::Session(_)).then_some(())).await;
                    if s.is_some() {
                        break;
                    }
                }
                Err(_) => tokio::time::sleep(Duration::from_millis(200)).await,
            }
            assert!(left.elapsed() < Duration::from_secs(5), "still out of the room (round {round})");
        }
        eprintln!("back after {:?}", left.elapsed());
        assert!(left.elapsed() < Duration::from_secs(4), "{:?}", left.elapsed());
        // that one goes too, before the next round
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
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
        HostConfig { dir: dir.clone(), name: "Studio PC".into(), version: "1.0.27".into(), test_answer: Some(true), port: 0, go_between: Some(meet.clone()), public_relay: None },
        Box::new(TestBackend(TestInput(Lines::default()), None)),
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

// ------------------------------------------------------------------ Blurt's public relay

/// A phone that goes on at the public relay and sends its voice as Opus.
fn public_phone() -> Options {
    Options { features: Some(["move", "publicRelay", "opus"].map(String::from).to_vec()), go_between: true, ..Options::default() }
}

fn big_picture() -> blurt_remote::wire::ScreenRequest {
    blurt_remote::wire::ScreenRequest {
        target: "display".into(),
        crop: blurt_remote::wire::Crop::WHOLE,
        width: 2560,
        height: 1600,
        bitrate: 8_000_000,
        fps: 60,
        codecs: Some(vec!["h264".into()]),
        display: None,
        features: None,
        window: None,
    }
}

/// Control messages until `want` takes one, within `t`, with a ping a second meanwhile (the host ends a session quiet for 12 s).
async fn wait_pinging<T>(p: &mut Phone, t: Duration, want: impl Fn(&ToPhone) -> Option<T>) -> Option<T> {
    let end = std::time::Instant::now() + t;
    while std::time::Instant::now() < end {
        p.send(&ToMac::Ping(0.0)).await;
        if let Some(x) = p.wait(Duration::from_secs(1), &want).await {
            return Some(x);
        }
    }
    None
}

/// Through the go-between with no direct path (the phone never knocks): the host's `publicRelay` just before its `noDirect` 8 s on,
/// then in at the public relay with the phone's ticket, within 5 s.
async fn on_public(meet: &str, public: &str, device: &str, key: &[u8]) -> Phone {
    let (mut phone, info) = away(meet, device, key, public_phone()).await;
    let f = info.features.unwrap_or_default();
    assert!(f.iter().any(|x| x == "publicRelay") && f.iter().any(|x| x == "opus"), "{f:?}");
    let t0 = std::time::Instant::now();
    assert!(phone.wait(Duration::from_secs(14), |m| matches!(m, ToPhone::NoDirect).then_some(())).await.is_some(), "noDirect");
    let after = t0.elapsed();
    assert!(after >= Duration::from_millis(7500) && after < Duration::from_secs(12), "{after:?}");
    let (address, room, ticket) = phone.public_offer(Some(public)).expect("publicRelay just before noDirect");
    assert_eq!(address, public);
    assert_eq!(room.len(), 43);
    // a release build goes only to the one address it knows
    assert!(phone.public_offer(None).is_none());
    drop(phone);
    let t1 = std::time::Instant::now();
    let q = Phone::connect_public(&address, &room, &ticket, device, key, public_phone()).await.expect("in at the public relay");
    assert!(t1.elapsed() < Duration::from_secs(5));
    // a ticket opens one connection
    assert!(Phone::connect_public(&address, &room, &ticket, device, key, public_phone()).await.is_err());
    q
}

#[tokio::test(flavor = "multi_thread")]
async fn no_direct_path_goes_on_at_the_public_relay() {
    let (r, p) = match public_pair(10, None).await {
        Ok(x) => x,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let (meet, public) = (format!("ws://127.0.0.1:{}", r.1), format!("ws://127.0.0.1:{}", p.1));
    let (input, asked) = (Lines::default(), Asked::default());
    let (h, dir, device, key) = paired_with(&meet, Some(&public), input.clone(), Some(asked.clone())).await;

    let mut q = on_public(&meet, &public, &device, &key).await;
    until(|| h.status().connected.filter(|c| c.route == "publicRelay")).await;
    assert_eq!(h.status().relay.go_between_problem, None, "the public relay carries it");

    // keys
    q.send(&ToMac::Key { chord: Chord::new(8, "C"), down: None }).await;
    assert_eq!(input.wait("held 0").await, ["held 8", "key C 0 None", "held 0"]);

    // voice as Opus: a second of it reaches dictation, as 20 ms frames
    let (tx, rx) = std::sync::mpsc::channel();
    h.mic().attach(tx);
    let pcm: Vec<u8> =
        (0..16_000).flat_map(|i| (((i as f64 * 440.0 * std::f64::consts::TAU / 16_000.0).sin() * 8000.0) as i16).to_le_bytes()).collect();
    let mut enc = blurt_remote::opus::Encoder::new().unwrap();
    let packets = enc.encode(&pcm);
    assert_eq!(packets.len(), 50);
    for pk in &packets {
        q.opus(pk).await;
    }
    let mut frames = 0;
    while frames < 50 {
        match rx.recv_timeout(Duration::from_secs(3)) {
            Ok(f) => {
                assert_eq!(f.len(), 320);
                frames += 1;
            }
            Err(_) => break,
        }
    }
    assert_eq!(frames, 50, "a second of voice");

    // the picture, asked for big: it waits for the lease, and comes as Data Saver's
    q.send(&ToMac::Screen(Some(big_picture()))).await;
    let view = q.wait(Duration::from_secs(5), |m| matches!(m, ToPhone::ScreenView { .. }).then_some(())).await;
    assert!(view.is_some(), "the picture, with a lease");
    let (w, _, bitrate, fps) = asked.0.lock().unwrap()[0];
    assert!(w <= 1280 && bitrate <= 1_000_000 && fps <= 15, "{:?}", asked.0.lock().unwrap());
    // off: it stops (and its lease goes back)
    q.send(&ToMac::Screen(None)).await;
    until(|| (*asked.1.lock().unwrap() >= 1).then_some(())).await;
    drop(q);
    until(|| h.status().connected.is_none().then_some(())).await;
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}

/// `LEASES=1`: a second computer's picture is busy (`screenFailed("busy")`, keys still working) until the first gives the lease back;
/// then it comes by itself, asked again within 30 s.
#[tokio::test(flavor = "multi_thread")]
async fn one_lease_is_busy_for_another_until_it_is_given_back() {
    let (r, p) = match public_pair(1, None).await {
        Ok(x) => x,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let (meet, public) = (format!("ws://127.0.0.1:{}", r.1), format!("ws://127.0.0.1:{}", p.1));
    let (a_asked, b_asked, b_input) = (Asked::default(), Asked::default(), Lines::default());
    let (ha, da, deva, keya) = paired_with(&meet, Some(&public), Lines::default(), Some(a_asked.clone())).await;
    let (hb, db, devb, keyb) = paired_with(&meet, Some(&public), b_input.clone(), Some(b_asked.clone())).await;
    let (mut a, mut b) = tokio::join!(on_public(&meet, &public, &deva, &keya), on_public(&meet, &public, &devb, &keyb));

    a.send(&ToMac::Screen(Some(big_picture()))).await;
    assert!(a.wait(Duration::from_secs(5), |m| matches!(m, ToPhone::ScreenView { .. }).then_some(())).await.is_some());
    b.send(&ToMac::Screen(Some(big_picture()))).await;
    let why = b.wait(Duration::from_secs(5), |m| if let ToPhone::ScreenFailed(w) = m { Some(w.clone()) } else { None }).await;
    assert_eq!(why.as_deref(), Some("busy"));
    assert!(b_asked.0.lock().unwrap().is_empty(), "no picture without a lease");
    // keys work meanwhile
    b.send(&ToMac::Key { chord: Chord::new(0, "Escape"), down: None }).await;
    b_input.wait("key Escape").await;

    // A's picture off: its lease goes back, and B's picture comes by itself
    a.send(&ToMac::Screen(None)).await;
    let t = std::time::Instant::now();
    let pinging_a = async {
        for _ in 0..40 {
            a.send(&ToMac::Ping(0.0)).await;
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    };
    let got = tokio::select! {
        v = wait_pinging(&mut b, Duration::from_secs(40), |m| matches!(m, ToPhone::ScreenView { .. }).then_some(())) => v,
        _ = pinging_a => None,
    };
    assert!(got.is_some(), "B's picture once A gave the lease back");
    eprintln!("B's picture {:?} after A gave the lease back", t.elapsed());
    assert!(t.elapsed() <= Duration::from_secs(32));
    assert_eq!(b_asked.0.lock().unwrap().len(), 1);
    for (h, d) in [(ha, da), (hb, db)] {
        h.stop();
        let _ = std::fs::remove_dir_all(d);
    }
}

fn clock() -> f64 {
    static T: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    T.get_or_init(std::time::Instant::now).elapsed().as_secs_f64()
}

/// Seconds from each picture's capture to the phone having it whole. Over a relay the host sends no clock, so each picture starts
/// with its capture time on `clock()`, which host and phone share here.
static AGES: Mutex<Vec<f64>> = Mutex::new(Vec::new());

fn age_of(data: &[u8]) -> bool {
    let Some(p) = blurt_remote::packets::unpack_payload(data) else { return false };
    let Some(at) = p.picture.get(..8) else { return false };
    AGES.lock().unwrap().push(clock() - f64::from_be_bytes(at.try_into().unwrap()));
    true
}

#[derive(Default)]
struct SteadySt {
    gen: u64,
    bitrate: u32,
    fps: u32,
    want_key: bool,
    /// the bitrate of each start, then of each `set_rate`
    rates: Vec<u32>,
    keyframes: usize,
}

/// A screen that keeps moving: frames at the rate it's given, each a frame's share of the bitrate (a keyframe four times that), and a
/// keyframe when asked, as a real encoder.
#[derive(Clone, Default)]
struct Steady(Arc<Mutex<SteadySt>>);

impl Screen for Steady {
    fn start(&mut self, c: &ScreenConfig, sink: FrameSink) -> Result<ScreenInfo, String> {
        let gen = {
            let mut s = self.0.lock().unwrap();
            s.gen += 1;
            (s.bitrate, s.fps, s.want_key) = (c.bitrate, c.fps, true);
            s.rates.push(c.bitrate);
            s.gen
        };
        let st = self.0.clone();
        std::thread::spawn(move || loop {
            let (f, gap) = {
                let mut s = st.lock().unwrap();
                if s.gen != gen {
                    return;
                }
                let fps = s.fps.clamp(1, 60);
                let per = (s.bitrate / 8 / fps).max(500) as usize;
                let key = std::mem::take(&mut s.want_key);
                s.keyframes += key as usize;
                let mut picture = clock().to_be_bytes().to_vec();
                picture.resize(if key { per * 4 } else { per }, 0x41);
                let f = EncodedFrame {
                    picture,
                    keyframe: key,
                    parameter_sets: if key { vec![vec![0x67, 1, 2], vec![0x68, 3]] } else { vec![] },
                    crop: Crop::WHOLE,
                    captured: clock(),
                    ..Default::default()
                };
                (f, 1.0 / fps as f64)
            };
            sink(f);
            std::thread::sleep(Duration::from_secs_f64(gap));
        });
        Ok(ScreenInfo { width: 1440.0, height: 900.0, codec: "h264".into() })
    }
    fn set_crop(&mut self, _: Crop) {}
    fn set_rate(&mut self, bitrate: u32, fps: u32) {
        let mut s = self.0.lock().unwrap();
        (s.bitrate, s.fps) = (bitrate, fps);
        s.rates.push(bitrate);
    }
    fn keyframe(&mut self) {
        self.0.lock().unwrap().want_key = true;
    }
    fn refresh(&mut self) {}
    fn stop(&mut self) {
        self.0.lock().unwrap().gen += 1;
    }
}

/// The test input and a moving screen.
struct MovingBackend(TestInput, Steady);

impl Backend for MovingBackend {
    fn input(&mut self) -> &mut dyn Input {
        &mut self.0
    }
    fn screen(&mut self) -> Option<&mut dyn Screen> {
        Some(&mut self.1)
    }
    fn platform(&self) -> &'static str {
        "linux"
    }
    fn display_aspect(&self) -> f64 {
        1.6
    }
    fn now(&self) -> f64 {
        clock()
    }
    fn keep_awake(&mut self, _: bool, _: bool) {}
}

/// The evening's cross-border path, made on loopback: the public relay passes the picture at 300 kbps (`LEASED_RATE`) and pauses
/// reading the host's connection past that, as it does whenever the far side can't keep up. The host is offered a screen moving at
/// its full 1 Mbps / 15 fps. A sender that sent every frame regardless (`measure-path.mjs`) was ~15 s behind on the real path at the
/// peak, and here would be about 10 s behind after 15 s; the real host has to stay within a few seconds by skipping frames (a
/// keyframe once the way is clear) and lowering its rate from the phone's reports (screen.rs `holding_back`, `report`).
#[tokio::test(flavor = "multi_thread")]
async fn a_slow_public_relay_costs_frames_not_seconds() {
    let (r, p) = match public_pair_with(10, None, &[("LEASED_RATE", (300_000 / 8).to_string()), ("LEASED_BURST", (64 * 1024).to_string())]).await
    {
        Ok(x) => x,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let (meet, public) = (format!("ws://127.0.0.1:{}", r.1), format!("ws://127.0.0.1:{}", p.1));
    let screen = Steady::default();
    let (h, dir, device, key) = paired_on(&meet, Some(&public), Box::new(MovingBackend(TestInput(Lines::default()), screen.clone()))).await;
    let mut q = on_public(&meet, &public, &device, &key).await;
    until(|| h.status().connected.filter(|c| c.route == "publicRelay")).await;

    let m = q.watch(Watch { request: big_picture(), warmup: 3.0, seconds: 15.0, weather: Weather::clear(), verify: Some(age_of) }).await;
    let (rates, keyframes) = {
        let s = screen.0.lock().unwrap();
        (s.rates.clone(), s.keyframes)
    };
    let mut ages = std::mem::take(&mut *AGES.lock().unwrap());
    ages.sort_by(f64::total_cmp);
    let (p50, p95, max) = (ages[ages.len() / 2], ages[ages.len() * 95 / 100], ages[ages.len() - 1]);
    eprintln!("through a 300 kbps relay: {m}; age p50/p95/max {p50:.2}/{p95:.2}/{max:.2} s; encoder rates {rates:?}, keyframes {keyframes}");
    assert_eq!(m.corrupt, 0);
    assert!(rates.iter().all(|r| *r <= 1_000_000), "Data Saver's picture at most: {rates:?}");
    assert!(*rates.last().unwrap() <= 400_000, "the encoder's rate comes down to what gets through: {rates:?}");
    assert!(m.mbps <= 0.33, "no more than the relay passes: {m}");
    assert!(m.shown >= 15, "the picture keeps coming, a frame a second at least: {m}");
    assert!(p95 < 3.0 && max < 5.0, "a few seconds behind at most, not a queue that grows: {p50}/{p95}/{max}");
    drop(q);
    until(|| h.status().connected.is_none().then_some(())).await;
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}

/// A dead public relay: the host can't get in and says `noDirect` alone, at once; a phone sent to one that never answers gives up after
/// 5 s, one that refuses at once at once.
#[tokio::test(flavor = "multi_thread")]
async fn a_dead_public_relay_is_the_no_direct_line() {
    let dead = format!("ws://127.0.0.1:{}", free_port());
    let (r, _p) = match public_pair(10, Some(dead.clone())).await {
        Ok(x) => x,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let meet = format!("ws://127.0.0.1:{}", r.1);
    let (h, dir, device, key) = paired_with(&meet, Some(&dead), Lines::default(), None).await;
    let (mut phone, _) = away(&meet, &device, &key, public_phone()).await;
    let t0 = std::time::Instant::now();
    assert!(phone.wait(Duration::from_secs(16), |m| matches!(m, ToPhone::NoDirect).then_some(())).await.is_some());
    let after = t0.elapsed();
    assert!(after < Duration::from_secs(8 + 5), "{after:?}");
    assert!(phone.public_offer(Some(&dead)).is_none(), "no publicRelay: the host couldn't get in");
    until(|| (h.status().relay.go_between_problem == Some(GoBetweenProblem::NoDirect)).then_some(())).await;

    // the phone's side
    let hole = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let hole_at = format!("ws://{}", hole.local_addr().unwrap());
    tokio::spawn(async move {
        let mut held = vec![];
        while let Ok((s, _)) = hole.accept().await {
            held.push(s); // taken, never answered
        }
    });
    let room = blurt_remote::public::new_room();
    let ticket = "1764000060.abcdefghijkl.abcdefghijklmnopqrstuv";
    let t1 = std::time::Instant::now();
    assert!(Phone::connect_public(&hole_at, &room, ticket, &device, &key, public_phone()).await.is_err());
    let took = t1.elapsed();
    assert!(took >= Duration::from_millis(4500) && took < Duration::from_millis(6500), "{took:?}");
    let t2 = std::time::Instant::now();
    assert!(Phone::connect_public(&dead, &room, ticket, &device, &key, public_phone()).await.is_err());
    // refused at once; Windows retries a refused SYN twice, ~0.5 s apart, before it gives up (about 2 s)
    let refused = if cfg!(windows) { Duration::from_secs(4) } else { Duration::from_secs(2) };
    assert!(t2.elapsed() < refused, "{:?}", t2.elapsed());
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}
