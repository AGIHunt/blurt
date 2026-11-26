# Remote Control: the clipboard and files, both ways

2026-11-26. Status: being built (branch `claude/remote-files`). Users moving from NetEase UU asked for it: without it they keep both apps open.
Before this, a computer driving another (the viewer) shared text both ways while its keys were captured and sent files to the host; a
phone could only type its own clipboard's text. This adds every other direction, on every pairing: iPhone / iPad / Android ↔ Mac /
Windows / Linux, and computer ↔ computer. The wire: [remote-protocol.md](remote-protocol.md) §Clipboard and files.

## The panel (2026-11-26)

Five role-played users read a draft with eight settled points and ten open questions (`promo/cases/remote-files-1126/DISCUSS.md`,
their answers `vote-P1.md` … `vote-P5.md`):

| | Who | Score | Their one thing |
|---|---|---|---|
| P1 | newcomer, teacher, iPhone + Windows laptop | 8 | know where a file went, and open it with one tap |
| P2 | moved from UU, Windows at work + MacBook, Xiaomi phone, sends 100s of MB | 6.5 | big files resume after a drop; a list of transfers |
| P3 | power user, Mac Studio + MacBook + Ubuntu, iPhone, own relay on a VPS | 7 | resume that really works, no extra prompts |
| P4 | privacy-minded, Mac mini with client work, helps parents' Windows PC | 7 | nothing leaves a computer without a tap there and then, seen and logged |
| P5 | phone only, Android, 4G and the metro | 7.5 | resume across drops, and know the data a big file costs |

What they decided, and why:

| Question | Votes | Built |
|---|---|---|
| Keep a half-sent file how long after a drop (draft: 10 min) | P2, P3: 1 h; P5: 30 min and a way to continue; P4: fine with a way to delete | **1 hour**, × deletes at once, the transfers list continues one by hand |
| Show it on the computer when its clipboard is taken | a: P1, P4 · c (log only): P2, P3 · b/c: P5 | **The host's "being controlled" bar says it for 4 s** (P1 "一闪就过", P3's compromise) **and the connection log keeps it, without the content** (P4) |
| Where on the phone | a (a Transfer button on the bar): P1, P2, P4, P5 · c (a key): P3, a acceptable | **a** |
| An image from the computer | c: all five | the phone's clipboard, and a **Save to Photos** button on the card. Nothing is written to Photos by itself |
| Files from the computer | c (photos into Photos): P1, P2, P3, P5 · a (the app's folder): P4 | **a**, with **Open**, **Save to Photos** (pictures and videos) and **Share…** on the card: everyone's compromise, and Photos asks for its permission only when the button is used |
| Sending from the computer's side | a: P1, P2, P3 (right-click, not a bar) · b: P4, P5 | **Send Files… on the host's bar** while a device is connected (an explicit act at the computer, P4's condition). The Finder / Explorer right-click needs a shell extension on each system: later |
| Folders | b (zip them): P1, P2, P3, P5 · a: P4 | **zipped** where they're sent from; the card says 正在压缩… |
| An image on the phone's clipboard | a: P1, P2, P3, P5 · b: P4 (a only behind a button) | **yes, through the same button**: it never goes by itself |
| A big file over the own relay | b (time left): P1, P2, P3, P4 · c: P5 | **time left on the card**; and **on mobile data, more than 100 MB asks first** (P5; the others are on Wi-Fi) |
| Where files land on a computer | b (Downloads/Blurt): P1, P2, P4, P5 · a: P3 | **Downloads/Blurt** |
| Computer ↔ computer copy here, paste there in Finder / Explorer | a: P1, P4, P5 · b: P2, P3 (menu now, paste later) | **a menu item and a shortcut**; pasting files straight into Finder / Explorer is later |

Answered in writing:
- P4 objected to the share sheet's queue going out later by itself. Sharing to Blurt names the computer it goes to ("Send to Office PC"):
  that tap is the act. What waits shows in the transfers list with ×, and anything not sent within an hour is dropped.
- P4: the computer's clipboard goes only to the phone's clipboard, is never written to a file, and the log says "clipboard", not what it was.
- P2 asked for a card that appears whenever something is copied on the computer. No: the earlier panel and this one keep the clipboard a
  manual act on phones. The viewer's text clipboard (while keys are captured) is unchanged.
- P2's transfers list (UU's 传输列表) is in: the phones' Transfer sheet lists this run's transfers and the last 50 before.

Not this round: syncing the clipboard by itself on phones; browsing the computer's folders from the phone; dragging a file out of the
picture onto this computer's desktop; sending to several computers at once; pasting copied files into Finder / Explorer (P2, P3: next);
right-click Send to iPhone (P1, P2, P3: next).

## What the user does

**Phone → computer.** The Transfer button on the phone's bar (next to the screen button) opens the Transfer sheet:

- **Send Photos…** (the system photo picker: no permission asked), **Send Files…** (Files / the Android file picker; folders are zipped).
- **Get Copied Items from Office PC**: what is copied on the computer right now comes to the phone (below).
- The list of transfers: each with its name, where it goes or came from, progress and time left, × while going; done ones open on tap.

Also: the system **Share** sheet → **Blurt** (iOS share extension; Android `ACTION_SEND` / `ACTION_SEND_MULTIPLE`), to the
computer last controlled, named on the button. The phone's **Paste from This Phone** key (on the text keyboard's bar) now sends a copied
image too: the computer puts it on its own clipboard and pastes it into the app in front, as text has always been typed there.

Files land in **Downloads/Blurt** on the computer, quarantined (Mac quarantine flag, Windows Mark of the Web) so they never open by
themselves, with a notification there ("File from iPhone").

**Computer → phone.** Copy on the computer (on the picture, or at the computer): text, a screenshot, or files in Finder / Explorer /
Files. Then **Get Copied Items from Office PC** on the phone:

| Copied | What the phone does |
|---|---|
| text | onto the phone's clipboard; the card shows "Copied" and its first words |
| an image (a screenshot, a picture copied from an app) | onto the phone's clipboard; the card has **Save to Photos** |
| files or folders (folders zipped) | saved: iOS in Files → On My iPhone → Blurt (the app's home-screen name); Android in Download/Blurt. The card has **Open**, **Share…**, and **Save to Photos** for pictures and videos |
| nothing | "Nothing is copied on Office PC." |

Text longer than a message (64 KiB) comes as a file and is put on the clipboard all the same. The computer's bar says "Clipboard sent to
iPhone" for 4 s and the log keeps the time, never the content.

From the computer's side: **Send Files…** on the "being controlled" bar (Mac: also drop files on it) sends to the device connected now.

**Computer ↔ computer.** The viewer already sends files (Send Files…, or drop on the picture). New in its ⋯ menu: **Get Copied Items**
(⌥⌘V on a Mac, Ctrl+Alt+V elsewhere, when keys aren't going to the remote): what is copied on the other computer comes to this one's
Downloads/Blurt; an image comes onto this computer's clipboard; text already comes while keys are captured.

## Rules

- **Nothing moves by itself.** Every transfer starts from a tap or a click on one end. The clipboard is read only when asked.
- **Locked computer:** it neither takes nor gives (`locked`): "Office PC is locked."
- **Limits:** 4 GB a file; a batch has at most 1,000 files; an image pasted from the phone at most 20 MB. Names lose any folder part, `:`
  and leading dots; a name in use gets " 2", " 3" …
- **Space:** a receiver that hasn't the size plus 256 MB free says `space` before a byte is sent.
- **Progress:** the receiver says how much it has written every 1 MiB; the sender keeps at most 4 MiB ahead of that. Time left comes from
  the last 5 s of progress, shown once a file has gone for 2 s.
- **Cancel:** × on either end. The sender's ends the file short (`fileEnd` before `size`), the receiver's answers `fileFailed "stopped"`;
  either way the part is deleted at once.
- **Resume:** a dropped connection leaves the part. The receiver keeps it for 1 hour, keyed by device and file id. When the session is back,
  the sender begins the same file again with the same id; the receiver answers with how much it has, and the sender goes on from there.
  The card says "Paused. Resumes when reconnected." The phone's list has **Continue** on a paused file whose session didn't come back by
  itself. After an hour, or if the receiver has no part, it starts from 0.
- **Mobile data:** a phone on mobile data asks before more than 100 MB goes either way ("Send 350 MB over mobile data?"). A transfer that
  goes on after a drop asks again when it comes back on mobile data with more than 100 MB left (Wi-Fi lost mid-file): the same question,
  with what's left; until the answer the sender stops a window in, as for a new file.
- **Public connection service:** it only introduces the two ends; it can't carry files. Files wait until the direct path opens (usually a
  few seconds: the card says 正在建立直连…, as the status card does) and then go over it. If the direct path never opens the session ends with
  the existing no-direct message: nothing fails silently. Over an own relay, files go at the relay's speed, with time left.

## Where it's built

| | Sends | Receives | Clipboard |
|---|---|---|---|
| Swift core, `BlurtRemoteKit/RemoteFiles.swift` | `RemoteFileSender` (chunks, window, resume) | `RemoteFileReceiver` (parts kept 1 h, unique names, the space check) | `RemoteClipboard` |
| Mac host (`BlurtApp/Remote/RemoteHostFiles.swift`) | getClipboard's files (folders zipped) and image; the bar's Send Files… and drop on the bar; the bar shows how far | Downloads/Blurt, quarantine, one notification per batch | read on request (files, then an image, then text); a `clip` onto the pasteboard and ⌘V, except in a password field or at the lock screen, where the device gets a notice (Not pasted: …); a copied file over 4 GB answers `too_large` (zips made for it deleted); the bar says "Clipboard sent to …" 4 s; the log counts clipboard and files each way |
| Mac viewer (`BlurtApp/Viewer/ViewerFileSender.swift`) | Send Files… and drop (folders now zipped), paused and resumed | Get Copied Items (⋯, ⌥⌘V while keys stay here) → Downloads/Blurt, quarantined; the card's Show in Finder (or a click on the card) shows it | a `clip` or Get Copied text onto the pasteboard, whatever the Share Clipboard switch says (it was asked for) |
| Windows / Linux host (`crates/blurt-remote`) | as the Mac | Downloads/Blurt, Mark of the Web | Windows CF_UNICODETEXT / CF_DIB / CF_HDROP; Linux arboard text + image, `text/uri-list` for files |
| Windows / Linux viewer (`viewer.rs`, `apps/desktop`) | Send Files… (exists) | Get Copied Items | |
| Rust core, `crates/blurt-remote/src/files.rs` (2026-11-26) | `files::Sender` (chunks, window, resume; a thread per sender) | `files::Receiver` (parts kept 1 h per device + id, unique names, the space check via statvfs / GetDiskFreeSpaceExW, Mark of the Web) | `Input::copied` / `Input::paste_clip` (host.rs), `platform/clip.rs` |
| Windows / Linux host, as built (`server.rs`, `platform/clip.rs`, `apps/desktop` remote.rs) | a sender per device, held until `session` has gone and, on the public connection service, the stream moved; getClipboard's files (folders zipped, stored), image (PNG), text over 64 KiB as `Text.txt`; the bar's Send Files… (`remote_send_files`) | Downloads/Blurt for every device, Mark of the Web on Windows, one notification per batch | read on request through arboard: Windows CF_HDROP, then "PNG" / CF_DIBV5, then text; Linux `text/uri-list`, then `image/png`, then text (Wayland data-control where the compositor has it, else XWayland's clipboard, which mutter keeps in step). A phone's `clip` image (PNG, JPEG, TIFF, BMP; not HEIC) or text onto the clipboard, then Ctrl+V, except in a password field or at the lock screen, where the device gets a notice (Not pasted: …). A copied file over 4 GB answers `too_large`. The bar says "Clipboard sent to …" 4 s and how far a file to the device is; the log counts clipboard, received, sent |
| Windows / Linux viewer, as built (`viewer.rs` + `apps/desktop` viewer.rs, `ViewerWindow.tsx`) | Send Files… and drop (folders now zipped, "Compressing…"), paused across a drop and resumed | Get Copied Items (⋯, Ctrl+Alt+V while keys stay here) → Downloads/Blurt with the Mark of the Web; the files card shows each one with ×, its line, time left, Show in Folder | a `clip` image or text onto this computer's clipboard (tauri clipboard plugin), Get Copied text too, whatever the clipboard switch says |
| iPhone / iPad (`apps/ios`) | photo picker, document picker, share extension, Paste from This Phone (image) | Documents (shown in Files) | UIPasteboard |
| Android (`apps/android`) | photo picker, `ACTION_OPEN_DOCUMENT`, share intents | MediaStore Downloads/Blurt (API 29+), app external files below | ClipboardManager |

## Copy

Every platform uses these words (copy.md; reuse where a string exists). `%@` is a device's or computer's name as this end shows it (its alias).
Android says 分享 where iOS says 共享, and 相册 / Gallery where iOS says 照片 / Photos.

| Where | 中文 | English |
|---|---|---|
| The phone's bar button (accessibility) and the sheet's title | 传输 | Transfer |
| Sheet actions | 发送照片… · 发送文件… · 获取 %@ 上拷贝的内容 | Send Photos… · Send Files… · Get Copied Items from %@ |
| The sheet's empty list | 发送或获取的文件会显示在这里。 | Files you send or get appear here. |
| A row going out · coming in (`%@ / %@` done / size) | 发往 %@ · %@ / %@ · 来自 %@ · %@ / %@ | To %@ · %@ of %@ · From %@ · %@ of %@ |
| A batch (prefix) · time left (suffix, system duration) | 第 %ld/%ld 个 · 还剩 %@ | %ld of %ld · %@ left |
| States | 等待中 · 正在建立直连… · 正在压缩… · 正在准备…（照片载入中）· 已暂停，重新连接后继续。 · 已停止 | Waiting · Connecting directly… · Compressing… · Preparing… (photos loading) · Paused. Resumes when reconnected. · Stopped |
| Paused, with Continue beside it (the button says the rest) · paused because the app went out of sight | 已暂停 · 打开 Blurt 后继续。 | Paused · Resumes when Blurt is open. |
| Photos that couldn't come out of the library (iPhone) · the Preparing… row's name | %ld 项无法载入。 · %ld 项 | Couldn’t load %ld items. · %ld items |
| A paused row beside its Continue button (the button says the rest; one line) | 已暂停 | Paused |
| Sent (a computer that resumes) · sent to an older one, which saves in Downloads (as the Mac viewer's `viewer.file.saved.to`) | 已保存到 %@ 的「下载/Blurt」 · 已保存到 %@ 的「下载」文件夹 | Saved to Downloads/Blurt on %@ · Saved to Downloads on %@ |
| More than 1,000 picked or shared: nothing goes | 一次最多发送 1,000 个。 | Send up to 1,000 at a time. |
| Received on iPhone · on Android · on a computer | 已保存到「文件」App 的 Blurt 文件夹 · 已保存到「Download/Blurt」 · 已保存到「下载/Blurt」 | Saved to Files › Blurt · Saved to Download/Blurt · Saved to Downloads/Blurt |
| A received file's buttons (iPhone: a tap opens it, touch and hold has Share… and Save to Photos, as in Files) | 打开 · 共享… · 存储到照片 · 在访达中显示 / 在文件夹中显示（Windows）/ 在「文件」中显示（Linux） | Open · Share… · Save to Photos · Show in Finder / Show in Folder (Windows) / Show in Files (Linux) |
| A transfer's buttons | 停止 · 继续 | Stop · Continue |
| What came from the clipboard (a row each: ✓, this title, the first words or Save to Photos / Gallery on the right) | 已拷贝 · 已拷贝图片 | Copied · Image Copied |
| Nothing came | %@ 上没有拷贝的内容。 · %@ 已锁屏。 · %@ 上拷贝的文件太多。一次最多 1,000 个。 · %@ 上拷贝的文件超过 4 GB。（`too_large`）· 无法从 %@ 获取此类内容。 · 若要使用此功能，请更新 %@ 上的口喷鸡。 | Nothing is copied on %@. · %@ is locked. · Too many files are copied on %@. Copy up to 1,000 at a time. · A file copied on %@ is larger than 4 GB. (`too_large`) · Can't get this kind of item from %@. · To use this, update Blurt on %@. |
| Not sent (exist, viewer.file.failed.*) | 未发送：对方空间不足。 · 未发送：文件超过 4 GB。 · 未发送：对方已锁屏。 · 未发送。 | Not sent: not enough space on that computer. · Not sent: larger than 4 GB. · Not sent: that computer is locked. · Not sent. |
| Not received | 未接收：本机空间不足。 · 未接收。 | Not received: not enough space on this device (on a computer: this computer). · Not received. |
| Mobile data (title · buttons) | 使用移动网络发送 %@？ · 使用移动网络接收 %@？ · 发送 · 接收 · 取消 | Send %@ over mobile data? · Get %@ over mobile data? · Send · Get · Cancel |
| An image pasted from the phone, too big | 无法粘贴超过 20 MB 的图片。 | Can’t paste images larger than 20 MB. |
| Share extension, named Blurt as on the home screen (button · nothing paired · after the tap · how many, beside the title, for 2 or more) | 发送到 %@ · 请先在 Blurt 中配对电脑。 · 请在一小时内打开 Blurt 发送。 · %ld 项 | Send to %@ · Pair a computer in Blurt first. · Open Blurt within an hour to send. · %ld items |
| iOS Photos permission (NSPhotoLibraryAddUsageDescription) | 将从电脑获取的照片和视频存储到「照片」。 | Save pictures and videos from your computer to Photos. |
| The host's bar: who (was 正在被“%@”控制 / “%@” is controlling this computer, 2026-11-26; the Mac's was 正在被「%@」控制 / “%@” is controlling this Mac) | %@ 正在控制本机 | %@ is controlling this computer (Mac: this Mac) |
| The host's bar: button (only for a device that takes files) · notice for 4 s | 发送文件… · 剪贴板已发送到 %@ | Send Files… · Clipboard sent to %@ |
| The host's bar while a file goes to the device (in place of who; the batch after the name; on the Mac also the viewer card's line, before time left: was Sending %ld of %ld to %@ · %@ of %@ / 正在发送第 %ld/%ld 个到 %@ · %@ / %@) · paused · failed, 4 s | 发往 %@ · 第 %ld/%ld 个 · %@ / %@ · 已暂停，重新连接后继续。 · 未发送。 | To %@ · %ld of %ld · %@ of %@ · Paused. Resumes when reconnected. · Not sent. |
| Time left's number (inside 还剩 %@ / %@ left): minutes above 60 s, seconds below, a space before the unit | %ld 分钟 · %ld 秒 | %ld min · %ld sec |
| A device's pasted image or long text held back in a password field or at the lock screen (a notice to the device; Mac, Windows and Linux hosts; was 或屏幕已锁定。内容已放入对方的剪贴板。 / or the computer is locked. It’s on that computer’s clipboard.) | 未粘贴：对方的光标在密码框中，或对方已锁屏。内容已放入其剪贴板。 | Not pasted: the cursor is in a password field, or that computer is locked. It’s on its clipboard. |
| The host's notification for several files | 收到「%@」发来的 %ld 个文件 | %ld files from %@ |
| The host's connection log | 已发送剪贴板 · 收到 %ld 个文件 · 已发送 %ld 个文件 | Clipboard sent · Received %ld files · Sent %ld files |
| The viewer's ⋯ menu | 获取拷贝的内容 | Get Copied Items |

## Measurements

| What | Result | How |
|---|---|---|
| A 3 MB file, viewer → host, through the go-between in budget mode (`BUDGET=1`), moved stream on loopback | 369–426 ms over 3 runs, including the wait for the move; the go-between carried < 16 KiB and never hit its budget | `RemoteViewerSessionTests.testFilesBothWaysThroughTheBudgetRelay` |
| Get Copied, a 1.2 MB file and a 10-byte one, host → viewer, same session | both whole, in order (index 1, 2) | the same test |
| A drop at 5.6 of 12 MB, then back | only the missing part goes again (≤ one chunk more) | `RemoteFilesTests.testADropPausesAndTheSameFileGoesOnFromWhereItWas` |

| Rust: the engine back to back, a batch, a name in use, a drop at 5.6 of 12 MB then back, a part kept over an hour, × on either end, a clip, a locked receiver, an older receiver without resume | 12 tests, 0.38 s; after the drop only what was missing went again (≤ one chunk more) | `cargo test -p blurt-remote --lib files` (2026-11-26, this Mac) |
| Rust host → the test phone on loopback (its end is `files::Receiver`): copied text, 30,000 Chinese characters as `Text.txt`, a PNG as `Image.png`, two files and a folder (zipped) as one batch, 1,001 files (`too_big`), a phone's pasted image | all whole; 4.9 s for the test, most of it pairing | `tests/files.rs` `copied_text_an_image_and_files_come_to_the_phone` |
| Rust host → test phone, 12 MB from the bar's Send Files…, the phone gone at 40 % and back | resumed with the same id; at most what was missing plus the 4 MiB window went again | `tests/files.rs` `a_file_sent_from_the_bar_goes_on_after_the_phone_drops` |

| A 50 MB file, Android emulator → fake host, throttled to 1.5 MB/s | with a fixed 4 MiB window the phone dropped its session 21 times (pings waited 2.7 s behind file data); with the rate-based window, no drop, 34 s | `apps/android/fakehost`, 2026-11-26 |
| A drop mid-file on the Android emulator | went on from 17,694,720 bytes, 45 ms after the session reopened | the same rig |
| 136 MB host → phone after Get Copied Items on (emulated) mobile data | asked first, then arrived with the same SHA-256 | the same rig |
| 136 MB host → phone begun on Wi-Fi, the session dropped at 3 MB and back on mobile data | asked "Get 131 MB over mobile data?" (what was left), went on from 3,145,728 bytes after Get | the same rig, `RemoteFilesTest.aFileThatGoesOnAfterADropIsAskedAboutAgain` |
| 136 MB phone → host (share sheet) begun on Wi-Fi, dropped, back on mobile data | asked again before a byte more went; after Send it went on from where the host had it | the same rig |

### Windows and Linux, the bar and the card (2026-11-26, design-judge round)

- **The bar** (`RemoteBanner.tsx`, remote.rs `banner`): it now says what the Mac's says. While a file goes to the device (Send Files…,
  Get Copied Items' files; not a clip) the line is where and how far, from `remote://transfer` (and `remote_transfers` when the bar opens),
  the one going first, then one waiting, then one paused; a failure other than × says 未发送。 for 4 s. Send Files… shows only when the
  connected device's hello listed `files` (`Status.connected.files`); before, it showed for every device and did nothing for one without.
- **Its size:** the window was a fixed 480 × 38, which left about 200 px empty after the zh line. The page measures the bar
  (`width: max-content`, at most the display less 40 px, then …) and `remote_banner_fit` sets the window to that width, even, centred
  again. Radius 10 px with a 1 px white 12 % border; Linux makes the window transparent so the corners are the page's, Windows 11 rounds
  the undecorated window itself (8 px, so the page uses 8). Send Files… and Disconnect share one button style.
- **Round 2** (a fresh judge on r1): the bar still changed width with its line (612 → 875 → 985 → 1030 px in the shots), so the buttons
  moved under the pointer. Now the Mac's rule: saying who, the line is as wide as the wider of who and "Clipboard sent to …" (both
  measured in the page); a flash or a file's line keeps at least that and never narrows while it shows (paused and Not sent. too); back
  to who, back to that width. Both buttons semibold, as the Mac's. The card: a finished row shows a check and a failed one the warning
  mark (a stopped one keeps its arrow); the line is direction first, as the Copy table: "From %@ · 2 of 3 · …" / 来自 %@ · 第 2/3 个 · …
  (was the batch first); the header's × is a plain glyph (a row's × stops a file and keeps its circle) on the rows' right inset (it sat
  2 px out); a received file's button is Show in Folder / 在文件夹中显示 on Windows and Show in Files / 在「文件」中显示 on Linux (the
  card had the main window's Show in File Explorer). Shots `windows-linux/r2/` (`viewer-files-card-close-windows-*` for Windows).
- **Round 3** (the last judge on r2): the bar still went 788 → 920 → 1046 px and back to 788 on paused (zh). Now it has one width
  from the moment it shows for a device: the widest line it can say for that device (who, the clipboard line, a file at its longest,
  "10 of 10 · 999.9 MB of 999.9 MB", paused, Not sent.), so nothing moves during a session: r3 is 570 px in every state in en, 562 in
  zh (460 / 465 with no Send Files…). The line is semibold as the Mac's, the two buttons the same weight. The card's going row has two
  fixed lines as the phones: where and "2 of 3", then how far and time left (2 min left no longer lands alone on Windows); a row's ×
  is the same plain glyph as the card's; a paused bar is the accent dimmed, not grey. Shots `windows-linux/r3/`.
- **The card's line** (`ViewerWindow.tsx` FileLine): it wrapped inside a value ("… · 1 / min, 35 sec left", zh after a trailing ·). Each
  " · " piece is now an unbreakable inline block that brings its own dot, and the line starts one dot-width left under a clip, so a
  wrapped line neither starts nor ends with a dot; a piece wider than the card ends in …. A line without " · " (a sentence) wraps as one.
  Numbers are tabular. Time left is one unit: 2 分钟 / 2 min above 60 s, 40 秒 / 40 sec below (Intl's short duration gave 1 分钟 35 秒 and
  2分钟 without a space).
- **The card:** × and Show in Folder are pinned at 20 px (the shell's button min-height made × a tall oval); the header has no
  background; 10 px under the last row; the card is opaque, since a light window in the picture showed through its 6 % as a band.
- Shots: `promo/cases/remote-files-1126/windows-linux/r1/` (the bar in every state, en and zh; the card), from the web app's mock
  (`?banner=1&phone=paired&banner_state=going|batch|paused|failed|clipboard`, `&banner_files=0`; `?viewer=den&viewer_files=1`) in headless
  Chromium at 2×.

### The Mac, the bar and the card (2026-11-26, design-judge round)

- **The bar** (`RemoteBanner.swift`): its width jumped between who (420 pt), "Clipboard sent to iPhone" (392) and a file going (495), so
  Send Files… and Disconnect slid under the pointer. Now the idle bar is as wide as the wider of who and the clipboard line, and a file's
  line takes max(that, what it needs) and never narrows while it shows; the line takes the spare room, the buttons stay at the end.
  Digits are tabular. Insets 12 / 11 pt (were 12 / 6: Disconnect nearly touched the end). Measured with the test hooks
  (`remotebar iPhone | clipboard | sending`): en 414 / 414 / 458 pt, zh 316 / 316 / 430 pt. A file's line still widens it once (the sending line is longer than who); it
  stays put for the rest of the transfer.
- **The card** (`ViewerFileCard`): the line keeps To / From when time left shows (it dropped the name, so a file coming in read like one
  going out): "To Studio · 2 of 3 · 5.1 MB of 8.4 MB · 40 sec left". Two-line states are 420 pt (was 380) so that line fits;
  one-line states (Copied, Nothing is copied…) hug their text, 260–460 pt, and wrap past that. Time left is one unit, by hand
  (DateComponentsFormatter wrote 40秒 / 1分钟 in Chinese). Tabular digits. Saved, received and failed centre their two lines (they sat
  at the top over an empty bar's room); paused keeps its bar where it got to, at 40 %. Received has a Show in Finder button (the card's
  click still shows it too). Nothing copied and locked use the info mark; the triangle stays for what failed.
- **Round 2** (a fresh judge on r1): Send Files… had regular weight beside a semibold Disconnect and read as disabled; both are
  semibold now. A PDF being sent showed Chrome's page (`NSWorkspace.icon(for:)` is the default app's document icon); a file here being
  sent now shows its Quick Look thumbnail (icon mode, as Finder), the type icon only until that comes or for a file still coming in.
  One-line states (Copied, Nothing is copied…, too_large) are 44 pt tall with a 26 pt mark and hug their text from 150 pt (were 62 pt
  tall, 260 pt at least, with a wide gap before ×); one that wraps gets the two-line height back. Shots `mac/r2/`, with the bar's
  paused and Not sent. lines (`remotebar paused | failed`) and each bar also on the made-up desktop picture (`*-desk-*.png`: the bar's
  own window shot laid under that picture's menu bar; the harness shoots the bar's window alone, never this Mac's screen).
- Shots: `promo/cases/remote-files-1126/mac/r1/` (the bar's three lines and the card's ten states, en and zh), from the isolated test
  app: the bar from its test hook alone (nothing controls this Mac), the card on a pretend host in the same process (`viewer hint file.*`).

Not measured yet: a real phone over Wi-Fi and mobile data; a real Mac host (m1max, LAN-only, wasn't reachable from this Mac's network on
2026-11-26); Windows and Linux hosts (CI builds and tests only).

## iPhone and iPad (2026-11-26)

| | Built | Where |
|---|---|---|
| The wire | `hello.features` adds `files` and `resume`; `session.features` is kept as `Link.hostFeatures` until the next session. One `RemoteFileSender` and one `RemoteFileReceiver` in `Link`, the receiver keyed by the computer's own id. The sender sends only on a session whose stream has moved (go-between) and pauses on `lost()` / `disconnect()`; switching computers stops what was queued for the last one | `apps/ios/BlurtRemote/Net/Link.swift` |
| Received files | the app's Documents, shown in Files as **Blurt** (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`); parts in Caches/parts | Info.plist |
| The bar | **Transfer** (↑↓) beside the screen button in every layout; lit while something goes or waits. Portrait: the four icons by the arrow key went from 36 to 32 pt so the tabs lose 16 pt, not 36 (strip 156 → 136 pt on a 402 pt phone, 145 → 129 on 375); then (r1) Transfer's 13 pt arrows take a 28 pt cell (24 on a narrow phone) and one line of tabs keeps 8 pt between names instead of 10: strip 140 pt, and 常用 字母 符号 更多 (104 pt at 13 pt) render at 13 pt (12 before). English names need 164 pt at 13 pt, more than the strip has had since the find button came (156 pt), so they stay at the 10 pt floor; landscape tabs are 13 pt in both languages (the strip there doesn't share the row). Landscape: five controls at the island's end don't fit at 42 pt between a 132 pt island and the corners, so all five are as tall as three that do (35 pt on a 402 pt-tall phone, 40 on 440) | `Pad/PadLayout.swift` |
| The sheet | Send Photos… (PHPicker, `.current` representation, no permission), Send Files… (document picker, opened in place, folders zipped with a Compressing… row), Get Copied Items (disabled with "To use this, update Blurt on %@." for a host without `clipboard`), the answer under it, and the list: this run, then the last 50 finished (Application Support/transfers.json). Stop on anything not over; Continue on this run's outgoing files that paused or failed on the way (not stopped, too big, no space or unreadable), as a text button under the bar's end so every bar ends at the same x; a paused row beside it says just 已暂停 / Paused. A received file's row opens on a tap (Quick Look) and a touch and hold has Share… and Save to Photos (pictures and videos; add-only permission asked on the first tap): r0's Menu popped over the row and the one above. Get Copied Items' icon is an outline clipboard like the two above it; the touch-and-hold menu's icons are in the label colour, not mint; a Preparing… row has × (what it loads is dropped). Leading icons: arrows while moving, the file's kind (photo, film, table, PDF, zip, doc) in secondary once over, a red ! when it failed. The first section sits ~20 pt under the title (`.contentMargins(.top, 11)`, compact section spacing; it was ~44) | `Files/TransferSheet.swift`, `Files/Transfers.swift` |
| A row's line | a file on its way has the same two lines both ways: where (with its place in a batch), then how far and the time left ("2 of 3 · To MacBook Pro" / "148 MB of 412 MB · 3 min left"; r1 broke wherever it fit, so going out and coming in read differently). Parts never break inside (no-break spaces and word joiners); other states are one line of up to two | `TransferWords.going`, `TransferRowView.whole` |
| Get Copied's answer, sheet away | a toast at the top of the stage, a mint ✓ before Copied / Image Copied as on Android (4 s; 8 s with Save to Photos for an image, a mint-tinted capsule: the light filled one was the brightest thing on the screen) | `Files/TransferToast.swift` |
| Mobile data | `NWPathMonitor.usesInterfaceType(.cellular)` (a hotspot is Wi-Fi). Sending: a pick over 100 MB in all asks first. Getting: a begin whose batch has over 100 MB left (what a resumed file already has doesn't count) is taken, but past the receiver's first answer its progress isn't said, so the computer stops a window (≤ 4 MiB) in and waits up to a minute instead of giving up after 10 s; a file that all came in that window keeps its end until the answer. Asked once per batch; not answered in 50 s is no; a no stops it (`stopped`, part deleted) and refuses the rest of that batch for 2 minutes; a short end meanwhile (the computer gave up or stopped it) closes the question. Sending: on a session that comes up on mobile data, or Wi-Fi going while files go, more than 100 MB left asks again; until then nothing begins and no chunk goes (a short end still does), a yes holds 10 minutes, a no stops them. Out of sight (the ~25 s the session stays in the background) a paused row says 打开 Blurt 后继续。 | `Transfers.admit`, `answer`, `onMobileData`; `Link.fileIn`, `feed`, `answerFile`, `holdOutgoing` |
| Paste from This Device | an image on the pasteboard, to a host with `clipboard`, goes as a `clip` PNG or JPEG (≤ 20 MB, else "The image is larger than 20 MB."); text as before | `Keys/TypeField.swift`, `Transfers.pasteImage` |
| Share extension | **Blurt** in the share sheet (images, movies, files, up to 1,000); the system's sheet in the phone's light or dark appearance with the content at its top (r1's dark card over a grey wash scored 5), showing the first item as a 40 pt thumbnail (an ImageIO thumbnail, never the whole photo decoded in the extension's memory) and, for 2 or more, how many beside the title. "Send to %@" names the computer last controlled (App Group defaults, written when a session is ready); the tap copies the items into the group's Outbox with that computer's id, then "Open Blurt within an hour to send."; nothing paired: "Pair a computer in Blurt first." The app takes the outbox when it's in front and ready with that computer (scene active, session up), sends each share as a batch and deletes the copies once over; waiting shares show as Waiting rows with ×; anything over an hour old, or a half-filled share as old, is deleted | `apps/ios/BlurtShare`, `apps/ios/Shared/Outbox.swift` |
| App Group | `group.dev.blurt.remote` (debug, `dev.blurt.remote` / `.share`), `group.work.blurt.remote` (release), from the `BLURT_APP_GROUP` build setting into the entitlements and Info.plist's `BlurtAppGroup` | `project.yml` |

| What | Result | How |
|---|---|---|
| The model: each row's line, the nothing-copied reasons, the 100 MB rule both ways, a held batch (yes, no, given up), the list's order and the 50 kept, Continue, Stop, the outbox (per computer, an hour, a share still being filled, × on one file) and its pickup (only in front, only for that computer), one file through the real engine to Saved | 15 tests pass; the whole suite 210 tests, the 2 MacDeckGoldenTests failing as on main. r1 (2026-11-26): 19 TransferTests (the line's breaks, Paused beside Continue, out of sight, Downloads on an older computer, `too_large`, a resumed file asked only about what's left and held as Waiting, the question closing when the computer gives up or the session goes, sending asked again on mobile data); the suite 214, the same 2 failing | `BlurtRemoteTests/TransferTests.swift`, XCTest injected with simctl (iPhone 17 Pro simulator) |
| Share → Blurt from Photos in the simulator, then the app opened | the photo landed in the group's Outbox with the computer's id; the app took it on opening and queued it (Outbox empty after) | by hand, `promo/cases/remote-files-1126/ios/share-*` |
| Save to Photos on a received picture | the add-only question on the first tap, then the picture in Photos | by hand in the simulator |

Not checked on iOS: a real host session (no host on this Mac; the Android fake host doesn't speak files), a device build with the App
Group provisioned (simulator builds sign it locally), mobile data on a device.

### Android (2026-11-26)

Built in `apps/android` (details and numbers: [remote-android.md](remote-android.md) §Files and the clipboard):

| | Where | What |
|---|---|---|
| Engine | `core/RemoteFiles.kt` (`RemoteFilesTest`, `VectorsTest`) | the Swift engine's behaviour; plus a target computer per file, the share queue's hour, and a receiver hold for the mobile-data question |
| Wire | `core/RemoteMessages.kt` | `ToMac.FileBegin` clip/index/count/total; `FileProgress` / `FileSaved` / `FileFailed` / `GetClipboard`; `ToPhone.FileBegin` / `FileChunk` / `FileEnd` / `ClipboardNone`; hello `files`, `resume` |
| Sends | `files/Transfers.kt`, `sheets/TransferSheet.kt`, `ShareActivity.kt` | photo picker, document picker, a folder zipped, the share sheet, Paste from This Device (image) |
| Receives | `files/Downloads.kt` | MediaStore Download/Blurt (Android 10+), the app's own Download/Blurt below; Save to Gallery on tap |
| Clipboard | `files/Transfers.kt` | ClipboardManager; an image through the FileProvider |

Android-only words, beyond the Copy table: **发送文件夹… / Send Folder…** (its own row under Send Files…, with a folder icon, since the
Android document picker can't pick a folder with files), and the share sheet's "nothing paired" line names the Android app as it's installed:
请先在口喷鸡中配对电脑。 / Pair a computer in Blurt first. Android opens the app itself after a share with no session, so it doesn't need
"Open Blurt Remote to send."

The share dialog (Android): the title **发送到 %@ / Send to %@** names the computer, the body lists the items as name · size (four, then
…), and the buttons are **取消 · 发送 / Cancel · Send**. It follows the phone's light or dark theme (it sits over another app); the
app's own screens stay dark. Sizes and the mobile-data question keep "136 MB" whole (a no-break space between the number and the unit), and
both dialogs break their title into even lines ("Get 132 MB over / mobile data?", never a lone "data?") with Material's 24 dp under the
buttons' labels (`AskDialog`; AlertDialog left about 45 dp).

The sheet (round 2, 2026-11-26): the transfers are one grouped list, as Files by Google shows a folder: a row each, dividers at the text,
no buttons under a name. A tap on a received file opens it; its ⋮ (**更多选项 / More Options** to TalkBack) holds **分享… · 保存到相册 /
Share… · Save to Gallery**, the second greyed with ✓ once saved. Icons sit in one 24 dp slot, so every title starts 54 dp in. A stopped row
leaves the list when the same file (name, way, computer) begins again. Get Copied Items greyed says why under it: the pad card's
正在重新连接 %@… / Reconnecting to %@… or 无法连接 %@ / Can't connect to %@, or the update line. The bar's Transfer arrows are one path (two
translucent strokes overlapped into bright dots at the tips) and turn mint while something goes or waits, as on the iPhone.

A finding for every end: a file going out queues the sender's own pings behind up to 4 MiB. At 1.5 MB/s the Android phone dropped its
session every few seconds until it counted the computer's file progress as a sign of life; a host or viewer that times out on pongs alone will
do the same when the phone or viewer sends it a big file slowly.

