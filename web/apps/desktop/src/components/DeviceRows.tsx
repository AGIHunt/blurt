// The parts both lists on the Remote Control page are made of (PhonePage.tsx, viewer/ComputersGroup.tsx), so the two
// read as one: a state line led by its status mark, a row's ⋯ (Remove, in red), the "+ Add …" line that ends a box, and the
// line a box shows while it is empty. Row: icon · name over state · at most one button · ⋯ (quiet at rest, its
// place kept), every ⋯ on one right edge.
import { useState, type ReactNode } from 'react';
import { Icon, type IconName } from '@blurt/icons';
import { Menu, type MenuAt, type MenuEntry } from './Menu';
import { StatusDot } from './StatusDot';
import { t } from '../i18n';

/** good: connected; warn: something in the way; ready: can connect now; off: offline, last used (StatusDot.tsx). */
export type Tone = 'good' | 'warn' | 'ready' | 'off';

/** The state under a name, its words first: the mark in a fixed column so every row's words start at the same place, then
 *  the state, then what else there is to say (the system, the path). Only the state words take the warning colour. */
export function StateLine({ tone, state, rest, tip, testid, data }: { tone: Tone; state: string; rest?: string; tip?: string; testid?: string; data?: string }) {
  return (
    <span className="pg-line-detail ph-state" data-testid={testid} data-state={data} title={tip}>
      <StatusDot tone={tone} small />
      <span>
        <span className={tone === 'warn' ? 'ph-warn' : undefined}>{state}</span>
        {rest && ` · ${rest}`}
      </span>
    </span>
  );
}

/** ⋯ at a row's end: what is done to the row rather than with it, in a menu. */
export function RowMore({ name, entries, testid }: { name: string; entries: MenuEntry[]; testid?: string }) {
  const [at, setAt] = useState<MenuAt | null>(null);
  return (
    <>
      <button className="icon-btn ph-more" aria-label={t('st.agents.more.named', { 1: name })} aria-haspopup="menu" aria-expanded={!!at} data-testid={testid}
        onClick={(e) => setAt(at ? null : { x: 0, y: 0, anchor: e.currentTarget, align: 'end' })}>
        <Icon name="more" size={15} />
      </button>
      {at && <Menu at={at} label={name} onClose={() => setAt(null)} entries={entries} />}
    </>
  );
}

/** A row: its icon, the name over its state, then its button (if any) and ⋯. */
export function DeviceRow({ icon, name, state, children, testid, kind }: { icon: IconName; name: string; state: ReactNode; children?: ReactNode; testid?: string; kind?: string }) {
  return (
    <div className="pg-line ph-row" data-testid={testid} data-kind={kind}>
      <span className="pg-line-ic"><Icon name={icon} size={18} /></span>
      <span className="pg-line-text">
        <span className="pg-line-title">{name}</span>
        {state}
      </span>
      {children}
    </div>
  );
}

/** The line that ends a box: "+ Add Device…" — the whole line is the button. */
export function AddLine({ label, onClick, disabled, title, testid }: { label: string; onClick: () => void; disabled?: boolean; title?: string; testid?: string }) {
  return (
    <button type="button" className="pg-line ph-add" onClick={onClick} disabled={disabled} title={title} data-testid={testid}>
      <span className="pg-line-ic"><Icon name="plus" size={16} /></span>
      <span className="pg-line-text">{label}</span>
    </button>
  );
}

/** A box with nothing in it yet: what it is for, and its one button beside it. */
export function EmptyLine({ icon, title, detail, children }: { icon: IconName; title: string; detail: ReactNode; children: ReactNode }) {
  return (
    <div className="pg-line ph-row ph-empty">
      <span className="pg-line-ic"><Icon name={icon} size={18} /></span>
      <span className="pg-line-text">
        <span className="pg-line-title">{title}</span>
        <span className="pg-line-detail">{detail}</span>
      </span>
      {children}
    </div>
  );
}
