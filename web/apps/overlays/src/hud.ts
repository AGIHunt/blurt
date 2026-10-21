// The recording HUD: timer, mic meter, pause / snap / finish / discard. State comes only from C8 status lines.
import { HudModel, fmtTime, meterBars } from './clock';
import { EV, connect, params, ready, t, type StatusLine } from './host';

const host = await connect('hud');
const el = document.querySelector<HTMLElement>('.hud')!;
const time = el.querySelector<HTMLElement>('.time')!;
const bars = [...el.querySelectorAll<HTMLElement>('.meter i')];
const count = el.querySelector<HTMLElement>('.count')!;
const msg = el.querySelector<HTMLElement>('.msg')!;
const discardBtn = el.querySelector<HTMLElement>('[data-a=discard]')!;
const snapBtn = el.querySelector<HTMLElement>('[data-a=snap]')!;
const model = new HudModel();

el.querySelector('.stop .lbl')!.textContent = t('完成', 'Done');
el.querySelector('[data-a=pause]')!.setAttribute('title', t('暂停 / 继续', 'Pause / resume'));
snapBtn.title = t('截图（不停录）', 'Snap a still (keeps recording)');
discardBtn.title = t('放弃这段', 'Discard this take');
if (params.get('mic') === '0') el.classList.add('no-mic');

function render() {
  el.dataset.state = model.state;
  time.textContent = fmtTime(model.elapsed(performance.now()));
  const lit = meterBars(model.level);
  bars.forEach((b, i) => b.classList.toggle('on', i < lit));
  count.textContent = model.shots ? String(model.shots) : '';
  msg.textContent =
    model.state === 'starting'
      ? t('正在开始…', 'Starting…')
      : model.state === 'saving'
        ? t('正在保存…', 'Saving…')
        : model.state === 'done'
          ? t('已保存', 'Saved')
          : (model.error ?? '');
  if (model.state === 'error') msg.title = model.error ?? '';
}

let armed = 0;
el.addEventListener('click', (e) => {
  const b = (e.target as HTMLElement).closest<HTMLElement>('[data-a]');
  if (!b) return;
  let action = b.dataset.a!;
  if (action === 'pause' && model.state === 'paused') action = 'resume';
  if (action === 'discard') {
    if (!armed) {  // two clicks: a take is never lost to a stray click
      discardBtn.classList.add('armed');
      discardBtn.title = t('再点一次放弃', 'Click again to discard');
      armed = window.setTimeout(() => {
        armed = 0;
        discardBtn.classList.remove('armed');
        discardBtn.title = t('放弃这段', 'Discard this take');
      }, 2500);
      return;
    }
    clearTimeout(armed);
  }
  if (action === 'stop') model.stopping();
  if (action === 'snap') {
    snapBtn.classList.add('flash');
    setTimeout(() => snapBtn.classList.remove('flash'), 180);
  }
  void host.emit(EV.action, { action });
  render();
});

await host.on<StatusLine>(EV.status, (line) => {
  if (line.ev === 'level' && params.get('mic') !== '0') el.classList.remove('no-mic');
  model.apply(line, performance.now());
  render();
});

setInterval(render, 250);
render();

await ready(host, 'hud', (push) => {
  // ?demo=1 — recording for a while, a mic, two snaps (browser preview / CI screenshot)
  push(EV.status, { ev: 'started', t0: Date.now() / 1000 });
  let k = 0;
  setInterval(() => push(EV.status, { ev: 'level', rms: 0.02 + 0.1 * Math.abs(Math.sin(k++ / 3)) }), 100);
  push(EV.status, { ev: 'snap', n: 2, file: 'shots/002.png' });
  if (params.get('demo') === 'paused') push(EV.status, { ev: 'paused', t: 83 });
});
