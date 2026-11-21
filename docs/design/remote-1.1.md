# Remote Control 1.1.0: reachable any time, safe to leave on, AI on the remote

Status: draft 3 (2026-11-20), after a five-person user panel (two rounds), for the founder's review. Sources: the founder's day of
real use at home and at the office, NetEase UU Remote (recording, home screenshot, its control centre read on the live app), research on
lock/login-screen capture per OS. The version is **1.1.0**.

## What went wrong on 2026-11-20

| What the founder saw | Cause | 1.1.0 |
|---|---|---|
| M1 Max (MacBook Pro, macOS 15.7.2, FileVault on) ran flat; plugged in, it showed a password screen: Blurt failed, UU showed the screen and took the password | **Not a restart** (up 197 days): the battery ran out, the Mac hibernated, and woke to the **lock screen** of the logged-in session. Blurt was running; its host log shows the home viewer's session opened at 09:41 over the LAN and frames went out, then 18–32 % loss, the rate fell to 10 fps / 200 kbps, mostly nothing sent, and at 09:59 the viewer went silent. The viewer kept no log, so what it showed is unknown | the lock screen must work for the user's own host (§1: capture through the lock, input to its password field); viewer events kept (done) |
| From the office, M1 Max unreachable; lid open, UU connected to it | **The M1 Max's relay is dead.** It has its own relay address (not this Mac's), and that relay fails the TLS handshake from both networks; the host retried it every ~10 s from 09:40 to 12:22 ("waiting") and no session from the office ever reached it. With an own relay set, the public connection service is switched off, so there was no fallback, and neither end said why | try the public service when the own relay fails; say "对方的中转连不上" on the card and on the host; one relay setting across the user's own computers (§1) |
| Mac mini: "needs Screen Recording" over a huge pointer | leftover BlurtHostTest copy lacks the grant; the pointer was scaled by the 16 × 10 placeholder | pointer only once a frame is up (done); remove the test copy |
| ⌥R: the take's first second shows Blurt's viewer, not UU | Blurt became active while the picker was up | the take starts once the picked app is frontmost again |
| "After a drop, do I pair again?" | No, it reconnects by itself | 正在重新连接… over the last picture |

## The panel

| | Who | Their one thing |
|---|---|---|
| A | indie dev, Mac Studio + MacBook Pro, Claude Code all day, FileVault on | dictation onto the remote; know why it won't connect |
| B | Berlin designer, Mac mini at the studio, FileVault on, privacy-minded | a service worth trusting: signed, logged, revocable |
| C | family tech support for parents' Windows laptop and iMac | anti-scam; parents never have to do anything |
| D | office MacBook (MDM) → home Windows 11 + RTX 4080 | Windows service (UAC, login after updates); Mac→Windows keys |
| E | Ubuntu 26.04 + NVIDIA, LUKS, auto-lock 5 min | Linux lock screen, but only with a privilege-split root service |

Agreed by all five: the Windows service ships in 1.1.0; the Mac login-window service can wait (FileVault Macs, which macOS recommends,
can't use it); no last picture on the cards by default; a public relay over TCP 443 as a fallback (free but limited, paired devices only;
self-hosted only is a non-starter); a host that always says who is controlling it; dictation never typed into a password field; cut the
small always-on-top window.

## 1.1.0

### 1. Reachable, and says why not
- **States with reasons, never guesses**: 可连接 · 直连/中转 · 在登录界面 · 已睡眠 · 10:42 起 · 上次在线 03:12 (then the likely reasons and
  what to do: "如果它重启过且开了 FileVault，需要有人在电脑前输密码" / "让家人插上电源、打开盖子") · 这个网络挡住了直连 → 已改走中转.
  "Asleep since" can be turned off on the host (it tells the public service when the computer is up).
  Built: relays answer `GET …/v1/<room>/peek` with `{host, asleep, seen}` (server.js, both Workers; tools/remote-relay/test.mjs covers
  it). A Mac about to sleep closes its waiting connections with 4010 and opens none until it wakes; Settings → "显示本机睡眠时间" (on)
  turns that off. Viewers (Mac, Windows/Linux) peek each closed computer once a minute while a list shows: "已睡眠 · 10:42 起",
  else "离线 · 3 小时前"; an older relay answers 404 and the card stays as before. Not yet: Windows/Linux hosts saying "asleep" (they
  show "last seen"), the phones' cards, and the deployed go-between and own relays (deployed with the release).
- **保持可连接 / Stay awake for remote access**: keeps only the computer awake; the screen still turns off on its own timer. Asked once
  when the computer is first paired as a host, with what it costs (a desktop: a few to tens of watts; a laptop: only while plugged in,
  and a closed lid still sleeps). Says that it overrides the system's sleep timer, not the display timer.
- **A relay that fails is said and routed around** (the 11-20 office failure): the host shows 中转连不上 in its own status and tells
  the public service so viewers can say it; while the own relay fails, both ends also try the public connection service. The user's
  own computers share one relay setting (set on one, offered to the others) so a stale address can't linger on one of them.
  Built (all hosts and viewers): two failed tries in a row count as down; the host then also waits at the go-between (unless its switch
  is off) and Settings says "自建中转无响应，暂用公共连接服务"; viewers try the go-between too and say why on the card and window. Tests:
  crates/blurt-remote tests/go_between.rs and tests/viewer.rs `a_dead_own_relay_*`.
- **A public relay over TCP 443** when direct fails (office and hotel networks): sealed end to end like today, only for paired devices
  holding a ticket from the connection service, low bitrate, a monthly cap per computer. Self-hosting stays documented.
- **Reconnect cover**: the last picture dimmed with 正在重新连接…; on the host, a reconnect shows nothing alarming.

### 2. Windows system service (lock, login after updates, UAC, Ctrl+Alt+Del)
- LocalSystem service, opt-in with one plain explanation; a headless host in the console session that follows Default/Winlogon/UAC
  desktops; Ctrl+Alt+Del via SendSAS; Windows Hello PIN typed like any key.
- **Privilege split** (all services, from E and B): a small capture-and-input process with no network; networking and crypto in an
  unprivileged process; a local socket that checks who's calling, so no other local user can read the screen.
- Only devices a logged-in user already paired; pairing is never offered at the login or lock screen.
- Signed updates (the updater's own key). The installer stays unsigned for now (founder, 2026-11-21: no paid certificate, and not SignPath Foundation, which needs the founder's account and a click per release and shows SignPath as the publisher); the Defender gate (`scripts/defender-check.ps1`) runs on every release and false positives are reported.

**How it's built (draft 4, 2026-11-20):**

| process | runs as | network | does |
|---|---|---|---|
| `blurt-remote-service.exe` | LocalSystem, session 0 | none | starts the agent in the console session and again after each logon, logoff or switch; starts the standby host when no Blurt of a logged-in user is hosting; SendSAS for Ctrl+Alt+Del |
| `blurt-remote-service.exe agent` | LocalSystem, console session | none | the existing Windows backend (DXGI Desktop Duplication, Media Foundation, SendInput) on whichever desktop has the input: Default, Winlogon (lock, login), the UAC prompt; one named pipe |
| Blurt (the user's app) | the user | yes | the host as today; with the service on, its screen and input go through the pipe (`agent::Proxy`), its clipboard stays its own |
| `blurt-remote-service.exe standby` | LocalService | yes | at the login screen, or when no one's Blurt runs: the same host over the pipe, with the paired devices the user's app handed the service (ProgramData, SYSTEM-only) |

The pipe's DACL lets in only SYSTEM, the console user and LocalService; the agent also checks the caller's process (its image is
Blurt's or the service's). Frames cross the pipe encoded (H.264 / HEVC), so it carries kilobytes, not raw pixels. Turned on in
Settings → Remote Control (one UAC prompt: `blurt-remote-service.exe install`), off the same way; the uninstaller removes it.

Built and tried on Windows Server 2022 (GCP `blurt-win3`, 2026-11-20): `crates/blurt-remote/src/agent.rs` (the protocol, tested on
every OS), `platform/windows/{service,desktop}.rs`, `src/bin/blurt-remote-service.rs`, `examples/agent_probe.rs`.

| what | result |
|---|---|
| logged-in desktop through the agent | picture (DXGI duplication), keys |
| lock screen (`LockWorkStation`) | picture: the lock image is on the Default desktop |
| Ctrl+Alt+Del (`SendSAS`, allowed for services at install) | the curtain lifts; capture follows to Winlogon |
| UAC consent prompt | picture on the secure desktop; Alt+Y from the remote approved it (an Administrator cmd opened) |
| login screen, no one logged in | the standby host (LocalService) answered a paired device over the internet with the login picture |

Learned: one duplex synchronous pipe deadlocks (a blocking read holds up the frames' writes): two one-way pipes. Duplication gives no
ACCESS_LOST when the input moves to the secure desktop, it only stops: the agent looks at the input desktop every 250 ms. The
agent writes a short log (%ProgramData%\Blurt Remote\agent.log). Not yet: the real Blurt build on Windows (the Settings switch's
UAC prompt, `replace_backend`, `sync_standby`), Windows 11's Hello PIN, clippy on Windows.

### 2b. Mac: the lock screen (1.1.0, founder's call 2026-11-20) and the login window
- Measured on the M1 Max (macOS 15.7.2, 2026-11-20): once the session locks, ScreenCaptureKit sends no more frames, and the 1.0.27
  viewer kept showing the last desktop as if live (link up, pointer moving).
- UU Remote, read on this Mac: a root LaunchDaemon plus an agent in /Library/LaunchAgents loaded for `LoginWindow` and `Aqua` (as the
  user once logged in); its capture library carries ScreenCaptureKit and CGDisplayStream both.
- 1.1.0: while locked the host captures with CGDisplayStream at the encoder's size; if that brings nothing within 1.5 s the viewer gets
  `screenLocked(true)` and shows the last frame darker with "已锁屏"; on unlock ScreenCaptureKit is started again. A drop keeps the last
  frame the same way with "正在重新连接…". Typing at the lock screen: CGEventPost after clearing stale modifiers.
- The login window (after a restart without FileVault, or logged out): the same agent loaded for `LoginWindow`, installed once with the
  admin password; it hands over to the user's host at login.

### 3. Safe to leave on (anti-scam, trust)
- Pairing yes on the host: big text, "只允许你自己或家人连接。警察、银行、客服不会让你安装或允许这个。", the six digits, and the requesting
  device's name.
- Every new pairing **notifies every already-paired device** and goes in the host's log. **需要已配对设备批准新配对** is a switch on the
  host (suggested when setting up someone else's computer; changing it needs the host's admin password).
- Built: the pairing question carries the anti-scam line (Mac card, Windows/Linux sheet). The host's bar (Mac: a panel under the menu
  bar; Windows/Linux: a small always-on-top window) shows while a device is connected; 断开 sends `ended` (wire, vectors), and every
  viewer stops and offers 重新连接 instead of reconnecting by itself.
- The host always shows **正在被「John 的 MacBook」控制 · 断开** (Chinese-first, no jargon on the controlled side), and a **连接记录**
  (who, when, how long, from where, files received).
- **Remove a device from anywhere**: any paired device of the same owner can revoke another; the host drops it at once.
- **隐私屏 / Black out remote screen**: off by default; when on, the host's screen shows "正在被 John 的 MacBook 远程使用，画面已隐藏",
  never plain black. Mac and Windows; Linux says it can't.
- Received files keep the quarantine flag (Mac) / Mark of the Web (Windows); they're not run by themselves.

### 4. AI on the remote (on by default, no menu)
- **Dictation types on the remote**: hold the dictation key with a viewer in front; the key itself is never sent to the remote, so it
  coexists with 按键发往远端. The host refuses text while its lock or login screen or a password field is in front. Into a terminal (the
  host reports the front app) no trailing 。. Polishing and screen-text recognition run where they run today; the viewer says which model.
- ⌥C / ⌥T / ⌥A on the remote picture already work; the first connection shows a one-line tip.

### 5. Keys across systems
- The take-back key changes from Ctrl+Alt (clashes with Ctrl+Alt+T, Ctrl+Alt+arrows, Ctrl+Alt+Del) to one that can be set; ⌃⌘ stays on Mac.
- A key map in the control centre: Win/Super, Alt/Option, AltGr, and how to switch input methods on the remote.
- With ⌘ 当作 Ctrl, ⌘C/⌘V in a terminal on the remote send copy/paste (Ctrl+Shift+C/V), never an interrupt.
- Text injection bypasses the remote's input method; on Linux the clipboard is put back after the paste.

Built (keys): the dictation key never reaches the remote. Mac: the trigger's flagsChanged stays local. Windows/Linux: right Alt (or
either Alt) is held back and sent only with another key, so AltGr chords still type. With ⌘ 当作 Ctrl, ⌘C / ⌘V into a terminal on a
Windows or Linux host send Ctrl+Shift+C / V (RemoteTerminals: bundle ids and program names).

### 6. The viewer and the page
Built (files): `fileBegin` / `fileChunk` / `fileEnd` → `fileProgress` / `fileSaved` / `fileFailed` (vectors). The sender keeps ≤ 4 MB
unacknowledged; the host writes `<name>.part` in Downloads, renames it, and quarantines it (Mac quarantine flag, Windows Mark of the
Web), refuses at the lock screen, deletes a part left by a dropped session; at most 4 GB; a notification on the host. Mac viewer: drop
on the picture or 发送文件…; Windows/Linux viewer: 发送文件…. Tests: crates/blurt-remote incoming.rs, tests/viewer.rs.
- Title bar: name, display tabs, 直连/中转 and delay, **按键发往远端**, **控制中心 ▾** (画质 · 窗口 (适应窗口, 实际大小 1:1, 全屏) · 键盘与鼠标
  (⌘ 当作 Ctrl, 按键对照, Ctrl+Alt+Del, 只看) · 发送文件… (also by drop; lands in the host's Downloads) · 共享剪贴板 · 安全 (隐私屏, 立即锁定,
  断开时锁定对方, kept apart) · 显示网络状态 · 断开). "只看 / View only" is the one name everywhere.
- The Remote Control page: computer cards with state and reason, time connected or last seen; the last picture only if turned on.
- The viewer says which permissions it needs on this computer (Accessibility for Keys to Remote) before asking.
- **Rename (founder's call):** a paired device or computer gets a name of the user's own on this computer only: nothing is sent to the
  other side, the record's id never changes, and the host's later hello or DNS-SD name never overwrites it (an `alias` kept beside the
  record and shown first: Mac `RemoteServer.Device.alias`, `RemoteComputer.alias`). Inline, in place of the name: Return keeps it, Esc
  puts it back, an empty field brings the device's own name back (and the renamed name's tooltip says that own name). Ways in: on
  the Remote Control page a double-click on the name (both lists; elsewhere on a computer's row a double-click still opens it), and
  重命名… / Rename… in every row's ⋯ and context menu; in the Computers window only the ⋯ and context menu, since a double-click
  anywhere on a row opens the computer there (Finder's rule). The alias is what this Mac shows wherever it names the device: the
  page, the "being controlled" bar, the pairing question, the privacy cover, a received file's notification, the viewer window's
  title and its covers, Add Computer's pairing card when a computer is added again. The anti-scam notice sent to other devices keeps
  the names they gave. Tests: `RemoteAliasTests`.
  Windows/Linux: the same, with a double-click on the name in both lists (`Device.alias`, `Computer.alias`; old files load):
  `remote_rename_device`, `computers_rename`; tests in store.rs, viewer.rs, tests/server.rs, web rename.test.ts.

### 7. Linux preview (opt-in, separate package)
`blurt-system-service` deb, never enabled by the main package, `apt purge` removes everything: a privilege-split root service that reads
the display from the kernel (DRM/KMS) and types through uinput, for the lock and the GDM login screen. Per-user scope (A's devices see the
greeter and A's session only), admin approval to attach a device, journald log and a notice after unlock. Intel/AMD/virtio first;
"NVIDIA proprietary driver: not supported yet" until tested. LUKS: remote restart warns that the disk needs a password at the computer.

## 1.1.x
Mac login-window service + FileVault-aware restart (unless the founder pulls it in) · files both ways with resume · Wake-on-LAN through
another Blurt device on the same network · Touch ID before the viewer opens (optional) · notify me when an agent on the remote needs me ·
iPhone on TestFlight · rename this computer for the people controlling it · Linux service stable · silent updates for hosts with the service.

## Order of work
1. The office failure's cause (M1 Max host log), fixes, honest states, reconnect cover, stay awake.
2. Safety: pairing warning, notify paired devices, the always-on bar, connection log, remote revoke.
3. Dictation on the remote, keys across systems, the viewer's control centre, send files.
4. Windows service with the privilege split; signed installer.
5. 443 relay with caps.
6. Linux preview package.
Tried on real machines: M1 Max (Mac host, through UU while away), a rented Windows 11 VM, a rented Ubuntu 26.04 VM; this Mac only views.
