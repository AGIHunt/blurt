// The main window's marks, as the Mac draws them — all of them @blurt/icons glyphs now (assets/icons/*.svg, the 24 grid
// and 1.75 stroke of the family; docs/design/windows-parity/icons.md has the SF Symbol each one stands for): the
// sidebar button (sidebar.left / .right), the filter (line.3.horizontal.decrease.circle, outline and filled), In
// Progress' half circle, Unassigned's dashed ring, the current project's scope, a pin, the missing folder's question
// mark, and a project's folder in its own colour (ProjectLook: FNV-1a of the id over the same eight hues, drawn as
// the island's IslandGlyph.project — the family's folder stroked in the colour over a 28 % wash of it).
import { ICONS, Icon } from '@blurt/icons';
import type { CSSProperties } from 'react';

type P = { size?: number; className?: string; title?: string; style?: CSSProperties };

export const SidebarGlyph = ({ size = 16, className, title, style, right }: P & { right?: boolean }) => (
  <Icon name={right ? 'sidebar-right' : 'sidebar'} size={size} className={className} title={title} style={style} />
);

export const FilterGlyph = ({ size = 16, className, title, style, on }: P & { on?: boolean }) => (
  <Icon name={on ? 'filter-fill' : 'filter'} size={size} className={className} title={title} style={style} />
);

export const ProgressGlyph = ({ size = 16, className, title, style }: P) => <Icon name="progress" size={size} className={className} title={title} style={style} />;

export const UnassignedGlyph = ({ size = 16, className, title, style }: P) => <Icon name="unassigned" size={size} className={className} title={title} style={style} />;

export const ScopeGlyph = ({ size = 11, className, title, style }: P) => <Icon name="scope" size={size} className={className} title={title} style={style} />;

export const PinGlyph = ({ size = 14, className, title, style, off }: P & { off?: boolean }) => (
  <Icon name={off ? 'pin-off' : 'pin'} size={size} className={className} title={title} style={style} />
);

export const MissingFolderGlyph = ({ size = 16, className, title, style }: P) => <Icon name="folder-missing" size={size} className={className} title={title} style={style} />;

/** ProjectLook.palette: blue, orange, green, purple, pink, indigo, brown, yellow (the system colours, light / dark). */
const HUES = ['#007aff', '#ff9500', '#34c759', '#af52de', '#ff2d55', '#5856d6', '#a2845e', '#ffcc00'];
export function projectColor(id: string): string {
  if (id === 'inbox') return 'var(--mute)';
  let h = 2166136261;
  for (const b of new TextEncoder().encode(id)) h = Math.imul(h ^ b, 16777619) >>> 0;
  return HUES[h % HUES.length];
}

const FOLDER = ICONS.folder[0][1];
export const ProjectGlyph = ({ id, size = 16, className, title }: P & { id: string }) => (
  <svg
    className={'ico' + (className ? ' ' + className : '')}
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.75}
    strokeLinecap="round"
    strokeLinejoin="round"
    style={{ color: projectColor(id) }}
    role={title ? 'img' : undefined}
    aria-label={title}
    aria-hidden={title ? undefined : true}
  >
    <path d={FOLDER} fill="currentColor" fillOpacity={0.28} />
  </svg>
);
