// Note bubble under a fresh shot: type what is wrong, ⏎ saves, Esc skips (voice notes: NoteBubble.swift on macOS;
// here later, with the mic path). Opened with ?n=3&src=<shot url>&text=<existing note>.
import { EV, connect, params, ready, t } from './host';
import { EnterGuard } from './ime';

const host = await connect('note');
const form = document.querySelector<HTMLFormElement>('.bubble')!;
const img = form.querySelector<HTMLImageElement>('.shot')!;
const text = form.querySelector<HTMLTextAreaElement>('textarea')!;
const n = Number(params.get('n') ?? 0);
const guard = new EnterGuard().attach(text);
let done = false;

text.placeholder = t('这张图哪里不对？直接打字', 'What is wrong here? Just type');
form.querySelector('.hint')!.textContent = t('⏎ 保存 · ⇧⏎ 换行 · Esc 跳过', '⏎ save · ⇧⏎ new line · Esc skip');
form.querySelector('[data-a=skip]')!.textContent = t('跳过', 'Skip');
form.querySelector('.primary')!.textContent = t('保存', 'Save');
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
  img.src =
    'data:image/svg+xml,' +
    encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" width="480" height="300"><rect width="480" height="300" fill="#6b8fd6"/><rect x="30" y="30" width="200" height="24" rx="6" fill="#fff" opacity=".8"/><rect x="30" y="80" width="420" height="190" rx="10" fill="#fff" opacity=".45"/></svg>',
    );
  text.value = params.get('text') ?? t('保存按钮太浅了', 'The save button is too faint');
});
