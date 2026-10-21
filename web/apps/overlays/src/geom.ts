import type { CssRect } from './host';

export const MIN_SIZE = 24; // css px; a smaller drag is a click (= full screen)

export function rectFrom(a: { x: number; y: number }, b: { x: number; y: number }): CssRect {
  return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), w: Math.abs(a.x - b.x), h: Math.abs(a.y - b.y) };
}

export function clampRect(r: CssRect, bounds: { w: number; h: number }): CssRect {
  const x = Math.max(0, Math.min(r.x, bounds.w));
  const y = Math.max(0, Math.min(r.y, bounds.h));
  return { x, y, w: Math.max(0, Math.min(r.x + r.w, bounds.w) - x), h: Math.max(0, Math.min(r.y + r.h, bounds.h) - y) };
}

/** Move a rect by (dx, dy) without leaving the bounds (dragging a selection). */
export function moveRect(r: CssRect, dx: number, dy: number, bounds: { w: number; h: number }): CssRect {
  return {
    ...r,
    x: Math.max(0, Math.min(r.x + dx, bounds.w - r.w)),
    y: Math.max(0, Math.min(r.y + dy, bounds.h - r.h)),
  };
}

export const isClick = (r: CssRect) => r.w < MIN_SIZE || r.h < MIN_SIZE;

export const contains = (r: CssRect, x: number, y: number) => x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;

/** "1280 × 720" in the pixels that will be recorded (physical, even — like record.py). */
export function sizeLabel(r: CssRect, dpr: number): string {
  const w = Math.round(r.w * dpr) & ~1;
  const h = Math.round(r.h * dpr) & ~1;
  return `${w} × ${h}`;
}

/** Where the picker's toolbar goes: under the selection, else above, else inside at the bottom. */
export function toolbarPos(r: CssRect, bar: { w: number; h: number }, bounds: { w: number; h: number }, gap = 10) {
  const x = Math.max(8, Math.min(r.x + r.w - bar.w, bounds.w - bar.w - 8));
  if (r.y + r.h + gap + bar.h <= bounds.h) return { x, y: r.y + r.h + gap };
  if (r.y - gap - bar.h >= 0) return { x, y: r.y - gap - bar.h };
  return { x, y: Math.max(0, r.y + r.h - gap - bar.h) };
}

export function parseRect(s: string | null): CssRect | null {
  if (!s) return null;
  const v = s.split(',').map(Number);
  return v.length === 4 && v.every(Number.isFinite) ? { x: v[0], y: v[1], w: v[2], h: v[3] } : null;
}
