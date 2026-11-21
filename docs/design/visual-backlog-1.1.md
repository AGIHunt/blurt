# Visual backlog after 1.1.0

The 1.1 visual gate (2026-11-21, base 77dfade7) was stopped once it had judged the whole app. After that, only the Remote, pairing, viewer, models and onboarding pages were fixed for 1.1.0, plus five layout-lint defects. This list is the rest: screens left out of 1.1, with the judges' average (3 judges, 1–10, where 8 means it would ship in Claude desktop, Linear or Raycast) and the first problem they named.

- Shots and judge notes: `promo/cases/visual-gate-1.1/inventory/<screen-id>/` (bug-agent checkout).
- Full verdicts: the workflow journal of run wf_516c59fd-7e2.
- Next round: run `.claude/workflows/blurt-visual-gate.js` with `only:` set to the pages below. It enforces the scope, retakes missed shots and uses one redesigner per page.

## Shots that missed their state (39): retake before judging

`permissions.fn`, `dictation.nudge`, `recording.discard`, `settings.agents.examples`, `cards.hover`, `recording.notes`, `screentext.no-match`, `settings.agents.install`, `cards.preview`, `main.job`, `main.unassigned`, `note.markup`, `screentext.read`, `settings.dictation`, `settings.storage.hover`, `main.cards.empty`, `main.lab.new`, `recording.menu`, `note.mic-busy`, `screentext.selected`, `cards.hanging`, `island.peep.listening`, `island.peep.talking`, `settings.search`, `settings.shortcuts`, `picker.text`, `main.banner`, `main.empty.project`, `main.empty.scanning`, `panel.move`, `permissions`, `permissions.screen`, `recording.ink`, `settings.privacy`, `island.switcher`, `toast.action`, `picker`, `note.kind`, `recording`

## Lowest scores (37 screens under 6.5)

| avg | screen | first problem |
|---|---|---|
| 5.0 | `settings.agents` | BLOCKER (zh-light, zh-dark, bottom edge y≈1236–1240 around x≈930 and x≈1330): the tops of the next section's glyphs (the Model / Effort column names) peek out a… |
| 5.0 | `settings.agents.missing` | P1 control economy / spec violation (whole 'Use Blurt in Your Agent' list, all 4 shots): 12+ rows, each repeating the same hollow ring, the same 'Not connected'… |
| 5.0 | `settings.privacy.missing` | P1 control economy / redundancy (Permissions section, all four shots): the missing state is said three times and fixed four ways. The summary row's title lists … |
| 5.2 | `main.lab.regression` | P1 alignment, detail pane, Configuration row (all 4 shots): the Picker sits in `.frame(maxWidth: 360)` and is centred inside it, so the label 'Configuration' st… |
| 5.3 | `main.lab.case` | BLOCKER CHECK: nothing is cut off at any of the four window edges in any of the four shots. The traffic lights are clear, the ⋯ and Save Changes sit inside the … |
| 5.7 | `panel.shortcuts.search` | zh-light and zh-dark: searching 'copy' finds nothing ('没有匹配的快捷键'), while en finds 3 rows. ShortcutRowView.haystack (MainMenu.swift ~L565) holds only the localiz… |
| 5.7 | `settings.dictation.bottom` | P1 typography/clipping (en-light, en-dark, top of the page column, y≈130–150): the 'Translate' section heading is cut in half at the scroll area's top edge, dir… |
| 6.0 | `dictation.kept` | Hierarchy is upside down (all four shots, text block at y≈95-160 px). The status line 'No text field found. Your text:' / '未找到输入框，文字如下' is set in 13 medium at 9… |
| 6.0 | `island.dropin` | No edge cut-offs in any of the four shots: the top corners are the notch shoulders, and the left, right and bottom edges are clean. The layout lint list is empt… |
| 6.0 | `island.polishing` | Clarity, the main issue: island.polishing cannot be told apart from island.transcribing or from 'sending' (Dictation.sendQueued, a double tap's Return). All thr… |
| 6.0 | `main.cards` | Tiles carry no identity (all shots, Current row). There is no note, time or source app under any tile, so the grid is four anonymous thumbnails. Tiles 1 and 3, … |
| 6.0 | `main.cards.focus` | Nothing cut off at any window edge in the four shots: traffic lights clear, right and bottom edges clean, no layout-lint entries. No blocker. |
| 6.0 | `main.cards.history` | History tiles have no identity at all (History row, y≈617–800). Under each tile there is no note, no destination ('Dragged into Slack'), no time and no kind mar… |
| 6.0 | `main.dictation.words` | BLOCKER CHECK: nothing is cut off at a window edge in the four full-size shots. All four edges are clean and the traffic lights clear the sidebar toggle. At min… |
| 6.0 | `main.empty.discarded` | Blocker check: nothing is cut off. All four edges are clear in all four shots (the traffic lights, the record/snap capsule at the top right with about 12 px to … |
| 6.0 | `main.home.focus` | Hierarchy: there is no single focus. The 3 pt accent ring, the green link line under Dictation, five saturated green switches, seven keycap groups and two mint … |
| 6.0 | `main.home.off` | P1 hierarchy/polish, top of content pane (all 4 shots, x≈592–680, y≈15–45 at 2000px scale): the page title 'Home' / '主页' is a blurred, near-invisible ghost unde… |
| 6.0 | `main.home.recent` | Nothing is cut off at the window edge, so there is no blocker. The 'Notes' row is sliced by the toolbar hairline at the top (icon, label and '02:31' half under … |
| 6.0 | `main.job-failed` | P1 alignment, middle column, all 4 shots: the "Failed 1" / "失败 1" section header starts at the title column (x~494 at display scale), but the "My SaaS 49" heade… |
| 6.0 | `main.lab` | Hierarchy, detail column: the screen has no single focus. 'New Take' (about 20 pt semibold) has the same weight as the page title 'Dictation', so the two titles… |
| 6.0 | `menubar` | P1 alignment (lint confirmed, all four menu shots): "Computers…" / "电脑…" starts at x≈118 while every other top-level row starts at x≈75, so it reads as a sub-it… |
| 6.0 | `settings.agents.details` | P2 truncation (lint confirmed, all 6 en shots incl. min/restore): Background Organizing → Recordings → Model pop-up reads "Default (Agent's defaul…" (AXPopUpBut… |
| 6.0 | `settings.storage` | Blocker check: nothing is clipped at the left, top or right edge in any of the 4 shots, and nothing sits under the traffic lights. At the bottom, the rest shots… |
| 6.2 | `cards.focus` | Scale and hierarchy (all 4 main shots): the focus tip is about 888 x 390 pt, with an 864 x 318 pt picture, under a card row whose cards are 84 pt high. When the… |
| 6.2 | `main.dictation.edit` | Button order and placement go against the Mac and against the reference apps. Save (primary, gradient) is on the leading edge with Cancel to its right (detail p… |
| 6.2 | `main.home` | Capability card is a wall of controls at rest. Every one of the 5 rows has a brand-green switch, and 4 have keycaps: Cards shows 4 caps plus a switch (5 marks),… |
| 6.2 | `panel.shortcuts` | Not a blocker: nothing is cut off at a window edge in any of the four shots. The single close button and the title clear the content, the keycaps end 20 pt insi… |
| 6.2 | `settings.general` | P1 hierarchy/whitespace: an empty band of about 45 pt between the toolbar title 'General' (y~51px) and the first heading 'Features' (y~190px) in all four shots.… |
| 6.3 | `main.dictation` | Alignment, the two column headers don't meet. The list column's title band ('Dictation 15 dictations') sits at y≈103 (en-light, 2000-wide coords), but the detai… |
| 6.3 | `main.empty.failed` | Copy (P1), centre stack, title and hint, all four shots: the hint repeats the title. EN: 'Couldn't read your items' then 'Couldn't read the items in this folder… |
| 6.3 | `main.empty.no_results` | State contradiction in the list column (all 4 shots): the search field shows its placeholder 'Search items' / '搜索事项' while the heading says 'Results for “zebra”… |
| 6.3 | `main.project` | Recordings section is off the list grid (all four shots). The 'Recordings 1 v' header starts about 6 pt left of the 'My SaaS' heading and about 13 pt left of th… |
| 6.3 | `note.heard` | P1 typography/correctness, text line, all 6 bubble shots (-2): the committed and pending words run together as "The coupon field resets afterapplying" with no s… |
| 6.3 | `panel.palette.query` | Density (main problem): the list has a fixed height of about 10 rows (CommandPalette.swift listHeight, 'a fixed height ... so nothing jumps'). With one hit (IN-… |
| 6.3 | `settings.agents.bottom` | Blocker check: none. All four edges are clear in all 4 shots. The Claude Code row half-hidden under the toolbar (y≈130–150) is the spec'd 10 pt scroll fade on s… |
| 6.3 | `settings.projects.selected` | Selection wash is off the grid. It runs from x≈508 to 1664 px, but the row hairlines and every other element sit at 532–1640 (ProjectsPane.swift:240, `.padding(… |
| 6.3 | `settings.storage.bottom` | P1 Models section, all four shots (y~593-650): the heading says '644 KB' but there are no rows under it, only the footnote 'Chosen in Models.' / 在「模型」里选择。. The … |

The other 52 screens scored 6.5–8. Most notes on them are about density and hierarchy, not defects.
