// The one empty state (docs/design/system.md §3.5), the same as the macOS app's (EmptyStateView / BrandMarkView): the
// brand mark — Peep alone, idling (a breath and a blink), no tile — then a neutral title and a neutral hint, and at
// most one primary below. Three looks, one layout (the Mac's tones): friendly (the mark; its first button the view's
// one primary, ↩), miss (a quiet symbol — a search or a filter that matched nothing; its buttons only undo that, so
// they're plain), trouble (a quiet symbol — a scan that failed, a folder that's gone). A path is one line, cut in the
// middle, the whole path its tooltip; `busy` puts the spinner where the buttons go.
import type { ReactNode } from 'react';
import { Mascot } from '@blurt/icons';

export function EmptyState({ title, body, testId, children, tone = 'friendly', icon, path, busy }: {
  title: string;
  body?: string;
  testId?: string;
  children?: ReactNode;
  tone?: 'friendly' | 'miss' | 'trouble';
  /** the quiet symbol of a miss or a trouble */
  icon?: ReactNode;
  path?: string;
  busy?: boolean;
}) {
  return (
    <div className={`hero-empty tone-${tone}`} data-testid={testId} role="group" aria-label={[title, body, path].filter(Boolean).join('. ')}>
      {tone === 'friendly' ? <Mascot clip={busy ? 'thinking' : 'idle'} size={80} className="mark" /> : icon && <span className="hero-empty-ic">{icon}</span>}
      <h2>{title}</h2>
      {body && <p>{body}</p>}
      {path && <p className="hero-empty-path" title={path}>{path}</p>}
      {busy && <span className="mw-spinner" aria-hidden="true" />}
      {children && <div className="acts">{children}</div>}
    </div>
  );
}
