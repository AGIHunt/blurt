// The parts both lists on the Remote Control page are made of (PhonePage.tsx, viewer/ComputersGroup.tsx), so the two
// read as one: a state line led by its status mark, a row's ⋯ (Remove, in red), the "+ Add …" line that ends a box, and the
// line a box shows while it is empty. Row: icon · name over state · at most one button · ⋯ (quiet at rest, its
// place kept), every ⋯ on one right edge. A paired row's name is renamed in place (double-click it, or ⋯ → Rename…): a name
// this computer alone uses (remote-1.1.md §6).
import { useEffect, useRef, useState, type ReactNode } from 'react';
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

/** A name being renamed, after a key: Enter (or a click away) saves, Esc cancels; anything else goes on typing. */
export function nameKey(key: string): 'save' | 'cancel' | null {
  return key === 'Enter' ? 'save' : key === 'Escape' ? 'cancel' : null;
}

/** What a rename sends: null when nothing changed (cancelled, or the same name), else the name trimmed; '' is "its own name again"
 *  (an emptied field restores the name the device gives itself). */
export function renamed(shown: string, typed: string, how: 'save' | 'cancel'): string | null {
  if (how === 'cancel') return null;
  const v = typed.trim();
  return v === shown ? null : v;
}

/** Rename in place: the name selected; Enter saves, Esc cancels, empty goes back to `own` (its placeholder). */
function NameField({ name, own, onDone }: { name: string; own: string; onDone: (v: string | null) => void }) {
  const [v, setV] = useState(name);
  const el = useRef<HTMLInputElement>(null);
  const done = useRef(false);
  useEffect(() => {
    const take = () => {
      if (!el.current || document.activeElement === el.current) return;
      el.current.focus();
      el.current.select();
    };
    take();
    // again once the ⋯ menu has handed the focus back to its button
    const f = requestAnimationFrame(take);
    return () => cancelAnimationFrame(f);
  }, []);
  const finish = (how: 'save' | 'cancel') => {
    if (done.current) return;
    done.current = true;
    onDone(renamed(name, v, how));
  };
  return (
    <input ref={el} className="mw-rename ph-rename" value={v} placeholder={own} maxLength={64} spellCheck={false} autoComplete="off"
      aria-label={t('phone.rename.named', { 1: name })} data-tip={t('mw.rename.keys')} data-testid="device-rename"
      onChange={(e) => setV(e.target.value)}
      onBlur={() => finish('save')}
      onKeyDown={(e) => {
        const how = nameKey(e.key);
        if (!how) return;
        e.preventDefault();
        e.stopPropagation();
        finish(how);
      }} />
  );
}

/** A row's rename: whether its name is a field now, and what saving does. The row's ⋯ offers `entry` (Rename…). */
export interface Rename {
  editing: boolean;
  setEditing: (on: boolean) => void;
  /** the name the device gives itself: an emptied field goes back to it */
  own: string;
  /** the new name, trimmed; '' for its own again */
  save: (name: string) => void;
}

/** The Rename… line of a row's ⋯. */
export const renameEntry = (r: Rename): MenuEntry => ({ label: t('phone.rename'), run: () => r.setEditing(true) });

/** A row: its icon, the name over its state, then its button (if any) and ⋯. With `rename`, a double-click on the name renames it. */
export function DeviceRow({ icon, name, state, children, testid, kind, rename }: { icon: IconName; name: string; state: ReactNode; children?: ReactNode; testid?: string; kind?: string; rename?: Rename }) {
  return (
    <div className="pg-line ph-row" data-testid={testid} data-kind={kind}>
      <span className="pg-line-ic"><Icon name={icon} size={18} /></span>
      <span className="pg-line-text">
        {rename?.editing ? (
          <NameField name={name} own={rename.own} onDone={(v) => {
            rename.setEditing(false);
            if (v != null) rename.save(v);
          }} />
        ) : (
          <span className="pg-line-title" onDoubleClick={rename ? () => rename.setEditing(true) : undefined}>{name}</span>
        )}
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
