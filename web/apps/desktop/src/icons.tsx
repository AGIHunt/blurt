// No emoji as icons (user rule). Everything in the UI goes through <Icon name="…">; when the shared package
// web/packages/icons (generated from assets/icons/*.svg) merges, this file becomes:
//   export { Icon } from '@blurt/icons';  export type { IconName } from '@blurt/icons';
// Until then: a small local set of 24×24 stroke icons with the same call shape.

import type { CSSProperties } from 'react';

const P: Record<string, string> = {
  record: 'M12 7a5 5 0 1 0 0 10a5 5 0 1 0 0-10z',
  snap: 'M4 8h3l2-3h6l2 3h3v11H4z M12 10.5a3 3 0 1 0 0 6a3 3 0 1 0 0-6z',
  inbox: 'M3 13l3-8h12l3 8v6H3z M3 13h5l1 3h6l1-3h5',
  items: 'M8 6h13 M8 12h13 M8 18h13 M3.5 6h.01 M3.5 12h.01 M3.5 18h.01',
  sessions: 'M3 5h18v14H3z M3 9h18 M7 5v4 M12 5v4 M17 5v4',
  agent: 'M5 8h14v11H5z M12 4v4 M9 13h.01 M15 13h.01 M9 16h6 M2 12v3 M22 12v3',
  folder: 'M3 6h6l2 2h10v11H3z',
  home: 'M3 11l9-7l9 7 M5 10v10h14V10 M10 20v-6h4v6',
  settings:
    'M12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6z M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3a1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5a1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8a1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1a1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5a1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z',
  issue: 'M8 9a4 4 0 0 1 8 0v6a4 4 0 0 1-8 0z M12 9v10 M8 12H4 M20 12h-4 M8 16l-3 2 M16 16l3 2 M8 9L5 7 M16 9l3-2 M10 5L9 3 M14 5l1-2',
  idea: 'M9 18h6 M10 21h4 M12 3a6 6 0 0 0-4 10.5c.7.7 1 1.5 1 2.5h6c0-1 .3-1.8 1-2.5A6 6 0 0 0 12 3z',
  note: 'M5 3h10l4 4v14H5z M15 3v4h4 M8 12h8 M8 16h6',
  task: 'M4 4h16v16H4z M8 12l3 3l5-6',
  egg: 'M12 3c3.5 0 6.5 5.5 6.5 10a6.5 6.5 0 0 1-13 0C5.5 8.5 8.5 3 12 3z',
  chick: 'M12 3c3.5 0 6.5 5.5 6.5 10a6.5 6.5 0 0 1-13 0C5.5 8.5 8.5 3 12 3z M6 12l2.5-2l2 2l2-2l2 2l2.5-2l1.5 2',
  chicken: 'M7 20h10 M9 20v-3 M15 20v-3 M6 13a6 6 0 0 0 12 0V9a4 4 0 0 0-7-2.6L9 9H6z M14 9h.01 M18 9l3 1l-3 1 M12 4l1-2l1 2',
  check: 'M5 12l5 5L20 7',
  x: 'M6 6l12 12 M18 6L6 18',
  search: 'M11 4a7 7 0 1 0 0 14a7 7 0 1 0 0-14z M21 21l-5-5',
  prev: 'M15 6l-6 6l6 6',
  next: 'M9 6l6 6l-6 6',
  back: 'M19 12H5 M11 6l-6 6l6 6',
  fixing: 'M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18v3h3l6.3-6.3a4 4 0 0 0 5.4-5.4l-2.5 2.5l-2.4-.6l-.6-2.4z',
  stop: 'M7 7h10v10H7z',
  dot: 'M12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6z',
};

export type IconName = keyof typeof P;

export function Icon({ name, size = 16, className, style, title }: { name: IconName | string; size?: number; className?: string; style?: CSSProperties; title?: string }) {
  const d = P[name] ?? P.dot;
  const filled = name === 'record' || name === 'dot';
  return (
    <svg className={`icon icon-${name}${className ? ` ${className}` : ''}`} width={size} height={size} viewBox="0 0 24 24" style={style}
      fill={filled ? 'currentColor' : 'none'} stroke="currentColor" strokeWidth={1.7} strokeLinecap="round" strokeLinejoin="round"
      role={title ? 'img' : undefined} aria-hidden={title ? undefined : true} aria-label={title}>
      {title && <title>{title}</title>}
      {d.split(' M').map((seg, i) => <path key={i} d={i ? `M${seg}` : seg} />)}
    </svg>
  );
}

export const KIND_ICON: Record<string, IconName> = { issue: 'issue', idea: 'idea', note: 'note', task: 'task' };
export function KindIcon({ kind, size = 16 }: { kind: string; size?: number }) {
  return <Icon name={KIND_ICON[kind] ?? 'note'} size={size} className={`kind-${kind}`} title={kind} />;
}
