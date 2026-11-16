// The Text & Translation page's model (the Mac's MainWindow/ScreenTextPage.swift and BlurtCore CardSelection, in plain
// functions; docs/design/screen-text.md §1g): what Alt+Shift+C copied and Alt+Shift+T translated, newest first by day,
// a search over the text, the original and the app, and a list selection (click, Ctrl-click, Shift-click, the arrows,
// Ctrl+A). No React here (screentext.test.ts).
import type { ScreenTextEntry } from './api';

/** Every word of the search in the text, the original or the app (any case). */
export function matches(e: ScreenTextEntry, query: string): boolean {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
  const hay = [e.text, e.source ?? '', e.app ?? ''].join('\n').toLowerCase();
  return terms.every((w) => hay.includes(w));
}

/** The rows under their days (each day's first moment, local time), newest first as given. */
export function byDay(entries: ScreenTextEntry[]): { day: number; rows: ScreenTextEntry[] }[] {
  const out: { day: number; rows: ScreenTextEntry[] }[] = [];
  for (const e of entries) {
    const d = new Date(e.time * 1000);
    const day = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime() / 1000;
    const last = out[out.length - 1];
    if (last && last.day === day) last.rows.push(e);
    else out.push({ day, rows: [e] });
  }
  return out;
}

/** A list selection: the selected ids and the row a Shift-click or Shift+arrow extends from. */
export interface Selection {
  ids: string[];
  anchor: string | null;
}
export const NONE: Selection = { ids: [], anchor: null };

/** A click on `id` among `order` (the list as shown): alone; Ctrl (⌘) toggles it; Shift selects from the anchor. */
export function click(s: Selection, id: string, order: string[], mods: { toggle?: boolean; range?: boolean }): Selection {
  if (mods.range && s.anchor && order.includes(s.anchor)) {
    const a = order.indexOf(s.anchor);
    const b = order.indexOf(id);
    const [lo, hi] = a < b ? [a, b] : [b, a];
    return { ids: order.slice(lo, hi + 1), anchor: s.anchor };
  }
  if (mods.toggle) {
    const on = s.ids.includes(id);
    return { ids: on ? s.ids.filter((x) => x !== id) : [...s.ids, id], anchor: id };
  }
  return { ids: [id], anchor: id };
}

/** ↑ / ↓ (with Shift: extend from the anchor). Nothing selected: the first row. */
export function step(s: Selection, order: string[], by: 1 | -1, extend: boolean): Selection {
  if (!order.length) return NONE;
  const at = s.ids.length ? order.indexOf(s.ids[by > 0 ? s.ids.length - 1 : 0]) : -1;
  if (at < 0) return { ids: [order[0]], anchor: order[0] };
  // the moving end: the row away from the anchor (or the one selected)
  const ends = s.ids.map((x) => order.indexOf(x)).filter((i) => i >= 0);
  const anchorAt = s.anchor ? order.indexOf(s.anchor) : at;
  const moving = extend && ends.length > 1 ? (Math.min(...ends) === anchorAt ? Math.max(...ends) : Math.min(...ends)) : at;
  const next = Math.max(0, Math.min(order.length - 1, moving + by));
  if (!extend) return { ids: [order[next]], anchor: order[next] };
  const a = anchorAt < 0 ? next : anchorAt;
  const [lo, hi] = a < next ? [a, next] : [next, a];
  return { ids: order.slice(lo, hi + 1), anchor: order[a] };
}

/** What Copy puts on the clipboard for the selection: the texts in the list's order, a blank line between them;
 *  `original`: a translation's original instead (the others' own text). */
export function copied(entries: ScreenTextEntry[], ids: string[], original = false): string {
  return entries
    .filter((e) => ids.includes(e.id))
    .map((e) => (original && e.translated && e.source ? e.source : e.text).trim())
    .join('\n\n');
}

/** Settings' and the page's line: how many, and how long they are kept (`days` 7, 30, -1 forever, 0 not kept). */
export function keepLine(days: number, count: number, t: (k: string, p?: Record<string, string | number>) => string): string {
  if (days === 0) return t('home.screen_text.summary.off');
  if (days < 0) return t('home.screen_text.summary.forever', { n: count });
  return t('home.screen_text.summary', { n: count, a: t('home.screen_text.days', { n: days }) });
}
