// The one empty state (docs/design/system.md §3.5), the same as the macOS app's: the brand mark — the app icon, the
// 4A chick on its gradient tile — then a neutral title and a neutral hint, and at most one primary below.
import type { ReactNode } from 'react';
import appIcon from '@blurt/ui/app-icon.png';

export function EmptyState({ title, body, testId, children }: { title: string; body?: string; testId?: string; children?: ReactNode }) {
  return (
    <div className="hero-empty" data-testid={testId}>
      <img className="mark" src={appIcon} width={80} height={80} alt="" aria-hidden="true" />
      <h2>{title}</h2>
      {body && <p>{body}</p>}
      {children && <div className="acts">{children}</div>}
    </div>
  );
}
