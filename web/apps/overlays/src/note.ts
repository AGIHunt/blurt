// The note bubble (the Mac's NoteBubble + InkStage; docs/design/windows-parity/snap-and-note.md).
//
// mode=snap — a fresh snap: this window covers the monitor. The picture stays frozen where it was taken, at 1:1, the
// rest of the screen dimmed 42 % as the picker had it, the pen on it (Shift box, Alt ellipse, holding still snaps a
// rough shape clean, Ctrl+Z takes a stroke back); the bubble docks beside it (BubbleDock), its caret pointing at it.
// It listens as it opens (Rust: the mic and the warm speech server) and shows the words heard in grey in the field's
// place; nothing ends it by itself — ↩ / Done / a click outside the picture commit it, Esc clears what was typed and
// then discards the snap (with Undo), Tab takes the grey words (or opens the place list), typing over them replaces
// them, Ctrl+1–4 / Ctrl+0 set its type. The keys are notecore.ts `noteAction` (BlurtCore NoteKeys).
// Params: sel, work (CSS px of this window), n, src, place, projects (JSON), voice (listen | busy | nomic), hint
// (the stage's pen hint), first (the list's keys), lang, platform. Rust → `blurt://note` ops (NoteOp); ← `blurt://action`
// {action: 'note.mic', keep} (Tab / typing stop the mic) and `blurt://note-done` (SnapDone).
//
// Without mode=snap — Edit Note on a card (and a recording's snap note): the same composer in its own small window, the
// picture over the words, "Save ↩"; ?n=3&src=<shot url>&text=<the note>. `note-done` {n, text | null}.
import { iconSvg, type IconName } from '@blurt/icons/core';
import { EV, connect, params, ready, t, type CssRect } from './host';
import {
  InkStroke,
  KINDS,
  clean,
  clock,
  dock,
  inkWidth,
  joined,
  noteAction,
  placeChoices,
  snapTool,
  takenNote,
  editApply,
  merged,
  type Action,
  type DockSide,
  type Key,
  type KeyState,
  type NoteKind,
  type PlaceRef,
  type Pt,
} from './notecore';
import { parseRect } from './geom';
import { projectColor } from './projectlook';

const host = await connect('note');
const $ = <T extends Element>(s: string, root: ParentNode = document) => root.querySelector<T>(s)!;
const ic = (name: IconName | string, size = 16, cls = '') => iconSvg(name as IconName, { size, className: cls ? `ic ${cls}` : 'ic' });
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

const stage = $<HTMLElement>('.stage');
const hole = $<HTMLElement>('.hole');
const frozenImg = $<HTMLImageElement>('.frozen');
const canvas = $<HTMLCanvasElement>('.ink');
const inkHint = $<HTMLElement>('.inkhint');
const dimEl = $<HTMLElement>('.dim');
const bubble = $<HTMLElement>('.bubble');
const bgPath = $<SVGPathElement>('.bg path');
const bgSvg = $<SVGSVGElement>('.bg');
const card = $<HTMLElement>('.card');
const shotImg = $<HTMLImageElement>('.shot');
const bars = $<HTMLElement>('.bars');
const icon = $<HTMLElement>('.icon');
const live = $<HTMLElement>('.live');
const field = $<HTMLTextAreaElement>('textarea');
const placeChip = $<HTMLButtonElement>('.chip.place');
const kindChip = $<HTMLButtonElement>('.chip.kind');
const tools = $<HTMLElement>('.tools');
const status = $<HTMLElement>('.status');
const doneBtn = $<HTMLButtonElement>('.done');
const places = $<HTMLElement>('.list.places');
const filter = $<HTMLInputElement>('.filter input');
const placeRows = $<HTMLElement>('.places .rows');
const placeKeys = $<HTMLElement>('.places .keys');
const kinds = $<HTMLElement>('.list.kinds');
const kindRows = $<HTMLElement>('.kinds .rows');

const snapMode = params.get('mode') === 'snap' || params.get('mode') === 'edit';
/** Edit Note on a card: the same composer in its own window, the picture enlarged in it with its strokes */
const editMode = params.get('mode') === 'edit';
const n = () => Number(params.get('n') ?? 0);
let shotN = n();
document.body.classList.toggle('snap', snapMode);

// ------------------------------------------------------------------ shared: the field, the footer's key line

/** The footer line the way menus set their keys: keys semibold, the words regular, both secondary. */
function keyLine(s: string) {
  return esc(s).replace(/(↑↓|↩|Esc|Tab|Ctrl\+Z|Shift)/g, '<b>$1</b>');
}

/** The primary's key: a thin return arrow at the label's stroke (a font's ↩ renders as a heavy blob in Segoe UI). */
const RET = '<svg class="ret" width="12" height="12" viewBox="0 0 12 12" aria-hidden="true"><path d="M10 2.5v3.2a1.8 1.8 0 0 1-1.8 1.8H2.6M4.6 5.3 2.3 7.5l2.3 2.2" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';

/** A sentence's end on words still being said is the speech model guessing: it shows once the next words (or Tab,
    Enter) settle it, so a stop never flashes in mid-phrase. */
const liveTail = (s: string) => s.replace(/[。．.！!？?]\s*$/u, '');

let measureCtx: CanvasRenderingContext2D | null = null;
function fitField(max: number) {
  field.style.height = '0px';
  let fieldH = field.scrollHeight;
  // empty: its height is the placeholder's lines, measured — never a blank second line under a one-line placeholder
  if (!field.value && field.placeholder) {
    measureCtx ??= document.createElement('canvas').getContext('2d');
    const cs = getComputedStyle(field);
    if (measureCtx) {
      measureCtx.font = `${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`;
      const room = field.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
      fieldH = measureCtx.measureText(field.placeholder).width <= room ? 22 : Math.min(fieldH, 44);
    }
  }
  const want = Math.max(live.hidden ? 0 : live.scrollHeight, fieldH);
  field.style.height = `${Math.min(max, Math.max(20, want))}px`;
}

// ================================================================== Edit Note (a card's note, its own window)

function editNote() {
  let done = false;
  const src = params.get('src');
  shotImg.hidden = !src;
  if (src) shotImg.src = src;
  field.value = params.get('text') ?? '';
  field.placeholder = t('note.placeholder');
  placeChip.hidden = true;
  kindChip.hidden = true;
  doneBtn.innerHTML = `<span>${esc(t('note.save'))}</span>${RET}`;
  doneBtn.title = t('note.save_tip');
  icon.innerHTML = ic('pencil', 16);
  bubble.classList.add('pop', 'caret-up');
  const finish = (text: string | null) => {
    if (done) return;
    done = true;
    void host.emit(EV.noteDone, { n: n(), text: text === null ? null : clean(text) });
    if (host.host === 'browser') document.body.dataset.done = JSON.stringify(text);
  };
  const shape = () => {
    fitField(src ? 90 : 220);
    drawBubble('up', bubble.offsetWidth / 2);
  };
  field.addEventListener('input', shape);
  field.addEventListener('keydown', (e) => {
    if (e.isComposing || e.keyCode === 229) return;
    if (e.key === 'Enter' && !e.shiftKey && !e.ctrlKey && !e.altKey) {
      e.preventDefault();
      finish(field.value);
    }
    if (e.key === 'Escape') finish(null);
  });
  doneBtn.addEventListener('click', () => finish(field.value));
  shotImg.addEventListener('load', shape);
  field.focus({ preventScroll: true });
  field.setSelectionRange(field.value.length, field.value.length);
  shape();
  void ready(host, 'note', () => {
    shotImg.hidden = false;
    shotImg.src =
      'data:image/svg+xml,' +
      encodeURIComponent(
        '<svg xmlns="http://www.w3.org/2000/svg" width="480" height="300"><rect width="480" height="300" fill="#6b8fd6"/><rect x="30" y="30" width="200" height="24" rx="6" fill="#fff" opacity=".8"/><rect x="30" y="80" width="420" height="190" rx="10" fill="#fff" opacity=".45"/></svg>',
      );
    field.value = params.get('text') ?? t('note.demo');
    shape();
  });
}

// ------------------------------------------------------------------ the bubble's outline: card and caret as one path

const CARET = 9;
const R = 14;
type Caret = 'up' | 'down' | 'left' | 'right' | 'none';

function drawBubble(caret: Caret, at: number, tail = true) {
  const w = bubble.offsetWidth;
  const h = bubble.offsetHeight;
  const c = CARET;
  const half = c + 2;
  const ins = { t: caret === 'up' ? c : 0, l: caret === 'left' ? c : 0, b: caret === 'down' ? c : 0, r: caret === 'right' ? c : 0 };
  const b = { x0: 0.5 + ins.l, y0: 0.5 + ins.t, x1: w - 0.5 - ins.r, y1: h - 0.5 - ins.b };
  const x = Math.min(Math.max(at, b.x0 + R + half), b.x1 - R - half);
  const y = Math.min(Math.max(at, b.y0 + R + half), b.y1 - R - half);
  const p: string[] = [`M${b.x0 + R},${b.y0}`];
  if (caret === 'up' && tail) p.push(`L${x - half},${b.y0}L${x},${b.y0 - c}L${x + half},${b.y0}`);
  p.push(`L${b.x1 - R},${b.y0}Q${b.x1},${b.y0} ${b.x1},${b.y0 + R}`);
  if (caret === 'right' && tail) p.push(`L${b.x1},${y - half}L${b.x1 + c},${y}L${b.x1},${y + half}`);
  p.push(`L${b.x1},${b.y1 - R}Q${b.x1},${b.y1} ${b.x1 - R},${b.y1}`);
  if (caret === 'down' && tail) p.push(`L${x + half},${b.y1}L${x},${b.y1 + c}L${x - half},${b.y1}`);
  p.push(`L${b.x0 + R},${b.y1}Q${b.x0},${b.y1} ${b.x0},${b.y1 - R}`);
  if (caret === 'left' && tail) p.push(`L${b.x0},${y + half}L${b.x0 - c},${y}L${b.x0},${y - half}`);
  p.push(`L${b.x0},${b.y0 + R}Q${b.x0},${b.y0} ${b.x0 + R},${b.y0}Z`);
  bgSvg.setAttribute('width', String(w));
  bgSvg.setAttribute('height', String(h));
  bgPath.setAttribute('d', p.join(''));
  card.style.margin = `${ins.t}px ${ins.r}px ${ins.b}px ${ins.l}px`;
}

// ================================================================== a fresh snap

interface SnapDone {
  n: number;
  /** false: Esc / the bin — discarded (Undo brings it back) */
  save: boolean;
  text: string | null;
  /** the words, when the page decides them (taken with Tab); null: Rust's final words for a kept take */
  said: string | null;
  /** keep: the recording becomes the snap's voice; drop: it goes; none: there was none */
  voice: 'keep' | 'drop' | 'none';
  kind: NoteKind | null;
  /** project id; null = Unassigned (a card) */
  place: string | null;
  strokes: number[][][];
  /** the "Saved" moment: Rust closes the window after it */
  flash: boolean;
  /** what the card shows meanwhile (the words heard) */
  heard: string | null;
  /** this note's number */
  g: number;
  /** the pen's line and the picture's width, CSS px (the marked picture keeps the line's look) */
  lw: number;
  selW: number;
}

type NoteOp =
  | { op: 'shot'; n: number; src: string }
  | { op: 'voice'; state: 'listening' | 'busy' | 'nomic' }
  | { op: 'level'; v: number }
  | { op: 'speech' }
  | { op: 'live'; committed: string; pending?: string }
  | { op: 'ended'; why: 'nospeech' | 'maxed' | 'lost' }
  | { op: 'words'; said: string | null }
  | { op: 'commit' }
  | { op: 'failed' };

/** this note's number: Rust's ops for an older note are not this one's */
const gen = Number(params.get('g') ?? 0);

/** Edit Note's enlarged picture (NoteBubble.previewSize): at most 540 × 320, at least 140 × 90, its own shape. */
function previewSize(pw: number, ph: number) {
  const aspect = Math.max(0.2, Math.min(5, pw / Math.max(1, ph)));
  let w = 540;
  let h = w / aspect;
  if (h > 320) {
    h = 320;
    w = h * aspect;
  }
  return { w: Math.max(140, Math.round(w)), h: Math.max(90, Math.round(h)) };
}

function snapNote() {
  stage.hidden = editMode;
  const hasPic = !editMode || !!params.get('src');
  const pv = previewSize(Number(params.get('pw') ?? 1600), Number(params.get('ph') ?? 1000));
  const sel: CssRect = editMode
    ? { x: 0, y: 0, ...pv }
    : (parseRect(params.get('sel')) ?? { x: innerWidth * 0.25, y: innerHeight * 0.2, w: innerWidth * 0.4, h: innerHeight * 0.4 });
  if (editMode) {
    // the picture goes into the bubble, above the words; a voice card has none
    hole.classList.add('pic');
    hole.hidden = !hasPic;
    card.insertBefore(hole, card.querySelector('.row'));
    document.body.classList.add('edit');
  }
  const work: CssRect = parseRect(params.get('work')) ?? { x: 0, y: 0, w: innerWidth, h: innerHeight };
  const projects: PlaceRef[] = (() => {
    try {
      return JSON.parse(params.get('projects') ?? '[]') as PlaceRef[];
    } catch {
      return [];
    }
  })();
  const firstTimes = params.get('first') === '1';
  const unassigned = t('project.inbox');

  // ---- state (NoteBubble's)
  let place: string | null = params.get('place') || null;
  let chosenKind: NoteKind | null = (params.get('kind') as NoteKind | null) || null;
  const v0 = editMode ? 'none' : (params.get('voice') ?? 'nomic');
  let listening = v0 === 'listen';
  // Edit Note: the note as it was opened (NoteEdit), its voice to play, a re-record
  const openedTyped = params.get('typed') || null;
  const openedSaid = params.get('said') || null;
  const voiceSrc = params.get('voiceSrc') ?? '';
  let fieldHoldsSaid = true;
  let player: HTMLAudioElement | null = null;
  let voiceBusy = v0 === 'busy';
  let micGone = false;
  let speechStarted = false;
  let voiceKept = false;
  let voiceDone = false;
  let waitingWords = false;
  let accepted = false;
  let wordsInField: string | null = null;
  let takenRaw: string | null = null;
  let finalWords: string | null = null;
  let heard = { committed: '', pending: '' };
  let typed = false;
  let picking = false;
  let pickingKind = false;
  let hovering = false;
  let inkUndoFirst = false;
  let closed = false;
  let listenSince = performance.now();
  let level = 0;
  let shown = 0;
  const strokes: Pt[][] = (() => {
    try {
      return (JSON.parse(params.get('strokes') ?? '[]') as number[][][]).map((s) => s.map(([x, y]) => ({ x, y })));
    } catch {
      return [];
    }
  })();

  // ---- the stage: the frozen picture, its edge, the dim; a click on the dim is done
  Object.assign(hole.style, editMode ? { width: `${sel.w}px`, height: `${sel.h}px` } : { left: `${sel.x}px`, top: `${sel.y}px`, width: `${sel.w}px`, height: `${sel.h}px` });
  const setShot = (src: string) => {
    if (src) frozenImg.src = src;
  };
  setShot(params.get('src') ?? '');
  // no picture yet: the picker's still of this monitor, cropped to the selection, until the shot arrives — the frozen
  // picture is there the moment the picker goes (the Mac crops its loupe still the same way)
  const still = editMode || params.get('src') ? '' : params.get('still') ?? '';
  const stillShown: Promise<unknown> = still
    ? (() => {
        const im = new Image();
        im.src = still;
        Object.assign(hole.style, { backgroundImage: `url("${still}")`, backgroundSize: `${innerWidth}px ${innerHeight}px`, backgroundPosition: `${-sel.x}px ${-sel.y}px`, backgroundRepeat: 'no-repeat' });
        return Promise.race([im.decode().catch(() => undefined), new Promise((r) => setTimeout(r, 600))]);
      })()
    : Promise.resolve();
  // the dim: everything but the picture (an even-odd cut-out); the whole screen taken: no dim, its line inside the edge
  const full = !editMode && sel.x <= 0.5 && sel.y <= 0.5 && sel.w >= innerWidth - 1 && sel.h >= innerHeight - 1;
  hole.classList.toggle('full', full);
  const cutDim = () => {
    const [W, H] = [innerWidth, innerHeight];
    dimEl.style.clipPath = `path(evenodd, 'M0 0H${W}V${H}H0Z M${sel.x} ${sel.y}h${sel.w}v${sel.h}h${-sel.w}Z')`;
  };
  dimEl.hidden = editMode || full;
  if (!dimEl.hidden) {
    cutDim();
    addEventListener('resize', cutDim);
  }
  stage.addEventListener('pointerdown', (e) => {
    if (e.target === stage || e.target === dimEl) commit();
  });
  // the stage's hint, the first few times: above the picture, else below it, else just inside its top
  if (params.get('hint') === '1' && !editMode) {
    inkHint.hidden = false;
    inkHint.textContent = t('note.stage_hint');
    const w = inkHint.offsetWidth;
    const h = 28;
    // never in the island's band at the top of the screen (its top 6 + pill 30 + 8; the Mac keeps out of the menu bar);
    // 10 px above the picture, else below it, else just inside its top (the whole screen: top centre, under the island)
    const floor = work.y + 48;
    let y = sel.y - 10 - h;
    if (full) y = floor;
    else {
      if (y < floor) y = sel.y + sel.h + 10;
      if (y + h > work.y + work.h - 8) y = Math.max(sel.y + 10, floor);
    }
    const x = Math.min(Math.max(8, sel.x + sel.w / 2 - w / 2), innerWidth - w - 8);
    Object.assign(inkHint.style, { left: `${x}px`, top: `${y}px` });
    setTimeout(hideInkHint, 6000);
  }
  function hideInkHint() {
    inkHint.classList.add('gone');
  }

  // ---- the pen (InkCanvas): strokes are 0–1 of the picture
  const dpr = devicePixelRatio || 1;
  canvas.width = Math.round(sel.w * dpr);
  canvas.height = Math.round(sel.h * dpr);
  const ctx = canvas.getContext('2d')!;
  // the line as wide as the snap's own: 1:1 on the stage; scaled to Edit Note's enlarged picture
  const lw = editMode
    ? Math.max(2, (inkWidth(Math.min(screen.width, screen.height)) * sel.w) / Math.max(1, Number(params.get('rw') ?? sel.w)))
    : inkWidth(Math.min(innerWidth, innerHeight));
  const markup = getComputedStyle(document.documentElement).getPropertyValue('--markup').trim() || '#ff5c3d';
  let stroke: InkStroke | null = null;
  let restTimer = 0;
  let activityAt = 0;
  const now = () => performance.now() / 1000;
  function path(pts: Pt[]) {
    const p = new Path2D();
    if (pts.length === 1) {
      p.arc(pts[0].x, pts[0].y, lw * 4.5, 0, Math.PI * 2);
      return p;
    }
    p.moveTo(pts[0].x, pts[0].y);
    for (let i = 1; i < pts.length - 1; i++) p.quadraticCurveTo(pts[i].x, pts[i].y, (pts[i].x + pts[i + 1].x) / 2, (pts[i].y + pts[i + 1].y) / 2);
    p.lineTo(pts[pts.length - 1].x, pts[pts.length - 1].y);
    return p;
  }
  function drawInk() {
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, sel.w, sel.h);
    Object.assign(ctx, { lineWidth: lw, lineCap: 'round', lineJoin: 'round', strokeStyle: markup, shadowColor: 'rgba(0,0,0,0.45)', shadowBlur: Math.max(1.2, lw * 0.4) * 2 });
    for (const s of strokes) ctx.stroke(path(s.map((p) => ({ x: p.x * sel.w, y: p.y * sel.h }))));
    if (stroke) ctx.stroke(path(stroke.display));
  }
  const local = (e: PointerEvent): Pt => ({ x: Math.min(Math.max(e.offsetX, 0), sel.w), y: Math.min(Math.max(e.offsetY, 0), sel.h) });
  canvas.addEventListener('pointerdown', (e) => {
    if (e.button !== 0 || closed) return;
    e.preventDefault();
    canvas.setPointerCapture(e.pointerId);
    stroke = new InkStroke(local(e), snapTool(e.shiftKey, e.altKey), now());
    hideInkHint();
    clearInterval(restTimer);
    // the pen resting at the end of a freehand stroke snaps to its shape (checked while the button is down)
    restTimer = window.setInterval(() => {
      if (stroke?.checkRest(now())) drawInk();
    }, 50);
    drawInk();
  });
  canvas.addEventListener('pointermove', (e) => {
    if (!stroke) return;
    if (stroke.move(local(e), snapTool(e.shiftKey, e.altKey), now())) drawInk();
    // drawing is the user still at it: the mic's no-speech stop waits for the pen (NoteEndpointer.activity)
    if (listening && performance.now() - activityAt > 500) {
      activityAt = performance.now();
      void host.emit(EV.action, { action: 'note.activity', g: gen });
    }
  });
  const flush = () => {
    clearInterval(restTimer);
    if (!stroke) return;
    const s = stroke;
    stroke = null;
    const r3 = (v: number) => Math.round(v * 1000) / 1000;
    strokes.push(s.kept(2).map((p) => ({ x: r3(Math.min(Math.max(p.x, 0), sel.w) / sel.w), y: r3(Math.min(Math.max(p.y, 0), sel.h) / sel.h) })));
    inkUndoFirst = true;
    drawInk();
    render();
  };
  canvas.addEventListener('pointerup', flush);
  canvas.addEventListener('pointercancel', flush);
  function undoInk() {
    if (!strokes.length) return;
    strokes.pop();
    if (!strokes.length) inkUndoFirst = false;
    drawInk();
    render();
  }

  // ---- the bubble's pieces
  doneBtn.innerHTML = `<span>${esc(t(editMode ? 'note.save' : 'note.done'))}</span>${RET}`;
  doneBtn.title = t(editMode ? 'note.save_tip' : 'note.done_tip');
  if (editMode) {
    field.value = params.get('text') ?? '';
    field.setSelectionRange(field.value.length, field.value.length);
  }
  placeChip.title = t('note.chip_tip');
  kindChip.title = t('note.kind_tip');
  filter.placeholder = t('note.find');
  $<HTMLElement>('.fic').innerHTML = ic('search', 14);
  placeKeys.innerHTML = keyLine(t('note.st_pick'));
  placeKeys.hidden = !firstTimes;

  const dashedRing = '<svg class="ic ring" width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="5.6" fill="none" stroke="currentColor" stroke-width="1.4" stroke-dasharray="2.2 2"/></svg>';
  const chevrons = '<svg class="chev" width="9" height="12" viewBox="0 0 9 12" aria-hidden="true"><path d="M1.5 4.5 4.5 1.5 7.5 4.5M1.5 7.5 4.5 10.5 7.5 7.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const placeRef = (id: string | null) => (id ? projects.find((p) => p.id === id) ?? null : null);
  // a project's folder in its colour, as the island's switcher and the main window draw it (ProjectChip: ProjectLook)
  const missingFolder =
    '<svg class="ic" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" aria-hidden="true"><path d="M3 7.5C3 6.119 4.119 5 5.5 5L8.9 5C9.313 4.992 9.711 5.155 10 5.45L11.6 7L18.5 7C19.881 7 21 8.119 21 9.5L21 17.5C21 18.881 19.881 20 18.5 20L5.5 20C4.119 20 3 18.881 3 17.5Z"/><path d="M10.1 11.9a1.9 1.9 0 1 1 2.6 1.75c-.45.2-.7.55-.7 1v.2"/><circle cx="12" cy="17.2" r=".8" fill="currentColor" stroke="none"/></svg>';
  const placeGlyph = (p: PlaceRef | null) =>
    p
      ? p.missing
        ? `<span class="pg missing">${missingFolder}</span>`
        : `<span class="pg tint" style="color:${projectColor(p.id)}">${ic('folder', 16)}</span>`
      : `<span class="pg none">${dashedRing}</span>`;
  const kindName = (k: NoteKind) => t(`kind.${k}`);
  const kindGlyph = (k: NoteKind | null) => (k ? `<span class="kg k-${k}">${ic(k, 16)}</span>` : `<span class="kg none">${ic('tag', 14)}</span>`);

  function chips() {
    const p = placeRef(place);
    const pname = p?.name ?? unassigned;
    placeChip.innerHTML = `${placeGlyph(p)}<span class="nm">${esc(pname)}</span>${chevrons}`;
    placeChip.classList.toggle('open', picking);
    placeChip.classList.toggle('missing', !!p?.missing);
    placeChip.setAttribute('aria-label', t('note.chip_ax', { name: pname + (p?.missing ? `, ${t('note.missing_short')}` : '') }));
    placeChip.title = [p?.missing ? t('note.missing_short') : '', t('note.chip_tip')].filter(Boolean).join('\n');
    kindChip.innerHTML = `${kindGlyph(chosenKind)}<span class="nm">${esc(chosenKind ? kindName(chosenKind) : t('note.kind_chip'))}</span>${chevrons}`;
    kindChip.classList.toggle('open', pickingKind);
    kindChip.setAttribute('aria-label', t('note.kind_ax', { kind: chosenKind ? kindName(chosenKind) : t('note.kind_none') }));
  }

  // ---- the voice
  const keyState = (): KeyState => {
    const heardAny = (heard.committed + heard.pending).trim() !== '';
    let voice: KeyState['voice'] = 'none';
    if (editMode) voice = listening ? (speechStarted ? 'words' : 'listening') : 'none';
    else if (!accepted) {
      if (listening) voice = speechStarted || heardAny ? 'words' : 'listening';
      else if (voiceKept) voice = 'words';
    }
    return {
      mode: editMode ? 'edit' : 'fresh',
      voice,
      typed: editMode ? field.value : (accepted || wordsInField !== null) && !typed ? '' : field.value,
      composing,
      picking,
      pickingKind,
    };
  };

  /** Stops the mic now (Tab, typing): what was said is kept; with nothing said, nothing is. */
  function stopListening(via: string) {
    if (!listening) return;
    listening = false;
    const keep = speechStarted || (heard.committed + heard.pending).trim() !== '';
    voiceDone = true;
    void host.emit(EV.action, { action: 'note.mic', keep, via, g: gen });
    if (keep) {
      voiceKept = true;
      waitingWords = true;
    } else {
      heard = { committed: '', pending: '' };
      retakeFell();
    }
  }

  /** The final words of what was said are in (NoteBubble.wordsIn). */
  function wordsIn(said: string | null) {
    waitingWords = false;
    if (editMode) return render(); // a re-record's words are the card's, once it is saved
    const w = clean(said);
    if (!w) {
      if (!(heard.committed + heard.pending).trim() && !accepted) voiceKept = false;
      return render();
    }
    finalWords = w;
    heard = { committed: w, pending: '' };
    if (accepted && takenRaw !== null) {
      if (field.value.startsWith(takenRaw)) settleTaken(takenRaw, w);
    } else if (accepted) {
      setField(joined(w, field.value));
    }
    render();
  }

  function setField(w: string) {
    field.value = w;
    takenRaw = w;
    wordsInField = clean(w) ?? w;
    field.setSelectionRange(w.length, w.length);
  }

  function settleTaken(raw: string, w: string) {
    const old = field.value;
    const tail = old.slice(raw.length);
    const caret = field.selectionStart ?? old.length;
    field.value = w + tail;
    takenRaw = w;
    wordsInField = clean(w) ?? w;
    const at = caret >= raw.length ? caret - raw.length + w.length : Math.min(caret, w.length);
    field.setSelectionRange(at, at);
    typed = clean(field.value) !== null && clean(field.value) !== wordsInField;
  }

  function takeWords() {
    const w = clean(heard.committed + heard.pending);
    // Edit Note: Tab ends the re-record, kept (its words replace the note's on Save)
    if (!editMode) accepted = true;
    stopListening('tab');
    if (w && !editMode) setField(w);
    render();
  }

  /** Edit Note's Record Again: the field keeps what was typed (the new take brings the words), the mic records. */
  function rerecord() {
    if (!editMode || listening) return;
    const opened = merged(openedTyped, openedSaid) ?? '';
    if (clean(field.value) === clean(opened)) {
      field.value = openedTyped ?? '';
      fieldHoldsSaid = false;
    }
    typed = field.value !== '';
    speechStarted = false;
    voiceDone = false;
    voiceKept = false;
    listening = true;
    listenSince = performance.now();
    void host.emit(EV.action, { action: 'note.record', g: gen });
    render();
  }

  /** A re-record ended without a take: the words said show again — unless what was typed changed meanwhile. */
  function retakeFell() {
    if (!editMode || fieldHoldsSaid || voiceKept || clean(field.value) !== clean(openedTyped)) return;
    field.value = merged(openedTyped, openedSaid) ?? '';
    fieldHoldsSaid = true;
  }

  function play() {
    if (!voiceSrc) return;
    player?.pause();
    player = new Audio(voiceSrc);
    void player.play();
  }

  function lineBreak() {
    const s = field.selectionStart ?? field.value.length;
    const e = field.selectionEnd ?? s;
    field.setRangeText('\n', s, e, 'end');
    onInput();
  }

  function clearText() {
    field.value = takenRaw ?? '';
    field.setSelectionRange(field.value.length, field.value.length);
    typed = false;
    render();
  }

  // ---- the lists
  let placeSel = 0;
  let placeList: (PlaceRef | null)[] = [];
  function renderPlaces() {
    placeList = placeChoices(projects, filter.value, unassigned);
    placeSel = Math.min(placeSel, Math.max(0, placeList.length - 1));
    const q = filter.value.trim();
    placeRows.innerHTML = placeList.length
      ? placeList
          .map((p, i) => {
            const checked = (p?.id ?? null) === place;
            const name = p?.name ?? unassigned;
            const caption = p?.missing ? t('note.missing_short') : p ? '' : t('note.unassigned_caption');
            const tip = p?.missing ? t('note.missing_short') : p ? name : t('note.unassigned_tip');
            return `<div class="r${i === placeSel ? ' sel' : ''}${!p && i > 0 ? ' line' : ''}${p?.missing ? ' missing' : ''}" role="option" data-i="${i}" title="${esc(tip)}" aria-selected="${checked}">${placeGlyph(p)}<span class="nm">${hilite(name, q)}${caption ? `<small>${esc(caption)}</small>` : ''}</span><span class="ck">${checked ? ic('check', 14) : ''}</span></div>`;
          })
          .join('')
      : `<div class="nomatch">${esc(t("note.no_match"))}</div>`;
  }
  function hilite(name: string, q: string) {
    if (!q) return esc(name);
    const i = name.toLowerCase().indexOf(q.toLowerCase());
    return i < 0 ? esc(name) : `${esc(name.slice(0, i))}<b>${esc(name.slice(i, i + q.length))}</b>${esc(name.slice(i + q.length))}`;
  }
  function openPick() {
    if (picking) return;
    if (pickingKind) closeKinds();
    picking = true;
    filter.value = '';
    renderPlaces();
    placeSel = Math.max(0, placeList.findIndex((p) => (p?.id ?? null) === place));
    renderPlaces();
    render();
    filter.focus();
  }
  function closePick() {
    if (!picking) return;
    picking = false;
    render();
    field.focus();
    field.setSelectionRange(field.value.length, field.value.length);
  }
  function picked(p: PlaceRef | null) {
    // a project whose folder can't be found takes nothing: the snap stays a card
    place = p && !p.missing ? p.id : null;
    closePick();
  }
  filter.addEventListener('input', () => {
    placeSel = 0;
    renderPlaces();
    render();
  });
  filter.addEventListener('keydown', (e) => {
    if (e.isComposing) return;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      if (placeList.length) placeSel = (placeSel + (e.key === 'ArrowDown' ? 1 : -1) + placeList.length) % placeList.length;
      renderPlaces();
    } else if (e.key === 'Enter') {
      e.preventDefault();
      if (placeList[placeSel] !== undefined) picked(placeList[placeSel]);
    } else if (e.key === 'Escape' || e.key === 'Tab') {
      e.preventDefault();
      e.stopPropagation();
      closePick();
    }
  });
  placeRows.addEventListener('pointerdown', (e) => {
    const r = (e.target as HTMLElement).closest<HTMLElement>('.r');
    if (r) {
      e.preventDefault();
      picked(placeList[Number(r.dataset.i)]);
    }
  });

  const kindList: (NoteKind | null)[] = [...KINDS, null];
  let kindSel = 0;
  function renderKinds() {
    kindRows.innerHTML = kindList
      .map((k, i) => {
        const name = k ? kindName(k) : t('note.kind_none');
        return `<div class="r${i === kindSel ? ' sel' : ''}${k === null ? ' line' : ''}" role="option" data-i="${i}" ${k === null ? `title="${esc(t('note.kind_none_tip'))}"` : ''} aria-selected="${k === chosenKind}">${kindGlyph(k)}<span class="nm">${esc(name)}${k === null ? `<small>${esc(t('note.kind_none_caption'))}</small>` : ''}</span><span class="ck">${k === chosenKind ? ic('check', 13) : ''}</span><kbd class="kk">Ctrl+${k ? KINDS.indexOf(k) + 1 : 0}</kbd></div>`;
      })
      .join('');
  }
  function openKinds() {
    if (pickingKind) return;
    if (picking) closePick();
    pickingKind = true;
    kindSel = kindList.indexOf(chosenKind);
    renderKinds();
    render();
    field.focus();
  }
  function closeKinds() {
    if (!pickingKind) return;
    pickingKind = false;
    render();
  }
  function setKind(k: NoteKind | null) {
    chosenKind = k;
    if (pickingKind) closeKinds();
    render();
  }
  kindRows.addEventListener('pointerdown', (e) => {
    const r = (e.target as HTMLElement).closest<HTMLElement>('.r');
    if (r) {
      e.preventDefault();
      setKind(kindList[Number(r.dataset.i)]);
    }
  });
  placeChip.addEventListener('click', () => (picking ? closePick() : openPick()));
  kindChip.addEventListener('click', () => (pickingKind ? closeKinds() : openKinds()));
  placeChip.addEventListener('mousedown', (e) => e.preventDefault());
  kindChip.addEventListener('mousedown', (e) => e.preventDefault());
  doneBtn.addEventListener('mousedown', (e) => e.preventDefault());
  doneBtn.addEventListener('click', () => commit());

  // ---- what the bubble says now (NoteBubble.refreshStatus + layout)
  let caret: Caret = 'left';
  let caretAt = 26;
  let side: DockSide | null = null;
  let width = 0;
  let sentSize = { w: 0, h: 0 };
  let glyphHtml = '';
  let toolsBuilt = '';
  function render() {
    if (closed) return;
    chips();
    // the glyph column: the level while it listens; the keyboard once the keyboard has the note; a waveform for words
    // said and waiting; the mic struck through when it can't or doesn't listen
    bars.hidden = !listening;
    if (editMode) {
      // Edit Note: the glyph column is a button — play the voice it has, else record one (brand ink)
      icon.hidden = listening;
      const b = voiceSrc ? 'play' : 'record';
      const html = `<button type="button" class="gbtn" data-g="${b}" title="${esc(t(voiceSrc ? 'note.play' : 'note.record'))}">${ic(voiceSrc ? 'play' : 'mic', 16)}</button>`;
      if (glyphHtml !== html) icon.innerHTML = glyphHtml = html; // (never rebuilt under a click)
      icon.className = 'icon';
    } else {
      const sym = listening ? null : accepted || typed ? 'keyboard' : voiceKept ? 'waveform' : 'mic-off';
      icon.hidden = !sym;
      icon.innerHTML = sym === 'mic-off' ? `${ic('mic', 16)}<i class="slash"></i>` : sym ? ic(sym, 16) : '';
      icon.className = 'icon';
    }
    // the placeholder says what to do — or, in grey, the words heard
    let ph = '';
    const heardAny = (heard.committed + heard.pending).trim() !== '';
    if (editMode) ph = t('note.placeholder');
    else if (accepted) ph = wordsInField === null && waitingWords ? '' : t('note.placeholder_optional');
    else if (listening || voiceKept) ph = heardAny ? '' : t('note.listening');
    else if (voiceBusy) ph = t('note.ph_voice_busy');
    else if (micGone) ph = t('note.ph_mic_gone');
    else if (!voiceDone) ph = t('note.ph_no_mic');
    else ph = t('note.placeholder_optional');
    field.placeholder = ph;
    live.hidden = editMode || accepted || !(listening || voiceKept) || !heardAny || field.value !== '';
    // settled words in secondary ink, the newest piece lighter until the next lands (no guessed full stop on it)
    const pend = listening ? liveTail(heard.pending) : heard.pending;
    const comm = listening && !pend ? liveTail(heard.committed) : heard.committed;
    live.innerHTML = `<span>${esc(comm)}</span><span class="pending">${esc(pend)}</span>`;
    // the status slot: state, and the keys only for the grey words
    const ks = keyState();
    let line = '';
    if (picking || pickingKind) line = '';
    else if (editMode) {
      // a re-record: the running time; once something was said, Tab ends it (kept) — Save ↩ keeps it too
      line = listening ? keyLine(t(speechStarted ? 'note.st_rerecord_tab' : 'note.st_rerecord', { t: clock((performance.now() - listenSince) / 1000) })) : '';
    } else if (ks.voice === 'words' && ks.typed.trim() === '' && (heardAny || !listening)) {
      // the time keeps running in front of the keys while it still listens (the Mac's 0:07 · Tab accept)
      line = (listening ? `${clock((performance.now() - listenSince) / 1000)} · ` : '') + keyLine(t('note.st_voice'));
    }
    // talking, no words yet: the running time (a Tab hint with nothing to take would be a promise it can't keep)
    else if (listening) line = clock((performance.now() - listenSince) / 1000);
    // the mic is a voice note's: why it doesn't listen, where the time would be
    else if (voiceBusy && !typed && !accepted) line = esc(t('note.st_voice_busy'));
    status.innerHTML = line;
    // the hover tools: the stroke undo (with ink), the bin
    const want = hovering && !picking && !pickingKind;
    const toolsHtml = want
      ? `${strokes.length ? `<button type="button" class="tool undo" title="${esc(t('note.undo'))}">${ic('undo', 14)}</button>` : ''}${
          editMode
            ? voiceSrc && !listening
              ? `<button type="button" class="tool again" title="${esc(t('note.rerecord'))}">${ic('mic', 14)}</button>`
              : ''
            : `<button type="button" class="tool bin" title="${esc(t('note.discard_tip'))}">${ic('trash', 14)}</button>`
        }`
      : '';
    if (toolsBuilt !== toolsHtml) tools.innerHTML = toolsBuilt = toolsHtml;
    doneBtn.disabled = picking || pickingKind;
    places.hidden = !picking;
    kinds.hidden = !pickingKind;
    fitField(editMode && hasPic ? 90 : 220);
    status.classList.toggle('over', status.scrollWidth > status.clientWidth + 1);
    layout();
  }
  tools.addEventListener('mousedown', (e) => e.preventDefault());
  tools.addEventListener('click', (e) => {
    const b = (e.target as HTMLElement).closest('button');
    if (b?.classList.contains('undo')) undoInk();
    if (b?.classList.contains('bin')) cancel();
    if (b?.classList.contains('again')) rerecord();
  });
  icon.addEventListener('mousedown', (e) => e.preventDefault());
  icon.addEventListener('click', (e) => {
    const g = (e.target as HTMLElement).closest<HTMLElement>('[data-g]')?.dataset.g;
    if (g === 'play') play();
    if (g === 'record') rerecord();
  });
  bubble.addEventListener('pointerenter', () => {
    hovering = true;
    render();
  });
  bubble.addEventListener('pointerleave', () => {
    hovering = false;
    render();
  });

  /** Sized from the start for the chips, the bin, the keys line and Done, so it never widens as the words come. */
  function measureWidth() {
    const kept = chosenKind;
    const probe = document.createElement('span');
    probe.className = 'status probe';
    probe.innerHTML = `0:00 · ${keyLine(t('note.st_voice'))}`;
    card.querySelector('.foot')!.append(probe);
    const widest = Math.max(
      ...[null, ...KINDS].map((k) => {
        chosenKind = k;
        chips();
        return kindChip.offsetWidth;
      }),
    );
    chosenKind = kept;
    chips();
    const need = 12 + Math.min(200, placeChip.offsetWidth - 6) + 2 + widest + 4 + 26 + 6 + probe.offsetWidth + 10 + doneBtn.offsetWidth + 12;
    probe.remove();
    // (the Mac caps it at 440 pt; Segoe UI sets the same words ~6 % wider, so the footer may take a little more here)
    return Math.max(editMode ? Math.max(400, sel.w + 24) : 360, Math.min(470, Math.ceil(need)));
  }

  function layout() {
    const inner = Math.max(width, picking || pickingKind ? Math.min(440, (picking ? places : kinds).scrollWidth) : 0);
    card.style.width = `${inner}px`;
    if (editMode) {
      // its own window, under the card it belongs to: the caret up, the window sized to the bubble (Rust) with room
      // for its shadow on every side (blur 22 + offset 10: a window edge through it is a hard grey box on Windows)
      Object.assign(bubble.style, { left: '34px', top: '10px' });
      // (a window smaller than the bubble for a moment must never leave the page scrolled: the picture was cut off)
      if (scrollX || scrollY) scrollTo(0, 0);
      document.scrollingElement?.scrollTo(0, 0);
      drawBubble('up', (inner + 0) / 2);
      const w = Math.ceil(inner + 68);
      const h = Math.ceil(card.offsetHeight + CARET + 10 + 40);
      if (w !== sentSize.w || h !== sentSize.h) {
        sentSize = { w, h };
        void host.emit(EV.action, { action: 'note.size', w, h, g: gen });
      }
      return;
    }
    // docked beside the frozen picture, never over it (BubbleDock); the caret points at it from the side it is on
    const cw = inner;
    const ch = card.offsetHeight;
    const d = dock({ w: cw + CARET, h: ch + CARET }, sel, work);
    side = d.side;
    const want: Caret = { right: 'left', left: 'right', below: 'up', above: 'down', inside: 'none' }[d.side] as Caret;
    caret = want;
    let x = d.x;
    let y = d.y;
    const bw = cw + (caret === 'left' || caret === 'right' ? CARET : 0);
    const bh = ch + (caret === 'up' || caret === 'down' ? CARET : 0);
    if (side === 'right' || side === 'left') {
      if (side === 'left') x = sel.x - 12 - bw;
      y = Math.min(Math.max(sel.y, work.y + 8), work.y + work.h - 8 - bh);
      const top = Math.max(sel.y, y);
      const bottom = Math.min(sel.y + sel.h, y + bh);
      caretAt = top + Math.min(26, Math.max(0, bottom - top) / 2) - y;
    } else if (side === 'below' || side === 'above') {
      // centred on the picture, kept on the work area
      x = Math.min(Math.max(sel.x + sel.w / 2 - bw / 2, work.x + 8), work.x + work.w - 8 - bw);
      if (side === 'above') y = sel.y - 12 - bh;
      caretAt = sel.x + sel.w / 2 - x;
    } else {
      // inside (the whole screen): one 16 px inset from the work area's right and bottom, as Windows' toasts sit
      x = Math.min(sel.x + sel.w, work.x + work.w) - 16 - bw;
      y = Math.min(sel.y + sel.h, work.y + work.h) - 16 - bh;
    }
    Object.assign(bubble.style, { left: `${Math.round(x)}px`, top: `${Math.round(y)}px` });
    drawBubble(caret, caretAt);
  }

  // ---- input: the keys are NoteKeys
  let composing = false;
  field.addEventListener('compositionstart', () => (composing = true));
  field.addEventListener('compositionend', () => {
    composing = false;
    onInput();
  });
  function perform(a: Action): boolean {
    if (closed || a.a === 'pass') return false;
    switch (a.a) {
      case 'ignore':
        break;
      case 'commit':
        commit();
        break;
      case 'newLine':
        lineBreak();
        break;
      case 'takeWords':
        takeWords();
        if (a.newLine) lineBreak();
        break;
      case 'openPlaces':
        openPick();
        break;
      case 'closePlaces':
        closePick();
        break;
      case 'clearText':
        clearText();
        break;
      case 'close':
        cancel();
        break;
      case 'typeOver':
      case 'typedNote':
        stopListening('typing');
        break;
      case 'setKind':
        setKind(a.kind);
        break;
      case 'moveKind':
        kindSel = (kindSel + a.d + kindList.length) % kindList.length;
        renderKinds();
        break;
      case 'pickKind':
        setKind(kindList[kindSel]);
        break;
      case 'closeKinds':
        closeKinds();
        break;
    }
    return true;
  }
  function keyOf(e: KeyboardEvent): Key | null {
    const mods = (e.ctrlKey ? 1 : 0) + (e.altKey ? 2 : 0) + (e.shiftKey ? 4 : 0) + (e.metaKey ? 8 : 0);
    if (e.key === 'Escape') return { k: 'escape' };
    if (e.key === 'Enter') return mods === 0 ? { k: 'return' } : mods === 4 || mods === 1 || mods === 2 ? { k: 'shiftReturn' } : null;
    if (e.key === 'Tab') return mods === 0 ? { k: 'tab' } : null;
    if (e.key === 'ArrowUp' && mods === 0) return { k: 'up' };
    if (e.key === 'ArrowDown' && mods === 0) return { k: 'down' };
    const digit = /^(Digit|Numpad)([0-9])$/.exec(e.code);
    if (digit && mods === 1) return { k: 'command', d: Number(digit[2]) };
    return null;
  }
  addEventListener(
    'keydown',
    (e) => {
      if (closed) return;
      if (e.key === 'Alt') e.preventDefault(); // Alt-drag draws an ellipse: never the window's menu
      const k = keyOf(e);
      const st = { ...keyState(), composing: composing || e.isComposing || e.keyCode === 229 };
      if (k) {
        // the place list's filter keeps its keys (↑↓ ↩ Esc there): only Ctrl+digits reach the bubble from it
        if (picking && document.activeElement === filter && k.k !== 'command') return;
        if (perform(noteAction(k, st))) {
          e.preventDefault();
          e.stopPropagation();
        } else if (k.k === 'tab') e.preventDefault(); // never Tab out of the note
        return;
      }
      if (picking) return;
      // Ctrl+Z: the last stroke goes when drawing was the last thing done (or there is no text to undo)
      if (e.ctrlKey && !e.shiftKey && !e.altKey && e.key.toLowerCase() === 'z' && strokes.length && (inkUndoFirst || field.value === '')) {
        e.preventDefault();
        undoInk();
      }
    },
    true,
  );
  function onInput() {
    if (composing) return;
    const committed = field.value;
    let now = committed.trim() !== '';
    // the words taken with Tab, in the field: only a change to them is typing
    if (wordsInField !== null && clean(committed) === wordsInField) now = false;
    // typing over the grey words replaces them; before anything was said it makes a typed note
    if (now && !typed) perform(noteAction({ k: 'typing' }, keyState()));
    if (pickingKind) closeKinds();
    // the words taken, all deleted: they are the grey words again
    if (accepted && wordsInField !== null && committed.trim() === '') {
      accepted = false;
      wordsInField = null;
      takenRaw = null;
    }
    if (field.value !== (wordsInField ?? '')) inkUndoFirst = false;
    typed = now;
    render();
  }
  field.addEventListener('input', onInput);
  addEventListener('keyup', (e) => {
    if (e.key === 'Alt') e.preventDefault(); // (its release would put the window in menu mode)
  });

  // ---- leaving: another app taking over saves a moment later (it never floats, or listens, over every app)
  let resign = 0;
  addEventListener('blur', () => {
    clearTimeout(resign);
    resign = window.setTimeout(() => {
      if (!document.hasFocus()) commit();
    }, 3000);
  });
  addEventListener('focus', () => clearTimeout(resign));

  // ---- closing (NoteBubble.close)
  function commit() {
    if (closed) return;
    close(true, listening || (voiceKept && !accepted && !typed));
  }
  function cancel() {
    if (!closed) close(false, false);
  }
  function close(save: boolean, flash: boolean) {
    flush();
    player?.pause();
    if (editMode) return closeEdit(save, flash);
    const discard = !save;
    const hadTyping = !accepted && wordsInField === null && typed && field.value.trim() !== '';
    let voice: SnapDone['voice'] = 'none';
    if (listening) {
      const said = speechStarted || (heard.committed + heard.pending).trim() !== '';
      voice = said && !hadTyping ? 'keep' : 'drop';
    } else if (voiceKept) voice = hadTyping ? 'drop' : 'keep';
    let text: string | null = clean(field.value);
    let said: string | null = null;
    if (wordsInField !== null) {
      const note = takenNote(wordsInField, finalWords, field.value);
      if (voice === 'keep') {
        text = note.typed;
        said = note.said ?? wordsInField;
      } else {
        text = clean(field.value) ?? wordsInField;
      }
    }
    const out: SnapDone = {
      n: shotN,
      save,
      text,
      said,
      voice,
      kind: chosenKind,
      place,
      strokes: strokes.map((s) => s.map((p) => [p.x, p.y])),
      flash: flash && !discard,
      heard: clean(heard.committed + heard.pending),
      g: gen,
      lw,
      selW: sel.w,
    };
    closed = true;
    clearInterval(timer);
    void host.emit(EV.noteDone, out as unknown as Record<string, unknown>);
    if (host.host === 'browser') document.body.dataset.done = JSON.stringify(out);
    // the stage goes at once; the bubble says "Saved" for a moment when it was spoken, then goes
    stage.classList.add('gone');
    if (out.flash) {
      // "Saved": the words turn primary (they are the note now), the ok check in the glyph column, Done stands down;
      // the caret goes with the picture (nothing left to point at)
      bars.hidden = true;
      icon.hidden = false;
      icon.className = 'icon ok';
      icon.innerHTML = ic('check', 16);
      field.placeholder = '';
      live.innerHTML = `<span>${esc(clean(heard.committed + heard.pending) ?? '')}</span>`;
      status.innerHTML = esc(t('note.saved'));
      tools.innerHTML = '';
      bubble.classList.add('saved');
      drawBubble(caret, caretAt, false);
      setTimeout(() => bubble.classList.add('gone'), 450);
    } else bubble.classList.add('gone');
  }

  /** Edit Note's outcome (NoteBubble.close, mode .edit): NoteEdit decides the typed part and the words; Esc puts
      everything back (a re-record goes, the note it would have replaced was never touched). */
  function closeEdit(save: boolean, flash: boolean) {
    const said = speechStarted || voiceKept;
    const retaken = save && (voiceKept || (listening && said));
    const note = editApply(openedTyped, openedSaid, openedSaid, field.value, fieldHoldsSaid, retaken);
    const out = {
      n: shotN,
      save,
      text: note.typed,
      said: note.said,
      voice: retaken ? 'keep' : listening || voiceKept ? 'drop' : 'none',
      kind: chosenKind,
      place,
      strokes: strokes.map((s) => s.map((p) => [p.x, p.y])),
      flash: flash && save,
      g: gen,
      lw,
      selW: sel.w,
    };
    closed = true;
    clearInterval(timer);
    void host.emit(EV.noteDone, out as unknown as Record<string, unknown>);
    if (host.host === 'browser') document.body.dataset.done = JSON.stringify(out);
    bubble.classList.add('gone');
  }

  // ---- ticking: the level bars and the running time
  const barEls = [...bars.querySelectorAll<HTMLElement>('i')];
  const reduce = document.documentElement.dataset.reduceMotion === '1';
  let lastSecond = -1;
  const timer = window.setInterval(() => {
    shown = Math.max(level, shown * 0.86);
    level *= 0.82;
    const tt = performance.now() / 1000;
    barEls.forEach((b, i) => {
      const weight = i === 1 ? 1 : 0.7;
      const breath = reduce ? 0.5 : 0.5 + 0.5 * Math.sin(tt * 3.2 - i * 0.9);
      const rest = (i === 1 ? 8 : 5) + breath * (i === 1 ? 2.5 : 1.5);
      const voice = (reduce ? (shown > 0.15 ? 1 : 0) : Math.min(1, shown * 1.25)) * weight;
      b.style.height = `${Math.max(rest, 5 + 10 * voice)}px`;
    });
    const s = Math.floor((performance.now() - listenSince) / 1000);
    if (listening && s !== lastSecond) {
      lastSecond = s;
      render();
    }
  }, 50);

  // ---- from Rust
  function apply(op: NoteOp & { g?: number }) {
    if (op.g !== undefined && op.g !== gen) return;
    if (closed && op.op !== 'words') return;
    switch (op.op) {
      case 'shot':
        shotN = op.n;
        setShot(op.src);
        break;
      case 'voice':
        if (op.state === 'listening') {
          if (!listening && !voiceDone) listenSince = performance.now();
          listening = !voiceDone;
        } else {
          listening = false;
          voiceBusy = op.state === 'busy';
        }
        break;
      case 'level':
        level = Math.max(level, op.v);
        return;
      case 'speech':
        speechStarted = true;
        break;
      case 'live':
        if (!listening && !voiceKept) return;
        if (accepted) return;
        heard = { committed: op.committed, pending: op.pending ?? '' };
        break;
      case 'ended':
        if (!listening) return;
        listening = false;
        voiceDone = true;
        if (op.why === 'lost' && !speechStarted && !(heard.committed + heard.pending).trim()) {
          micGone = true;
          heard = { committed: '', pending: '' };
        } else if (op.why === 'nospeech') {
          heard = { committed: '', pending: '' };
          retakeFell();
        } else {
          voiceKept = true;
          waitingWords = true;
        }
        break;
      case 'words':
        if (closed) return;
        return wordsIn(op.said);
      case 'commit':
        return commit();
      case 'failed':
        closed = true;
        stage.classList.add('gone');
        bubble.classList.add('gone');
        return;
    }
    render();
  }
  void host.on<NoteOp>(EV.note, apply);

  // ---- open
  if (strokes.length) drawInk();
  renderKinds();
  width = measureWidth();
  render();
  bubble.classList.add('in');
  field.focus({ preventScroll: true });

  // ready (the frozen picker under this window goes) once the frozen picture is drawn: two frames after the still
  void stillShown.then(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))).then(() => ready(host, 'note', (push) => {
    // ?demo=1 listening, words coming · ?demo=words grey words waiting · ?demo=places / kinds a list open ·
    // ?demo=typed · ?demo=nomic
    const demo = params.get('demo') ?? '1';
    const sample =
      'data:image/svg+xml,' +
      encodeURIComponent(
        `<svg xmlns="http://www.w3.org/2000/svg" width="${Math.round(sel.w)}" height="${Math.round(sel.h)}"><rect width="100%" height="100%" fill="#ffffff"/><rect x="24" y="24" width="${Math.round(sel.w * 0.45)}" height="18" rx="4" fill="#253244"/><rect x="24" y="60" width="${Math.round(sel.w - 48)}" height="12" rx="4" fill="#b8c2d0"/><rect x="24" y="84" width="${Math.round(sel.w * 0.7)}" height="12" rx="4" fill="#b8c2d0"/><rect x="24" y="${Math.round(sel.h - 60)}" width="110" height="34" rx="8" fill="#dfe6ef"/></svg>`,
      );
    push(EV.note, { op: 'shot', n: 3, src: sample });
    const zh = document.documentElement.lang === 'zh-Hans';
    if (editMode) {
      if (!params.get('text')) field.value = zh ? '这个保存按钮颜色太浅了，换成主色' : 'The save button is too faint, make it the brand colour';
      strokes.push([0.1, 0.12, 0.5, 0.12, 0.5, 0.3, 0.1, 0.3, 0.1, 0.12].reduce<Pt[]>((a, v, i, arr) => (i % 2 ? a : [...a, { x: v, y: arr[i + 1] }]), []));
      drawInk();
      hovering = params.get('demo') === 'hover';
      return render();
    }
    const words = zh ? '这个保存按钮颜色太浅了，' : 'The save button is too faint, ';
    const more = zh ? '换成主色' : 'make it the brand colour';
    if (demo === 'nomic') return push(EV.note, { op: 'voice', state: 'nomic' });
    if (demo === 'busy') return push(EV.note, { op: 'voice', state: 'busy' });
    push(EV.note, { op: 'voice', state: 'listening' });
    let k = 0;
    setInterval(() => push(EV.note, { op: 'level', v: 0.25 + 0.5 * Math.abs(Math.sin(k++ / 2.5)) }), 80);
    push(EV.note, { op: 'speech' });
    push(EV.note, { op: 'live', committed: words, pending: demo === '1' ? more : '' });
    if (demo === 'words') push(EV.note, { op: 'ended', why: 'maxed' });
    if (demo === 'typed') {
      field.value = zh ? '按钮对比度不够' : 'Button contrast too low';
      onInput();
    }
    if (demo === 'places') openPick();
    if (demo === 'kinds') openKinds();
    if (demo === 'ink') {
      strokes.push([0.1, 0.12, 0.35, 0.4, 0.62, 0.4, 0.62, 0.12, 0.1, 0.12].reduce<Pt[]>((a, v, i, arr) => (i % 2 ? a : [...a, { x: v, y: arr[i + 1] }]), []));
      drawInk();
      hovering = true;
      render();
    }
  }));
}

// (after every declaration above: the pages' code reads the constants)
if (!snapMode) editNote();
else snapNote();
