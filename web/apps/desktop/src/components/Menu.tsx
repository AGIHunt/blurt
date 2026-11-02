// A menu the way the Mac's NSMenu draws one, for the window's context menus, the heading's Sort / Filter menus, the ⋯
// menu and the selection's ⋯: an image column, the title, a hint line where one is asked for, the key at the trailing
// edge, a check for the current choice, section headers, separators and submenus. It opens at a point (a right-click)
// or under an element (a button), stays on screen, and is keyboard-first: ↑ / ↓ move, ↩ or Space picks, → opens a
// submenu, ← / Esc close it; a click outside closes. The focus goes back where it was.
import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { Icon } from '@blurt/icons';

export type MenuEntry =
  | {
      kind?: 'item';
      label: string;
      icon?: ReactNode;
      keys?: string;
      hint?: string;
      /** a second line under the label, always shown (a pop-up's choice: what it means) */
      note?: string;
      checked?: boolean | 'mixed';
      disabled?: boolean;
      /** the reason it's off (its tooltip) */
      tip?: string;
      danger?: boolean;
      /** a line that states rather than acts (the state menu's current state): normal ink, not pickable */
      current?: boolean;
      badge?: string;
      submenu?: MenuEntry[];
      run?: () => void;
      testId?: string;
    }
  | { kind: 'separator' }
  | { kind: 'header'; label: string };
/** a pickable row of a menu */
export type MenuItem = Exclude<MenuEntry, { kind: 'separator' } | { kind: 'header' }>;

export interface MenuAt {
  x: number;
  y: number;
  /** the element it hangs from (its bottom-left), when it opened from a button */
  anchor?: HTMLElement | null;
  /** line up with the anchor's leading edge whatever side it is on, or ('end') its trailing edge: a pop-up button's
   *  menu hangs from the button's right edge and grows leftward, so it never crosses the content column's edge */
  align?: 'start' | 'end';
  /** at least this wide (a pop-up button's menu is never narrower than the button) */
  minWidth?: number;
}

/** Separators only between groups: none first, last or twice. */
export function tidy(entries: (MenuEntry | false | null | undefined)[]): MenuEntry[] {
  const out: MenuEntry[] = [];
  for (const e of entries) {
    if (!e) continue;
    if (e.kind === 'separator' && (!out.length || out[out.length - 1].kind === 'separator')) continue;
    out.push(e);
  }
  while (out.length && out[out.length - 1].kind === 'separator') out.pop();
  return out;
}

const pickable = (e: MenuEntry) => (e.kind ?? 'item') === 'item' && !(e as { disabled?: boolean }).disabled && !(e as { current?: boolean }).current;

export function Menu({ entries, at, onClose, label, sub }: { entries: MenuEntry[]; at: MenuAt; onClose: () => void; label?: string; sub?: boolean }) {
  const el = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);
  const [ix, setIx] = useState(-1);
  const [open, setOpen] = useState<{ index: number; at: MenuAt } | null>(null);
  const back = useRef<Element | null>(sub ? null : document.activeElement);

  useLayoutEffect(() => {
    const m = el.current;
    if (!m) return;
    const r = m.getBoundingClientRect();
    let left = at.x;
    let top = at.y;
    if (at.anchor) {
      const a = at.anchor.getBoundingClientRect();
      // a button in the right half (the toolbar's ⋯) lines the menu up with its right edge, as Windows and the Mac do
      left = at.align === 'end' ? a.right - r.width : at.align !== 'start' && a.left + a.width / 2 > innerWidth / 2 ? a.right - r.width : a.left;
      top = a.bottom + 4;
      if (top + r.height > innerHeight - 8) top = Math.max(8, a.top - r.height - 4);
    }
    if (left + r.width > innerWidth - 8) left = sub ? at.x - r.width - (at.anchor?.getBoundingClientRect().width ?? 0) : innerWidth - 8 - r.width;
    if (top + r.height > innerHeight - 8) top = Math.max(8, innerHeight - 8 - r.height);
    setPos({ left: Math.max(8, left), top: Math.max(8, top) });
    m.focus({ preventScroll: true });
  }, [at.x, at.y, at.anchor, entries.length]);

  // the button that owns the open menu stays pressed while it is open
  useEffect(() => {
    const a = at.anchor;
    if (!a) return;
    a.classList.add('menu-open');
    return () => a.classList.remove('menu-open');
  }, [at.anchor]);

  useEffect(() => {
    if (sub) return;
    const down = (e: MouseEvent) => {
      if (!(e.target as HTMLElement).closest?.('.mw-menu')) onClose();
    };
    const blur = () => onClose();
    window.addEventListener('mousedown', down, true);
    window.addEventListener('blur', blur);
    return () => {
      window.removeEventListener('mousedown', down, true);
      window.removeEventListener('blur', blur);
      if (back.current instanceof HTMLElement && document.contains(back.current)) back.current.focus({ preventScroll: true });
    };
  }, []);

  const runAt = (i: number) => {
    const e = entries[i];
    if (!e || !pickable(e) || e.kind === 'header' || e.kind === 'separator') return;
    if ('submenu' in e && e.submenu) return openSub(i);
    onClose();
    e.run?.();
  };
  const openSub = (i: number) => {
    const row = el.current?.querySelector<HTMLElement>(`[data-ix="${i}"]`);
    if (!row) return;
    const r = row.getBoundingClientRect();
    setOpen({ index: i, at: { x: r.right - 2, y: r.top - 5, anchor: null } });
  };
  const step = (d: number) => {
    const n = entries.length;
    for (let k = 1; k <= n; k++) {
      const j = (((ix < 0 ? (d > 0 ? -1 : 0) : ix) + d * k) % n + n) % n;
      if (pickable(entries[j])) return setIx(j);
    }
  };

  // columns only where a row uses them: a menu with no checks has no check gutter, one with no images no image column
  // (the sort menu is "✓ Updated", not "✓ ⎵ Updated")
  const items = entries.filter((e): e is MenuItem => (e.kind ?? 'item') === 'item');
  const hasCheck = items.some((e) => e.checked !== undefined);
  const hasIcon = items.some((e) => !!e.icon);
  return createPortal(
    <div
      ref={el}
      className={`mw-menu ${hasCheck ? '' : 'no-check'} ${hasIcon ? '' : 'no-ic'}`}
      role="menu"
      aria-label={label}
      tabIndex={-1}
      style={{ ...(pos ? { left: pos.left, top: pos.top } : { left: -9999, top: -9999 }), ...(at.minWidth ? { minWidth: at.minWidth } : {}) }}
      onContextMenu={(e) => e.preventDefault()}
      onKeyDown={(e) => {
        if (open) return;
        e.stopPropagation();
        if (e.key === 'ArrowDown') step(1);
        else if (e.key === 'ArrowUp') step(-1);
        else if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          if (ix >= 0) runAt(ix);
        } else if (e.key === 'ArrowRight' && ix >= 0 && 'submenu' in entries[ix]) openSub(ix);
        else if (e.key === 'Escape' || (e.key === 'ArrowLeft' && sub)) onClose();
        else return;
        e.preventDefault();
      }}
    >
      {entries.map((e, i) => {
        if (e.kind === 'separator') return <div key={i} className="mw-menu-sep" role="separator" />;
        if (e.kind === 'header') return <div key={i} className="mw-menu-head">{e.label}</div>;
        const has = !!e.submenu;
        return (
          <div
            key={i}
            data-ix={i}
            role={e.checked !== undefined ? 'menuitemcheckbox' : 'menuitem'}
            aria-checked={e.checked === 'mixed' ? 'mixed' : e.checked}
            aria-disabled={e.disabled || undefined}
            aria-haspopup={has || undefined}
            data-tip={e.tip ?? (e.hint && !e.danger ? undefined : e.hint)}
            data-testid={e.testId}
            className={`mw-menu-row ${i === ix ? 'on' : ''} ${e.disabled ? 'off' : ''} ${e.danger ? 'danger' : ''} ${e.current ? 'current' : ''}`}
            onMouseEnter={() => {
              if (e.current) return;
              setIx(i);
              if (has && !e.disabled) openSub(i);
              else setOpen(null);
            }}
            onMouseDown={(ev) => ev.preventDefault()}
            onClick={() => runAt(i)}
          >
            <span className="mw-menu-check">{e.checked === true ? <Icon name="check" size={12} /> : e.checked === 'mixed' ? '–' : null}</span>
            <span className="mw-menu-ic">{e.icon}</span>
            <span className="mw-menu-txt">
              <span className="mw-menu-label">{e.label}</span>
              {e.hint && e.danger && <span className="mw-menu-hint">{e.hint}</span>}
              {e.note && <span className="mw-menu-hint">{e.note}</span>}
            </span>
            {e.badge && <span className="mw-menu-badge">{e.badge}</span>}
            {e.keys && <span className="mw-menu-keys">{e.keys}</span>}
            {has && <Icon name="chevron-right" size={12} className="mw-menu-more" />}
          </div>
        );
      })}
      {open && (entries[open.index] as { submenu?: MenuEntry[] }).submenu && (
        <Menu
          sub
          entries={(entries[open.index] as { submenu: MenuEntry[] }).submenu}
          at={open.at}
          onClose={() => {
            setOpen(null);
            el.current?.focus();
          }}
        />
      )}
    </div>,
    document.body,
  );
}

/** One menu on screen at a time, opened from anywhere in the window. */
export function useMenu() {
  const [m, setM] = useState<{ entries: MenuEntry[]; at: MenuAt; label?: string } | null>(null);
  const node = m ? <Menu entries={m.entries} at={m.at} label={m.label} onClose={() => setM(null)} /> : null;
  return {
    node,
    open: (entries: MenuEntry[], at: MenuAt, label?: string) => setM(entries.length ? { entries, at, label } : null),
    close: () => setM(null),
    isOpen: !!m,
  };
}
