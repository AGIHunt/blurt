// A recording's chrome that isn't the island (the Mac's Chrome.swift; docs/design/windows-parity/recording.md §3–4).
// Three windows load this page (capture/chrome.rs); the first two are content-protected, never in the video:
//  • mode=countdown — the 3-2-1 before a take (CountdownView): a piece of the island over the area about to be
//    recorded — black, radius 24, the number in a thin ring that drains once over the whole countdown in `rec` (linear,
//    on the number's own clock; still and full with reduced motion), Peep listening beside "Get ready", the keys that
//    pause and finish, and "Start now" as the island's mint chip. A click anywhere on it starts at once (`go`).
//  • mode=frame — the recorded area's frame (BorderView): 4 px outside the area, `rec` solid while it rolls, `attn`
//    dashed while paused (dashes fitted to each side so every corner is the same solid corner), each over a 35 % black
//    under-stroke 0.75 px wider a side so it holds on any content. Click-through (Rust).
//  • mode=ink — the pen while recording (recink.ts): recorded with the area, click-through until the pen is on.
// Rust → page: `blurt://rec` {op: 'countdown', n, total} | {op: 'frame', paused} | {op: 'ink', on}. Page → Rust: blurt://action {action:
// 'go'}, blurt://ready.
import { mascotHtml } from '@blurt/icons/mascot';
import '@blurt/icons/mascot.css';
import '@blurt/icons/peep-s';
import { EV, connect, params, ready, t } from './host';
import { dashedPieces, ringLeft } from './recgeom';
import { startInk } from './recink';

export const REC_EV = 'blurt://rec';

export type RecOp = { op: 'countdown'; n: number; total?: number } | { op: 'frame'; paused: boolean } | { op: 'ink'; on: boolean };

const RING = 92;
const reduceMotion = () => document.documentElement.dataset.reduceMotion === '1';

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
const root = document.querySelector<HTMLElement>('.root')!;
const mode = params.get('mode') === 'frame' ? 'frame' : params.get('mode') === 'ink' ? 'ink' : 'countdown';
document.documentElement.dataset.mode = mode;
const host = await connect('rec');

// ------------------------------------------------------------------ frame
function drawFrame(paused: boolean) {
  const W = innerWidth;
  const H = innerHeight;
  // the window is the area plus 4 px a side: the stroke's centre 2 px out from the area
  const [x0, y0, x1, y1] = [2, 2, W - 2, H - 2];
  const color = paused ? 'var(--attn)' : 'var(--rec)';
  const paths = paused
    ? dashedPieces(x0, y0, x1, y1).map((d) => `<path d="${d}"/>`).join('')
    : `<rect x="${x0}" y="${y0}" width="${x1 - x0}" height="${y1 - y0}" rx="4" ry="4"/>`;
  root.innerHTML = `<svg class="frame${paused ? ' paused' : ''}" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" aria-hidden="true">
    <g class="under">${paths}</g><g class="line" style="stroke:${color}">${paths}</g></svg>`;
}

// ------------------------------------------------------------------ countdown
interface Key {
  /** the key as the user set it ("Alt+Shift+P") */
  key: string;
  /** what it does: pause | finish */
  word: 'pause' | 'finish';
}
let n = Number(params.get('n') ?? 3) || 3;
let total = Number(params.get('total') ?? n) || n;
/** the countdown's own clock: second 0 is when the window opened (record.py's lines only ever move it on, never back —
    they arrive late, the first one about a second after the area was chosen, and the number must not stand still) */
let t0 = performance.now() - (total - n) * 1000;
let fired = false;
const keys: Key[] = (() => {
  try {
    return (JSON.parse(params.get('keys') ?? '[]') as Key[]).filter((k) => k.key);
  } catch {
    return [];
  }
})();

function go() {
  if (fired) return;
  fired = true;
  void host.emit(EV.action, { action: 'go' });
}

function buildCountdown() {
  const C = Math.PI * (RING - 3);
  const hint = keys.length
    ? `<div class="keys">${keys.map((k) => `<span class="pair"><span class="chord">${k.key.split('+').map((c) => `<span class="cap">${esc(c)}</span>`).join('')}</span>${esc(t(`rec.countdown.${k.word}`))}</span>`).join('')}</div>`
    : '';
  root.innerHTML = `<div class="panel" role="group" aria-label="${esc(`${t('rec.countdown.ready')} ${n}`)}">
    <div class="ring"><svg width="${RING}" height="${RING}" viewBox="0 0 ${RING} ${RING}" aria-hidden="true">
      <circle class="track" cx="${RING / 2}" cy="${RING / 2}" r="${RING / 2 - 1.5}"/>
      <circle class="left" cx="${RING / 2}" cy="${RING / 2}" r="${RING / 2 - 1.5}" stroke-dasharray="${C} ${C}"/></svg>
      <span class="num">${n}</span></div>
    <div class="ready">${mascotHtml('listening', { size: 26 })}<span>${esc(t('rec.countdown.ready'))}</span></div>
    ${hint}
    <button class="start" title="${esc(t('rec.countdown.skip'))}">${esc(t('rec.countdown.start_now'))}</button></div>`;
  root.onpointerdown = (e) => (e.preventDefault(), go());
  runClock();
}

function setNumber(k: number) {
  if (k === n) return;
  n = k;
  const el = root.querySelector<HTMLElement>('.num');
  if (!el) return;
  if (!reduceMotion()) {
    el.classList.remove('swap');
    void el.offsetWidth;
    el.classList.add('swap');
  }
  el.textContent = String(k);
  root.querySelector('.panel')?.setAttribute('aria-label', `${t('rec.countdown.ready')} ${k}`);
}

function tick() {
  const ring = root.querySelector<SVGCircleElement>('.left');
  if (!ring) return;
  const C = Math.PI * (RING - 3);
  const held = params.get('hold');
  // the number from the clock (1 at the least: it holds there until the take starts and Rust closes the window)
  const gone = (performance.now() - t0) / 1000;
  if (held == null) setNumber(Math.max(1, total - Math.floor(gone)));
  const p = held != null ? Number(held) : reduceMotion() ? 1 : 1 - (gone - (total - n));
  const left = reduceMotion() && held == null ? 1 : ringLeft(n, total, p);
  ring.setAttribute('stroke-dasharray', `${(left * C).toFixed(2)} ${C.toFixed(2)}`);
}

/** Frames for the ring while they come; a timer for the number either way (WebView2 may hold a window's animation
    frames — the number must still step on the second) */
function runClock() {
  if (params.get('hold') != null) return tick();
  const frame = () => {
    tick();
    if (!reduceMotion()) requestAnimationFrame(frame);
  };
  frame();
  setInterval(tick, 100);
}

// ------------------------------------------------------------------ wiring
if (mode === 'ink') {
  const setOn = startInk(host, root);
  setOn(params.get('on') === '1');
  void host.on<RecOp>(REC_EV, (op) => {
    if (op.op === 'ink') setOn(op.on);
  });
} else if (mode === 'frame') {
  let paused = params.get('paused') === '1';
  drawFrame(paused);
  addEventListener('resize', () => drawFrame(paused));
  void host.on<RecOp>(REC_EV, (op) => {
    if (op.op === 'frame') drawFrame((paused = op.paused));
  });
} else {
  buildCountdown();
  void host.on<RecOp>(REC_EV, (op) => {
    if (op.op !== 'countdown') return;
    if (op.total) total = op.total;
    // record.py ahead of the clock: jump to it; behind: the clock wins (no number ever comes back)
    if (op.n > 0 && op.n < n) {
      t0 = Math.min(t0, performance.now() - (total - op.n) * 1000);
      setNumber(op.n);
    }
  });
}

void ready(host, 'rec', (push) => {
  // ?demo=1: the countdown runs 3-2-1 by itself; the frame turns paused and back every 2 s
  if (mode === 'countdown') {
    let k = n;
    const step = () => (k > 1 ? (push(REC_EV, { op: 'countdown', n: --k, total }), setTimeout(step, 1000)) : undefined);
    setTimeout(step, 1000);
  } else {
    let p = false;
    setInterval(() => push(REC_EV, { op: 'frame', paused: (p = !p) }), 2000);
  }
});
