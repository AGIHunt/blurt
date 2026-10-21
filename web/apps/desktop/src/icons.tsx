// No emoji as icons (user rule). Everything in the UI goes through <Icon name="…"> — the blurt icon family
// (@blurt/icons, generated from assets/icons/*.svg). The names below are this app's words for them.
import type { CSSProperties } from 'react';
import { Icon as BlurtIcon, resolveIcon, type IconName as BlurtIconName } from '@blurt/icons';

const MAP = {
  record: 'record-fill',
  snap: 'snap',
  inbox: 'inbox',
  items: 'list',
  sessions: 'film',
  agent: 'agent',
  folder: 'folder',
  home: 'home',
  settings: 'settings',
  issue: 'bug',
  idea: 'spark',
  note: 'note',
  task: 'task',
  egg: 'egg',
  chick: 'hatched',
  chicken: 'chicken',
  check: 'check',
  x: 'x',
  search: 'search',
  prev: 'chevron-left',
  next: 'chevron-right',
  back: 'arrow-left',
  up: 'chevron-up',
  down: 'chevron-down',
  fixing: 'wand',
  fixed: 'peck',
  stop: 'stop',
  dot: 'record-fill',
} as const satisfies Record<string, BlurtIconName>;

export type IconName = keyof typeof MAP | BlurtIconName;

export function Icon({ name, size = 16, className, style, title }: { name: IconName | string; size?: number; className?: string; style?: CSSProperties; title?: string }) {
  const n = (MAP as Record<string, BlurtIconName>)[name] ?? resolveIcon(name) ?? 'record-fill';
  return <BlurtIcon name={n} size={size} className={`icon icon-${name}${className ? ` ${className}` : ''}`} style={style} title={title} />;
}

export const KIND_ICON: Record<string, IconName> = { issue: 'issue', idea: 'idea', note: 'note', task: 'task' };
export function KindIcon({ kind, size = 16 }: { kind: string; size?: number }) {
  return <Icon name={KIND_ICON[kind] ?? 'note'} size={size} className={`kind-${kind}`} title={kind} />;
}
