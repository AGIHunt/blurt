# One computer controlling another

2026-11-19. Status: designed, being built. The founder approved the screens on 2026-11-19: a window per computer, a list of computers,
and a display switcher. Wire: [remote-protocol.md](remote-protocol.md). Paths away from home: [remote-go-between.md](remote-go-between.md).
Words: [copy.md](copy.md).

## What it is

Blurt on a Mac, Windows or Linux computer can show and drive another computer that runs Blurt. To the computer being driven (the
**host**), the driving computer (the **viewer**) is one more paired device, like a phone. It pairs the same way, connects by the same
paths, and gets the same picture and the same input messages. The host side gains almost nothing. The viewer is new on all three systems.

What it doesn't need from the phone: the key deck, the touch gestures, the zoomed-picture handling. A viewer has a real keyboard and mouse.

## The viewer

**The list of computers.** It opens from the menu bar or tray → 电脑 / Computers, and from Settings → 手机和电脑 / Phones and Computers.

- Each row shows the computer's name, its system, and a state: 已连接 · <path>, 可连接 · <path>, or 离线 · <when last seen>.
  It has one button: 打开窗口 / Open Window, 连接 / Connect, or 移除 / Remove.
- **添加电脑 / Add Computer:**
  - On the same network, nearby Blurt computers are listed, found by DNS-SD `_blurt-remote._tcp`. Choosing one starts pairing. The host
    shows six digits and asks for a yes, as for a new phone; the viewer shows the same six digits.
  - Away, the user pastes the pairing link from the host's 添加设备 / Add Device (`blurtremote://pair?…`).

**A window per computer.** Several computers at once means several windows. Keys go only to the window in front. On a Mac the windows
can merge into tabs, the system's way.

- **Toolbar:**
  - the computer's name;
  - the path and round trip, e.g. 直连 · 18 ms;
  - the display switcher, e.g. 屏幕 1 / 2, shown only when the host has more than one display;
  - 按键发往远端 / Keys to Remote, which shows whether keys are captured;
  - picture quality (Auto, as on the phone);
  - a ⋯ menu.
- **Keyboard:**
  - While the window is in front and keys are captured, every key goes to the host, system shortcuts included: ⌘Tab, ⌘Space, Alt+Tab,
    the Windows key.
  - ⌃⌘ on a Mac viewer, Ctrl+Alt on Windows and Linux, gives keys and the mouse back to this computer. A hint at the bottom of the
    picture says so for 3 s after capture starts.
  - Clicking into the picture captures again.
- **Modifiers across systems:**
  - A Mac viewer driving Windows or Linux sends ⌘ as Ctrl, Ctrl as the Windows / Super key, and leaves ⌥ as Alt.
  - Windows or Linux driving a Mac does the reverse: Ctrl as ⌘, the Windows / Super key as Ctrl.
  - The ⋯ menu can turn this off.
- **Pointer:** absolute. Where the mouse is over the picture is where the host's pointer goes. The local pointer is hidden over the picture
  and the host's pointer is drawn from the cursor stream, as on the phone. Wheel and trackpad scrolling go through as scrolling. Buttons
  and drags go through as they are.
- **Displays:** the switcher draws the host's displays as they're arranged and switches with a click (`showDisplay`). By default, 跟着远端
  指针换屏 / Follow the Pointer is on, as `showDisplay(nil)` already does. 在新窗口中打开 / Open in New Window shows another display in
  a second window, which needs a second session.
- **Clipboard:** text only. It is sent to the host when keys are captured, and back from the host when its clipboard changes while
  captured. The ⋯ menu can turn it off.
- **Picture:** decoded locally from H.264 or HEVC, as negotiated today, and sized to the window, not to a phone screen. Resizing the
  window asks for a new size. Full screen is the system's own.
- **Paths:** the same as a phone, in the same order: same network, overlay, own relay, public connection service. The toolbar names
  the path in the agreed terms.

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
