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

**Computer ↔ computer.** The viewer already sends files (Send Files…, or drop on the picture). New in its ⋯ menu: **Get Copied Files**
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
  The card says "Paused. Continues when reconnected." The phone's list has **Continue** on a paused file whose session didn't come back by
  itself. After an hour, or if the receiver has no part, it starts from 0.
- **Mobile data:** a phone on mobile data asks before more than 100 MB goes either way ("Send 350 MB over mobile data?").
- **Public connection service:** it only introduces the two ends; it can't carry files. Files wait until the direct path opens (usually a
  few seconds: the card says 正在建立直连…, as the status card does) and then go over it. If the direct path never opens the session ends with
  the existing no-direct message: nothing fails silently. Over an own relay, files go at the relay's speed, with time left.

## Where it's built

| | Sends | Receives | Clipboard |
|---|---|---|---|
| Swift core, `BlurtRemoteKit/RemoteFiles.swift` | `RemoteFileSender` (chunks, window, resume) | `RemoteFileReceiver` (parts kept 1 h, unique names, the space check) | `RemoteClipboard` |
| Mac host (`BlurtApp/Remote/RemoteHostFiles.swift`) | getClipboard's files (folders zipped) and image; the bar's Send Files… and drop on the bar; the bar shows how far | Downloads/Blurt, quarantine, one notification per batch | read on request (files, then an image, then text); a `clip` onto the pasteboard and ⌘V; the bar says "Clipboard sent to …" 4 s; the log counts clipboard and files each way |
| Mac viewer (`BlurtApp/Viewer/ViewerFileSender.swift`) | Send Files… and drop (folders now zipped), paused and resumed | Get Copied Files (⋯, ⌥⌘V while keys stay here) → Downloads/Blurt, quarantined; a click on the card shows it in Finder | a `clip` or Get Copied text onto the pasteboard, whatever the Share Clipboard switch says (it was asked for) |
| Windows / Linux host (`crates/blurt-remote`) | as the Mac | Downloads/Blurt, Mark of the Web | Windows CF_UNICODETEXT / CF_DIB / CF_HDROP; Linux arboard text + image, `text/uri-list` for files |
| Windows / Linux viewer (`viewer.rs`, `apps/desktop`) | Send Files… (exists) | Get Copied Files | |
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
| States | 等待中 · 正在建立直连… · 正在压缩… · 已暂停，重新连接后继续。 · 已停止 | Waiting · Connecting directly… · Compressing… · Paused. Continues when reconnected. · Stopped |
| Sent | 已保存到 %@ 的「下载/Blurt」 | Saved to Downloads/Blurt on %@ |
| Received on iPhone · on Android · on a computer | 已存到「文件」App 的 Blurt 文件夹 · 已存到「Download/Blurt」 · 已保存到「下载/Blurt」 | Saved in Files › Blurt · Saved to Download/Blurt · Saved to Downloads/Blurt |
| A received file's buttons | 打开 · 共享… · 存储到照片 · 在访达中显示 / 在文件夹中显示 | Open · Share… · Save to Photos · Show in Finder / Show in Folder |
| A transfer's buttons | 停止 · 继续 | Stop · Continue |
| What came from the clipboard | 已拷贝 · 已拷贝图片 | Copied · Image Copied |
| Nothing came | %@ 上没有拷贝的内容。 · %@ 已锁屏。 · %@ 上拷贝的文件太多。一次最多 1,000 个。 · 无法从 %@ 获取此类内容。 · %@ 需要更新后才能使用。 | Nothing is copied on %@. · %@ is locked. · Too many files are copied on %@. Send up to 1,000 at a time. · Can't get this kind of item from %@. · Update %@ to use this. |
| Not sent (exist, viewer.file.failed.*) | 未发送：对方空间不足。 · 未发送：文件超过 4 GB。 · 未发送：对方已锁屏。 · 未发送。 | Not sent: not enough space on that computer. · Not sent: larger than 4 GB. · Not sent: that computer is locked. · Not sent. |
| Not received | 未接收：本机空间不足。 · 未接收。 | Not received: not enough space on this device. · Not received. |
| Mobile data (title · buttons) | 使用移动网络发送 %@？ · 使用移动网络接收 %@？ · 发送 · 接收 · 取消 | Send %@ over mobile data? · Get %@ over mobile data? · Send · Get · Cancel |
| An image pasted from the phone, too big | 图片超过 20 MB。 | The image is larger than 20 MB. |
| Share extension, named Blurt as on the home screen (button · nothing paired · after the tap) | 发送到 %@ · 请先在 Blurt 中配对电脑。 · 打开 Blurt 即可发送。 | Send to %@ · Pair a computer in Blurt first. · Open Blurt to send. |
| iOS Photos permission (NSPhotoLibraryAddUsageDescription) | 将从电脑获取的照片和视频存储到“照片”。 | Save pictures and videos from your computer to Photos. |
| The host's bar: button · notice for 4 s | 发送文件… · 剪贴板已发送到 %@ | Send Files… · Clipboard sent to %@ |
| The host's notification for several files | 收到「%@」发来的 %ld 个文件 | %ld files from %@ |
| The host's connection log | 发送了剪贴板 · 收到 %ld 个文件 · 发送了 %ld 个文件 | Sent the clipboard · Received %ld files · Sent %ld files |
| The viewer's ⋯ menu | 接收拷贝的文件 | Get Copied Files |

## Measurements

| What | Result | How |
|---|---|---|
| A 3 MB file, viewer → host, through the go-between in budget mode (`BUDGET=1`), moved stream on loopback | 369–426 ms over 3 runs, including the wait for the move; the go-between carried < 16 KiB and never hit its budget | `RemoteViewerSessionTests.testFilesBothWaysThroughTheBudgetRelay` |
| Get Copied, a 1.2 MB file and a 10-byte one, host → viewer, same session | both whole, in order (index 1, 2) | the same test |
| A drop at 5.6 of 12 MB, then back | only the missing part goes again (≤ one chunk more) | `RemoteFilesTests.testADropPausesAndTheSameFileGoesOnFromWhereItWas` |

Not measured yet: a real phone over Wi-Fi and mobile data; a real Mac host (m1max, LAN-only, wasn't reachable from this Mac's network on
2026-11-26); Windows and Linux hosts (CI builds and tests only).
