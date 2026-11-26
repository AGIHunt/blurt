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

/** The row's line under the name: where it goes or came from and how far, or its state. `route`: the window's path now. */
export function transferLine(x: Transfer, computer: string, route: string | null): string {
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
    case 'going': {
      const amount = t(x.incoming ? 'viewer.file.from' : 'viewer.file.to', { 1: computer, 2: size(x.done), 3: size(x.size) });
      const batch = x.count && x.count > 1 && x.index ? `${t('viewer.file.batch', { 1: x.index, 2: x.count })} · ` : '';
      const left = x.secondsLeft != null ? ` · ${t('viewer.file.left', { 1: i18n().formatDuration(Math.max(1, Math.ceil(x.secondsLeft)), 'short') })}` : '';
      return batch + amount + left;
    }
  }
}

/** × is there while it can still be stopped. */
export const stoppable = (x: Transfer) => x.state === 'waiting' || x.state === 'going' || x.state === 'paused';

/** What getClipboard's "nothing" says, by its reason. */
export const noneLine = (why: string, computer: string) =>
  t(`viewer.none.${why === 'locked' || why === 'too_big' || why === 'unsupported' ? why : 'empty'}`, { 1: computer });
