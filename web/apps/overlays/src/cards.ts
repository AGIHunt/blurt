// The hanging cards' rules that need no DOM — a port of the Mac's BlurtCore CardRow.swift / IslandLayout.swift
// (CardShape) so the row on Windows / Linux hangs, sizes and reveals by the same numbers (island.ts draws it).
//
//  • the row (cardRow): newest first, left to right — at most 5 cards and never wider than 780 px; the rest wait
//    behind a quiet "+N" tile at the row's end. A "+1" tile never stands in for a card that would fit. Centred under
//    the island, never off the screen's edge (`bounds`: the window less its 12 px margins).
//  • a snap's card (cardShape): 84 px high, as wide as its picture wants within 84…150 px; a picture too wide or too
//    tall for that is shown whole (letterboxed), never as a blown-up slice of its middle.
//  • the threads (threadX): straight above their card while the row fits under the island; a wider row is mapped onto
//    the island's bottom edge in proportion, so they keep their order and never fan from its corners.
//  • making room for a lifted card (stepAside): the items on each side step 8 px aside, the tile too.
//  • coming down (CardReveal): after the pointer has rested on the island 180 ms; up again 250 ms after it left.
//  • a click (DeferredClick): copies once the double-click interval has passed; a double-click edits the note instead.

export const CARD_H = 84;
export const SHOT_DEFAULT = { w: 112, h: CARD_H };
export const VOICE = { w: 168, h: 50 };
export const TILE = { w: 72, h: CARD_H };
export const GAP = 12;
/** the cards keep this far from the window's (the screen's) edges */
export const EDGE = 12;
/** the cards' top edge under the island (every card's: no uneven threads at rest) */
export const BELOW = 18;
export const MAX_SHOWN = 5;
export const MAX_WIDTH = 780;
/** the lifted card: this much higher, 1.05× from its clasp; its neighbours step this far aside */
export const LIFT = 5;
export const LIFT_SCALE = 0.05;
export const ASIDE = 8;

export interface RowLayout {
  /** indices into the cards (kept oldest first) in the order they hang, left to right: newest first */
  shown: number[];
  /** each shown card's centre x, in the same order */
  centres: number[];
  /** the cards that don't hang: the "+N" tile's count (0: no tile) */
  more: number;
  /** the tile's centre x, nil without one */
  tileX: number | null;
  /** from the left edge of the first item to the right edge of the last (the tile included) */
  span: [number, number];
}

/** `widths`: every card's width, oldest first. `centre`: the island's centre x. `bounds`: where the row may go. */
export function cardRow(
  widths: number[],
  centre: number,
  bounds: [number, number],
  { tile = TILE.w, gap = GAP, maxShown = MAX_SHOWN, maxWidth = MAX_WIDTH } = {},
): RowLayout {
  if (!widths.length) return { shown: [], centres: [], more: 0, tileX: null, span: [0, 0] };
  const [lo, hi] = bounds;
  const screen = Math.max(0, hi - lo);
  const room = Math.min(maxWidth, screen);
  const width = (n: number) =>
    widths.slice(widths.length - n).reduce((a, b) => a + b, 0) + gap * Math.max(0, n - 1) + (widths.length > n ? gap + tile : 0);
  let n = Math.min(widths.length, Math.max(1, maxShown));
  while (n > 1 && width(n) > room) n--;
  // no "+1" for a card that fits: the one card it would hide hangs instead, in the room the tile row may take
  if (widths.length === n + 1 && n + 1 <= Math.max(1, maxShown) && width(n + 1) <= Math.min(screen, room + gap + tile)) n++;
  const shown: number[] = [];
  for (let i = widths.length - 1; i >= widths.length - n; i--) shown.push(i);
  const total = width(n);
  // centred on the island, but never off the screen's edge
  let x = Math.min(Math.max(centre - total / 2, lo), Math.max(lo, hi - total));
  const left = x;
  const centres: number[] = [];
  for (const i of shown) {
    centres.push(x + widths[i] / 2);
    x += widths[i] + gap;
  }
  const more = widths.length - n;
  return { shown, centres, more, tileX: more > 0 ? x + tile / 2 : null, span: [left, left + total] };
}

/** The island's centre in the window: the stage's middle (the island is CSS-centred on it). A window not laid out
 *  yet (0 wide) falls back to the screen's, never to 0 — that hung the row at the window's left edge. */
export function rowCentre(stageWidth: number, fallback: number): number {
  const w = stageWidth > 0 ? stageWidth : fallback;
  return w > 0 ? w / 2 : 0;
}

/** Where the row may go: the window less EDGE each side. */
export const rowBounds = (stageWidth: number): [number, number] => [EDGE, Math.max(EDGE, stageWidth - EDGE)];

/** A snap's card for a picture `px` big (null: not known yet — the classic 4:3 card). `fills`: aspect fill (a little
 *  of its edges cut) or shown whole on the card's surface. */
export function cardShape(px: { w: number; h: number } | null): { w: number; h: number; fills: boolean } {
  if (!px || px.w <= 0 || px.h <= 0) return { ...SHOT_DEFAULT, fills: true };
  const w = Math.min(150, Math.max(84, Math.round((CARD_H * px.w) / px.h)));
  return { w, h: CARD_H, fills: fills(px, { w, h: CARD_H }) };
}

/** Fill only while aspect fill cuts at most 40 % of the picture. */
export function fills(p: { w: number; h: number }, b: { w: number; h: number }): boolean {
  if (p.w <= 0 || p.h <= 0 || b.w <= 0 || b.h <= 0) return true;
  const a = p.w / p.h;
  const c = b.w / b.h;
  return 1 - Math.min(a / c, c / a) <= 0.4;
}

/** Where a card's thread leaves the island's bottom edge (`edge`), given the whole row's span. */
export function threadX(x: number, row: [number, number], edge: [number, number]): number {
  const rw = row[1] - row[0];
  const ew = edge[1] - edge[0];
  if (!(rw > ew) || rw <= 0) return Math.min(Math.max(x, edge[0]), edge[1]);
  const k = (x - row[0]) / rw;
  return Math.min(Math.max(edge[0] + k * ew, edge[0]), edge[1]);
}

/** Making room for a lifted card: everything left of it moves `by` left, everything right of it (the tile too) right. */
export function stepAside(items: number, lifted: number | null, by = ASIDE): number[] {
  return Array.from({ length: Math.max(0, items) }, (_, i) => (lifted === null || lifted >= items || i === lifted ? 0 : i < lifted ? -by : by));
}

export const CardReveal = {
  /** the pointer rests on the island this long before the cards come down (the island opens after the same time) */
  dwell: 180,
  /** they go back up this long after the pointer has left their region */
  away: 250,
  /** resting on the ear's count opens the island a little later, so the count can still be clicked */
  earDwell: 800,
  /** brought down on purpose (the ear's count) with the pointer elsewhere: they stop staying down this long after */
  unvisited: 10000,
  /** a new capture's card shows this long before it goes up (the Mac: a few seconds after a capture) */
  afterCapture: 3000,
  /** cards brought down on purpose stay until the pointer has been on them and left — or `unvisited` after */
  staysDown: (visited: boolean, pointerIn: boolean, sinceReveal: number) => (visited ? pointerIn : sinceReveal < CardReveal.unvisited),
};

/** A plain click copies once the double-click interval has passed; a second click cancels it (double-click = edit the
 *  note), so editing never overwrites the clipboard first. */
export class DeferredClick<ID> {
  pending: ID | null = null;
  due = 0;
  click(id: ID, count: number, at: number, interval: number): 'edit' | 'copy' {
    if (count >= 2) {
      this.pending = null;
      return 'edit';
    }
    this.pending = id;
    this.due = at + interval;
    return 'copy';
  }
  fire(at: number): ID | null {
    if (this.pending === null || at < this.due) return null;
    const id = this.pending;
    this.pending = null;
    return id;
  }
  cancel() {
    this.pending = null;
  }
}

/** Delete never asks: "Deleted · Undo" for this long; deletes in a row gather under that one Undo. */
export const UNDO_MS = 5000;

// ------------------------------------------------------------------ the Cards panel (BlurtCore CardsPanelKeys, CardGrid)

export type Segment = 'hanging' | 'used';
export type PanelKey = 'left' | 'right' | 'up' | 'down' | 'space' | 'tab' | 'enter' | 'copy' | 'delete' | 'escape' | 'close';
export type PanelAction =
  | { a: 'segment'; seg: Segment }
  | { a: 'focus'; i: number | null }
  | { a: 'preview'; i: number }
  | { a: 'copyAndClose'; i: number }
  | { a: 'delete'; i: number }
  | { a: 'close' }
  | { a: 'none' };

/** The overview's grid: one row up to 4 cards, then half of them a row (rounded up), at most 4 — never an orphan. */
export const gridColumns = (n: number) => (n <= 4 ? Math.max(1, n) : Math.min(4, Math.ceil(n / 2)));
export const TILE_W = 148;
export const TILE_H = 100;
export const PANEL_GAP = 14;
export const PANEL_PAD = 16;
export const PANEL_MIN_W = 440;
export const gridWidth = (cols: number) => PANEL_PAD * 2 + cols * TILE_W + Math.max(0, cols - 1) * PANEL_GAP;

export const CardsPanelRules = {
  /** Show Cards with the panel closed: Current while a card hangs, else History; nothing in either: nothing. */
  openSegment(hanging: number, used: number): Segment | null {
    if (hanging > 0) return 'hanging';
    return used > 0 ? 'used' : null;
  },
  toggle(isOpen: boolean, hanging: number, used: number): 'close' | 'nothing' | Segment {
    if (isOpen) return 'close';
    return CardsPanelRules.openSegment(hanging, used) ?? 'nothing';
  },
  /** What `key` does with the keyboard on the panel (the one key map). */
  action(key: PanelKey, seg: Segment, focus: number | null, count: number, columns: number, pointed: number | null = null): PanelAction {
    const f = focus !== null && focus >= 0 && focus < count ? focus : null;
    const cols = Math.max(1, columns);
    switch (key) {
      case 'tab':
        return { a: 'segment', seg: seg === 'hanging' ? 'used' : 'hanging' };
      case 'left':
        if (f === null) return seg === 'hanging' ? { a: 'none' } : { a: 'segment', seg: 'hanging' };
        return f > 0 ? { a: 'focus', i: f - 1 } : { a: 'none' };
      case 'right':
        if (f === null) return seg === 'used' ? { a: 'none' } : { a: 'segment', seg: 'used' };
        return f < count - 1 ? { a: 'focus', i: f + 1 } : { a: 'none' };
      case 'down': {
        if (f === null) return count > 0 ? { a: 'focus', i: 0 } : { a: 'none' };
        const lastRow = Math.floor((count - 1) / cols);
        return Math.floor(f / cols) < lastRow ? { a: 'focus', i: Math.min(f + cols, count - 1) } : { a: 'none' };
      }
      case 'up':
        if (f === null) return { a: 'none' };
        return f - cols >= 0 ? { a: 'focus', i: f - cols } : { a: 'focus', i: null };
      case 'space': {
        const i = f ?? (pointed !== null && pointed >= 0 && pointed < count ? pointed : null);
        return i === null ? { a: 'none' } : { a: 'preview', i };
      }
      case 'enter':
      case 'copy':
        return f === null ? { a: 'none' } : { a: 'copyAndClose', i: f };
      case 'delete':
        return f === null ? { a: 'none' } : { a: 'delete', i: f };
      case 'escape':
      case 'close':
        return { a: 'close' };
    }
  },
  /** In the preview: ← / ↑ the card before, → / ↓ the one after, Space or Esc back to the grid. */
  previewAction(key: PanelKey): { a: 'step'; d: number } | { a: 'close' } | { a: 'none' } {
    if (key === 'left' || key === 'up') return { a: 'step', d: -1 };
    if (key === 'right' || key === 'down') return { a: 'step', d: 1 };
    if (key === 'space' || key === 'escape' || key === 'close') return { a: 'close' };
    return { a: 'none' };
  },
};

/** A key event as the panel names it (Windows: Ctrl where the Mac has ⌘). */
export function panelKey(e: { key: string; ctrlKey?: boolean; metaKey?: boolean }): PanelKey | null {
  const cmd = !!(e.ctrlKey || e.metaKey);
  switch (e.key) {
    case 'ArrowLeft':
      return 'left';
    case 'ArrowRight':
      return 'right';
    case 'ArrowUp':
      return 'up';
    case 'ArrowDown':
      return 'down';
    case ' ':
      return cmd ? null : 'space';
    case 'Tab':
      return 'tab';
    case 'Enter':
      return 'enter';
    case 'Backspace':
    case 'Delete':
      return 'delete';
    case 'Escape':
      return 'escape';
  }
  if (cmd && e.key.toLowerCase() === 'c') return 'copy';
  if (cmd && e.key.toLowerCase() === 'w') return 'close';
  return null;
}

/** How long ago, for the cards' panels: "Just now" under a minute, then minutes, hours, "Yesterday", days. */
export type Ago = { k: 'just' } | { k: 'min'; n: number } | { k: 'hr'; n: number } | { k: 'yesterday' } | { k: 'days'; n: number };
export function cardAgo(seconds: number): Ago {
  const s = Math.max(0, seconds);
  if (s < 60) return { k: 'just' };
  if (s < 3600) return { k: 'min', n: Math.floor(s / 60) };
  if (s < 86400) return { k: 'hr', n: Math.floor(s / 3600) };
  const d = Math.floor(s / 86400);
  return d === 1 ? { k: 'yesterday' } : { k: 'days', n: d };
}

/** A used card is kept 7 days: whole days left (it says so on its last day). */
export const daysLeft = (takenAt: number, now: number) => Math.max(0, Math.ceil(7 - (now - takenAt) / 86400));
