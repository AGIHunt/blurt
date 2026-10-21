// The perch (鸡舍): a wooden rod at the top of the screen; every shot hangs from it like a polaroid held by a
// chicken-foot clip (Perch.swift on macOS). Cards land with a damped pendulum swing, hovering lifts a card and its
// neighbours make room, × drops it with gravity, a breeze now and then; reduce motion = fades.
// The window is click-through except over what is drawn: the page reports those rects (EV.hitRects).
import { EV, connect, params, ready, reduceMotion, t, type Card, type CssRect, type PerchOp } from './host';
import { Pendulum, Spring } from './spring';
import { iconSvg } from '@blurt/icons/core';

const host = await connect('perch');
const root = document.querySelector<HTMLElement>('.perch')!;
const deck = root.querySelector<HTMLElement>('.cards')!;
const end = root.querySelector<HTMLElement>('.end')!;
const nest = end.querySelector<HTMLElement>('.nest')!;
const processBtn = end.querySelector<HTMLElement>('[data-a=process]')!;
const clearBtn = end.querySelector<HTMLElement>('[data-a=clear]')!;
clearBtn.textContent = t('清空', 'Clear');
processBtn.innerHTML = iconSvg('chicken', { size: 16 }) + '<span></span>'; // 整理 = the chicken, never an emoji
const processLabel = processBtn.querySelector('span')!;

const CARD_W = 132;
const GAP = 14;
const LEFT = 30;
const FOOT = `<svg class="leg" viewBox="0 0 34 30" aria-hidden="true">
  <path d="M17 0v15" stroke="#733d0a" stroke-width="5.5" stroke-linecap="round"/>
  <path d="M17 0v15" stroke="#fab03d" stroke-width="3.5" stroke-linecap="round"/>
  <g stroke-linecap="round" stroke-linejoin="round" fill="none">
    <path d="M17 14 7 25M17 15v13M17 14l10 11" stroke="#733d0a" stroke-width="5"/>
    <path d="M17 14 7 25M17 15v13M17 14l10 11" stroke="#fab03d" stroke-width="3.2"/>
    <path d="M17 13v3" stroke="#cc7819" stroke-width="3.2"/>
  </g></svg>`;

interface Live {
  card: Card;
  el: HTMLElement;
  x: Spring;
  drop: Spring;
  lift: Spring;
  swing: Pendulum;
  falling?: { vy: number; y: number; spin: number; a: number; o: number };
}

const live: Live[] = [];
const reveal = new Spring(-1, 0.42, 0.82); // 0 = shown, -1 = tucked away (fraction of the window height)
let hovered: Live | null = null;
let overPerch = false;
let hideAt = 0;
let busy = false;

function cap(c: Card) {
  return c.text ?? '';
}

function makeCard(card: Card): Live {
  const el = document.createElement('div');
  el.className = 'card';
  el.innerHTML = `${FOOT}<div class="photo"><img alt="" draggable="false"><div class="cap"></div></div><button class="x" title="${t('移除', 'Remove')}">${iconSvg('x', { size: 12 })}</button>`;
  el.querySelector('img')!.src = card.src;
  const capEl = el.querySelector<HTMLElement>('.cap')!;
  capEl.textContent = cap(card);
  capEl.dataset.n = `#${card.n}`;
  el.title = card.text ?? '';
  const l: Live = { card, el, x: new Spring(0, 0.5, 0.8), drop: new Spring(-160, 0.42, 0.72), lift: new Spring(0, 0.28, 0.72), swing: new Pendulum() };
  el.addEventListener('mouseenter', () => (hovered = l));
  el.addEventListener('mouseleave', () => hovered === l && (hovered = null));
  el.addEventListener('click', (e) => {
    if ((e.target as HTMLElement).closest('.x')) return remove(card.n, true);
    el.classList.add('copied');
    setTimeout(() => el.classList.remove('copied'), 600);
    void host.emit(EV.action, { action: 'copy', n: card.n });
  });
  el.addEventListener('dblclick', () => void host.emit(EV.action, { action: 'note', n: card.n }));
  deck.append(el);
  return l;
}

function layout() {
  const hanging = live.filter((l) => !l.falling);
  // as many as fit left of the end controls; the newest stay
  const room = innerWidth - LEFT - (end.hidden ? 24 : end.offsetWidth + 40);
  const fit = Math.max(1, Math.floor((room + GAP) / (CARD_W + GAP)));
  const visible = hanging.slice(-fit);
  hanging.forEach((l) => (l.el.style.display = visible.includes(l) ? '' : 'none'));
  const hi = hovered && !hovered.falling ? visible.indexOf(hovered) : -1;
  visible.forEach((l, i) => {
    const room = hi < 0 || i === hi ? 0 : i < hi ? -10 : 10; // neighbours make room
    l.x.target = LEFT + i * (CARD_W + GAP) + room;
    l.lift.target = i === hi ? -8 : 0;
  });
  const n = hanging.length;
  processBtn.hidden = n === 0 || busy;
  clearBtn.hidden = n === 0 || busy;
  processLabel.textContent = t(`整理 ${n} 张`, `Sort ${n} shot${n === 1 ? '' : 's'}`);
  nest.hidden = !busy;
  end.hidden = processBtn.hidden && clearBtn.hidden && nest.hidden;
}

function add(card: Card, animate = true) {
  if (live.some((l) => l.card.n === card.n && !l.falling)) {
    const l = live.find((x) => x.card.n === card.n)!;
    l.card = card;
    l.el.querySelector<HTMLElement>('.cap')!.textContent = cap(card);
    return;
  }
  const l = makeCard(card);
  live.push(l);
  layout();
  l.x.value = l.x.target;
  l.drop.target = 0;
  if (!animate || reduceMotion()) {
    l.drop.snap();
    if (animate) l.el.animate?.([{ opacity: 0 }, { opacity: 1 }], { duration: 200 });
  } else {
    l.swing.kick((Math.random() < 0.5 ? -1 : 1) * (2.2 + Math.random()));
  }
}

function remove(n: number, byUser = false) {
  const l = live.find((x) => x.card.n === n && !x.falling);
  if (!l) return;
  if (byUser) void host.emit(EV.action, { action: 'remove', n });
  if (reduceMotion()) {
    l.el.remove();
    live.splice(live.indexOf(l), 1);
  } else {
    l.falling = { vy: -120, y: l.drop.value + l.lift.value, spin: (Math.random() - 0.5) * 3, a: l.swing.angle, o: 1 };
  }
  if (hovered === l) hovered = null;
  layout();
}

function show(hold = 3000) {
  reveal.target = 0;
  hideAt = hold > 0 ? performance.now() + hold : Infinity;
  kick();
}

function hide() {
  hideAt = 0;
  reveal.target = -1;
  kick();
}

function apply(op: PerchOp) {
  switch (op.op) {
    case 'set':
      for (const l of live) l.el.remove();
      live.length = 0;
      op.cards.forEach((c) => add(c, false));
      break;
    case 'add':
      add(op.card);
      show(3000);
      break;
    case 'remove':
      remove(op.n);
      break;
    case 'show':
      show(op.hold ?? 3000);
      break;
    case 'hide':
      hide();
      break;
    case 'busy':
      busy = op.on;
      nest.querySelector('span')!.textContent = op.label ?? t('孵化中…', 'Hatching…');
      if (busy) show(0);
      break;
  }
  layout();
  kick();
}

// --- frame loop (runs only while something moves)
let raf = 0;
let last = 0;
function kick() {
  if (!raf) {
    last = performance.now();
    raf = requestAnimationFrame(frame);
    // rAF stalls in hidden / headless webviews: fall back to a timer so state still settles
    setTimeout(() => {
      if (raf) {
        cancelAnimationFrame(raf);
        frame(performance.now());
      }
    }, 60);
  }
}

function frame(now: number) {
  const dt = Math.min(0.05, (now - last) / 1000);
  last = now;
  raf = 0;
  if (hideAt && now > hideAt && !overPerch && !busy) hide();
  layout();
  const H = innerHeight;
  if (reduceMotion()) reveal.snap();
  const r = reveal.step(dt);
  root.style.transform = `translateY(${(r * H).toFixed(1)}px)`;
  root.style.opacity = reduceMotion() ? (reveal.target === 0 ? '1' : '0') : '1';
  let moving = !reveal.resting || (hideAt > 0 && hideAt !== Infinity);
  for (const l of [...live]) {
    if (l.falling) {
      const f = l.falling;
      f.vy += 2400 * dt;
      f.y += f.vy * dt;
      f.a += f.spin * dt;
      f.o -= 1.6 * dt;
      l.el.style.transform = `translate(${l.x.value}px, ${f.y}px) rotate(${f.a}rad)`;
      l.el.style.opacity = String(Math.max(0, f.o));
      if (f.y > H + 40 || f.o <= 0) {
        l.el.remove();
        live.splice(live.indexOf(l), 1);
      } else moving = true;
      continue;
    }
    const x = l.x.step(dt);
    const y = l.drop.step(dt) + l.lift.step(dt);
    const a = reduceMotion() ? 0 : l.swing.step(dt, hovered === l);
    l.el.style.transform = `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px) rotate(${a.toFixed(4)}rad)`;
    if (!(l.x.resting && l.drop.resting && l.lift.resting && l.swing.resting)) moving = true;
  }
  reportHits();
  if (moving) kick();
}

// --- breeze: every 9–16 s a small gust passes along the rod
function breeze() {
  if (!reduceMotion() && reveal.target === 0) {
    live.forEach((l, i) => setTimeout(() => (l.swing.kick((Math.random() - 0.3) * 0.5), kick()), i * 90));
  }
  setTimeout(breeze, 9000 + Math.random() * 7000);
}
setTimeout(breeze, 9000);

// --- click-through: tell Rust where we draw (only while shown)
let lastHits = '';
let lastSent = 0;
function reportHits(force = false) {
  const now = performance.now();
  if (!force && now - lastSent < 100) return;
  const rects: CssRect[] = [];
  if (reveal.value > -0.95) {
    const add = (el: Element) => {
      const b = el.getBoundingClientRect();
      if (b.width && b.height) rects.push({ x: Math.round(b.left), y: Math.round(b.top), w: Math.round(b.width), h: Math.round(b.height) });
    };
    add(root.querySelector('.rod')!);
    live.forEach((l) => !l.falling && add(l.el));
    if (!end.hidden) add(end);
  }
  const s = JSON.stringify(rects);
  if (s !== lastHits || force) {
    lastHits = s;
    lastSent = now;
    void host.emit(EV.hitRects, { rects });
  }
}

root.addEventListener('mouseenter', () => (overPerch = true));
root.addEventListener('mouseleave', () => {
  overPerch = false;
  if (hideAt !== Infinity && reveal.target === 0) hideAt = Math.min(hideAt || Infinity, performance.now() + 400);
  kick();
});
end.addEventListener('click', (e) => {
  const a = (e.target as HTMLElement).closest<HTMLElement>('[data-a]')?.dataset.a;
  if (a) void host.emit(EV.action, { action: a });
});

await host.on<PerchOp>(EV.perch, apply);
layout();
kick();

await ready(host, 'perch', (push) => {
  // ?demo=1 — three shots hanging, the perch shown (browser preview / CI screenshot)
  const shot = (n: number, hue: number, text: string | null): Card => ({
    n,
    text,
    src:
      'data:image/svg+xml,' +
      encodeURIComponent(
        `<svg xmlns="http://www.w3.org/2000/svg" width="240" height="156"><rect width="240" height="156" fill="hsl(${hue} 55% 62%)"/><rect x="18" y="18" width="120" height="14" rx="4" fill="#fff" opacity=".8"/><rect x="18" y="44" width="200" height="90" rx="6" fill="#fff" opacity=".45"/></svg>`,
      ),
  });
  push(EV.perch, { op: 'set', cards: [shot(1, 210, t('保存按钮太浅', 'Save button too faint')), shot(2, 25, null)] });
  push(EV.perch, { op: 'show', hold: 0 });
  setTimeout(() => push(EV.perch, { op: 'add', card: shot(3, 140, t('这里加个搜索', 'Add search here')) }), params.get('demo') === 'still' ? 0 : 600);
  if (params.get('demo') === 'busy') push(EV.perch, { op: 'busy', on: true });
});
reportHits(true);
