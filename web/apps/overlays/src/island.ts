// The island on Windows / Linux (v0.7 contract K7): a floating pill at the top centre of the screen — the same
// component as the macOS notch island, with lighter motion. Collapsed it shows only what is happening (recording
// time, a voice note, the hatching egg while captures are organized); hovering it (or the hotkeys) opens it: the
// current project and the switcher, record / screenshot / voice, the jobs under way, the agent sessions that need
// you, what waits for review. Unfiled captures hang under it as cards, each held by a chicken's claw; drag one onto
// a project to file it.
//
// The window is the full width of the screen and click-through except over what is drawn (we report those rects).
// Rust (apps/desktop/src-tauri/src/island.rs) sends `state` / `cards` / … ops and gets actions back.
import { iconSvg, type IconName } from '@blurt/icons/core';
import { meterBars } from './clock';
import {
  EV,
  connect,
  i18n,
  params,
  plural,
  ready,
  reduceMotion,
  setLang,
  t,
  type Card,
  type CssRect,
  type IslandOp,
  type IslandState,
  type JobRow,
  type ProjectRef,
} from './host';
import { Pendulum, Spring } from './spring';

const host = await connect('island');
const stage = document.querySelector<HTMLElement>('.stage')!;
const deck = document.querySelector<HTMLElement>('.cards')!;
const island = document.querySelector<HTMLElement>('.island')!;
const pill = island.querySelector<HTMLElement>('.pill')!;
const body = island.querySelector<HTMLElement>('.body')!;

// ------------------------------------------------------------------ geometry and timing (K7)
const TOP = 6; // the pill sits this far under the top of the work area
const PILL_H = 30;
const PILL_MIN_W = 120;
const OPEN_W = 480;
const MAX_H = 420;
const CARD_GAP = 14;
const HANG = 18; // card top edge under the island
const SHOT = { w: 112, h: 84 };
const VOICE = { w: 168, h: 44 };
const MAX_CARDS = 7;
const HOVER_IN = 150;
const HOVER_OUT = 400;
const TOAST_MS = 2400;

const ic = (name: IconName, size = 16, cls = '') => iconSvg(name, { size, className: cls ? `ic ${cls}` : 'ic' });
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const num = (n: number) => i18n.formatNumber(n);
const clock = (s: number) => i18n.formatDuration(s, 'clock');
const AGENTS: Record<string, string> = { claude: 'Claude Code', codex: 'Codex', kimi: 'Kimi Code', opencode: 'OpenCode' };

// ------------------------------------------------------------------ state
let S: IslandState = { project: null, projects: [], toReview: 0, recording: null, voice: null, hatching: 0, jobs: [], sessions: [], hotkeys: {} };
let stateAt = performance.now();
let level = 0;
let open = false; // expanded
let drawer: null | 'switch' | 'drop' = null;
let confirmDiscard = false;
let toast: null | { kind: string; n?: number; code?: string; job?: string; type?: string } = null;
let toastTimer = 0;
let peekUntil = 0;
let hovering = false;
let hoverTimer = 0;
let filter = '';
let selIx = 0;
let attention = 0; // performance.now() of the last "needs you"
let bump = 0;

function recElapsed(): number {
  const r = S.recording;
  if (!r) return 0;
  return (r.elapsed ?? 0) + (r.paused ? 0 : (performance.now() - stateAt) / 1000);
}
function voiceElapsed(): number {
  return S.voice ? S.voice.elapsed + (performance.now() - stateAt) / 1000 : 0;
}

const hanging = () => live.filter((l) => l.phase === 'hang' || l.phase === 'fly');
const needsYou = () => S.sessions.filter((s) => s.status === 'waiting_input');

function visible(): boolean {
  return !!(
    S.recording ||
    S.voice ||
    S.hatching ||
    toast ||
    open ||
    drawer ||
    hovering ||
    live.length ||
    needsYou().length ||
    performance.now() < peekUntil
  );
}

// ------------------------------------------------------------------ the pill (collapsed)
function attnDot() {
  return needsYou().length ? `<i class="attn${performance.now() - attention < 1200 ? ' pulse' : ''}" aria-hidden="true"></i>` : '';
}

function pillHtml(): string {
  if (toast) return toastHtml();
  if (S.recording) {
    const r = S.recording;
    return `<span class="ear l"><i class="rec-dot${r.paused ? ' paused' : ''}"></i><span class="time" data-clock="rec">${clock(recElapsed())}</span></span>
      <span class="ear r">${ic('camera', 14)}<span class="num">${num(r.shots)}</span>${attnDot()}</span>`;
  }
  if (S.voice) {
    return `<span class="ear l"><span class="wave" data-wave>${'<i></i>'.repeat(5)}</span></span>
      <span class="ear r"><span class="time" data-clock="voice">${clock(voiceElapsed())}</span></span>`;
  }
  const name = S.project ? esc(S.project.name) : esc(t('project.auto'));
  const right = [
    S.hatching ? `<span class="egg"><span class="wobble">${ic('egg', 15)}</span><span class="num">${num(S.hatching)}</span></span>` : '',
    S.toReview ? `<span class="badge" title="${esc(plural('island.open_inbox', S.toReview))}">${num(S.toReview)}</span>` : '',
    attnDot(),
  ].join('');
  return `<span class="ear l">${ic('folder', 14)}<span class="pname">${name}</span></span><span class="ear r">${right}</span>`;
}

function toastHtml(): string {
  const tt = toast!;
  if (tt.kind === 'sorted') {
    const msg = tt.n ? plural('island.toast.sorted', tt.n) : t('island.toast.sorted_none');
    return `<button class="toast ok" data-a="open.inbox">${ic('hatched', 15)}<span>${esc(msg)}</span></button>`;
  }
  const what = tt.type ? t(`job.type.${tt.type}`) : '';
  const msg = tt.kind === 'failed' ? t('island.toast.failed', { what }) : t(`error.${tt.code ?? 'unknown'}`);
  const reason = tt.kind === 'failed' && tt.code && tt.code !== 'unknown' && i18n.has(`error.${tt.code}`) ? ` · ${t(`error.${tt.code}`)}` : '';
  const acts =
    tt.kind === 'failed' && tt.job
      ? `<button class="mini" data-a="retry" data-job="${esc(tt.job)}">${esc(t('island.toast.retry'))}</button><button class="mini" data-a="log" data-job="${esc(tt.job)}">${esc(t('island.toast.log'))}</button>`
      : '';
  return `<span class="toast bad">${ic('warning', 15)}<span>${esc(msg + reason)}</span>${acts}</span>`;
}

// ------------------------------------------------------------------ the body (expanded)
function toolBtn(a: string, icon: IconName, label: string, key?: string) {
  const tip = key ? `${label}  ${key}` : label;
  return `<button class="tool" data-a="${a}" aria-label="${esc(label)}" data-tip="${esc(tip)}">${ic(icon, 17)}</button>`;
}

function projectChip(small = false) {
  const p = S.project;
  return `<button class="proj${small ? ' small' : ''}" data-a="switch" aria-haspopup="listbox" data-tip="${esc(t('island.switch'))}${S.hotkeys.project ? `  ${esc(S.hotkeys.project)}` : ''}">
    ${ic(p ? 'folder' : 'spark', 15)}<span class="pname">${esc(p ? p.name : t('project.auto'))}</span>${p ? `<span class="key">${esc(p.key)}</span>` : ''}${ic('chevron-down', 13, 'chev')}</button>`;
}

const JOB_ICON: Record<string, IconName> = { process: 'hatching', route: 'git-branch', snap: 'screenshot', voice: 'voice', record: 'record', agent: 'terminal' };

function jobRow(j: JobRow) {
  const title = j.title || t(`job.type.${j.type}`);
  const step = j.step ? t(`job.step.${j.step}`) : '';
  const p = typeof j.progress === 'number' ? Math.max(0.04, Math.min(1, j.progress)) : null;
  return `<div class="row job">
    <span class="lead${j.type === 'process' ? ' wobble' : ''}">${ic(JOB_ICON[j.type] ?? 'process', 15)}</span>
    <span class="txt"><span class="title">${esc(title)}</span><span class="sub">${esc(step)}</span></span>
    <span class="bar${p === null ? ' indet' : ''}"><i style="${p === null ? '' : `width:${(p * 100).toFixed(0)}%`}"></i></span></div>`;
}

function sessionRow(s: IslandState['sessions'][number]) {
  return `<button class="row sess" data-a="open.session" data-job="${esc(s.job)}">
    <i class="sdot s-${esc(s.status)}"></i>
    <span class="txt"><span class="title">${esc(AGENTS[s.agent] ?? s.agent)}<span class="ids">${esc(s.items.join(', '))}</span></span><span class="sub">${esc(t(`session.${s.status}`))}</span></span>
    ${ic('chevron-right', 14, 'chev')}</button>`;
}

function footer() {
  return S.toReview
    ? `<button class="foot" data-a="open.inbox">${ic('inbox', 15)}<span>${esc(plural('island.open_inbox', S.toReview))}</span>${ic('chevron-right', 14, 'chev')}</button>`
    : `<div class="foot quiet">${ic('check', 15)}<span>${esc(t('island.caught_up'))}</span></div>`;
}

function idleBody() {
  const head = `<div class="head">${projectChip()}<span class="grow"></span>
    ${toolBtn('record', 'record', t('island.record'), S.hotkeys.record)}
    ${toolBtn('snap', 'screenshot', t('island.snap'), S.hotkeys.snap)}
    ${toolBtn('voice', 'voice', t('island.voice'), S.hotkeys.voice)}</div>`;
  const jobs = S.jobs.length ? `<div class="sect"><div class="label">${esc(t('island.jobs.title'))}</div>${S.jobs.slice(0, 3).map(jobRow).join('')}</div>` : '';
  const sess = S.sessions.length ? `<div class="sect"><div class="label">${esc(t('island.sessions.title'))}</div>${S.sessions.map(sessionRow).join('')}</div>` : '';
  return head + jobs + sess + footer();
}

function recBody() {
  const r = S.recording!;
  const bars = '<i></i>'.repeat(12);
  if (confirmDiscard) {
    return `<div class="head rec"><i class="rec-dot${r.paused ? ' paused' : ''}"></i><span class="time big" data-clock="rec">${clock(recElapsed())}</span></div>
      <div class="confirm"><span>${esc(t('island.rec.discard.confirm'))}</span><span class="grow"></span>
      <button class="btn" data-a="discard.no">${esc(t('island.rec.discard.no'))}</button><button class="btn danger" data-a="discard.yes">${esc(t('island.rec.discard.yes'))}</button></div>`;
  }
  return `<div class="head rec"><i class="rec-dot${r.paused ? ' paused' : ''}"></i><span class="time big" data-clock="rec">${clock(recElapsed())}</span>
      ${r.paused ? `<span class="tag">${esc(t('island.rec.paused'))}</span>` : ''}<span class="grow"></span>${projectChip(true)}</div>
    <div class="controls">
      ${r.paused ? toolBtn('resume', 'resume', t('island.rec.resume')) : toolBtn('pause', 'pause', t('island.rec.pause'))}
      ${toolBtn('snap', 'screenshot', t('island.rec.snap'))}
      <span class="meter" aria-hidden="true" data-meter>${bars}</span>
      <span class="grow"></span><span class="sub">${esc(plural('island.rec.shots', r.shots))}</span>
      <button class="btn ghost" data-a="discard">${ic('discard', 15)}<span>${esc(t('island.rec.discard'))}</span></button>
      <button class="btn primary" data-a="stop">${ic('stop-fill', 13)}<span>${esc(t('island.rec.finish'))}</span></button>
    </div>`;
}

function voiceBody() {
  return `<div class="head voice"><span class="wave big" data-wave>${'<i></i>'.repeat(9)}</span>
      <span class="txt"><span class="title">${esc(t('island.voice.listening'))}</span><span class="sub">${esc(t('island.voice.hint'))}</span></span>
      <span class="grow"></span><span class="time" data-clock="voice">${clock(voiceElapsed())}</span>
      <button class="btn primary" data-a="voice.stop">${esc(t('island.voice.done'))}</button></div>`;
}

function projectRows(): { rows: ProjectRef[]; more: number } {
  const q = filter.trim().toLowerCase();
  const all = S.projects.filter((p) => !q || p.name.toLowerCase().includes(q) || p.key.toLowerCase().startsWith(q));
  return q ? { rows: all, more: 0 } : { rows: all.slice(0, 8), more: Math.max(0, all.length - 8) };
}

/** Switcher entries in keyboard order: auto (switcher only), projects. */
function choices(): (ProjectRef | null)[] {
  const { rows } = projectRows();
  return drawer === 'switch' && !filter.trim() ? [null, ...rows] : rows;
}

function listHtml(): string {
  const { rows, more } = projectRows();
  const cur = S.project?.id ?? null;
  const items: string[] = [];
  const opts = choices();
  if (drawer === 'switch' && !filter.trim()) {
    items.push(`<button class="row prj${selIx === 0 ? ' sel' : ''}" role="option" data-pid="auto" aria-selected="${cur === null}">
      ${ic('spark', 15)}<span class="txt"><span class="title">${esc(t('project.auto'))}</span><span class="sub">${esc(t('island.auto.hint'))}</span></span>${cur === null ? ic('check', 14, 'tick') : ''}</button>`);
  }
  rows.forEach((p) => {
    const ix = opts.indexOf(p);
    items.push(`<button class="row prj${ix === selIx && drawer === 'switch' ? ' sel' : ''}" role="option" data-pid="${esc(p.id)}" data-drop="project:${esc(p.id)}" aria-selected="${cur === p.id}">
      ${ic('folder', 15)}<span class="title">${esc(p.name)}</span><span class="key">${esc(p.key)}</span>${cur === p.id ? ic('check', 14, 'tick') : ''}</button>`);
  });
  if (more) items.push(`<div class="more">${esc(plural('island.more', more))}</div>`);
  return items.join('');
}

function drawerHtml() {
  if (drawer === 'switch') {
    return `<div class="search">${ic('search', 15)}<input type="text" spellcheck="false" autocomplete="off" placeholder="${esc(t('island.filter'))}" value="${esc(filter)}" aria-label="${esc(t('island.filter'))}"></div>
      <div class="list" role="listbox">${listHtml()}</div>
      <button class="row add" data-a="project.open">${ic('folder-plus', 15)}<span class="title">${esc(t('project.open_folder'))}</span><kbd>Ctrl+O</kbd></button>`;
  }
  return `<div class="label">${esc(t('island.drop.title'))}</div><div class="list">${listHtml()}</div>
    <div class="targets">
      <div class="row target" data-drop="inbox">${ic('inbox', 15)}<span class="txt"><span class="title">${esc(t('project.inbox'))}</span><span class="sub">${esc(t('island.drop.inbox.hint'))}</span></span></div>
      <div class="row target ai" data-drop="ai">${ic('spark', 15)}<span class="txt"><span class="title">${esc(t('project.ai_sort'))}</span><span class="sub">${esc(t('island.drop.ai.hint'))}</span></span></div>
    </div>`;
}

function bodyHtml() {
  if (drawer) return drawerHtml();
  if (S.recording) return recBody();
  if (S.voice) return voiceBody();
  return idleBody();
}

// ------------------------------------------------------------------ render
let lastBody = '';
function render() {
  const shown = visible();
  const expanded = shown && (open || !!drawer);
  island.classList.toggle('shown', shown);
  island.classList.toggle('open', expanded);
  island.dataset.mode = S.recording ? 'rec' : S.voice ? 'voice' : 'idle';
  pill.innerHTML = `<span class="pill-in">${pillHtml()}</span>`;
  const html = expanded ? bodyHtml() : '';
  if (drawer === 'switch' && body.querySelector('.search input') && expanded) {
    body.querySelector('.list')!.innerHTML = listHtml(); // keep the filter field (focus, caret) while typing
  } else if (html !== lastBody) {
    body.innerHTML = html ? `<div class="body-in">${html}</div>` : '';
    lastBody = html;
    if (drawer === 'switch') {
      const input = body.querySelector<HTMLInputElement>('.search input');
      input?.focus();
      input?.addEventListener('input', () => {
        filter = input.value;
        selIx = 0;
        render();
      });
    }
  }
  size(expanded);
  ticks();
  kick();
}

/** The island's box: measured content, animated by CSS (width / height / radius transitions). */
function size(expanded: boolean) {
  const inner = pill.querySelector<HTMLElement>('.pill-in');
  const w = expanded ? OPEN_W : Math.max(PILL_MIN_W, Math.ceil((inner?.scrollWidth ?? 0) + 24));
  const content = body.querySelector<HTMLElement>('.body-in');
  const h = expanded && content ? Math.min(MAX_H, content.offsetHeight + 16) : PILL_H;
  island.style.width = `${w}px`;
  island.style.height = `${h}px`;
  islandH = h;
}

let islandH = PILL_H;
const islandBottom = () => (visible() ? TOP + islandH : TOP + PILL_H);

/** Live numbers (clocks, the voice waveform) without re-rendering. */
function ticks() {
  for (const el of island.querySelectorAll<HTMLElement>('[data-clock]')) el.textContent = clock(el.dataset.clock === 'rec' ? recElapsed() : voiceElapsed());
  for (const m of island.querySelectorAll<HTMLElement>('[data-meter]')) {
    const lit = S.recording?.paused ? 0 : meterBars(level, m.children.length);
    [...m.children].forEach((b, i) => b.classList.toggle('on', i < lit));
  }
  for (const w of island.querySelectorAll<HTMLElement>('[data-wave]')) {
    const bars = [...w.children] as HTMLElement[];
    bars.forEach((b, i) => {
      const k = 0.35 + 0.65 * Math.abs(Math.sin(performance.now() / 160 + i * 1.3));
      b.style.transform = `scaleY(${Math.max(0.18, Math.min(1, level * 9 * k + 0.12)).toFixed(3)})`;
    });
  }
}
setInterval(() => {
  if (S.recording || S.voice) ticks();
}, 250);

// ------------------------------------------------------------------ expand / collapse
island.addEventListener('mouseenter', () => {
  hovering = true;
  clearTimeout(hoverTimer);
  hoverTimer = window.setTimeout(() => {
    open = true;
    render();
  }, HOVER_IN);
});
island.addEventListener('mouseleave', () => {
  hovering = false;
  clearTimeout(hoverTimer);
  hoverTimer = window.setTimeout(() => {
    if (drawer === 'drop' || dragging) return;
    if (drawer === 'switch' && document.activeElement?.closest('.search')) return; // typing a filter
    open = false;
    confirmDiscard = false;
    if (drawer === 'switch') closeSwitcher();
    render();
  }, HOVER_OUT);
});

function openSwitcher() {
  drawer = 'switch';
  filter = '';
  selIx = Math.max(0, choices().findIndex((c) => (c?.id ?? null) === (S.project?.id ?? null)));
  lastBody = '';
  void host.emit(EV.action, { action: 'keyboard', on: true });
  render();
}

function closeSwitcher() {
  if (drawer !== 'switch') return;
  drawer = null;
  filter = '';
  lastBody = '';
  void host.emit(EV.action, { action: 'keyboard', on: false }); // the island goes back to never taking focus
}

function useProject(id: string) {
  void host.emit(EV.action, { action: 'project.use', id });
  S = { ...S, project: id === 'auto' ? null : S.projects.find((p) => p.id === id) ?? S.project };
  closeSwitcher();
  open = false;
  render();
}

addEventListener('keydown', (e) => {
  if (drawer !== 'switch') {
    if (e.key === 'Escape' && S.voice) void host.emit(EV.action, { action: 'voice.cancel' });
    return;
  }
  const opts = choices();
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    selIx = (selIx + (e.key === 'ArrowDown' ? 1 : -1) + opts.length) % Math.max(1, opts.length);
    render();
  } else if (e.key === 'Enter' && !e.isComposing && e.keyCode !== 229) {
    e.preventDefault();
    const c = opts[selIx];
    if (c !== undefined) useProject(c ? c.id : 'auto');
  } else if (e.key === 'Escape') {
    closeSwitcher();
    open = false;
    render();
  } else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'o') {
    e.preventDefault();
    void host.emit(EV.action, { action: 'project.open' });
    closeSwitcher();
    render();
  }
});

island.addEventListener('click', (e) => {
  const el = e.target as HTMLElement;
  const prj = el.closest<HTMLElement>('[data-pid]');
  if (prj && drawer === 'switch') return useProject(prj.dataset.pid!);
  const a = el.closest<HTMLElement>('[data-a]');
  if (!a) {
    if (!open && !drawer) {
      open = true;
      render();
    }
    return;
  }
  const action = a.dataset.a!;
  switch (action) {
    case 'switch':
      return drawer === 'switch' ? (closeSwitcher(), render()) : openSwitcher();
    case 'discard':
      confirmDiscard = true;
      return render();
    case 'discard.no':
      confirmDiscard = false;
      return render();
    case 'discard.yes':
      confirmDiscard = false;
      void host.emit(EV.action, { action: 'discard' });
      return render();
    case 'retry':
    case 'log':
    case 'open.session':
      void host.emit(EV.action, { action, job: a.dataset.job });
      break;
    default:
      void host.emit(EV.action, { action });
  }
  if (['open.inbox', 'open.session', 'record', 'snap', 'voice', 'project.open'].includes(action)) {
    toast = null;
    open = false;
    closeSwitcher();
  }
  render();
});

function showToast(op: Extract<IslandOp, { op: 'toast' }>) {
  if (S.recording && op.kind !== 'error') return; // K4: nothing while recording
  toast = { kind: op.kind, n: op.n, code: op.code, job: op.job, type: op.type };
  clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => {
    toast = null;
    render();
  }, op.kind === 'sorted' ? TOAST_MS : TOAST_MS * 2);
  if (op.kind === 'sorted') hatchPop();
  render();
}

function hatchPop() {
  island.classList.remove('hatch');
  void island.offsetWidth;
  island.classList.add('hatch'); // the egg cracks (0.6 s), the count takes its place
}

function bumpIsland() {
  bump = performance.now();
  island.classList.remove('bump');
  void island.offsetWidth;
  island.classList.add('bump');
}

// ------------------------------------------------------------------ cards held by the claw
type Phase = 'fly' | 'hang' | 'drag' | 'pull' | 'fall';
interface Live {
  card: Card;
  key: string;
  el: HTMLElement;
  leg: HTMLElement;
  face: HTMLElement;
  phase: Phase;
  x: Spring;
  y: Spring; // offset from the hanging position (fly-in starts below)
  lift: Spring;
  reach: Spring; // the claw's reach, 0 (up) … 1 (down at the card)
  swing: Pendulum;
  tilt: number;
  drag?: { ox: number; oy: number; px: number; py: number; moved: boolean };
  fall?: { vy: number; y: number; spin: number; a: number; o: number };
  pullT0?: number;
}

const live: Live[] = [];
let hovered: Live | null = null;
let dragging: Live | null = null;
const keyOf = (c: Card) => `${c.session ?? ''}#${c.n}`;
const dims = (c: Card) => (c.kind === 'voice' || !c.src ? VOICE : SHOT);

const CLAW = `<svg class="foot" viewBox="0 0 34 22" aria-hidden="true"><g fill="none" stroke-linecap="round" stroke-linejoin="round">
  <path class="toe l" d="M17 2 7 16" stroke="#733d0a" stroke-width="5"/><path class="toe r" d="M17 2l10 14" stroke="#733d0a" stroke-width="5"/>
  <path d="M17 2v16" stroke="#733d0a" stroke-width="5"/>
  <path class="toe l" d="M17 2 7 16" stroke="#fab03d" stroke-width="3.2"/><path class="toe r" d="M17 2l10 14" stroke="#fab03d" stroke-width="3.2"/>
  <path d="M17 2v16" stroke="#fab03d" stroke-width="3.2"/></g></svg>`;

function faceHtml(c: Card) {
  if (c.kind === 'voice' || !c.src) {
    return `<div class="face voice">${ic('waveform', 16)}<span class="cap">${esc(c.text || t('island.cards.voice'))}</span></div>`;
  }
  return `<div class="face shot"><img alt="" draggable="false" src="${esc(c.src)}">${c.text ? `<span class="cap">${esc(c.text)}</span>` : ''}</div>`;
}

function makeCard(card: Card, from: 'fly' | 'still'): Live {
  const el = document.createElement('div');
  el.className = 'hang';
  el.style.width = `${dims(card).w}px`;
  el.dataset.kind = card.kind === 'voice' || !card.src ? 'voice' : 'shot';
  el.innerHTML = `<div class="leg"><i class="stem"></i>${CLAW}</div><div class="card">${faceHtml(card)}
    <button class="x" aria-label="${esc(t('island.cards.remove'))}">${ic('x', 11)}</button><span class="flash">${esc(t('island.cards.copied'))}</span></div>`;
  const leg = el.querySelector<HTMLElement>('.leg')!;
  const face = el.querySelector<HTMLElement>('.card')!;
  face.title = card.text ?? '';
  const l: Live = {
    card,
    key: keyOf(card),
    el,
    leg,
    face,
    phase: from === 'fly' ? 'fly' : 'hang',
    x: new Spring(0, 0.5, 0.82),
    y: new Spring(from === 'fly' ? 150 : 0, 0.55, 0.72),
    lift: new Spring(0, 0.28, 0.75),
    reach: new Spring(from === 'fly' ? 0 : 1, 0.35, 1),
    swing: new Pendulum(46, 6), // K7: settles within 1.2 s
    tilt: 0,
  };
  l.y.target = 0;
  l.reach.target = 1;
  face.addEventListener('pointerenter', () => (hovered = l));
  face.addEventListener('pointerleave', () => hovered === l && (hovered = null));
  face.addEventListener('pointerdown', (e) => startDrag(l, e));
  face.addEventListener('dblclick', () => void host.emit(EV.action, { action: 'card.note', n: card.n, session: card.session }));
  face.querySelector('.x')!.addEventListener('click', (e) => {
    e.stopPropagation();
    drop(l, 'fall');
    void host.emit(EV.action, { action: 'card.remove', n: card.n, session: card.session });
  });
  deck.append(el);
  if (from === 'fly' && reduceMotion()) {
    l.y.snap();
    l.reach.snap();
    el.animate?.([{ opacity: 0 }, { opacity: 1 }], { duration: 200 });
  }
  return l;
}

function setCards(cards: Card[]) {
  const keep = new Set(cards.map(keyOf));
  for (const l of [...live]) if (!keep.has(l.key) && (l.phase === 'hang' || l.phase === 'fly')) drop(l, 'gone');
  for (const c of cards) {
    const l = live.find((x) => x.key === keyOf(c) && x.phase !== 'fall' && x.phase !== 'pull');
    if (l) {
      l.card = c;
      l.face.querySelector('.face')!.outerHTML = faceHtml(c);
    } else live.push(makeCard(c, 'still'));
  }
  layoutCards();
}

function addCard(card: Card, pull: boolean) {
  if (live.some((l) => l.key === keyOf(card) && l.phase !== 'fall')) return;
  const l = makeCard(card, 'fly');
  live.push(l);
  if (!reduceMotion()) l.swing.kick((Math.random() < 0.5 ? -1 : 1) * (1.1 + 0.5 * Math.random()));
  layoutCards();
  if (pull) setTimeout(() => drop(l, 'pull'), reduceMotion() ? 200 : 650); // caught, then hauled into the island
  render();
}

/** A card leaves: pulled into the island, falling (removed), or just gone (filed elsewhere). */
function drop(l: Live, how: 'pull' | 'fall' | 'gone') {
  if (l.phase === 'fall' || l.phase === 'pull') return;
  if (hovered === l) hovered = null;
  l.el.classList.add('open'); // the claw lets go
  if (how === 'gone' || reduceMotion()) {
    l.el.animate?.([{ opacity: 1 }, { opacity: 0 }], { duration: 200 }).finished.then(() => remove(l), () => remove(l));
    if (!l.el.animate) remove(l);
    l.phase = 'fall';
    if (how === 'pull') bumpIsland();
    return;
  }
  if (how === 'fall') {
    l.phase = 'fall';
    l.fall = { vy: -60, y: l.y.value + l.lift.value, spin: (Math.random() - 0.5) * 2.4, a: l.swing.angle, o: 1 };
  } else {
    l.phase = 'pull';
    l.pullT0 = performance.now();
  }
  layoutCards();
  kick();
}

function remove(l: Live) {
  l.el.remove();
  const i = live.indexOf(l);
  if (i >= 0) live.splice(i, 1);
  layoutCards();
  render();
}

/** Hanging cards centred under the island, newest last; beyond seven, a "+N" stack. */
function layoutCards() {
  const cards = hanging();
  const shown = cards.slice(-MAX_CARDS);
  const extra = cards.length - shown.length;
  cards.forEach((l) => (l.el.style.display = shown.includes(l) ? '' : 'none'));
  const widths = shown.map((l) => dims(l.card).w);
  const total = widths.reduce((a, b) => a + b, 0) + CARD_GAP * Math.max(0, shown.length - 1);
  const hi = hovered && shown.includes(hovered) ? shown.indexOf(hovered) : -1;
  let x = innerWidth / 2 - total / 2;
  shown.forEach((l, i) => {
    const w = widths[i];
    const room = hi < 0 || i === hi ? 0 : i < hi ? -8 : 8; // neighbours make room
    l.x.target = x + w / 2 + room;
    if (l.phase === 'fly' && l.x.value === 0) l.x.value = l.x.target;
    l.lift.target = i === hi ? -6 : 0;
    l.tilt = (i % 2 ? 1 : -1) * 0.035; // ±2°
    x += w + CARD_GAP;
  });
  stack.hidden = extra <= 0;
  if (extra > 0) {
    stack.textContent = t('island.cards.more', { n: num(extra) });
    stack.style.transform = `translate(${x + 4}px, ${islandBottom() + HANG + 6}px)`;
  }
  sortBtn.hidden = cards.length < 2 || !!dragging;
  if (!sortBtn.hidden) {
    sortBtn.querySelector('span')!.textContent = t('project.ai_sort');
    sortBtn.style.transform = `translate(${x + (extra > 0 ? 70 : 12)}px, ${islandBottom() + HANG + 14}px)`;
  }
}

const stack = document.createElement('div');
stack.className = 'stack';
stack.hidden = true;
const sortBtn = document.createElement('button');
sortBtn.className = 'sort';
sortBtn.innerHTML = `${ic('spark', 14)}<span></span>`;
sortBtn.hidden = true;
sortBtn.addEventListener('click', () => {
  void host.emit(EV.action, { action: 'card.ai_sort' });
  hanging().forEach((l, i) => setTimeout(() => drop(l, 'pull'), i * 70));
});
stage.append(stack, sortBtn);

// --- drag a card onto a drop target
function startDrag(l: Live, e: PointerEvent) {
  if (e.button !== 0 || (e.target as HTMLElement).closest('.x') || l.phase !== 'hang') return;
  const r = l.face.getBoundingClientRect();
  l.drag = { ox: e.clientX - r.left, oy: e.clientY - r.top, px: e.clientX, py: e.clientY, moved: false };
  l.face.setPointerCapture(e.pointerId);
  const move = (ev: PointerEvent) => {
    const d = l.drag!;
    if (!d.moved && Math.hypot(ev.clientX - d.px, ev.clientY - d.py) < 4) return;
    if (!d.moved) {
      d.moved = true;
      dragging = l;
      l.phase = 'drag';
      l.el.classList.add('open', 'dragging'); // the claw opens and pulls back up
      drawer = 'drop';
      open = true;
      lastBody = '';
      render();
    }
    d.px = ev.clientX;
    d.py = ev.clientY;
    highlight(ev.clientX, ev.clientY);
    kick();
  };
  const up = (ev: PointerEvent) => {
    l.face.removeEventListener('pointermove', move);
    l.face.removeEventListener('pointerup', up);
    l.face.removeEventListener('pointercancel', up);
    const d = l.drag;
    l.drag = undefined;
    if (!d?.moved) {
      // a click: copy (the screenshot, or a voice note's words)
      l.face.classList.remove('copied');
      void l.face.offsetWidth;
      l.face.classList.add('copied');
      void host.emit(EV.action, { action: 'card.copy', n: l.card.n, session: l.card.session });
      return;
    }
    const target = targetAt(ev.clientX, ev.clientY);
    dragging = null;
    drawer = null;
    open = false;
    lastBody = '';
    if (target) {
      const c = l.card;
      if (target === 'ai') void host.emit(EV.action, { action: 'card.ai_sort' });
      else if (target === 'inbox') void host.emit(EV.action, { action: 'card.inbox', n: c.n, session: c.session });
      else void host.emit(EV.action, { action: 'card.assign', n: c.n, session: c.session, project: target.slice('project:'.length) });
      l.phase = 'hang';
      drop(l, 'pull');
    } else {
      // missed: back to the claw
      l.phase = 'hang';
      l.el.classList.remove('open', 'dragging');
      const r = l.face.getBoundingClientRect();
      l.y.value = r.top - (islandBottom() + HANG);
      l.x.value = r.left + r.width / 2;
      l.reach.value = 0.4;
    }
    l.el.classList.remove('dragging');
    render();
  };
  l.face.addEventListener('pointermove', move);
  l.face.addEventListener('pointerup', up);
  l.face.addEventListener('pointercancel', up);
}

function targetAt(x: number, y: number): string | null {
  const el = document.elementsFromPoint(x, y).find((e) => (e as HTMLElement).dataset?.drop) as HTMLElement | undefined;
  return el?.dataset.drop ?? null;
}

function highlight(x: number, y: number) {
  const hit = targetAt(x, y);
  for (const el of island.querySelectorAll<HTMLElement>('[data-drop]')) el.classList.toggle('over', el.dataset.drop === hit);
}

// --- the frame loop (runs only while something moves)
let raf = 0;
let last = 0;
let settleUntil = 0;
function kick() {
  settleUntil = performance.now() + 450; // CSS transitions of the island box
  if (!raf) {
    last = performance.now();
    raf = requestAnimationFrame(frame);
    setTimeout(() => raf && frame(performance.now()), 50); // rAF stalls in hidden webviews: a timer still settles it
  }
}

function frame(now: number) {
  raf = 0;
  const dt = Math.min(0.05, Math.max(0, (now - last) / 1000));
  last = now;
  let moving = now < settleUntil;
  const base = islandBottom() + HANG;
  for (const l of [...live]) {
    const { w, h } = dims(l.card);
    if (l.phase === 'fall' && l.fall) {
      const f = l.fall;
      f.vy += 2400 * dt;
      f.y += f.vy * dt;
      f.a += f.spin * dt;
      f.o -= 2 * dt;
      l.el.style.transform = `translate(${(l.x.value - w / 2).toFixed(1)}px, 0)`;
      l.face.style.transform = `translate(0, ${(base + f.y).toFixed(1)}px) rotate(${f.a.toFixed(3)}rad)`;
      l.face.style.opacity = String(Math.max(0, f.o));
      l.reach.target = 0;
      l.leg.style.transform = `scaleY(${Math.max(0, l.reach.step(dt)).toFixed(3)})`;
      if (f.o <= 0 || f.y > innerHeight) remove(l);
      else moving = true;
      continue;
    }
    if (l.phase === 'pull' && l.pullT0 !== undefined) {
      const k = Math.min(1, (now - l.pullT0) / 450);
      const e = k * k * k; // ease-in
      const cx = innerWidth / 2;
      const cy = TOP + PILL_H / 2;
      const x0 = l.x.value;
      const y0 = base + l.y.value;
      const x = x0 + (cx - x0) * e;
      const y = y0 + (cy - h / 2 - y0) * e;
      l.el.style.transform = `translate(${(x - w / 2).toFixed(1)}px, 0)`;
      l.face.style.transform = `translate(0, ${y.toFixed(1)}px) scale(${(1 - 0.8 * e).toFixed(3)})`;
      l.face.style.opacity = String(1 - 0.6 * e);
      l.leg.style.height = `${Math.max(0, y).toFixed(1)}px`;
      if (k >= 1) {
        remove(l);
        bumpIsland();
      } else moving = true;
      continue;
    }
    if (l.phase === 'drag' && l.drag) {
      const d = l.drag;
      l.el.style.transform = `translate(${(d.px - d.ox).toFixed(1)}px, 0)`;
      l.face.style.transform = `translate(0, ${(d.py - d.oy).toFixed(1)}px) rotate(${(-0.03).toFixed(3)}rad) scale(1.04)`;
      l.reach.target = 0;
      l.leg.style.transform = `scaleY(${l.reach.step(dt).toFixed(3)})`;
      moving = true;
      continue;
    }
    const x = l.x.step(dt);
    const y = base + l.y.step(dt) + l.lift.step(dt);
    const reach = l.reach.step(dt);
    if (l.phase === 'fly' && Math.abs(l.y.value) < 2) l.phase = 'hang';
    const a = reduceMotion() ? 0 : l.swing.step(dt, hovered === l) + l.tilt;
    l.el.style.transform = `translate(${(x - w / 2).toFixed(1)}px, 0) rotate(${a.toFixed(4)}rad)`;
    l.face.style.transform = `translate(0, ${y.toFixed(1)}px)`;
    l.face.style.opacity = '1';
    l.leg.style.height = `${(y + 8).toFixed(1)}px`;
    l.leg.style.transform = `scaleY(${reach.toFixed(3)})`;
    l.el.classList.toggle('open', reach < 0.94);
    if (!(l.x.resting && l.y.resting && l.lift.resting && l.reach.resting && (reduceMotion() || l.swing.resting))) moving = true;
  }
  if (now - bump < 300) moving = true;
  reportHits();
  if (moving) kick();
}

// --- breeze: now and then a small gust passes along the cards
function breeze() {
  if (!reduceMotion() && !dragging) hanging().forEach((l, i) => setTimeout(() => (l.swing.kick((Math.random() - 0.3) * 0.4), kick()), i * 90));
  setTimeout(breeze, 10000 + Math.random() * 8000);
}
setTimeout(breeze, 10000);

// --- click-through: where we draw (the whole window while a card is being dragged)
let lastHits = '';
function reportHits(force = false) {
  const rects: CssRect[] = [];
  const add = (el: Element) => {
    const b = el.getBoundingClientRect();
    if (b.width && b.height) rects.push({ x: Math.floor(b.left), y: Math.floor(b.top), w: Math.ceil(b.width), h: Math.ceil(b.height) });
  };
  if (dragging) rects.push({ x: 0, y: 0, w: innerWidth, h: innerHeight });
  else {
    if (island.classList.contains('shown')) add(island);
    for (const l of live) if (l.phase === 'hang' || l.phase === 'fly') add(l.face);
    if (!sortBtn.hidden) add(sortBtn);
  }
  const s = JSON.stringify(rects);
  if (s !== lastHits || force) {
    lastHits = s;
    void host.emit(EV.hitRects, { rects });
  }
}

// ------------------------------------------------------------------ ops from the app
function apply(op: IslandOp) {
  switch (op.op) {
    case 'state':
      if (op.state.lang) setLang(op.state.lang);
      if (!S.recording && op.state.recording) confirmDiscard = false;
      S = op.state;
      stateAt = performance.now();
      if (op.state.expanded) open = true;
      if (drawer === 'switch') selIx = Math.min(selIx, Math.max(0, choices().length - 1));
      lastBody = '';
      break;
    case 'cards':
      setCards(op.cards);
      break;
    case 'card':
      addCard(op.card, op.pull);
      return;
    case 'toast':
      return showToast(op);
    case 'switcher':
      if (op.open) openSwitcher();
      else closeSwitcher();
      break;
    case 'peek':
      peekUntil = performance.now() + 3000;
      setTimeout(render, 3050);
      break;
    case 'attention':
      if (op.status === 'waiting_input') attention = performance.now();
      setTimeout(render, 1300);
      break;
    case 'status':
      if (op.line.ev === 'level') level = op.line.rms;
      return ticks();
    case 'level':
      level = op.rms;
      return ticks();
  }
  render();
}

await host.on<IslandOp>(EV.island, apply);
render();
reportHits(true);
// scripted smoke runs read what the island shows (apps/desktop: BLURT_TEST_EVAL)
(window as unknown as { __island: () => unknown }).__island = () => ({
  open: island.classList.contains('open'),
  shown: island.classList.contains('shown'),
  drawer,
  recording: S.recording,
  hatching: S.hatching,
  toReview: S.toReview,
  project: S.project?.name ?? null,
  cards: live.filter((l) => l.phase === 'hang' || l.phase === 'fly').map((l) => ({ n: l.card.n, kind: l.card.kind, text: l.card.text })),
  pill: pill.innerText,
  toast,
});

await ready(host, 'island', (push) => {
  // ?demo=1 idle, expanded · ?demo=rec recording · ?demo=voice · ?demo=drop a card being filed · ?demo=switch
  const demo = params.get('demo') ?? '1';
  const shot = (n: number, hue: number, text: string | null): Card => ({
    n,
    text,
    kind: 'shot',
    session: '/demo/inbox/sessions/20261022-101500-shots',
    src:
      'data:image/svg+xml,' +
      encodeURIComponent(
        `<svg xmlns="http://www.w3.org/2000/svg" width="224" height="168"><rect width="224" height="168" fill="hsl(${hue} 45% 60%)"/><rect x="16" y="16" width="110" height="12" rx="4" fill="#fff" opacity=".85"/><rect x="16" y="40" width="192" height="110" rx="8" fill="#fff" opacity=".42"/></svg>`,
      ),
  });
  const zh = i18n.lang === 'zh-Hans';
  const projects = [
    { id: 'p1', name: 'bug-agent', key: 'BA' },
    { id: 'p2', name: 'airank', key: 'AIR' },
    { id: 'p3', name: zh ? '官网改版' : 'website-refresh', key: 'WR' },
  ];
  const base: IslandState = {
    project: demo === 'auto' || demo === 'drop' ? null : projects[0],
    projects,
    toReview: 5,
    recording: null,
    voice: null,
    hatching: demo === '1' ? 1 : 0,
    jobs: demo === '1' ? [{ id: 'j1', type: 'process', title: zh ? '价格页走查' : 'Pricing page walkthrough', step: 'write', progress: 0.62 }] : [],
    sessions: demo === '1' ? [{ job: 'j2', agent: 'claude', status: 'waiting_input', items: ['BA-12', 'BA-13'] }] : [],
    hotkeys: { record: 'Alt+Shift+R', snap: 'Alt+Shift+A', voice: 'Alt+Shift+V', project: 'Alt+Shift+O' },
    expanded: ['1', 'rec', 'voice', 'auto'].includes(demo),
  };
  if (demo === 'rec') base.recording = { elapsed: 74, paused: false, shots: 2, at: Date.now() / 1000 };
  if (demo === 'voice') base.voice = { elapsed: 3, at: Date.now() / 1000 };
  push(EV.island, { op: 'state', state: base });
  if (demo === 'rec' || demo === 'voice') {
    let k = 0;
    setInterval(() => push(EV.island, { op: 'level', rms: 0.02 + 0.08 * Math.abs(Math.sin(k++ / 3)) }), 100);
  }
  if (['auto', 'drop', 'cards'].includes(demo)) {
    push(EV.island, {
      op: 'cards',
      cards: [shot(1, 210, zh ? '保存按钮太浅' : 'Save button too faint'), { n: 2, src: '', kind: 'voice', text: zh ? '搜索框放到顶部' : 'Move search to the top', session: '/demo/inbox/sessions/20261022-101500-shots' }],
    });
    setTimeout(() => push(EV.island, { op: 'card', card: shot(3, 140, null), pull: false }), params.has('still') ? 0 : 500);
  }
  if (demo === 'drop') {
    drawer = 'drop';
    open = true;
    lastBody = '';
    render();
    setTimeout(() => island.querySelector('[data-drop="project:p2"]')?.classList.add('over'), 900);
  }
  if (demo === 'switch') setTimeout(openSwitcher, 50);
  if (demo === 'toast') setTimeout(() => push(EV.island, { op: 'toast', kind: 'sorted', n: 5, job: 'j1' }), 300);
});
