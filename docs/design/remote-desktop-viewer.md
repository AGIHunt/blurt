# One computer controlling another

2026-11-19. Status: designed; the Mac side built (below, §Built on the Mac), Windows and Linux being built. The founder approved the screens on 2026-11-19: a window per computer, a list of computers,
and a display switcher. Wire: [remote-protocol.md](remote-protocol.md). Paths away from home: [remote-go-between.md](remote-go-between.md).
Words: [copy.md](copy.md).

## What it is

Blurt on a Mac, Windows or Linux computer can show and drive another computer that runs Blurt. To the computer being driven (the
**host**), the driving computer (the **viewer**) is one more paired device, like a phone. It pairs the same way, connects by the same
paths, and gets the same picture and the same input messages. The host side gains almost nothing. The viewer is new on all three systems.

What it doesn't need from the phone: the key deck, the touch gestures, the zoomed-picture handling. A viewer has a real keyboard and mouse.

## The viewer

**The list of computers.** It opens from the menu bar or tray → 电脑 / Computers; on the Mac the same rows are on the main window's
手机和电脑 / Phones and Computers page (§One page for the devices).

- Each row shows the computer's name, its system, and a state: 已连接 · <path>, 可连接 · <path>, or 离线 · <when last seen>.
  It has one button: 打开窗口 / Open Window, 连接 / Connect, or 移除 / Remove.
- **添加电脑 / Add Computer:**
  - On the same network, nearby Blurt computers are listed, found by DNS-SD `_blurt-remote._tcp`. Choosing one starts pairing. The host
    shows six digits and asks for a yes, as for a new phone; the viewer shows the same six digits.
  - Away, the user pastes the pairing link from the host's 添加设备 / Add Device (`blurtremote://pair?…`).
  - **When it doesn't pair** (1.1.0, Mac viewer; `RemoteViewerLink.State.pairingFailed`), the host never says why (a refused handshake
    or a bare close), so the viewer reads it from when, and each case says what to do next. The sheet is never a dead end: Try Again
    where the same link or nearby computer can still work, else Back to the link field with the link still in it; Cancel closes.
    - refused before anyone was asked (`spent`): a link → 这个链接已过期或已被用过。 + how to get a new one (Back); nearby → the host
      isn't taking a new computer now (it's asking about another, or was just told no) + Try Again.
    - closed while the question was up (`declined`): %@ 未允许本机。 A close at 90 % of the host's 120 s question or later
      (`unanswered`): %@ 那边没有人及时回应。 A link's code is spent either way (Back); nearby, Try Again asks again.
    - can't reach it: 无法连接 %@。 + what to check (a copied link lasts 10 minutes) + Try Again / Back. The link keeps trying
      meanwhile: if the host turns up and asks, its six digits replace the failure, so the anti-scam check can be done.
  - **A computer that removed this Mac** (the host's `removed` in a session, `State.removed`): its key is deleted, the record kept with
    `removed`, and its row says 已移除本机 with 重新添加… in place of Connect (the window's cover offers the same). A key refused with no
    session (`forgotten`, which anyone on the network can send) says the same for this run only and keeps the key. Adding it again
    replaces the record by the host's id. Tests: BlurtRemoteKitTests `RemoteViewerPairingTests`.
  - **The same on every platform** (2026-11-21): the Windows/Linux viewer (blurt-remote `PairError` Spent / Declined / Unanswered /
    Unreachable, `pair_steps`, `Link::Removed` apart from `Link::Forgotten`; the web's Add Computer panel and window cover) and both
    phones (iOS `PairFailure`, Android `PairEnd`: the pad's card says the failure, then what to do, with Retry while a code can't be
    reached and Scan Code otherwise; a computer's `removed` in a session keeps the record, marked, with its key gone). A phone also says
    when the pairing stopped because the app left the screen while the computer was asking. Tests: blurt-remote tests/viewer.rs,
    web viewer.test.ts, iOS LinkStatusTests, Android LinkStatusTest.

**A window per computer.** Several computers at once means several windows. Keys go only to the window in front. On a Mac the windows
can merge into tabs, the system's way.

- **Toolbar** (Mac, visual gate 1.1, `viewer.mac` r1; as Screen Sharing: the picture is the one focus, the chrome a few small icons):
  - the computer's name, and under it the path (同一网络 / Same network); the round trip joins it only once it is slow enough to feel
    (80 ms and up, e.g. 公共连接服务 · 140 毫秒): a fast one under the name every second was noise;
  - icon-only items, no text and no chevrons, so the bar has one shape in every language; each says what it does in its tooltip
    and, when the window is too narrow for them, its label in the overflow menu:
    - 按键发往远端 / Keys to Remote: a keyboard, outlined while this Mac keeps its keys; filled in `brand.ink` on the `brand.tint`
      wash while they go to the computer (macOS 26's prominent toolbar item), so whether it's on shows at rest. It stands on its
      own (a tinted item leaves its group, so it never sits in one). Tooltip: 把按键发往 Studio / 键盘和鼠标正发往 Studio。按 ⌃⌘ 交还。;
    - the display switcher (`display.2`), in the bar only while the host has more than one display: its popover draws the
      arrangement (below); no 屏幕 1 / 2 counter at rest;
    - ⋯ (`ellipsis.circle`, no indicator): 画质 ▸ 自动 (按连接情况自动调整) · 清晰 · 均衡 · 省流量 (with 正在消耗手机流量 under them
      on a costly path) — set once and seldom touched, so no slot of its own —, then ⌘ 当作 Ctrl (Windows and Linux hosts only),
      共享剪贴板, 隐私屏 (where the host can), then 发送文件… and 发送 Ctrl+Alt+Del (Windows), then 发送系统快捷键… where Input
      Monitoring is missing.
  - The window keeps the host's shape at every size, its smallest too (480 × 270 points of picture for 16:9), so there are never
    bands beside the picture.
  - Screenshots: the pretend host's screen is drawn by `skills/blurt/recorder/macos/Tests/make_host_screen.swift` (a Mac desktop:
    menu bar with the Apple menu and clock, Terminal in zsh, an editor, the Dock), shown as `viewer fakehost PNG mac name=Studio`,
    with BLURT_TEST_KEY_LOOK=1 so the window draws as the key window. Shots: promo/cases/visual-gate-1.1/fix/viewer/.
- **Keyboard:**
  - While the window is in front and keys are captured, every key goes to the host, system shortcuts included: ⌘Tab, ⌘Space, Alt+Tab,
    the Windows key.
  - ⌃⌘ on a Mac viewer, Ctrl+Alt on Windows and Linux, gives keys and the mouse back to this computer. A hint at the top of the
    picture says so for 3 s after capture starts, and Keys to Remote shows its on state (the filled keyboard in brand ink) for as long
    as it lasts.
  - Clicking into the picture captures again.
- **Modifiers across systems:**
  - A Mac viewer driving Windows or Linux sends ⌘ as Ctrl, Ctrl as the Windows / Super key, and leaves ⌥ as Alt.
  - Windows or Linux driving a Mac does the reverse: Ctrl as ⌘, the Windows / Super key as Ctrl.
  - The ⋯ menu can turn this off.
- **Pointer:** absolute. Where the mouse is over the picture is where the host's pointer goes. The local pointer is hidden over the picture
  and the host's pointer is drawn from the cursor stream, as on the phone. Wheel and trackpad scrolling go through as scrolling. Buttons
  and drags go through as they are.
- **Displays:** the switcher draws the host's displays as they're arranged and switches with a click (`showDisplay`). By default, 跟着远端
  指针换屏 / Follow Remote Pointer is on, as `showDisplay(nil)` already does. 在新窗口中打开 / Open in New Window shows another display in
  a second window, which needs a second session.
- **Clipboard:** text only. It is sent to the host when keys are captured, and back from the host when its clipboard changes while
  captured. The ⋯ menu can turn it off.
- **Picture:** decoded locally from H.264 or HEVC, as negotiated today, and sized to the window, not to a phone screen. Resizing the
  window asks for a new size. Full screen is the system's own.
- **Paths:** the same as a phone, in the same order: same network, overlay, own relay, public connection service. The toolbar names
  the path in the agreed terms.
- **The cover** (when the link is down or the picture stopped; `ViewerCoverView`): the last frame stays, frozen — blurred 14 pt,
  greyed (saturation 0.35) and dimmed 45 % — so it reads as a picture that stopped and none of its text competes with the words. Over
  it, one card for every state, the same width (400 pt, narrower in a small window) and place (centred 45 % down the picture, above
  the host's taskbar or dock), so only its mark, words and buttons change between Reconnecting, Can't reach, Ended and the rest: the
  toast grid (system.md §3.2) on a sheet's surface that follows light and dark: the brand spinner while it tries, the amber ⚠ when it
  needs the user, else the state's glyph; the title (15 semibold) names the computer ("Reconnecting to Office PC…"); the detail
  (12.5, secondary) says where it's trying and for how long ("Same network · trying for 0:12"), and once it says it can't reach it,
  "Still trying · 0:42" (it goes on trying by itself). Its buttons on their own row at the right: Disconnect (esc), the way out,
  always — it closes the window — and the state's one action (↩) after it as the primary: Try Again, Reconnect, Take Over, Add Again.
  Meanwhile the subtitle says the state in a word (Reconnecting… / Not connected), the display switcher and Keys to Remote
  are disabled, and ⋯ alone stays live, with Try Again and Disconnect at its end.

## Wire additions

All are optional, so older peers ignore them.

- `hello.features` includes `"viewer"`, and `"move"` as for phones.
- `RemoteSessionInfo.features` includes `"viewer"` when the host accepts a viewer's extras.
- `ToMac.clipboard(String)` and `ToPhone.clipboard(String)`: text only, at most 64 KiB, sent only while keys are captured.
- `ToMac.screen(RemoteScreenRequest)` from a viewer carries the window's size in pixels, not a phone's points. The host's ScreenPlan
  takes the viewer's size as the width ceiling, with the same rates as the phone.
- A viewer sends ordinary `key` / `mods` / `button` / pointer messages. Absolute pointer moves use `pointerTo` and the pointer packets
  the phone uses in Touch Mode. A key the phone deck can't produce, such as F13–F19 or the keypad, needs `RemoteChord` to name it; add
  the missing names.

## Per system

| | Mac viewer | Windows viewer | Linux viewer |
|---|---|---|---|
| Code | Swift, BlurtApp + BlurtRemoteKit (`RemoteChannel` role phone) | Rust `crates/blurt-remote` (from `phone.rs`) + the Tauri app | same as Windows |
| Decode | VideoToolbox (the iPhone app's decoder, moved into BlurtRemoteKit) | WebCodecs in WebView2 if it decodes the stream; otherwise Media Foundation | WebCodecs in WebKitGTK if present; otherwise openh264 (software) |
| Capture keys | a CGEventTap while in front (Blurt already has Accessibility) | a low-level keyboard hook while in front | the keyboard-shortcuts-inhibit protocol where the compositor offers it; otherwise system shortcuts stay local, and the ⋯ menu says so |

## Not in the first version

Sound, file transfer, dragging files between computers, and several viewers driving one host at once (one at a time, as with phones).

## Built on the Mac (2026-11-19)

Branch `claude/remote-go-between`. Swift only; the wire's reference is BlurtRemoteKit, as for phones.

**Wire** (BlurtRemoteKit; `tests/remote-vectors/vectors.json` → `toMac` `hello_viewer`, `screen_viewer`, `clipboard`, `keys_captured`,
`keys_released`, `key_f13_down`, `key_keypad_enter`; `toPhone` `session_viewer`, `clipboard`; and a `viewer` block):

- `RemoteFeature.viewer` = `"viewer"` in `hello.features` (with `"move"`) and `session.features`. `RemoteFeature.window` = `"window"`
  in a viewer's hello: another window of a viewer that already has a session (another display). The host keeps the first session and
  runs this one beside it; a second phone still replaces the first.
- `ToMac.clipboard(String)`, `ToPhone.clipboard(String)`: `RemoteClipboard.maxBytes` = 65,536 bytes of UTF-8; empty or larger isn't sent.
- **Added: `ToMac.keysCaptured(Bool)`.** The spec says the clipboard goes only while keys are captured; the host can't know that without
  being told, so the viewer says so when capture starts and ends. The host sends `ToPhone.clipboard` only in between (a Mac host checks its
  pasteboard twice a second then, and not otherwise).
- `RemoteScreenRequest.window: RemotePixelSize?` (`{"width","height"}`, pixels). The host fits the picture into the smaller of the
  request's box and the window (`RemoteScreenRequest.box`), so the window is the ceiling. Phones send none.
- `RemoteKey` names for a full keyboard: F13–F20, `Keypad0`…`Keypad9`, `KeypadDecimal` `KeypadMultiply` `KeypadPlus` `KeypadMinus`
  `KeypadDivide` `KeypadEnter` `KeypadEquals` `KeypadComma`, `NumLock` (a Mac's Clear), `Insert` (a Mac's Help), `CapsLock`, `Menu`,
  `IntlBackslash` `IntlYen` `IntlRo` `Lang1` `Lang2`, `VolumeUp` `VolumeDown` `Mute`, and `PrintScreen` `ScrollLock` `Pause` (a Mac host
  presses F13–F15 for them). The vectors list every name with its Mac key code.
- **A key held down repeats as `key(chord, down: true)` again.** A posted key doesn't repeat by itself; the Mac host now presses it again
  with the autorepeat flag when a held key comes down a second time.
- Modifiers travel as `mods` (the keys' state), keys as `key(name, down:)` with no modifiers of their own. The swap for another family
  (⌘ as Ctrl, ⌃ as the Windows / Super key, and the reverse from Windows or Linux) is the command and control bits exchanged
  (`RemoteViewerKeys.map`; the vectors' `viewer.modifierMap`).
- **Nearby pairing (added).** Finding a computer by DNS-SD gives no key. The viewer uses a device id starting `nearby-` and a key everyone
  knows (`RemoteNearby.key` = SHA-256 of `blurt-remote-nearby-1`; in the vectors). That key protects nothing: the host asks its owner,
  showing the six digits the viewer shows too, which only match with nobody in between (the commitment in the handshake), then sends
  `newKey` as for a code. A host accepts it only on its own network listener, never over a relay; one question at a time; after a no,
  none for 30 s. A host with nothing paired doesn't listen, so it is found only while its 添加设备 / Add Device is open.

**Host** (`RemoteServer`, `RemoteScreen`, `RemoteInput`): a viewer is paired, kept (`Device.kind` "computer", shown with a computer
icon in the device list) and driven like a phone, on every path; the go-between and the move unchanged. A nearby question brings
the main window's 手机和电脑 page to the front (Settings until 2026-11-20). Session takeover now waits for the hello, so a viewer's `window` session can be kept beside the
first; the other windows end with the first, or after 12 s of quiet. Their picture, display choice, input and clipboard work as the
first's.

**Viewer** (`BlurtApp/Viewer/`, the connection and picture in BlurtRemoteKit so the tests drive them):

- `RemoteViewerLink`: one session to one computer, role phone; the iPhone app's order of paths (the addresses it last listed, overlay
  ones with a 1.5 s wait, DNS-SD by its id, then its relay or the public connection service 1.2 s later, then the direct path and the
  move). `RemoteViewerScreen`: the phone's receiver with NACK / LTR / parity, reports every second. `RemoteScreenDecoder`: the iPhone
  app's decoder, moved into BlurtRemoteKit (`apps/ios` keeps `ScreenDecoder` as a name for it).
- `RemoteScreenPlan`: the phone's rates with the window's pixels as the ceiling. Auto: Sharp on the same network (window size, 12 Mbps,
  the panel's rate up to 120), Balanced away (at most 2560 × 1600, 4–8 Mbps by pixels, 30 fps); Low Data Mode: Data Saver (1280 × 800,
  1 Mbps, 15 fps). A resize asks again 0.4 s after the window settles; a new path asks again; a new round trip doesn't.
- Computers list: menu bar → 电脑…, and Settings → 手机和电脑 → 电脑 (the same rows; on the Mac now the page, §One page for the devices). The pane is the phone capability's, so the
  capability is now called 手机和电脑 / Phones and Computers everywhere it's named (Home, General). "Available" means a way to it exists
  now: found by DNS-SD, or it has a relay / the public connection service / a Tailscale address; nothing is asked of it until Connect.
  A Windows computer's icon is `display`, not `pc` (whose face reads as Windows' crash screen). The host's 添加设备 has 拷贝链接 / Copy
  Link for pairing from another network.
- The window: the host's shape (`contentAspectRatio`, no bars), title the computer's name, subtitle the path, with the round trip only from 80 ms.
  The display switcher (only with two displays or more) is a popover under the display item (its arrow on it), on one solid
  sheet (white / the elevated #2A2A2A: the remote picture never shows through it). The arrangement (`RemoteDisplayMap`) on top: neutral
  tiles (black 6 % / white 10 %, a 0.5 pt hairline, the number), the host's main display with a menu-bar strip. Under it one list on the
  Move popover's grid (28 pt rows): 跟着远端指针换屏 / Follow Remote Pointer, then a row per display (its number, its name, 主屏幕 / Main).
  A tile and its row are one target. Pinned to a display: a 2 pt accent ring and the brand tint on its tile, a check on its row; following:
  a check on Follow and only a small pointer on the display the pointer is on, so the two never look alike. 在新窗口中打开屏幕 2 / Open
  Display 2 in New Window is a glyph on a row under the pointer (its tooltip names the display) and on every tile's and row's context menu. A window that becomes key captures; one that stops being key gives keys back;
  clicking into the picture captures again (that click stays here). Capture needs Blurt in front as well (`wantsKeys`: connected, key,
  `NSApp.isActive`): a window that opens or reconnects while another app is in front captures nothing, tells the host nothing and leaves
  this Mac's input method alone; Blurt coming to the front captures for its key window, and going behind gives the keys back
  (`didBecomeActive` / `didResignActive`). Fixed 2026-11-21 after the 1.1 dogfood run, where a window opening behind WeChat switched
  this Mac to ABC and told the host `captured true`.
- Keys: a session event tap (`ViewerKeyboard`) while capture is on and the window is key, so ⌘Tab, ⌘Space and ⌃← go to the host. Without
  Accessibility, an NSEvent monitor instead: the window's keys only, and the hint says system shortcuts stay here. ⌃⌘ pressed and let go
  alone releases (⌃⌘F still reaches the host), hint for 3 s. The release sends the host nothing (`RemoteHeldModifiers`): a press of ⌃,
  ⌘ or both waits until a key, a click, a scroll or another modifier says it's a shortcut, and then goes before it; ⌃ or ⌘ tapped alone
  goes as a tap (⌃ alone is the Windows key: Start); letting go of what the host has goes at once. Before this a Windows host saw Win,
  then Ctrl+Win, each time the keys came back.
- The hint wraps (up to four lines, 640 pt of text at most, 16 pt from the window's edges): at 480 pt the Input Monitoring hint is
  three lines in English, two in Chinese; before, it was one line 875 pt wide, cut at both edges.
- The hint is the capture chrome's hint pill (system.md, Hint pill; `ViewerHintPill`), not a box of its own (visual gate 1.1, 2026-11-21):
  the island's black with its hairline and soft shadow (`CaptureGlass`), centred **12 pt under the picture's top edge**, where a remote
  desktop has title bars, never over its taskbar or Dock (it sat 24 pt above the bottom, on the Windows taskbar's icons). One sentence
  (13 medium, white 92 %), a hairline, then the keys as keycaps, one per key, and their word (12, white 62 %): "Keyboard and mouse go
  to Office PC | [⌃][⌘] Release" / "键盘和鼠标正发往 Office PC | [⌃][⌘] 交还本机" — no key typed into the sentence. Without
  Input Monitoring a quieter note under it ("System shortcuts stay on this Mac until …"), 6 s. One row is a capsule (34 pt); a window
  too narrow for it puts the keys under the sentence, 14 pt corners. It fades in (0.18 s) and out (0.25 s), never takes a click, and
  the pointer resting on it keeps it up (1.5 s more after it leaves). Giving the keys back ends the release hint at once.
- Files sent (Send Files… or dropped on the picture) show on a file card in the picture's bottom-left corner, 12 pt over the band where a
  host keeps its taskbar or Dock (7.5 % of the picture's height, 64 pt at least): the file's icon, its name cut in the middle so the
  extension stays, "Sending to Office PC · 3.2 MB of 8.4 MB" with a bar, and × to stop (`ViewerFileCard`). Saved and not-sent end on
  the same card. It sat as a bare "Sending “…”…" sentence on the Windows taskbar's icons before.
- The picture's ground is #1E1E1E, never pure black, for what shows beside it (full screen on a screen of another shape).
- One floating thing over the picture at a time: the release hint closes the display switcher, and opening the switcher ends a short
  hint (what lasts, no control there, stays). The switcher in the 1.1 gate's hint shots was the earlier `viewer displays` still open:
  a transient popover only closes on a click outside, which a test build never gets; `viewer hint` now closes it as capturing does.
- This Mac's input method while keys are captured: a plain layout (ABC), chosen only with Blurt in front; at the end the one before comes
  back only if the plain one is still in use, so an input method the user picked meanwhile stays. A test build never touches the Mac's
  input method or asks for Input Monitoring: `InputMethod` has a stand-in there (`viewer input ID`), and `viewer active on|off` /
  `viewer key` stand in for Blurt coming to the front, since a test build stays behind the user's apps.
- Pointer: `pointerTo` with numbers, as the phone's; over the relay 30 a second. The host's pointer drawn from the cursor stream at the
  picture's scale; this Mac's own place is shown until the host's word includes the last move (`RemoteCursor.wait`). Scrolling: trackpad
  phases go through, the trackpad's own coasting stays here and the host coasts from the speed the fingers left with (`scrollFling`);
  a wheel's scroll ends after 0.15 s quiet; deltas in the fingers' direction, the host applying its own setting. All of it in the stream,
  behind the pointer's last place.

**Away through the public connection service** (fixed after the first real run, 2026-11-19: this Mac → a Mac mini over
`wss://meet.blurt.work`, both on symmetric CGNAT, no IPv6 here; pairing worked, the host said `noDirect` and closed, and the window stayed
on 正在连接… with an empty subtitle while the list still said 可连接 · 公共连接服务):

- Through the service a session counts as connected only once it has moved onto the direct path; before that the window says
  正在连接… and the subtitle names the way being tried (公共连接服务; the owner's relay, or 同一网络, when that's what is tried), then the
  real path · round trip once up.
- `noDirect` from the host, or the service closing with 4003 before the move: the link lets the session go and its state is
  `away(noDirect)`. The window says 无法直连。请在对方电脑上设置自建中转。 with 重试 / Try Again; the list says 无法直连 / Can't Connect
  Directly. A refused upgrade (429 and the like) is `away(busy)`: 公共连接服务今日已达上限。请稍后再试，或使用自建中转。, no button.
- It stays said: the next rounds keep looking for the same network in the background and ask the service again only after its wait
  (30 s, 2 min, 10 min, then hourly; `RemoteRelay.busyWait`). Try Again, or another network (NWPathMonitor, in the link and in the list),
  clears no-direct and asks at once; busy waits its time out. A paired computer whose first session ends this way is kept and its window
  opens on the message.
- The mapping is `RemoteViewerLink.away(refused:closeCode:moved:heardNoDirect:)` and `RemoteViewerRow.of` (tests:
  `testWhatAPublicServiceEndingSays`, `testTheListsStates`); `RemoteViewerSessionTests.testNoDirectPathIsSaidAndStays` (a host on a
  relay met as the service is: session, `noDirect`, close: the state goes to `away(noDirect)`, never `connected`, stays for 4 s with the
  relay asked once, and Try Again asks again) and `testBusyIsSaid` (an HTTP 429 to the upgrade: `away(busy)`, asked once).
- The cover's buttons are drawn by their own layers (`BrandButton`, `ViewerQuietButton`), and the window's content view is
  layer-backed: a standard bezel over the picture's layer was attached and laid out but never drawn, so Try Again and Take Over were
  missing before.

**Measured / checked:**

- `swift test` (BlurtRemoteKit, 98 tests): `RemoteViewerTests` (key codes and names, the modifier swap both ways and off, the release
  chord, the clipboard limit in bytes, the plan's sizes and rates, older peers); `RemoteViewerSessionTests`: a viewer link pairs with an
  in-process host found "nearby" (same six digits both ends, new key kept), gets 12+ real H.264 frames (the iOS fixture) decoded, sends
  `keysCaptured`, clipboard, ⌘ as Ctrl to a Windows host, C down / up, F13, `mods 0`, a numbered `pointerTo`, and hears the host's
  clipboard; then through a relay with the go-between's budget the stream moves onto UDP, frames decode, a 63 KB clipboard and a key go
  after the move, and the relay carries under 16 KiB. Also run against `BUDGET=1 node tools/remote-relay/server.js` (`BLURT_TEST_RELAY`):
  passes, no 4003. The whole suite: 1155 tests, 5 failures all in `ScreenTextTests` (OCR of Japanese and an edge cut), not touched here.
- The app (test build, its own home and bundle id, this Mac as viewer only): `viewer fakehost` runs a pretend host in the same process
  (no capture, no input posted) whose screen is a still picture encoded as H.264. Paired nearby with six digits, the window opened on the
  same session, the picture decoded and shown at the window's size (2560 × 1440 for a 1280-pt window), ⌘C arrived as `mods Ctrl` + C,
  a held C as a second down, F13 and the keypad's Enter by name, ⌃⌘ released (`mods ""`, `captured false`, `releaseAll`), a click as
  button down / up, and the clipboard went both ways.
- Not run yet: a real host. This Mac is never driven (the founder's rule), so viewer → host runs are against another Mac and Windows /
  Linux machines. Not measured: the event tap's hold on ⌘Tab / ⌘Space against a real host, decode-to-glass latency, two windows on one
  host.

Screenshots (zh-Hans and en, light): `promo/cases/remote-desktop-viewer/` — computers-list, add-computer, add-computer-digits,
settings-phones-and-computers, viewer-window, viewer-window-switcher.

## Built for Windows and Linux (2026-11-19)

Branch `claude/remote-go-between`. Rust (`crates/blurt-remote`) and the Tauri app (`apps/desktop/src-tauri`, `web/apps/desktop`). The wire
is the Mac's (above, and the vectors); the Rust side reads and writes all of it.

**Wire and keys** (`wire.rs`, `keys.rs`): `ToMac.clipboard` / `keysCaptured`, `ToPhone.clipboard`, `screen.window` (`ScreenRequest::boxed`,
the box the host fits into), `VIEWER`, `WINDOW`, `MAX_CLIPBOARD`. `keys::ALL` is RemoteKey.all's 114 names in its order (a test reads
RemoteKeys.swift and the vectors' `viewer.keys`). Hosts press them: Windows `keymap.rs` (F13–F20 as VK_F13… with scan 64–6B; the keypad
as VK_NUMPAD*; `KeypadEnter`, `KeypadDivide`, `NumLock`, `PrintScreen`, the volume keys and `Menu` extended; the ISO / JIS keys by scan
code; `Lang1` / `Lang2` as VK_IME_ON / VK_IME_OFF); Linux `keys.rs` (evdev KEY_F13…, KEY_KP*, KEY_102ND, KEY_YEN, KEY_RO,
KEY_HANGEUL / KEY_HANJA, KEY_SYSRQ…). `keys::map_mods` is RemoteViewerKeys.map (checked against `viewer.modifierMap`).

**Host** (`server.rs`; Windows and Linux alike):

- A hello with `viewer` marks the session a viewer's; `session.features` is `["move", "viewer"]`. The device is kept with
  `kind: "computer"` (devices.json, `RemoteStatus.devices[].kind`). Pairing, the paths, the go-between and the move are the phone's.
- Nearby pairing as the Mac's: a `nearby-` id on the host's own TCP listener (never a relay) gets `pairing::nearby_key` (SHA-256 of
  `blurt-remote-nearby-1`), then the same question and six digits as a code, and its own new key. One question at a time; after a no,
  none for 30 s (`NEARBY_PAUSE`). Any other unknown id is still `not_paired`, so a removed phone hears what it always did.
- The window is the ceiling: `screen.rs` fits the display's shape into `boxed()`; the backends never go above the display's pixels.
- `keysCaptured(true)` starts a watch of this computer's clipboard (`Input::clipboard`, twice a second, `CLIPBOARD_EVERY`); a change
  from what it last read, and not what the viewer just put there, goes as `ToPhone.clipboard`. `ToMac.clipboard` is put on only while
  captured, at most 64 KiB (`Input::set_clipboard`: Windows CF_UNICODETEXT, Linux arboard on XWayland's clipboard).
- Absolute moves keep a double click: a `pointerTo` within half a percent of the last click's place doesn't reset the click count
  (`Hands::move_to`), so a hand's jitter between two clicks is still a double click.
- **Takeover waits for the hello**, as on the Mac. A viewer's second window (`window`) is refused here with
  `screenFailed("one_display")`: both backends capture one display at a time (one WGC / PipeWire stream per process), so the first window
  keeps the computer. 在新窗口中打开 is therefore not offered by the Windows / Linux viewer.

**Viewer core** (`viewer.rs`, from `phone.rs`): `Computers` (computers.json; keys as `computer-<host id>` in Credential Manager / the
Secret Service), `browse` (DNS-SD), `pair` (link or nearby; the digits shown from `PairingWaits`), `open` (the phone's order: the
addresses it knows and those found nearby over TCP, 1.5 s each in parallel; then its relay or the public connection service), and
`Session`: reconnects after a drop (1, 2, 4, 8, 15 s; busy: 30 s, 2 min, 10 min, hourly), knocks on UDP every 250 ms until `udpOK`, runs
the phone's receiver (NACK, LTR, parity), pings and reports every second, and hands frames on as Annex B with the WebCodecs codec string
(`codec_string`: `avc1.PPCCLL` from the SPS, `hev1.…` from the HEVC SPS's profile_tier_level). `plan` is RemoteScreenPlan's numbers.

**The app** (`src-tauri/src/viewer.rs`, `viewer_keys.rs`; web `src/viewer/`):

- Tray → 电脑… opens Settings → 手机和电脑 at the 电脑 group. The pane is renamed; the host's Add Phone… is 添加设备… / Add Device…, and its
  code has 复制链接 / Copy Link for a computer to paste.
- Rows: 已连接 · <path> (a window's session is up) → 打开窗口; 可连接 · <path> (found nearby; or a Tailscale address, a relay or the public
  connection service it can be tried through) → 连接; 离线 · <last seen> → 移除. Add Computer… lists unpaired computers found nearby
  (DNS-SD runs while the list shows) and takes a pasted link; while pairing, the digits show and the window opens once paired.
- A window per computer (`viewer-<n>`, `index.html?viewer=<host id>`). Its webview hands a Channel to `viewer_attach`; frames come through
  it as bytes (1, flags, u32 id, codec string, Annex B), events as JSON. Toolbar: name, path · round trip, 屏幕 1 / 2 (only with two
  displays or more; the arrangement drawn, 跟着远端指针换屏), 按键发往远端, 画质, ⋯ (Ctrl 当作 ⌘ for a Mac host, 共享剪贴板, 全屏 = F11 /
  the window's own full screen; on Linux without the inhibit protocol, 系统快捷键仍在本机生效).
- Keys: `keys::Keyboard` turns `KeyboardEvent.code`s into `mods` and `key(down:)` (a repeat is another down), and releases on Ctrl+Alt
  let go alone (left Alt: AltGr types; Ctrl+Alt+T still reaches the host). Windows: a `WH_KEYBOARD_LL` hook while captured and in front,
  scan codes → web codes (`keys::code_of_scan`), swallowed; injected keys and AltGr's fake Ctrl skipped; Ctrl+Alt+Del and Win+L stay
  Windows'. Linux: `gdk_seat_grab` on the window (Wayland: keyboard-shortcuts-inhibit, GNOME asks once; X11: a real grab), keys from the
  webview; whether the compositor offers the protocol is read from the Wayland registry. Focus lost: everything held is let go of.
- Pointer: `pointerTo` at most once a frame while captured; the click that captures stays here; buttons, the wheel (Changed, Ended after
  0.15 s). The local pointer is hidden over the picture and the host's drawn from the cursor stream.

**Decode, measured:**

| Webview | WebCodecs | H.264 | HEVC | Notes |
|---|---|---|---|---|
| WebView2 (Windows) | yes | expected (Chromium + Media Foundation) | with the HEVC extension / hardware | not run on Windows yet |
| WebKitGTK 2.52.6, Ubuntu 24.04 (Docker, xvfb), with gstreamer1.0-libav | yes | 60 / 60 frames of the recorded stream | 60 / 60 | `isConfigSupported` true for both |
| same, plugins-good only | yes | `NotSupportedError` | `NotSupportedError` | `isConfigSupported` false: the window says it can't decode |
| same, plugins-bad + ugly, no libav | yes | "Decode error" | 60 / 60 | |
| Chromium (this Mac's preview browser) | yes | yes (dev server: the mock's encoded desktop, 2048 × 1152) | yes | |

So the .deb now depends on `gstreamer1.0-libav`, and the native fallback (Media Foundation / openh264) is **not built**: WebView2 always has
H.264, and WebKitGTK has both codecs once libav is there. A webview that decodes nothing shows 本机无法解码画面 with the package to
install. The RPM still only recommends openh264 (Fedora's libav plugin is RPM Fusion's); untried.

**Tests:** `cargo test` (crate, macOS: 181 unit + every integration test; Linux in Docker Ubuntu 24.04: 183 + all, clippy -D warnings
clean; Windows: clippy -D warnings clean for x86_64-pc-windows-msvc with a stand-in C compiler). `keys.rs` (names vs RemoteKeys.swift,
web codes, scan codes, the swap, Ctrl+C to a Mac as ⌘C, Alt+Tab held, both Shifts, the release chord and AltGr), `viewer.rs` (Annex B,
codec strings incl. the recorded streams, the plan, the store), `vectors.rs` (50 + 31 messages, the `viewer` block). `tests/viewer.rs`, the
real host with a made-up backend (the recorded H.264 stream as its screen) and the Rust viewer: paired by link (six digits, kind
computer), session features, a 1200 × 800 window gives 1200 × 750, frames whole and byte-identical in Annex B with `avc1.64000D`,
Ctrl+C to a Mac host as held 1 / C / held 0, Keypad7 and F13, a double click at one place, the wheel, the clipboard only while captured
and both ways (not echoed, > 64 KiB dropped), a bigger window asks again (2000 × 1250), removal heard; nearby pairing (digits, a key of
its own, a no pauses the next, an unknown plain id still `not_paired`); through `BUDGET=1 node tools/remote-relay/server.js` as the
public connection service: meets, moves to the direct path, 30+ frames and Ctrl+V after the move, nothing over budget. The app:
`cargo check` macOS, Windows (cross), Ubuntu 24.04 (Docker, clippy). Web: tsc + vitest 134. In the dev server: the window's mock encodes a
made-up desktop with WebCodecs and decodes it through the real path; capture, the hint, the switcher, the menus.

**Not run yet (this Mac is never driven):** the app on real Windows and Linux; the hook and the grab; the clipboard backends; WebView2's
decode; two real computers end to end. Recipe for the rented VMs: below.

**On the VMs:**

1. Host side (either VM): `cargo run --example host -- --real --answer ask` in `crates/blurt-remote` prints a pairing link and every
   input event, or run the desktop app (`pnpm tauri dev` in apps/desktop, debug, `BLURT_TEST_COMMANDS=1` for file keys).
2. Viewer side (the other VM): the desktop app; Settings → 手机和电脑 → 电脑 → 添加电脑…; the host shows up under 同一网络 (its Add Device…
   open), or paste the link. Compare the digits, allow on the host.
3. Check: the picture (Windows: WebView2; Linux: libav installed, then removed → the no-decoder line), path and round trip in the toolbar;
   a click captures and the hint shows 3 s; Alt+Tab, the Windows key, Super, Ctrl+Alt+T reach the host; Ctrl+Alt let go alone releases;
   the keypad, F13, PrintScreen, Insert; a double click, a drag, the wheel; copy on each side and paste on the other while captured, not
   after release; resize the window (a new size after 0.3 s); two displays on the host → the switcher; away: block the LAN, the relay or
   the public connection service, then 直连 after the move. Linux viewer on GNOME Wayland: the inhibit prompt once, then Super and
   Alt+Tab go to the host; on a compositor without it, the ⋯ line.

Screenshots (zh-Hans and en, light and dark): `promo/cases/remote-desktop-viewer/` — `settings-computers`, `settings-add-computer`,
`settings-pairing-digits`, `settings-link-error`, `viewer-captured-hint`, `viewer-display-switcher`, `viewer-more-menu`,
`viewer-quality-menu`, `viewer-linux-shortcuts-local`, `viewer-connecting`, `viewer-offline`, `viewer-replaced`.

## One page for the devices (Mac, 2026-11-20)

Now named 远程控制 / Remote Control (below); 手机和电脑 is the name this section started with.

The same feature sat in three places with three names: Home's row (手机和电脑), the sidebar page 手机, and Settings → 手机和电脑. Paired
devices were listed twice (page and Settings), the computers this Mac controls only in Settings and the Computers window, and a computer
that controls this Mac showed under a phone heading with a phone icon. Now:

- **One name:** 手机和电脑 / Phones and Computers on Home, in the sidebar, as the page's title, in ⌘K and the Go menu, and as the
  Settings pane. The menu-bar row's Add… and Home's fix say 添加设备… / Add Device…, as the page does.
- **The page holds every device**, in three groups (`MainWindow/PhonePageViews.swift`), with a new device's yes-or-no above them:
  - 能控制本机的设备 / Devices That Can Control This Computer: every paired phone and computer, its mark by kind (iPhone, iPad; a
    laptop or desktop for a computer), its line (已连接 · <path> in the agreed path names, or 上次使用：…), 移除…; at the bottom 添加设备…,
    whose code (QR, the six digits, 拷贝链接 → 已拷贝，10 分钟内有效 for 4 s) takes its place while open. Nothing paired: one row that
    says so and carries 添加设备….
  - 本机可控制的电脑 / Computers You Can Control: ViewerStore's computers, drawn by the Computers window's `ComputerRow` in the page's
    grid (`style: .page`): its state (已连接 · 可连接 · 离线 · 无法直连), 连接 or 打开窗口, and 重命名… · 移除… in the ⋯ menu (and the
    context menu). A double-click on a name on the page renames it in place (remote-1.1.md §6); the Computers window renames from
    the ⋯ only, a double-click there opens the computer.
    添加电脑… at the bottom opens the same Add Computer sheet. The page watches ViewerStore while on show, so 可连接 is live.
  - 本机 / This Mac: unchanged — only what stands in a device's way (Accessibility, the port, Screen Recording, the relay); all well is
    one line.
  - Then 连不上时 while a phone should be connecting, and where the phone app comes from. 手机设置… on the title line opens Settings.
- **Settings → 远程控制 is options only:** its first row says what is paired and who is connected, with 查看设备 (or, nothing paired,
  添加设备…, which opens the page with the code up). Then 本机 (stay awake, sleep time, keys on screen, the screen) and 其他网络 (the
  public connection service and the own relay, each with its state as the line under it; Copy Instructions is the footnote). The catalogue's `remote.phones` /
  `remote.computers` sections and their rows are gone, so search doesn't land on a list that isn't there.
- **Device kind on the host:** `RemoteServer.Device.kind` is "computer" when the hello's `features` carry `viewer`
  (`RemoteFeature.viewer`), nil for a phone. It is written when a device pairs and again whenever it connects, so a record kept before
  kinds existed (nil, a phone) is corrected the first time that computer comes back.

- **The row grid, after three rounds of the visual gate:** every row's mark in one 18 pt slot at one size, the text 28 pt in, its state
  disc before every state line (hollow ring for 上次使用 / 可连接 / 离线, the check for 已连接), an offline computer's name quieter;
  Rename… and Remove… are in each row's ⋯ (one trailing column for both lists, Connect / Open Window before it; Rename… is also a
  double-click on the name, remote-1.1.md §6); each list ends with an inline
  "+ 添加设备… / + 添加电脑…" line on the grid, empty or not; every bordered button on the page is the small size. The code is one quiet
  card (QR 124 pt, 添加设备 / Add Device, one line of how, 取消 · 拷贝链接); a device asking is a card of its own (lock, 允许 X 控制本机？,
  the digits in threes, 不允许 · 允许 with Allow the page's primary, and still no default: Return must not say yes). Copy cut on the way:
  the code's how-to and the own relay's line are one sentence each; Settings' headings are sentence case, as its other panes'.
  Gate scores (3 fresh judges, round 3): empty 8/8/7, devices 7/7.5/7, add device 7/7/7, asking 8/7.5/7.5, settings 8/8/7.5.
- **Round 2 (2026-11-20), the three points left open:**
  - States read apart: `StatusDot` has a fifth tone, `ready` (a plain filled disc, secondary grey), for 可连接; 已连接 keeps the
    green check, 离线 and 上次使用 the quiet grey ring, and no name is dimmed (the mark and the words carry it, on both lists). Tried
    first and dropped: a brand-ink ring (judges read it as a second green beside the check, and as the links' colour), then a grey
    ring with a dot (too close to the hollow ring at 9 pt). The Computers window
    draws the same rows with the page's outlined buttons and ⋯, so it changed with the page.
  - An offline computer shows no button: 离线 is a guess from when it was last seen, so 连接 is still there, in the row's ⋯ with
    移除… (and the context menu); never a disabled button. The Computers window's rows have the same ⋯ now.
  - The code card says when the code on screen gives way: 1:40 后更换二维码 / New code in 1:40, counting down once a second to
    `Status.pairingRenews` — the moment RemoteServer puts up the next code (`pairingLife − pairingGrace`, 100 s; the code itself is
    good 20 s longer, so the one showing never fails). The desktop app's 还剩 1:40 is for a code that runs out and waits for New Code;
    next to "the code renews itself" judges read it as a contradiction, so the Mac says what happens instead. 拷贝链接's
    已拷贝，10 分钟内有效 is unchanged.
  - Hairlines start at the text column, as Apple's lists; an empty list's line has no device mark.
  - Gate, three fresh judges per round: page-devices 7.5/7/7 → 7/8/8 → 7/8/8; page-add-device 7/7/7 → 6.5/8/8 → 7/7/7.5;
    Computers window 7.5/7.5/7 → 7/7/7 → 8/7/7.5. The last round's shared asks were made after it (the countdown back to the
    secondary grey, the window's Add Computer… the rows' size and trailing edge) and not judged again. Still asked for: a colour for
    可连接 rather than grey (the founder asked for it to read apart from 离线; a hue would be a sixth colour in the status set), one
    zh format for 上次使用：3天前 and 离线 · 2 天前 (system formatter output vs ours), and lighter chrome on the code card.
  - The pairing question's 允许 was already its own key (`settings.remote.ask.yes`), apart from the permission rows' 允许…
    (`settings.kit.allow`).
  - The name is one key on the Mac, `feature.phone` (Home, sidebar, page, ⌘K, Go menu, Settings pane, and through %@ the pane's
    lead, the menu bar's row and onboarding's line): `phone.title` and `settings.kit.remote` are gone.
  - **Renamed 远程控制 / Remote Control** (the founder, 2026-11-20): 手机和电脑 named two kinds of device, not what the feature does;
    the two groups keep their names (能控制本机的设备 · 本机可控制的电脑). The menu bar's row reads 远程控制：iPhone 已连接; the relay
    instructions say Settings → Remote Control → Relay Address; the phone apps point to the same names.
  - **Visual fix pass (1.1.0, 2026-11-21).** The gate's judges agreed on four things; one pass fixed them:
    - This Mac's state comes first, under the title (system.md §3.4). With all well and a device paired it is one quiet line
      (其他设备可以控制本机 · what that covers); before anything is paired, nothing. Each problem is one notice there (`PhoneNotice`,
      SettingsNotice's look on the page's column) with its fix. The 本机 / This Mac section is gone.
    - The page now reads what this Mac's own tries found from other networks (`Status.away`, as Settings' Status row reads it):
      `PhoneFacts.away` gives a relay-down notice (with an own relay set), and, through the public connection service, a
      today's-limit notice (`goBetweenBusy`) and a no-direct-path one (`noDirect`). Each is said only while no device is connected.
      Before, these states drew the green all-well line.
    - One name for the machine in en: Devices That Can Control This Mac; the other list is `phone.section.computers` (Computers You
      Can Control / 你能控制的电脑, no longer a near-anagram of 能控制本机的设备). Settings' own key is unchanged.
    - 连不上时 / If It Won't Connect is closed at the page's foot (`phonepage tips open|closed`), so the page no longer ends on a tip
      cut by the window's edge. It shows nothing when this Mac can't open its port (that cause is here, not on the phone). The phone
      app's build links are a footnote under Add Device…. A device row's ⋯ shows on hover. zh: 上次使用 2 小时前 (no colon, a
      space between the number and the Chinese).
    Shots: `promo/cases/visual-gate-1.1/fix/remote-page/`.

Screenshots (zh-Hans and en, light and dark): `promo/cases/devices-page/mac/` — `page-empty`, `page-devices`, `page-add-device`,
`page-asking`, `settings`. Hooks: `phonepage fake …` now includes a paired computer (MacBook Pro) beside the iPhone and iPad;
`viewer fake` for the computers; `viewer settings` for the pane.

## One place for devices (Windows and Linux, 2026-11-20)

Before, the same feature sat in three places under three names: Home's row (手机), the sidebar page (手机) and Settings → 手机和电脑. Paired
devices were listed twice, the computers this one drives were only in Settings, and a computer that drives this one showed under a
phones heading with a phone icon. The founder approved one structure; branch `claude/devices-page-desktop`.

- **One name, one string:** 远程控制 / Remote Control (the founder's rename of 手机和电脑, 2026-11-20) is `feature.phone` alone: Home's
  row, the sidebar item, ⌘K, the page title, the Settings pane title (the catalog's pane title is `feature.phone`; `phone.pane.title`
  is gone) and the sentences that name the page (`welcome.use.phone.detail`, `phone.devices.lead` take it as a parameter). Renaming
  again is that one string per language. The sidebar, Home and the pane use a devices icon (`assets/icons/devices.svg`: a screen with
  a phone in front). The relay instructions (remote.rs), the mock's copy and apps/android/README.md say Settings → Remote Control.
- **The page** (`web/apps/desktop/src/components/PhonePage.tsx`) holds the devices, in three boxes on one row grammar
  (`components/DeviceRows.tsx`): glyph · name over its state line · at most one small button · ⋯ (quiet at rest) on one right edge.
  - 能控制本机的设备 / Devices That Can Control This Computer: every paired phone and computer, glyph by kind (phone or screen), state
    first (已连接 · <path> · 正在显示屏幕, or 未连接 · 上次使用：…), 移除 / Remove (red) in ⋯. The last line "+ 添加设备…": the QR code
    with its time left ticking each second, one line of how, 还没有 App？ with the two build pages, 拷贝链接 / Copy Link (4 s of
    已拷贝，10 分钟内有效; `remotePairingLinkCopied` keeps that link 10 minutes) and 取消. None paired: 还没有配对的设备 with 添加设备… as the
    page's one primary.
  - 本机可控制的电脑 / Computers You Can Control: `viewer/ComputersGroup.tsx`, moved here from Settings. State first (已连接 · 同一网络 ·
    macOS; 可连接 · <path>; 无法直连, the agreed line as its tooltip; 离线 · <when>), 打开窗口 or 连接; an offline computer has no button,
    its 连接 is in ⋯ above 移除. "+ 添加电脑…": the computers found nearby as the list's own rows (可连接 · 同一网络, 配对), then the
    pairing link field (its 配对 once something is typed; Return pairs) with 取消 beside it; the digits while pairing.
  - 本机 / This Computer: what stands in a device's way (firewall Allow…, Wayland's Remote Desktop, the port, the relay) — then first on
    the page, on the attention wash — else one line at the end (手机和电脑可以控制本机 · 指针和按键 · 屏幕画面 · …).
  - Then 连不上时 when it applies. The header's 设置… / Settings… opens the pane.
- **Status marks** (`components/StatusDot.tsx`, tones in settings.css `.st-dot`, shared with Settings → Agents): connected a filled
  green disc with a check, available a hollow ring in the accent, offline / not connected a small dim grey dot, warning an amber disc
  with "!". system.md §3.3 still describes off as a hollow ring; this is the change.
- **Settings → 远程控制** keeps only options: the lead 设备列表在主窗口的「远程控制」页。 查看设备 (search's pair / QR / computer words land on
  it; the old `phone.add` and `phone.computers.add` rows redirect there), 本机 (show this screen on the phone) and 外出连接 (own relay,
  public connection service, Set Up a Relay). No device lists, no notices. A switch that can't change now (the public service while
  an own relay is set) keeps its setting on a dimmed accent track, the same in both themes.
- **The question** for a new device is always the window's dialog now (the pane no longer asks in place): one centred column, the
  device's glyph (screen or phone from `asking.kind`, the neutral devices glyph when a host doesn't say), 允许“X”控制本机？, the digits
  in the UI face, “X”显示相同的数字时才允许。 and where it is, one sentence a line; 不允许 keeps the focus, its ring not changing its size.
- **Kind on the host** (`crates/blurt-remote/src/store.rs` `DeviceKind`): a hello listing `viewer` is a computer. Kept on the device
  (`"kind": "computer"` in devices.json, nothing for a phone, so records from before read as phones) and learned again on every
  session, so an old record of a computer corrects itself. In the status: `devices[].kind` and `asking.kind` ("phone" | "computer").
  No wire change. Test: `tests/server.rs` `a_device_is_a_phone_or_a_computer` (asks as a computer, kept, read back after a restart).
- **无法直连 in the list** (`src-tauri/src/viewer.rs`): a window that ended with `noDirect` marks its computer until it connects or
  Connect tries again (the Mac's `ViewerStore.failed`).
- **The path a row names** when the computer isn't open: 同一网络 when found nearby, else the path its last session used
  (`Computer.last_route` in computers.json, set at pairing and on every connect), else the guess from its overlay address or relay.
  Before, a computer just used on the same network (Windows → Linux, 同一网络 · 1 ms in the window) read 可连接 · 公共连接服务 afterwards,
  from the relay in its pairing link.
- **Visual gate** (3 fresh judges a round, 3 rounds): round 3 — empty page 8/8/8, the question 8/8.5/8 (computer) and 8/8/8
  (unknown), paired page 8/7.5/8, Add Device 7/7.5/7.5, Settings 7/7.5/8, ⋯ menu 7/7.5/7.5, firewall 7/7.5/7.5, Add Computer 6/7/7.
  Fixed after round 3 without a fourth round: the nearby spinner (a quarter arc in secondary ink, not a ring), 取消 beside the link
  field, the store links' underline, ⋯ at 3:1, the sidebar's attention dot clear of the glyph and name, the question's focus ring.
  Still asked for: the warning state words neutral with only the mark amber (system.md says attnInk), a heading for the Add Computer
  panel, the link field told apart from buttons in light mode (shared `.st-field`), a CJK-first font drawing ASCII hyphens long in
  zh names (app-wide font stack), a tablet glyph for iPads.

Screenshots (zh-Hans and en, light and dark): `promo/cases/devices-page/desktop/` — 01 page with devices, 02 empty, 03 Add Device,
04 Add Computer, 05 a computer's ⋯ (无法直连), 06 Settings, 07 the question from a computer, 08 from a host that doesn't say, 09 Windows
firewall. Mock: `?view=phone&phone=paired` (two phones and a computer), `&computers=nodirect`, `&phone=asking_pc | asking_old`.


## Pairing screens, visual pass (Mac, 2026-11-21)

- **Computers window**: the rows sit in one rounded card, Add Computer… is its last line, and the window is as tall as its rows
  (460–640 pt wide; while Add Computer shows it grows to the sheet's height, so the sheet never hangs past an edge). Each row's
  button sits in a slot as wide as the widest row button; ⋯ shows on hover (the context menu has the same items). The text column
  is one VoiceOver element across its full width ("Office PC, Windows, Needs its own relay").
- **Needs its own relay** (was Can't Connect Directly): sentence case, amber, the reason and fix in the tooltip, and Try Again in
  place of a Connect that reads as contradicting it. The Windows / Linux list says the same words.
- **Add Computer**: 400 pt, always inside the window (min 460). "On this network" (each found computer with its Connect, then a
  quiet "Looking for more computers…" row) and "On another network" (one full-width field; the footer's Connect is the sheet's
  only default). The empty field takes no focus. Pairing is one centred card for connecting, the digits (SF Pro tabular, 3 + 3 in a
  quiet well, a waiting spinner, read digit by digit) and a failure, with one width and height.
- **The host's question (PhoneAsk)**: one stack in the Windows / Linux sheet's order — the question, the digits, what to compare,
  the anti-scam line right above the buttons — and Don't Allow / Allow as two equal outlined buttons (Allow is never highlighted;
  no default button).
- **The pairing code (PhonePairingCode)**: the card is as wide as what it holds; the QR at 148 pt with "New code in 1:40" under it;
  a quiet ✕ (Esc) in place of Cancel; Copy Link alone, its tooltip saying it is for a computer on another network.

## Tried on real machines (2026-11-19)

Mac viewer (this repo's test build) on a home connection in China (China Mobile, symmetric CGNAT, no IPv6) → the 1.0.26 CI builds on
two rented GCP machines in Singapore (Windows Server 2022 and Ubuntu 26.04 GNOME, public IPs, no GPU), through the public connection
service.

| | Windows | Linux |
|---|---|---|
| Pairing by pasted link through the public connection service | works; digits match | works; digits match |
| Moved onto the direct path | only once Windows Firewall lets Blurt in; before that 无法直连 (as designed) | works at once |
| Round trip after the move | 534–555 ms | 534–877 ms |
| Picture | none: no D3D11 video processor without a GPU → CPU fallback added (below) | after GNOME's Remote Desktop dialog; see below |

Found and fixed:

- **A Linux host stopped listening after its first away session.** With a Secret Service that has no default keyring (an auto-login
  session), keys go in `~/.blurt/secrets/`, but reading one asked the Secret Service only and took "not there" for an answer, so the
  device's key was gone after the session and the host never waited for it again (`secret_linux.rs`; `remote_relay` `no_key` is logged
  now when a paired device's key can't be read).
- **The Windows host showed nothing without a GPU.** `nv12.rs` + `CpuConverter`: BGRA from a CPU-readable staging texture to NV12 on
  the CPU (BT.709 limited, tent-filter scaling, up to 4 threads), into Microsoft's software H.264 MFT at the software size cap and ≤ 30
  fps; 2.5 ms for 1080p → 720p on an M5 Max in tests. The GPU path is unchanged where it works.
- **The viewer said 无法连接 when only the screen had failed**, and the desktop viewer showed the host's raw English sentence. Both now
  say `viewer.screen_off` / `viewer.screen_permission` / `viewer.one_display` / `viewer.screen_failed` (无法显示 X 的屏幕。指针和按键仍可使用。)
  with 重试, which asks for the screen again (after GNOME's dialog is answered, for one).
- **A Linux computer's name was its FQDN** (`vm.zone.c.project.internal`): the pretty hostname, else the host name up to the first dot.
- **The host's pairing question said "your phone"** to a computer: 对方设备上显示同样的数字时才允许。

Seen, not changed:

- A pasted pairing link is good while that code is shown; the code renews about every 100 s, and an older link then fails as 无法连接.
  The waiting connections renew with it, so this is the only reconnect cadence on the public connection service: an idle connection
  stays open (200 s measured from the Mac and from the VM, with and without protocol pings).
- GNOME's Remote Desktop dialog has to be answered at the host the first time (90 s); a viewer away from it waits on a black window.
  Answering it once is part of setting up a Linux host.
- A viewer window that opens in front captures the keys (as designed); scripted test runs release capture right away.

**Mac viewer → Mac host on the same network** (the M1 Max at home, this branch's test build next to the owner's own 1.0.26):
path 同一网络, round trip 8–27 ms, picture at the host's 40 fps with idle frames skipped; pointer, click, keys (keypad Enter into
TextEdit) and the clipboard both ways while captured all work. Two things found:

- **Without Accessibility on the host nothing it posts lands** (macOS drops it silently), while the picture works on Screen Recording
  alone: the owner clicked a button through the viewer and saw nothing happen. The Mac viewer said so for 6 s only; now the line stays
  until the host can be controlled (`ViewerPictureView.showHint(seconds: nil)`; the desktop viewer already kept its cover).
- **Two Blurts on one computer advertise the same name**, so "add by name" may reach the other one (the owner's release, which refused).
  Real computers run one Blurt; tests pair by link.

**The host hang** (Windows, any host sending a keyframe of more than 16 pieces after the move to the direct path): `frame()` held the
stream's lock and the first paced batch locked it again on the same thread; found from a minidump, fixed in `screen.rs` with a test
(`a_big_frame_on_the_direct_path_goes_out`).

**Windows ↔ Linux** (the two rented machines, one network, 2026-11-19, last build of the branch): both ways pair by pasted link (six
digits, a computer icon on the question), connect from the list, show the picture on the same network at 1 ms, and take clicks and
typing (Notepad on Windows, Text Editor on Linux). Found and fixed on the way:

- **Connect / Open Window opened a white window that never answered on Windows**: a webview built inside a synchronous Tauri command
  deadlocks there. `computers_open` is async now; pairing had worked because its window opens from another thread.
- **A quick click held the button down** on the host: the desktop viewer sent the down after the pointer move resolved but the up at
  once, so a fast click's up arrived first. Both now go in order (`inOrder` in ViewerWindow.tsx).
- **Keys didn't reach the other computer from Windows**: the hook dropped every injected key (an on-screen keyboard, a remote-desktop
  tool such as the one the owner uses, a remapper); now only Blurt's own tagged keys (BRMT, BLRT) stay. And after another device took
  the session, Keys to Remote stayed on with the hook off, so keys went nowhere after reconnecting: capture ends with the session.
  The webview's own key events stand in when the hook isn't installed (the hook swallows what it takes, so nothing goes twice).
- **A slow yes ended the session it allowed** (the host's 12 s silence clock ran while the owner compared digits): it restarts when the
  session takes over, on the Rust and the Mac host.
- **A copied pairing link died with the next code on screen** (≤ 2 min): it now lasts 10 minutes (COPIED_LIFE), the button says so.
