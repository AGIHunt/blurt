// The snap note's rules, ported from the Mac's BlurtCore so the Windows bubble decides exactly as the Mac's does
// (docs/design/windows-parity/snap-and-note.md): NoteKeys (state × key → action), NoteEsc, NoteKind, the pen
// (InkStroke / InkFit / InkHold / InkStyle / InkHint — Ink.swift), BubbleDock (where the bubble sits beside the frozen
// picture), NoteEdit (the words taken with Tab, edited) and ProjectPick (the place list's order and filter).
// Coordinates here are CSS pixels, y down (the Mac's are AppKit points, y up: BubbleDock is mirrored accordingly).

// ------------------------------------------------------------------ the type (NoteKind)

export const KINDS = ['issue', 'idea', 'note', 'task'] as const;
export type NoteKind = (typeof KINDS)[number];

/** Ctrl+digit: 1…4 a kind, 0 none (null); undefined: not the bubble's digit. */
export function kindForDigit(d: number): NoteKind | null | undefined {
  if (d === 0) return null;
  return KINDS[d - 1];
}

// ------------------------------------------------------------------ the keys (NoteKeys, NoteEsc)

export type Key =
  | { k: 'return' }
  | { k: 'shiftReturn' }
  | { k: 'tab' }
  | { k: 'escape' }
  | { k: 'typing' }
  | { k: 'up' }
  | { k: 'down' }
  | { k: 'command'; d: number };

export type Mode = 'fresh' | 'edit' | 'recording';
/** none: no mic, or its words are in the field already; listening: nothing said yet; words: grey words (or set aside) */
export type Voice = 'none' | 'listening' | 'words';

export interface KeyState {
  mode: Mode;
  voice: Voice;
  /** what the user typed (the words taken with Tab, untouched, are not typing) */
  typed: string;
  composing: boolean;
  picking: boolean;
  pickingKind: boolean;
}

export type Action =
  | { a: 'commit' }
  | { a: 'newLine' }
  | { a: 'takeWords'; newLine: boolean }
  | { a: 'openPlaces' }
  | { a: 'closePlaces' }
  | { a: 'clearText' }
  | { a: 'close' }
  | { a: 'typeOver' }
  | { a: 'typedNote' }
  | { a: 'setKind'; kind: NoteKind | null }
  | { a: 'moveKind'; d: number }
  | { a: 'pickKind' }
  | { a: 'closeKinds' }
  | { a: 'ignore' }
  | { a: 'pass' };

const blank = (s: string) => s.trim() === '';

export const wordsShowing = (s: KeyState) => s.voice === 'words' && blank(s.typed);

/** Esc in two steps: the typed text first (a fresh snap only), then the snap. */
export const noteEsc = (fresh: boolean, field: string): 'clearText' | 'close' => (fresh && !blank(field) ? 'clearText' : 'close');

export function noteAction(key: Key, s: KeyState): Action {
  if (s.composing) return { a: 'pass' };
  if (key.k === 'command') {
    const kind = kindForDigit(key.d);
    return kind === undefined ? { a: 'pass' } : { a: 'setKind', kind };
  }
  if (s.pickingKind) {
    switch (key.k) {
      case 'escape':
      case 'tab':
        return { a: 'closeKinds' };
      case 'return':
        return { a: 'pickKind' };
      case 'up':
        return { a: 'moveKind', d: -1 };
      case 'down':
        return { a: 'moveKind', d: 1 };
      case 'shiftReturn':
        return { a: 'ignore' };
      default:
        break; // typing: as below (the bubble closes the list)
    }
  }
  if (s.picking) return key.k === 'escape' ? { a: 'closePlaces' } : { a: 'pass' };
  switch (key.k) {
    case 'up':
    case 'down':
      return { a: 'pass' };
    case 'return':
      return { a: 'commit' };
    case 'escape':
      return noteEsc(s.mode === 'fresh', s.typed) === 'clearText' ? { a: 'clearText' } : { a: 'close' };
    case 'shiftReturn':
      if (s.mode !== 'fresh') return { a: 'newLine' };
      if (wordsShowing(s)) return { a: 'takeWords', newLine: true };
      return blank(s.typed) ? { a: 'ignore' } : { a: 'newLine' };
    case 'tab':
      if (s.mode === 'recording') return { a: 'pass' };
      if (s.mode === 'edit') return s.voice === 'words' ? { a: 'takeWords', newLine: false } : { a: 'openPlaces' };
      return wordsShowing(s) ? { a: 'takeWords', newLine: false } : { a: 'openPlaces' };
    case 'typing':
      if (s.mode !== 'fresh') return { a: 'pass' };
      return s.voice === 'words' ? { a: 'typeOver' } : s.voice === 'listening' ? { a: 'typedNote' } : { a: 'pass' };
  }
}

// ------------------------------------------------------------------ the note's text (CardNote, NoteEdit)

export function clean(s: string | null | undefined): string | null {
  const t = (s ?? '').trim();
  return t ? t : null;
}

/** The typed note and the words said as one text (the card's). */
export function merged(typed: string | null | undefined, said: string | null | undefined): string | null {
  const t = clean(typed);
  const s = clean(said);
  if (t && s) return t === s || t.includes(s) ? t : s.includes(t) ? s : `${t}\n${s}`;
  return t ?? s;
}

/** The words taken with Tab, then what was typed after Tab before they came. */
export function joined(words: string, typed: string): string {
  const t = typed.trim();
  if (!t) return words;
  const ascii = (c: string | undefined) => !!c && /[A-Za-z0-9!-/:-@[-`{-~]/.test(c);
  // a new sentence typed after words that stop mid-sentence (a cut segment): a full stop between them, never a
  // run-on "…the border of Also the button"; CJK joins with nothing (no space after 。)
  if (/[A-Za-z0-9]$/.test(words) && /^[A-Z][a-z]/.test(t)) return `${words}. ${t}`;
  return words + (ascii(words.at(-1)) && ascii(t[0]) ? ' ' : '') + t;
}

/** NoteEdit.apply: the note after Edit Note was saved. `opened…`: the note when it opened; `currentSaid`: its words
    now; `fieldHoldsSaid`: the field still shows the words said (false once a re-record set it to the typed part);
    `retaken`: a new recording was kept (its words are to come). */
export function editApply(
  openedTyped: string | null,
  openedSaid: string | null,
  currentSaid: string | null,
  field: string,
  fieldHoldsSaid: boolean,
  retaken: boolean,
): { typed: string | null; said: string | null } {
  const edited = clean(field);
  if (retaken) return { typed: edited, said: null };
  const base = fieldHoldsSaid ? (merged(openedTyped, openedSaid) ?? '') : (openedTyped ?? '');
  if (edited === clean(base)) return { typed: openedTyped, said: currentSaid };
  if (fieldHoldsSaid && clean(openedSaid) !== null) return edited === null ? { typed: null, said: openedSaid } : { typed: null, said: edited };
  return { typed: edited, said: currentSaid };
}

/** NoteEdit.apply for the words taken with Tab (openedTyped nil, fieldHoldsSaid, not retaken). */
export function takenNote(words: string, currentSaid: string | null, field: string): { typed: string | null; said: string | null } {
  const edited = clean(field);
  if (edited === clean(words)) return { typed: null, said: currentSaid };
  if (clean(words) !== null) return edited === null ? { typed: null, said: words } : { typed: null, said: edited };
  return { typed: edited, said: currentSaid };
}

// ------------------------------------------------------------------ the pen (Ink.swift)

export interface Pt {
  x: number;
  y: number;
}
export type InkTool = 'free' | 'box' | 'ellipse';

/** A snap's markup: Shift box, Alt ellipse (Shift wins when both are down), else freehand. */
export const snapTool = (shift: boolean, alt: boolean): InkTool => (shift ? 'box' : alt ? 'ellipse' : 'free');

export const InkHold = { seconds: 0.5, radius: 3 };

export type InkShape =
  | { s: 'line'; a: Pt; b: Pt }
  | { s: 'rect'; r: { x: number; y: number; w: number; h: number } }
  | { s: 'ellipse'; r: { x: number; y: number; w: number; h: number } };

const dist = (a: Pt, b: Pt) => Math.hypot(b.x - a.x, b.y - a.y);

function distToLine(p: Pt, a: Pt, b: Pt) {
  const d = dist(a, b);
  if (d === 0) return dist(p, a);
  return Math.abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / d;
}

/** Nearly level or upright (within 6°): exactly so. */
function straightened(a: Pt, b: Pt): Pt {
  const ang = Math.abs((Math.atan2(b.y - a.y, b.x - a.x) * 180) / Math.PI);
  if (ang <= 6 || ang >= 174) return { x: b.x, y: a.y };
  if (Math.abs(ang - 90) <= 6) return { x: a.x, y: b.y };
  return b;
}

/** The clean shape a rough freehand stroke is close to, or null (it stays as drawn). */
export function inkFit(pts: Pt[]): InkShape | null {
  if (pts.length < 3) return null;
  const first = pts[0];
  const last = pts[pts.length - 1];
  let length = 0;
  for (let i = 1; i < pts.length; i++) length += dist(pts[i - 1], pts[i]);
  if (length < 16) return null;
  const xs = pts.map((p) => p.x);
  const ys = pts.map((p) => p.y);
  const box = { x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) };
  const chord = dist(first, last);
  if (chord >= 20 && chord >= 0.8 * length) {
    const dev = Math.max(...pts.map((p) => distToLine(p, first, last)));
    if (dev <= Math.max(5, 0.07 * chord)) return { s: 'line', a: first, b: straightened(first, last) };
  }
  const big = Math.max(box.w, box.h);
  if (Math.min(box.w, box.h) < 10 || chord > Math.max(14, 0.3 * big) || length < 1.4 * (box.w + box.h)) return null;
  let rectErr = 0;
  let ellErr = 0;
  for (const p of pts) {
    const u = (p.x - box.x) / box.w;
    const v = (p.y - box.y) / box.h;
    rectErr += Math.min(u, 1 - u, v, 1 - v);
    ellErr += Math.abs(Math.hypot(u - 0.5, v - 0.5) / 0.5 - 1) * 0.5;
  }
  rectErr /= pts.length;
  ellErr /= pts.length;
  if (Math.min(rectErr, ellErr) > 0.08) return null;
  return rectErr <= ellErr ? { s: 'rect', r: box } : { s: 'ellipse', r: box };
}

/** A Shift / Alt drag from a to b: the box or the ellipse it spans (null while it is still a dot). */
export function dragShape(tool: InkTool, a: Pt, b: Pt): InkShape | null {
  const r = { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), w: Math.abs(b.x - a.x), h: Math.abs(b.y - a.y) };
  if (Math.max(r.w, r.h) < 4) return null;
  return tool === 'box' ? { s: 'rect', r } : tool === 'ellipse' ? { s: 'ellipse', r } : null;
}

/** The point list a shape is stored as: a box's corners doubled, an ellipse as 72 points round, a line its ends. */
export function shapePoints(s: InkShape): Pt[] {
  if (s.s === 'line') return [s.a, s.b];
  const r = s.r;
  if (s.s === 'rect') {
    const c = [
      { x: r.x, y: r.y },
      { x: r.x + r.w, y: r.y },
      { x: r.x + r.w, y: r.y + r.h },
      { x: r.x, y: r.y + r.h },
      { x: r.x, y: r.y },
    ];
    return c.flatMap((p) => [p, p]);
  }
  const n = 72;
  return Array.from({ length: n + 1 }, (_, i) => {
    const a = (i / n) * 2 * Math.PI - Math.PI / 2;
    return { x: r.x + r.w / 2 + (r.w / 2) * Math.cos(a), y: r.y + r.h / 2 + (r.h / 2) * Math.sin(a) };
  });
}

/** One stroke from pointer-down to pointer-up (InkStroke). `now` in seconds. */
export class InkStroke {
  pts: Pt[];
  shape: Pt[] | null = null;
  snappedAs: 'line' | 'rect' | 'ellipse' | null = null;
  private restAt: Pt;
  private restSince: number;

  constructor(
    readonly start: Pt,
    public tool: InkTool,
    now: number,
  ) {
    this.pts = [start];
    this.restAt = start;
    this.restSince = now;
  }

  get display(): Pt[] {
    return this.shape ?? this.pts;
  }
  get kind(): string {
    return this.snappedAs ?? this.tool;
  }
  get length(): number {
    let l = 0;
    for (let i = 1; i < this.pts.length; i++) l += dist(this.pts[i - 1], this.pts[i]);
    return l;
  }

  /** The pen moved (with these modifiers down): true when what is shown changed. */
  move(p: Pt, tool: InkTool, now: number): boolean {
    if (dist(p, this.restAt) > InkHold.radius * (this.snappedAs ? 2 : 1)) {
      this.restAt = p;
      this.restSince = now;
      if (this.snappedAs) {
        this.snappedAs = null;
        this.shape = null;
      }
    }
    this.tool = tool;
    let added = false;
    const last = this.pts[this.pts.length - 1];
    if (dist(p, last) >= 1.5) {
      this.pts.push(p);
      added = true;
    }
    if (tool !== 'free') {
      this.snappedAs = null;
      const s = dragShape(tool, this.start, p);
      this.shape = s ? shapePoints(s) : null;
      return true;
    }
    if (!this.snappedAs) {
      const was = this.shape !== null;
      this.shape = null;
      return added || was;
    }
    return false;
  }

  /** While the button is down: a freehand stroke the pen rested on snaps to its clean shape. True when it just did. */
  checkRest(now: number): boolean {
    if (this.tool !== 'free' || this.snappedAs || now - this.restSince < InkHold.seconds) return false;
    const s = inkFit(this.pts);
    if (!s) return false;
    this.shape = shapePoints(s);
    this.snappedAs = s.s;
    return true;
  }

  /** The kept points: a shape as it is, freehand thinned to ≥ minGap apart; a tap is its one point. */
  kept(minGap: number): Pt[] {
    if (this.shape) return this.shape;
    if (this.length < 6) return [this.pts[0]];
    const keep: Pt[] = [];
    for (const p of this.pts) if (!keep.length || dist(p, keep[keep.length - 1]) >= minGap) keep.push(p);
    const end = this.pts[this.pts.length - 1];
    const k = keep[keep.length - 1];
    if (k.x !== end.x || k.y !== end.y) keep.push(end);
    return keep;
  }
}

/** The line in px: wider on a bigger display (its short side), 3–6 in half px. */
export const inkWidth = (shortSide: number) => Math.round(Math.min(6, Math.max(3, shortSide / 260)) * 2) / 2;

/** How many pens the stage's hint is shown on (record.ink_hint_shown counts them). */
export const InkHint = { times: 3, shows: (alreadyShown: number) => alreadyShown < 3 };

// ------------------------------------------------------------------ where the bubble docks (BubbleDock)

export type DockSide = 'right' | 'left' | 'below' | 'above' | 'inside';
export interface Box {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** Where a `bubble`-sized box goes beside `sel`, inside `screen` (CSS px, y down): to the right with its top at the
    selection's top, else to the left, else below, else above; a selection that leaves no room outside gets it inside,
    in its bottom-right corner. */
export function dock(bubble: { w: number; h: number }, sel: Box, screen: Box, gap = 12, margin = 8): { x: number; y: number; side: DockSide } {
  const { w, h } = bubble;
  const right = screen.x + screen.w;
  const bottom = screen.y + screen.h;
  const clampY = (y: number) => Math.min(Math.max(y, screen.y + margin), bottom - margin - h);
  const clampX = (x: number) => Math.min(Math.max(x, screen.x + margin), right - margin - w);
  const top = clampY(sel.y);
  if (sel.x + sel.w + gap + w <= right - margin) return { x: sel.x + sel.w + gap, y: top, side: 'right' };
  if (sel.x - gap - w >= screen.x + margin) return { x: sel.x - gap - w, y: top, side: 'left' };
  if (sel.y + sel.h + gap + h <= bottom - margin) return { x: clampX(sel.x + sel.w - w), y: sel.y + sel.h + gap, side: 'below' };
  if (sel.y - gap - h >= screen.y + margin) return { x: clampX(sel.x + sel.w - w), y: sel.y - gap - h, side: 'above' };
  return { x: clampX(sel.x + sel.w - w - gap), y: clampY(sel.y + sel.h - h - gap), side: 'inside' };
}

// ------------------------------------------------------------------ the place list (ProjectPick)

export interface PlaceRef {
  id: string;
  name: string;
  key?: string;
  /** its folder can't be found */
  missing?: boolean;
}

const fold = (s: string) => s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();

/** Best first: the key typed exactly, names starting with it, a word of the name starting with it, the key starting
    with it, the name containing it. Ties keep the order given (recently used first). Empty: all, as given. */
export function filterPlaces<T extends PlaceRef>(items: T[], query: string): T[] {
  const q = fold(query.trim());
  if (!q) return items;
  const ranked: [number, number, T][] = [];
  items.forEach((it, i) => {
    const n = fold(it.name);
    const k = fold(it.key ?? '');
    const words = n.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
    const rank =
      k === q ? 0 : n.startsWith(q) ? 1 : words.some((w) => w.startsWith(q)) ? 2 : k.startsWith(q) ? 3 : n.includes(q) ? 4 : -1;
    if (rank >= 0) ranked.push([rank, i, it]);
  });
  return ranked.sort((a, b) => a[0] - b[0] || a[1] - b[1]).map((r) => r[2]);
}

/** The rows: at most `limit` projects (recent first, filtered), then Unassigned (null) while nothing is typed or its
    own name matches. */
export function placeChoices<T extends PlaceRef>(projects: T[], query: string, unassigned: string, limit = 6): (T | null)[] {
  // a project whose folder is gone can't take the snap: after the ones that can (still above Unassigned)
  const found = filterPlaces(projects, query);
  const rows: (T | null)[] = [...found.filter((p) => !p.missing), ...found.filter((p) => p.missing)].slice(0, limit);
  const typed = query.trim() !== '';
  if (!typed || filterPlaces([{ id: '', name: unassigned }], query).length) rows.push(null);
  return rows;
}

/** "0:04" */
export const clock = (s: number) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
