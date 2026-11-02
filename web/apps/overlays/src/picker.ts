// The area picker (the Mac's Picker.swift; docs/design/windows-parity/snap-and-note.md §5–6): a transparent window over
// one monitor. Emits {rect} in this window's CSS px (Rust maps it to the desktop), or null when cancelled.
//  • snap (purpose=screenshot): like ⌘⇧4 — letting go of a drag takes the shot; a click takes the window under the
//    pointer (`wins`, the visible top-level windows, top first); F the whole screen, L the last area. Taken, the dim
//    stays (frozen) until the note's stage is up and Rust closes this window.
//  • record: the same choosing, then the toolbar — Cancel esc · Full screen F · Last area L | Start recording ↩.
//  • text / translate (Copy Text, Translate): a crosshair and one drag, no dim, no toolbar, no hint (ScreenTextCopy's
//    TextDragPicker); letting go reads it.
// Keys: Esc cancels (Shift+Esc clears the selection), Enter / Space confirm, F, L, ? the key legend, arrows nudge 1 px
// (Shift 10). Double-click inside the selection confirms.
import { iconSvg } from '@blurt/icons/core';
import { contains, parseRect } from './geom';
import { EV, connect, params, ready, t, type CssRect } from './host';

const host = await connect('picker');
const $ = <T extends HTMLElement>(s: string) => document.querySelector<T>(s)!;
const mask = $('.mask');
const winEl = $('.win');
const wlabel = $('.wlabel');
const sel = $('.sel');
const size = $('.size');
const hint = $('.hint');
const bar = $('.bar');
const handles = [...sel.querySelectorAll<HTMLElement>('.h')];
const loupe = $<HTMLCanvasElement>('.loupe');

const asked = params.get('purpose');
const purpose = asked === 'screenshot' || asked === 'text' || asked === 'translate' ? asked : 'record';
const textMode = purpose === 'text' || purpose === 'translate';
const snapMode = purpose !== 'record';
const last = parseRect(params.get('last'));
/** the visible windows under this one, top first (Windows: Rust lists them); absent: no window picking (Linux) */
const wins: CssRect[] | null = (() => {
  const raw = params.get('wins');
  if (raw === null) return null;
  try {
    return (JSON.parse(raw) as number[][]).filter((r) => r.length === 4).map(([x, y, w, h]) => ({ x, y, w, h }));
  } catch {
    return [];
  }
})();
/** the work area (minus the taskbar), CSS px of this window */
const work = parseRect(params.get('work'));
/** the first few pickers (snap.rs hint_budget): the full key legend, and the hovered window's "Click to snap this
    window" — the label keeps its own budget, so ? (the legend off) never takes the one cue a click needs */
const firstUses = params.get('legend') !== '0';
let legend = firstUses;
document.body.classList.toggle('text', textMode);

const W = () => innerWidth;
const H = () => innerHeight;
let rect: CssRect | null = null;
let hovered: CssRect | null = null;
/** the selection came from a window, F or L: a drag inside it draws a new one */
let snapped = false;
let drawing = false;
let mode: { k: 'none' } | { k: 'create'; x: number; y: number } | { k: 'move'; x: number; y: number; r: CssRect } | { k: 'resize'; i: number; r: CssRect } = {
  k: 'none',
};
let frozen = false;
let done = false;

const px = (n: number) => `${Math.round(n)}px`;
const place = (el: HTMLElement, r: CssRect) => Object.assign(el.style, { left: px(r.x), top: px(r.y), width: px(r.w), height: px(r.h) });
const clampTo = (r: CssRect): CssRect => {
  const x = Math.max(0, Math.min(r.x, W()));
  const y = Math.max(0, Math.min(r.y, H()));
  return { x, y, w: Math.max(0, Math.min(r.x + r.w, W()) - x), h: Math.max(0, Math.min(r.y + r.h, H()) - y) };
};
const fills = (r: CssRect) => r.w >= W() - 1 && r.h >= H() - 1;
const radius = () => (document.documentElement.dataset.platform === 'win' ? 8 : 12);
const keycap = (k: string, cls = '') => `<kbd${cls ? ` class="${cls}"` : ''}>${k}</kbd>`;
/** CSS px → this monitor's physical px (what the loupe's readout and the size badge count) */
const phys = (v: number) => Math.round(v * (devicePixelRatio || 1));

/** the whole window, then the hole (rounded like the window when r > 0): an even-odd path for the dim's clip-path */
function holePath(h: CssRect, r: number) {
  const outer = `M0 0H${W()}V${H()}H0Z`;
  const { x, y, w, h: hh } = h;
  if (r <= 0) return `${outer} M${x} ${y}h${w}v${hh}h${-w}Z`;
  return `${outer} M${x + r} ${y}h${w - 2 * r}a${r} ${r} 0 0 1 ${r} ${r}v${hh - 2 * r}a${r} ${r} 0 0 1 ${-r} ${r}h${-(w - 2 * r)}a${r} ${r} 0 0 1 ${-r} ${-r}v${-(hh - 2 * r)}a${r} ${r} 0 0 1 ${r} ${-r}Z`;
}

function windowAt(x: number, y: number): CssRect | null {
  return wins?.find((r) => r.w > 40 && r.h > 40 && contains(r, x, y)) ?? null;
}

function handlePoints(r: CssRect) {
  const { x, y, w, h } = r;
  return [
    [x, y],
    [x + w / 2, y],
    [x + w, y],
    [x + w, y + h / 2],
    [x + w, y + h],
    [x + w / 2, y + h],
    [x, y + h],
    [x, y + h / 2],
  ];
}

function hintHtml() {
  const keys: [string, string][] = [];
  if (legend) {
    keys.push(['F', t('picker.full_screen')]);
    if (last) keys.push(['L', t('picker.last_area')]);
  }
  keys.push(['Esc', t('picker.cancel')]);
  // the legend off: a faint ? after Esc says how to bring it back
  const back = legend ? '' : `<span class="kv q" title="${t('picker.legend_tip')}">${keycap('?', 'faint')}</span>`;
  return `${iconSvg(snapMode ? 'snap' : 'record', { size: 15, className: 'ic' })}<span class="lead">${t(snapMode ? 'picker.lead_snap' : 'picker.lead_record')}</span><i class="rule"></i>${keys
    .map(([k, w]) => `<span class="kv">${keycap(k)}<span>${w}</span></span>`)
    .join('')}${back}`;
}

function barHtml() {
  const b = (a: string, label: string, key: string) =>
    `<button data-a="${a}" title="${t('picker.tip_key', { what: label, key })}"><span>${label}</span><span class="key">${key}</span></button>`;
  const parts = [b('cancel', t('picker.cancel'), 'Esc'), b('full', t('picker.full_screen'), 'F')];
  if (last) parts.push(b('last', t('picker.last_area'), 'L'));
  const ok = snapMode ? t('picker.snap') : t('picker.start');
  parts.push(
    '<i class="rule"></i>',
    `<button data-a="ok" class="primary" title="${t('picker.tip_key', { what: ok, key: '↩' })}">${iconSvg(snapMode ? 'snap' : 'record', { size: 15, className: 'ic' })}<span>${ok}</span><span class="key">↩</span></button>`,
  );
  return parts.join('');
}

let hintBuilt = '';
function render() {
  const hole = rect ?? (textMode ? null : hovered);
  // the dim is its own layer with the hole cut out (even-odd): WebView2 clips a 100vmax box-shadow to the element's
  // own box on a transparent window, so the shadow trick left the rest of the screen undimmed
  mask.hidden = textMode;
  mask.classList.toggle('hole', !!hole);
  mask.style.clipPath = hole ? `path(evenodd, '${holePath(hole, !rect && !fills(hole) ? radius() : 0)}')` : '';
  document.body.classList.toggle('frozen', frozen);
  // the hovered window, in its own shape: a mint 10 % tint, a 2 px mint line; what a click does on it (legend only)
  winEl.hidden = !!rect || !hovered || textMode;
  if (!winEl.hidden && hovered) {
    place(winEl, hovered);
    winEl.style.borderRadius = fills(hovered) ? '0' : px(radius());
    wlabel.innerHTML = `${iconSvg(snapMode ? 'snap' : 'record', { size: 14, className: 'ic' })}<span>${t(snapMode ? 'picker.window_snap' : 'picker.window_record')}</span>`;
    const lw = wlabel.offsetWidth;
    wlabel.hidden = !firstUses || lw > hovered.w - 16 || hovered.h <= 40;
  }
  sel.hidden = !rect;
  if (rect) {
    place(sel, rect);
    const showHandles = !frozen && !drawing && !textMode;
    handlePoints(rect).forEach(([x, y], i) => {
      handles[i].hidden = !showHandles;
      Object.assign(handles[i].style, { left: px(x - rect!.x), top: px(y - rect!.y) });
    });
    size.hidden = frozen || textMode;
    size.textContent = `${phys(rect.w)} × ${phys(rect.h)}`;
    // above its top-left corner, 6 px clear of the 2 px line; inside the corner when there's no room above
    const above = rect.y - 2 - 6 - 22 >= 4;
    Object.assign(size.style, above ? { left: '-2px', top: '-32px' } : { left: '8px', top: '10px' });
  }
  // the how-to: bottom centre, above the taskbar; at the top when the hovered window covers that spot
  hint.hidden = frozen || !!rect || drawing || textMode;
  if (!hint.hidden) {
    const html = hintHtml();
    if (html !== hintBuilt) hint.innerHTML = hintBuilt = html;
    const wa = work ?? { x: 0, y: 0, w: W(), h: H() };
    const hw = hint.offsetWidth;
    const hh = hint.offsetHeight;
    // one gap in DIP above the work area's bottom (the taskbar) at every scale
    let r = { x: Math.round((W() - hw) / 2), y: wa.y + wa.h - 24 - hh, w: hw, h: hh };
    // a hovered window's edge never runs through it (12 px clear): at the top under the island when its bottom edge is
    // in the way, else just inside the window's bottom edge
    const crosses = (win: CssRect, a: CssRect) => {
      const m = 12;
      const over = a.x - m < win.x + win.w && a.x + a.w + m > win.x && a.y - m < win.y + win.h && a.y + a.h + m > win.y;
      const inside = a.x >= win.x + m && a.x + a.w <= win.x + win.w - m && a.y >= win.y + m && a.y + a.h <= win.y + win.h - m;
      return over && !inside;
    };
    if (hovered && crosses(hovered, r)) {
      const top = { ...r, y: wa.y + 52 };
      const inner = { ...r, y: Math.min(r.y, hovered.y + hovered.h - 24 - hh) };
      if (!crosses(hovered, top)) r = top;
      else if (!crosses(hovered, inner) && inner.y > wa.y + 52) r = inner;
    }
    Object.assign(hint.style, { left: px(r.x), top: px(r.y) });
  }
  // the toolbar: under the selection, centred; above it, else inside at its bottom (snap: none while a drag draws)
  bar.hidden = frozen || textMode || !rect || rect.w < 8 || rect.h < 8 || (snapMode && mode.k !== 'none');
  if (!bar.hidden && rect) {
    if (!bar.innerHTML) bar.innerHTML = barHtml();
    const bw = bar.offsetWidth;
    const bh = bar.offsetHeight;
    // the Mac's (C32): centred on the selection, straddling its bottom edge; kept 12 px inside the work area (never on
    // the taskbar) — a selection that reaches the bottom gets it just inside its bottom edge
    const wa = work ?? { x: 0, y: 0, w: W(), h: H() };
    let y = rect.y + rect.h - bh / 2;
    if (y + bh > wa.y + wa.h - 12) y = Math.min(rect.y + rect.h, wa.y + wa.h) - 12 - bh;
    if (y < wa.y + 12) y = wa.y + 12;
    const x = Math.max(wa.x + 12, Math.min(rect.x + rect.w / 2 - bw / 2, wa.x + wa.w - bw - 12));
    Object.assign(bar.style, { left: px(x), top: px(y) });
  }
}

function finish(r: CssRect | null) {
  if (done) return;
  done = true;
  // a snap is being taken: only the dim (and the line) until the stage takes over
  if (r && snapMode && !textMode) {
    frozen = true;
    render();
  }
  void host.emit(EV.picked, { rect: r });
  if (host.host === 'browser') document.body.dataset.picked = JSON.stringify(r);
}

const confirm = () => rect && finish(rect);

function full() {
  rect = { x: 0, y: 0, w: W(), h: H() };
  snapped = true;
  render();
  if (snapMode) confirm();
}

function useLast() {
  if (!last) return;
  rect = clampTo(last);
  snapped = true;
  render();
  if (snapMode) confirm();
}

addEventListener('pointerdown', (e) => {
  if (done || e.button !== 0 || (e.target as HTMLElement).closest('.bar')) return;
  (e.target as HTMLElement).setPointerCapture?.(e.pointerId);
  const p = { x: e.clientX, y: e.clientY };
  if (e.detail === 2 && rect && contains(rect, p.x, p.y) && !textMode) return confirm();
  if (rect && !textMode) {
    const i = handlePoints(rect).findIndex(([x, y]) => Math.hypot(x - p.x, y - p.y) < 10);
    if (i >= 0) {
      mode = { k: 'resize', i, r: rect };
      return;
    }
    if (contains(rect, p.x, p.y) && !snapped) {
      mode = { k: 'move', x: p.x, y: p.y, r: rect };
      return;
    }
  }
  mode = { k: 'create', ...p };
});

addEventListener('pointermove', (e) => {
  const p = { x: e.clientX, y: e.clientY };
  if (mode.k === 'none') {
    if (!rect && !textMode && wins) {
      const h = windowAt(p.x, p.y);
      if (JSON.stringify(h) !== JSON.stringify(hovered)) {
        hovered = h;
        render();
      }
    }
    return;
  }
  if (mode.k === 'create') {
    if (Math.hypot(p.x - mode.x, p.y - mode.y) <= 4) return;
    drawing = true;
    const q = { x: Math.max(0, Math.min(p.x, W())), y: Math.max(0, Math.min(p.y, H())) };
    rect = { x: Math.min(mode.x, q.x), y: Math.min(mode.y, q.y), w: Math.abs(q.x - mode.x), h: Math.abs(q.y - mode.y) };
    snapped = false;
    hovered = null;
  } else if (mode.k === 'move') {
    const r = mode.r;
    rect = {
      ...r,
      x: Math.min(Math.max(r.x + p.x - mode.x, 0), W() - r.w),
      y: Math.min(Math.max(r.y + p.y - mode.y, 0), H() - r.h),
    };
  } else if (mode.k === 'resize') {
    const r = mode.r;
    let [x0, y0, x1, y1] = [r.x, r.y, r.x + r.w, r.y + r.h];
    if ([0, 6, 7].includes(mode.i)) x0 = p.x;
    if ([2, 3, 4].includes(mode.i)) x1 = p.x;
    if ([0, 1, 2].includes(mode.i)) y0 = p.y;
    if ([4, 5, 6].includes(mode.i)) y1 = p.y;
    rect = clampTo({ x: Math.min(x0, x1), y: Math.min(y0, y1), w: Math.abs(x1 - x0), h: Math.abs(y1 - y0) });
    snapped = false;
  }
  document.body.classList.toggle('dragging', true);
  render();
});

addEventListener('pointerup', (e) => {
  if (mode.k === 'none') return;
  const m = mode;
  mode = { k: 'none' };
  drawing = false;
  document.body.classList.remove('dragging');
  if (m.k === 'create') {
    const p = { x: e.clientX, y: e.clientY };
    if (Math.hypot(p.x - m.x, p.y - m.y) <= 4) {
      if (textMode) return finish(null);
      // a click: the window under the pointer (no window list: the whole screen, as before)
      const h = wins ? (hovered ?? windowAt(m.x, m.y)) : { x: 0, y: 0, w: W(), h: H() };
      if (h) {
        rect = clampTo(h);
        snapped = true;
        hovered = null;
      }
    }
  }
  if (rect && (rect.w < (textMode ? 4 : 16) || rect.h < (textMode ? 4 : 16))) rect = null;
  render();
  // like ⌘⇧4: letting go takes it (a text drag: reads it; nothing dragged: cancelled)
  if (textMode) return finish(rect);
  if (snapMode && rect) confirm();
});

addEventListener('keydown', (e) => {
  if (done || e.isComposing) return;
  if (e.key === 'Escape') {
    if (rect && e.shiftKey && !textMode) {
      rect = null;
      render();
    } else finish(null);
    return;
  }
  if (textMode) return;
  if (e.key === 'Enter' || e.key === ' ') {
    e.preventDefault();
    return confirm();
  }
  const k = e.key.toLowerCase();
  if (k === 'f' && !e.ctrlKey && !e.altKey && !e.metaKey) return full();
  if (k === 'l' && !e.ctrlKey && !e.altKey && !e.metaKey) return useLast();
  if (e.key === '?' || e.key === '/') {
    legend = !legend;
    hintBuilt = '';
    return render();
  }
  const d = e.shiftKey ? 10 : 1;
  const nudge: Record<string, [number, number]> = { ArrowLeft: [-d, 0], ArrowRight: [d, 0], ArrowUp: [0, -d], ArrowDown: [0, d] };
  if (nudge[e.key] && rect) {
    e.preventDefault();
    rect = { ...rect, x: rect.x + nudge[e.key][0], y: rect.y + nudge[e.key][1] };
    render();
  }
});

bar.addEventListener('click', (e) => {
  const a = (e.target as HTMLElement).closest<HTMLElement>('[data-a]')?.dataset.a;
  if (a === 'ok') confirm();
  if (a === 'cancel') finish(null);
  if (a === 'full') full();
  if (a === 'last') useLast();
});
// ------------------------------------------------------------------ the loupe (Loupe.swift)
// 120 px, 8×, nearest neighbour with the pixel grid on it; the pixel under the pointer framed, a crosshair through it;
// under it the Mac's readout — where the pointer is (physical px), or the selection's size while a drag draws it
const ZOOM = 8;
const SIZE = 120;
const LABEL_H = 28; // 6 px gap + a 22 px pill
const PAD = 14; // room for the ring and the shadow round the disc (the canvas draws them)
const GAP = 24; // from the pointer
const still = new Image();
let stillReady = false;
if (params.get('still')) {
  still.onload = () => (stillReady = true);
  still.src = params.get('still')!;
}
let pointer = { x: -1, y: -1 };
let loupeFrame = 0;

/** It shows while it helps place an edge (parity 5.9): not over a window that a click would take whole, not on (or by)
    the toolbar; with a selection only within 16 px of its edges, or while a drag draws it. */
function loupeWanted(p: { x: number; y: number }) {
  if (!stillReady || frozen || done || p.x < 0) return false;
  if (textMode || mode.k !== 'none') return true;
  if (!rect) return !hovered; // a hovered window is taken with a click: nothing to line up
  if (!bar.hidden) {
    const b = bar.getBoundingClientRect();
    if (p.x > b.left - 12 && p.x < b.right + 12 && p.y > b.top - 12 && p.y < b.bottom + 12) return false;
  }
  const m = 16;
  const out = { x: rect.x - m, y: rect.y - m, w: rect.w + 2 * m, h: rect.h + 2 * m };
  const inn = { x: rect.x + m, y: rect.y + m, w: rect.w - 2 * m, h: rect.h - 2 * m };
  return contains(out, p.x, p.y) && !(inn.w > 0 && inn.h > 0 && contains(inn, p.x, p.y));
}

function drawLoupe() {
  loupeFrame = 0;
  const p = pointer;
  loupe.hidden = !loupeWanted(p);
  if (loupe.hidden) return;
  // 24 px from the pointer: below-right as the Mac's Loupe.frame (Copy Text too: up-left covered the line above the one
  // being aimed at); while a drag draws, on the side away from the selection; flipped where it would leave the work area
  const wa = work ?? { x: 0, y: 0, w: W(), h: H() };
  let dx = 1;
  let dy = 1;
  if (mode.k === 'create') {
    dx = p.x >= mode.x ? 1 : -1;
    dy = p.y >= mode.y ? 1 : -1;
  }
  const fullH = SIZE + LABEL_H;
  const at = (d: number, v: number, len: number) => (d > 0 ? v + GAP : v - GAP - len);
  let x = at(dx, p.x, SIZE);
  let y = at(dy, p.y, fullH);
  if (x < wa.x + 4 || x + SIZE > wa.x + wa.w - 4) x = at(-dx, p.x, SIZE);
  if (y < wa.y + 4 || y + fullH > wa.y + wa.h - 4) y = at(-dy, p.y, fullH);
  Object.assign(loupe.style, { left: `${x - PAD}px`, top: `${y - PAD}px` });
  const dpr = devicePixelRatio || 1;
  const cw = SIZE + 2 * PAD;
  const ch = fullH + 2 * PAD;
  if (loupe.width !== Math.round(cw * dpr)) {
    loupe.width = Math.round(cw * dpr);
    loupe.height = Math.round(ch * dpr);
    loupe.style.width = `${cw}px`;
    loupe.style.height = `${ch}px`;
  }
  const g = loupe.getContext('2d')!;
  g.setTransform(dpr, 0, 0, dpr, PAD * dpr, PAD * dpr);
  g.clearRect(-PAD, -PAD, cw, ch);
  // the disc's shadow (black 35 %, 12 px, y + 4), drawn once under it
  g.save();
  g.shadowColor = 'rgb(0 0 0 / 0.35)';
  g.shadowBlur = 12;
  g.shadowOffsetY = 4;
  g.beginPath();
  g.roundRect(0, 0, SIZE, SIZE, 10);
  g.fillStyle = 'rgb(20 20 20)';
  g.fill();
  g.restore();
  g.save();
  g.beginPath();
  g.roundRect(0, 0, SIZE, SIZE, 10);
  g.clip();
  const k = still.naturalWidth / W(); // image px per CSS px
  // whole image pixels round the pointer, each one an even square of the disc (the 8× grid stays true at 150 %)
  const n = Math.max(3, Math.round(SIZE / ZOOM) | 1); // odd: the pointer's pixel in the middle
  const cell = SIZE / n;
  const ix = Math.floor(p.x * k) - (n >> 1);
  const iy = Math.floor(p.y * k) - (n >> 1);
  g.imageSmoothingEnabled = false;
  g.drawImage(still, ix, iy, n, n, 0, 0, SIZE, SIZE);
  // the pixel grid: a hairline between the pixels — mid-grey at a third, so it shows on white (a blank page read as an
  // empty tile at 0.22) without hiding the colours
  g.lineWidth = 1 / dpr;
  g.strokeStyle = 'rgb(120 120 120 / 0.34)';
  g.beginPath();
  for (let i = 1; i < n; i++) {
    const v = Math.round(i * cell * dpr) / dpr;
    g.moveTo(v, 0);
    g.lineTo(v, SIZE);
    g.moveTo(0, v);
    g.lineTo(SIZE, v);
  }
  g.stroke();
  // the pixel under the pointer framed, the crosshair through it (the selection's colour, a dark halo under it)
  const c0 = (n >> 1) * cell;
  const c1 = c0 + cell;
  const mid = SIZE / 2;
  const cross = () => {
    g.beginPath();
    g.moveTo(0, mid);
    g.lineTo(c0, mid);
    g.moveTo(c1, mid);
    g.lineTo(SIZE, mid);
    g.moveTo(mid, 0);
    g.lineTo(mid, c0);
    g.moveTo(mid, c1);
    g.lineTo(mid, SIZE);
    g.rect(c0, c0, cell, cell);
  };
  g.lineWidth = 3;
  g.strokeStyle = 'rgb(0 0 0 / 0.28)';
  cross();
  g.stroke();
  g.lineWidth = 1.25;
  g.strokeStyle = getComputedStyle(document.documentElement).getPropertyValue('--selection').trim() || '#1ca288';
  cross();
  g.stroke();
  g.restore();
  // its edge on any page: a 1.5 px white ring inside a 1 px dark hairline
  g.lineWidth = 1.5;
  g.strokeStyle = 'rgb(255 255 255 / 0.95)';
  g.beginPath();
  g.roundRect(0.75, 0.75, SIZE - 1.5, SIZE - 1.5, 9.5);
  g.stroke();
  g.lineWidth = 1;
  g.strokeStyle = 'rgb(0 0 0 / 0.28)';
  g.beginPath();
  g.roundRect(-0.5, -0.5, SIZE + 1, SIZE + 1, 10.5);
  g.stroke();
  // the readout: the selection's size while one is drawn or resized, else the pointer's position
  const sized = !!rect && (mode.k === 'create' || mode.k === 'resize' || (textMode && mode.k !== 'none'));
  const label = sized ? `${phys(rect!.w)} × ${phys(rect!.h)}` : `${phys(p.x)}, ${phys(p.y)}`;
  g.font = `600 11px ${getComputedStyle(document.body).fontFamily}`;
  const tw = Math.ceil(g.measureText(label).width) + 18;
  const ly = SIZE + 6;
  const lh = 22;
  g.save();
  g.shadowColor = 'rgb(0 0 0 / 0.25)';
  g.shadowBlur = 12;
  g.shadowOffsetY = 4;
  g.fillStyle = 'rgb(30 30 32 / 0.9)';
  g.beginPath();
  g.roundRect(SIZE / 2 - tw / 2, ly, tw, lh, lh / 2);
  g.fill();
  g.restore();
  g.strokeStyle = 'rgb(255 255 255 / 0.14)';
  g.lineWidth = 1;
  g.beginPath();
  g.roundRect(SIZE / 2 - tw / 2 + 0.5, ly + 0.5, tw - 1, lh - 1, lh / 2 - 0.5);
  g.stroke();
  g.fillStyle = 'rgb(255 255 255 / 0.92)';
  g.textBaseline = 'middle';
  g.textAlign = 'center';
  g.fillText(label, SIZE / 2, ly + lh / 2 + 0.5);
}

addEventListener(
  'pointermove',
  (e) => {
    pointer = { x: e.clientX, y: e.clientY };
    if (!loupeFrame) loupeFrame = requestAnimationFrame(drawLoupe);
  },
  true,
);

addEventListener('resize', render);
render();

await ready(host, 'picker', () => {
  // ?demo=1 an area chosen · ?demo=hover a window under the pointer
  const demo = params.get('demo');
  if (demo === 'hover') hovered = wins?.[0] ?? { x: innerWidth * 0.2, y: innerHeight * 0.12, w: innerWidth * 0.55, h: innerHeight * 0.6 };
  else rect = { x: innerWidth * 0.2, y: innerHeight * 0.18, w: innerWidth * 0.5, h: innerHeight * 0.5 };
  if (demo === 'drag') {
    drawing = true;
    mode = { k: 'create', x: 0, y: 0 };
  }
  render();
});
