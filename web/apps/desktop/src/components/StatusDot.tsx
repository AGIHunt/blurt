// The status mark every list uses (Settings → Agents, the Remote Control page; system.md §1.5, §3.3): each state its own
// shape as well as its colour. good: a filled green disc with a check (connected, working); warn: an amber disc with "!";
// bad: a red disc with "×"; ready: a filled grey disc (available, can connect now); off: a hollow grey ring (offline, last used), as
// the Mac's StatusDot; busy: a spinner (still checking — an empty ring on every row read as radio buttons beside switches).
// The tones are in settings.css `.st-dot`; `small` is the size inside a line of text.
import { Icon } from '@blurt/icons';

export type DotTone = 'good' | 'warn' | 'bad' | 'ready' | 'off' | 'busy';

export function StatusDot({ tone, small }: { tone: DotTone; small?: boolean }) {
  const cls = `st-dot ${tone} ${small ? 'sm' : ''}`;
  if (tone === 'busy') return <span className={cls} aria-hidden><span className="st-spin" /></span>;
  return <span className={cls} aria-hidden>{tone === 'good' ? <Icon name="check" size={9} /> : tone === 'warn' ? '!' : tone === 'bad' ? '×' : null}</span>;
}
