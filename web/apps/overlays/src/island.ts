// The island on Windows / Linux (v0.7 contract K7): the Mac's island as it is drawn on a screen without a notch — a
// capsule at the top centre (Capture/Island/Island.swift `geo.notch == false`), with the Mac's ears, open views,
// toasts and hanging cards. docs/design/windows-parity/island.md is the audit (every Mac behaviour, what this does).
//
//  • collapsed: only what is live (Island.updateEars) — recording (dot + time | snaps or the level), a voice note
//    (Peep listening + wave | how it ends, then the clock), dictation (Peep talking + level | style marks + clock; Peep
//    thinking + dots while it works), the cards waiting (their glyph + count), Peep thinking while captures are
//    organised, "+n" as captures land in the inbox, a done moment ("✓ Copied").
//    Nothing at all at rest: the inbox's backlog is the tray's and the open island's Inbox row.
//  • open (hover 180 ms, or a hotkey): IslandContent — home (Peep, the project, record / snap / voice; jobs, the
//    cards waiting with Organize, the Inbox row, or the keys), the recording controls, the voice
//    note, the project switcher and the drop drawer. Toasts: one layout (mark, headline · detail, a quiet button).
//  • the cards hang only while you look (HangingCards): newest first, at most five, centred under the island
//    (cards.ts = BlurtCore CardRow); they come down when the pointer rests on the island, after a capture, or from the
//    ear's count, and the threads reel them back up 250 ms after the pointer has left.
//
// The window is the full width of the screen and click-through except over what is drawn (we report those rects).
// Rust (apps/desktop/src-tauri/src/island.rs) sends `state` / `cards` / … ops and gets actions back.
import { iconSvg, type IconName } from '@blurt/icons/core';
import { mascotHtml, setMascotLevel } from '@blurt/icons/mascot';
import '@blurt/icons/mascot.css';
import '@blurt/icons/peep-s';
import {
  BELOW,
  CardReveal,
  DeferredClick,
  LIFT,
  LIFT_SCALE,
  FADE,
  MAX_HUNG,
  UNDO_MS,
  VOICE,
  cardRow,
  cardShape,
  rowBounds,
  rowCentre,
  stepAside,
  visibleIn,
  type RowLayout,
  CardsPanelRules,
  PANEL_MIN_W,
  TILE_W,
  cardAgo,
  daysLeft,
  gridColumns,
  gridWidth,
  panelKey,
  type Segment,
} from './cards';
import { meterBars } from './clock';
import {
  EV,
  connect,
  i18n,
  params,
  plural,
  ready,
  reduceMotion,
  setLang,
  t,
  type Card,
  type CssRect,
  type IslandOp,
  type IslandState,
  type JobRow,
  type ProjectRef,
} from './host';
import { projectColor } from './projectlook';
import { Pendulum, Spring } from './spring';

const host = await connect('island');
const stage = document.querySelector<HTMLElement>('.stage')!;
const deck = document.querySelector<HTMLElement>('.cards')!;
const island = document.querySelector<HTMLElement>('.island')!;
const pill = island.querySelector<HTMLElement>('.pill')!;
const body = island.querySelector<HTMLElement>('.body')!;
// the words while you talk (the Mac's LiveTranscript): the island's lower half, not interactive, click-through
const livePanel = document.createElement('div');
livePanel.className = 'live';
livePanel.setAttribute('aria-live', 'polite');
island.after(livePanel);
// the live caption while recording (the Mac's CaptionPanel; recording.md §7.2): one line of what was just said under
// the island, the newest words kept (cut at the head); in 0.2 s, out 0.6 s after 5 s
const captionEl = document.createElement('div');
captionEl.className = 'caption';
captionEl.setAttribute('aria-live', 'polite');
livePanel.after(captionEl);
let captionTimer = 0;
function showCaption(text: string) {
  const tx = text.trim();
  if (!tx || !S.recording) return;
  captionEl.innerHTML = `<span dir="auto">${esc(tx)}</span>`;
  captionEl.style.top = `${Math.round(island.getBoundingClientRect().bottom + 10)}px`;
  captionEl.classList.add('shown');
  clearTimeout(captionTimer);
  captionTimer = window.setTimeout(() => captionEl.classList.remove('shown'), 5000);
}
const glow = document.querySelector<HTMLElement>('.glow');
// a right-click menu (a card's, the island's) or the recording's ··· menu: dark, as the island it hangs from
// the strip between the screen's top edge and the pill: part of the island's target, so the pointer pushed against
// the top of the screen (Fitts: the Mac's notch opens there) opens it — at 150 % the pill starts 9 px down
const hot = document.createElement('div');
hot.className = 'island-hot';
stage.append(hot);
const menuEl = document.createElement('div');
menuEl.className = 'menu';
menuEl.hidden = true;
menuEl.setAttribute('role', 'menu');
stage.append(menuEl);

// ------------------------------------------------------------------ geometry and timing (Island.swift, capsule)
const TOP = 6; // the capsule sits this far under the top of the work area
const PILL_H = 30;
const PILL_MIN_W = 120;
// one ear alone (the cards' count): the capsule hugs it — its 14 px insets and a floor — instead of a 120 px slab with
// the count lost in the middle (the Mac's capsule ears are sized to what they hold)
const LONE_MIN_W = 72;
// the launch hello (the Mac's Island.hello, 0.5 s after the island is up): Peep says hello in the ear with "Ready",
// for the hello clip and a moment to read it (EarSlot.helloSeconds), then the ears go back to what they hold
const HELLO_AFTER_MS = 500;
const HELLO_MS = 2800;
const PEEK_W = 150; // brought out by the hot zone with nothing to say
const OPEN_W = 480;
const MAX_H = 420;
// the capsule's width while live text hangs under it: the panel's own (IslandLayout.livePanelMinWidth), so the pair
// reads as one island with its lower half, the same edges and corners (the Mac's 292 sits under a notch's proportions;
// a free-floating capsule 48 px narrower than its panel read as two widgets — windows-parity/island.md)
const LIVE_CAPSULE_W = 340;
const EARS_LINE_MIN_W = 292; // a line under the listening ears: the Mac's width family (292 … 480), never narrower
const HOVER_IN = CardReveal.dwell;
const HOVER_OUT = 400;
const TOAST_MIN = 5000; // ToastQueue.minSeconds
const TOAST_HOVER_HOLD = 1200; // Island.toastHoverHold
const NEWS_MS = 4500; // Island.newsSeconds
const MOMENT_MS = 2200;
const VOICE_HINT_S = 3; // Island.voiceHintSeconds
const DOUBLE_CLICK_MS = 500; // Windows' default double-click time
const MAX_CARDS_KEPT = MAX_HUNG;

const ic = (name: IconName, size = 16, cls = '') => iconSvg(name, { size, className: cls ? `ic ${cls}` : 'ic' });
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const num = (n: number) => i18n.formatNumber(n);
const clock = (s: number) => i18n.formatDuration(s, 'clock');
/** dictation's clock: the time so far, then — from 4:30 — the time left before the 5-minute limit, with a minus
 *  ("−0:29") in the attention colour (BlurtCore DictationRunaway.clock; Rust: dictation/flow.rs `Runaway`) */
const DICT_COUNTDOWN = 270;
const DICT_LIMIT = 300;
function dictClock(): string {
  const e = dictElapsed();
  return e >= DICT_COUNTDOWN ? clock(Math.max(0, Math.ceil(DICT_LIMIT - e))) : clock(e);
}
/** in its last half minute the clock counts down: its minus is drawn by .time.neg::before, kerned onto the digits
 *  (Segoe UI's U+2212 carries wide side bearings — "− 0:28" read as two things; the Mac sets it tight) */
const dictCountdown = () => dictElapsed() >= DICT_COUNTDOWN;
const tipKey = (label: string, key?: string) => (key ? t('island.tip_key', { label, key }) : label);

// glyphs the line family doesn't have as such, at its stroke (IslandGlyph): record (a ring and a dot), Unassigned
// (a dashed ring — never a second tray beside the Inbox's)
const SVG = (inner: string, size = 15) =>
  `<svg class="ico ic" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" aria-hidden="true">${inner}</svg>`;
const recordGlyph = (size = 15) => SVG('<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="2.6" fill="currentColor" stroke="none"/>', size);
const ringGlyph = (size = 15) => SVG('<circle cx="12" cy="12" r="8" stroke-dasharray="1.7 4.58"/>', size);

/** The project's one identity: the family's folder in its colour, its body washed at 28 %. */
const folderGlyph = (p: ProjectRef) => `<span class="pf" style="color:${projectColor(p.id)}">${ic('folder', 15)}</span>`;
/** A folder that is gone: the family's folder, outlined, a question mark in it (IslandGlyph.missing). */
const missingGlyph = (size = 15) =>
  SVG('<path d="M3 7.5C3 6.119 4.119 5 5.5 5L8.9 5C9.313 4.992 9.711 5.155 10 5.45L11.6 7L18.5 7C19.881 7 21 8.119 21 9.5L21 17.5C21 18.881 19.881 20 18.5 20L5.5 20C4.119 20 3 18.881 3 17.5Z"/><path d="M10.1 11.9a1.9 1.9 0 1 1 2.6 1.75c-.45.2-.7.55-.7 1v.2"/><circle cx="12" cy="17.2" r=".8" fill="currentColor" stroke="none"/>', size);
/** One mark per place: a project's coloured folder, a missing folder's question mark. */
const placeGlyph = (p: ProjectRef) => (p.exists === false ? `<span class="dim">${missingGlyph()}</span>` : folderGlyph(p));

// ------------------------------------------------------------------ state
let S: IslandState = { project: null, projects: [], toReview: 0, recording: null, voice: null, hatching: 0, jobs: [], hotkeys: {} };
let stateAt = performance.now();
let level = 0;
// Peep's beak follows the voice while you dictate (the level as the wave bars read it: ~0.1 rms is a loud word)
setMascotLevel(() => Math.min(1, level * 9));
let open = false; // expanded
let drawer: null | 'switch' | 'drop' = null;
let confirmDiscard = false;
let liveText: null | { text: string; partial: string; typed: boolean } = null;
let liveTop = 0; // where the live panel sits once its text has gone in (it doesn't move any more)
let peekUntil = 0;
let hovering = false;
let hoverSince = 0;
let hoverTimer = 0;
// a line's button was clicked: the island stays closed until the pointer really moves away from where it clicked (the
// line that follows may be narrower and wider again under a resting pointer: that's no new hover)
let holdClosed: null | { x: number; y: number } = null;
document.addEventListener('mousemove', (e) => {
  if (holdClosed && Math.hypot(e.screenX - holdClosed.x, e.screenY - holdClosed.y) > 12) holdClosed = null;
});
let filter = '';
let selIx = 0;
let showAll = false;
let bump = 0;
let moment: null | { text: string; until: number; lead?: 'keyboard' } = null; // "✓ Copied" in the ears; ⌨ ✓ Sent
let news: null | { n: number; until: number } = null; // "+n" as captures land in the inbox
let lastReview = -1;
let sorted: null | { ok: boolean; n: number; until: number } = null; // Peep's hop (or head shake) when a run ends

function recElapsed(): number {
  const r = S.recording;
  if (!r) return 0;
  return (r.elapsed ?? 0) + (r.paused ? 0 : (performance.now() - stateAt) / 1000);
}
const dictElapsed = () => (S.dictation ? S.dictation.elapsed + (performance.now() - stateAt) / 1000 : 0);
const voiceElapsed = () => (S.voice ? S.voice.elapsed + (performance.now() - stateAt) / 1000 : 0);

const hanging = () => live.filter((l) => l.phase === 'hang' || l.phase === 'fly');
// the count says what has landed: a card still flying in adds its 1 when it reaches its place (Mac C43: the number
// ticks as the card arrives, never ahead of it)
const cardCount = () => live.filter((l) => l.phase === 'hang').length;

// ------------------------------------------------------------------ toasts (BlurtCore ToastQueue, the island's rules)
interface Toast {
  key?: string;
  /** headline; after the first " · " (or "\n") the detail, in secondary white */
  text: string;
  /** the leading slot: the ok check, the attention triangle, a source glyph; or Peep (done / error) */
  mark?: IconName | 'spinner' | 'peep';
  peep?: 'done' | 'error';
  /** where it went: the project's folder in its own colour leads the line (`inbox`: Unassigned's ring) — the Mac's
   *  Filed / Moved / Organizing lines (C13, C38) */
  project?: string;
  /** whose line it is: a dictation line with no mark leads with the grey Peep */
  src?: 'dictation';
  /** one quiet button (an Undo, Open, Show): sent back as an action with `extra`; `vars` fill its label ("Download (230 MB)") */
  action?: { a: string; label: string; extra?: Record<string, unknown>; vars?: Record<string, string> };
  /** a second, quieter choice left of it (the Mac's Toast.second: "Download (950 MB)" · "Use Cloud…"); the first is
   *  then the filled one */
  second?: { a: string; label: string; vars?: Record<string, string> };
  /** waits behind what the user is doing now (a job that finished) */
  passive?: boolean;
  /** shown over the open island too (an Undo for what was just done on the cards under it) */
  overOpen?: boolean;
  ms?: number;
}
let toastNow: (Toast & { left: number }) | null = null;
const toastWait: (Toast & { left: number; posted: number })[] = [];
let toastTick = performance.now();

/** A picker, a snap's note, a take starting (Rust's `busy`), a take, a voice note, a dictation listening: lines that
 *  can wait (a question, a tip, a job that finished) hold until 1.5 s after it is over — never over a capture. */
let busyCapture = false;
let idleSince = performance.now();
const heldLines: Toast[] = [];
const busyNow = () => busyCapture || !!S.recording || !!S.voice || S.dictation?.phase === 'listening';
/** what was up and can wait goes back to wait (a question asked at launch, still unanswered) */
function parkWaiting() {
  if (toastNow?.passive && toastNow.action) {
    heldLines.unshift(toastNow);
    toastNow = null;
  }
}

function postToast(tt: Toast) {
  if (tt.passive && busyNow()) {
    heldLines.push(tt);
    return;
  }
  if (S.recording && !tt.overOpen && tt.mark !== 'warning') return; // K4: nothing while recording
  const left = Math.max(TOAST_MIN, tt.ms ?? TOAST_MIN);
  if (toastNow && tt.key && toastNow.key === tt.key) {
    toastNow = { ...tt, left }; // replaced, not repeated: its text, its action, a fresh clock
  } else if (toastNow && tt.passive) {
    toastWait.push({ ...tt, left, posted: performance.now() });
  } else {
    // newest first: a reply takes the slot; one with an action that still matters comes back after it
    // (a dictation notice that was already read — up a second or more — doesn't: "Typeless is also running" came back
    // 15 s later, after Typeless had quit)
    const seen = !!toastNow && Math.max(TOAST_MIN, toastNow.ms ?? TOAST_MIN) - toastNow.left > 1000;
    const readNotice = !!toastNow?.key?.startsWith('dictation') && seen;
    if (toastNow?.action && !toastNow.passive && toastNow.left > 1000) toastWait.unshift({ ...toastNow, posted: performance.now() });
    else if (toastNow?.passive && !readNotice) toastWait.unshift({ ...toastNow, posted: performance.now() });
    toastNow = { ...tt, left };
  }
  toastTick = performance.now();
  render();
}

function dismissToast() {
  toastNow = null;
  // stale ones go: a reply that waited over 10 s describes something that is over
  while (toastWait.length) {
    const n = toastWait.shift()!;
    if (n.passive || performance.now() - n.posted < 10000) {
      toastNow = n;
      break;
    }
  }
  render();
}

/** The open island takes only the toasts meant to go over it; the others wait (their clock stopped) until it closes. */
const toastShows = () => !!toastNow && !drawer && (!open || !!toastNow.overOpen);

setInterval(() => {
  const now = performance.now();
  const dt = now - toastTick;
  toastTick = now;
  if (toastNow && toastShows() && !hovering) {
    toastNow.left -= dt;
    if (toastNow.left <= 0) dismissToast();
  }
  if (moment && now > moment.until) (moment = null), render();
  if (news && now > news.until) (news = null), render();
  if (sorted && now > sorted.until) (sorted = null), render();
  if (readingUntil && now > readingUntil) (readingUntil = 0), render();
  if (busyNow()) idleSince = now;
  else if (heldLines.length && now - idleSince > 1500 && !toastNow) postToast(heldLines.shift()!);
}, 200);
/** Copy Text / Translate reading what was dragged over: Peep thinks in the ear (until its line, at most 30 s) */
let readingUntil = 0;
let helloUntil = 0;

/** The widest text a done line may have to go in the ears instead of a toast (Island.earMomentMaxText, 96 pt on the
 *  Mac; "Ctrl+V" is longer than "⌘V"). */
const EAR_MOMENT_MAX = 130;
let measureCtx: CanvasRenderingContext2D | null = null;
function earTextW(text: string): number {
  measureCtx ??= document.createElement('canvas').getContext('2d');
  if (!measureCtx) return Infinity;
  measureCtx.font = `600 13px ${getComputedStyle(document.body).fontFamily}`;
  return measureCtx.measureText(text).width;
}
/** A number and its unit never part at a wrap ("950 MB", "20 s", "约 20 秒"). */
const keepUnits = (s: string) => s.replace(/(\d) (MB|GB|KB|kB|s|min)(?![A-Za-z])/g, '$1\u00a0$2').replace(/(\d) (秒|分钟)/g, '$1\u00a0$2');

function earMoment(text: string, lead?: 'keyboard') {
  // dictation's "Sent" (lead: the keyboard) is its own moment while a take is still on its way, never over one that listens
  // (a take still on its way — recognizing, polishing — gives its ears to the moment: the moment is about it)
  const dictBusy = S.dictation?.phase === 'listening';
  if (S.recording || S.voice || dictBusy) return postToast({ text, mark: 'check' });
  moment = { text, until: performance.now() + (lead ? 1600 : MOMENT_MS), lead };
  render();
}

function visible(): boolean {
  return !!(
    S.recording ||
    S.voice ||
    S.dictation ||
    (recDone && performance.now() < recDone.until) ||
    liveText ||
    (S.hatching > 0 && !quietAtRest()) ||
    toastNow ||
    open ||
    drawer ||
    hovering ||
    // a first card still flying in: the island it lands in is there (the landed ones only while the island may rest)
    live.some((l) => l.phase === 'fly') ||
    (hanging().length > 0 && !quietAtRest()) ||
    moment ||
    performance.now() < helloUntil ||
    news ||
    sorted ||
    !menuEl.hidden ||
    performance.now() < peekUntil
  );
}

// ------------------------------------------------------------------ the ears (collapsed: Island.updateEars)
/** "Show the island when idle" is off (app.island_idle; the Mac's Island.showsAtRest) and nothing has brought it out:
 *  what only stands — the cards' count, Peep thinking over an organize — stays out of the ears. What is live still shows. */
const quietAtRest = () => S.idle === false && !open && !drawer && !hovering && performance.now() >= peekUntil;
const waveHtml = (n: number, cls = '') => `<span class="wave${cls ? ' ' + cls : ''}" data-wave>${'<i></i>'.repeat(n)}</span>`;
const cardsEar = () =>
  `<button class="earbtn" data-a="cards.reveal" title="${esc(plural('island.cards_waiting', cardCount()))}">${ic('cards', 15, 'cards-ic')}<span class="num">${num(cardCount())}</span></button>`;

/** The style marks of a dictation that listens: a list while Structured, the translate glyph while translated — in
 *  mint, 14 px, 6 px apart; the translate target is said with the clock (dictClockHtml), never as a second mint label. */
function dictMarks(): string {
  const d = S.dictation!;
  const m = (d.style === 'structured' ? ic('list', 14, 'mint') : '') + (d.translate ? ic('languages', 14, 'mint') : '');
  return m ? `<span class="dmarks">${m}</span>` : '';
}

/** The clock's group: the translate target in the clock's own white before the time ("EN 0:22"; the Mac's
 *  Dictation.earClock), the time in the attention colour in its last half minute. */
function dictClockHtml(): string {
  const d = S.dictation!;
  const tgt = d.translate && d.target ? `<span class="tgt">${esc(d.target)}</span>` : '';
  return `<span class="dclock">${tgt}<span class="time${dictCountdown() ? ' neg' : ''}" data-clock="dict">${dictClock()}</span></span>`;
}

/** How a voice note ends, alone ("Alt+Shift+V to finish", "Pause to finish", "Let go to finish"). */
function voiceEndHint(): string {
  const v = S.voice;
  if (!v) return '';
  if (v.ends === 'hold' || v.hold) return t('island.voice.hold_hint');
  if (v.ends === 'key' || v.ends === undefined) return S.hotkeys.voice ? t('island.voice.hint_key', { key: S.hotkeys.voice }) : t('island.voice.hint_done');
  return t('island.voice.hint_pause');
}

/** …with Esc in its first seconds, and in its last minute the time left (IslandContent.voiceHint). */
function voiceHint(): string {
  const v = S.voice;
  if (!v) return '';
  let s = voiceEndHint();
  if (voiceElapsed() < 10) s += ` · ${t('island.voice.esc_hint')}`;
  const limit = (v as { limit?: number }).limit;
  if (limit) {
    const left = Math.max(0, Math.ceil(limit - voiceElapsed()));
    if (left <= 60) s += ` · ${t('island.voice.time_left', { time: clock(left) })}`;
  }
  return s;
}

// the take just ended: the dot and the time turn into the ok check and its length for 1.6 s (RecordingDone)
let recDone: null | { text: string; until: number } = null;

function ears(): { l: string; r: string } {
  // the moment wins over a state that still says recording (its refresh can land just after rec_done)
  if (recDone && performance.now() < recDone.until) {
    return { l: `<i class="done-disc" aria-hidden="true">${ic('check', 10)}</i><span class="time">${esc(recDone.text)}</span>`, r: '' };
  }
  if (S.recording) {
    const r = S.recording;
    // the level: four bars resting at staggered heights in silence, lit with the voice (system.md "Recording ear")
    let right = r.shots > 0 ? `${ic('snap', 15)}<span class="num">${num(r.shots)}</span>` : r.paused ? '' : `<span class="meter ear-meter" data-meter>${'<i></i>'.repeat(4)}</span>`;
    // the pen on: its pencil in mint leads the right ear (the Mac's C36), in the meter's place
    if (r.pen && !r.paused) right = `${ic('pencil', 15, 'mint')}${r.shots > 0 ? right : ''}`;
    // paused: the pause bars, not the dot (never colour alone)
    const mark = r.paused ? '<i class="rec-pause" aria-hidden="true"><b></b><b></b></i>' : '<i class="rec-dot"></i>';
    return { l: `${mark}<span class="time${r.paused ? ' attn-t' : ''}" data-clock="rec">${clock(recElapsed())}</span>`, r: right };
  }
  if (S.voice && open && !drawer) {
    // one live meter at a time: the open island has the big waveform, so the ear shows the mic there
    return { l: ic('mic', 15, 'mint'), r: `<span class="time" data-clock="voice">${clock(voiceElapsed())}</span>` };
  }
  if (S.voice) {
    const hint = voiceElapsed() < VOICE_HINT_S;
    return {
      l: `${mascotHtml('listening', { size: 24 })}${waveHtml(7)}`,
      r: hint ? `<span class="sub" data-voice-end>${esc(voiceEndHint())}</span>` : `<span class="time" data-clock="voice">${clock(voiceElapsed())}</span>`,
    };
  }
  // "Sent": Peep done on the left, the keyboard, ✓ and the word on the right (island.dictation-sent keeps Peep in the
  // left ear; the keyboard says where it went, small and in the ears' white), for 1.6 s
  // a done line after a take ("✓ Copied") is the same moment without the keyboard (the Mac's Island.toast → earMoment)
  if (moment && S.dictation?.phase !== 'listening') {
    const kb = moment.lead === 'keyboard' ? ic('keyboard', 16, 'kb') : '';
    // "Copied · Ctrl+V to paste": the word semibold, the hint after " · " in secondary white (one moment, two weights)
    const cut = moment.text.indexOf(' · ');
    const word = cut > 0 ? moment.text.slice(0, cut) : moment.text;
    const sub = cut > 0 ? `<span class="sub"> · ${esc(moment.text.slice(cut + 3))}</span>` : '';
    return { l: mascotHtml('done', { size: 24 }), r: `<span class="moment">${kb}${ic('check', 12, 'ok')}<span class="word">${esc(word)}${sub}</span></span>` };
  }
  // Copy Text / Translate reading: Peep thinks, three dots (the cards' count stays on the right)
  if (readingUntil) return { l: mascotHtml('thinking', { size: 24 }), r: `<span class="dots"><i></i><i></i><i></i></span>${cardCount() && !quietAtRest() ? cardsEar() : ''}` };
  if (S.dictation) {
    const d = S.dictation;
    if (d.phase === 'listening') {
      return { l: `${mascotHtml('talking', { size: 24, level: true })}${waveHtml(5, 'mirror')}`, r: `${dictMarks()}${dictClockHtml()}` };
    }
    // transcribing, polishing: Peep thinks (its eye looks round), three dots
    return { l: mascotHtml('thinking', { size: 24 }), r: `<span class="dots" aria-label="${esc(t(`island.dictation.${d.phase}`))}"><i></i><i></i><i></i></span>` };
  }
  // the right ear's one thing: a run that just ended, Peep thinking with the count, the inbox's news
  let lr: { l: string; r: string } | null = null;
  if (performance.now() < helloUntil) lr = { l: '', r: `<span class="hello">${mascotHtml('hello', { size: 24 })}<span>${esc(t('island.hello'))}</span></span>` };
  else if (sorted) lr = { l: mascotHtml(sorted.ok ? 'done' : 'error', { size: 24 }), r: sorted.n ? `<span class="num">+${num(sorted.n)}</span>` : '' };
  else if (S.hatching && !quietAtRest()) lr = { l: mascotHtml('thinking', { size: 24 }), r: `<span class="num">${num(S.hatching)}</span>` };
  else if (news) lr = { l: ic('inbox', 15), r: `<span class="num">+${num(news.n)}</span>` };
  if (cardCount() && !quietAtRest()) {
    // the cards' count is one thing (their stack and the number together); the left ear when nothing else is there
    if (!lr) return { l: cardsEar(), r: '' };
    // Peep thinking and its count, its hop and "+n", the inbox's news: one thing, on the left
    return { l: lr.l + lr.r, r: cardsEar() };
  }
  return lr ?? { l: '', r: '' };
}

function pillHtml(): string {
  const e = ears();
  if (!e.l && !e.r) return '';
  return `<span class="ear l">${e.l}</span><span class="ear r">${e.r}</span>`;
}

// ------------------------------------------------------------------ toasts in the island (IslandContent.buildToast)
function toastHtml(): string {
  const tt = toastNow!;
  const parts = tt.text.split('\n');
  let headline = parts[0];
  let detail = parts.length > 1 ? parts.slice(1).join(' · ') : '';
  const cut = !detail ? headline.indexOf(' · ') : -1;
  let head = cut > 0 ? headline.slice(0, cut) : headline;
  const rest = cut > 0 ? headline.slice(cut + 3) : '';
  // still at work: the spinner in the slot — a line whose headline (before " · ") ends in "…" with nothing to do about
  // it ("Still recognizing… · Esc to cancel"), or one Rust marks so ("Downloading the speech model (950 MB) · …")
  const working = tt.mark === 'spinner' || (!tt.action && !tt.mark && !tt.peep && head.endsWith('…'));
  if (working && head.endsWith('…')) head = head.slice(0, -1);
  if (detail.endsWith('…')) detail = detail.slice(0, -1);
  // "headline · detail": two weights on one line (the headline semibold, the detail regular in secondary white)
  const headHtml = `<span class="lead-t">${nobreakNames(esc(head))}</span>${rest ? `<span class="detail-inline"> · ${nobreakNames(esc(rest))}</span>` : ''}`;
  // the slot is never a hole: a line with no mark of its own leads with its source's quiet glyph — for dictation the
  // grey Peep (Mac D13-01, D19-01, D27-01) — so its text starts on the same column as every other line's
  const place = tt.project ? (tt.project === 'inbox' ? null : (S.projects.find((p) => p.id === tt.project) ?? { id: tt.project, name: '', key: '' })) : undefined;
  const lead = tt.peep
    ? `<span class="slot art">${mascotHtml(tt.peep, { size: 28 })}</span>`
    : working
      ? `<span class="slot quiet-peep">${mascotHtml('thinking', { size: 20 })}</span>`
      : place !== undefined
        ? `<span class="slot">${place ? folderGlyph(place) : `<span class="dim">${ringGlyph()}</span>`}</span>`
        : tt.mark && tt.mark !== 'spinner' && tt.mark !== 'peep'
          ? `<span class="slot mark-${tt.mark}">${ic(tt.mark as IconName, 15)}</span>`
          : `<span class="slot quiet-peep">${mascotHtml('idle', { size: 18 })}</span>`;
  const second = tt.action && tt.second ? `<button class="quiet" data-a="toast.second">${esc(t(tt.second.label, tt.second.vars))}</button>` : '';
  const act = tt.action ? `${second}<button class="quiet${second ? ' fill' : ''}" data-a="toast.act">${esc(t(tt.action.label, tt.action.vars))}</button>` : '';
  // two answers: a question (IslandContent.buildQuestion) — the text on its own line at the open width, the answers
  // on a row of their own under it, right-aligned on the 14 px edge
  const q = !!second;
  return `<div class="toastrow${tt.peep ? ' has-art' : ''}${q ? ' question' : ''}">${lead}<span class="ttext"><span class="hl">${headHtml}</span>${
    detail ? `<span class="detail">${esc(detail)}</span>` : ''
  }</span>${act ? (q ? `<span class="answers">${act}</span>` : act) : ''}</div>`;
}

/** Project names in a line are one unbreakable run ("api-server" never splits at its hyphen). */
function nobreakNames(html: string): string {
  let out = html;
  for (const p of S.projects) {
    const n = esc(p.name);
    if (n.length > 2 && out.includes(n)) out = out.split(n).join(`<span class="nb">${n}</span>`);
  }
  return out;
}

// ------------------------------------------------------------------ the open island: home (IslandContent.buildHome)
function toolBtn(a: string, glyph: string, label: string, key?: string) {
  return `<button class="tool" data-a="${a}" aria-label="${esc(label)}" data-tip="${esc(tipKey(label, key))}">${glyph}</button>`;
}

function projectChip() {
  const p = S.project;
  // one name for nothing chosen: "Unassigned" (the one term everywhere), dimmed; a context, not a button-pill
  // its folder gone: captures hang as cards meanwhile — the chip says so, dimmed, and the switcher offers Locate…
  const gone = p?.exists === false || S.projects.find((x) => x.id === p?.id)?.exists === false;
  return `<button class="proj${p && !gone ? '' : ' none'}" data-a="switch" aria-haspopup="listbox" aria-label="${esc(t('island.project_ax', { name: p ? p.name : t('island.unassigned') }))}" data-tip="${esc(gone ? t('island.drawer.missing_sub') : tipKey(t('island.switch'), S.hotkeys.project))}">
    <span class="pname">${esc(p ? p.name : t('island.unassigned'))}</span>${ic('chevron-down', 11, 'chev')}</button>`;
}

function jobRow(j: JobRow) {
  const title = j.title || t(`job.type.${j.type}`);
  const step = j.step ? t(`job.step.${j.step}`) : '';
  const p = typeof j.progress === 'number' ? Math.max(0, Math.min(1, j.progress)) : 0;
  return `<button class="row job" data-a="open.job" data-job="${esc(j.id)}">
    <span class="lead"><i class="spinner"></i></span>
    <span class="txt"><span class="title">${esc(title)}${step ? `<span class="status">  ${esc(step)}</span>` : ''}</span>
    <span class="prog"><i style="width:${(p * 100).toFixed(0)}%"></i></span></span></button>`;
}

function hkHint(key: string | undefined, label: string) {
  return key ? t('island.hint', { key, label }) : null;
}

function homeBody() {
  // Peep at the row's left end whenever the island is open (BA-17): thinking while captures are organized, as in the ear
  const head = `<div class="head">${mascotHtml(S.hatching ? 'thinking' : 'idle', { size: 24, className: 'home' })}${projectChip()}<span class="grow"></span>
    ${toolBtn('record', recordGlyph(), t('island.record'), S.hotkeys.record)}
    ${toolBtn('snap', ic('snap', 15), t('island.snap'), S.hotkeys.snap)}
    ${toolBtn('voice', ic('mic', 15), t('island.voice'), S.hotkeys.voice)}</div>`;
  const rows: string[] = [];
  for (const j of S.jobs.slice(0, 3)) rows.push(jobRow(j));
  const n = cardCount();
  if (n) {
    // the cards waiting, and the view's one filled button: with a current project they are organized into it; with
    // none, into Unassigned with a suggested project each (one agent run for all)
    const p = S.project;
    const tip = p ? t('island.organize_tip', { project: p.name }) : plural('island.organize_all_tip', n);
    rows.push(`<div class="row cards-row" data-a="cards.reveal" role="button" tabindex="-1">
      <span class="lead">${ic('cards', 15)}</span><span class="txt"><span class="title">${esc(plural('island.cards_waiting', n))}</span></span>
      <button class="primary" data-a="cards.organize" data-tip="${esc(tip)}">${ic('spark', 14)}<span>${esc(t('island.organize'))}</span></button></div>`);
  }
  if (S.toReview > 0) {
    rows.push(`<button class="row" data-a="open.inbox" aria-label="${esc(t('island.inbox') + ', ' + plural('island.to_review', S.toReview))}">
      <span class="lead">${ic('inbox', 15)}</span><span class="txt"><span class="title">${esc(t('island.inbox'))}</span></span>
      <span class="acc">${num(S.toReview)}</span>${ic('chevron-right', 13, 'chev')}</button>`);
  }
  if (!rows.length) {
    // nothing going on: what the keys do, on the text column
    const hint = [hkHint(S.hotkeys.snap, t('island.snap')), hkHint(S.hotkeys.voice, t('island.voice')), hkHint(S.hotkeys.project, t('island.switch'))]
      .filter(Boolean)
      .join('   ·   ');
    if (hint) rows.push(`<div class="keys">${esc(hint)}</div>`);
  }
  return head + rows.join('');
}

// ------------------------------------------------------------------ recording (IslandContent.buildRecording)
function recBody() {
  const r = S.recording!;
  if (confirmDiscard) {
    // the question alone on its line, what goes with it on a quiet second line, then Discard · Start Over · Keep
    // Recording ↩ — the last where Finish was, so nothing destructive lands under the hand that stops
    const lost = r.shots > 0 ? plural('island.rec.snaps', r.shots) : '';
    return `<div class="rec-body"><div class="q">${esc(t('island.rec.discard_q'))}</div>${lost ? `<div class="q2">${esc(t('island.rec.discard_also', { what: lost }))}</div>` : ''}
      <div class="answers"><span class="grow"></span>
      <button class="pillbtn err" data-a="discard.yes">${esc(t('island.rec.discard'))}</button>
      <button class="pillbtn" data-a="restart">${esc(t('island.rec.restart'))}</button>
      <button class="primary" data-a="discard.no"><span>${esc(t('island.rec.keep'))}</span><span class="k">↩</span></button></div></div>`;
  }
  const pause = r.paused
    ? `<button class="circle resume" data-a="resume" aria-label="${esc(t('island.rec.resume'))}" data-tip="${esc(t('island.rec.resume'))}">${ic('play', 15)}</button>`
    : `<button class="circle" data-a="pause" aria-label="${esc(t('island.rec.pause'))}" data-tip="${esc(t('island.rec.pause'))}">${ic('pause', 15)}</button>`;
  const snap = `<button class="circle" data-a="snap" aria-label="${esc(t('island.rec.snap_note'))}" data-tip="${esc(tipKey(t('island.rec.snap_note'), S.hotkeys.snap))}">${ic('snap', 15)}</button>`;
  const more = `<button class="circle" data-a="rec.more" aria-label="${esc(t('island.rec.more'))}" data-tip="${esc(t('island.rec.more'))}">${ic('more', 15)}</button>`;
  // where it goes once finished: Finish's tooltip (the ··· menu's Goes to… changes it)
  const where = t('island.rec.goes_after', { project: S.project?.name ?? t('island.unassigned') });
  const fin = `<button class="finish${r.paused ? ' quiet-fin' : ''}" data-a="stop" data-tip="${esc(where)}">${ic('stop', 13)}<span>${esc(t('island.rec.finish'))}</span></button>`;
  return `<div class="rec-body"><div class="controls">${pause}${snap}<span class="grow"></span>${more}${fin}</div>${penLine()}</div>`;
}

/** The pen's quiet key line under the controls (the Mac's KeyLine): on — "Pen on · [Esc] Pen off"; off — its key and
 *  the shapes, the first three takes only. */
let penTakes = (() => {
  try {
    return Number(localStorage.getItem('blurt.penHintTakes') ?? 0) || 0;
  } catch {
    return 0;
  }
})();
function penLine(): string {
  const r = S.recording!;
  const cap = (k: string) => `<kbd>${esc(k)}</kbd>`;
  // on: the pencil in the ear says so; the line is the keys (the Mac's KeyLine: keycap + label pairs)
  if (r.pen && !r.paused) return `<div class="penline">${cap('Esc')}<span>${esc(t('island.rec.pen_off'))}</span>${cap('Shift')}<span>${esc(t('island.rec.pen_box'))}</span>${cap('Alt')}<span>${esc(t('island.rec.pen_ellipse'))}</span></div>`;
  if (!S.hotkeys.pen || penTakes > 3 || r.paused) return '';
  return `<div class="penline">${cap(S.hotkeys.pen)}<span>${esc(t('island.rec.pen_keys'))}</span></div>`;
}

// ------------------------------------------------------------------ voice note (IslandContent.buildVoice)
function voiceBody() {
  const v = S.voice!;
  const holding = v.ends === 'hold' || !!v.hold;
  const done = holding ? '' : `<button class="primary" data-a="voice.stop" data-tip="${esc(tipKey(t('island.voice.done_tip'), S.hotkeys.voice))}">${ic('check', 14)}<span>${esc(t('island.voice.done'))}</span></button>`;
  const structured = (v as { structured?: boolean }).structured;
  const chip =
    structured === undefined
      ? ''
      : `<button class="chip${structured ? ' on' : ''}" data-a="voice.structured" aria-pressed="${structured}">${ic('list', 13)}<span>${esc(t('island.voice.structured'))}</span></button>`;
  const dest = S.project ? t('island.voice.goes_to', { project: S.project.name }) : t('island.voice.goes_card');
  return `<div class="voice-body"><div class="vrow">${mascotHtml('listening', { size: 32 })}${waveHtml(40, 'big track')}${done}</div>
    <div class="vrow2">${chip}<span class="sub" data-voice-hint>${esc(voiceHint())}</span><span class="grow"></span><span class="sub dest" title="${esc(dest)}">${esc(dest)}</span></div></div>`;
}

// ------------------------------------------------------------------ the drawer: switcher and drop targets
function projectRows(): { rows: ProjectRef[]; more: boolean } {
  const q = filter.trim().toLowerCase();
  const found = S.projects.filter((p) => !q || p.name.toLowerCase().includes(q) || p.key.toLowerCase().startsWith(q));
  // a project whose folder is gone can't take anything: after the ones that can (never the first row, the default)
  const all = [...found.filter((p) => p.exists !== false), ...found.filter((p) => p.exists === false)];
  return q || showAll ? { rows: all, more: false } : { rows: all.slice(0, 8), more: all.length > 8 };
}

/** The drawer's choosable rows, in keyboard order: projects, More…, then (switcher) Unassigned and Add Project…. */
function choices(): string[] {
  const { rows, more } = projectRows();
  const ids = rows.map((p) => `project:${p.id}`);
  if (more) ids.push('more');
  if (drawer === 'switch') ids.push(...(pickFor ? ['none'] : ['none', 'add']));
  else ids.push('inbox', 'organize');
  return ids;
}

function drawerRows(): string {
  const cur = pickFor ? pickFor.current : (S.project?.id ?? null);
  const ids = choices();
  const sel = (id: string) => (drawer === 'switch' && ids[selIx] === id ? ' sel' : '');
  const { rows, more } = projectRows();
  const items: string[] = [];
  for (const p of rows) {
    const id = `project:${p.id}`;
    const checked = drawer === 'switch' && cur === p.id;
    // the project's key only on the row being chosen, never beside the check (one trailing mark)
    // a project whose folder is gone: said, dimmed, and chosen = Locate… (MissingFolder)
    const gone = p.exists === false;
    items.push(`<button class="row prj${sel(id)}${gone ? ' gone' : ''}" role="option" data-c="${esc(id)}" data-drop="${esc(id)}" aria-selected="${checked}">
      <span class="lead">${placeGlyph(p)}</span><span class="txt"><span class="title">${esc(p.name)}</span>${gone ? `<span class="sub">${esc(t('island.drawer.missing_sub'))}</span>` : ''}</span>
      ${checked ? ic('check', 14, 'tick') : `<span class="key">${esc(p.key)}</span>`}</button>`);
  }
  if (more) items.push(`<button class="row${sel('more')}" data-c="more"><span class="lead">${ic('more', 15)}</span><span class="txt"><span class="title">${esc(t('island.drawer.more'))}</span></span></button>`);
  if (!S.projects.length) items.push(`<div class="keys">${esc(t('island.drawer.no_projects'))}</div>`);
  if (drawer === 'switch') {
    // Unassigned comes last, under a line, in every project picker; then Add Project…
    items.push('<div class="sep"></div>');
    items.push(`<button class="row${sel('none')}" role="option" data-c="none" aria-selected="${cur === null}" data-tip="${esc(t('island.drawer.none_sub'))}">
      <span class="lead dim">${ringGlyph()}</span><span class="txt"><span class="title">${esc(t('island.unassigned'))}</span></span>${cur === null ? ic('check', 14, 'tick') : ''}</button>`);
    // (a pick for something else — File to, Move to — is one choice of a place: Add Project… is the switcher's)
    if (!pickFor) items.push(`<button class="row${sel('add')}" data-c="add"><span class="lead">${ic('folder-plus', 15)}</span><span class="txt"><span class="title">${esc(t('island.drawer.add_project'))}</span></span><span class="acc">Ctrl+O</span></button>`);
  } else {
    items.push('<div class="sep"></div>');
    items.push(`<div class="row target" data-drop="inbox" data-tip="${esc(t('island.drawer.inbox_sub'))}"><span class="lead dim">${ringGlyph()}</span><span class="txt"><span class="title">${esc(t('island.unassigned'))}</span></span></div>`);
    items.push(`<div class="row target" data-drop="organize"><span class="lead mint">${ic('spark', 15)}</span><span class="txt"><span class="title">${esc(t('island.organize'))}</span><span class="sub">${esc(plural('island.drawer.organize_sub', dropCount()))}</span></span></div>`);
  }
  return items.join('');
}

function drawerHtml() {
  if (drawer === 'switch') {
    // the filter field in the first row (the magnifier on the icon column), what this is across from it
    return `<div class="dhead"><label class="filter">${ic('search', 15)}<input type="text" spellcheck="false" autocomplete="off" placeholder="${esc(t('island.drawer.filter'))}" value="${esc(filter)}" aria-label="${esc(t('island.drawer.filter'))}"></label>
      <span class="dtitle">${esc(t(pickFor?.title ?? 'island.drawer.switch_title'))}</span></div><div class="list" role="listbox">${drawerRows()}</div>`;
  }
  return `<div class="dhead"><span class="dtitle left">${esc(t('island.drawer.drop_title'))}</span></div><div class="list">${drawerRows()}</div>`;
}

const dropCount = () => (dragging ? withSelection(dragging).length : cardCount());

function bodyHtml() {
  if (drawer) return drawerHtml();
  if (toastShows()) return toastHtml();
  if (!open) return '';
  if (S.recording) return recBody();
  if (S.voice) return voiceBody();
  return homeBody();
}

// ------------------------------------------------------------------ the live text (LiveTranscript)
function renderLive() {
  const lt = liveText;
  livePanel.classList.toggle('shown', !!lt);
  if (!lt) {
    livePanel.innerHTML = '';
    liveTop = 0;
    return;
  }
  livePanel.classList.toggle('typed', lt.typed);
  livePanel.classList.toggle('under-open', island.classList.contains('open'));
  // the last three lines while it listens (newest at the bottom); once typed, from the top, up to eight
  // typed: the ok check goes with the last few characters (one unbreakable run), so it never wraps onto a line alone
  const tail = lt.typed ? (/\S{1,4}$/u.exec(lt.text)?.[0] ?? '') : '';
  const head = tail ? lt.text.slice(0, lt.text.length - tail.length) : lt.text;
  livePanel.innerHTML = `<div class="live-in" style="--lines:${lt.typed ? 8 : 3}"><span class="done">${esc(head)}${
    lt.typed ? `<span class="tail">${esc(tail)}${ic('check', 13, 'ok in')}</span>` : ''
  }</span>${lt.partial ? `<span class="partial">${esc(lt.partial)}</span>` : ''}${lt.typed ? '' : '<i class="caret" aria-hidden="true"></i>'}</div>`;
  const inner = livePanel.firstElementChild as HTMLElement;
  if (!lt.typed) inner.scrollTop = inner.scrollHeight;
  inner.classList.toggle('above', !lt.typed && inner.scrollTop > 0);
  inner.classList.toggle('more', lt.typed && inner.scrollHeight > inner.clientHeight + 2);
  placeLive();
}

/** The island's lower half: 6 px under it, in its width family (IslandLayout.livePanelWidth), below the hanging cards
 *  when they are down — and once its text has gone in, it stays where it is. */
function placeLive() {
  if (!liveText) return;
  const ib = island.getBoundingClientRect();
  const w = island.classList.contains('open') ? ib.width : Math.min(OPEN_W, Math.max(LIVE_CAPSULE_W, restingW));
  livePanel.style.width = `${Math.round(Math.min(w, (stage.clientWidth || innerWidth) - 32))}px`;
  if (liveText.typed && liveTop) {
    // it doesn't move sideways or up once its text went in — but a line that comes after it ("Sent", "Sounds like a
    // list") grows the island, and the panel moves down under it instead of sliding beneath it
    liveTop = Math.max(liveTop, Math.round(TOP + islandH + 6));
    livePanel.style.top = `${liveTop}px`;
    return;
  }
  let top = TOP + islandH + 6;
  if (downK.value > 0.5) for (const l of hanging()) if (l.el.style.display !== 'none') top = Math.max(top, l.face.getBoundingClientRect().bottom + 10);
  liveTop = Math.round(top);
  livePanel.style.top = `${liveTop}px`;
}

// ------------------------------------------------------------------ render
let lastBody = '';
let lastPill = '';
let restingW = PILL_MIN_W;
function render() {
  const shown = visible();
  const html = shown ? bodyHtml() : '';
  const expanded = !!html;
  island.classList.toggle('shown', shown);
  island.classList.toggle('open', expanded && (open || !!drawer));
  island.classList.toggle('toasting', expanded && !open && !drawer);
  // a line while a dictation is on goes under the ears (Peep, the level, the clock; or Peep thinking and the dots while
  // it recognizes or polishes — "Still recognizing · Esc to cancel" belongs to the take still working), as on the Mac
  island.classList.toggle('ears-toast', expanded && !open && !drawer && toastShows() && (!!S.dictation || (!S.dictation && !S.recording && !S.voice && cardCount() > 0)));
  // a picker or a snap's note is up: the island steps back (the Mac's picker covers it)
  island.classList.toggle('stepback', busyCapture && !open && !drawer);
  island.dataset.mode = S.recording ? 'rec' : S.dictation ? 'dict' : S.voice ? 'voice' : 'idle';
  // the recording / voice note island open: its ears ride out to the open shape's corners, over the body's edges
  island.classList.toggle('ears-open', expanded && open && !drawer && !toastShows() && !!(S.recording || S.voice));
  // the listening glow: only while blurt listens (a voice note, a dictation), never while recording or idle
  // a dictation keeps the same glow from listening through recognizing and polishing (only Peep and the right ear
  // change), and it goes with the take
  stage.dataset.glow = shown && (S.voice || S.dictation) && !S.recording ? '1' : '0';
  stage.dataset.mode = island.dataset.mode;
  const ph = pillHtml();
  if (ph !== lastPill) {
    // only when it changed: a one-shot mascot clip (Peep's hop) must not restart on every state op
    pill.innerHTML = `<span class="pill-in">${ph}</span>`;
    lastPill = ph;
  }
  if (drawer === 'switch' && body.querySelector('.filter input') && expanded) {
    body.querySelector('.list')!.innerHTML = drawerRows(); // keep the filter field (focus, caret) while typing
  } else if (html !== lastBody) {
    body.innerHTML = html ? `<div class="body-in${toastShows() && !drawer ? ' toast-in' : ''}">${html}</div>` : '';
    lastBody = html;
    if (drawer === 'switch') {
      const input = body.querySelector<HTMLInputElement>('.filter input');
      input?.focus();
      input?.addEventListener('input', () => {
        filter = input.value;
        selIx = Math.max(0, choices().findIndex((c) => c.startsWith('project:')));
        render();
      });
    }
  }
  size(expanded);
  renderLive();
  ticks();
  kick();
  paintNow();
}

/** The island's box: measured content, animated by CSS (width / height / radius transitions). */
let islandH = PILL_H;
let remeasure = 0;
let takeLineW = 0; // the widest line under this take's ears so far
/** A toast row's width on one line (its slot, its text unwrapped, its buttons): measured with the text on one line —
 *  a clamped -webkit-box reports a narrower max-content than its line needs, and the line then wrapped one character
 *  onto a second line ("语音模型无响 / 应"). The content is left at that width; the caller holds it. */
function rowWidth(content: HTMLElement): number {
  const tr = content.querySelector<HTMLElement>('.toastrow');
  if (!tr) return 0;
  const held = content.style.width;
  content.style.width = '';
  content.classList.add('measuring');
  const w = Math.ceil(tr.getBoundingClientRect().width);
  content.classList.remove('measuring');
  content.style.width = held;
  return w;
}
function size(expanded: boolean) {
  const inner = pill.querySelector<HTMLElement>('.pill-in');
  const content = body.querySelector<HTMLElement>('.body-in');
  const toasting = expanded && !open && !drawer;
  let w: number;
  let h: number;
  // the ears at their own width: .pill-in is at least as wide as the island (min-width: 100%), so measured as it
  // stands it would report the open width back and the resting pill would never shrink from it again
  let earsW = 0;
  if (inner && inner.children.length) {
    inner.style.minWidth = '0';
    earsW = Math.ceil(inner.scrollWidth);
    inner.style.minWidth = '';
  }
  const lone = !!inner && inner.querySelectorAll(':scope > .ear:not(:empty)').length === 1;
  restingW = earsW ? Math.max(lone ? LONE_MIN_W : PILL_MIN_W, earsW) : performance.now() < peekUntil || hovering ? PEEK_W : PILL_MIN_W;
  if (liveText && earsW) restingW = Math.max(restingW, LIVE_CAPSULE_W);
  if (expanded && !toasting) {
    w = OPEN_W;
    h = content ? Math.min(MAX_H, content.offsetHeight) : PILL_H;
  } else if (toasting && content) {
    // a line hugs what it says (its slot, text and button, 14 px after the last): no empty floor to the right of
    // "Cancelled · Undo"; under the listening ears it keeps their width family
    const earsToast = island.classList.contains('ears-toast');
    w = Math.min(OPEN_W, Math.max(earsToast ? EARS_LINE_MIN_W : PILL_MIN_W, rowWidth(content)));
    if (earsToast) w = Math.max(w, restingW);
    // one width for the take: a line under the ears grows the island to the widest line this take has needed and
    // never shrinks it mid-take, so the ears don't jump sideways when one line replaces another (the Mac's notch strip)
    if (earsToast && S.dictation) w = takeLineW = Math.max(w, takeLineW);
    content.style.width = `${w}px`;
    h = content.offsetHeight + (island.classList.contains('ears-toast') ? PILL_H : 0);
    // measured again a frame later: a CJK face that arrives after the first layout makes the line wider
    if (!remeasure) {
      remeasure = requestAnimationFrame(() => {
        remeasure = 0;
        const c2 = body.querySelector<HTMLElement>('.body-in');
        if (c2 && c2 === content && w < OPEN_W && rowWidth(c2) > w) size(true);
      });
    }
  } else {
    w = restingW;
    h = PILL_H;
  }
  if (!S.dictation) takeLineW = 0;
  island.style.width = `${w}px`;
  island.style.height = `${h}px`;
  hot.style.width = `${w}px`;
  if (glow) {
    glow.style.width = `${w}px`;
    glow.style.height = `${h}px`;
  }
  islandH = h;
}

const islandBottom = () => (visible() ? TOP + islandH : TOP + PILL_H);

/** Live numbers (clocks, the waveform, the meter) without re-rendering. */
function ticks() {
  for (const el of island.querySelectorAll<HTMLElement>('[data-voice-hint]')) {
    const h = voiceHint();
    if (el.textContent !== h) el.textContent = h;
  }
  if (S.voice && voiceElapsed() >= VOICE_HINT_S && island.querySelector('[data-voice-end]')) render();
  for (const el of island.querySelectorAll<HTMLElement>('[data-clock]')) {
    if (el.dataset.clock === 'dict') el.classList.toggle('neg', dictCountdown());
    el.textContent = el.dataset.clock === 'dict' ? dictClock() : clock(el.dataset.clock === 'rec' ? recElapsed() : voiceElapsed());
  }
  for (const m of island.querySelectorAll<HTMLElement>('[data-meter]')) {
    const lit = S.recording?.paused ? 0 : meterBars(level, m.children.length);
    [...m.children].forEach((b, i) => b.classList.toggle('on', i < lit));
  }
  // the voice note's track (C24): the newest bar arrives at the right, by Done, and the history scrolls left into the
  // hairline; silence draws a 2 px tick, so it still reads as listening
  const now = performance.now();
  if (S.voice && now - waveAt >= 120) {
    waveAt = now;
    waveHist.push(Math.min(1, level * 9));
    if (waveHist.length > 80) waveHist.shift();
  }
  for (const w of island.querySelectorAll<HTMLElement>('[data-wave]')) {
    const bars = [...w.children] as HTMLElement[];
    const track = w.classList.contains('track');
    if (track) {
      const n = bars.length;
      bars.forEach((b, i) => {
        const v = waveHist[waveHist.length - n + i];
        b.style.height = v === undefined ? '0px' : `max(2px, ${(Math.min(1, v + 0.06) * 100).toFixed(1)}%)`;
      });
      continue;
    }
    bars.forEach((b, i) => {
      const k = 0.35 + 0.65 * Math.abs(Math.sin(now / 160 + i * 1.3));
      const v = level * 9 * k;
      b.style.height = `${(Math.max(0.18, Math.min(1, v + 0.12)) * 100).toFixed(1)}%`;
    });
  }
}
const waveHist: number[] = [];
let waveAt = 0;
setInterval(() => {
  if (S.recording || S.voice || S.dictation) ticks();
}, 250);

// ------------------------------------------------------------------ expand / collapse (Island.poll)
function hoverIn() {
  if (hovering) return;
  hovering = true;
  hoverSince = performance.now();
  clearTimeout(hoverTimer);
  if (holdClosed) return render();
  // dictation never opens the island: ears only, so the app being typed into keeps the whole screen
  if (S.dictation) return render();
  // resting on the ear's count opens it a little later, so the count can still be clicked
  const dwell = island.querySelector('.earbtn:hover') ? CardReveal.earDwell : HOVER_IN;
  hoverTimer = window.setTimeout(() => {
    if (!hovering || open || drawer) return;
    if (toastNow && toastShows()) {
      // a toast under the pointer holds for a moment; resting longer is asking for the island
      hoverTimer = window.setTimeout(() => {
        if (!hovering) return;
        dismissToast();
        setOpen(true);
      }, TOAST_HOVER_HOLD);
      return;
    }
    setOpen(true);
  }, dwell);
  render();
}
island.addEventListener('mouseenter', hoverIn);
hot.addEventListener('mouseenter', hoverIn);
/** (the menu that was up has gone: the island folds now, if the pointer is still away) */
function hoverOut2() {
  if (hovering || cardHover || menuHover || !menuEl.hidden || drawer === 'drop' || dragging || confirmDiscard) return;
  setOpen(false);
}
function hoverOut() {
  if (!hovering) return;
  hovering = false;
  clearTimeout(hoverTimer);
  menuAway();
  hoverTimer = window.setTimeout(() => {
    if (drawer === 'drop' || dragging || confirmDiscard || menuHover) return;
    if (!menuEl.hidden) return void (hoverTimer = window.setTimeout(hoverOut2, 950));
    if (drawer === 'switch' && document.activeElement?.closest('.filter')) return; // typing a filter
    if (cardHover) return; // the pointer went down onto the hanging cards: the island stays open over them
    setOpen(false);
  }, HOVER_OUT);
  render();
}
island.addEventListener('mouseleave', (e) => {
  if (e.relatedTarget !== hot) hoverOut();
});
hot.addEventListener('mouseleave', (e) => {
  if (e.relatedTarget !== island && !island.contains(e.relatedTarget as Node | null)) hoverOut();
});

function setOpen(on: boolean) {
  if (on) revealCards(false);
  if (on === open) return render();
  open = on;
  if (!on) {
    if (confirmDiscard) setConfirm(false);
    if (drawer === 'switch') closeSwitcher();
    closeMenu();
    showAll = false;
  }
  lastBody = '';
  render();
}

function setConfirm(on: boolean) {
  confirmDiscard = on;
  // the question takes the keyboard while it shows (↩ = Keep Recording, Esc closes): the island never does otherwise
  void host.emit(EV.action, { action: 'keyboard', on });
  lastBody = '';
}

function openSwitcher() {
  drawer = 'switch';
  filter = '';
  showAll = false;
  const ids = choices();
  selIx = Math.max(0, ids.indexOf(S.project ? `project:${S.project.id}` : 'none'));
  lastBody = '';
  void host.emit(EV.action, { action: 'keyboard', on: true });
  render();
}

/** The switcher as a picker for something else (the Mac's Island.Pick: "Move To" for a recording's Change, recording.md
 *  §6.2): its title, the place now checked; choosing sends `rec.move:<id>|<token>` instead of switching projects. */
let pickFor: { title: string; current: string | null; token: string } | null = null;
function openPicker(p: { title: string; current: string | null; token: string }) {
  if (drawer === 'switch') closeSwitcher(); // the switcher's head is drawn once: start it again with the pick's title
  pickFor = p;
  openSwitcher();
  selIx = Math.max(0, choices().indexOf(p.current ? `project:${p.current}` : 'none'));
  open = true;
  render();
}

function closeSwitcher() {
  if (drawer !== 'switch') return;
  pickFor = null;
  drawer = null;
  filter = '';
  lastBody = '';
  void host.emit(EV.action, { action: 'keyboard', on: false }); // the island goes back to never taking focus
}

function choose(id: string) {
  if (id === 'more') {
    showAll = true;
    lastBody = '';
    return render();
  }
  if (pickFor && id !== 'add') {
    void host.emit(EV.action, { action: `rec.move:${id === 'none' ? 'inbox' : id.slice('project:'.length)}|${pickFor.token}` });
    closeSwitcher();
    open = false;
    return render();
  }
  if (id === 'add') {
    void host.emit(EV.action, { action: 'project.open' });
    closeSwitcher();
    open = false;
    return render();
  }
  const pid = id === 'none' ? 'auto' : id.slice('project:'.length);
  if (S.projects.find((p) => p.id === pid)?.exists === false) {
    // its folder is gone: where is it now? (becomes current once found; Cancel changes nothing)
    void host.emit(EV.action, { action: 'project.locate', id: pid, use: true });
    closeSwitcher();
    open = false;
    return render();
  }
  void host.emit(EV.action, { action: 'project.use', id: pid });
  S = { ...S, project: pid === 'auto' ? null : (S.projects.find((p) => p.id === pid) ?? S.project) };
  closeSwitcher();
  open = false;
  render();
}

addEventListener('keydown', (e) => {
  if (panel && panelKeyDown(e)) return;
  if (confirmDiscard) {
    if (e.key === 'Enter') {
      e.preventDefault();
      setConfirm(false);
      render();
    } else if (e.key === 'Escape') setOpen(false);
    return;
  }
  if (drawer !== 'switch') {
    if (e.key === 'Escape' && S.voice) void host.emit(EV.action, { action: 'voice.cancel' });
    return;
  }
  const ids = choices();
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    selIx = (selIx + (e.key === 'ArrowDown' ? 1 : -1) + ids.length) % Math.max(1, ids.length);
    render();
  } else if (e.key === 'Enter' && !e.isComposing && e.keyCode !== 229) {
    e.preventDefault();
    if (ids[selIx]) choose(ids[selIx]);
  } else if (e.key === 'Escape') {
    closeSwitcher();
    open = false;
    render();
  } else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'o') {
    e.preventDefault();
    choose('add');
  }
});

// WebKitGTK (Linux) sends no click when the pressed element was drawn again before the release (WebView2 sends it to
// what both have in common): a press and a release on the same action, with no click right after, is that click
let pressA: string | null = null;
island.addEventListener('pointerdown', (e) => (pressA = (e.target as HTMLElement).closest<HTMLElement>('[data-a]')?.dataset.a ?? null), true);
island.addEventListener(
  'pointerup',
  (e) => {
    const a = pressA;
    pressA = null;
    const target = a ? (document.elementFromPoint(e.clientX, e.clientY) as HTMLElement | null)?.closest<HTMLElement>('[data-a]') : null;
    if (!target || target.dataset.a !== a) return;
    let clicked = false;
    const mark = (ev: Event) => {
      // the click went to the action: done; to what the two had in common (the island): not the press it was
      if ((ev.target as HTMLElement).closest<HTMLElement>('[data-a]')?.dataset.a === a) clicked = true;
      else ev.stopImmediatePropagation();
    };
    island.addEventListener('click', mark, { once: true, capture: true });
    setTimeout(() => {
      island.removeEventListener('click', mark, true);
      if (!clicked && target.isConnected) target.click();
    }, 80);
  },
  true,
);

island.addEventListener('click', (e) => {
  const el = e.target as HTMLElement;
  const c = el.closest<HTMLElement>('[data-c]');
  if (c && drawer === 'switch') return choose(c.dataset.c!);
  const a = el.closest<HTMLElement>('[data-a]');
  if (!a) {
    // a click on the collapsed island (or on a toast's line) opens it right away
    if (!open && !drawer && !S.dictation) setOpen(true);
    return;
  }
  const action = a.dataset.a!;
  switch (action) {
    case 'switch':
      return drawer === 'switch' ? (closeSwitcher(), render()) : openSwitcher();
    case 'discard.no':
      setConfirm(false);
      return render();
    case 'discard.yes':
      setConfirm(false);
      void host.emit(EV.action, { action: 'discard' });
      return render();
    case 'restart':
      setConfirm(false);
      void host.emit(EV.action, { action: 'restart' });
      return render();
    case 'rec.more':
      return showRecMenu(a);
    case 'cards.reveal':
      e.stopPropagation();
      // the ear's count: the cards come down and stay; the open island's cards row: the Cards panel
      if (a.closest('.cards-row')) {
        setOpen(false);
        return openPanel('hanging', false);
      }
      setOpen(false);
      return revealCards(true);
    case 'cards.organize':
      e.stopPropagation();
      void host.emit(EV.action, { action: 'card.ai_sort', project: S.project?.id ?? null });
      hanging().forEach((l, i) => setTimeout(() => drop(l, 'pull'), i * 70));
      setOpen(false);
      return;
    case 'toast.second':
    case 'toast.act': {
      // the pointer is still on the island after the click: it must not open the island (and drop the cards over the
      // text just typed) — not until it has left
      clearTimeout(hoverTimer);
      holdClosed = { x: (e as MouseEvent).screenX ?? 0, y: (e as MouseEvent).screenY ?? 0 };
      const tt = toastNow;
      if (action === 'toast.second') {
        if (tt?.second) void host.emit(EV.action, { action: tt.second.a });
        return dismissToast();
      }
      if (tt?.action) void host.emit(EV.action, { action: tt.action.a, ...(tt.action.extra ?? {}) });
      if (tt?.action?.a === 'card.restore' || tt?.action?.a === 'card.putback') revealCards(true);
      return dismissToast();
    }
    case 'open.job':
      void host.emit(EV.action, { action: 'open.job', job: a.dataset.job });
      break;
    case 'voice.structured':
      void host.emit(EV.action, { action: 'voice.structured' });
      return;
    default:
      void host.emit(EV.action, { action });
  }
  if (['open.inbox', 'open.job', 'record', 'snap', 'voice', 'project.open'].includes(action)) {
    toastNow = null;
    open = false;
    closeSwitcher();
  }
  render();
});

island.addEventListener('contextmenu', (e) => {
  e.preventDefault();
  if (!live.some((l) => l.phase === 'hang' || l.phase === 'fly')) return;
  showIslandMenu(e.clientX, island.getBoundingClientRect().bottom + 6);
});

function showToastOp(op: Extract<IslandOp, { op: 'toast' }>) {
  switch (op.kind) {
    case 'dictation':
      // a plain line leads with its source's glyph, not Peep (the Mac's toastMark: one Peep, never two); dictation's
      // own keys (BlurtCore DictationToastKeys: the take, its tip, "still recognizing", a failed take's Retry …) and
      // passive lines (tips, reminders) come from Rust (dictation/flow.rs `toast_keys`)
      // the Mac's marks: the attention triangle where it failed, the ok check for a done line, else none (the text on its
      // column); "Sent" is the ears' moment, not a line
      if (op.moment) return earMoment(t(op.msg ?? '', op.vars), op.moment);
      {
        const text = keepUnits(t(op.msg ?? '', op.vars));
        // a short done line with nothing to do about it ("✓ Copied", "✓ 已复制 · Ctrl+V 粘贴") is a moment in the ears,
        // like "Sent" (the Mac's Island.toast: icon check, no action, no " · ", one line, at most earMomentMaxText —
        // 130 px here, as Windows' key names are longer than ⌘V)
        // one " · " is allowed: the hint after it is said in the moment's secondary white ("✓ 已复制 · Ctrl+V 粘贴")
        if (op.mark === 'check' && !op.action && !op.second && text.split(' · ').length <= 2 && !text.includes('\n') && earTextW(text) <= EAR_MOMENT_MAX) {
          return earMoment(text);
        }
        return postToast({ key: op.key ?? 'dictation', text, mark: op.mark, src: 'dictation', project: op.project, action: op.action, second: op.second, ms: op.ms, passive: op.passive });
      }
    case 'capture':
      // a snap's, a screen text's, a recording's line: its own mark or none — never the mic (the Mac's toastMark)
      if (op.key === 'screen-text') readingUntil = 0;
      return postToast({ key: op.key ?? 'capture', text: t(op.msg ?? '', op.vars), mark: op.mark, project: op.project, action: op.action, ms: op.ms, passive: op.passive });
    case 'sorted': {
      // the run ended: Peep's peep and hop, then the quiet line with Open (JobNotifier)
      sorted = { ok: true, n: op.n ?? 0, until: performance.now() + 2400 };
      const text = op.n ? `${t('island.toast.organized')} · ${plural('island.toast.new', op.n)}` : t('island.toast.organized');
      return postToast({ text, peep: 'done', passive: true, action: { a: 'open.inbox', label: 'island.toast.open' } });
    }
    case 'failed': {
      sorted = { ok: false, n: 0, until: performance.now() + 2400 };
      const what = op.type ? t(`job.type.${op.type}`) : t('job.type.process');
      return postToast({ text: t('island.toast.didnt_finish', { what }), peep: 'error', passive: true, action: op.job ? { a: 'open.job', label: 'island.toast.show', extra: { job: op.job } } : undefined });
    }
    case 'taken': {
      // what went in (the Mac's DragReceipt): the picture, the picture and its note, the .md too, the note copied
      const o = op as Extract<IslandOp, { kind: 'taken' }>;
      const text = t(`island.toast.taken_${o.what ?? 'picture'}`);
      return postToast({ key: 'taken', text, mark: 'check', overOpen: true, ms: UNDO_MS, action: { a: 'card.putback', label: 'island.undo', extra: { cards: o.cards ?? [] } } });
    }
    case 'line':
      return postToast({ text: t(op.msg, op.vars), mark: op.mark, overOpen: true });
    default:
      return postToast({ text: t(`error.${op.code ?? 'unknown'}`), mark: 'warning' });
  }
}

function bumpIsland() {
  bump = performance.now();
  island.classList.remove('bump');
  void island.offsetWidth;
  island.classList.add('bump');
}

// ------------------------------------------------------------------ menus (a card's, the island's, ···)
interface MenuItem {
  label: string;
  run?: () => void;
  sub?: MenuItem[];
  sep?: boolean;
  glyph?: string;
  key?: string;
  danger?: boolean;
}
let menuTimer = 0;
let menuHover = false;
/** The pointer left the island and its cards without going onto the menu: the menu goes 0.9 s later (7.8). */
function menuAway() {
  if (menuEl.hidden || menuHover) return;
  clearTimeout(menuTimer);
  menuTimer = window.setTimeout(() => !menuHover && closeMenu(), 900);
}
function showMenu(items: MenuItem[], x: number, y: number) {
  const html = (list: MenuItem[], depth: number): string =>
    list
      .map((it, i) => {
        if (it.sep) return '<div class="msep"></div>';
        const sub = it.sub ? `<div class="menu sub">${html(it.sub, depth + 1)}</div>` : '';
        // (a div, not a button: a submenu's rows inside a button would be parsed out of it)
        return `<div class="mi${it.sub ? ' has-sub' : ''}${it.danger ? ' danger' : ''}" role="menuitem" tabindex="-1" data-mi="${depth}:${i}">${it.glyph ?? ''}<span>${esc(it.label)}</span>${
          it.key ? `<span class="mk">${esc(it.key)}</span>` : it.sub ? ic('chevron-right', 12, 'chev') : ''
        }${sub}</div>`;
      })
      .join('');
  menuEl.innerHTML = html(items, 0);
  menuEl.hidden = false;
  const flat = new Map<string, MenuItem>();
  const walk = (list: MenuItem[], depth: number) => list.forEach((it, i) => (flat.set(`${depth}:${i}`, it), it.sub && walk(it.sub, depth + 1)));
  walk(items, 0);
  menuEl.onclick = (e) => {
    const b = (e.target as HTMLElement).closest<HTMLElement>('[data-mi]');
    const it = b && flat.get(b.dataset.mi!);
    if (!it || it.sub) return;
    e.stopPropagation();
    closeMenu();
    it.run?.();
  };
  menuEl.onpointerleave = () => {
    menuHover = false;
    menuTimer = window.setTimeout(closeMenu, 900);
  };
  menuEl.onpointerenter = () => {
    menuHover = true;
    clearTimeout(menuTimer);
  };
  const W = stage.clientWidth || innerWidth;
  const r = menuEl.getBoundingClientRect();
  menuEl.style.left = `${Math.round(Math.min(Math.max(8, x), W - r.width - 8))}px`;
  menuEl.style.top = `${Math.round(Math.min(y, (stage.clientHeight || innerHeight) - r.height - 8))}px`;
  menuEl.classList.toggle('flip', x + r.width + 200 > W);
  clearTimeout(menuTimer);
  render();
  reportHits(true);
}
function closeMenu() {
  for (const x of live) x.face.classList.remove('menu-for');
  if (menuEl.hidden) return;
  menuHover = false;
  menuEl.hidden = true;
  menuEl.innerHTML = '';
  render();
  reportHits(true);
}

/** The ··· menu (IslandContent.showRecordingMenu): where the take goes, Discard or Start Over…. */
function showRecMenu(btn: HTMLElement) {
  const b = btn.getBoundingClientRect();
  showMenu(
    [
      // BA-66: finish without organizing — the video is kept and shown in File Explorer (recording.md §5.5)
      { label: t('island.rec.video_only'), run: () => void host.emit(EV.action, { action: 'videoonly' }) },
      { sep: true, label: '' },
      // the pen latched on / off (its key, Esc puts it down; recording.md §4.6)
      { label: t('island.rec.pen'), glyph: S.recording?.pen ? ic('check', 14) : '', key: S.hotkeys.pen, run: () => void host.emit(EV.action, { action: 'pen' }) },
      { sep: true, label: '' },
      { label: t('island.rec.goes_to', { project: S.project?.name ?? t('island.unassigned') }), glyph: S.project ? folderGlyph(S.project) : `<span class="dim">${ringGlyph()}</span>`, key: S.hotkeys.project, run: () => openSwitcher() },
      { sep: true, label: '' },
      { label: t('island.rec.discard_menu'), run: () => (setConfirm(true), render()) },
    ],
    b.left,
    b.bottom + 6,
  );
}

const cardRef = (c: Card) => ({ n: c.n, session: c.session });

/** A card's right-click menu (HangingCards.cardMenu). */
function showCardMenu(l: Live, x: number, y: number, extra: MenuItem[] = []) {
  const c = l.card;
  for (const x2 of live) x2.face.classList.toggle('menu-for', x2 === l);
  const n = cardCount();
  // this card, or the Ctrl-click selection it is part of (withSelection)
  const these = withSelection(l);
  const moveTo: MenuItem[] = [
    ...S.projects.slice(0, 8).map((p) => ({ label: p.name, glyph: placeGlyph(p), run: () => fileCards(these, `project:${p.id}`) })),
    { sep: true, label: '' },
    { label: t('island.unassigned'), glyph: `<span class="dim">${ringGlyph()}</span>`, run: () => fileCards(these, 'inbox') },
  ];
  const items: MenuItem[] = [...extra];
  if (c.src) items.push({ label: t('island.card.copy_image'), run: () => copyCard(l, 'image') });
  if (c.text) items.push({ label: t('island.card.copy_text'), run: () => copyCard(l, 'text') });
  if (n > 1) items.push({ label: plural('island.card.copy_all', n), run: () => copyAll() });
  items.push({ label: t('island.card.edit_note'), run: () => void host.emit(EV.action, { action: 'card.note', ...cardRef(c), rect: faceRect(c) }) });
  if (c.file) items.push({ label: t('island.card.reveal'), run: () => void host.emit(EV.action, { action: 'card.reveal', ...cardRef(c) }) });
  items.push({ sep: true, label: '' });
  items.push({ label: these.length > 1 ? plural('island.card.move_n', these.length) : t('island.card.move_to'), sub: moveTo });
  items.push({ label: these.length > 1 ? plural('island.card.organize_n', these.length) : t('island.card.organize'), run: () => fileCards(these, 'organize') });
  items.push({ sep: true, label: '' });
  items.push({ label: t('island.card.delete'), danger: true, run: () => deleteCards([l]) });
  showMenu(items, x, y);
}

/** The island's right-click menu (TakenPanel.islandMenu): what concerns every hanging card. */
function showIslandMenu(x: number, y: number) {
  const n = cardCount();
  showMenu(
    [
      // (Show only while they are up: hanging, they are shown)
      ...(downK.value > 0.5 ? [] : [{ label: plural('island.cards.show', n), run: () => revealCards(true) }]),
      { label: plural('island.card.copy_all', n), run: () => copyAll() },
      // into the current project when there is one, else Unassigned with suggestions (organizeTarget)
      { label: t('island.cards.organize_all'), run: () => (void host.emit(EV.action, { action: 'card.ai_sort', project: S.project?.id ?? null }), hanging().forEach((l, i) => setTimeout(() => drop(l, 'pull'), i * 70))) },
      { sep: true, label: '' },
      { label: plural('island.card.delete_all', n), danger: true, run: () => deleteCards(hanging()) },
    ],
    x,
    y,
  );
}

function copyCard(l: Live, what: 'image' | 'text' | 'auto') {
  void host.emit(EV.action, { action: what === 'text' ? 'card.copy_text' : 'card.copy', ...cardRef(l.card) });
  if (downK.value > 0.5 && l.el.style.display !== 'none') {
    copiedAt = { key: l.key, until: performance.now() + 1200 };
    l.face.classList.remove('flash');
    void l.face.offsetWidth;
    l.face.classList.add('flash');
    kick();
  } else earMoment(t('island.cards.copied'));
}
/** "✓ Copied" under the card just clicked, for 1.2 s (the multi-select chip's component) */
let copiedAt: { key: string; until: number } | null = null;
function copyAll() {
  const cards = hanging().slice().reverse().map((l) => cardRef(l.card)); // newest first, as the row
  void host.emit(EV.action, { action: 'card.copy_all', cards });
  earMoment(plural('island.card.copied_n', cards.length));
}

// deletes in a row gather under one Undo (CardUndo)
let undoCards: { n: number; session?: string | null }[] = [];
let undoUntil = 0;
function deleteCards(ls: Live[]) {
  if (!ls.length) return;
  const refs = ls.map((l) => cardRef(l.card));
  for (const l of ls) drop(l, 'fall');
  void host.emit(EV.action, { action: 'card.remove', ...refs[0], cards: refs });
  undoCards = performance.now() < undoUntil ? [...undoCards, ...refs] : refs;
  undoUntil = performance.now() + UNDO_MS;
  postToast({
    key: 'delete',
    text: plural('island.card.deleted', undoCards.length),
    overOpen: true,
    ms: UNDO_MS,
    action: { a: 'card.restore', label: 'island.undo', extra: { cards: undoCards } },
  });
}

function fileCard(l: Live, target: string) {
  fileCards(withSelection(l), target);
}

/** Cards filed together (one card, or a Ctrl-click selection): onto a project, Unassigned, or Organize. A project
 *  whose folder is gone takes nothing — the cards stay, and the island offers Locate… (MissingFolder.warn). */
function fileCards(ls: Live[], target: string) {
  const refs = ls.map((l) => cardRef(l.card));
  if (target.startsWith('project:')) {
    const p = S.projects.find((x) => x.id === target.slice('project:'.length));
    if (p && p.exists === false) {
      for (const l of ls) if (l.phase !== 'hang' && l.phase !== 'fly') backOnThread(l);
      return missingToast(p);
    }
  }
  if (target === 'organize') void host.emit(EV.action, { action: 'card.organize', ...refs[0], cards: refs });
  else if (target === 'inbox') void host.emit(EV.action, { action: 'card.inbox', ...refs[0], cards: refs });
  else void host.emit(EV.action, { action: 'card.assign', ...refs[0], cards: refs, project: target.slice('project:'.length) });
  clearSelection();
  ls.forEach((l, i) => {
    if (l.phase !== 'hang') l.phase = 'hang';
    setTimeout(() => drop(l, 'pull'), i * 70);
  });
}

/** "“X” folder not found · Card kept", with Locate… (MissingFolder.warn). */
function missingToast(p: ProjectRef) {
  postToast({ key: 'missing-folder', text: t('island.missing.card_kept', { name: p.name }), mark: 'warning', overOpen: true, ms: 8000, action: { a: 'project.locate', label: 'island.locate', extra: { id: p.id } } });
}

// --- the Ctrl-click selection (the Mac's ⌘-click): copied as one, moved as one; a plain click or the cards going up
// ends it
const selection = new Set<string>();
let selCopiedUntil = 0;
function withSelection(l: Live): Live[] {
  if (!selection.has(l.key)) return [l];
  return hanging().filter((x) => selection.has(x.key)).reverse(); // newest first, as the row
}
function toggleSelected(l: Live) {
  if (selection.has(l.key)) selection.delete(l.key);
  else selection.add(l.key);
  for (const x of live) x.face.classList.toggle('picked', selection.has(x.key));
  if (selection.size) {
    const cards = hanging().filter((x) => selection.has(x.key)).reverse().map((x) => cardRef(x.card));
    void host.emit(EV.action, { action: 'card.copy_all', cards });
    selCopiedUntil = performance.now() + 2600;
  }
  kick();
}
function clearSelection() {
  if (!selection.size) return;
  selection.clear();
  for (const x of live) x.face.classList.remove('picked');
  kick();
}

// ------------------------------------------------------------------ cards hanging on threads (HangingCards)
type Phase = 'fly' | 'hang' | 'drag' | 'out' | 'pull' | 'fall';
interface Live {
  card: Card;
  key: string;
  el: HTMLElement;
  leg: HTMLElement;
  face: HTMLElement;
  phase: Phase;
  w: number;
  h: number;
  fills: boolean;
  x: Spring;
  y: Spring; // offset from the hanging position (fly-in starts below)
  lift: Spring;
  reach: Spring; // how far the thread has dropped, 0 (in the island) … 1 (down at the card)
  swing: Pendulum;
  fresh: boolean; // not placed yet: put at its slot at once, never slid in from the window's edge
  fromX?: number; // a fly-in from where it was taken: its x starts there
  drag?: { ox: number; oy: number; px: number; py: number; moved: boolean };
  fall?: { vy: number; y: number; spin: number; a: number; o: number };
  pullT0?: number;
  justDragged?: boolean;
}

const live: Live[] = [];
let hovered: Live | null = null;
let dragging: Live | null = null;
let row: RowLayout = cardRow([], 0, [0, 0]);
/** how far a row longer than its window is scrolled (RowLayout.scroll; 0: the newest at the left) */
let scrollX = 0;
const keyOf = (c: Card) => `${c.session ?? ''}#${c.n}`;
const isVoice = (c: Card) => c.kind === 'voice' || !c.src;
const clicks = new DeferredClick<string>();

// the cards come down (CardReveal): after a capture for a moment, while the pointer is on them or the island, while
// it is open or a card is dragged — and brought down on purpose (the ear's count) until visited and left
const downK = new Spring(0, 0.4, 0.9);
let revealUntil = 0;
let stickyAt = 0;
let stickyVisited = false;
let cardHover = false;
let cardAwayTimer = 0;

/** Edit Note open over a card (Rust's `editing`) */
let editing = false;

function cardsDown(): boolean {
  const now = performance.now();
  if (panel && !dragging) return false;
  if (editing && !S.recording) return true;
  // a take or a voice note running: the cards stay up over what is being recorded — only an explicit reveal (the
  // ear's count, Alt+Shift+H, the menu) or a drag brings them down (the Mac's K7: recordingStarted → retract)
  if (S.recording || S.voice) {
    if (dragging || drawer === 'drop' || cardHover) return true;
    if (stickyAt && CardReveal.staysDown(stickyVisited, cardHover || hovering, now - stickyAt)) return true;
    stickyAt = 0;
    return false;
  }
  if (dragging || drawer === 'drop' || open || !menuEl.hidden || cardHover || now < revealUntil) return true;
  if (hovering && now - hoverSince >= CardReveal.dwell) return true;
  if (stickyAt && CardReveal.staysDown(stickyVisited, cardHover || hovering, now - stickyAt)) return true;
  stickyAt = 0;
  return false;
}

/** `sticky`: brought down on purpose (the ear's count, the menu) — they stay until the pointer has come and gone. */
function revealCards(sticky: boolean) {
  if (sticky) {
    stickyAt = performance.now();
    stickyVisited = false;
  }
  revealUntil = Math.max(revealUntil, performance.now() + 400);
  layoutCards();
  render();
}

function onCardsEnter() {
  clearTimeout(cardAwayTimer);
  cardHover = true;
  if (stickyAt) stickyVisited = true;
}
function onCardsLeave() {
  clearTimeout(cardAwayTimer);
  cardAwayTimer = window.setTimeout(() => {
    cardHover = false;
    // onto the menu that hangs from the card: still here
    if (menuHover) return;
    menuAway();
    if (!hovering && open && !drawer && !confirmDiscard && menuEl.hidden) setOpen(false);
    layoutCards();
    render();
  }, CardReveal.away);
}

// ---- a card's hover note (the Mac's CardTip): after the hover dwell, only when the card cuts its note short — the
// whole note and "Snap · 14:32" under the card, in the island's own surface (never the system's white tooltip)
const tipEl = document.createElement('div');
tipEl.className = 'cardtip';
tipEl.hidden = true;
stage.append(tipEl);
let tipTimer = 0;
function tipSoon(l: Live) {
  clearTimeout(tipTimer);
  tipTimer = window.setTimeout(() => showTip(l), 350);
}
function hideTip() {
  clearTimeout(tipTimer);
  tipEl.hidden = true;
}
function showTip(l: Live) {
  if (hovered !== l || dragging || !menuEl.hidden || selection.size || downK.value < 0.9) return;
  const voice = isVoice(l.card);
  // a voice card whose words fit has nothing more to show
  const cut = l.face.querySelector<HTMLElement>('.band, .cap');
  if (voice && (!l.card.text || !cut || (cut.scrollWidth <= cut.clientWidth + 1 && cut.scrollHeight <= cut.clientHeight + 1))) return;
  const wall = (l.card as HCard).wall;
  const what = voice ? t('island.cards.voice') : t('island.card.snap');
  const title = l.card.text ? `<div class="tnote">${esc(l.card.text)}</div>` : '';
  const pic = !voice && l.card.src ? `<div class="tpic"><img alt="" draggable="false" src="${esc(l.card.src)}"></div>` : '';
  tipEl.innerHTML = `${title}<div class="twhen">${esc(wall ? `${what} · ${timeOf(wall)}` : what)}</div>${pic}`;
  tipEl.classList.toggle('pic', !!pic);
  tipEl.hidden = false;
  const r = l.face.getBoundingClientRect();
  const w = tipEl.offsetWidth;
  tipEl.style.left = `${Math.round(Math.min(Math.max(8, r.left + r.width / 2 - w / 2), innerWidth - w - 8))}px`;
  tipEl.style.top = `${Math.round(r.bottom + 8)}px`;
}

function faceHtml(l: Live) {
  const c = l.card;
  if (isVoice(c)) {
    // a voice card is a text card: up to two lines of its words and a small mic mark
    return `<div class="face voice">${ic('mic', 13, 'vmic')}<span class="cap">${esc(c.text || t('island.card.transcribing'))}</span></div>`;
  }
  return `<div class="face shot${l.fills ? '' : ' whole'}"><img alt="" draggable="false" crossorigin="anonymous" src="${esc(c.src)}">${c.text ? `<span class="band">${esc(c.text.replace(/\s+/g, ' '))}</span>` : ''}</div>`;
}

function measure(l: Live) {
  if (isVoice(l.card)) return Object.assign(l, { w: VOICE.w, h: VOICE.h, fills: true });
  const img = l.face.querySelector('img');
  const px = img && img.naturalWidth ? { w: img.naturalWidth, h: img.naturalHeight } : null;
  const s = cardShape(px);
  const changed = s.w !== l.w || s.fills !== l.fills;
  Object.assign(l, { w: s.w, h: s.h, fills: s.fills });
  if (changed) {
    l.el.style.width = `${l.w}px`;
    l.face.querySelector('.face')?.classList.toggle('whole', !l.fills);
    layoutCards();
  }
}

function makeCard(card: Card, from: 'fly' | 'still'): Live {
  const el = document.createElement('div');
  el.className = 'hang';
  el.dataset.kind = isVoice(card) ? 'voice' : 'shot';
  el.innerHTML = `<div class="leg"><i class="thread"></i><i class="clasp"></i></div><div class="card" role="button" tabindex="-1"></div>`;
  const leg = el.querySelector<HTMLElement>('.leg')!;
  const face = el.querySelector<HTMLElement>('.card')!;
  const l: Live = {
    card,
    key: keyOf(card),
    el,
    leg,
    face,
    phase: from === 'fly' ? 'fly' : 'hang',
    w: isVoice(card) ? VOICE.w : 112,
    h: isVoice(card) ? VOICE.h : 84,
    fills: true,
    x: new Spring(0, 0.5, 0.82),
    y: new Spring(from === 'fly' ? 150 : 0, 0.55, 0.72),
    lift: new Spring(0, 0.28, 0.75),
    reach: new Spring(from === 'fly' ? 0 : 1, 0.35, 1),
    swing: new Pendulum(46, 6), // K7: settles within 1.2 s
    fresh: true,
  };
  setFace(l);
  el.style.width = `${l.w}px`;
  l.y.target = 0;
  l.reach.target = 1;
  face.addEventListener('pointerenter', () => {
    hovered = l;
    onCardsEnter();
    layoutCards();
    kick();
    tipSoon(l);
  });
  face.addEventListener('pointerleave', () => {
    if (hovered === l) hovered = null;
    onCardsLeave();
    layoutCards();
    kick();
    hideTip();
  });
  face.addEventListener('pointerdown', hideTip);
  face.addEventListener('pointerdown', (e) => startDrag(l, e));
  face.addEventListener('click', (e) => {
    if ((e.target as HTMLElement).closest('.x')) return;
    if (l.justDragged) return void (l.justDragged = false);
    if (e.ctrlKey || e.metaKey) return toggleSelected(l); // Ctrl-click: into (or out of) the selection, copied as one
    clearSelection();
    // a plain click copies once the double-click interval has passed; a double-click edits the note, never copying first
    if (clicks.click(l.key, e.detail, performance.now(), DOUBLE_CLICK_MS) === 'edit') {
      void host.emit(EV.action, { action: 'card.note', ...cardRef(l.card), rect: faceRect(l.card) });
      return;
    }
    setTimeout(() => clicks.fire(performance.now()) === l.key && copyCard(l, 'auto'), DOUBLE_CLICK_MS + 10);
  });
  face.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    e.stopPropagation();
    const r = face.getBoundingClientRect();
    showCardMenu(l, r.left, r.bottom + 6);
  });
  deck.append(el);
  if (from === 'fly' && reduceMotion()) {
    l.y.snap();
    l.reach.snap();
  }
  return l;
}

function setFace(l: Live) {
  l.face.innerHTML = `${faceHtml(l)}<button class="x" aria-label="${esc(t('island.card.delete'))}">${ic('x', 10)}</button>`;
  // (no native tooltip: its white system box isn't the island's — the note is the card's label for assistive tech)
  l.face.setAttribute('aria-label', l.card.text || (isVoice(l.card) ? t('island.cards.voice') : t('island.card.snap')));
  l.face.querySelector('.x')!.addEventListener('click', (e) => {
    e.stopPropagation();
    deleteCards([l]);
  });
  const img = l.face.querySelector('img');
  if (img) {
    if (img.complete) measure(l);
    else img.addEventListener('load', () => measure(l), { once: true });
  }
}

function setCards(cards: Card[]) {
  const keep = new Set(cards.map(keyOf));
  for (const l of [...live]) if (!keep.has(l.key) && (l.phase === 'hang' || l.phase === 'fly' || l.phase === 'out')) drop(l, 'gone');
  for (const c of cards.slice(-MAX_CARDS_KEPT)) {
    const l = live.find((x) => x.key === keyOf(c) && x.phase !== 'fall' && x.phase !== 'pull');
    if (l) {
      if (l.card.text !== c.text || l.card.src !== c.src) {
        l.card = c;
        setFace(l);
      }
      l.card = c;
    } else live.push(makeCard(c, 'still'));
  }
  layoutCards();
  showFirstHint();
}

/** Where a card is drawn (CSS px of this window), for "Edit Note…" to open under it. */
function faceRect(c: Card, el?: Element | null): CssRect | null {
  const e = el ?? live.find((l) => l.key === keyOf(c))?.face;
  if (!e) return null;
  const r = e.getBoundingClientRect();
  return r.width ? { x: r.left, y: r.top, w: r.width, h: r.height } : null;
}

function addCard(card: Card, pull: boolean, from?: CssRect | null) {
  if (live.some((l) => l.key === keyOf(card) && l.phase !== 'fall')) return;
  // a frame asked for while the snap's full-screen stage covered this page (WebView2 holds an occluded page's frames)
  // would land now and count as starved, snapping the flight to its end: the stage is gone (Rust sends this after
  // it), so the loop starts over
  restartLoop();
  const l = makeCard(card, 'fly');
  live.push(l);
  scrollX = 0; // the newest, where it is caught: at the window's left
  if (from && !reduceMotion()) {
    // it flies from where it was taken (the snapped area) to its place on the row
    l.fromX = from.x + from.w / 2;
    l.y.value = from.y + from.h / 2 - (islandBottom() + BELOW + l.h / 2);
  }
  if (!reduceMotion()) l.swing.kick((Math.random() < 0.5 ? -1 : 1) * (1.1 + 0.5 * Math.random()));
  // the cards hang for a moment after a capture
  revealUntil = performance.now() + CardReveal.afterCapture;
  layoutCards();
  if (pull) setTimeout(() => drop(l, 'pull'), reduceMotion() ? 200 : 650); // caught, then hauled into the island
  showFirstHint();
  render();
}

/** A card leaves: pulled into the island, falling (deleted), or just gone (filed elsewhere, taken by a drag). */
function drop(l: Live, how: 'pull' | 'fall' | 'gone') {
  if (l.phase === 'fall' || l.phase === 'pull') return;
  if (hovered === l) hovered = null;
  l.el.classList.add('open'); // the thread lets go
  if (how === 'gone' || reduceMotion()) {
    // a fade by the clock, not by an animation's end (a throttled page may never run that callback)
    l.el.classList.add('fading');
    setTimeout(() => remove(l), 220);
    l.phase = 'fall';
    if (how === 'pull') bumpIsland();
    return;
  }
  if (how === 'fall') {
    l.phase = 'fall';
    l.fall = { vy: -60, y: l.y.value + l.lift.value, spin: (Math.random() - 0.5) * 2.4, a: l.swing.angle, o: 1 };
  } else {
    l.phase = 'pull';
    l.pullT0 = performance.now();
  }
  layoutCards();
  kick();
}

function remove(l: Live) {
  if (!live.includes(l)) return;
  l.el.remove();
  const i = live.indexOf(l);
  if (i >= 0) live.splice(i, 1);
  layoutCards();
  render();
}

// a row longer than its window scrolls sideways in it: the wheel or the touchpad's swipe over the row, rigidly (the
// cards move with the fingers)
deck.addEventListener(
  'wheel',
  (e) => {
    const v = row.viewport;
    const top = islandBottom();
    if (!v || downK.value < 0.5 || dragging || e.clientX < v[0] || e.clientX > v[1] || e.clientY < top || e.clientY > top + BELOW + 100) return;
    e.preventDefault();
    const d = Math.abs(e.deltaX) >= Math.abs(e.deltaY) ? e.deltaX : e.deltaY;
    scrollRow(scrollX + d * (e.deltaMode === 1 ? 16 : 1));
  },
  { passive: false },
);
function scrollRow(to: number) {
  const before = scrollX;
  scrollX = Math.min(Math.max(0, to), row.maxScroll);
  const d = before - scrollX;
  if (Math.abs(d) < 0.01) return;
  for (const l of hanging()) l.x.value += d;
  layoutCards();
}
// a row wider than the island hangs from the island's lip: a 3 px band of its black flush under it, centred on it,
// as wide as the outermost clasps plus 8 (CardRow.lip) — never threads fanning from nowhere
const lip = document.createElement('div');
lip.className = 'lip';
lip.hidden = true;
stage.append(lip);
// the first card ever says what it is for, once
const hint = document.createElement('div');
hint.className = 'first-hint';
hint.hidden = true;
deck.append(hint);

let hintShown = (() => {
  try {
    return localStorage.getItem('blurt.cards_hint_shown') === '1';
  } catch {
    return false;
  }
})();
let hintUntil = 0;
function showFirstHint() {
  if (hintShown || S.recording || !hanging().length) return;
  hintShown = true;
  hintUntil = performance.now() + 6000;
  try {
    localStorage.setItem('blurt.cards_hint_shown', '1');
  } catch {
    /* a page without storage just shows it again next time */
  }
  setTimeout(() => (layoutCards(), render()), 6050);
}

/** The row (BlurtCore CardRow): newest first, centred under the island, never off the window's edge; a row longer than
 *  its window scrolls in it, its edges fading where more cards wait. `snapX`: put the cards at their slots at once
 *  (the window changed size, or they are new). */
function layoutCards(snapX = false) {
  // oldest first, by when each was taken (the row puts the newest leftmost): the order the cards came in is not that
  // order when a refresh lists one before its fly-in lands; one still flying with no time yet is the newest
  const cards = hanging()
    .map((l, i) => ({ l, i, w: l.card.wall ?? (l.phase === 'fly' ? Infinity : -Infinity) }))
    .sort((a, b) => a.w - b.w || a.i - b.i)
    .map((x) => x.l);
  const W = stage.clientWidth || innerWidth || screen.width;
  row = cardRow(
    cards.map((l) => l.w),
    rowCentre(stage.clientWidth || innerWidth, screen.width),
    rowBounds(W),
    { scroll: scrollX },
  );
  scrollX = row.scroll;
  const shownSet = new Set(row.shown.map((i) => cards[i]));
  cards.forEach((l) => (l.el.style.display = shownSet.has(l) ? '' : 'none'));
  const order = row.shown.map((i) => cards[i]); // left to right
  const lifted = hovered && order.includes(hovered) ? order.indexOf(hovered) : null;
  const aside = stepAside(order.length, lifted);
  order.forEach((l, j) => {
    l.x.target = row.centres[j] + aside[j];
    if (l.fresh || snapX || reduceMotion()) {
      l.x.snap();
      if (l.fresh && l.fromX !== undefined && !snapX && !reduceMotion()) l.x.value = l.fromX;
      l.fresh = false;
    }
    l.lift.target = j === lifted ? -LIFT : 0;
  });
  rowMask();
  downK.target = cards.length && cardsDown() ? 1 : 0;
  if (reduceMotion()) downK.snap();
  kick();
  paintNow();
}

/** The fade at the row's window edges where more cards wait beyond them (none while it fits, or a card is dragged). */
let maskNow = '';
function rowMask() {
  const v = row.viewport;
  let m = '';
  if (v && !dragging) {
    const l = scrollX > 0.5 ? FADE : 0;
    const r = scrollX < row.maxScroll - 0.5 ? FADE : 0;
    m = `linear-gradient(to right, transparent ${v[0]}px, #000 ${v[0] + l}px, #000 ${v[1] - r}px, transparent ${v[1]}px)`;
  }
  if (m === maskNow) return;
  maskNow = m;
  deck.style.maskImage = m;
}
/** Some of the card shows in the row's window (it can be pointed at, and the lip reaches it). */
const inView = (l: Live) => visibleIn(l.x.value - l.w / 2, l.x.value + l.w / 2, row) > 0.15;

// --- drag a card: onto a project in the island, or out into any app (CardDrag; Island.dragMoved)
function islandZone(margin: number) {
  const r = island.getBoundingClientRect();
  return { l: r.left - margin, r: r.right + margin, t: r.top - margin, b: r.bottom + margin };
}
const inZone = (z: { l: number; r: number; t: number; b: number }, x: number, y: number) => x >= z.l && x <= z.r && y >= z.t && y <= z.b;

function startDrag(l: Live, e: PointerEvent) {
  if (e.button !== 0 || (e.target as HTMLElement).closest('.x') || l.phase !== 'hang') return;
  const r = l.face.getBoundingClientRect();
  l.drag = { ox: e.clientX - r.left, oy: e.clientY - r.top, px: e.clientX, py: e.clientY, moved: false };
  l.face.setPointerCapture(e.pointerId);
  const end = () => {
    l.face.removeEventListener('pointermove', move);
    l.face.removeEventListener('pointerup', up);
    l.face.removeEventListener('pointercancel', up);
  };
  const move = (ev: PointerEvent) => {
    const d = l.drag!;
    if (!d.moved && Math.hypot(ev.clientX - d.px, ev.clientY - d.py) < 4) return;
    if (!d.moved) {
      d.moved = true;
      clicks.cancel();
      closeMenu();
      dragging = l;
      stage.classList.add('dragging');
      l.phase = 'drag';
      l.el.classList.add('open', 'dragging'); // the thread lets go and springs back into the island
      render();
    }
    d.px = ev.clientX;
    d.py = ev.clientY;
    // near the island (70 px; 24 once open), the drawer opens and takes the drop
    const near = inZone(islandZone(drawer === 'drop' ? 24 : 70), ev.clientX, ev.clientY);
    if (near && drawer !== 'drop') {
      drawer = 'drop';
      lastBody = '';
      render();
    } else if (!near && drawer === 'drop') {
      drawer = null;
      lastBody = '';
      render();
    }
    // out of the island's zone and off the cards' band: the system's own drag takes the picture on to another app
    const band = islandBottom() + BELOW + 84 + 30;
    const offRow = ev.clientY > band || ev.clientX < row.span[0] - 24 || ev.clientX > row.span[1] + 24;
    if ((l.card.file || (isVoice(l.card) && l.card.text)) && !near && offRow && !targetAt(ev.clientX, ev.clientY)) {
      l.face.releasePointerCapture(ev.pointerId);
      end();
      l.drag = undefined;
      dragging = null;
      stage.classList.remove('dragging');
      drawer = null;
      lastBody = '';
      l.phase = 'out'; // it went with the drag: shown again only if the drop is cancelled
      l.el.classList.remove('dragging');
      l.el.style.visibility = 'hidden';
      outTimer = window.setTimeout(() => dragOut({ ...cardRef(l.card), result: 'cancel' }), 60000);
      render();
      // "Picture with the note under it": the dragged picture is a copy with the note in a strip under it
      const caption = S.cardPrefs?.drag === 'caption' && l.card.text ? captioned(l) : null;
      // the window stops taking the mouse first (it took all of it while the card was dragged inside): else, under
      // the pointer everywhere, the island itself is the drop target the system's drag finds, and nothing else gets it
      reportHits(true);
      void host.emit(EV.action, { action: 'card.dragout', ...cardRef(l.card), ...(caption ? { caption } : {}), ...dragImage(l.card, l.face, d) });
      return;
    }
    highlight(ev.clientX, ev.clientY);
    kick();
  };
  const up = (ev: PointerEvent) => {
    end();
    const d = l.drag;
    l.drag = undefined;
    if (!d?.moved) return; // a click: the click handler copies (deferred) or edits
    l.justDragged = true;
    setTimeout(() => (l.justDragged = false), 50);
    const target = targetAt(ev.clientX, ev.clientY);
    dragging = null;
    stage.classList.remove('dragging');
    drawer = null;
    open = false;
    lastBody = '';
    l.el.classList.remove('dragging');
    if (target) {
      l.phase = 'hang';
      fileCard(l, target);
    } else {
      // dropped on nothing: back where it hung, a thread drops again and takes it
      backOnThread(l);
    }
    render();
  };
  l.face.addEventListener('pointermove', move);
  l.face.addEventListener('pointerup', up);
  l.face.addEventListener('pointercancel', up);
}

/** The card's picture with its note in a strip under it, as a PNG data URL (null when the picture can't be read). */
function captioned(l: Live): string | null {
  const img = l.face.querySelector('img');
  if (!img || !img.naturalWidth || !l.card.text) return null;
  try {
    const w = img.naturalWidth;
    const font = Math.max(14, Math.round(w / 42));
    const pad = Math.round(font * 0.9);
    const cv = document.createElement('canvas');
    const g = cv.getContext('2d')!;
    g.font = `500 ${font}px "Segoe UI", system-ui, sans-serif`;
    // whole words to the strip's width (CJK breaks anywhere)
    const lines: string[] = [];
    for (const para of l.card.text.split('\n')) {
      let line = '';
      for (const tok of para.match(/[\u3000-\u9fff\uff00-\uffef]|\S+\s*/g) ?? ['']) {
        if (line && g.measureText(line + tok).width > w - 2 * pad) {
          lines.push(line.trimEnd());
          line = tok.trimStart();
        } else line += tok;
      }
      lines.push(line.trimEnd());
    }
    const strip = pad * 2 + lines.length * Math.round(font * 1.4);
    cv.width = w;
    cv.height = img.naturalHeight + strip;
    g.drawImage(img, 0, 0);
    g.fillStyle = '#1c1c1e';
    g.fillRect(0, img.naturalHeight, w, strip);
    g.fillStyle = '#fff';
    g.font = `500 ${font}px "Segoe UI", system-ui, sans-serif`;
    g.textBaseline = 'top';
    lines.forEach((s, i) => g.fillText(s, pad, img.naturalHeight + pad + i * Math.round(font * 1.4)));
    return cv.toDataURL('image/png'); // throws on a picture the page may not read: then the picture goes alone
  } catch {
    return null;
  }
}

/** The shutter (record.snap_sound): a short two-blade click, made here — no sound file to ship. */
let audio: AudioContext | null = null;
function shutter() {
  try {
    audio ??= new AudioContext();
    const a = audio;
    const blade = (at: number, gain: number) => {
      const len = Math.round(a.sampleRate * 0.045);
      const buf = a.createBuffer(1, len, a.sampleRate);
      const d = buf.getChannelData(0);
      for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3);
      const src = a.createBufferSource();
      src.buffer = buf;
      const band = a.createBiquadFilter();
      band.type = 'bandpass';
      band.frequency.value = 2600;
      band.Q.value = 0.8;
      const g = a.createGain();
      g.gain.value = gain;
      src.connect(band).connect(g).connect(a.destination);
      src.start(a.currentTime + at);
    };
    blade(0, 0.5);
    blade(0.07, 0.35);
  } catch {
    /* no audio output: silence */
  }
}

function backOnThread(l: Live) {
  l.phase = 'hang';
  l.el.classList.remove('open', 'dragging');
  l.el.style.visibility = '';
  const r = l.face.getBoundingClientRect();
  l.y.value = r.top - (islandBottom() + BELOW);
  l.x.value = r.left + r.width / 2;
  l.reach.value = 0.4;
  layoutCards();
}

let outTimer = 0;
/** The system's drag ended (island.rs `card.dragout`): dropped in another app = taken (Rust files it as taken and
 *  says so), else it comes back to its thread. */
function dragOut(o: { n: number; session?: string | null; result: string }) {
  clearTimeout(outTimer);
  const l = live.find((x) => x.phase === 'out' && x.card.n === o.n && (x.card.session ?? null) === (o.session ?? null));
  if (!l) return;
  if (o.result === 'dropped') drop(l, 'gone');
  else backOnThread(l);
  render();
}

function targetAt(x: number, y: number): string | null {
  const el = document.elementsFromPoint(x, y).find((e) => (e as HTMLElement).dataset?.drop) as HTMLElement | undefined;
  return el?.dataset.drop ?? null;
}

function highlight(x: number, y: number) {
  const hit = targetAt(x, y);
  for (const el of island.querySelectorAll<HTMLElement>('[data-drop]')) el.classList.toggle('over', el.dataset.drop === hit);
}

// --- the frame loop (runs only while something moves): one chain at a time — an animation frame, or a timer when
// the page gets none (rAF stalls in hidden webviews)
let raf = 0;
let fallback = 0;
let last = 0;
let settleUntil = 0;
let askedAt = 0; // when the loop asked for a frame that hasn't come yet
function kick() {
  settleUntil = performance.now() + 450; // CSS transitions of the island box
  if (raf) return;
  last = askedAt = performance.now();
  raf = requestAnimationFrame(onTick);
  fallback = window.setTimeout(onTick, 50);
}
/** Drops a frame request left over from a stretch the page was held (it would read as starved) and starts afresh. */
function restartLoop() {
  if (!raf || performance.now() - askedAt < 250) return;
  cancelAnimationFrame(raf);
  clearTimeout(fallback);
  raf = 0;
  askedAt = 0;
}
function onTick() {
  cancelAnimationFrame(raf);
  clearTimeout(fallback);
  raf = 0;
  frame(performance.now());
}

/** One frame now, without waiting for the next animation frame: what is drawn never depends on the frame loop
 *  running (a throttled page may not get one for seconds — the cards then sat at the window's top-left corner). */
let inFrame = false;
function paintNow() {
  if (!inFrame) frame(performance.now());
}

function frame(now: number) {
  if (inFrame) return;
  inFrame = true;
  try {
    step(now);
  } finally {
    inFrame = false;
  }
}

function step(now: number) {
  // a page the system throttles (an occluded or background webview: WebView2 counts a click-through overlay as one)
  // gets a frame a second or less — then nothing animates: every spring lands where it is going at once
  // (only a frame the loop asked for and waited on counts: a paint between frames says nothing)
  const starved = !raf && askedAt > 0 && now - askedAt > 250;
  if (!raf) askedAt = 0;
  const dt = Math.min(0.05, Math.max(0, (now - last) / 1000));
  last = now;
  let moving = now < settleUntil;
  let landed = false;
  downK.target = hanging().length && cardsDown() ? 1 : 0;
  if (starved || reduceMotion()) downK.snap();
  const down = downK.step(dt);
  if (!downK.resting) moving = true;
  const base = islandBottom() + BELOW;
  const top = islandBottom() - 3; // where the threads come out (tucked under the island's edge)
  for (const l of [...live]) {
    const { w, h } = l;
    l.leg.style.top = `${top}px`;
    if (l.phase === 'out') continue;
    if (l.phase === 'fall' && l.fall) {
      const f = l.fall;
      f.vy += 2400 * dt;
      f.y += f.vy * dt;
      f.a += f.spin * dt;
      f.o -= 2 * dt;
      l.el.style.transform = `translate(${(l.x.value - w / 2).toFixed(1)}px, 0)`;
      l.face.style.transform = `translate(0, ${(base + f.y).toFixed(1)}px) rotate(${f.a.toFixed(3)}rad)`;
      l.face.style.opacity = String(Math.max(0, f.o));
      l.reach.target = 0;
      l.leg.style.transform = `scaleY(${Math.max(0, l.reach.step(dt)).toFixed(3)})`;
      if (f.o <= 0 || f.y > innerHeight || starved) remove(l);
      else moving = true;
      continue;
    }
    if (l.phase === 'pull' && l.pullT0 !== undefined) {
      const k = starved ? 1 : Math.min(1, (now - l.pullT0) / 450);
      const e = k * k * k; // ease-in
      const cx = rowCentre(stage.clientWidth || innerWidth, screen.width);
      const cy = TOP + PILL_H / 2;
      const x0 = l.x.value;
      const y0 = base + l.y.value;
      const x = x0 + (cx - x0) * e;
      const y = y0 + (cy - h / 2 - y0) * e;
      l.el.style.transform = `translate(${(x - w / 2).toFixed(1)}px, 0)`;
      l.face.style.transform = `translate(0, ${y.toFixed(1)}px) scale(${(1 - 0.8 * e).toFixed(3)})`;
      l.face.style.opacity = String(1 - 0.6 * e);
      l.leg.style.height = `${Math.max(0, y - top).toFixed(1)}px`;
      if (k >= 1) {
        remove(l);
        bumpIsland();
      } else moving = true;
      continue;
    }
    if (l.phase === 'drag' && l.drag) {
      const d = l.drag;
      l.el.style.transform = `translate(${(d.px - d.ox).toFixed(1)}px, 0)`;
      l.face.style.transform = `translate(0, ${(d.py - d.oy).toFixed(1)}px) rotate(-0.03rad) scale(1.04)`;
      l.face.style.opacity = '1';
      l.reach.target = 0;
      l.leg.style.transform = `scaleY(${l.reach.step(dt).toFixed(3)})`;
      moving = true;
      continue;
    }
    if (starved) {
      for (const s of [l.x, l.y, l.lift, l.reach]) s.snap();
      l.swing.angle = l.swing.velocity = 0;
    }
    const x = l.x.step(dt);
    // up in the island: the threads reel the card back behind it (a card's height and its thread above the edge)
    const up = (1 - down) * (BELOW + h + 10);
    const y = base + l.y.step(dt) + l.lift.step(dt) - up;
    const reach = Math.min(l.reach.step(dt), down);
    if (l.phase === 'fly' && Math.abs(l.y.value) < 2) {
      l.phase = 'hang';
      landed = true;
    }
    const a = reduceMotion() ? 0 : l.swing.step(dt, hovered === l);
    const lifted = hovered === l && down > 0.9;
    l.el.style.transform = `translate(${(x - w / 2).toFixed(1)}px, 0) rotate(${a.toFixed(4)}rad)`;
    l.face.style.transform = `translate(0, ${y.toFixed(1)}px) scale(${lifted ? 1 + LIFT_SCALE : 1})`;
    l.face.style.opacity = String(Math.max(0, Math.min(1, down * 1.6)));
    l.face.classList.toggle('lifted', lifted);
    l.leg.style.height = `${Math.max(0, y - top).toFixed(1)}px`;
    l.leg.style.transform = `scaleY(${reach.toFixed(3)})`;
    l.el.classList.toggle('open', reach < 0.94);
    l.el.classList.toggle('up', down < 0.02);
    if (!(l.x.resting && l.y.resting && l.lift.resting && l.reach.resting && (reduceMotion() || l.swing.resting))) moving = true;
  }
  // the lip, while some clasp is not under the island's bottom edge (its rounded corners kept clear)
  const ir = island.getBoundingClientRect();
  const cx = ir.left + ir.width / 2;
  const v = row.viewport;
  const clasps = down > 0.5 ? (v ? [v[0] + 8, v[1] - 8] : row.centres) : [];
  const edge = [ir.left + 15, ir.right - 15];
  const lipped = clasps.some((x) => x < edge[0] - 1 || x > edge[1] + 1);
  lip.hidden = !lipped;
  if (lipped) {
    const half = Math.max(ir.width / 2, Math.max(...clasps.map((x) => Math.abs(x - cx))) + 8);
    lip.style.transform = `translate(${(cx - half).toFixed(1)}px, ${(ir.bottom - 1).toFixed(1)}px)`;
    lip.style.width = `${(2 * half).toFixed(1)}px`;
  }
  rowMask();
  if (down < 0.02 && scrollX && !dragging) {
    scrollX = 0; // next time they come down: the newest first
    layoutCards(true);
  }
  // the selection: a ring on each card, "✓ 2 selected · Copied" under the row; it ends as the cards go up
  if (selection.size && down < 0.02) clearSelection();
  // a plain click's copy: "✓ Copied" under that card, 1.2 s (the same chip)
  const copiedL = copiedAt && now < copiedAt.until && !selection.size ? (hanging().find((l) => l.key === copiedAt!.key) ?? null) : null;
  if (copiedAt && !copiedL && now >= copiedAt.until) copiedAt = null;
  selPill.hidden = !(selection.size || copiedL) || down < 0.9;
  if (!selPill.hidden && copiedL) {
    const txt = t('island.cards.copied');
    if (selPill.dataset.t !== txt) {
      selPill.innerHTML = `${ic('check', 12, 'ok')}<span>${esc(txt)}</span>`;
      selPill.dataset.t = txt;
    }
    const fr = copiedL.face.getBoundingClientRect();
    selPill.style.transform = `translate(${Math.round(fr.left + fr.width / 2 - selPill.offsetWidth / 2)}px, ${Math.round(fr.bottom + 8)}px)`;
    moving = true;
  } else if (!selPill.hidden) {
    const copied = now < selCopiedUntil ? ` · ${t('island.cards.copied')}` : '';
    const txt = `${plural('island.cards.selected', selection.size)}${copied}`;
    if (selPill.dataset.t !== txt) {
      selPill.innerHTML = `${ic('check', 12, 'ok')}<span>${esc(txt)}</span>`;
      selPill.dataset.t = txt;
    }
    const tallest = Math.max(84, ...hanging().map((l) => l.h));
    selPill.style.transform = `translate(${Math.round(rowCentre(stage.clientWidth || innerWidth, screen.width) - selPill.offsetWidth / 2)}px, ${Math.round(base + tallest + 12)}px)`;
    if (now < selCopiedUntil + 50) moving = true;
  }
  const showHint = now < hintUntil && down > 0.9 && hanging().length > 0 && !dragging && !selection.size;
  hint.hidden = !showHint;
  if (showHint) {
    hint.textContent = t('island.card.first_hint');
    const newest = row.shown.length ? hanging()[row.shown[0]] : null;
    if (newest) hint.style.transform = `translate(${Math.round(row.centres[0] - 120)}px, ${Math.round(base + newest.h + 10)}px)`;
  }
  if (now - bump < 300) moving = true;
  placeLive();
  placePanel();
  reportEdge(down);
  reportHits();
  if (landed) {
    // the count takes the card that just arrived, with a small bump on the number
    render();
    const n = document.querySelector<HTMLElement>('.earbtn .num');
    if (n && !reduceMotion()) {
      n.classList.remove('tick');
      void n.offsetWidth;
      n.classList.add('tick');
    }
  }
  if (moving) kick();
}

// --- what opens under the island (Rust's other overlays: a Translate card) goes under the cards while they are down
let lastEdge = -1;
function reportEdge(down: number) {
  let bottom = islandBottom();
  if (down > 0.5) for (const l of hanging()) if (l.el.style.display !== 'none') bottom = Math.max(bottom, l.face.getBoundingClientRect().bottom);
  const b = Math.round(bottom + 10);
  if (b === lastEdge) return;
  lastEdge = b;
  // (once it holds still: not a message every frame while the cards move)
  clearTimeout(edgeTimer);
  edgeTimer = window.setTimeout(() => void host.emit(EV.action, { action: 'cards.edge', bottom: lastEdge }), 120);
}
let edgeTimer = 0;

// --- breeze: now and then a small gust passes along the cards
function breeze() {
  if (!reduceMotion() && !dragging && downK.value > 0.9) hanging().forEach((l, i) => setTimeout(() => (l.swing.kick((Math.random() - 0.3) * 0.4), kick()), i * 90));
  setTimeout(breeze, 10000 + Math.random() * 8000);
}
setTimeout(breeze, 10000);

// --- the window changed size (RDP reconnect, a display-scale change, another monitor): the row moves at once
function onResize() {
  layoutCards(true);
  render();
  reportHits(true);
}
addEventListener('resize', onResize);
new ResizeObserver(() => onResize()).observe(stage);

// --- click-through: where we draw (the whole window while a card is being dragged)
let lastHits = '';
function reportHits(force = false) {
  const rects: CssRect[] = [];
  const add = (el: Element) => {
    const b = el.getBoundingClientRect();
    if (b.width && b.height) rects.push({ x: Math.floor(b.left), y: Math.floor(b.top), w: Math.ceil(b.width), h: Math.ceil(b.height) });
  };
  // a card face, only the part of it in the row's window
  const clipAdd = (el: Element) => {
    const b = el.getBoundingClientRect();
    const v = row.viewport;
    const l = v ? Math.max(b.left, v[0]) : b.left;
    const r = v ? Math.min(b.right, v[1]) : b.right;
    if (r - l > 0 && b.height) rects.push({ x: Math.floor(l), y: Math.floor(b.top), w: Math.ceil(r - l), h: Math.ceil(b.height) });
  };
  if (dragging) rects.push({ x: 0, y: 0, w: innerWidth, h: innerHeight });
  else {
    if (island.classList.contains('shown')) add(island);
    // the strip at the top centre takes the pointer: pushed against the top edge it opens the island, even with
    // nothing to show (else an empty island could never be found). Not while the island stays hidden at rest
    // (app.island_idle off): there the top edge is the apps' own — a maximized browser's tabs took these clicks. The
    // cards are then the tray's Show Cards, the cards key and the main window's notice.
    if (S.idle !== false) add(hot);
    if (downK.value > 0.5) {
      for (const l of live) if ((l.phase === 'hang' || l.phase === 'fly') && l.el.style.display !== 'none' && inView(l)) clipAdd(l.face);
      // a row that scrolls takes the pointer across its band, gaps included, so a swipe over it reaches it
      const v = row.viewport;
      if (v) {
        const top = islandBottom() + BELOW;
        rects.push({ x: Math.floor(v[0]), y: Math.floor(top), w: Math.ceil(v[1] - v[0]), h: Math.max(84, ...hanging().map((l) => l.h)) });
      }
    }
    if (!menuEl.hidden) for (const m of [menuEl, ...menuEl.querySelectorAll('.mi.has-sub:hover > .sub')]) add(m);
    if (!panelEl.hidden) add(panelEl);
    if (!previewEl.hidden) add(previewEl);
    if (!selPill.hidden) add(selPill);
  }
  // nothing showing: the window may follow the pointer to another screen (Island.swift poll)
  const idle =
    !open && !drawer && !toastNow && !S.recording && !S.voice && !S.dictation && !dragging && menuEl.hidden && panelEl.hidden && previewEl.hidden;
  const s = JSON.stringify(rects) + idle;
  if (s !== lastHits || force) {
    lastHits = s;
    void host.emit(EV.hitRects, { rects, idle });
  }
}
menuEl.addEventListener('pointerover', () => reportHits());

// ------------------------------------------------------------------ the Cards panel (CardsOverview) and its preview
// "Cards" with two segments — Current N (the cards at the top of the screen) and History N (the ones dragged out or
// pasted into another app in the last 7 days). Show Cards (the hotkey, the tray), and the open island's cards row
// open it; it sits under the strip the cards hang in, takes the keyboard (given back on close) and closes
// when another app is clicked (the window loses the keyboard: the Mac's light panel). Keys: CardsPanelRules.
type HCard = Card & { wall?: number | null; taken?: number };
let history: HCard[] = [];
let panel: null | { seg: Segment; focus: number | null; pointed: number | null } = null;
let preview: null | { i: number } = null;
const panelEl = document.createElement('div');
panelEl.className = 'panel';
panelEl.hidden = true;
panelEl.setAttribute('role', 'dialog');
const previewEl = document.createElement('div');
previewEl.className = 'preview';
previewEl.hidden = true;
// "✓ 2 selected · Copied" under the row (the Ctrl-click selection)
const selPill = document.createElement('div');
selPill.className = 'selpill';
selPill.hidden = true;
stage.append(panelEl, previewEl, selPill);

const nowS = () => Date.now() / 1000;
function agoText(sec: number): string {
  const a = cardAgo(sec);
  if (a.k === 'just') return t('island.time.just_now');
  if (a.k === 'yesterday') return t('island.time.yesterday');
  return plural(a.k === 'min' ? 'island.time.minutes_ago' : a.k === 'hr' ? 'island.time.hours_ago' : 'island.time.days_ago', a.n);
}
const timeOf = (wall?: number | null) => (wall ? new Date(wall * 1000).toLocaleTimeString(i18n.lang, { hour: '2-digit', minute: '2-digit' }) : '');
/** "Snap · 19:03" / "Voice note · 19:03": what a card is and when, where it has no words of its own. */
const cardName = (c: HCard) => {
  const what = isVoice(c) ? t('island.cards.voice') : t('island.card.snap');
  const at = timeOf(c.wall);
  return at ? `${what} · ${at}` : what;
};
const panelCards = (seg: Segment): HCard[] => (seg === 'hanging' ? hanging().slice().reverse().map((l) => l.card as HCard) : history);
const liveOf = (c: Card) => live.find((l) => l.key === keyOf(c) && (l.phase === 'hang' || l.phase === 'fly'));

function togglePanel() {
  const r = CardsPanelRules.toggle(!!panel, cardCount(), history.length);
  if (r === 'close') return closePanel();
  // nothing: Peep says so, with the key that makes one (never a dead end)
  if (r === 'nothing') return postToast({ key: 'cards-none', text: S.hotkeys.snap ? t('island.cards.none_detail', { key: S.hotkeys.snap }) : t('island.cards.none') });
  openPanel(r, false);
}

function openPanel(seg: Segment, focusFirst: boolean) {
  void host.emit(EV.action, { action: 'cards.history' });
  const had = !!panel;
  panel = { seg, focus: focusFirst && panelCards(seg).length ? 0 : null, pointed: null };
  if (!had) {
    panelFocused = document.hasFocus();
    panelOpenedAt = performance.now();
    void host.emit(EV.action, { action: 'keyboard', on: true });
  }
  closeMenu();
  renderPanel();
  setTimeout(() => panelEl.focus(), 0);
}

function closePanel() {
  if (!panel) return;
  panel = null;
  preview = null;
  panelEl.hidden = true;
  previewEl.hidden = true;
  panelEl.innerHTML = '';
  previewEl.innerHTML = '';
  // the keyboard goes back where the user was (unless the switcher or Discard's question still needs it)
  if (drawer !== 'switch' && !confirmDiscard) void host.emit(EV.action, { action: 'keyboard', on: false });
  render();
  reportHits(true);
}

// the light panel: another app took the keyboard (a click outside) — it closes. Only once it really had the keyboard:
// Windows may hand the activation over a moment late (the foreground lock), and a blur from before that is no click
// outside
let panelFocused = false;
let panelOpenedAt = 0;
addEventListener('focus', () => {
  if (panel) panelFocused = true;
});
addEventListener('blur', () => {
  if (panel && panelFocused && performance.now() - panelOpenedAt > 400) closePanel();
});

const keycap = (k: string) => `<kbd>${esc(k)}</kbd>`;
function keysHtml(items: [string[], string][]) {
  return items.map(([ks, label]) => `<span class="kh">${ks.map(keycap).join('')}<span>${esc(label)}</span></span>`).join('');
}

function tileHtml(c: HCard, i: number, seg: Segment) {
  const f = panel!.focus === i;
  const pointed = panel!.pointed === i;
  const pic = isVoice(c)
    ? `<div class="tpic voice">${ic('mic', 13, 'vmic')}<span>${esc(c.text || t('island.card.transcribing'))}</span></div>`
    : `<div class="tpic"><img alt="" draggable="false" crossorigin="anonymous" src="${esc(c.src)}"></div>`;
  const note = !isVoice(c) ? `<div class="tnote${c.text ? '' : ' quiet'}">${esc(c.text || cardName(c))}</div>` : '';
  const left = seg === 'used' && c.taken ? daysLeft(c.taken, nowS()) : 9;
  const last = left <= 1 ? `<div class="tlast">${esc(plural('island.taken.days_left', left))}</div>` : '';
  return `<div class="ptile${f ? ' focus' : ''}${pointed ? ' hover' : ''}" data-i="${i}" role="button" aria-label="${esc(c.text || cardName(c))}">${pic}
    <div class="tacts"><button data-t="preview" aria-label="${esc(t('island.card.preview'))}">${ic('eye', 13)}</button><button data-t="menu" aria-label="${esc(t('island.taken.more'))}">${ic('more', 13)}</button><button data-t="copy" class="tcopy">${esc(t('island.taken.copy'))}</button></div>
    ${note}${last}</div>`;
}

function renderPanel() {
  if (!panel) return;
  const seg = panel.seg;
  const cards = panelCards(seg);
  const nh = cardCount();
  const nu = history.length;
  // as wide as the wider of the two segments' grids: switching never changes its shape
  const cols = gridColumns(cards.length || 1);
  const w = Math.max(PANEL_MIN_W, gridWidth(gridColumns(Math.max(1, nh))), gridWidth(gridColumns(Math.max(1, nu))));
  const segBtn = (sg: Segment, label: string) => `<button role="tab" data-seg="${sg}" aria-selected="${seg === sg}" class="${seg === sg ? 'on' : ''}">${esc(label)}</button>`;
  const head = `<div class="ph"><span class="pt">${esc(t('island.cards.title'))}</span>
    <div class="segs" role="tablist" aria-label="${esc(t('island.cards.segments_ax'))}">${segBtn('hanging', t('island.cards.seg_current', { n: num(nh) }))}${segBtn('used', t('island.cards.seg_history', { n: num(nu) }))}</div>
    <span class="grow"></span>${seg === 'hanging' && nh ? `<button class="pbtn" data-p="more" aria-label="${esc(t('island.taken.more'))}">${ic('more', 15)}</button>` : ''}
    <button class="pbtn" data-p="close" aria-label="${esc(t('island.panel.close'))}">${ic('x', 14)}</button></div>`;
  let grid: string;
  if (!cards.length) {
    const expired = seg === 'used' && false;
    const title = seg === 'used' ? (expired ? 'island.cards.history_expired_title' : 'island.cards.history_empty_title') : 'island.cards.current_empty_title';
    const hint = seg === 'used' ? (expired ? 'island.cards.history_expired_hint' : 'island.cards.history_empty_hint') : 'island.cards.current_empty_hint';
    grid = `<div class="pempty"><div class="et">${esc(t(title))}</div><div class="eh">${esc(t(hint))}</div></div>`;
  } else {
    grid = `<div class="pgrid" style="grid-template-columns:repeat(${cols}, ${TILE_W}px)">${cards.map((c, i) => tileHtml(c, i, seg)).join('')}</div>`;
  }
  // the footer: the tile pointed at (or the keyboard's) — its whole note and when — else how to use a tile; the keys
  const fi = panel.pointed ?? panel.focus ?? (seg === 'used' && cards.length ? 0 : null);
  const fc = fi !== null ? cards[fi] : undefined;
  const when = fc ? (seg === 'used' && fc.taken ? t('island.cards.history_when', { ago: agoText(nowS() - fc.taken) }) : timeOf(fc.wall)) : '';
  const foot = fc
    ? `<span class="fnote">${esc(fc.text || cardName(fc))}</span>${when ? `<span class="fwhen">${esc(when)}</span>` : ''}`
    : `<span class="fhint">${esc(t(seg === 'used' ? 'island.cards.history_hint' : 'island.cards.overview_hint'))}</span>`;
  const keys = cards.length
    ? keysHtml([
        [['←', '→'], t('island.keys.choose')],
        [['Enter'], t('island.keys.copy')],
        [['Space'], t('island.keys.preview')],
        [['Del'], t('island.keys.delete')],
        [['Esc'], t('island.keys.close')],
      ])
    : '';
  panelEl.style.width = `${w}px`;
  panelEl.innerHTML = `${head}${grid}<div class="pfoot"><div class="pfl">${foot}</div><div class="pkeys">${keys}</div></div>`;
  panelEl.hidden = false;
  placePanel();
  if (preview) renderPreview();
  reportHits(true);
}

/** Under the strip the cards hang in, whether they are down or not, so cards that come down never cover its title
 *  (CardRow.panelTop); right under the island when no card hangs. */
function placePanel() {
  if (panelEl.hidden) return;
  const band = hanging().length && !panel ? BELOW + 84 + 30 : 0;
  const top = islandBottom() + band + 12;
  const W = stage.clientWidth || innerWidth;
  const w = panelEl.offsetWidth;
  panelEl.style.transform = `translate(${Math.round(Math.max(8, (W - w) / 2))}px, ${Math.round(top)}px)`;
  panelEl.style.maxHeight = `${Math.max(200, (stage.clientHeight || innerHeight) - top - 12)}px`;
}

function panelTile(el: Element | null): { i: number; c: HCard } | null {
  const tEl = (el as HTMLElement | null)?.closest<HTMLElement>('.ptile');
  if (!tEl || !panel) return null;
  const i = Number(tEl.dataset.i);
  const c = panelCards(panel.seg)[i];
  return c ? { i, c } : null;
}

function copyPanelCard(c: HCard) {
  void host.emit(EV.action, { action: 'card.copy', ...cardRef(c) });
  earMoment(t('island.cards.copied'));
}

function deletePanelCard(c: HCard) {
  if (!panel) return;
  if (panel.seg === 'hanging') {
    const l = liveOf(c);
    if (l) deleteCards([l]);
  } else {
    void host.emit(EV.action, { action: 'card.remove', ...cardRef(c) });
    history = history.filter((h) => keyOf(h) !== keyOf(c));
    postToast({ key: 'delete', text: plural('island.card.deleted', 1), overOpen: true, ms: UNDO_MS, action: { a: 'card.restore', label: 'island.undo', extra: { cards: [cardRef(c)] } } });
  }
  panel.focus = panel.focus === null ? null : Math.min(panel.focus, panelCards(panel.seg).length - 2);
  if (panel.focus !== null && panel.focus < 0) panel.focus = null;
  setTimeout(renderPanel, 30);
}

function panelMenu(c: HCard, i: number, x: number, y: number) {
  const pv: MenuItem = { label: t('island.card.preview'), run: () => openPreview(i) };
  if (panel?.seg === 'hanging') {
    const l = liveOf(c);
    if (l) return showCardMenu(l, x, y, [pv, { sep: true, label: '' }]);
    return;
  }
  // History: Preview · Copy Image · Copy Note · Put Back · Show in File Explorer · Delete
  const items: MenuItem[] = [pv, { sep: true, label: '' }];
  if (c.src) items.push({ label: t('island.card.copy_image'), run: () => copyPanelCard(c) });
  if (c.text) items.push({ label: t('island.taken.copy_note'), run: () => (void host.emit(EV.action, { action: 'card.copy_text', ...cardRef(c) }), earMoment(t('island.cards.copied'))) });
  items.push({
    label: t('island.taken.put_back'),
    run: () => {
      void host.emit(EV.action, { action: 'card.putback', ...cardRef(c) });
      history = history.filter((h) => keyOf(h) !== keyOf(c));
      revealCards(true);
      renderPanel();
    },
  });
  if (c.file) items.push({ label: t('island.card.reveal'), run: () => void host.emit(EV.action, { action: 'card.reveal', ...cardRef(c) }) });
  items.push({ sep: true, label: '' });
  items.push({ label: t('island.card.delete'), run: () => deletePanelCard(c) });
  showMenu(items, x, y);
}

const panelClicks = new DeferredClick<string>();
panelEl.addEventListener('click', (e) => {
  const el = e.target as HTMLElement;
  const segB = el.closest<HTMLElement>('[data-seg]');
  if (segB && panel) return switchSeg(segB.dataset.seg as Segment);
  const pb = el.closest<HTMLElement>('[data-p]');
  if (pb?.dataset.p === 'close') return closePanel();
  if (pb?.dataset.p === 'more') {
    // Current's ···: Copy All, Organize All, Delete All (the island's menu)
    const r = pb.getBoundingClientRect();
    return showIslandMenu(r.left, r.bottom + 6);
  }
  const tt = panelTile(el);
  if (!tt || !panel) return;
  if (preview) closePreview();
  const act = el.closest<HTMLElement>('[data-t]')?.dataset.t;
  if (act === 'preview') return openPreview(tt.i);
  if (act === 'copy') return copyPanelCard(tt.c);
  if (act === 'menu') {
    const r = el.closest('[data-t]')!.getBoundingClientRect();
    return panelMenu(tt.c, tt.i, r.left, r.bottom + 4);
  }
  if (tileDragged) return void (tileDragged = false);
  // click = copy once the double-click interval has passed; double-click = edit the note (Current) / preview (History)
  const k = keyOf(tt.c);
  if (panelClicks.click(k, e.detail, performance.now(), DOUBLE_CLICK_MS) === 'edit') {
    if (panel.seg === 'hanging') void host.emit(EV.action, { action: 'card.note', ...cardRef(tt.c), rect: faceRect(tt.c, panelEl.querySelector(`.ptile[data-i="${tt.i}"]`)) });
    else openPreview(tt.i);
    return;
  }
  setTimeout(() => panelClicks.fire(performance.now()) === k && copyPanelCard(tt.c), DOUBLE_CLICK_MS + 10);
});
panelEl.addEventListener('contextmenu', (e) => {
  e.preventDefault();
  const tt = panelTile(e.target as Element);
  if (tt) panelMenu(tt.c, tt.i, e.clientX, e.clientY);
});
panelEl.addEventListener('pointerover', (e) => {
  if (!panel) return;
  const tt = panelTile(e.target as Element);
  const i = tt ? tt.i : null;
  if (i !== panel.pointed) {
    panel.pointed = i;
    for (const el of panelEl.querySelectorAll<HTMLElement>('.ptile')) el.classList.toggle('hover', Number(el.dataset.i) === i);
    updatePanelFoot();
  }
});
panelEl.addEventListener('pointerleave', () => {
  if (!panel) return;
  panel.pointed = null;
  for (const el of panelEl.querySelectorAll<HTMLElement>('.ptile.hover')) el.classList.remove('hover');
  updatePanelFoot();
});
function updatePanelFoot() {
  // (a full render would restart the pictures: the footer alone)
  const keep = panelEl.querySelector('.pgrid')?.scrollTop ?? 0;
  renderPanel();
  const g = panelEl.querySelector('.pgrid');
  if (g) g.scrollTop = keep;
}

function switchSeg(seg: Segment) {
  if (!panel || panel.seg === seg) return;
  panel.seg = seg;
  panel.focus = null;
  panel.pointed = null;
  closePreview();
  renderPanel();
}

function panelKeyDown(e: KeyboardEvent): boolean {
  if (!panel || drawer === 'switch' || confirmDiscard) return false;
  const k = panelKey(e);
  if (!k) return false;
  e.preventDefault();
  if (preview) {
    const a = CardsPanelRules.previewAction(k);
    if (a.a === 'step') stepPreview(a.d);
    else if (a.a === 'close') closePreview();
    return true;
  }
  const cards = panelCards(panel.seg);
  const cols = gridColumns(cards.length || 1);
  const a = CardsPanelRules.action(k, panel.seg, panel.focus, cards.length, cols, panel.pointed);
  switch (a.a) {
    case 'segment':
      switchSeg(a.seg);
      break;
    case 'focus':
      panel.focus = a.i;
      renderPanel();
      panelEl.querySelector('.ptile.focus')?.scrollIntoView({ block: 'nearest' });
      break;
    case 'preview':
      openPreview(a.i);
      break;
    case 'copyAndClose':
      // copies and closes: the keyboard back where the user was, so Ctrl+V pastes it
      copyPanelCard(cards[a.i]);
      closePanel();
      break;
    case 'delete':
      deletePanelCard(cards[a.i]);
      break;
    case 'close':
      closePanel();
      break;
  }
  return true;
}

// --- the big preview (CardPreview): the card at its size or fitted to 80 % of the screen; ← → the card before / after
function openPreview(i: number) {
  if (!panel) return;
  preview = { i };
  renderPreview();
}
function closePreview() {
  if (!preview) return;
  preview = null;
  previewEl.hidden = true;
  previewEl.innerHTML = '';
  panelEl.classList.remove('behind');
  reportHits(true);
}
function stepPreview(d: number) {
  if (!panel || !preview) return;
  const n = panelCards(panel.seg).length;
  preview.i = Math.min(n - 1, Math.max(0, preview.i + d));
  renderPreview();
}
function renderPreview() {
  if (!panel || !preview) return;
  const cards = panelCards(panel.seg);
  const c = cards[preview.i];
  if (!c) return closePreview();
  const W = stage.clientWidth || innerWidth;
  const H = stage.clientHeight || innerHeight;
  // one fixed frame for the whole run of cards (← → never makes it jump): the picture fitted whole inside it
  const fw = Math.round(Math.min(W * 0.8, 960));
  const fh = Math.round(Math.min(H * 0.8 - 104, 600));
  const body = isVoice(c)
    ? `<div class="pvwords">${esc(c.text || t('island.card.transcribing'))}</div>`
    : `<img alt="" draggable="false" src="${esc(c.src)}">`;
  // the header says what and when (and where in the run); the footer the note, once
  const kind = cardName(c);
  const used = panel.seg === 'used' && c.taken ? t('island.cards.history_when', { ago: agoText(nowS() - c.taken) }) : '';
  previewEl.style.width = `${fw}px`;
  previewEl.innerHTML = `<div class="ph"><span class="pt">${esc(kind)}</span><span class="pcount">${num(preview.i + 1)} / ${num(cards.length)}</span><span class="grow"></span>
    <button class="pbtn" data-pv="close" aria-label="${esc(t('island.panel.close'))}">${ic('x', 14)}</button></div>
    <div class="pvbody" style="height:${fh}px">${body}</div>
    <div class="pfoot"><div class="pfl"><span class="fnote">${esc(c.text || '')}</span>${used ? `<span class="fwhen">${esc(used)}</span>` : ''}</div></div>`;
  // the preview takes the panel's place: nothing half-covered behind it
  panelEl.classList.add('behind');
  previewEl.hidden = false;
  requestAnimationFrame(() => placePreview());
  placePreview();
  reportHits(true);
}
function placePreview() {
  if (previewEl.hidden) return;
  const W = stage.clientWidth || innerWidth;
  const H = stage.clientHeight || innerHeight;
  previewEl.style.transform = `translate(${Math.round((W - previewEl.offsetWidth) / 2)}px, ${Math.round(Math.max(8, (H - previewEl.offsetHeight) / 2))}px)`;
}
previewEl.addEventListener('click', (e) => {
  if ((e.target as HTMLElement).closest('[data-pv="close"]')) closePreview();
});
previewEl.addEventListener('load', () => (placePreview(), reportHits(true)), true);

// --- a tile dragged: onto a project in the island (Current), or out into any app (both)
let tileDragged = false;
panelEl.addEventListener('pointerdown', (e) => {
  const tt = panelTile(e.target as Element);
  if (!tt || e.button !== 0 || (e.target as HTMLElement).closest('[data-t]') || !panel) return;
  const seg = panel.seg;
  const tEl = (e.target as HTMLElement).closest<HTMLElement>('.ptile')!;
  const r0 = tEl.getBoundingClientRect();
  const start = { x: e.clientX, y: e.clientY, ox: e.clientX - r0.left, oy: e.clientY - r0.top };
  let moved = false;
  let ghost: HTMLElement | null = null;
  tEl.setPointerCapture(e.pointerId);
  const end = () => {
    tEl.removeEventListener('pointermove', move);
    tEl.removeEventListener('pointerup', up);
    tEl.removeEventListener('pointercancel', up);
    ghost?.remove();
    stage.classList.remove('dragging');
    tEl.classList.remove('lifting');
  };
  const move = (ev: PointerEvent) => {
    if (!moved && Math.hypot(ev.clientX - start.x, ev.clientY - start.y) < 4) return;
    if (!moved) {
      moved = true;
      panelClicks.cancel();
      closeMenu();
      tEl.classList.add('lifting');
      ghost = tEl.cloneNode(true) as HTMLElement;
      ghost.className = 'ptile ghost';
      stage.append(ghost);
      stage.classList.add('dragging');
      reportHits(true);
    }
    ghost!.style.transform = `translate(${ev.clientX - start.ox}px, ${ev.clientY - start.oy}px) rotate(-0.03rad)`;
    const near = seg === 'hanging' && inZone(islandZone(drawer === 'drop' ? 24 : 70), ev.clientX, ev.clientY);
    if (near !== (drawer === 'drop')) {
      drawer = near ? 'drop' : null;
      open = near;
      lastBody = '';
      render();
    }
    highlight(ev.clientX, ev.clientY);
    const pr = panelEl.getBoundingClientRect();
    const outside = !near && !inZone({ l: pr.left, r: pr.right, t: pr.top, b: pr.bottom }, ev.clientX, ev.clientY);
    if (outside && (tt.c.file || (isVoice(tt.c) && tt.c.text))) {
      // off the panel: the system's own drag takes it on to another app
      tEl.releasePointerCapture(ev.pointerId);
      end();
      tileDragged = true;
      reportHits(true);
      void host.emit(EV.action, { action: 'card.dragout', ...cardRef(tt.c), ...dragImage(tt.c, tEl, { ox: start.ox, oy: start.oy }) });
    }
  };
  const up = (ev: PointerEvent) => {
    end();
    if (!moved) return;
    tileDragged = true;
    const target = targetAt(ev.clientX, ev.clientY);
    if (drawer === 'drop') {
      drawer = null;
      open = false;
      lastBody = '';
    }
    const l = liveOf(tt.c);
    if (target && l) fileCards([l], target);
    render();
    setTimeout(renderPanel, 30);
  };
  tEl.addEventListener('pointermove', move);
  tEl.addEventListener('pointerup', up);
  tEl.addEventListener('pointercancel', up);
});

/** The card as the island draws it, for the system's drag image: a PNG of its face at the screen's scale, and where
 *  the pointer holds it (physical px). */
function dragImage(c: Card, el: HTMLElement, at: { ox: number; oy: number }): { image?: string; ox: number; oy: number } {
  const dpr = devicePixelRatio || 1;
  const r = el.getBoundingClientRect();
  const w = Math.round(Math.min(r.width, 240));
  const h = Math.round(Math.min(r.height, 180));
  try {
    const cv = document.createElement('canvas');
    cv.width = Math.round(w * dpr);
    cv.height = Math.round(h * dpr);
    const g = cv.getContext('2d')!;
    g.scale(dpr, dpr);
    const round = (x: number, y: number, ww: number, hh: number, rr: number) => {
      g.beginPath();
      g.roundRect(x, y, ww, hh, rr);
    };
    round(0, 0, w, h, 10);
    g.fillStyle = '#fbfaf7';
    g.fill();
    const img = el.querySelector('img');
    if (img && img.naturalWidth && !isVoice(c)) {
      g.save();
      round(3, 3, w - 6, h - 6, 7);
      g.clip();
      const k = Math.max((w - 6) / img.naturalWidth, (h - 6) / img.naturalHeight);
      g.drawImage(img, 3, 3, img.naturalWidth * k, img.naturalHeight * k);
      g.restore();
    } else {
      g.fillStyle = '#26221c';
      g.font = `500 12px "Segoe UI", system-ui, sans-serif`;
      g.textBaseline = 'top';
      const words = (c.text ?? '').replace(/\s+/g, ' ');
      let line = '';
      let y = 9;
      for (const ch of words) {
        if (g.measureText(line + ch).width > w - 22) {
          g.fillText(line, 11, y);
          line = ch;
          y += 16;
          if (y > h - 18) break;
        } else line += ch;
      }
      if (y <= h - 18) g.fillText(line, 11, y);
    }
    return { image: cv.toDataURL('image/png'), ox: Math.round(at.ox * dpr), oy: Math.round(at.oy * dpr) };
  } catch {
    return { ox: Math.round(at.ox * dpr), oy: Math.round(at.oy * dpr) };
  }
}

// ------------------------------------------------------------------ ops from the app
function apply(op: IslandOp) {
  switch (op.op) {
    case 'state': {
      if (op.state.lang) setLang(op.state.lang);
      if (!S.recording && op.state.recording) {
        confirmDiscard = false;
        // the take starts: the cards go up and stay there (an earlier reveal doesn't carry over)
        stickyAt = 0;
        revealUntil = 0;
        penTakes += 1;
        try {
          localStorage.setItem('blurt.penHintTakes', String(penTakes));
        } catch {
          /* private storage: the hint just shows */
        }
      }
      if (S.recording && !op.state.recording && confirmDiscard) setConfirm(false);
      if ((op.state.recording && !S.recording) || (op.state.voice && !S.voice)) parkWaiting();
      if (op.state.voice && !S.voice) waveHist.length = 0;
      // the inbox grew (not the first count): "+n" for a moment
      const n = op.state.toReview ?? 0;
      if (lastReview >= 0 && n > lastReview) news = { n: (news && performance.now() < news.until ? news.n : 0) + n - lastReview, until: performance.now() + NEWS_MS };
      lastReview = n;
      // a dictation or a voice note starting: the open island folds away, so its ears show
      if ((op.state.dictation && !S.dictation) || (op.state.voice && !S.voice && !op.state.expanded)) {
        if (drawer === 'switch') closeSwitcher();
        open = false;
      }
      S = op.state;
      stateAt = performance.now();
      if (op.state.expanded) open = true;
      if (drawer === 'switch') selIx = Math.min(selIx, Math.max(0, choices().length - 1));
      lastBody = '';
      break;
    }
    case 'cards':
      setCards(op.cards);
      break;
    case 'card':
      addCard(op.card, op.pull, op.from);
      return;
    case 'toast': {
      // the take's ✓ and length own the ears for their 1.6 s: a line that follows the take ("Organizing into …") waits
      // for it instead of covering it (a card refresh in between used to take the moment at 100 %)
      const wait = recDone ? recDone.until - performance.now() : 0;
      if (wait > 0 && op.kind === 'capture') {
        setTimeout(() => showToastOp(op), wait + 20);
        return;
      }
      return showToastOp(op);
    }
    case 'toast_drop':
      // what the island said under these keys is over (a new take, the end of listening, a take that landed)
      if (toastNow?.key && op.keys.includes(toastNow.key)) dismissToast();
      for (let i = toastWait.length - 1; i >= 0; i--) if (toastWait[i].key && op.keys.includes(toastWait[i].key!)) toastWait.splice(i, 1);
      break;
    case 'switcher':
      if (op.open) openSwitcher();
      else closeSwitcher();
      break;
    case 'pick':
      openPicker(op);
      break;
    case 'hover': {
      // over the pill or the strip above it with no mouseenter seen, or gone with no mouseleave (the window turned
      // click-through under a pointer that had stopped)
      const inside = (el: Element) => {
        const b = el.getBoundingClientRect();
        return b.width > 0 && op.x >= b.left && op.x < b.right && op.y >= b.top && op.y < b.bottom;
      };
      if (op.out) hoverOut(); // off everything the island draws (cards and menus included)
      else if ((island.classList.contains('shown') && inside(island)) || inside(hot)) hoverIn();
      break;
    }
    case 'peek':
      peekUntil = performance.now() + 3000;
      setTimeout(render, 3050);
      break;
    case 'status':
      if (op.line.ev === 'level') level = op.line.rms;
      if (op.line.ev === 'snap' && S.cardPrefs?.snapSound) shutter();
      return ticks();
    case 'caption':
      return showCaption(op.text ?? '');
    case 'live':
      liveText = op.text || op.partial ? { text: op.text, partial: op.partial ?? '', typed: !!op.typed } : null;
      break;
    case 'level':
      level = op.rms;
      return ticks();
    case 'dragout':
      return dragOut(op);
    case 'reveal':
      revealCards(true);
      if (op.open && cardCount()) {
        setOpen(true);
        // brought down on purpose: it stays until the pointer has come and gone — or, if it never comes, 10 s
        const at = performance.now();
        const check = () => {
          if (!open) return;
          if (hovering || cardHover) return; // the pointer came: leaving closes it as usual
          if (performance.now() - at >= CardReveal.unvisited) setOpen(false);
          else setTimeout(check, 1000);
        };
        setTimeout(check, 1000);
      }
      break;
    case 'busy':
      busyCapture = op.on;
      if (op.on) {
        // a new capture: the last one's line is over ("Snap discarded · Undo" over the next picker); a question waits
        parkWaiting();
        if (toastNow && !toastNow.passive && toastNow.mark !== 'warning') toastNow = null;
      }
      break;
    case 'working':
      readingUntil = op.on ? performance.now() + 30000 : 0;
      break;
    case 'editing':
      // Edit Note is up under a card: the row stays where it is until it closes (the Mac keeps the card it edits)
      editing = op.on;
      if (!op.on) revealUntil = Math.max(revealUntil, performance.now() + 900);
      kick();
      break;
    case 'rec_done':
      recDone = { text: op.length, until: performance.now() + 1600 };
      setTimeout(render, 1650);
      break;
    case 'history':
      history = (op.cards as HCard[]) ?? [];
      if (panel) renderPanel();
      break;
    case 'panel':
      togglePanel();
      break;
    case 'shutter':
      return shutter();
  }
  render();
}

await host.on<IslandOp>(EV.island, apply);
render();
reportHits(true);
// the launch hello, once, when nothing live is in the ears (Island.hello's guard)
setTimeout(() => {
  if (S.recording || S.voice || S.dictation || toastNow || open || drawer) return;
  helloUntil = performance.now() + HELLO_MS;
  render();
  setTimeout(render, HELLO_MS + 60);
}, HELLO_AFTER_MS);
// scripted smoke runs read what the island shows (apps/desktop: BLURT_TEST_EVAL)
(window as unknown as { __island: () => unknown }).__island = () => ({
  open: island.classList.contains('open'),
  shown: island.classList.contains('shown'),
  drawer,
  recording: S.recording,
  hatching: S.hatching,
  toReview: S.toReview,
  project: S.project?.name ?? null,
  cards: live.filter((l) => l.phase === 'hang' || l.phase === 'fly').map((l) => ({ n: l.card.n, kind: l.card.kind, text: l.card.text })),
  row: { centres: row.centres, span: row.span, scroll: row.scroll, maxScroll: row.maxScroll, down: downK.value },
  pill: pill.innerText,
  toast: toastNow ? { text: toastNow.text, action: toastNow.action?.label ?? null } : null,
});

await ready(host, 'island', (push) => {
  // ?demo=1 idle, expanded · rec · voice · drop (a card being filed) · switch · toast · cards · dict · live · discard ·
  // menu (a card's right-click menu) · ears (collapsed, cards waiting) · many (eight cards: five and "+3")
  const demo = params.get('demo') ?? '1';
  const shot = (n: number, hue: number, text: string | null, w = 224, h = 168): Card => ({
    n,
    text,
    kind: 'shot',
    session: '/demo/inbox/sessions/20261022-101500-shots',
    src:
      'data:image/svg+xml,' +
      encodeURIComponent(
        `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="${w}" height="${h}" fill="hsl(${hue} 45% 60%)"/><rect x="${w * 0.07}" y="${h * 0.1}" width="${w * 0.5}" height="${h * 0.07}" rx="4" fill="#fff" opacity=".85"/><rect x="${w * 0.07}" y="${h * 0.24}" width="${w * 0.86}" height="${h * 0.65}" rx="8" fill="#fff" opacity=".42"/></svg>`,
      ),
  });
  const zh = i18n.lang === 'zh-Hans';
  const projects = [
    { id: 'p1', name: 'bug-agent', key: 'BA' },
    { id: 'p2', name: 'airank', key: 'AIR' },
    { id: 'p3', name: zh ? '官网改版' : 'website-refresh', key: 'WR' },
    ...(demo === 'missing' ? [{ id: 'p4', name: 'billing-api', key: 'BIL', exists: false }] : []),
  ];
  const base: IslandState = {
    project: ['auto', 'drop', 'ears', 'many'].includes(demo) ? null : projects[0],
    projects,
    toReview: 5,
    recording: null,
    voice: null,
    hatching: demo === '1' ? 1 : 0,
    jobs: demo === '1' ? [{ id: 'j1', type: 'process', title: zh ? '价格页走查' : 'Pricing page walkthrough', step: 'write', progress: 0.62 }] : [],
    hotkeys: { record: 'Alt+Shift+R', snap: 'Alt+Shift+A', voice: 'Alt+Shift+V', project: 'Alt+Shift+O', pen: 'Alt+Shift+D' },
    expanded: ['1', 'rec', 'voice', 'auto', 'discard', 'quiet', 'pen'].includes(demo),
  };
  if (demo === 'quiet') Object.assign(base, { toReview: 0 });
  if (demo === 'rec' || demo === 'discard') base.recording = { elapsed: 74, paused: false, shots: 2, at: Date.now() / 1000 };
  // ?demo=pen: the take with the pen on (the pencil in the ear, "Pen on · Esc Pen off")
  if (demo === 'pen') base.recording = { elapsed: 74, paused: false, shots: 0, pen: true, at: Date.now() / 1000 };
  if (demo === 'voice') base.voice = { elapsed: 3, at: Date.now() / 1000, ends: 'key' };
  if (demo === 'dict' || demo === 'live') base.dictation = { phase: 'listening', elapsed: 12, at: Date.now() / 1000, style: 'structured' };
  push(EV.island, { op: 'state', state: base });
  if (demo === 'discard') setTimeout(() => (setConfirm(true), render()), 50);
  if (['rec', 'voice', 'dict', 'live', 'discard', 'pen'].includes(demo)) {
    let k = 0;
    setInterval(() => push(EV.island, { op: 'level', rms: 0.02 + 0.08 * Math.abs(Math.sin(k++ / 3)) }), 100);
  }
  if (demo === 'live')
    push(EV.island, {
      op: 'live',
      text: zh ? '我们把搜索框挪到页面顶部，' : 'Let’s move the search box to the top of the page, ',
      partial: zh ? '再把保存按钮颜色调深一点' : 'and make the save button a bit darker',
    });
  if (demo === 'missing') setTimeout(openSwitcher, 50);
  if (['panel', 'preview', 'history', 'select'].includes(demo)) {
    const now = Date.now() / 1000;
    const notes = zh ? ['保存按钮太浅', '搜索框放到顶部', '价格页的表格错位了', null, '登录后跳转到了旧页面'] : ['Save button too faint', 'Move search to the top', 'The pricing table is misaligned', null, 'Login lands on the old page'];
    push(EV.island, { op: 'cards', cards: notes.map((tx, i) => ({ ...shot(i + 1, 40 + i * 55, tx, i === 2 ? 320 : 224, 168), wall: now - 600 * (5 - i) })) });
    push(EV.island, {
      op: 'history',
      cards: [
        { ...shot(11, 200, zh ? '错误提示看不懂' : 'The error message is unclear'), wall: now - 90000, taken: now - 3600 },
        { n: 12, src: '', kind: 'voice', text: zh ? '把导出按钮放到右上角' : 'Put Export in the top right corner', session: '/demo/inbox/sessions/20261022-101500-shots', wall: now - 400000, taken: now - 6.4 * 86400 },
      ],
    });
    if (demo === 'select') {
      setTimeout(() => {
        const hs = hanging();
        toggleSelected(hs[hs.length - 1]);
        toggleSelected(hs[hs.length - 2]);
        revealCards(true);
      }, 50);
    } else {
      setTimeout(() => {
        openPanel(demo === 'history' ? 'used' : 'hanging', true);
        if (demo === 'preview') openPreview(0);
      }, 50);
    }
  }
  if (['auto', 'drop', 'cards', 'menu', 'ears', 'many', '1'].includes(demo)) {
    const voice: Card = { n: 2, src: '', kind: 'voice', text: zh ? '搜索框放到顶部' : 'Move search to the top', session: '/demo/inbox/sessions/20261022-101500-shots' };
    const manyN = Number(params.get('n')) || 8; // ?n=40: a row long enough to scroll
    const cards = demo === 'many' ? Array.from({ length: manyN }, (_, i) => i + 2).map((n) => shot(n, (n * 40) % 360, n === manyN + 1 ? (zh ? '保存按钮太浅' : 'Save button too faint') : null)) : [shot(1, 210, zh ? '保存按钮太浅' : 'Save button too faint', 320, 120), voice];
    push(EV.island, { op: 'cards', cards });
    if (demo !== 'many') setTimeout(() => push(EV.island, { op: 'card', card: shot(3, 140, null), pull: false }), params.has('still') ? 0 : 500);
    if (demo !== 'ears' && demo !== '1') setTimeout(() => revealCards(true), 10);
  }
  if (demo === 'drop') {
    drawer = 'drop';
    open = true;
    lastBody = '';
    render();
    setTimeout(() => island.querySelector('[data-drop="project:p2"]')?.classList.add('over'), 900);
  }
  if (demo === 'menu') setTimeout(() => {
    const l = hanging()[hanging().length - 1];
    const r = l.face.getBoundingClientRect();
    showCardMenu(l, r.left + 20, r.bottom - 10);
  }, 900);
  if (demo === 'switch') setTimeout(openSwitcher, 50);
  if (demo === 'toast') setTimeout(() => push(EV.island, { op: 'toast', kind: 'sorted', n: 5, job: 'j1' }), 300);
  if (demo === 'undo') {
    push(EV.island, { op: 'cards', cards: [shot(1, 210, null)] });
    setTimeout(() => deleteCards(hanging()), 300);
  }
});
