// The card under the island (the Mac's ScreenTextCard): ⌥C's text or ⌥T's translation, whole, to read and to copy
// again — only when it went nowhere but the clipboard (flow.rs, paste_policy::screen_text::shows_card). × on the left
// closes it now, Copy on the right. It goes by itself 10 s after it shows — not while the pointer is over it (then 10 s after it leaves); Esc closes it
// only while the pointer is over it (Rust holds Esc then, never otherwise: an Esc meant for the app in front is never
// taken). The window never takes the focus. Params: text, lang. → `blurt://action` textcard.size {h} / .pointer
// {inside} / .copy / .close {why: esc | close_button | timeout}; ← `blurt://note` {op: 'text', text} (a new text in its
// place), {op: 'close'}.
import { iconSvg } from '@blurt/icons/core';
import { EV, connect, params, ready, t } from './host';

const host = await connect('textcard');
const card = document.querySelector<HTMLElement>('.card')!;
const text = document.querySelector<HTMLElement>('.text')!;
const copy = document.querySelector<HTMLButtonElement>('.copy')!;
const closeButton = document.querySelector<HTMLButtonElement>('.close')!;
const row = document.querySelector<HTMLElement>('.row')!;
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
  // a one-line text is one row: × and Copy at that line's end (the text keeps room for them); longer: their own row,
  // × on the left, Copy on the right
  card.style.setProperty('--cw', `${row.offsetWidth + 12}px`);
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
closeButton.innerHTML = iconSvg('x', { size: 14 });
closeButton.title = t('capture.text.card.close');
closeButton.setAttribute('aria-label', t('capture.text.card.close'));
closeButton.addEventListener('click', () => close('close_button'));
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
