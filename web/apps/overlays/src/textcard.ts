// ⌥T's translation card (the Mac's ScreenTextCard): the whole translation under the island, to read and to copy again.
// It goes by itself 10 s after it shows — not while the pointer is over it (then 10 s after it leaves); Esc closes it
// only while the pointer is over it (Rust holds Esc then, never otherwise: an Esc meant for the app in front is never
// taken). The window never takes the focus. Params: text, lang. → `blurt://action` textcard.size {h} / .pointer
// {inside} / .copy / .close {why}; ← `blurt://note` {op: 'text', text} (a new translation in its place), {op: 'close'}.
import { iconSvg } from '@blurt/icons/core';
import { EV, connect, params, ready, t } from './host';

const host = await connect('textcard');
const card = document.querySelector<HTMLElement>('.card')!;
const text = document.querySelector<HTMLElement>('.text')!;
const copy = document.querySelector<HTMLButtonElement>('.copy')!;
const SECONDS = 10;
let inside = false;
let timer = 0;
let copiedTimer = 0;
let closed = false;

const send = (action: string, p: Record<string, unknown> = {}) => void host.emit(EV.action, { action, ...p });

function resetButton() {
  copy.textContent = t('capture.text.card.copy');
  copy.classList.remove('done');
}

function set(s: string) {
  // runs of blank lines from the page's layout read as one paragraph break (the Mac card is set tight)
  text.textContent = s.trim().replace(/\n[ \t]*(\n[ \t]*)+/g, '\n');
  text.scrollTop = 0;
  resetButton();
  // a one-line translation is one row: Copy at that line's end (the text keeps room for it); longer: Copy's own row
  card.style.setProperty('--cw', `${copy.offsetWidth + 12}px`);
  card.classList.add('inline');
  if (text.scrollHeight > 22 + 1) card.classList.remove('inline');
  fade();
  send('textcard.size', { h: Math.ceil(card.getBoundingClientRect().height) + 34 });
  later();
}

/** the last line fades while there is more below */
function fade() {
  text.classList.toggle('more', text.scrollHeight - text.scrollTop - text.clientHeight > 1);
}

function later() {
  clearTimeout(timer);
  if (inside) return;
  timer = window.setTimeout(() => close('timeout'), SECONDS * 1000);
}

function close(why: string) {
  if (closed) return;
  closed = true;
  clearTimeout(timer);
  card.classList.add('gone');
  send('textcard.close', { why });
}

text.addEventListener('scroll', fade);
function pointed(on: boolean) {
  if (on === inside) return;
  inside = on;
  card.classList.toggle('hover', on);
  send('textcard.pointer', { inside: on });
  later();
}
card.addEventListener('pointerenter', () => pointed(true));
card.addEventListener('pointerleave', () => pointed(false));
copy.addEventListener('click', () => {
  send('textcard.copy');
  // "Copied" with the ok check for a moment, then Copy again
  copy.innerHTML = `${iconSvg('check', { size: 13, className: 'ic' })}<span>${t('capture.text.card.copied')}</span>`;
  copy.classList.add('done');
  clearTimeout(copiedTimer);
  copiedTimer = window.setTimeout(resetButton, 1600);
});
card.setAttribute('aria-label', t('capture.text.card.ax'));
void host.on<{ op: string; text?: string; x?: number; y?: number }>(EV.note, (op) => {
  // the pointer as Rust sees it (the window gets no pointer events before a click on Windows)
  if (op.op === 'cursor' && op.x !== undefined && op.y !== undefined) {
    const r = card.getBoundingClientRect();
    pointed(op.x >= r.left && op.x < r.right && op.y >= r.top && op.y < r.bottom);
    return;
  }
  if (op.op === 'text' && op.text) {
    closed = false;
    card.classList.remove('gone');
    set(op.text);
  }
  if (op.op === 'close') close('esc');
});
set(params.get('text') ?? '');

await ready(host, 'textcard', () => {
  set(
    params.get('lang') === 'zh-Hans'
      ? '保存按钮的颜色太浅，在白色背景上几乎看不见。\n建议改成主色，并加粗文字。'
      : 'The save button is too light; on a white background it almost disappears.\nMake it the brand colour and set the label in bold.',
  );
});
