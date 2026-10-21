// Region picker: a transparent window over one monitor. Drag = area, click = whole screen, drag inside the area
// = move it; Enter / ✓ starts, Esc / ✕ cancels. Emits {rect} in this window's CSS px; Rust maps it to the desktop.
import { clampRect, contains, isClick, moveRect, parseRect, rectFrom, sizeLabel, toolbarPos } from './geom';
import { EV, connect, params, ready, t, type CssRect } from './host';

const host = await connect('picker');
const sel = document.querySelector<HTMLElement>('.sel')!;
const size = sel.querySelector<HTMLElement>('.size')!;
const bar = document.querySelector<HTMLElement>('.bar')!;
const hint = document.querySelector<HTMLElement>('.hint')!;
const last = parseRect(params.get('last'));
const btn = (a: string) => bar.querySelector<HTMLElement>(`[data-a=${a}]`)!;

const purpose = params.get('purpose') === 'screenshot' ? 'screenshot' : 'record';
hint.textContent = t(`picker.hint.${purpose}`);
btn('ok').innerHTML = `<span></span><kbd>↩</kbd>`;
btn('ok').querySelector('span')!.textContent = t(`picker.ok.${purpose}`);
btn('cancel').textContent = t('picker.cancel');
btn('full').textContent = t('picker.full');
btn('last').textContent = t('picker.last');
btn('last').hidden = !last;

const bounds = () => ({ w: innerWidth, h: innerHeight });
let rect: CssRect | null = null;
let drag: { kind: 'new' | 'move'; x: number; y: number; start: CssRect | null } | null = null;
let done = false;

function render() {
  document.body.classList.toggle('has-sel', !!rect);
  sel.hidden = !rect;
  bar.hidden = !rect || !!drag;
  if (!rect) return;
  Object.assign(sel.style, { left: `${rect.x}px`, top: `${rect.y}px`, width: `${rect.w}px`, height: `${rect.h}px` });
  size.textContent = sizeLabel(rect, devicePixelRatio);
  size.style.top = rect.y < 30 ? '6px' : '-26px';
  size.style.left = rect.y < 30 ? '6px' : '0';
  if (!bar.hidden) {
    const p = toolbarPos(rect, { w: bar.offsetWidth, h: bar.offsetHeight }, bounds());
    Object.assign(bar.style, { left: `${p.x}px`, top: `${p.y}px` });
  }
}

function finish(r: CssRect | null) {
  if (done) return;
  done = true;
  void host.emit(EV.picked, { rect: r });
  if (host.host === 'browser') document.body.dataset.picked = JSON.stringify(r);
}

addEventListener('pointerdown', (e) => {
  if (e.button !== 0 || (e.target as HTMLElement).closest('.bar')) return;
  const inside = rect && contains(rect, e.clientX, e.clientY);
  drag = { kind: inside ? 'move' : 'new', x: e.clientX, y: e.clientY, start: rect };
  (e.target as HTMLElement).setPointerCapture?.(e.pointerId);
  render();
});
addEventListener('pointermove', (e) => {
  if (!drag) return;
  rect =
    drag.kind === 'move' && drag.start
      ? moveRect(drag.start, e.clientX - drag.x, e.clientY - drag.y, bounds())
      : clampRect(rectFrom(drag, { x: e.clientX, y: e.clientY }), bounds());
  render();
});
addEventListener('pointerup', (e) => {
  if (!drag) return;
  const d = drag;
  drag = null;
  if (d.kind === 'new') {
    const r = rectFrom(d, { x: e.clientX, y: e.clientY });
    if (isClick(r)) {
      rect = { x: 0, y: 0, ...bounds() }; // a click: the whole screen, confirmed right away
      render();
      return finish(rect);
    }
  }
  render();
});
addEventListener('keydown', (e) => {
  if (e.key === 'Escape') finish(null);
  if (e.key === 'Enter' && rect && !e.isComposing) finish(rect);
});
bar.addEventListener('click', (e) => {
  const a = (e.target as HTMLElement).closest<HTMLElement>('[data-a]')?.dataset.a;
  if (a === 'ok') finish(rect);
  if (a === 'cancel') finish(null);
  if (a === 'full') finish({ x: 0, y: 0, ...bounds() });
  if (a === 'last' && last) {
    rect = clampRect(last, bounds());
    render();
  }
});
addEventListener('resize', render);
render();

await ready(host, 'picker', () => {
  // ?demo=1 — an area already chosen (screenshots)
  rect = { x: innerWidth * 0.2, y: innerHeight * 0.18, w: innerWidth * 0.5, h: innerHeight * 0.5 };
  render();
});
