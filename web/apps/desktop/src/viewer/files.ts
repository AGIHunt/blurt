// Files between this computer and the one in the window (docs/design/remote-files.md): what a transfer's row says. The transfers
// themselves are src-tauri viewer.rs's (crates/blurt-remote files.rs), told to the window as `{"type": "transfer"}`.
import { i18n, t } from '../i18n';

export type TransferState = 'waiting' | 'going' | 'paused' | 'done' | 'failed';
export interface Transfer {
  id: string;
  name: string;
  size: number;
  done: number;
  incoming: boolean;
  clip: boolean;
  state: TransferState;
  why?: string | null;
  index?: number | null;
  count?: number | null;
  /** received: where it was saved */
  path?: string | null;
  secondsLeft?: number | null;
}

/** "350 KB", "12.4 MB", "1.6 GB" */
export function size(n: number): string {
  const unit = (v: number, u: string, digits: number) => i18n().formatNumber(v, { style: 'unit', unit: u, maximumFractionDigits: digits });
  if (n >= 1024 ** 3) return unit(n / 1024 ** 3, 'gigabyte', 1);
  if (n >= 1024 ** 2) return unit(n / 1024 ** 2, 'megabyte', 1);
  return unit(Math.max(1, Math.round(n / 1024)), 'kilobyte', 0);
}

/** The row's line under the name, all on one: where it goes or came from and how far, or its state. `route`: the window's path now. */
export function transferLine(x: Transfer, computer: string, route: string | null): string {
  return transferLines(x, computer, route).join(' · ');
}

/** The same in its fixed lines, as the phones show it: a file on its way has two, where (and "2 of 3") then how far and time left, so
 * "2 min left" never lands alone; a state is one. */
export function transferLines(x: Transfer, computer: string, route: string | null): string[] {
  if (x.state === 'going') {
    const [where, ...amount] = lineParts(t(x.incoming ? 'viewer.file.from' : 'viewer.file.to', { 1: computer, 2: size(x.done), 3: size(x.size) }));
    const first = withBatch([where], x);
    if (x.secondsLeft != null) amount.push(t('viewer.file.left', { 1: timeLeft(x.secondsLeft) }));
    return [first.join(' · '), amount.join(' · ')];
  }
  return [stateLine(x, computer, route)];
}

function stateLine(x: Transfer, computer: string, route: string | null): string {
  switch (x.state) {
    case 'waiting':
      // on the public connection service files wait for the direct path, as the status card says
      return t(route === 'goBetween' ? 'viewer.file.connecting' : 'viewer.file.waiting');
    case 'paused':
      return t('viewer.file.paused');
    case 'done':
      return x.incoming ? t('viewer.file.received') : t('viewer.file.saved', { 1: computer });
    case 'failed':
      if (x.why === 'stopped') return t('viewer.file.stopped');
      if (x.incoming) return t(x.why === 'space' ? 'viewer.file.not_received.space' : 'viewer.file.not_received.other');
      return t(`viewer.file.failed.${x.why === 'space' || x.why === 'too_big' || x.why === 'locked' ? x.why : 'other'}`);
    default:
      return '';
  }
}

/** "2 min" above a minute, "40 sec" below: one unit, as a progress line says it (还剩 2 分钟, 还剩 40 秒). */
export function timeLeft(seconds: number): string {
  const s = Math.max(1, Math.ceil(seconds));
  const n = (v: number) => i18n().formatNumber(v);
  return s > 60 ? t('viewer.file.minutes', { 1: n(Math.round(s / 60)) }) : t('viewer.file.seconds', { 1: n(s) });
}

/** The line's pieces between its " · ": each stays whole when the line wraps. */
export const lineParts = (line: string) => line.split(' · ');

/** "2 of 5" after the direction ("To Den PC · 2 of 5 · 3 MB of 12 MB"), for a file in a batch. */
function withBatch(parts: string[], x: Transfer): string[] {
  if (x.count && x.count > 1 && x.index) parts.splice(1, 0, t('viewer.file.batch', { 1: x.index, 2: x.count }));
  return parts;
}

/** The host's bar while a file goes to the device (the Mac's RemoteBanner.transfer): where and how far, its place in a batch after
 * the name ("To Maya’s iPhone · 2 of 5 · 3 MB of 12 MB"), paused, or nothing (null: the bar says who's controlling). */
export function barLine(x: Transfer, device: string): string | null {
  if (x.incoming || x.clip) return null;
  if (x.state === 'paused') return t('viewer.file.paused');
  if (x.state !== 'going' && x.state !== 'waiting') return null;
  return withBatch(lineParts(t('viewer.file.to', { 1: device, 2: size(x.done), 3: size(x.size) })), x).join(' · ');
}

/** × is there while it can still be stopped. */
export const stoppable = (x: Transfer) => x.state === 'waiting' || x.state === 'going' || x.state === 'paused';

/** What getClipboard's "nothing" says, by its reason. */
export const noneLine = (why: string, computer: string) =>
  t(`viewer.none.${why === 'locked' || why === 'too_big' || why === 'too_large' || why === 'unsupported' ? why : 'empty'}`, { 1: computer });
