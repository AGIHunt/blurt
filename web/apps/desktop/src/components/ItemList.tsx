// The dense list (the Mac's ItemListController + ItemCells): one row grammar in every place — kind icon, id, title,
// the state ring, a short date — 32 px high, grouped where it helps (the Inbox by project, In Progress, All Items and a
// project by state; a run's header above its first row, none when there is one run only). The ring shows only where
// the list doesn't already say the state (never on a new item, never in a list grouped by state) — pointed at or
// selected, it shows. Click selects, Ctrl-click and Shift-click select more; a right-click opens the row's menu; rows
// drag onto a project in the sidebar. E renames a title in place.
import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { Action, State } from '@blurt/ui';
import { KindIcon, StatusRing } from '@blurt/ui/react';
import type { ItemRow } from '../api';
import { i18n, plural, t } from '../i18n';
import { CLOSED, listDate, type Grouping, type Section } from '../places';

function Highlight({ text }: { text: string }) {
  // snippet(): matches are wrapped in [ ]
  const parts = text.split(/(\[[^\]]*\])/g);
  return <>{parts.map((p, i) => (p.startsWith('[') && p.endsWith(']') ? <mark key={i}>{p.slice(1, -1)}</mark> : p))}</>;
}

export const DRAG_TYPE = 'application/x-blurt-items';

/** The state's name; "handed off" says to whom (Look.stateLabel). */
export function stateText(r: ItemRow): string {
  if (r.state === 'handed_off' && r.work_to === 'external') return t('state.handed_off.external');
  return t(`state.${r.state}`);
}

/** The search hit, unless it only repeats the title. */
function hitOf(r: ItemRow): string | null {
  if (!r.snippet) return null;
  const plain = r.snippet.replace(/[[\]…]/g, '').trim().toLowerCase();
  return plain && r.title.toLowerCase().includes(plain) ? null : r.snippet;
}

export interface ListRowsProps {
  rows: ItemRow[];
  sections: Map<number, Section>;
  grouping: Grouping;
  selected: Set<string>;
  focus: string | null;
  searching: boolean;
  /** a project id → its name (section headers, suggestions) */
  projectName: (id: string) => string;
  /** registered projects a suggestion can file into */
  canSuggest: (id: string) => boolean;
  /** the rows carry their "Looks like X · Move" (Unassigned only, as on the Mac) */
  suggestRows?: boolean;
  onSelect: (uid: string, how: 'one' | 'toggle' | 'range') => void;
  onOpen: (r: ItemRow) => void;
  onAction: (r: ItemRow, a: Action) => void;
  onMenu: (r: ItemRow, at: { x: number; y: number }) => void;
  onMoveTo: (uids: string[], project: string) => void;
  /** the row whose state menu is open from the keyboard (S) */
  stateMenu: string | null;
  onStateMenu: (uid: string | null) => void;
  /** the row's ring was clicked: the state menu under it */
  onRingMenu?: (r: ItemRow, el: HTMLElement) => void;
  renaming: string | null;
  onRenameDone: (r: ItemRow, title: string | null) => void;
  mac?: boolean;
  /** bring this row into view (the keyboard's J / K, a revealed item); `n` repeats the same request */
  scrollTo?: { uid: string; n: number } | null;
  /** rows drag out as Windows' own file drag (mainwin.rs) instead of the page's */
  nativeDrag?: boolean;
  onNativeDrag?: (uids: string[]) => void;
}

/** Row metrics (ItemCells.swift's Look): a row is 32 px; a run's header 34 px above its first row (28 above the list's
    first). The list only renders the rows on screen, so a place of 20 000 items scrolls like one of 20. */
export const ROW_H = 32;
export const headerH = (i: number) => (i === 0 ? 30 : 40);
const OVERSCAN = 12;

export const ItemList = memo(function ItemList(p: ListRowsProps) {
  const { rows, sections, grouping, selected, focus } = p;
  const lang = i18n();
  const yesterday = lang.lang === 'zh-Hans' ? '昨天' : 'Yesterday';
  // each row's top, with the headers above it
  const tops = useMemo(() => {
    const out = new Float64Array(rows.length + 1);
    let y = 0;
    for (let i = 0; i < rows.length; i++) {
      if (sections.has(i)) y += headerH(i);
      out[i] = y;
      y += ROW_H;
    }
    out[rows.length] = y;
    return out;
  }, [rows, sections]);
  const box = useRef<HTMLDivElement>(null);
  const [view, setView] = useState({ top: 0, h: 800 });
  useLayoutEffect(() => {
    const el = box.current;
    if (!el) return;
    const on = () => setView({ top: el.scrollTop, h: el.clientHeight });
    on();
    const ro = new ResizeObserver(on);
    ro.observe(el);
    el.addEventListener('scroll', on, { passive: true });
    return () => {
      ro.disconnect();
      el.removeEventListener('scroll', on);
    };
  }, []);
  // a new place, filter or search starts at the top
  useLayoutEffect(() => {
    if (box.current && !p.scrollTo) box.current.scrollTop = 0;
  }, [rows.length === 0]);
  useLayoutEffect(() => {
    const el = box.current;
    const i = p.scrollTo ? rows.findIndex((r) => r.uid === p.scrollTo!.uid) : -1;
    if (!el || i < 0) return;
    const top = tops[i] - (sections.has(i) ? headerH(i) : 0);
    const bottom = tops[i] + ROW_H;
    if (top < el.scrollTop) el.scrollTop = top;
    else if (bottom > el.scrollTop + el.clientHeight) el.scrollTop = bottom - el.clientHeight + 10;
  }, [p.scrollTo?.n, p.scrollTo?.uid]);
  const find = (y: number) => {
    let lo = 0, hi = rows.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (tops[mid] + ROW_H < y) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  };
  const start = Math.max(0, find(view.top) - OVERSCAN);
  const end = Math.min(rows.length, find(view.top + view.h) + OVERSCAN);
  const above = start > 0 ? tops[start] - (sections.has(start) ? headerH(start) : 0) : 0;
  const below = tops[rows.length] - (end < rows.length ? tops[end] - (sections.has(end) ? headerH(end) : 0) : tops[rows.length]);
  return (
    <div ref={box} className="mw-rows" role="listbox" aria-multiselectable="true" aria-label={t('main.list.label')} aria-rowcount={rows.length} data-testid="items">
      <div style={{ height: above }} aria-hidden="true" />
      {rows.slice(start, end).map((r, k) => {
        const i = start + k;
        const sec = sections.get(i);
        const sel = selected.has(r.uid);
        const quiet = r.state === 'discarded' || CLOSED.includes(r.state);
        // in a list grouped by state the group says it; a new item's dashed ring says nothing (§4.2) — pointed at or
        // selected, the ring shows
        const ringAtRest = !(grouping === 'state' || r.state === 'new');
        const hit = p.searching ? hitOf(r) : null;
        const full = lang.formatDate(r.updated * 1000, { dateStyle: 'medium', timeStyle: 'short' });
        const sug = p.suggestRows && r.project_id === 'inbox' && r.state !== 'discarded' && r.suggested_project && p.canSuggest(r.suggested_project) ? r.suggested_project : null;
        return (
          <div key={r.uid} className="mw-row-wrap">
            {sec && (
              <div className={`mw-section ${i === 0 ? 'first' : ''}`} role="presentation">
                {grouping === 'state' && <StatusRing state={sec.key as State} size={14} />}
                <span className="mw-section-name">{grouping === 'state' ? t(`state.${sec.key}`) : sec.key === 'inbox' ? t('project.inbox') : p.projectName(sec.key)}</span>
                <span className="mw-section-n">{lang.formatNumber(sec.count)}</span>
              </div>
            )}
            <div
              role="option"
              aria-selected={sel}
              aria-label={[sec ? `${grouping === 'state' ? t(`state.${sec.key}`) : p.projectName(sec.key)}, ${plural('main.items.count', sec.count)}` : '', t(`kind.${r.kind}`), r.title || t('main.item.untitled'), r.item_id, stateText(r), r.project_id === 'inbox' ? t('project.inbox') : r.project_name].filter(Boolean).join(', ')}
              data-uid={r.uid}
              data-testid="item-row"
              className={`mw-row ${sel ? 'sel' : ''} ${focus === r.uid ? 'cur' : ''} ${ringAtRest ? 'ring-on' : ''} ${quiet ? 'quiet' : ''} ${r.state === 'discarded' ? 'gone' : ''}`}
              draggable={p.renaming !== r.uid}
              onDragStart={(e) => {
                const uids = sel ? [...selected] : [r.uid];
                if (p.nativeDrag && p.onNativeDrag) {
                  e.preventDefault();
                  p.onNativeDrag(uids);
                  return;
                }
                e.dataTransfer.setData(DRAG_TYPE, JSON.stringify(uids));
                e.dataTransfer.setData('text/plain', r.title);
                e.dataTransfer.effectAllowed = 'move';
              }}
              onMouseDown={(e) => {
                if (e.button !== 0) return;
                p.onSelect(r.uid, e.shiftKey ? 'range' : e.ctrlKey || e.metaKey ? 'toggle' : 'one');
              }}
              onDoubleClick={() => p.onOpen(r)}
              onContextMenu={(e) => {
                e.preventDefault();
                if (!sel) p.onSelect(r.uid, 'one');
                // the menu starts under the row it is for, never across its text (the Mac opens at the pointer; here the
                // menu's top edge sliced the row's title and time)
                const box = (e.currentTarget as HTMLElement).getBoundingClientRect();
                p.onMenu(r, { x: e.clientX, y: Math.max(e.clientY, box.bottom + 2) });
              }}
            >
              <span className="mw-c-kind">
                <KindIcon kind={r.kind} size={16} title={t(`kind.${r.kind}`)} />
              </span>
              <span className="mw-c-id">
                {r.item_id}
              </span>
              <span className={`mw-c-title ${sug ? 'has-sug' : ''}`}>
                {p.renaming === r.uid ? (
                  <TitleField title={r.title} onDone={(v) => p.onRenameDone(r, v)} />
                ) : (
                  <>
                    <span className="mw-tt" data-tip={r.title.trim() || undefined} data-tip-trunc="">{r.title.trim() || <i className="dim">{t('main.item.untitled')}</i>}</span>
                    {hit && <span className="mw-hit"><Highlight text={hit} /></span>}
                    {sug && (
                      <span className="mw-sug">
                        <span className="mw-sug-txt">{t('main.list.suggested', { a: p.projectName(sug) })}</span>
                        <span className="mw-sug-name">{p.projectName(sug)}</span>
                        <span className="mw-sug-sep" aria-hidden="true">·</span>
                        <button
                          className="mw-linkbtn"
                          data-tip={t('main.list.move.tip', { a: p.projectName(sug) })}
                          onMouseDown={(e) => e.stopPropagation()}
                          onClick={(e) => {
                            e.stopPropagation();
                            p.onMoveTo([r.uid], sug);
                          }}
                        >
                          {t('main.list.move')}
                        </button>
                      </span>
                    )}
                  </>
                )}
              </span>
              <span className="mw-c-ring" onMouseDown={(e) => e.stopPropagation()}>
                {/* the ring opens the window's state menu (App's stateMenuFor, the Mac's StateMenu) */}
                <button
                  type="button"
                  className={`spill-ring s-${r.state} ${p.stateMenu === r.uid ? 'open' : ''}`}
                  aria-haspopup="menu"
                  aria-label={t('main.state.ax', { a: stateText(r) })}
                  data-tip={stateText(r)}
                  onClick={(e) => {
                    e.stopPropagation();
                    if (!sel) p.onSelect(r.uid, 'one');
                    p.onRingMenu?.(r, e.currentTarget);
                  }}
                >
                  <StatusRing state={r.state} size={14} />
                </button>
              </span>
              <span className="mw-c-time" data-tip={full}>{listDate(r.updated, lang.locale, yesterday)}</span>
            </div>
          </div>
        );
      })}
      <div style={{ height: below }} aria-hidden="true" />
    </div>
  );
});

/** Rename in place: the whole title selected; Enter, Tab or a click away commits, Esc reverts; an empty title is refused. */
function TitleField({ title, onDone }: { title: string; onDone: (t: string | null) => void }) {
  const [v, setV] = useState(title);
  const el = useRef<HTMLInputElement>(null);
  const done = useRef(false);
  useEffect(() => {
    el.current?.focus();
    el.current?.select();
    // the start of the title in view, the whole of it selected (typing replaces it)
    if (el.current) el.current.scrollLeft = 0;
  }, []);
  const finish = (save: boolean) => {
    if (done.current) return;
    if (save && !v.trim()) return;
    done.current = true;
    onDone(save && v.trim() !== title ? v.trim() : null);
  };
  return (
    <input
      ref={el}
      className={`mw-rename ${v.trim() ? '' : 'bad'}`}
      data-tip={t('mw.rename.keys')}
      value={v}
      aria-label={t('main.menu.rename')}
      onChange={(e) => setV(e.target.value)}
      onMouseDown={(e) => e.stopPropagation()}
      onBlur={() => finish(!!v.trim())}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === 'Enter' || e.key === 'Tab') {
          e.preventDefault();
          finish(true);
        } else if (e.key === 'Escape') {
          e.preventDefault();
          finish(false);
        }
      }}
    />
  );
}
