// Ctrl+K (the Mac's CommandPalette): one field for every action, place and item. The empty field shows the useful few —
// SELECTED ITEM (hand off, copy instruction, its state actions, move), CAPTURE (Record, Snap), GO TO (the places) —
// everything else (Open Folder, Rescan, Settings, the projects, Make X Current, Show Only…, running jobs) comes when
// searched. With a query: "Items" (the index's search, top 8) then "Commands". A command matches on a contiguous run or
// on word prefixes ("cop ins" → Copy Instruction), never a loose subsequence. The footer says the chosen row's hint.
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Icon } from '@blurt/icons';
import { KindIcon, StatusRing } from '@blurt/ui/react';
import { api, type ItemRow } from '../api';
import { t } from '../i18n';
import { isImeKey } from '../ime';

export interface PaletteEntry {
  id: string;
  title: string;
  icon?: ReactNode;
  keys?: string;
  hint?: string;
  section?: 'selected' | 'capture' | 'go';
  pinned?: boolean;
  run: () => void;
}

export function matches(title: string, q: string): boolean {
  const s = q.trim().toLowerCase();
  if (!s) return true;
  const tl = title.toLowerCase();
  if (tl.includes(s) && (s.length >= 2 || tl.split(/[\s·]+/).some((w) => w.startsWith(s)))) return true;
  const words = tl.split(/[\s·\-/]+/);
  return s.split(/\s+/).every((p) => words.some((w) => w.startsWith(p)));
}

type Row = { header: string } | { entry: PaletteEntry } | { item: ItemRow };

/** The typed text in semibold inside a command's title (the Move popover's grammar), so it shows why a row matched. */
function Marked({ text, q }: { text: string; q: string }) {
  const s = q.trim().toLowerCase();
  const at = s ? text.toLowerCase().indexOf(s) : -1;
  if (at < 0) return <>{text}</>;
  return <>{text.slice(0, at)}<b>{text.slice(at, at + s.length)}</b>{text.slice(at + s.length)}</>;
}

export function Palette({ entries, chip, onClose, onItem }: {
  entries: PaletteEntry[];
  /** what "Selected Item" acts on */
  chip: ReactNode | null;
  onClose: () => void;
  onItem: (r: ItemRow) => void;
}) {
  const [q, setQ] = useState('');
  const [hits, setHits] = useState<ItemRow[]>([]);
  const [ix, setIx] = useState(0);
  // the pointer resting where the palette opens doesn't pick a row: only a real move does (Enter = the first row)
  const moved = useRef(false);
  const list = useRef<HTMLUListElement>(null);
  // the scope chip (the Mac's): × or Backspace in an empty field drops it, and with it the selected item's actions
  const [scoped, setScoped] = useState(true);
  const live = scoped ? entries : entries.filter((e) => e.section !== 'selected');
  useEffect(() => {
    if (!q.trim()) return setHits([]);
    const h = setTimeout(() => api.items({ query: q.trim(), limit: 8 }).then((r) => setHits(r.items), () => setHits([])), 80);
    return () => clearTimeout(h);
  }, [q]);
  const rows: Row[] = useMemo(() => {
    if (!q.trim()) {
      const out: Row[] = [];
      for (const [sec, name] of [['selected', t('main.palette.section.selected')], ['capture', t('main.palette.section.capture')], ['go', t('main.palette.section.go')]] as const) {
        const es = live.filter((e) => e.pinned && e.section === sec);
        if (es.length) out.push({ header: name }, ...es.map((entry) => ({ entry })));
      }
      return out;
    }
    const cmds = live.filter((e) => matches(e.title, q));
    const items: Row[] = hits.length ? [{ header: t('main.palette.section.items') }, ...hits.map((item) => ({ item }))] : [];
    const cmdRows: Row[] = cmds.length ? [{ header: t('main.palette.section.commands') }, ...cmds.map((entry) => ({ entry }))] : [];
    const first = cmds.some((e) => e.title.toLowerCase().startsWith(q.trim().toLowerCase()));
    return first ? [...cmdRows, ...items] : [...items, ...cmdRows];
  }, [q, hits, live]);
  const pickable = rows.map((r, i) => ('header' in r ? -1 : i)).filter((i) => i >= 0);
  const cur = pickable.includes(ix) ? ix : pickable[0] ?? -1;
  useEffect(() => {
    list.current?.querySelector('.sel')?.scrollIntoView({ block: 'nearest' });
  }, [cur]);
  // a section's title never ends the visible list: when one would sit on the bottom edge without its first row, the
  // list stops just above it (the rest scrolls)
  useLayoutEffect(() => {
    const ul = list.current;
    if (!ul) return;
    ul.style.maxHeight = '';
    const h = ul.clientHeight;
    if (ul.scrollHeight <= h + 1) return;
    const base = ul.getBoundingClientRect().top - ul.scrollTop;
    for (const li of ul.querySelectorAll<HTMLLIElement>('li.mw-pal-head')) {
      const next = li.nextElementSibling as HTMLElement | null;
      const top = li.getBoundingClientRect().top - base;
      const end = top + li.offsetHeight + (next ? next.offsetHeight : 0);
      if (top < h && end > h) {
        ul.style.maxHeight = `${top}px`;
        break;
      }
    }
  }, [rows]);
  const run = (r: Row | undefined) => {
    if (!r || 'header' in r) return;
    onClose();
    if ('item' in r) onItem(r.item);
    else r.entry.run();
  };
  const chosen = rows[cur];
  const hint = chosen && 'entry' in chosen ? chosen.entry.hint : chosen && 'item' in chosen ? (chosen.item.project_id === 'inbox' ? t('project.inbox') : chosen.item.project_name) : '';
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="sheet palette mw-palette" role="dialog" aria-modal="true" aria-label={t('menu.palette')} data-testid="palette">
        {chip && scoped && (
          <div className="mw-pal-chip">
            {chip}
            <button type="button" className="mw-pal-chip-x" aria-label={t('main.palette.clear_scope')} title={t('main.palette.clear_scope')} onClick={() => setScoped(false)}>
              <Icon name="x" size={11} />
            </button>
          </div>
        )}
        <div className="mw-pal-field">
        <Icon name="search" size={18} />
        <input
          autoFocus
          value={q}
          placeholder={t('main.palette.placeholder')}
          aria-label={t('main.palette.field')}
          onChange={(e) => {
            setQ(e.target.value);
            setIx(0);
          }}
          onKeyDown={(e) => {
            if (isImeKey(e)) return;
            const at = pickable.indexOf(cur);
            if (e.key === 'ArrowDown') setIx(pickable[Math.min(pickable.length - 1, at + 1)] ?? 0);
            else if (e.key === 'ArrowUp') setIx(pickable[Math.max(0, at - 1)] ?? 0);
            else if (e.key === 'Enter') run(rows[cur]);
            else if (e.key === 'Backspace' && !q && chip && scoped) setScoped(false);
            else if (e.key === 'Escape') {
              e.stopPropagation();
              onClose();
            } else return;
            e.preventDefault();
          }}
        />
        </div>
        <ul role="listbox" ref={list}>
          {rows.map((r, i) =>
            'header' in r ? (
              <li key={`h${i}`} className="mw-pal-head" role="presentation">{r.header}</li>
            ) : (
              <li key={'item' in r ? r.item.uid : r.entry.id} role="option" aria-selected={i === cur} className={i === cur ? 'sel' : ''} onMouseMove={(e) => {
                if (!moved.current && !(e.movementX || e.movementY)) return;
                moved.current = true;
                if (ix !== i) setIx(i);
              }} onClick={() => run(r)}>
                {'item' in r ? (
                  <>
                    <KindIcon kind={r.item.kind} size={16} />
                    <span className="mw-pal-id">{r.item.item_id}</span>
                    <span className="mw-pal-title">{r.item.title || t('main.item.untitled')}</span>
                    <StatusRing state={r.item.state} size={13} />
                    <span className="dim small">{t(`state.${r.item.state}`)}</span>
                  </>
                ) : (
                  <>
                    <span className="mw-pal-ic">{r.entry.icon}</span>
                    <span className="mw-pal-title"><Marked text={r.entry.title} q={q} /></span>
                    {r.entry.keys && <kbd>{r.entry.keys}</kbd>}
                  </>
                )}
              </li>
            ),
          )}
          {!rows.length && <li className="mw-pal-none dim">{t('main.palette.no_results', { a: q.trim() })}</li>}
        </ul>
        <div className="mw-pal-foot">
          <span className="dim small mw-pal-hint">{hint}</span>
          <span className="dim small"><kbd>Enter</kbd> {chosen && 'item' in chosen ? t('main.palette.footer.open') : t('main.palette.footer.run')}</span>
          <span className="dim small"><kbd>Esc</kbd> {t('main.palette.footer.close')}</span>
        </div>
      </div>
    </div>
  );
}
