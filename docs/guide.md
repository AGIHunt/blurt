# Blurt user guide · 使用指南

[English](#english) · [中文](#中文)

---

## English

Blurt turns what you say, snap and record into items — issues, ideas, notes, tasks — in your projects, and hands
them to a coding agent. On a Mac it also types what you say wherever your cursor is (**dictation**, `Fn`).
This page covers everything you do in the app; *Help → Blurt User Guide* and *Settings → General → User Guide* open
it. Shortcuts are the macOS defaults; on Windows and Linux read `⌥` as `Alt` and `⇧` as `Shift`. Every shortcut can be
changed in *Settings → Shortcuts*. Settings (`⌘,`) lists its panes in a sidebar with a search field on top: type what you
are looking for (`⌘F`), in English or Chinese — "login", "mirror", "快捷键" — and pick a result (or press `↩`) to jump
to that setting.

**First minute.** Blurt lives in the menu bar (Peep, the little round chick). The first launch walks you through what dictation
needs — the Microphone and Accessibility (Input Monitoring only if your key needs it); Screen Recording is asked for the
first time you snap or record. There is nothing to download: on macOS 26 dictation uses the Mac's own speech
recognition, and one optional AI-service key (DeepSeek recommended for polish, Aliyun for speech) fixes misheard words,
punctuation and names. On macOS 13–15 the key comes first, since those versions lack the new recognizer. Local models
(more accurate, offline) are an optional download that takes over once it is in. After that, try `Fn` in any text
field to dictate, `⌥A` to snap and `⌥C` to copy text from the screen. The notch at the top of the screen says one short line when there is something
to know — at most one at launch. It always says the latest thing you did (a newer line takes the place of an older
one about the same thing); a line with *Undo* stays at least 5 seconds and waits while the pointer is on it. Clicking the line opens the
notch; only its button undoes. The main window's messages ("Moved to …", "Done · Undo") show there too, and `⌘Z`
still undoes there after the line is gone.

### 1. Capture

The **notch** at the top of the screen is where capture starts (on a screen without a notch, and on Windows and
Linux, a small capsule in the same place). Hover it to see your current project and the ways to capture.

| | Shortcut | What happens |
|---|---|---|
| **Snap** | `⌥A` | Drag an area and let go: the picture stays frozen where it is (the rest of the screen dims) and the note sits beside it. Say (or type) what's wrong — the words show in grey in the note as you talk, and the note waits for you, however long you pause: `⏎` (or *Done*) saves it with the words as they are; `Tab` takes the words into the note so you can fix or add to them with the keyboard (listening stops); typing straight away replaces them; `⇧⏎` starts a new line. Draw straight on the picture: drag for freehand, `⇧`-drag for a box, `⌥`-drag for an ellipse; rest the pointer for half a second at the end of a rough circle, box or line and it straightens out; `⌘Z` (or the undo arrow that shows with the pointer over the note) takes the last stroke back. Finish with `⏎`, *Done*, or a click outside the picture. The marked picture then flies up to the notch as the card (the unmarked one is kept: *Edit Note* opens the strokes again). The place under the note (a project, or *Unassigned* when there is no current project) changes where this snap goes: click it (or press Tab when there are no grey words), type to filter your recent projects, `⏎`; *Unassigned* at the bottom keeps it as a card until you pick a project. When the note is saved the rest of the screen brightens again at once. `Esc` clears what you typed; a second `Esc` discards the snap (*Undo* for 5 s). |
| **Voice note** | `⌥V` | Press once and talk — pauses to think are fine; press `⌥V` again (or *Done* at the notch) to finish, up to 10 minutes. Or hold the keys and let go when you're done. `Esc` cancels in the first 10 seconds (with *Undo*); after that `Esc` belongs to your other apps again. The words show under the notch as you talk. Press `⇧` on its own while it listens (or click *Structured* at the notch) for a structured note, as in dictation. |
| **Copy Text from Screen** | `⌥C` | Drag across any text on the screen (a crosshair, nothing dims) and let go: the text is on the clipboard about 0.2 s later, laid out as it was — lists, tables, code indentation — without the half lines cut off at the edges. With another app in front it is pasted there too, wherever dictation would paste (WeChat included; not into a password field, nor when nothing that takes text has the focus). The notch says *Pasted* only once the text shows in the field; where Blurt can't check that (WeChat), it says *Copied · ⌘V to paste*. The clipboard keeps the text either way. Nothing is saved as a card. Esc or a click without a drag cancels. It uses macOS's own text recognition, so nothing to download; with the AI service key (or a local model) a second read corrects it, and the clipboard is swapped for the corrected text only if you haven't copied something else meanwhile. |
| **Translate Text from Screen** | `⌥T` | The same drag, then the text translated into the language set in *Settings → Copy Text from Screen → ⌥T translates into* (⌥T's own; dictation's ⌘ has its own, since reading usually goes the other way). *Auto* (the default) is your own language ↔ the other one, named in the list (*Auto: 简体中文 ↔ English*, *Auto: English ↔ 日本語*): text in your language goes into the other one, anything else into yours; a language you pick is always what you get — text already in it is copied as it is, and the notch says so (*Already in English · original copied*). Line breaks, lists, code, paths and names are kept. The notch says *Translating…*, then what became of it (*Translation pasted*, *Copied · ⌘V to paste* or *Translation copied*); the whole translation shows in a card under the notch, with *Copy*. The card goes after 10 s (not while the pointer is on it); with the pointer on it, Esc closes it — otherwise Esc stays with the app you're typing in. The translation is on the clipboard and pasted by the same rules as ⌥C. It uses the AI service key when you added one, else this Mac's polish model. |
| **Record** | `⌥R` | Pick an area, a window or the full screen and click *Start recording*; after a 3-second countdown (*Start now* skips it), talk while you use your product. `⌥R` again (or *Finish* at the notch) stops. |

While recording: `⌥P` pause; `⌥A` is the same snap as always — drag an area, say or type the note (its microphone
hears you while the recording does), draw on it, and it hangs as a card — and the recording keeps going, so the
snap is in the video too. The snap belongs to the recording: its picture, note and place go into the recording, and
organizing makes an item of it with your note (its card's menu says *Organized with this recording*; the card leaves
the thread when you finish). Hold `⌃` and drag to draw on the
screen — the same strokes as on a snap: `⌃⇧` for a box, `⌃⌥` for an ellipse (press `⌃` first, then add the other
key: a `⌃⌥` chord pressed all at once stays your window manager's), rest the pointer to straighten a rough
shape (the ink fades after 3 seconds) — `⌥D` keeps the pen on. `⌥M` marks the moment (a still of the recorded area,
counted apart). Dictation is off while recording (the notch says so). The notch shows the state: pause bars and the
time in amber while paused, a pen while the pen stays on (it takes your clicks; `Esc` or a click on *Pen on* turns it
off), and how many snaps you took. Open it for the words: *6 snaps · 4 items spotted* (the items Blurt has heard so
far), then where they go — *Organized into Atlas Web when you finish*. Blurt is recorded like any other app — its
windows, the cards, the note, the pen's ink and the notch — so a recording can show Blurt's own problems; only the
countdown and the red frame are never in it. *Settings → General → Don’t record the notch* leaves the notch out of
your recordings (snaps always show it).

When you finish, the notch says *Organizing into Atlas Web*, with how long that usually takes on your Mac once Blurt
has organized a few recordings (*Usually takes about 4 min*; until then it doesn't guess), and *Change* to pick
another project. Hover the notch to see it working, with the time left. When it's done, the notch says *Organized
into Atlas Web · 5 new* with *Open*. To keep a recording without organizing it — to send the video to someone —
choose *Save Video Only* in the notch's ··· menu (or the menu-bar menu) instead of *Finish*: the video is saved and
shown in the Finder. Blurt never deletes it on its own (*Delete videos automatically* only touches organized
recordings). The app has no button to organize it later; ask the blurt skill in your agent to process that recording.
Use a recording for flows, animations and timing;
use a snap or a voice note for everything that fits in one screen or one sentence.

**When something gets in the way.** A snap or a recording without Screen Recording permission says so at the notch
before you pick an area, with *Open Settings*. After an update macOS sometimes keeps an old build's permission that no
longer works: Blurt then says *Couldn't snap — macOS needs Screen Recording allowed again* and *Re-allow…* shows how to
remove Blurt from the list, add it again and restart it. A voice note you end yourself is kept even in a noisy room,
and is never thrown away without asking: if Blurt heard nothing in it, the notch says *Didn't hear anything* with
*Keep* for 8 seconds (longer while the pointer is on it); not kept, its audio goes to the Trash, never deleted. If no words come out of it, it waits as a card that says *No words recognized* with *Retry* — also with a current project, where it goes once Retry has the words, never as an
empty item. A note whose words couldn't be transcribed says so at the notch with *Retry*, and still goes to its
project once Retry has the words. If the microphone goes away mid-note (AirPods taken out), the note ends with what
you said; before you said anything, a snap's note says *Mic disconnected* and you can type it instead. A recording
that can't be finished says why — *The disk is full*, *Screen Recording was refused*, *The recorded display was
disconnected*, *Sleep or the lock screen stopped the recording*, *Writing the video file failed* — and keeps what it
had: the video up to where it stopped (*The disk is full — the first 3:12 is kept*) and the snaps you took during it,
ready to **Organize**; it stops as soon as the disk fills up instead of running on, and warns before it starts when
little space is left. Most hiccups no longer end a recording at all: if the video file fails partway, Blurt starts a
new one on the spot and puts the pieces back together when you finish (only the few seconds in between are missing,
and the notch says so); if macOS stops the screen capture for a moment (a display was rearranged, the capture
service restarted, the Mac slept or the screen locked), Blurt tries to pick the same screen up again: it waits until
the screen is unlocked and tries a few times. The time in between shows as a still picture. If that doesn't work,
the recording ends and keeps what it had. Stopping the screen sharing from macOS's menu
bar finishes the recording like *Finish*. The exact error behind a failure is kept in the recording's `meta.json`
(`error_domain`, `error_code`, `error_underlying`) and in the log. Quitting Blurt
never loses a capture on its way: it is saved first, or picked up again the next time Blurt starts — and a voice note
you cancelled stays cancelled, even if you quit before its *Undo* was gone.

**Long voice notes.** A voice note no longer ends when you stop to think: it goes on until you press `⌥V` again,
click *Done*, or let go of the keys if you held them (10 minutes at most; the notch shows the time, and the time left
in the last minute). Prefer the old way? *Settings → General → End a voice note when I pause* ends it after 1.5 s of
silence. A snap's spoken note doesn't end on a pause either: it waits for `⏎`, *Done* or `Tab`.

**Structured voice notes.** While a voice note listens, press `⇧` on its own (or click *Structured* at the notch, or
the time in the notch's right ear) to make it a structured note — the same switch as in dictation, any time before you
finish; press it again to go back. The notch shows the list mark next to the time. When the words are in, the polish
model lays out what you listed and keeps only your corrected wording ("milk, eggs — no, duck eggs" becomes duck eggs),
or leaves a paragraph a paragraph; the card's note is that text, and the transcript as heard is kept with the capture
(`said_raw` in its `shots.jsonl`). Without a polish model (*Settings → Dictation*) the note keeps the transcript and
the notch says so. `⌥V` itself and `⇧` with another key (a capital letter, `⇧`-click) never switch it.

**The words while you talk.** While a voice note or a dictation listens, what has been recognized so far shows in a
small dark panel under the notch — the last two or three lines, the newest at the bottom, fading in; a snap's spoken
note fills its own field the same way. When a dictation stops, the panel shows the text that went in from its top (up
to eight lines), so a list keeps its heading while you check it before a double tap sends it. The words keep up with
you even when you don't pause: the part you're still saying shows in a lighter grey and firms up to white as each
stretch is finished — on every Mac for notes, whose speech model is quick. It never takes the focus or a click, moves to the bottom of the screen when it would cover the line you're dictating into, and is never captured in
a recording. Because a voice note is transcribed piece by piece while you talk, its card has its words about as soon
as you stop. Turn it off in *Settings → General → Show text while I talk*.

In the menu-bar menu, hold `⌥` to turn *Start Recording* into *Record the Last Area*. The menu is short: capture
(record, snap, voice note, dictation history), *Open Blurt* and one *Inbox* row with what waits for you, the current
project, Settings and Quit. The countdown, system audio and what happens after a recording are in *Settings → General*.
The menu-bar icon is Peep in monochrome, like the other icons up there. Its beak moves while you dictate, it listens
during a voice note, it looks around while Blurt works, and it hops when something is done. A `blurt://record` or `blurt://snap` link opened from another app
asks at the notch first — one click — unless Blurt itself is in front.

Speech is transcribed on your computer. Nothing leaves it unless you choose a cloud speech service.

### 2. Projects and the current project

A **project** is a folder on your computer, the way an editor opens one: *Open Folder…* (`⌘O`) in the main window, or
drag a folder onto it. Items live inside the folder in `.blurt/`, which Blurt keeps out of git for you.

The **current project** decides where new captures go. You pick it; Blurt never guesses one from the app you're in,
and never moves an item on its own. Press `⌥O` (or click the project name at the notch) and type a few letters of
its name or key to switch; the menu bar's *Current Project ▸* (recently used first), *Settings → General* and the main
window's command palette (`⌘K`) do the same.
- **A project** — every snap and voice note goes straight into it and is processed right away, with a note or
  without one. A recording's items go there too.
- **Unassigned** (no current project) — snaps and voice notes wait as cards (below) until you say where they belong;
  a recording's items go to **Unassigned**.

If you move or rename a project's folder, Blurt doesn't write to the old place: a snap or voice note stays as a card,
a recording goes to **Unassigned**, and the notch says *Can't find billing-api's folder* with **Locate…**. Pick the
folder where it is now and it is the same project again (its items, key and IDs), and new captures go there; a
folder that isn't that project's is refused right in the panel, so you can pick again. The switcher shows such a
project with a question-mark folder and *Folder not found*, and picking it there (or in a snap note's list) asks
where it is.

When a recording ends, the notch says where it went — *Filed to Atlas Web · Change* — and **Change** puts it in
another project (it waits until organizing is done if it has to). A snap filed straight into a project says the same:
*Filed to Atlas Web · AW-14 · Change*. Either way *Moved to … · Undo* takes it back. An item you have already moved
somewhere yourself stays where you put it: Change and Undo only move the ones still where the recording put them.

When something is organized without a project, the agent is told your projects (their names, descriptions, folders and
newest titles) and may **suggest** one per item. It is only a suggestion: in **Unassigned** the item ends with *Looks
like Atlas Web · Move*, one click files it there, and items with the same suggestion are listed together under a line
*Looks like Atlas Web* with **Move All (3)**. `⌘Z` (or the toast's Undo) moves them back, with the IDs they
had — and the suggestion is still there.

In the main window, select items (`⌘`-click, `⇧`-click, `⌘A`) and press **`M`**: a small list opens at the selection —
type to filter, `↩` moves them all, `Esc` closes. You can also drag them onto a project in the sidebar, or use *Move to
Project* in the toolbar, the right-click menu or `⌘K`. Every move has `⌘Z`.

Projects stay in the sidebar in your order: a folder you open goes last, drag a project to move it, and using one
never reorders them — so `⌘5`…`⌘9` always open the same five. Double-click a project (or select it and press Return)
to rename it in place. **Remove from Blurt** happens right away (the folder and its items stay where they are) and
**Undo** brings the project back exactly as it was. The **Project** menu has the same actions for the project on show.

If you move or rename a project's folder, Blurt shows it with a folder and a question mark: *Folder not found*. Nothing
is saved into the old place meanwhile — a snap or voice note meant for it stays a card, a recording goes to
Unassigned, and the notch says so with **Locate…**. Choose where the folder is now and it is the same project again,
with its cards filed there. If the folder you pick is a different project, Blurt says so and changes nothing else.

### 3. Cards

With no current project each snap or voice note becomes a card under the notch, on a thin thread. They tuck away into
the notch when you're not looking (the stack and the number beside the notch count them: on its left, or on its
right while Peep or its news is on the left) and come back when you need them:

- **Rest the pointer on the notch** for a moment (or open it): every card drops down with the notch's details and
  moves with the notch as it opens. Just passing over the notch on the way to a menu drops nothing. They stay while
  the pointer is on the notch, on a card or on its thread, and tuck away a quarter of a second after it leaves; come
  back while they're going up and they turn round.
- **Click the count** beside the notch: the cards come down and stay until you've pointed at them and moved away (if
  you never do, they go back up after 10 seconds), or press `Esc` while the pointer is on them or in the first few
  seconds (an `Esc` meant for another app stays with that app).
- **The Cards panel, `⌥H`**: press **`⌥H`** (*Show Cards*; also the menu bar's *Show Cards* and the notch's cards row)
  for one panel under the notch with two tabs: **Current**, the cards hanging now, and **History**, the cards you
  dragged or pasted into another app in the last 7 days. `⌥H` opens it on Current, or on History when nothing hangs;
  `⌥H` again, `Esc` or a click anywhere outside closes it. It floats over the app you're working in, so you can drag a
  card straight into that app, and it only takes the keyboard when you press `⌥H` or click in it.
  Keys: `Tab` (or `←` `→` while no card is chosen) switches between Current and History; `↓` goes into the cards and
  the arrows move between them (`↑` from the top row goes back to the tabs); `Space` shows the chosen card big (there
  `←` `→` go to the card before or after, `Space` or `Esc` go back); `↩` or `⌘C` copies the card and hands the keyboard
  straight back, so `⌘V` pastes it where you were; `⌫` deletes it (with *Undo*). The notch's cards row lists these
  keys in its tooltip. VoiceOver reads each card as a button.
- In the main window, the Inbox shows **N captures are waiting for a project** while there are cards; click it (or
  **Choose Projects…**) to bring them all down and pick a project for each.

What you can do with a card:

- **Drag a card onto a project** in the notch's list to file it there and start processing. `⌘`-click several cards
  first to move them together: drag any of them, or right-click → *Move N Cards To ▸* (projects recently used first).
- Drag it onto **Unassigned** to file it without a project. **Organize** (in the notch, in a card's right-click menu,
  or *Organize All Cards* in the notch's right-click menu) hands the cards to the agent in one run: into the current
  project when there is one, otherwise into Unassigned with a suggested project for each item (see above).
- **Read it on the card**: a snap shows its note along the bottom of the picture — what you typed first, then what you
  said. The small mic mark means the words were spoken. While your words are still being written down the card says
  *Transcribing…*; if that fails it says *Couldn't transcribe* and the right-click menu has *Retry Transcription*. If
  you started talking and then typed instead (or the mic only heard the room), the recording is dropped: the card
  keeps what you typed and shows no mic.
- **Click to copy**, then `⌘V` anywhere: a snap copies its picture and its note together. Where a paste can take
  both at once — Notes, TextEdit, Mail, Pages — they go in as one, the way copying a picture-and-text message does.
  Chat apps — browsers (DeepSeek, ChatGPT, Claude on the web), Claude, Feishu/Lark, Slack, WeChat, QQ and other apps
  that keep only the picture when a paste has one — get the picture and then the note as a second paste (several
  cards: each picture, then its note), and the notch says *Picture and note pasted*. This works for 2 minutes after
  you click, as long as you haven't copied something else; the card copy is back on the clipboard afterwards, so `⌘V`
  works again. Terminals and the Finder get a normal paste. A voice note copies its words. Right-click for *Copy
  Image* or *Copy Text* on their own. (The copy waits for the double-click interval, so double-clicking to edit a
  note never replaces your clipboard first.)
- **Copy several at once**: `⌘`-click cards to pick them (a coloured ring shows which); each `⌘`-click copies all the
  picked cards as one — pictures and notes in the order they appear (newest first), like `⌘A` `⌘C` over a run of
  messages. A plain click, or the cards tucking away, ends the selection. *Copy All N Cards* in a card's right-click
  menu (or *Copy All N Cards* in the notch's) does it for every card, newest first.
- **Drag it out** into any app: a snap brings its picture (`Screenshot-153012.png`, with your ink if you drew on it)
  and its note — the picture first, then the text:

  | Drop it on | You get |
  | --- | --- |
  | Notes, TextEdit, Mail, Messages, Pages, Keynote | the picture and the note together, in one go |
  | Chrome, Safari and other browsers (DeepSeek, ChatGPT, Claude…), Claude (desktop app), Feishu/Lark, Slack, Notion, other Electron apps, any other app | the picture as an attachment, then Blurt pastes the note into the same message box (needs Accessibility) |
  | WeChat, QQ | the picture in the message box, then Blurt pastes the note after it (needs Accessibility) |
  | VS Code, Cursor, Windsurf, Zed, Xcode, JetBrains IDEs and other code editors | the picture; the note goes on the clipboard (*⌘V to paste the note*) — Blurt never pastes into a code editor by itself, where the cursor may be in your code |
  | Terminal, iTerm2, Ghostty, Warp, kitty, WezTerm, Alacritty | the paths of the picture and of a small Markdown file with the note (`Screenshot-153012-note.md`), so Claude Code or Codex can see the picture and read the note (the note itself is never typed into the shell) |
  | Finder or the Desktop | the picture file |

  The note is pasted into the message box you dropped on: Blurt brings that window forward, puts the cursor after the
  picture, pastes, and puts your clipboard back. It never pastes into Blurt itself, into a password field, or into
  another window. In Feishu/Lark it pastes only when it can tell the cursor is in a text box; when it can't, the note
  goes on the clipboard (*⌘V to paste the note*). *Settings → General → Also attach the note as a .md file* adds the Markdown file for chat apps and
  the Finder too (off by default). The note is also written into the picture's own description (Preview's *Get
  Info* shows it). A voice note is just text you happened to say, so it drops its words, never an audio file. Into
  a chat app — a browser, Claude, Feishu/Lark, Slack, WeChat, QQ — you can let go of it **anywhere in the window**,
  not only on the message box (those apps take dropped text only there): the card shows *Let go to paste into
  Claude* while it's over one, and Blurt then pastes the words into that window's message box (needs Accessibility;
  without it the words go on the clipboard — *Copied — ⌘V to paste into Claude*). Notes, TextEdit, code editors and terminals
  get the normal text drop; a terminal gets the words typed on one line at the prompt, never a Return, so nothing runs.
  A drag you let go of over nothing comes back to its thread. (Drag a voice note before its words are written down and it
  waits a moment for them, or tells you they aren't ready yet.)
- **After a drop**, the card has done its job and leaves its thread — but it isn't thrown away. The notch says what
  went in: *Dragged out · picture and note*, or *… picture and note paths* in a terminal. When the note couldn't be
  pasted after the picture (no Accessibility, *Chat apps: the picture, then the note* turned off, the app didn't come
  forward, or it was the Finder), the note goes on the clipboard instead — *Dragged out · picture · ⌘V to paste the
  note* — so `⌘V` brings the words back; this replaces what was on your clipboard, and *Undo* puts the card back on
  its thread and your clipboard as it was. You can turn this off in *Settings → General → If the note didn't go in
  with a drop, copy it*; the two-step paste itself is *Settings → General → Chat apps: the picture, then the note*.
- **History**: cards you dragged or pasted into another app stay in the Cards panel's *History* tab for 7 days
  (`⌥H`, then `Tab`). Each one is a tile like the cards under the notch: click to copy it (picture and note),
  double-click it, click its eye or press `Space` to see the picture big, drag it into any app again, and right-click
  it (or use *···*) to copy the picture or the note alone, *Put Back Under the Notch* to make it a card again, show it
  in the Finder or delete it. A tile on its last day says so. After 7 days it goes to the Trash.
- Optional: *Settings → General → Add the note under the picture when dragging* drops a copy of the picture with the
  note in a strip under it, for apps that take one picture and nothing else. Off by default; the capture itself stays
  clean.
- Hover a card whose note is cut short to read all of it (a spoken note also shows a play button there).
- Double-click a card to edit its note. *Edit Note…* shows the whole note, the spoken words too, so you can fix what
  was heard wrong; the button before the words plays the voice note (or records one), *Record Again* shows with the
  pointer over the note (it records until you press `Tab` or *Save*, not until you pause), the place under it moves the
  card to a project when you press *Save*, and `Esc` keeps the note as it was. A card waits until you do something
  with it — however long that takes.
- **Delete**: click ×, choose *Delete*, or press `⌫` with the keyboard on it. Nothing asks first: the notch says
  *Deleted · Undo* for 5 seconds, and *Undo* puts the card back where it was. Delete another while it shows and it
  becomes *Deleted 2 cards · Undo*, bringing both back. *Delete All N Cards* (in the notch's right-click menu) works
  the same way, with one *Undo* for all of them.
- The newest five cards sit side by side, newest on the left; the others wait behind a **+N** tile at the end of the
  row (never a *+1* for a card that fits). Click it for the Cards panel on Current, every card at once, newest first:
  click to copy, double-click to edit the note, the eye (or `Space`) to see it big, right-click for the card's menu,
  drag one out into any app or onto a project in the notch, `⌫` to delete. The panel opens below the cards, so a card
  you put back never covers it.
- A snap's card takes its picture's shape: a wide screenshot makes a wider card, and a toolbar or a sidebar shows
  whole instead of as a slice of its middle. A spoken note's mic mark sits before the note's first words. If a note
  couldn't be turned into words, the card says so in amber and keeps the mic mark: right-click it to retry.
- Your very first card says what to do with it: click to copy, or drag it into any app.
- While you record, the cards stay tucked away (they would cover what you're showing); `⌥H` still opens the Cards
  panel.

While Blurt processes captures you see a small egg at the notch; when it hatches, the new items are in your Inbox.

### 4. Review

The main window (`⌥B` → *Open Blurt*) has the **Inbox** at the top of the sidebar, then your projects.

The Inbox holds what needs you, and its header says how much: *3 new · 2 to verify* (the menu bar menu says the
same). Select an item to see everything about it on the right — what you said, the frames, steps, the suspected code —
and edit any field; changes save as you type. Only fields with something in them are shown; **Add field** under them
brings back an empty one. To go through a freshly processed capture quickly, open the capture and use the keyboard: `J`/`K` next and
previous, `A` keep, `X` discard, `Z` undo, `M` merge into the previous item, `G` list view, `?` all shortcuts (`⌘/`
also opens them, from the Help menu).

Editing, the Mac way:
- `M` moves the selected items to a project: type to filter, `↩` to move (see Projects).
- `E` renames the selected item right in the list (Return keeps it, Esc puts the old title back); Return moves into the
  item's details with the cursor at the end of its title. In a field, Esc puts back what was there; Esc again (or `⇧Tab`
  from the first control) goes back to the list.
- In **Steps**, Return starts the next step, Return on an empty step ends the list, `⌃⌘↑`/`⌃⌘↓` move a step.
- The kind, severity and type chips open a menu of their values; `1`–`4` set the kind (issue, idea, note, task) in the
  list and in the details alike.
- **One undo for the whole window**: `⌘Z` / `⇧⌘Z` take back the last step wherever it was made — a state, a move, a
  rename, a field you edited in the details — and the Edit menu says which ("Undo Change Kind", "Undo Edit Title"). It
  takes back only your own step: a state an agent wrote since stays, and a `⌘Z` pressed while Blurt is still saving
  waits for that save.
- `⌫` or `⌘⌫` discards the selected items, as in Finder. Removing a project from Blurt has no key; it's in the
  project's menu.
- **Search, order and filter sit on the list itself.** The search field is right under the list's title (`⌘F` or `/`
  to get there): type, then `↓` or `↩` to go into the results; `Esc` clears the search and puts you back in the list.
  On the title's line, the order button says how the list is sorted — *Updated ↓* is newest first — and opens the sort
  keys (Updated, Title, ID, Kind, State, Project) with *Ascending* and *Descending* (also in *View ▸ Sort By*). The
  funnel button next to it filters by kind and state; while a filter is on it is filled in, with how many filters
  apply, and a line above the list says what it shows, with **Clear**.
- Search finds an item by its ID too (`AW-11`, or an ID it had before it moved), in the search field, `⌘K` and for
  agents (MCP). When the item isn't in the place you're searching (it's discarded, filtered out or in another project),
  the list says where it is, with a button that shows it.
- `↑` on the first item walks up into the banners and running jobs above the list; Return on a banner opens it.
- Each place keeps its own filters: a State filter set in All Items stays there and never empties your Inbox.
- `⌘Q` quits Blurt, as in any Mac app (also from Settings). `⌘W` closes this window and leaves Blurt in the menu bar
  for dictation and capture.
- A task's **Done when** is what the agent is told "done" means; it shows (and can be edited) with the task's details.
  No field an item holds is ever hidden.
- An item file you or a sync tool edited into something Blurt can't read stays in the list, with a small warning mark
  before its title, and its details say *This item's file can't be read* with **Open in Editor** and **Show in
  Finder**. Blurt never overwrites it, and nothing else stops because of it: the other items keep updating, and Blurt
  says once which file needs fixing. Fix it and save; it shows up again. A file whose item changed underneath it (a
  checkout, a sync, a uid edited by hand) simply shows the new item.

### 5. Hand off to an agent

Select one or more items and choose how they get done:

- **Hand Off to Agent** (`⌘↩`) — runs Claude Code or Codex in a terminal inside Blurt, in the project folder. Several
  items can go to one conversation (*Together*) or one each (*In parallel*, each in its own git worktree so they
  don't edit the same files). The session keeps running if you close the window; Blurt tells you when it needs an
  answer or has finished a turn.
- **Copy instruction** — a one-line instruction pointing at a note with everything the agent needs (screenshots
  included). Paste it into the agent you already use. **Copy full text** copies the note itself.
- **Export Hand-off Bundle…** — for a person rather than an agent: one `.zip` with a summary (counts by kind and
  state, then each item with its state, what you said, the steps, suspected code and screenshots), a file per item,
  and the screenshots and clips. It uses relative paths only, so it opens on a teammate's computer. Pick where to
  save it; it is named after the project, the date and the number of items. While it packs, the notch says so; then
  it says where it saved it, with **Show in Finder**. The items keep their state. Paths on your Mac don't go into it:
  a path inside the project becomes relative, any other one keeps only the file name, and a screenshot that is no
  longer on disk is listed as not included. It is in the Item menu, the context menu, the **Hand Off** toolbar menu
  and `⌘K`.

To send items somewhere — a Slack channel, a Feishu group, Linear, GitHub, Notion — ask your agent, for example
"Bundle the checkout issues and post them to #web in Slack". It packs them (the `bundle_items` tool) and sends them
with the tools it already has; Blurt has no connectors of its own. *Settings → Agents → Ask your agent* has a few
more examples.

Agents that have the Blurt MCP installed (Blurt offers it when you set it up) report back on their own: you'll see the item move to
*In progress*, then *To verify*. If a session ends without the agent reporting back (it quit, crashed, or the Mac
restarted), the item stays *In progress* and says *Session ended without the agent reporting back*: **Open Session** to see what
it did, then **Restart Session**, **Mark as Done** or **Take Back**. **Open Session** is also in the Item menu and the
item's context menu.

When a session ends, its terminal shows how it ended rather than the dead window: *Codex couldn't start* with the
agent's last words (an expired login, an error), *Ready to review* when its branch has changes, or *Ended · no
changes*. **Restart Session** runs the same items with the same agent again (once — the button is off while it
starts); **Take Back** returns them to *To do*; **Show Output** shows what the agent left on screen. The item's
banner keeps two buttons and puts the rest under **⋯**. An agent that says nothing for a minute after it starts
reads *No response*: look at its window, or restart it. An agent that isn't signed in can't be picked in the
hand-off panel — it says what to run, and offers the other agent; agents handing work off from the command line get
the same answer.

The panel always works on the items' own project (its default agent, the model you last picked for it), whatever
project is current. What can't be handed off says why before the panel opens, with the way out: a discarded item
(**Restore**), one waiting to be verified or done (**Reopen**), one a session is still working on (**Open Session**).
An item whose last session ended without reporting can simply be handed off again: it is taken back from that session
first. **Take Back** on a session that is over and changed nothing also removes its worktree, its `blurt/…` branch and
its window — nothing is left next to your repo; when it did change something, the worktree stays for **Review
Changes…**. Taking back one item of a session (`R`, the state menu) leaves its other items with it; the clean-up
happens once none is left. Codex asks once to trust Blurt's hooks ("Trust all and continue"); the hook command no longer changes when
Python or Blurt updates, so it doesn't ask again. While an agent waits at one of these first questions (trusting the
folder, trusting the hooks), a line under the session's header says what it asks and what to answer. If you quit at
the trust question instead, the session says it stopped there and nothing was started; **Restart Session** asks again.
An agent too old for Blurt's terminal (Codex before 0.164) is caught before it starts: the Hand Off panel shows the
installed version and the command that updates it, with **Check Again**. Codex's footer shows *Running without the
shared background server* on every hand-off: Blurt passes its hooks with `-c`, which only Codex's embedded mode
accepts. It is harmless.

The conversation's first line is its title, such as *AW-12 · Login button does nothing (Blurt hand-off)*, so you can
find it in the agent's own list of conversations; Codex also gets it as the thread's name.

**Claude desktop.** If the Claude desktop app is installed, the hand-off panel asks where Claude Code runs: **Run in
Blurt's terminal** (recommended) or **Run in Claude desktop**. Blurt remembers the choice for each agent (also in
Settings → Agents). With the desktop app, Blurt still makes the worktree, then opens a new Claude conversation with
the items filled in: confirm the folder and press Send there. Blurt doesn't see that conversation live, so the item
reads *In the Claude desktop app · the agent reports progress*, with **Go to Claude**; the items move when the agent reports
them through the Blurt MCP. If the MCP isn't installed for Claude, the panel offers **Install…**, or you mark the items
yourself: the item then says *no progress comes back here: mark it done when it is*, with **Mark as Done** next to
**Go to Claude**, and the session list reads *In Claude desktop · waiting for you to mark it*. **Review Changes…** and **Merge** work on the worktree as usual. A Claude session already running in Blurt's
terminal can move there with **Continue in Claude Desktop…** in its **⋯** menu (Claude Code 2.1.285 or later, signed
in with a Claude subscription); the agent stops here and live status stops with it. If the Blurt MCP isn't installed
for Claude, the confirmation says so and offers **Install…** first, since the desktop app can't report progress
without it. If the desktop app doesn't take the conversation, **Restart Session** starts a new session on the same
items in Blurt's terminal.

**Review Changes…** shows what changed on the session's branch. **Merge** (`⌘↩`) brings it into your project folder;
when the agent left its work uncommitted (Codex can't commit inside a worktree), the button reads **Commit and
Merge** and Blurt commits it first, as "HS-5 Create done.txt (Blurt hand-off)". A branch with no changes can only be
discarded, never pushed. **Discard** puts the items back in *To do*. `Esc` closes the sheet at any point. While the
agent is still open in its window (a finished turn waits there), the button reads **End Session and Review**: it ends
the agent and shows the changes again, including any it made on the way out, and you merge from there. Merge lands
only what the sheet showed: if the branch changed after you opened it, Blurt asks you to review it again.

Organizing a recording stops when you quit Blurt (Blurt asks first; Return keeps it going), and a recording is never
organized twice at the same time. Running work is listed above the list under *Running*. If organizing fails, it stays
there with **Try Again** and **Dismiss** until you pick one, and it says why in words: which agent, what went wrong
(not signed in, out of quota, no network) and what to do — the step that failed is the one that did (*Prepare* when
the agent couldn't work at all). **Try Again** checks the agents again, so signing in and pressing it just works.
When the first agent in your order can't run, the next one organizes instead: Blurt says so at the notch each time,
and the job keeps it (*Organized by Codex (Claude Code isn't signed in)*). When none can run, it lists each agent of
your order with its own fix.

### 6. Item states

Every item has one state.

```
New ──keep──▶ To do ──hand off──▶ Handed off ──▶ In progress ──▶ To verify ──mark as done──▶ Done
                ▲                      │              │              │
                ├── take back ─────────┴──────────────┘              │
                └── send back ───────────────────────────────────────┘
```

- **New** — just captured; you haven't looked yet. **To do** — you kept it.
- **Handed off** → **In progress** — an agent has it and is working on it.
- **To verify** — the agent says it's finished. Check it: **Mark as done**, or **Send back** if it isn't right.
- **Done** — you confirmed it. **Won't do** — you decided not to (from any state that isn't finished).
  Both can be reopened.
- **Discarded** — the trash; **Restore** puts an item back where it was.

Your Inbox is *New* + *To verify*: marking something *Won't do*, *Done* or *Discarded* takes it out immediately. An
agent can never mark an item done — "fixed" from an agent always means *to verify*.

Click the status ring in front of an item to change its state; the menu only lists the steps that make sense right
now. Keys in the list: `A` keep · `D` mark as done · `R` back (send back, take back, reopen or restore — whichever
fits) · `W` won't do · `X` discard · `S` open the menu. A short note says where the item went, with **Undo**; a key
that doesn't apply says why (a discarded item needs `R` first).

### 7. Dictation (macOS)

Dictation types what you say into **whichever app has the focus**: a chat box, an email, your editor, a terminal.
It is separate from the voice note: `⌥V` keeps what you say in Blurt, and dictation puts it where you're typing.

- **Setting up.** The setup assistant (first launch, again from Settings → General) gets dictation ready in four
  short steps: what Blurt does and its keys; the permissions dictation needs (the microphone and Accessibility, with
  the permission guide below); *Download Recommended Models* — speech recognition, polish and voice notes picked for
  this Mac, one progress bar, carrying on in the background (if it fails, *Small Model Only* gets SenseVoice Small,
  228 MB); and a box to try it in — once a dictation lands, it asks you to try sending with a double tap — with *Open
  Blurt at login* (on, so the key always works). Screen Recording isn't
  asked there: the first snap or recording asks for it. Connecting an agent is in Settings → Agents.
- **Model downloads.** Every model download — the assistant's, *Settings → Models*'s, the dictation key's — goes
  through one queue: one model at a time, never the same one twice. While it runs, the menu-bar menu's first row
  shows it ("Downloading speech models · 2.1 of 6.1 GB", with *Show* and *Stop*) and Settings → Models shows the bar
  on the model's row ("Queued" for the next ones, "Unpacking…" after an archive came down). Quitting or restarting
  Blurt doesn't lose it: the next launch carries on where it stopped. A model that fails to download stops only what
  it was asked for with (its row says so, with *Try Again*); models you asked for elsewhere carry on. Dictation works as soon as its own model is in, even while polish is still
  coming, and that model is loaded at once so the first Fn isn't slow. Without a speech model the Fn key starts
  nothing: the notch says so and offers *Download* (or shows how far the download is) — a key press never starts a
  download by itself.
- **Tap Fn** (🌐, alone), talk, **tap it again**. Or **hold Fn** while you talk and let go to stop: anything held
  longer than about 0.3 s is push-to-talk. The notch's ears show a keyboard and a mint level while it listens, then
  a few dots while it transcribes and polishes. `Esc` cancels — while you talk, and also while the text is still on
  its way (it then never goes in; *Undo* at the notch brings it back for a few seconds, in case that `Esc` was meant
  for another app). Fn used with another key (`Fn`-arrow, `Fn`-F-keys…) never starts a dictation.
  What has been recognized so far shows under the notch while you talk, about a second behind you: the words you're
  still saying in a lighter grey (they can still change, and they don't end in a full stop until you're done), then
  white once that stretch is done. When you stop, that panel shows the text that was actually typed — polished, or
  laid out as a list — from its top (up to eight lines, so a list's heading and first item are there) for about a
  second and a half, a little longer for a longer text, with a small check after it: what a double tap would now
  send. It doesn't slow the paste down. (On Macs with less than 16 GB the grey part is
  left out and the words appear after each pause; `record.dictation.live_partial` true / false overrides that.)
- **When it's slow.** If the text isn't in 3 seconds after you stop (a model still loading), the notch says *Still
  recognizing… Esc to cancel*, or *Still polishing… Esc types it as spoken*: Esc then types what was heard without
  waiting for polish (the history marks it *As spoken*). A speech model that has stopped answering — even one an
  earlier Blurt left behind — is noticed and replaced on the next key press, so you aren't left waiting.
- **The next thought right away.** Tap Fn again as soon as you've stopped (after half a second, so it isn't a double
  tap) and the next dictation starts listening while the last one is still being typed; they go in in the order you
  said them.
- **Only where you were.** The text goes into the app you started in. If you've moved to another app by the time it
  is ready (a long dictation, a model still loading), it is copied instead and the notch says *Copied — paste with
  ⌘V*; a double tap's Return is then not pressed, and the notch says so in the same line: *Copied, not sent · paste
  with ⌘V*.
- **A dictation you forgot.** Hands-free dictation stops by itself at 5 minutes. After 20 seconds without speech the
  notch says *Still listening · Fn to finish · Esc to cancel*; from 4:30 the clock counts down (−0:30) in amber with a
  quiet *30 s left*, and at the limit the notch says the dictation stopped there and types what you said. A tap while
  that line shows doesn't start a new one.
- **No speech model yet.** Fn doesn't listen; the notch says *No speech model yet* with its size and **Download**, which starts it in the download queue above —
  the notch says it started, *Show* shows how far it is — the model you picked in Settings if that's the one
  missing. While it is already coming down, the notch says how far it is instead. A dictation never downloads a
  model by itself. If recognizing a dictation fails anyway, the recording is kept and the notch says so with
  **Retry**; once the model is there, the notch offers Retry for it again. The Dictation page lists it too, with
  Retry. It never says "didn't catch anything" for that. The Dictation page says it too, with **Download** and the
  download's progress, and only says dictation is on once the model is there.
- **Dictating into the middle of a sentence.** Blurt looks at the text on both sides of the cursor and inserts only
  what's new: put the cursor in 「我知道你就是▮的。」, say 「就是从老家回来的」, and you get 「我知道你就是从老家回来的。」 —
  not the repeated 「就是」 or a second full stop. Punctuation and spaces fit the sentence too. It only trims what it
  types, never what's already there, and where the field's text can't be read (WeChat) the words go in as said.
  Dictating after "I think ▮" doesn't start a new sentence: no capital, unless it's a name. In a terminal, a command
  you say stays a command ("git status", no capital, no full stop); a request to an agent stays a sentence.
- **Double-tap Fn to send.** Two quick taps press Return in the app in front. Two ways to use it:
  - **check, then send:** tap to stop, read the text (in the field, or in the panel under the notch), then
    double-tap to send — or fix it first;
  - **send straight away:** tap twice instead of the stop tap: the dictation stops, the text goes in, and then it is
    sent — the Return you'd press yourself in a chat. (With push-to-talk: let go, then double-tap.)

  A double tap that's a little slow (the second tap within 0.8 s, nothing said yet) still sends. Taps while the text
  is still on its way never lose it: a double tap then sends once it is in. The notch's right ear shows a check and
  "Sent" — or, when the Return couldn't be pressed (no Accessibility, a password field, the text was only copied), the
  notch says why not. Return goes as soon as the field shows the text, and your clipboard comes back only after that. For your first few dictations in a chat app, a quiet line after the text reminds you:
  *Double-tap Fn to send*. It works with whichever key you set, never types into Blurt itself or a password field,
  and can be turned off in *Settings → Dictation* (*Double-tap Fn to send (Return)*). A double tap only sends what you
  dictated: with nothing typed into that app in the last minute and nothing on its way, it presses nothing.
- **Sounds.** Peep peeps when the mic is really listening (talk now) and pecks when the take stops; a softer peck when
  Esc cancels it. Silence after a press means nothing started. Voice notes do the same; nothing plays while a screen
  recording runs. *Settings → Dictation* has a switch for each (*Sound when listening starts / stops*).
- **Translate while you talk.** Tap ⌘ (either side) while dictating, or click Peep in the notch: the take is typed
  translated. *Settings → Dictation → ⌘ translates into*: *Auto* (default) — your own language ↔ the other one, named
  in the list (for example *Auto: 简体中文 ↔ English*, or *Auto: English ↔ 日本語* when your Mac is in English with
  Japanese as its next language): what you say in your language goes into the other one, anything else into yours —
  or English, 简体中文, 繁體中文, 日本語, 한국어, Français, Deutsch, Español, Português, Italiano, Русский; what you
  said in that language already goes in as you said it. ⌥T (translate from screen) has its own setting, since reading
  usually goes the other way. The cloud model translates when you have one set up and *Use the cloud model to
  translate* is on (better, about 1 s); otherwise the local polish model.
- **Each app remembers.** Turn on Structured (⇧) or Translate (⌘) in an app and it stays on there until you switch it
  back; after an hour away the notch reminds you as the next take starts. *Settings → Dictation → Remember Structured
  and Translate for each app* turns this off; the apps are listed there with Reset. The apps where dictation is translated are
  listed under *Dictation is translated in these apps*: ⌘ in an app turns translation on and it stays on there, ⌘ again
  turns it off and removes the app; you can also remove one there. With remembering turned off, the notch may suggest
  translating in an app you keep translating in; accepting it says so, with *Undo*.
- **Nothing heard?** The notch names the microphone it listened with — "Didn't catch anything (AirPods)", or "No
  sound from AirPods" when that mic gave only silence (muted, the wrong input, a headset still connecting) — and
  *Change Mic…* opens *Settings → Dictation*'s microphone.
- *Settings → Dictation* (or the setup assistant) switches the key to **right Option** or **either Option key** (left
  or right, still only when tapped alone), and the mode to **tap to start, tap to stop** or **hold to talk** only. If
  you never picked a key before, you now have Fn; a key you chose stays.
- **Fn and macOS.** macOS has its own use for Fn (System Settings → Keyboard → "Press 🌐 key to": emoji, input
  source or system dictation). With Accessibility allowed, Blurt keeps the Fn press to itself so that action doesn't
  run as well (*Keep Fn for dictation*, on by default). If that macOS setting would react to Fn too, Settings →
  Dictation says so, and **Fix…** opens Keyboard settings with a note saying what to change. Blurt never changes it
  for you. If Typeless or Wispr Flow is running, Settings says so: both apps would react to Fn, so quit one or give one
  of them another key. The notch says it too, once a day, after a Fn dictation or when one of them opens — with
  **Use Right Option**, which switches Blurt's key at once.
- **Style** (*Settings → Dictation*) is one choice: **Verbatim** (exactly what the speech model heard, no polish),
  **Light** (the default), **Structured** or **Auto**. The polish model they use, and the speech model, are chosen in
  *Settings → Models → Dictation*: the recommended pair with its total size and one **Download**; Settings →
  Dictation shows which ones are in use, with *Change…*.
- **Polish** (Light) runs a small model on your Mac. It removes fillers (嗯, 那个, um, uh) and stutters,
  and adds punctuation and paragraphs. Everything else you said stays — when you correct yourself ("周三，不对，周四",
  "at two, I mean three"), both versions are typed as you said them; *Structured* (below) is the style that settles on
  the corrected one. A pause to breathe in the
  middle of a sentence doesn't end it: the full stop comes where the sentence does. It doesn't rewrite, summarize,
  translate or answer. When its output looks like any of that, or it takes longer than the time limit (3 s), you
  get the words exactly as spoken. The model comes with *Download Recommended Models* in the setup assistant (or
  download it in Settings → Models); the recommended one depends on your Mac's memory. *Verbatim* types the raw
  transcript.
- **Styles.** By default every app gets *Light*: the tidy-up above, and nothing more. It never turns what you say into
  a list, never drops a correction you made, and never changes your tone. A little of it depends on the app: in chat
  apps (WeChat, Slack, Feishu, Telegram…) the model is asked to keep 吧 / 呢 / 啊 and a one-sentence message gets no
  full stop; in terminals and code editors the text stays on one line. When you *want* it tidier — a list, or just
  the version you settled on:
  - **press ⇧ on its own while you talk** (any time, even halfway through, and also while holding Fn): *Structured*.
    The notch's right ear shows a list mark (the first couple of times a short line also says what it does). When you let go, the same local model goes over the whole dictation once
    more: what you took back or restated goes (in whatever words you did it), and points you counted off or listed
    become a numbered list with the sentence before them as its heading — only when you really enumerated; otherwise
    it stays a paragraph. It never rewrites or summarizes: if its result loses anything, you get the Light text. This
    takes a little longer (about 0.1–0.3 s more on an M-series Mac). Press ⇧ again to go back. **Fn+⇧** starts a
    dictation in Structured. A click on the notch while it listens does the same. Whatever you dictate right after a
    list starts a paragraph of its own;
  - **press ⌘ on its own while you talk** (or click Peep at the notch) to **translate**: what you say is typed in
    the language set in *⌘ translates into* (above). The notch shows a small language tag while it is on (EN, 中, ⇄ for
    Auto…) and the words as you said them; the translation goes in when you stop. It uses the AI service key when you
    added one, else this Mac's polish model; if it can't translate, the original goes in and the notch says so. Press
    ⌘ again to turn it off;
  - **⌥L reformats the last dictation**: Light → Structured → Verbatim (exactly what the speech model heard) → Light,
    with **Undo** at the notch. It replaces the text in the field only while it is exactly as it was typed; if you
    have edited it, your edited text is reformatted and goes to the clipboard instead, and the field stays as you left
    it. Pressed while the text is
    still going in, it waits for it: it's about the dictation you just saw. After a longer dictation that went in as
    prose, the model checks it for a list in the background (the paste never waits for it); if it finds one, the
    notch offers **Make a List** for a few seconds. *Make a List* and *Undo* belong to their dictation: they go when
    you start the next one, so they never change a newer text.
  - Nothing you *say* switches the style: "make a list" or 「帮我列个清单」 is typed like any other words, because it is
    often an instruction meant for an AI agent.
  - *By kind of app* under Style (Settings → Dictation) sets a style per kind of app (Chat, Code and terminals, Mail,
    Notes and documents, Other): the one above, Light, Verbatim, Structured, or Auto (the structured text only when
    the model made it a list). When you keep switching the same way in one app (three times or more), the notch asks
    once whether to make that the app's style; it never changes anything by itself, and what it learned shows (and
    resets) in Settings.
- **Words** (the Dictation page's *Words* tab; Settings → Dictation shows a count and *Manage…*): the names and terms
  you say often — "Claude Code", "tmux", a project's name. The speech model and polish are told these words, so
  "Claude" doesn't come out as "cloud" and "option" isn't cut to "op". They are hints, not rules: nothing you say is
  replaced by a word on the list ("a better video codec" stays a codec). Blurt adds a short built-in list of the
  tools you likely talk about (Claude Code, Codex, Cursor, Typeless, MCP, GitHub, OpenAI, DeepSeek, Qwen…, folded into
  one line) and your projects' names and keys (under their own heading, *From your projects*); remove any you don't
  want. The recommended **speech model** (Qwen3-ASR on Apple silicon) listens for these words directly; with the
  others, polish uses them. The words help with spelling only: they never decide which language a sentence is typed
  in, so 「这个 feature 下周上线」 stays Chinese with English words in it.
- **It learns from your fixes.** For a minute after a dictation, if you correct a word it typed (pool request →
  pull request), Blurt notices — once you're done: it compares what it typed with how the field reads when the
  minute is up, you move on, or you dictate again, never a half-typed word. The second time you make the same fix, or
  at once for a capital letter or a space ("github" → "GitHub"), the word joins your list and the notch says
  *Learned "pull request"* with **Undo**. It learns the word, never a replacement, and never two words run together
  with a comma, and a fix to an ordinary word (your → you're) is grammar, not a word to learn. Suggestions it isn't
  sure about wait in the Words tab for you to add or ignore.
- **Correcting a dictation on the Dictation page.** Select it and press `E` or `Return` (or *Correct*): the text is
  ready to edit with the cursor in it. `⌘Return` saves, `Esc` cancels. The note under it says which words it found
  and offers **Add to Words** (then **Undo**); nothing is added by itself. `⌘Z` puts the old text back and takes away
  the words that correction suggested.
- **The text around the cursor** helps too: when you start talking, Blurt reads about 500 characters before and after
  the cursor (and the window's title) so names are spelled the way the document spells them. With **Keep the audio**
  on (the default) it is kept with that dictation's history entry, for the Dictation Lab and feedback reports, and
  deleted with it; off, it is used for that one dictation and not kept. Password fields are never read. Both this and
  learning can be turned off in Settings.
- **Permissions:** Accessibility lets Blurt paste, read the text around the cursor and hear Fn; Input Monitoring is
  what it uses to hear the other keys; and the microphone, of course. Settings → Dictation says when the key can't be
  heard yet; under Permissions it shows each one (folded to *All allowed* once they are) and when the key was last
  heard while another app was in front. Until it is heard, the menu-bar menu
  starts with *Turn On Dictation…* and the notch reminds you about once a day. Both, and *Turn On…* in Settings, start
  the **permission guide** (below); dictation starts working within a few seconds of the switch, no restart needed.
  Without Accessibility, or when the focus isn't a text field, the text is copied and the notch says so: paste it
  with `⌘V`. Your clipboard is put back after a paste. In a password field nothing is typed or copied: the notch
  says so, with **Copy** if you meant it.
- **The permission guide.** *Set Up Permissions…* (the setup assistant, Settings → Privacy, Settings → Dictation) and
  each permission's *Allow…* do the clicking-around for you, one missing permission at a time: Blurt puts itself in
  the list (macOS may show its own prompt the first time), opens the exact page of System Settings, and a small panel
  next to the System Settings window says what to do — usually just "Turn on Blurt here". If Blurt isn't in the list,
  drag the Blurt icon from the panel into it. The panel follows the window, shows every step's state, and moves on by
  itself as soon as a switch is on; *Skip* leaves one for later. At the end Blurt comes back to the front with a check
  mark: "Done — dictation works in every app now." Screen Recording is asked when a snap or a recording first needs
  it (*Allow…* on the snap's message), and sometimes needs Blurt restarted; the panel and Settings → Privacy have a
  **Restart Blurt** button for that. Blurt never clicks or changes anything in System
  Settings itself.
- **Dictation** is a place in the main window's sidebar, under All Items (also menu bar → *Dictation History…*,
  `⌥⌘D`, or the command palette). It lists every dictation by day: the app it went into, the time, the text, and small
  marks for polished, *Not polished* (polish fell back; the reason on hover) and terms applied. The history has its own
  search field at the top of the list (`⌘F`; `↓` into the results, `Esc` clears it).
  Above the list are today's numbers (dictations, words, roughly the minutes saved) and a link to *Dictation
  Settings…*. Select a dictation to see it on the right: what was typed and what the speech model heard, one at a time
  or side by side, each with its own Copy button. From there you can **turn it into an item** in the current project
  (or Unassigned) or delete it. The detail also shows the app, the length, how it was typed, the style the text is
  actually in, and the speech and polish models by name. A second tab, **Words**, is where your custom words are
  added, filtered and removed (above): paste "Claude, Codex, tmux" to add three at once (a word already there is
  pointed out, not added twice); `Tab` into the words, `←` `→` to move, `⌫` to remove, `Return` or a double-click to
  change the spelling. Removing, adding and ignoring say so at the notch with **Undo** (`⌘Z` too). A dictation that
  wasn't recognized shows as such, with **Retry** while its recording is kept. After ⌥L replaced a text, the detail
  shows the text as it is now, with the first version under it. Keys: `↑` `↓` to move, `E` / `Return` to correct,
  `⌘C` to copy, `⌫` to delete (the notch says so with **Undo**, and `⌘Z` puts it back — with its recording), `⌘F` to
  search. With no dictations yet, the page explains which key to tap and says when dictation is off, can't hear its
  key yet, or has no speech model yet. History is kept for 30 days (Settings → Dictation), checked every day, not only
  when Blurt starts. **Keep the audio** (on by default, its own switch there) keeps each dictation's recording and the
  text around the cursor with its entry for those 30 days; turn it off and the recording is deleted as soon as the
  text is in. A dictation cut short by quitting Blurt is listed as not typed, with **Retry**.
- Dictation is off while a screen recording runs, because the recording is using the microphone. Dictation and the
  voice note never listen at the same time: whichever started first keeps the microphone until it's done.

#### Dictation Lab (developer option)

The lab is hidden until you turn on *Settings → General → Show the Dictation Lab (for developers)*. Then the Dictation
page's tabs are **History**, **Words** and **Lab** (also *Go → Dictation Lab*, `⌥⌘L`). The lab is where you find out why a
dictation came out wrong and keep the evidence. Everything in it stays on this Mac.

- **Record a take**: click the big button (or tap your dictation key while the lab is in front) and talk. Pick the
  microphone next to it, or **Import Audio…** to play a file in as the microphone. Nothing is typed anywhere.
- You see **each stage** side by side with its milliseconds: what the speech model heard for every piece, the stitched
  transcript, the polished text and the text that would have been typed (fitted into the "text around the cursor"
  you can fill in), plus the custom words used, the guard's verdict and anything it put back.
- Write **what you meant** (before or after the take) or the **corrected text**, and the lab shows the difference
  (Chinese by character, English by word) with WER, CER, punctuation and term accuracy. Mark what went wrong with the
  chips (wrong name, Chinese turned into English, punctuation, filler kept, content dropped, made-up words, wrong
  segmentation, start or end cut off, too slow), add a note and a rating, and **Save as Case**. A correction teaches
  the custom words; the lab shows what it learned, with **Undo**.
- **Compare** runs a saved case again through other settings: another speech model, polish off or another polish
  model, no custom words, no context.
- **Read a Script**: the lab shows a sentence, you read it aloud, and its text becomes the reference. Read it again if
  you stumbled (every take is kept; *Keep only this* tidies up), then go to the next one. A built-in script covers
  short and long sentences, chat, code, email and meetings, names, numbers, self-corrections, fillers and spoken lists.
  *Import a Script…* adds your own; *Generate 10 More* writes more in the same style.
- **Run All Cases** runs every saved case through the current pipeline in the background and shows what got better or
  worse, with an overall score and a breakdown by dimension. Agents and CI can run the same check:
  `uv run skills/blurt/scripts/dictation_lab.py run`.
- **Add to Lab** on any dictation in History makes it a case (with its audio if it was kept, else text only). *Keep
  the audio of my next dictations* keeps the audio of the next few real dictations so you can add them.
- **Export…** saves every case as a dataset (`manifest.jsonl` + 16 kHz WAVs) for evaluation or fine-tuning. *Move to
  Trash* deletes a case.

### 8. Settings, storage and privacy

- **Agents** lists the coding agents Blurt uses to organize recordings, snaps and voice notes and to fill in with AI,
  in order: the first that works runs, and the next takes over on a sign-in or quota problem. Under each agent,
  **Recordings** and **Cards** say which model and effort it uses: recordings get the agent's own model at low effort,
  cards (and AI fill-in) the cheapest model; change either there. Untick the ones you don't use. Only a problem that
  stops Blurt shows in red. Each installed agent shows *Skill + MCP* once the blurt skill and MCP are in it; while they
  are missing it offers *Connect…*, which shows what it will change before it does. **Ask your agent** at the bottom
  has three requests to start from (copy one with the button next to it): sending items to a chat, filing them in a
  tracker, fixing one. There is no Export pane any more: your agent sends items with its own tools, and old links to
  it open here.
- **Storage** shows what takes space: recordings and snaps per folder, every model by name with its size (*In use* or
  not), dictation history and audio, and Blurt's own files. A model nothing uses — an older one this version doesn't
  use included — can go to the Trash. Videos are most of the
  space (about 9 MB a minute): *Delete* removes the videos of organized recordings older than 30, 90 or 180 days, or
  all of them, and *Delete videos automatically* does it for you (it asks first if that would delete videos right
  away). It is off by default — Blurt never deletes what you made unless you ask. Only the video goes, to the Trash: items, frames and transcripts stay.
  *Move to Trash* happens at once, like in Finder, with *Undo* in the notch (and ⌘Z); only turning on automatic
  deletion asks first. If something can't come back (the Trash was emptied), the notch says so.
- **Shortcuts** can be changed from the keyboard too: Tab to a field, Space to record, Delete to remove it, ⌘Z to undo
  any change. Blurt refuses keys that belong to every app — ⌘ with any letter or key (⌘C Copy, ⌘Q, ⌘W, ⌘Space), the
  standard ⇧⌘ ones (⇧⌘Z Redo, ⇧⌘Q Log Out, ⇧⌘S…) and ⌃⌘Q, ⌃⌘F, ⌥⌘H, ⌥⌘W, ⌥⌘M — and says why; macOS's own
  shortcuts (⇧⌘3 and the other screenshot keys) are named as macOS's. Other ⇧⌘ keys (⇧⌘1, ⇧⌘2…) are fine. Keys
  another action already has: Blurt asks first, and *Swap* gives that action this one's keys in exchange.
- **Privacy** has the one full list of permissions, Spotlight, and *Never use cloud speech recognition*: with no
  cloud API key set, speech is recognized on your Mac anyway; turn it on to keep it that way after you set one. A
  permission Blurt doesn't need right now (Input Monitoring once Accessibility hears the Fn key) says *Not needed*;
  one you turned off says so, with *System Settings…* (macOS won't ask again).
  Blurt's own data (`~/.blurt`, `~/Blurt`) can only be read by your macOS account. Recordings, snaps and items stay on
  your Mac; when you organise them or hand them off, what's needed goes to the agent you use, under its terms (the
  footer says so while an agent is on).
- **Editing `~/.blurt/config.json` by hand:** a comma left before `}` or `]` is fine. If the file can't be read at
  all, Blurt and its scripts use the defaults (dictation, voice notes and processing keep working), keep a copy as
  `config.json.bad-<time>`, and say so once at launch with *Show File*; changes aren't saved until you fix it (the
  first change you make that can't be saved says so too). Blurt keeps finding its scripts wherever the skill is
  installed.
- **The menu** shows a shortcut next to a row only when it works; one another app or another Blurt holds has none,
  and its tooltip says why. When dictation can't work yet, the menu's first row says why: *Turn On Dictation…*
  (permissions), *Set Up Dictation…* (the speech tools didn't download) or *Download Speech Model…*.
- **Two Blurts at once** (a release and a development build): the first one keeps the shortcuts, and the dictation
  key stays with the one that can hear it (a build macOS hasn't given the permission to never holds it); the other
  takes them over when that one quits.

### 9. Updating

The Mac app updates itself (*Check for Updates…* in the menu and in *Settings → General*). It brings its own copy of
the skill's scripts (in `~/.blurt/skill`, refreshed with every update), and the agents you connected in *Settings →
Agents* use that copy, so they update with it. A skill you installed separately (`npx skills add AGIHunt/blurt`)
updates with that command. A Blurt you built yourself runs the scripts in your checkout and updates with
`uv run skills/blurt/scripts/record.py build`; when the app and those scripts don't speak the same version, the notch
says which one to update, and the menu-bar menu and *Settings → General* keep saying so until they match.

---

## 中文

口喷鸡把你说的、截的、录的整理成事项——问题、想法、笔记、待办——放在你的项目里，再交给写代码的 Agent 去做。
在 Mac 上，它还能把你说的话直接打在光标处（**听写**，按 `Fn`）。这页讲的是在 App 里怎么用；菜单「帮助 → 口喷鸡使用指南」和
「设置 → 通用 → 使用指南」都会打开这一页。下面的快捷键是 macOS 的默认值；Windows 和 Linux 上 `⌥` 是 `Alt`，`⇧` 是 `Shift`。
所有快捷键都能在「设置 → 快捷键」里改。设置（`⌘,`）左边是面板列表，最上面有搜索框：按 `⌘F` 输入想找的设置，中文英文都行
——「开机」「镜像」「hotkey」——点一个结果（或按 `↩`）就跳到那一项。

**第一分钟。** 口喷鸡住在菜单栏里（那只圆圆的小鸡 Peep）。第一次打开会带你开好听写要用的权限（麦克风、辅助功能；你选的按键需要时才有输入监控）；
屏幕录制等你第一次截图或录屏时再开。不用下载模型：macOS 26 上听写直接用系统自带的语音识别；再填一个 AI 服务的 key（可选，润色推荐 DeepSeek，
语音识别推荐阿里云百炼），就会帮你改错字、加标点、认对专有名词。macOS 13–15 没有新的系统识别，设置助手第一步就是填 key。本机模型（更准、能离线）
是可选的下载，下好后自动换上。之后在任意输入框里按 `Fn` 听写，按 `⌥A` 截图，按 `⌥C` 截图取字。
屏幕顶部的刘海有事要说时只说一句短话——启动时最多一句。它说的总是你刚做的事
（关于同一件事的新话会直接替换旧的）；带「撤销」的话至少停留 5 秒，鼠标指着时一直等着。点这句话会打开刘海，只有点它的按钮才会撤销。主窗口的提示（「已移到…」「已完成 · 撤销」）也在这里，提示消失后在主窗口按 `⌘Z` 照样能撤销。

### 1. 截图、语音备注和录屏

屏幕顶部的**刘海**是截图、语音备注和录屏的入口（没有刘海的屏幕、Windows 和 Linux 上，同一位置是一个小胶囊）。鼠标移上去，能看到当前项目和这几种方式。

| | 快捷键 | 做什么 |
|---|---|---|
| **截图** | `⌥A` | 框一块区域，松手：画面就停在原处（屏幕其余部分变暗），备注出现在它旁边。说出来（或者打字）哪里不对——说的时候，识别出的文字用灰色显示在备注里；停下来想多久都行，备注会等你：按 `⏎`（或点「完成」）保存，灰字原样采用；按 `Tab` 采用识别结果，文字变黑，可以接着用键盘改或补充（不再收音）；直接打字就替换掉灰字；`⇧⏎` 换行。直接在画面上画：拖动是自由画，`⇧` 拖动画方框，`⌥` 拖动画椭圆；画完一个歪歪的圈、框或线，停住半秒，它会变规整；`⌘Z` 撤销上一笔。按 `⏎`、点「完成」或点画面外面结束。画好的图随后飞到刘海，变成卡片（原图也保留：「编辑备注」能再改这些笔画）。备注保存后，屏幕其余部分马上恢复亮度。备注下面的项目（没有当前项目时是「未归类」）可以改这张截图去哪：点它（没有灰字时也可以按 Tab），打字筛选最近的项目，按 `⏎`；最下面的「未归类」会让它先作为卡片留在刘海下方，等你选项目。按 `Esc` 先清掉打的字，再按一次丢弃这张截图（5 秒内可以撤销）。 |
| **语音备注** | `⌥V` | 按一下开始说，中途停下来想一想也没关系；再按一次 `⌥V`（或点刘海上的「完成」）结束，最长 10 分钟。也可以按住说、松开结束。开始后 10 秒内按 `Esc` 取消（可以撤销）；过了 10 秒，`Esc` 还给别的 App。说的时候，识别出的文字显示在刘海下方。 |
| **截图取字** | `⌥C` | 在屏幕上拖过任何文字（十字光标，屏幕不变暗），松手：大约 0.2 秒后文字就在剪贴板里，版面照原样——列表、表格、代码缩进都在，边缘被截掉的半行不会混进来。前台是别的 App 时同时粘贴进去，听写能粘贴的地方都行（包括微信；密码框、没有可输入的焦点时不粘贴）。确认输入框里出现了这段文字，刘海才说「已粘贴」；确认不了（比如微信）就说「已复制 · ⌘V 粘贴」。文字总会留在剪贴板里。不存成卡片。按 `Esc` 或只点不拖就取消。用的是 macOS 自带的文字识别，不用下载；有 AI 服务 Key（或本机模型）时会再读一遍做修正，只有在你这期间没复制别的东西时，剪贴板才换成修正后的版本。 |
| **截图翻译** | `⌥T` | 同样拖选，识别后翻译成「设置 → 截图取字 → ⌥T 翻译成」里选的语言（⌥T 自己的设置；听写的 ⌘ 翻译另有设置，因为读和写的方向通常相反）。默认「自动」是你的语言 ↔ 另一种，列表里会写出这一对（「自动：简体中文 ↔ English」）：你的语言译成另一种，其他语言译成你的语言；选了某种语言就总是得到这种语言，已经是这种语言的文字原样复制，刘海上会说（「已是英语 · 原文已复制」）。换行、列表、代码、路径和名字都保留。刘海上先显示「正在翻译…」，再说结果（「已粘贴译文」「已复制 · ⌘V 粘贴」或「已复制译文」）；完整译文显示在刘海下面的小卡片里，带「复制」按钮。卡片 10 秒后自己收起（指针在上面时不收）；指针在卡片上时按 Esc 关闭，否则 Esc 照常留给你正在用的 App。译文在剪贴板里，按和 ⌥C 一样的规则粘贴。加了 AI 服务 Key 就用它，否则用这台 Mac 的润色模型。 |
| **录屏** | `⌥R` | 选区域、窗口或全屏，一边用产品一边说。再按 `⌥R`（或刘海上的「完成」）结束。 |

录屏时：`⌥P` 暂停；`⌥A` 和平时的截图一样——框选区域，说或打备注（录屏在收音的同时，备注也能听到你说话），在图上画，然后挂成一张卡片——录屏不会暂停，截图的过程也录在视频里。这张截图属于这段录屏：图、备注和去处都存进录屏里，整理时会按你的备注生成一个事项（卡片菜单里写着「随这段录屏一起整理」，点完成后卡片会收起）。按住 `⌃` 拖动在屏幕上画——和截图上的画法一样：`⌃⇧` 方框，`⌃⌥` 椭圆（先按 `⌃` 再加另一个键；同时按下的 `⌃⌥` 留给窗口管理工具），停住半秒把歪的形状变规整（笔迹 3 秒后消失）；`⌥D` 让画笔常开。`⌥M` 标记这一刻（截下录制区域的画面，单独计数）。录屏时不能听写，刘海上会说明。
刘海会显示当前状态：暂停时是琥珀色的暂停符号和时间；画笔常开时显示一支笔（这时点击会被画笔接走，按 `Esc` 或点「画笔已开」关掉）；截了几张图。展开刘海能看到文字说明：「截图 6 张 · 已识别 4 个事项」（到目前为止听出来的事项），下面一行是去处——「点完成后整理到 Atlas Web」。
口喷鸡自己也会像别的 App 一样被录进去——它的窗口、卡片、备注框、画笔笔迹和刘海——所以可以用录屏来反馈口喷鸡自己的问题；只有倒计时和红色边框永远不会录进去。不想录到刘海，就打开「设置 → 通用 → 录屏时不录刘海」（截图总会带上刘海）。

点完成后，刘海会说「正在整理到 Atlas Web」；口喷鸡在这台 Mac 上整理过几段录屏之后，还会说通常要多久（「通常约 4 分钟」；在那之前不瞎猜），旁边的「更改」可以换项目。鼠标移到刘海上能看到进度和剩余时间。整理好后，刘海会说「已整理到 Atlas Web · 5 条新的」，点「打开」。只想留下视频、不整理（比如要把视频发给别人）：在刘海的 ··· 菜单（或菜单栏菜单）里选「只保存视频」代替「完成」，视频会保存并在访达中显示。口喷鸡不会自己删它（「自动删除视频」只处理已经整理过的录屏）。App 里暂时没有「之后再整理」的按钮；需要的话，让你的 agent 里的 blurt 技能处理这段录屏。
操作流程、动画、时序问题用录屏；一个画面、一句话能说清的，用截图或语音备注。

**出了状况时。** 没有「屏幕录制」权限时，截图和录屏会在选区域之前就在刘海上说明，点「去设置」。更新之后，macOS 有时还留着旧版本的授权、实际已经用不了：这时会提示「截不了图：需要重新授权屏幕录制」，点「重新授权…」会告诉你在列表里删掉口喷鸡、再加回来，然后重新打开口喷鸡。你自己结束的语音备注，就算环境吵也会留下，也不会不打招呼就删掉：要是什么也没听到，刘海上会提示「没听到声音」，8 秒内（鼠标停在上面时更久）可以点「留下」，没留下的录音会放进废纸篓，不会直接删掉；要是没识别出文字，会先作为卡片留着，写着「没识别出文字」，可以「重试」——有当前项目时也一样，重试拿到文字后才归进项目，不会放进去一条空事项。备注没能转成文字时，刘海上会提示并给「重试」，重试拿到文字后照样归到原来的项目。说着说着麦克风断开了（比如摘下 AirPods），备注会带着已说的部分结束；还没开口就断开的话，截图的备注会提示「麦克风断开了」，可以改成打字。录屏没能录完时会说明原因（比如「磁盘满了」「屏幕录制被拒绝」），并留下已有的内容：停下之前录到的那段视频（「磁盘满了，前 3:12 已保留」）和录屏期间截的图，可以直接「整理」；磁盘一满就马上停下，不会空跑到你点「完成」；开始前磁盘空间不多时也会先提醒。退出口喷鸡不会丢掉还在处理的截图或语音备注：要么先存好，要么下次打开时接着处理；已经取消的语音备注，就算在「撤销」消失前退出，也不会再回来。

**长语音备注。** 语音备注不再因为你停下来思考就结束：再按一次 `⌥V`、点「完成」，或者按住说话时松开，才会结束（最长 10 分钟；刘海上显示已录时长，最后一分钟显示剩余时间）。想要以前那样？打开「设置 → 通用 → 停顿时结束语音备注」，安静 1.5 秒就结束。截图时说的备注也不会因为停顿结束：它等你按 `⏎`、点「完成」或按 `Tab`。

**边说边显示文字。** 语音备注或听写在听的时候，已经识别出的文字会显示在刘海下方的深色小面板里：最后两三行，最新的在最下面，淡入；截图时说的备注也一样，文字直接出现在备注框里。听写停下后，面板从头显示打进去的文字（最多八行），清单的标题也在，方便按两下发送前看一眼。即使一直不停顿，文字也会跟上：还在说的那一段用浅一点的灰色显示，这一段说完后变成白色。备注用的语音模型很快，所以每台 Mac 上都这样。它不会抢焦点、不接收点击；如果会挡住你正在听写的那一行，就挪到屏幕底部；也不会被录进屏幕录制。语音备注是边说边分段转写的，所以一停下来，卡片上的文字几乎马上就有了。不需要的话，在「设置 → 通用 → 边说边显示文字」里关掉。

菜单栏菜单里按住 `⌥`，「开始录屏」会变成「录上次的区域」。菜单很短：截图、录屏、语音备注、听写历史，「打开口喷鸡」和一行「待处理」（有几条等你看），当前项目，设置和退出。倒计时、是否录系统声音、录完之后做什么，都在「设置 → 通用」里。菜单栏图标是单色的 Peep，和菜单栏里其他图标一致：听写时它的嘴跟着你说话动，语音备注时它在听，口喷鸡干活时它四处看，有事做完时它会跳一下。从别的 App 打开的 `blurt://record` 或 `blurt://snap` 链接，会先在刘海里问一句、点一下才开始，除非口喷鸡自己就在最前面。

语音在你的电脑上转写。除非你选了云端语音服务，内容不会离开这台电脑。

### 2. 项目和当前项目

**项目**就是你电脑上的一个文件夹，跟编辑器打开文件夹一样：在主窗口里「打开文件夹…」（`⌘O`），或者把文件夹拖进来。
事项存在这个文件夹的 `.blurt/` 里，口喷鸡会自动让它不进 git。

**当前项目**决定新的截图、语音备注和录屏去哪。由你来选：口喷鸡不会按你正在用的 App 去猜，也不会自己移动事项。按
`⌥O`（或点刘海上的项目名），打几个字母（项目名或代号）就能切换；菜单栏的「当前项目 ▸」（最近用过的在前）、「设置 →
通用」和主窗口的命令面板（`⌘K`）也一样。
- **某个项目**：截图和语音备注直接进这个项目，有没有备注都一样，马上开始整理。录屏的事项也进这里。
- **未归类**（不选当前项目）：截图和语音备注先作为卡片留在刘海下方（见下），等你决定放哪；录屏的事项进「**未归类**」。

如果你移动了项目文件夹或改了名，口喷鸡不会往原来的位置写：截图和语音备注先留作卡片，录屏进「**未归类**」，刘海上会提示「找不到「billing-api」的文件夹」和「**找到它…**」。选一下它现在的位置，就还是原来那个项目（事项、代号和编号都在），之后的内容也会归到这里；选错了文件夹，面板里会直接说「这不是「billing-api」的文件夹」，可以重选。切换项目的列表里，这样的项目显示成带问号的文件夹，写着「文件夹不见了」，在那里（或截图备注的列表里）选它，会问你它现在在哪。

录屏结束时，刘海上会写明它去了哪——「已归到 Atlas Web · 更改」——点「**更改**」就能换个项目（还在整理的话，整理完再移过去）。
直接归进项目的截图也一样：「已归到 Atlas Web · AW-14 · 更改」。换了之后会提示「已移到 … · 撤销」，点撤销就移回来。
你自己已经挪走的事项留在你放的地方：「更改」和「撤销」只移动还在原处的那些。

没选项目的内容整理时，Agent 会拿到你的项目列表（名字、描述、文件夹和最近几条的标题），可以给每一条**建议**一个项目。
这只是建议：在「**未归类**」里，这一条后面会写「可能属于 Atlas Web · 移过去」，点一下就移过去；建议同一个项目的事项排在一起，
上方有一行「可能属于 Atlas Web」和「**全部移过去（3）**」。`⌘Z`（或提示里的「撤销」）能移回去，编号回到原来的，建议也还在。

在主窗口里选中事项（`⌘` 点、`⇧` 点、`⌘A`）后按 **`M`**：在选中的地方弹出一个小列表，打字筛选，`↩` 全部移过去，`Esc` 关闭。
也可以拖到侧栏的项目上，或者用工具栏、右键菜单、`⌘K` 里的「移到项目」。每次移动都能 `⌘Z`。

侧栏里的项目按你的顺序排：新打开的文件夹排在最后，拖动项目就能调整，用哪个都不会改变顺序——所以 `⌘5`…`⌘9` 永远对应同样的五个项目。
双击项目（或选中后按回车）可以直接改名。「**从口喷鸡移除**」立刻生效（文件夹和事项都不动），「**撤销**」会把项目原样放回来。
「**项目**」菜单里是同样的操作，作用于当前打开的项目。

项目的文件夹被移走或改了名，口喷鸡会在它旁边显示带问号的文件夹：「文件夹不见了」。这期间不会往旧位置存任何东西：要放进去的截图、语音备注先留成卡片，录屏放进「未归类」，刘海上会说明，并给出「**找到它…**」。选出文件夹现在的位置，它就还是原来的项目，卡片也会放进去。选的如果是另一个项目的文件夹，口喷鸡会说明，其他什么都不变。

### 3. 卡片

没选当前项目时，每张截图、每段语音备注都会变成一张卡片，用一根细线垂在刘海下方。你不看的时候它们会收进刘海（刘海旁边的卡片图标和数字就是有几张：平时在左边，Peep 或它的消息占着左边时在右边），需要时再放下来：

- **鼠标在刘海上停一下**（或者打开刘海）：所有卡片跟着刘海的详情一起垂下来，刘海展开时跟着刘海一起往下走。只是路过刘海去点菜单，卡片不会掉下来。鼠标在刘海上、卡片上或卡片的线上时一直显示，离开后很快收起；收到一半时鼠标回来，卡片就原地停下、重新垂下。
- **点刘海旁边的卡片数字**：卡片放下来并一直显示，直到你把鼠标移过来再移走（一直没移过来的话，10 秒后收起），或者鼠标在卡片上、或刚放下来的几秒内按 `Esc`（给别的 App 的 `Esc` 不会被拦下）。
- **卡片面板，`⌥H`**：按 **`⌥H`**（「显示卡片」；菜单栏的「显示卡片」和刘海里的卡片那一行也一样）会在刘海下方打开一个面板，分两栏：**当前**是现在挂在刘海下的卡片，**历史**是最近 7 天拖进或粘贴到别的 App 的卡片。`⌥H` 打开时在「当前」，没有卡片挂着时直接在「历史」；再按 `⌥H`、按 `Esc` 或在面板外随便点一下就关上。它浮在你正在用的 App 上面，卡片可以直接拖进那个 App；只有按 `⌥H` 或点进面板时它才拿走键盘。
  按键：`Tab`（没选中卡片时也可以用 `←` `→`）在「当前」和「历史」之间切换；`↓` 进到卡片里，方向键在卡片之间移动（在第一排按 `↑` 回到上面的两栏）；`Space` 放大看选中的卡片（放大时 `←` `→` 看前一张、后一张，`Space` 或 `Esc` 回去）；`↩` 或 `⌘C` 复制这张卡片，并马上把键盘还给原来的 App，接着按 `⌘V` 就能粘贴；`⌫` 删除（可以撤销）。刘海里卡片那一行的提示里写着这些按键。旁白（VoiceOver）会把每张卡片读成一个按钮。
- 主窗口「待处理」的顶部会显示「**N 条新记下的内容还没选项目**」，点一下（或点「**选项目…**」）就把它们全部放下来，逐条选项目。

卡片能做的事：

- **把卡片拖到刘海上列出的某个项目**：归到那个项目，开始整理。先按住 `⌘` 点选几张，就能一起移：拖其中任意一张，或者右键 →「把 N 张卡片移到 ▸」（最近用过的项目在前）。
- 拖到「**未归类**」：先存着，稍后再选项目。「**整理**」（刘海上的按钮、卡片右键菜单，或刘海右键菜单里的「整理全部卡片」）把卡片一次交给 Agent：有当前项目就整理进这个项目，没有就整理进「未归类」，每一条附上建议的项目（见上）。
- **单击复制**，然后在任何地方 `⌘V`：截图会把图片和备注一起复制。备忘录、文本编辑、邮件、Pages 这类一次就能连图带字收下的 App，直接一起贴进去，就像复制一条图文消息。聊天 App——浏览器（网页版 DeepSeek、ChatGPT、Claude）、Claude、飞书/Lark、Slack、微信、QQ，以及其他粘贴里只要有图片就只收图片的 App——会先贴图片，再把备注作为第二次粘贴贴上（多张卡片就一张图一段备注依次贴），刘海上显示「图片和备注已粘贴」。点卡片后的 2 分钟内有效，前提是你没有再复制别的；贴完剪贴板里还是这份卡片，可以再按 `⌘V`。终端和访达拿到的是普通的粘贴。语音卡片复制说的话。右键可以单独「复制图片」或「复制文字」。（单击后会等一个双击的间隔再复制，所以双击改备注不会先把你的剪贴板换掉。）
- **一次复制好几张**：按住 `⌘` 点卡片来选（选中的有一圈彩色边框），每次 `⌘` 点都会把选中的卡片作为一份内容复制好——图片和备注按显示的顺序排（最新的在前），就像对一串消息 `⌘A` `⌘C`。普通单击或者卡片收起来，选择就结束。卡片右键菜单里的「复制全部 N 张卡片」（或者刘海的右键菜单里「复制全部 N 张卡片」）一次复制所有卡片，最新的在前。
- **拖到别的 App 里**：截图拖出去是图片（`截图-153012.png`，画过就带笔迹）连同备注——先图片，后文字：

  | 拖到 | 得到 |
  | --- | --- |
  | 备忘录、文本编辑、邮件、信息、Pages、Keynote | 图片和备注，一次一起进去 |
  | Chrome、Safari 等浏览器（DeepSeek、ChatGPT、Claude…）、Claude（桌面版）、飞书/Lark、Slack、Notion、其他 Electron App、其他 App | 图片作为附件放进去，然后口喷鸡把备注贴进同一个输入框（需要「辅助功能」权限） |
  | 微信、QQ | 图片放进输入框，然后口喷鸡把备注贴在图片后面（需要「辅助功能」权限） |
  | VS Code、Cursor、Windsurf、Zed、Xcode、JetBrains 系 IDE 等代码编辑器 | 图片；备注放进剪贴板（「⌘V 可粘贴」）——口喷鸡不会自己往代码编辑器里粘贴，光标可能正停在你的代码里 |
  | 终端、iTerm2、Ghostty、Warp、kitty、WezTerm、Alacritty | 图片和一个写着备注的 Markdown 小文件（`截图-153012-备注.md`）的路径，Claude Code、Codex 能看到图片、读到备注（备注文字本身不会打进命令行） |
  | 访达或桌面 | 图片文件 |

  备注会贴进你拖进去的那个输入框：口喷鸡把那个窗口带到前面，把光标放到图片后面，粘贴，再把你的剪贴板还原。它不会贴进口喷鸡自己、密码框或者别的窗口。在飞书/Lark 里，只有确认光标在输入框里才会贴；确认不了时，备注放进剪贴板（「⌘V 可粘贴」）。「设置 → 通用 → 同时附上备注的 .md 文件」可以让聊天 App和访达也收到这个 Markdown 文件（默认关闭）。备注也写进了图片自带的描述里（预览的「显示简介」能看到）。语音备注本来就是说出来的文字，所以拖出去只有文字，不会是音频文件。拖进聊天 App——浏览器、Claude、飞书/Lark、Slack、微信、QQ——时，**窗口里任何地方都能松手**，不必正好对准输入框（这些 App 只在输入框上接收拖进来的文字）：卡片移到这类窗口上时会显示「松手粘贴到 Claude」，松手后口喷鸡把文字贴进那个窗口的输入框（需要「辅助功能」权限；没有的话文字放进剪贴板——「已复制，在 Claude 里按 ⌘V 粘贴」）。备忘录、文本编辑、代码编辑器和终端照常接收拖进来的文字；终端里是在提示符处打出一行文字，不会带回车，所以什么命令都不会执行。拖到空白处松手，卡片会回到线上。（语音备注还没转成文字时拖它，会稍等一下；还没好就提示你稍后再拖。）
- **拖进去以后**：卡片用完了，会从线上离开，但不会被扔掉。刘海上会说放进去了什么：「已拖走 · 图片和备注」，终端里是「已拖走 · 图片和备注的路径」。备注没能贴在图片后面时（没有「辅助功能」权限、关掉了「聊天 App：先放图片，再贴备注」、App 没到前台，或者拖进了访达），备注会改放进剪贴板——「已拖走 · 图片 · 备注已复制，⌘V 可粘贴」——在那里按 `⌘V` 就行；这会替换剪贴板里原来的内容，点「撤销」会把卡片放回线上，剪贴板也还原。不想要这一步，可以在「设置 → 通用 → 拖进去后备注没贴上时，复制到剪贴板」里关掉；两步粘贴本身在「设置 → 通用 → 聊天 App：先放图片，再贴备注」。
- **历史**：拖进或粘贴到别的 App 的卡片，会在卡片面板的「历史」里保留 7 天（按 `⌥H`，再按 `Tab`）。每张都和刘海下的卡片一样大：点一下复制（图片和备注一起），双击、点眼睛图标或按 `Space` 放大看图，再拖进任意 App 就能再用一次；右键（或「···」）可以单独复制图片或备注、「放回刘海下方」让它重新成为卡片、在访达中显示，或者删除。最后一天时卡片上会写出来。7 天后移到废纸篓。
- 可选：「设置 → 通用 → 拖出图片时把备注印在图片下方」，拖出去的是一份在下方加了备注条的图片副本，给只收一张图片的 App 用。默认关闭；原来的截图不变。
- 卡片上备注显示不全时，悬停可以看全文（语音备注那里还有播放按钮）。
- 双击卡片改备注。「编辑备注…」显示完整的备注，说的话也在里面，识别错了可以直接改；点麦克风可以重录（停下来不会结束，按 `Tab` 或「保存」才结束），按 `Esc` 备注保持原样。卡片会一直留着，直到你处理它，放多久都不会自己消失。
- **删除**：点 ×、右键「删除」，或者键盘在卡片上时按 `⌫`。不会先问你：刘海上显示「已删除 · 撤销」5 秒，点「撤销」卡片就回到原处。这时再删一张，会变成「已删除 2 张卡片 · 撤销」，两张一起回来。刘海的右键菜单里的「删除全部 N 张卡片」也一样，一次「撤销」全部回来。
- 最新的 5 张并排显示，最新的在最左边；其余的在这一排末尾的「+N」后面等着（放得下的那一张不会藏在「+1」后面）。点「+N」会打开卡片面板的「当前」，一次看到所有卡片（最新的在前）：单击复制，双击改备注，点眼睛图标（或按 `Space`）放大看，右键是卡片的菜单，拖到任意 App 或刘海上的项目，`⌫` 删除。面板开在卡片下方，放回去的卡片不会挡住它。
- 截图卡片跟着图片的形状走：宽屏截图对应一张更宽的卡片，工具栏、侧边栏这种很宽或很高的图会完整显示，不会只露出中间一截。说过备注的卡片，话筒标记在备注第一行的开头。备注没能转成文字时，卡片会用琥珀色写明，并保留话筒标记：右键卡片可以重试。
- 第一张卡片出现时，它会提示一句怎么用：点一下复制，或拖进任意 App。
- 录屏时卡片收着不放下来（免得挡住你要演示的东西），按 `⌥H` 仍然可以打开卡片面板。

整理时刘海上会出现一个小蛋；蛋破壳了，新事项就出现在「待处理」里。

### 4. 审核

主窗口（`⌥B` →「打开口喷鸡」）侧栏最上面是**待处理**，下面是你的项目。

「待处理」里是需要你看的，标题下面直接写着有多少：「3 条新的 · 2 条待验证」（菜单栏菜单里也是这么写）。选中一条，右边是它的全部内容——
原话、截图、步骤、可能相关的代码——每个字段都能改，边打边保存。只显示有内容的字段；空的字段在下面的「**添加字段**」里，选一个就加回来。刚整理好的一次录屏或一批截图想快速过一遍，就打开它，用键盘：`J` / `K` 下一条 / 上一条，
`A` 要做，`X` 丢弃，`Z` 撤销，`M` 并进上一条，`G` 列表视图，`?` 查看全部快捷键（「帮助」菜单里的 `⌘/` 也行）。

按 Mac 的习惯编辑：
- `M` 把选中的事项移到项目：打字筛选，`↩` 移过去（见「项目和当前项目」）。
- `E` 直接在列表里改标题（回车保存，Esc 恢复原标题）；回车进入右边的详情，光标停在标题末尾。在字段里按 Esc 恢复原来的内容，再按一次（或在第一个控件上按 `⇧Tab`）回到列表。
- 在「**复现步骤**」里，回车开始下一步，在空的一步上回车结束列表，`⌃⌘↑` / `⌃⌘↓` 移动一步。
- 种类、严重程度、类型这几个标签点开是选项菜单；`1`–`4` 设种类（问题、想法、笔记、待办），列表和详情里一样。
- **整个窗口一个撤销**：`⌘Z` / `⇧⌘Z` 撤销或重做最近一步，不管是在哪做的——改状态、移动、改标题、在详情里改的字段——「编辑」菜单会写明是哪一步（「撤销改种类」「撤销编辑标题」）。它只撤销你自己的这一步：Agent 之后写的状态不受影响；口喷鸡还在保存时按下的 `⌘Z` 会等保存完再执行。
- `⌫` 或 `⌘⌫` 丢弃选中的事项，和访达一样。把项目从口喷鸡移除没有快捷键，在项目的菜单里。
- **搜索、排序和筛选都在列表上。**搜索框就在列表标题下面（`⌘F` 或 `/` 跳过去）：输入后按 `↓` 或 `↩` 进入结果，`Esc` 清空搜索并回到列表。标题这一行的排序按钮写着列表现在怎么排——「更新时间 ↓」就是最新的在前——点开可以选按更新时间、标题、编号、种类、状态、项目排，以及升序、降序（「显示 ▸ 排序方式」里也有）。旁边的筛选按钮按种类和状态筛选；筛选打开时按钮变成实心并标出几项筛选，列表上方还有一行说明在看什么，带「**清除**」。
- 搜索也能按编号找事项（`AW-11`，或者它移走之前的编号），搜索框、`⌘K` 和 Agent（MCP）都一样。事项不在当前位置时（已丢弃、被筛选隐藏或在别的项目里），列表会说明它在哪，并有按钮直接显示它。
- 在第一条上按 `↑` 会走到列表上方的横幅和正在运行的任务；在横幅上按回车会打开它。
- 每个位置有自己的筛选：在「全部事项」里设的状态筛选只留在那里，不会把「待处理」筛空。
- `⌘Q` 退出口喷鸡，和其他 Mac App 一样（在设置窗口里也是）。`⌘W` 只关掉这个窗口，口喷鸡留在菜单栏里，听写和截图照常能用。
- 待办的「**完成标准**」就是交给 Agent 时说的「做到什么算完成」，和待办的详情放在一起，能看也能改。事项里存着的字段一个都不会藏起来。
- 你或同步工具把事项文件改成了口喷鸡读不懂的样子，它还留在列表里，标题前有个小警示标记，详情写着「这一条的文件读不出来」，带
  「**在编辑器中打开**」和「**在访达中显示**」。口喷鸡不会覆盖它，也不会因为它停下别的：其他事项照常更新，口喷鸡只提醒一次是哪个文件要改。
  改好保存，它就回来了。同一个文件换成了另一条（切分支、同步、手改了 uid），列表里显示的就是新的那条。

### 5. 交给 Agent

选中一条或几条，选一种交法：

- **交给 Agent**（`⌘↩`）：在口喷鸡内置的终端里、在项目文件夹中运行 Claude Code 或 Codex。几条可以放进一个对话（**一起处理**），
  也可以每条一个（**并行**，各自在独立的 git worktree 里，互不改到同一个文件）。关掉窗口会话也继续跑；需要你回答、或者一轮做完了，口喷鸡会提醒你。
- **复制指令**：一句话的指令，指向一份交接说明，Agent 需要的东西（包括截图）都在里面。粘贴给你平时用的 Agent 就行。「**复制全文**」复制的是交接说明本身。
- **导出交接包…**：给人看，而不是给 Agent：一个 `.zip`，里面有概要（按种类、按状态的条数，然后每一条的状态、你的原话、复现步骤、
  疑似代码位置和截图）、每条一个文件，以及截图和录屏片段。里面只用相对路径，同事的电脑上也能打开。选好保存位置即可，文件名是
  项目、日期和条数。打包时刘海会显示进度，完成后告诉你存在哪里，并带「**在访达中显示**」。事项的状态不会变。你这台 Mac 上的路径
  不会写进去：项目里的路径变成相对路径，其他路径只留文件名；已经找不到的截图会注明没有打包进来。「事项」菜单、右键菜单、
  工具栏的「**交给 Agent**」菜单和 `⌘K` 里都有。

想把事项发到别处——Slack 频道、飞书群、Linear、GitHub、Notion——直接跟 Agent 说，比如「把结账页的问题打包，发到 Slack 的 #web 频道」。
它会打包（`bundle_items` 工具），再用它自己已有的工具发出去；口喷鸡本身不接任何第三方服务。「设置 → Agent → 可以这样跟 Agent 说」
里还有几个例子。

装了口喷鸡 MCP 的 Agent（首次设置时口喷鸡会帮你装）会自己回报：你会看到事项变成「进行中」，再变成「待验证」。
如果会话结束了 Agent 却没回报（它退出了、崩溃了，或者 Mac 重启过），事项会留在「进行中」，上方写着「会话已结束，Agent 没有回报结果」：
点「**打开会话**」看看它做了什么，再「**重新开始会话**」「**标为完成**」或「**收回**」。「事项」菜单和右键菜单里也有「打开会话」。

会话结束后，终端那里说的是它怎么结束的，而不是一个死掉的窗口：「Codex 启动失败」并附上 Agent 最后说的话（登录失效、报错），
分支上有改动时是「可以查看改动」，没有就是「已结束 · 没有改动」。「**重新开始会话**」用同一个 Agent 把这些事项再跑一遍
（只会跑一次，启动时按钮是灰的）；「**收回**」把它们放回「要做」；「**查看输出**」看 Agent 最后留在屏幕上的内容。事项上方的提示条
最多两个按钮，其余的在「**⋯**」里。Agent 启动后一分钟都没有动静，会显示「没有反应」：看看它的窗口，或者重新开始。
没登录的 Agent 在「交给 Agent」面板里选不了：面板会写明要运行什么，并给出另一个 Agent；Agent 从命令行交接也会得到同样的答复。

面板用的总是这些事项自己的项目（它的默认 Agent、上次给它选的模型），和当前项目是哪个无关。交不了的事项在面板打开之前就说明原因，
并给出出路：已丢弃的（「**恢复**」）、待验证或已完成的（「**重新打开**」）、还有会话在做的（「**打开会话**」）。上一个会话没回报就结束了的事项，
可以直接再交：会先从那个会话收回。对已经结束、什么都没改的会话按「**收回**」，它的 worktree、`blurt/…` 分支和窗口也会一起清掉，
不会在你的仓库旁边留下东西；改过东西的，worktree 留着，可以「**查看改动…**」。只收回会话里的一条（`R`、状态菜单）时，其他事项还跟着它，
等一条都不剩了才清理。Codex 会请你信任一次口喷鸡的 hooks（选「Trust all and continue」）；
hooks 的命令不会再因为 Python 或口喷鸡更新而变，所以不会再问。Agent 停在这类第一次的询问（信任文件夹、信任 hooks）时，
会话标题下面会有一行字说明它在问什么、该怎么答。如果你在信任询问那一步直接退出，会话会说它停在了那里、什么都没开始；
「**重新开始会话**」会再问一次。在口喷鸡终端里用不了的旧版本 Agent（0.164 之前的 Codex）在开始前就会被拦下：
「交给 Agent」面板会显示装的版本和更新命令，并给出「**重新检查**」。Codex 每次交接时底部都会显示
*Running without the shared background server*：口喷鸡用 `-c` 传入 hooks，只有 Codex 的内嵌模式接受这种方式，不影响使用。

对话的第一行是它的标题，比如「AW-12 · 登录按钮点了没反应（口喷鸡交接）」，在 Agent 自己的对话列表里一眼就能找到；Codex 还会把它设为线程名。

**Claude 桌面端。** 装了 Claude 桌面端时，「交给 Agent」面板会问 Claude Code 在哪运行：「**在口喷鸡终端运行**」（推荐）或
「**在 Claude 桌面端运行**」。选择按 Agent 记住（设置 → Agent 里也能改）。选桌面端时，口喷鸡照样建好 worktree，然后在 Claude
里开一个新对话、填好这些事项：在 Claude 里确认文件夹并点发送。口喷鸡看不到那个对话的实时状态，事项上方写着「在 Claude 桌面端进行 ·
进度由 Agent 回报」，带「**前往 Claude**」；Agent 通过口喷鸡 MCP 回报后，事项才会变。Claude 没装 MCP 时，面板会给「**安装…**」，
不装就自己标记事项：这时事项上写着「这里收不到进度，做完后回来标为完成」，「**标为完成**」就在「**前往 Claude**」旁边，会话列表里写「在 Claude 桌面端 · 等你标记」。「**查看改动…**」和「**合并**」照常作用在 worktree 上。已经在口喷鸡终端里跑的 Claude 会话，可以用「**⋯**」菜单里的
「**在 Claude 桌面端继续…**」移过去（需要 Claude Code 2.1.285 或更高、用 Claude 订阅登录）；Agent 会在这里停下，实时状态也随之停止。
Claude 没装口喷鸡 MCP 时，确认框会说明桌面端没法回报进度，并先给「**安装…**」。桌面端没接过对话时，「**重新开始会话**」会在口喷鸡终端里
为这些事项开一个新会话。

「**查看改动…**」列出会话分支上改了什么。「**合并**」（`⌘↩`）把它并进项目文件夹；Agent 没提交的改动（Codex 在 worktree
里提交不了），按钮会变成「**提交并合并**」，由口喷鸡先提交，提交说明形如「HS-5 Create done.txt (Blurt hand-off)」。
没有改动的分支只能丢弃，不会被推送。「**丢弃**」会把事项放回「要做」。随时按 `Esc` 关掉这个面板。Agent 还开在它的窗口里时
（一轮做完了在那儿等着），按钮是「**结束会话并查看**」：先结束 Agent，再重新显示改动（包括它结束前刚写的），然后再从这里合并。
合并只会并入面板上显示的内容：打开面板后分支又有了改动，口喷鸡会请你重新查看。

整理录屏时退出口喷鸡会停止整理（退出前会先问你，按回车就是不退出），同一段录屏也不会同时整理两次。正在跑的整理和会话列在列表上方的
「**正在运行**」里。整理失败的会留在那里，带着「**重试**」和「**忽略**」，直到你选一个；它会用一句话说明是哪个 Agent、出了什么问题
（没登录、额度用完、连不上网）和该怎么办，标红的也是真正出问题的那一步（Agent 根本没法工作时是「准备」）。「**重试**」会重新检查 Agent，
所以登录后直接点就行。排在前面的 Agent 用不了时，由下一个来整理：每次换都会在刘海里说，整理记录里也留着（「由 Codex 整理（Claude Code 没登录）」）。
一个都用不了时，会按你排的顺序列出每个 Agent 和它自己的解决办法。

### 6. 事项状态

每条只有一个状态。

```
新 ──要做──▶ 要做 ──交给 Agent──▶ 已交给 Agent ──▶ 进行中 ──▶ 待验证 ──标为完成──▶ 完成
               ▲                     │               │          │
               ├── 收回 ─────────────┴───────────────┘          │
               └── 退回 ────────────────────────────────────────┘
```

- **新**：刚记下，你还没看。**要做**：你留下了。
- **已交给 Agent** → **进行中**：Agent 接手了，正在做。
- **待验证**：Agent 说做好了。看一眼：没问题就「**标为完成**」，不对就「**退回**」。
- **完成**：你确认过了。**不做**：你决定不做（没结束的事项都能标）。两者都能重新打开。
- **已丢弃**：垃圾桶；「**恢复**」会把事项放回丢弃前的状态。

待处理 = 新 + 待验证：标了不做、完成或丢弃的事项会立刻从待处理里消失。Agent 永远不能把事项标为完成——Agent 说「修好了」，一律是待验证。

点事项前面的状态圆环就能改状态，菜单里只列现在说得通的几步。列表里的快捷键：`A` 要做 · `D` 标为完成 ·
`R` 往回（退回、收回、重新打开或恢复，哪个适用就是哪个）· `W` 不做 · `X` 丢弃 · `S` 打开菜单。按完会有一行提示说事项去了哪，带「**撤销**」；
按了用不上的键，也会说明原因（已丢弃的事项要先按 `R` 恢复）。

### 7. 听写（macOS）

听写把你说的话打进**当前有焦点的 App**：聊天框、邮件、编辑器、终端都行。它和语音备注是两回事：`⌥V` 把说的话存进口喷鸡，听写把它打在你正在输入的地方。

- **设置。** 设置助手（第一次打开时出现，也可以从「设置 → 通用」再打开）用四小步把听写准备好：口喷鸡能做什么、各自的按键；听写需要的权限（麦克风和辅助功能，用下面的权限向导）；「下载推荐模型」——按这台 Mac 选好的语音识别、润色和语音备注模型，一个进度条，可以在后台继续下载（下载失败时可以「只下载小模型」，即 228 MB 的 SenseVoice Small）；最后一个输入框让你试一下（听写成功后，会再请你试一次用按两下发送），还有「登录时打开口喷鸡」（默认打开，这样听写键随时都能用）。屏幕录制权限不在这里问，第一次截图或录屏时再问。接入 Agent 在「设置 → Agent」里。
- **模型下载。** 所有模型下载——设置助手的、「设置 → 模型」的、听写键提示里的——都排在同一个队列里：一次下一个，同一个模型不会下两遍。下载时菜单栏菜单第一行显示进度（「正在下载语音模型 · 2.1 / 6.1 GB」，可以「查看」或「停止」），「设置 → 模型」里那个模型的行上有进度条（后面的显示「排队中」，压缩包下完后显示「正在解压…」）。退出或重启口喷鸡不会丢：下次打开接着下。某个模型下载失败，只停掉和它一起要下的那几个（它们的行上会写明，可以「重试」），别处要下的模型照常继续。听写自己的模型一到就能用（润色还在下也不影响），而且马上加载，第一下 Fn 不用等。还没有语音模型时，按 Fn 不会开始听写：刘海上会说明，并给「下载」（或者显示下载到哪了）——按键本身从不悄悄开始下载。
- **按一下 Fn**（🌐 键，单独按），说话，**再按一下**结束。也可以**按住 Fn** 说话，松开就结束：按住超过约 0.3 秒就是按住说话。听的时候刘海的两侧显示键盘和薄荷色的音量条，转写和润色时变成几个跳动的点。`Esc` 取消：说话时可以，文字还在处理时也可以（那段话就不会输入；几秒内可以点刘海上的「撤销」找回来，免得按给别的 App 的 `Esc` 把它丢掉）。Fn 和别的键一起用（Fn 加方向键、Fn 加功能键等）时不会开始听写。说话时，已经识别出的文字显示在刘海下方，大约比你慢一秒：还在说的部分是浅灰色（之后可能还会变，说完前不会先加句号），这一段说完就变成白色。按下结束后，这里会从头显示真正输入的文字（润色过的，或者排好的清单；最多八行，清单的标题和第一条都在）约一秒半，文字长一点就多停一会儿，后面带一个小对勾，也就是按两下会发送出去的内容。它不会让粘贴变慢。（内存小于 16 GB 的 Mac 上不显示灰色的部分，文字在每次停顿后出现；`record.dictation.live_partial` 设为 true / false 可以改变这个默认。）
- **慢的时候。** 按下结束 3 秒后文字还没好（模型还在加载），刘海上会提示「还在识别… Esc 取消」（或「还在润色…」）。语音模型停止回应时——哪怕是之前的口喷鸡留下的——下次按键会发现并换一个新的，不会让你一直等。
- **马上说下一段。** 刚结束就再按一下 Fn（隔半秒以上，免得算成按两下），下一段马上开始听，上一段还在输入也不影响；几段按你说的先后顺序输入。
- **只输入到原来的地方。** 文字只会输入到你开始说话时所在的 App。等文字好了你已经换到别的 App（说得很长、模型还在加载），就改成复制，刘海上提示「已复制，⌘V 粘贴」；这时按两下也不会按回车，刘海上会在同一行说明：「已复制，没有发送 · ⌘V 粘贴」。
- **忘了结束的听写。** 按一下开始的听写最长 5 分钟。超过 20 秒没说话，刘海上提示「还在听 · 按 Fn 结束 · Esc 取消」；从 4:30 开始时间倒数（−0:30），变成琥珀色并轻轻提示「还剩 30 秒」；到上限时刘海上会说明听写已结束，并输入你说的内容。这行提示还在时按的那一下不会开始新的一段。
- **还没有语音模型。** 按 Fn 不会开始听，刘海下方提示「还没有语音模型（大小）」和**下载**，点它就在上面的下载队列里开始下载，刘海上会说开始了，点「查看」看进度；如果你在设置里选了某个模型而它不在，下载的就是那个。已经在下载时，刘海上显示下载到哪了。听写本身从不自己下载模型。如果某一段还是没能识别，录音会保留，刘海上说明原因并给出**重试**；模型下载好以后，刘海上会再给一次重试。听写页里也会列出这一条，同样可以重试。这种情况不会再显示「没听到内容」。听写页也会说明还没有语音模型，给出**下载**和下载进度；模型就绪之前不会说「听写已开启」。
- **在句子中间听写。** 口喷鸡会看光标前后的文字，只插入新的部分：光标放在「我知道你就是▮的。」里，说「就是从老家回来的」，得到的是「我知道你就是从老家回来的。」，不会重复「就是」，也不会多一个句号。标点和空格也会顺着句子来。它只修剪自己要输入的文字，从不改动框里已有的内容；读不到输入框文字的地方（比如微信），就照说的输入。光标前是「I think ▮」这样没说完的句子时，接着说的话不会另起一句（首字母不大写，人名除外）。在终端里，说出的命令保持命令的样子（「git status」，不大写、不加句号）；说给 Agent 的请求还是一句话。
- **按两下 Fn 发送。** 快速按两下，就是在前台 App 里按回车。有两种用法：
  - **先看再发：** 按一下结束，看一眼文字（输入框里，或刘海下方的面板），再按两下发送；要改就先改。
  - **直接发：** 把结束的那一下换成按两下：听写结束，文字填进去，然后发送出去，就像在聊天框里自己按回车。（按住说话时：松开后按两下。）

  按两下只用来发送刚听写的内容：一分钟内没往这个 App 里听写过、也没有还在处理的，就什么都不按。
  按两下稍微慢一点（第二下在 0.8 秒内，还没说话）也算发送。文字还在处理时按键，不会丢掉这段话：这时按两下，会等文字填进去再发送——输入框里出现文字就马上回车，之后才还原你的剪贴板。刘海右侧会显示一个对勾和「已发送」；没能按回车时（没有辅助功能权限、在密码框里、文字只是复制了），刘海上会说明原因。在聊天 App 里的前几次听写后，会有一行小字提醒「按两下 Fn 发送」。换成其他按键也一样；不会往口喷鸡自己或密码框里按回车；不需要的话在「设置 → 听写」里关掉「按两下 Fn 发送（回车）」。
- **提示音。** 麦克风真正开始收音时小鸡叫一声（可以说了），结束时啄两下；按 Esc 取消是轻轻啄一下。按了没声音，就是没开始。语音备注也一样；录屏时不出声。「设置 → 听写」里开始和结束各有一个开关。
- **边说边翻译。** 听写时按一下 ⌘（左右都行），或点刘海里的小鸡，这段话就翻译后再输入。「设置 → 听写 → 按 ⌘ 翻译成」：「自动」（默认）是你的语言 ↔ 另一种，列表里会写出这一对（比如「自动：简体中文 ↔ English」；系统是英文、第二语言是日语时是「自动：English ↔ 日本語」）：说你自己的语言就译成另一种，说别的语言就译成你的语言；也可以选 English、简体中文、繁體中文、日本語、한국어、Français、Deutsch、Español、Português、Italiano、Русский，说的已经是这种语言时按原话输入。⌥T 截图翻译有它自己的设置（读和写的方向通常相反）。设置了云端模型并打开「用云端模型翻译」就用云端（更好，约 1 秒），否则用本机润色模型。
- **每个 App 记住你的选择。** 在某个 App 里打开结构化（⇧）或翻译（⌘）后，在这个 App 里一直保持，直到你再切回；隔一小时再用，开始时刘海会提示一句。在「设置 → 听写 → 在每个 App 里记住结构化和翻译」里可以关掉，用过的 App 也列在那里，可以重置。自动翻译的 App 列在「这些 App 里听写自动翻译」下面：在某个 App 里按 ⌘ 开启翻译，以后在那里一直翻译；再按 ⌘ 关掉，就从列表里移除；也可以在那里移除。关掉「记住」时，刘海可能会建议在你常翻译的 App 里一直翻译，接受后会说一句并带「撤销」。
- **没听到？** 刘海上会写出这次用的是哪个麦克风——「没听到内容（AirPods）」，或者这个麦克风全程没有声音时（静音了、选错了输入、耳机还在连接）写「AirPods 没有声音」——点「换麦克风…」打开「设置 → 听写」的麦克风。
- 在「设置 → 听写」（或设置助手）里可以把按键换成**右 Option** 或**任一 Option 键**（左右都行，同样只认单独按一下），方式换成只用「按一下开始，再按一下结束」或只用「按住说话」。以前没改过按键的，现在默认是 Fn；自己选过的按键保持不变。
- **Fn 和 macOS。** macOS 自己也会用 Fn（「系统设置 → 键盘 → 按下 🌐 键时」：表情、切换输入法或系统听写）。开启「辅助功能」后，口喷鸡会把 Fn 留给自己，macOS 的这个功能就不会同时触发（「Fn 只用来听写」，默认开启）。这项系统设置也会响应 Fn 时，「设置 → 听写」会提示，点**去设置…**会打开键盘设置，并告诉你改哪一项。口喷鸡不会替你改它。如果 Typeless 或 Wispr Flow 正在运行，设置页会提示：两边都会响应 Fn，退出其中一个，或者给其中一个换个键。用 Fn 听写完一段、或者它们刚打开时，刘海上也会提示一次（每天一次），点**改用右 Option** 就马上换键。
- **风格**（「设置 → 听写」）只有一个选项：**原话**（语音模型听到的原样，不润色）、**轻整理**（默认）、**结构化**或**自动**。它们用的润色模型和识别模型都在「设置 → 模型 → 听写」里选：推荐组合会写明一共多大，一个**下载**按钮就好；「设置 → 听写」显示正在用哪个，可以点「更换…」。
- **润色**（轻整理）在本机跑一个小模型：去掉语气词（嗯、那个、um、uh）和口吃，加标点、分段。其余你说的话都保留——中途改口（「周三，不对，周四」「at two, I mean three」）时，前后两种说法都照你说的打出来；只想要改口后那一版，用下面的「结构化」。说到一半停下来换口气不算一句话结束：句号只加在句子真正说完的地方。它不改写、不总结、不翻译、不回答问题。一旦输出像在做这些，或者超过时限（3 秒），这次就不润色，直接输入识别原文。模型在设置助手的「下载推荐模型」里一起装好（也可以在「设置 → 模型」里下载），推荐哪个取决于这台 Mac 的内存。选「原话」就直接输入识别原文。
- **风格。** 默认所有 App 都是「轻整理」：只做上面这些整理，不多做。它不会把你的话排成清单，不会删掉你的改口，也不改语气。按 App 稍有不同：在聊天 App（微信、Slack、飞书、Telegram 等）里会让模型保留「吧、呢、啊」这类语气词，只有一句话时不加句号；在终端和代码编辑器里不换行，打成一行。想要更整齐（排成清单，或者只留改口后的说法）时：
  - **说话时按一下 ⇧**（随时都行，说到一半也行，按住 Fn 说话时也行）：这一条就是「结构化」，刘海右侧会出现清单标记（头两次还会有一句短话说明它做什么）。松开按键后，同一个本地模型会把整段话再过一遍：你收回或重说的部分（不管你怎么说的）会去掉，你一条条数出来或列出来的要点会排成编号清单，前面那句话留作标题——只有真的在列举时才排，否则还是一段话。它不改写、不总结：结果一旦丢了内容，就打轻整理的版本。这会多花一点时间（M 系列 Mac 上大约多 0.1–0.3 秒）。再按一下 ⇧ 切回。按 **Fn+⇧** 开始，这一条直接就是结构化。听写时点一下刘海也一样。紧跟在清单后面说的内容，会另起一段。
  - **说话时单按一下 ⌘**（或点刘海里的小鸡）**翻译**：说的话翻译成上面「按 ⌘ 翻译成」里选的语言再输入。打开时刘海上有一个小的语言标签（EN、中，「自动」是 ⇄……），字幕显示的是你说的原话，停下后输入译文。加了 AI 服务 Key 就用它，否则用这台 Mac 的润色模型；翻译不成时输入原文，刘海上会说明。再按一次 ⌘ 关掉。
  - **⌥L 重排上一条**：轻整理 → 结构化 → 原话（语音模型听到的原样）→ 轻整理，刘海上可以**撤销**。只有那段文字还和输入时一模一样，才会在原处替换；你改过它的话，会按你改过的文字重排，放进剪贴板，输入框里的文字不动。文字还在输入时按下，会等它输入完：重排的就是你刚看到的那一条。较长的一条按普通段落打进去以后，模型会在后台看一下它是不是清单（输入从不等它）；是的话，刘海上会出现几秒「排成清单」。「排成清单」和「撤销」只属于它们那一条：开始下一段听写时就会消失，不会改到更新的文字。
  - 说出来的话不会切换风格：「帮我列个清单」「make a list」就照字面打出来，因为这往往是说给 AI Agent 的指令。
  - 「设置 → 听写」风格下的「按 App 类型」可以按 App 类别（聊天、代码和终端、邮件、笔记和文档、其他 App）选：跟随上面、轻整理、原话、结构化，或「自动」（只有模型排成了清单才用结构化的版本）。如果你在某个 App 里总是同样地切换（三次以上），刘海上会问一次要不要把它设成这个 App 的风格；它从不自己改，学到的设置在设置页里能看到，也能恢复默认。
- **词库**（听写页的「词库」标签；「设置 → 听写」里显示个数和「管理…」）：你常说的名字和术语，比如「Claude Code」「tmux」、项目名。识别和润色模型会参考这些词，「Claude」不会变成「cloud」，「option」也不会只剩「op」。它们只是提示，不是规则：你说的话不会被列表里的词替换（「视频 codec」还是 codec）。口喷鸡内置了一小组你可能常提到的工具名（Claude Code、Codex、Cursor、Typeless、MCP、GitHub、OpenAI、DeepSeek、Qwen 等，收在一行里），再加上你的项目名和项目代号（单独列在「来自你的项目」下）；不想要的可以移除。推荐的**语音模型**（Apple 芯片上用 Qwen3-ASR）在识别时就会照顾这些词；用其他模型时，由润色参考它们。这些词只帮着把名字写对，不会决定一句话用哪种语言打出来：「这个 feature 下周上线」还是中文。
- **它会从你的修改中学习。** 听写后一分钟内，如果你改了它打错的词（pool request → pull request），口喷鸡会注意到——等你改完再看：一分钟到了、你离开了那里、或者开始下一段听写时，拿输入的文字和输入框里最后的样子比，从不拿改到一半的词。同样的修改第二次出现时，或者只是改大小写、空格（「github」→「GitHub」）时，这个词就会加入列表，刘海上显示「记住了 pull request」，可以**撤销**。它记下的是这个词，不是替换规则，也不会把两个词连着逗号记成一个；普通单词的改动（your → you're）属于语法，不会当成新词。拿不准的会作为建议留在「词库」里，由你决定添加还是忽略。
- **在听写页里改正一条。** 选中它，按 `E` 或 `Return`（或点「改正」），光标就在文字里，可以直接改。`⌘Return` 保存，`Esc` 取消。下面会写出发现了哪些词，并给出**加入词库**（加入后可以**撤销**）；不会自己加进去。`⌘Z` 会把原来的文字放回去，并去掉这次改正建议的词。
- **光标附近的文字**也有帮助：开始说话时，口喷鸡会读取光标前后各约 500 个字和窗口标题，让名字和文档里的写法一致。「保留录音」打开时（默认打开），它随这条听写记录一起保存，供听写实验室和反馈使用，到期一起删除；关掉后只用于这一次听写，不会保存。从不读密码框。这项和自动学习都可以在设置里关掉。
- **权限**：「辅助功能」用来粘贴、读取光标附近的文字和听到 Fn；「输入监控」用来听到其他按键；还有麦克风。按键还听不到时，「设置 → 听写」最上面会提示；「权限」一栏列出每一项的状态（都开好时收成一行「都已开启」），以及上次在其他 App 里听到按键的时间。听不到的时候，菜单栏菜单第一行是「开启听写…」，刘海上大约每天提醒一次。这两处和设置里的「开启…」都会打开**权限向导**（见下）；开关打开后几秒内自动生效，不用重启。没有辅助功能权限、或者焦点不在输入框上时，文字会复制到剪贴板，刘海下方会提示「已复制，⌘V 粘贴」，按 `⌘V` 粘贴即可。粘贴之后，你原来的剪贴板内容会还原。光标在密码框里时既不输入也不复制：刘海上会说明，真要用的话点**复制**。
- **权限向导。**「设置权限…」（设置助手、「设置 → 隐私」「设置 → 听写」）和每项权限的「允许…」会替你跑腿，一次处理一项还没开的权限：口喷鸡先把自己加进列表（第一次 macOS 可能弹出自己的提示），打开「系统设置」里正好那一页，再在「系统设置」窗口旁边放一个小面板告诉你怎么做，通常就是「在这里打开口喷鸡的开关」。列表里没有口喷鸡时，把面板上的口喷鸡图标拖进列表就行。面板跟着窗口走，显示每一步的状态，开关一打开就自动进入下一步；「跳过」可以留到以后。全部完成后口喷鸡回到最前面，打个勾：「好了，现在在任何 App 里都能听写。」屏幕录制权限在第一次截图或录屏需要时才问（截图失败的提示上有「允许…」），有时要重新打开口喷鸡才生效，面板和「设置 → 隐私」里有**重新打开口喷鸡**按钮。口喷鸡从不替你点击或修改「系统设置」里的任何东西。
- **听写**是主窗口侧栏里的一页，在「全部事项」下面（也可以从菜单栏 →「听写历史…」、`⌥⌘D` 或命令面板进入）。它按天列出所有听写：打到了哪个 App、时间、文字，以及几个小标记：润色过、「未润色」（润色没成功，鼠标停在上面能看到原因）、用到了词库里的词。历史列表最上面有它自己的搜索框（`⌘F`；`↓` 进入结果，`Esc` 清空）。列表上方是今天的数字（听写次数、字数、大约省下的分钟）和「听写设置…」入口。选中一条，右边显示详情：输入的文字和语音模型识别的原文，可以分开看，也可以对照看，各有复制按钮。在这里还能**转为事项**（进当前项目，没有当前项目就进「未归类」）或删除，并能看到 App、时长、输入方式、文字实际是哪种风格，以及识别和润色模型的名字。第二个标签**词库**用来添加、筛选和移除你的自定义词（见上）：粘贴「Claude, Codex, tmux」一次加三个（已经有的会提示，不会重复加）；`Tab` 进入词，`←` `→` 移动，`⌫` 移除，`Return` 或双击改写法。移除、添加和忽略都会在刘海上提示，可以**撤销**（`⌘Z` 也行）。没能识别的听写会标出来，录音还在时可以**重试**。⌥L 替换过的一条，详情里显示现在的文字，下面是最初的版本。按键：`↑` `↓` 切换，`E` / `Return` 改正，`⌘C` 复制，`⌫` 删除（刘海上会提示并可**撤销**，`⌘Z` 也行，录音也一起找回来），`⌘F` 搜索。还没有听写时，这一页会告诉你按哪个键，听写关着、还听不到按键或还没有语音模型时也会说明。历史默认保留 30 天（在「设置 → 听写」里改），每天检查一次，不只在启动时。「保留录音」（默认打开，那里单独一个开关）会把每条听写的录音和光标附近的文字随记录保留这 30 天；关掉后，文字输入完录音就删除。口喷鸡在听写处理完之前退出的，会列为没有输入，可以**重试**。
- 录屏时听写不可用，因为麦克风正被录屏占用。听写和语音备注不会同时听：先开始的那个用完麦克风，另一个才能用。

#### 听写测试台（开发者选项）

测试台默认隐藏，打开「设置 → 通用 → 显示听写测试台（开发者用）」后才出现。打开后听写页的标签是**历史**、**词库**和**测试台**（也可以从菜单「前往 → 听写测试台」或 `⌥⌘L` 进入）。听写哪里出了错、为什么错，都可以在测试台里查清楚，并把证据留下来。这里的一切都只存在这台 Mac 上。

- **录一段**：点大按钮（测试台在前面时也可以按听写键），然后说话。旁边可以选麦克风，也可以**导入音频**，把文件当作麦克风的声音放进来。不会往任何地方打字。
- **每一步的结果**并排显示，各带耗时：每一段识别出的原文、拼接后的原文、润色结果，以及最终会输入的文字（按你填的「光标附近的文字」衔接过），还有用到的自定义词、检查的结论和补回的内容。
- 写下**你想说的**（录之前或之后都行）或者**修正后的文字**，测试台会标出差别（中文按字、英文按词），给出词错率、字错率、标点和术语的准确率。用标签标出哪里错了（名字或术语错了、中文变成了英文、标点、口头禅没去掉、内容丢了、多出了没说的话、断句不对、开头或结尾被截掉、太慢），写备注、打分，然后**存为用例**。修正会让自定义词学到东西，测试台会显示学到了什么，可以**撤销**。
- **对比**：把存好的用例换一种设置再跑一遍，比如换识别模型、不润色或换润色模型、不用自定义词、不看上下文。
- **照稿朗读**：测试台给出一句话，你照着读，这句话自动成为参考文本。读错了就重读（每一遍都会留下，「只留这一遍」可以清理），然后读下一句。自带的稿子覆盖长短句、聊天、编程指令、邮件、会议纪要、名字、数字、说错改口、口头禅和口头列举。「导入稿子…」可以加你自己的，「再生成 10 句」会按同样的风格再写一些。
- **全部重跑**：在后台把所有用例按现在的流程再跑一遍，标出哪些变好、哪些变差，给出总分，并按维度拆开看。Agent 和 CI 也能跑同样的检查：`uv run skills/blurt/scripts/dictation_lab.py run`。
- 在历史里任意一条听写上点**加到测试台**，就会生成一个用例（留了录音就带录音，没留就只有文字）。勾选「保留接下来几次听写的录音」，就能把接下来几次真实听写的录音留下来，再加进测试台。
- **导出…**会把所有用例存成一个数据集（`manifest.jsonl` 加 16 kHz 的 WAV），可以拿去做评测或微调。「移到废纸篓」删除用例。

### 8. 设置、存储和隐私

- **Agent**：口喷鸡用来整理录屏、截图和语音备注以及 AI 补全的 Agent，按顺序用：排在前面、能用的先用，没登录或额度用完时自动换下一个。用不到的取消勾选。每个 Agent 下面的「**录屏**」和「**卡片**」是各自用的模型和思考强度：录屏默认用 Agent 自己的模型、低思考强度，卡片（和 AI 补全）默认用最省的模型，都能在这里改。只有会让口喷鸡用不了的问题才标红。装好的 Agent 里有 blurt skill 和 MCP 时显示「skill + MCP」；还没装时有「连接…」，装之前先列出要改的地方。最下面的「**可以这样跟 Agent 说**」有三句可以直接用的话（点旁边的按钮复制）：发到群里、建到项目管理工具里、修一条。「导出」设置页已经去掉：发到哪里由 Agent 用它自己的工具完成，以前指向「导出」的链接会打开这里。
- **存储**：看清空间都用在哪：每个文件夹里的录屏和截图、每个模型的名字和大小（是否在用）、听写历史和录音、口喷鸡自己的文件。没被用到的模型（包括这个版本用不到的旧模型）可以移到废纸篓。视频最占地方（每分钟约 9 MB）：「删除」可以删掉 30、90、180 天前或全部已整理录屏的视频，「自动删除视频」可以替你定期删（打开时如果马上就会删掉视频，会先问你）。默认关闭——你不开口，口喷鸡不删你的东西。只删视频本身（移到废纸篓），事项、画面和文字稿都会保留。「移到废纸篓」像访达一样直接移，刘海上有「撤销」（⌘Z 也行）；只有打开「自动删除视频」时才先问。如果有东西放不回去（废纸篓已经清空），刘海上会说。
- **快捷键**也能用键盘改：Tab 到输入框，按空格开始录，按删除键去掉，任何修改都能 ⌘Z 撤销。所有 App 都在用的键会被拒绝并说明原因——⌘ 加任何字母或键（⌘C 复制、⌘Q、⌘W、⌘空格）、标准的 ⇧⌘ 组合（⇧⌘Z 重做、⇧⌘Q 退出登录、⇧⌘S…），以及 ⌃⌘Q、⌃⌘F、⌥⌘H、⌥⌘W、⌥⌘M；macOS 自己的快捷键（⇧⌘3 等截屏键）会说明是 macOS 在用。其他 ⇧⌘ 组合（⇧⌘1、⇧⌘2…）可以用。别的动作已经在用的键，会先问你：「互换」会把这个动作原来的键换给它。
- **隐私**：完整的权限列表、Spotlight，还有「不用云端语音识别」：没设置云端 API 密钥时，语音本来就只在你的 Mac 上识别；打开它，以后设置了密钥也不会用云端。现在用不到的权限（辅助功能已经能听到 Fn 时的输入监控）显示「不需要」；你关掉的权限写着「已关闭」，旁边是「系统设置…」（macOS 不会再问一次）。口喷鸡自己的数据（`~/.blurt`、`~/Blurt`）只有你的 macOS 账户能读。录屏、截图、事项都存在你的 Mac 上；整理或交给 Agent 时，需要的内容会发给你用的 Agent，按它的条款处理（开着 Agent 时，页面底部会写明）。
- **手改 `~/.blurt/config.json`**：`}` 或 `]` 前面多一个逗号没关系。文件完全读不了时，口喷鸡和它的脚本都先用默认设置（听写、语音备注和整理照常能用），把原文件另存为 `config.json.bad-<时间>`，启动时说一次，配「显示文件」；改好之前，设置的改动不会保存（第一次没存上的改动也会提示）。不管 skill 装在哪，口喷鸡都还能找到它的脚本。
- **菜单**里只给能用的快捷键标上按键；被别的 App 或另一个口喷鸡占着的不标，鼠标停上去会说明原因。听写还用不了时，菜单第一行会说为什么：「开启听写…」（权限）、「设置听写…」（语音工具没下载下来）或「下载语音模型…」。
- **同时开着两个口喷鸡**（正式版和开发版）：先打开的那个负责快捷键；听写键交给能听到它的那个（macOS 没给权限的版本不会占着它）；它退出后，另一个接管。

### 9. 更新

Mac App 会自己更新（菜单和「设置 → 通用」里的「检查更新…」）。App 自带一份 skill 脚本（放在 `~/.blurt/skill`，每次更新一起换新），在「设置 → Agent」里连接的 Agent 用的也是这一份，所以会跟着一起更新。单独装的 skill（`npx skills add AGIHunt/blurt`）用这条命令更新。自己编译的口喷鸡用代码目录里的脚本，运行 `uv run skills/blurt/scripts/record.py build` 更新；App 和脚本的版本对不上时，刘海里会提示该更新哪边，菜单栏菜单和「设置 → 通用」也会一直写着，直到对上为止。
