// Note bubble under a fresh capture: type what it is about, ↩ saves, Esc skips. Opened with ?n=3&src=<shot url>&text=
// <existing note> (no src: a voice note's card, just the words).
import { EV, connect, params, ready, t } from './host';
import { EnterGuard } from './ime';

const host = await connect('note');
const form = document.querySelector<HTMLFormElement>('.bubble')!;
const img = form.querySelector<HTMLImageElement>('.shot')!;
const text = form.querySelector<HTMLTextAreaElement>('textarea')!;
const n = Number(params.get('n') ?? 0);
const guard = new EnterGuard().attach(text);
let done = false;

text.placeholder = t('note.placeholder');
form.querySelector('.hint')!.textContent = t('note.hint');
form.querySelector('[data-a=skip]')!.textContent = t('note.skip');
form.querySelector('.primary')!.textContent = t('note.save');
if (!params.get('src')) form.classList.add('no-shot'); // a voice note's card: just the words
if (params.get('src')) img.src = params.get('src')!;
text.value = params.get('text') ?? '';

function finish(value: string | null) {
  if (done) return;
  done = true;
  void host.emit(EV.noteDone, { n, text: value === null ? null : value.trim() || null });
  if (host.host === 'browser') document.body.dataset.done = JSON.stringify(value);
}

text.addEventListener('keydown', (e) => {
  if (guard.isSubmit(e)) {
    e.preventDefault();
    finish(text.value);
  }
});
addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !e.isComposing) finish(null);
});
form.addEventListener('submit', (e) => {
  e.preventDefault();
  finish(text.value);
});
form.querySelector('[data-a=skip]')!.addEventListener('click', () => finish(null));
text.focus();

await ready(host, 'note', () => {
  form.classList.remove('no-shot');
  img.src =
    'data:image/svg+xml,' +
    encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" width="480" height="300"><rect width="480" height="300" fill="#6b8fd6"/><rect x="30" y="30" width="200" height="24" rx="6" fill="#fff" opacity=".8"/><rect x="30" y="80" width="420" height="190" rx="10" fill="#fff" opacity=".45"/></svg>',
    );
  text.value = params.get('text') ?? t('note.demo');
});
