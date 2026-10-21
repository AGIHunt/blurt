# Feature parity with the vanilla review page

Reference: `skills/blurt/scripts/review.html` as of `1e728d2` (904 lines, vanilla JS). The shared Playwright checks in
`e2e/review.spec.ts` run against both pages — `REVIEW_HTML=<old review.html> pnpm test:e2e` is the parity run (all
shared checks pass on the old page too, so they encode its behaviour); checks named `NEW:` cover what the old page
lacked. `e2e:` = Playwright (Chromium + WebKit), `unit:` = vitest, `wk:` = `pnpm test:wkwebview` (real WKWebView,
macos host), `app:` = checked by hand in Blurt.app's review window (WKWebView over review.py).

| # | Behaviour of the old page | New page | Covered by |
|---|---|---|---|
| 1 | Theme before first paint: browser = the user's pick (`blurt.theme`) else the system; app window always follows the system; toggle button (browser only) | same (+ `?theme=`) | e2e screenshots; app |
| 2 | Language: `blurt.lang` pick, else items.json `language`, else the browser; toggle | same | e2e "severity keys … language switch" |
| 3 | Top bar: logo, session name, keep/drop progress bar, counts, processing pill, save state, Overview/Focus/List, theme, language, shortcuts, Finish ⌘⏎ | same; session name + theme hidden in the app | e2e, app |
| 4 | Default view: overview when there is a digest, focus when >1 item, else list; remembered in `blurt.view` | same | e2e "J/K … G and V" |
| 5 | Overview: title, kind counts, digest (mini markdown), items by kind → focus | same | e2e (V) |
| 6 | Focus queue: number, kind egg, title, "needs input" dot, keep/drop dot, current row, scroll into view | same | e2e |
| 7 | Stage: frame hugging its aspect ratio, AR cache (no flash), strip of frames / clip / recording, caption with time + caption + ⤓ download (`?download=1`), lightbox | same; + Quick Look / reveal when the host has them; 1px inner stroke | e2e "media", wk |
| 8 | Recording: seek to start − 1.5 s, pause after end + 2 s; O / ▶ jumps there; Space plays | same | e2e "media" |
| 9 | Slide-in animation up/down on navigation; wheel and swipe on the stage move between items | same | manual (app), code port |
| 10 | Inspector: id, merged_from, n / N, ↑↓; auto-sizing title; status / kind / severity (cycles) / type (cycles) / low-confidence chips; questions + answer; quote with time | same; + fix chip | e2e |
| 11 | Fields per kind (issue / idea / task / note), generic fields for custom lenses, tags (`,` `，`), source URL; lists parse `1.` / `-` | same; uid / fix / fix_history / schema never shown as fields (the old page showed `uid`) | e2e "autosave", "NEW: v2 fields" |
| 12 | Code refs: click copies | same; opens in the editor when the host has `openCode` | manual |
| 13 | Autosave 450 ms, "Saving… / Saved / could not save", only diffs sent as user-ops, `_user` recorded by the server | same | e2e "autosave", unit store |
| 14 | Three-way merge of agent writes: user's unsaved fields win, new items inserted in place, the field being typed in untouched | same | e2e "agent writes never overwrite…", unit sync |
| 15 | Progressive mode: poll 1.5 s while processing, shimmer placeholders, new frames fade in, pill working / stalled (10 min) / finished | same; idle poll 5 s → 2 s (agent frames within 3 s) | e2e "set-frames … 3 s", wk |
| 16 | Keys: J/K/↓↑, A/⏎ keep, X/⌫/Del drop, Z/U undo, M merge, 1 2 3 severity, ← → media, Space, O, E, G, V, ?, ⌘⏎, Esc | same | e2e, wk, app |
| 17 | Keep/drop → toast with Undo, next unreviewed item; last one → finish dialog | same | e2e |
| 18 | Undo stack (80) restores only the user's own steps | same | e2e "J/K…", "M merges…", unit sync |
| 19 | Merge into the previous non-dropped item: quote " … ", text joined, lists unioned, time widened, merged_from; undo brings it back | same; never folds uid / fix / fix_history (the old page wrote `"uid1\nuid2"`); `"2024"` tags stay strings | e2e "M merges…", unit sync |
| 20 | List: search (title/module/owner/id/summary/tags), status filter, kind filter (≥2 kinds), cards with stamp + meta, click → focus | same; + fix state in the meta line | e2e "list view" |
| 21 | Finish dialog: counts, "still processing" warning once, review the rest / cancel, confirm; waits for queued saves; unsaved typing goes with the confirmation; done screen | same | e2e "⌘⏎ → confirm", unit store, wk, app |
| 22 | In the app window: `window.blurtApp` → no theme toggle / session name, done text, `{type:"confirmed"}` to `webkit.messageHandlers.blurt`, title via `document.title` | same | app (ReviewWindow, real keys), unit hosts |
| 23 | Hand-written items.json without ids: saved whole (legacy) | same (browser host `saveDoc`) | code port |
| 24 | Shots sessions (no recording): no recording entry | same | e2e "screenshots session" |
| 25 | Items dropped before this review are hidden | same | unit sync |
| 26 | Narrow windows: queue hides < 1180 px, compact top bar < 1000 px, single column < 860 px; reduced motion | same | manual |
| — | NEW: IME Enter guard (keyCode 229 / isComposing / 50 ms after compositionend); Enter commits the title and single-line fields without also keeping the item | | e2e "NEW: an IME's Enter", unit ime, wk, app |
| — | NEW: item mode (`mode=item`, by id or uid, `setItem`), host adapters (browser / macos / tauri), drag rects, Quick Look / reveal / openCode / fixWithAgent / download affordances, fix chip + history, platform tokens mac / win / gnome × light / dark, system accent | | e2e, unit hosts, wk |
