// The pen while recording (the Mac's InkView; docs/design/windows-parity/recording.md §4.6): rec.html?mode=ink, a
// window exactly over the recorded area that the recording sees (not content-protected: the ink is meant to be in the
// video). Click-through until the pen is on (Rust); then a drag draws — plain freehand, Shift a box, Alt an ellipse
// (the snap pen's keys, notecore InkStroke / inkFit: resting at the end of a freehand stroke snaps it to a clean
// shape) — and a ring follows the pointer. Ink fades 3 s after the last stroke, so a circle and the arrow drawn right
// after it share a frame. Each stroke goes to Rust → events.jsonl ("stroke": its shape, ≤ 120 points 0–1 of the area).
import { InkStroke, inkWidth, snapTool, type Pt } from './notecore';
import { strokePoints } from './recgeom';
import { EV, type OverlayHost } from './host';

/** Seconds the ink stays after the last stroke (InkView.visible). */
export const INK_VISIBLE = 3;

export function startInk(host: OverlayHost, root: HTMLElement) {
  const canvas = document.createElement('canvas');
  const halo = document.createElement('div');
  halo.className = 'halo';
  halo.hidden = true;
  root.append(canvas, halo);
  const ctx = canvas.getContext('2d')!;
  const markup = getComputedStyle(document.documentElement).getPropertyValue('--markup').trim() || '#ff5c3d';
  const lw = inkWidth(Math.min(screen.width, screen.height));
  const now = () => performance.now() / 1000;
  let on = false;
  let stroke: InkStroke | null = null;
  let began = 0;
  let restTimer = 0;
  let fadeTimer = 0;
  let done: Pt[][] = [];
  let alpha = 1;

  function size() {
    const dpr = devicePixelRatio || 1;
    canvas.width = Math.round(innerWidth * dpr);
    canvas.height = Math.round(innerHeight * dpr);
    draw();
  }
  function path(pts: Pt[]) {
    const p = new Path2D();
    if (pts.length === 1) {
      p.arc(pts[0].x, pts[0].y, 18, 0, Math.PI * 2); // a tap rings the spot
      return p;
    }
    p.moveTo(pts[0].x, pts[0].y);
    for (let i = 1; i < pts.length - 1; i++) p.quadraticCurveTo(pts[i].x, pts[i].y, (pts[i].x + pts[i + 1].x) / 2, (pts[i].y + pts[i + 1].y) / 2);
    p.lineTo(pts[pts.length - 1].x, pts[pts.length - 1].y);
    return p;
  }
  function draw() {
    const dpr = devicePixelRatio || 1;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, innerWidth, innerHeight);
    Object.assign(ctx, { lineWidth: lw, lineCap: 'round', lineJoin: 'round', strokeStyle: markup, shadowColor: 'rgba(0,0,0,0.45)', shadowBlur: Math.max(1.2, lw * 0.4) * 2, shadowOffsetY: 1 });
    ctx.globalAlpha = alpha;
    for (const s of done) ctx.stroke(path(s));
    ctx.globalAlpha = 1;
    if (stroke) ctx.stroke(path(stroke.display));
  }
  function fadeOut() {
    const t0 = performance.now();
    const step = () => {
      if (stroke) return; // a new stroke began: the old ink stays with it
      alpha = Math.max(0, 1 - (performance.now() - t0) / 500);
      if (alpha > 0) {
        draw();
        requestAnimationFrame(step);
      } else {
        done = [];
        alpha = 1;
        draw();
      }
    };
    requestAnimationFrame(step);
  }
  const at = (e: PointerEvent): Pt => ({ x: e.clientX, y: e.clientY });
  const moveHalo = (p: Pt) => (halo.style.transform = `translate(${p.x - 9}px, ${p.y - 9}px)`);

  addEventListener('resize', size);
  addEventListener('pointermove', (e) => {
    if (!on) return;
    moveHalo(at(e));
    halo.hidden = false; // the ring only where the pointer really is (never parked at the window's corner)
    if (stroke && stroke.move(at(e), snapTool(e.shiftKey, e.altKey), now())) draw();
  });
  addEventListener('pointerdown', (e) => {
    if (!on || e.button !== 0) return;
    e.preventDefault();
    clearTimeout(fadeTimer);
    alpha = 1;
    stroke = new InkStroke(at(e), snapTool(e.shiftKey, e.altKey), now());
    began = now();
    canvas.setPointerCapture?.(e.pointerId);
    clearInterval(restTimer);
    restTimer = window.setInterval(() => stroke?.checkRest(now()) && draw(), 50);
  });
  addEventListener('pointerup', () => {
    clearInterval(restTimer);
    if (!stroke) return;
    const s = stroke;
    stroke = null;
    const kept = s.kept(3);
    done.push(kept);
    draw();
    void host.emit(EV.action, { action: 'stroke', stroke: { shape: s.kind, points: strokePoints(kept, innerWidth, innerHeight, !!s.shape), dur: Math.round((now() - began) * 1000) / 1000 } });
    fadeTimer = window.setTimeout(fadeOut, INK_VISIBLE * 1000);
  });

  size();
  return (o: boolean) => {
    on = o;
    // a fully transparent window lets clicks fall through: a whisper of fill makes it take them (InkView.setOn)
    document.documentElement.classList.toggle('pen-on', on);
    if (!on) halo.hidden = true;
    if (!on && stroke) {
      stroke = null;
      draw();
    }
  };
}
