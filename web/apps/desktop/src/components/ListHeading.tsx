// The top of the list (the Mac's ListHeading, FilterBar, SuggestionsBanner, MissingFolderBanner, JobsSection): the
// place's name in 17 px semibold with its counts beside it ("Inbox  9 new · 6 to verify") and, on the same line, the
// controls that act on the list — its order, named ("Updated ↓"), the Filter button (filled, in brand ink, with how many
// filters are on) and "+ New"; under it the list's own search field. A quiet line says which filter is on, with Clear.
// The running jobs sit above the rows on the rows' grid. An empty place has none of the controls: its empty state alone.
import { forwardRef, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { Icon } from '@blurt/icons';
import type { Job, ProjectRow } from '../api';
import { i18n, plural, t } from '../i18n';
import { isImeKey } from '../ime';
import { FilterGlyph, MissingFolderGlyph, ProjectGlyph } from './glyphs';

export function ListHeading({ title, counts, sortLabel, sortTip, filters, filterTip, showControls, canSort = true, canAdd, onSort, onFilter, onAdd }: {
  title: string;
  counts: string;
  sortLabel: string;
  sortTip: string;
  filters: number;
  filterTip: string;
  showControls: boolean;
  /** the order: off while nothing is listed (it would sort nothing); the Filter stays, it is how the filter changes */
  canSort?: boolean;
  canAdd: boolean;
  onSort: (el: HTMLElement) => void;
  onFilter: (el: HTMLElement) => void;
  onAdd: () => void;
}) {
  // Before the name or its counts are cut, the controls give up their words: first New's ("+"), then the order's (the
  // arrow alone, its name in the tooltip). Measured in CSS px from the natural widths of the title, the counts and the
  // words (each element's own scrollWidth — the row around them ellipsises, so its width says nothing), so 100 % and
  // 150 % land on the same form for the same column.
  const row = useRef<HTMLDivElement>(null);
  const [level, setLevel] = useState(0);
  useLayoutEffect(() => {
    const el = row.current;
    if (!el) return;
    const fit = () => {
      const h1 = el.querySelector<HTMLElement>('.mw-h-title');
      const n = el.querySelector<HTMLElement>('.mw-h-counts');
      const ctl = el.querySelector<HTMLElement>('.mw-h-ctl');
      if (!h1 || !ctl) return;
      const words = [...el.querySelectorAll<HTMLElement>('.mw-h-word')].map((w) => w.scrollWidth);
      const cs = getComputedStyle(el);
      const room = el.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight) - 8;
      const text = h1.scrollWidth + (n ? n.scrollWidth + 8 : 0);
      // the controls' full width: what shows now plus the words hidden now
      const hidden = [...el.querySelectorAll<HTMLElement>('.mw-h-word.off')].reduce((a, w) => a + (Number(w.dataset.w) || 0), 0);
      const full = ctl.scrollWidth + hidden;
      const newW = Number(el.querySelector<HTMLElement>('.mw-h-word.new')?.dataset.w) || words[1] || 0;
      const lv = text + full <= room ? 0 : text + full - newW <= room ? 1 : 2;
      setLevel(lv);
    };
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(el);
    return () => ro.disconnect();
  }, [title, counts, sortLabel, filters, showControls]);
  // remember each word's width while it shows (data-w), so a hidden one still counts
  const word = (cls: string) => (node: HTMLElement | null) => {
    if (node && !node.classList.contains('off') && node.scrollWidth) node.dataset.w = String(node.scrollWidth + 4);
    void cls;
  };
  const [sortName, sortArrow] = (() => {
    const m = /^(.*?)\s*([↑↓])$/.exec(sortLabel);
    return m ? [m[1], m[2]] : [sortLabel, ''];
  })();
  return (
    <div className="mw-heading" ref={row}>
      <div className="mw-h-text">
        <h1 className={`mw-h-title ${/^[「『“（]/.test(title) ? 'hang' : ''}`} data-tip={title} data-tip-trunc="">{title}</h1>
        {counts && <span className="mw-h-counts" aria-hidden="true">{counts}</span>}
      </div>
      <div className="mw-h-ctl">
        {showControls && (
          <>
            {canSort && <button className="mw-bar-btn" onClick={(e) => onSort(e.currentTarget)} data-tip={sortTip} aria-label={sortTip} aria-haspopup="menu" data-testid="sort">
              <span ref={word('sort')} className={`mw-h-word sort ${level >= 2 ? 'off' : ''}`}>{sortName}</span>
              {sortArrow && <SortArrow up={sortArrow === '↑'} />}
            </button>}
            <button className={`mw-bar-btn mw-filter ${filters ? 'on' : ''}`} onClick={(e) => onFilter(e.currentTarget)} data-tip={filterTip} aria-label={t('main.toolbar.filter')} aria-haspopup="menu" data-testid="filter">
              <FilterGlyph size={15} on={filters > 0} />
              {filters > 0 && <span>{i18n().formatNumber(filters)}</span>}
            </button>
          </>
        )}
        {canAdd && (
          <button className="mw-bar-btn mw-new" onClick={onAdd} data-tip={t('main.new_item.tip', { a: 'Ctrl+N' })} aria-label={t('main.new_item.button')} data-testid="new-item">
            <Icon name="plus" size={13} />
            <span ref={word('new')} className={`mw-h-word new ${level >= 1 ? 'off' : ''}`}>{t('main.new_item.button')}</span>
          </button>
        )}
      </div>
    </div>
  );
}

/** The order's direction, drawn in the icon family's stroke (the text ↓ sat low and thin next to the label). */
function SortArrow({ up }: { up: boolean }) {
  return (
    <svg className="ico mw-sort-arrow" width={12} height={12} viewBox="0 0 24 24" aria-hidden="true" style={up ? { transform: 'rotate(180deg)' } : undefined}>
      <path d="M12 5v14M6 13l6 6l6-6" />
    </svg>
  );
}

export const SearchField = forwardRef<HTMLInputElement, { value: string; enabled: boolean; onChange: (v: string) => void; onEnterList: () => void; onClear: () => void }>(
  function SearchField({ value, enabled, onChange, onEnterList, onClear }, ref) {
    return (
      <div className="mw-search">
        <Icon name="search" size={13} />
        <input
          ref={ref}
          type="search"
          value={value}
          disabled={!enabled}
          placeholder={enabled ? t('main.search.placeholder') : t('main.search.placeholder_wait')}
          aria-label={t('main.search.label')}
          data-tip={t('mw.search.tip')}
          data-testid="search"
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={(e) => {
            if (isImeKey(e)) return;
            // Mail's and Finder's list search: ↓ or ↩ into the results, Esc clears and goes back to the list
            if (e.key === 'ArrowDown' || e.key === 'Enter') {
              e.preventDefault();
              onEnterList();
            } else if (e.key === 'Escape') {
              e.preventDefault();
              e.stopPropagation();
              if (value) onClear();
              onEnterList();
            }
          }}
        />
      </div>
    );
  },
);

/** "Showing Issues, Ideas · To verify   Clear": only while a filter is on; a click on it opens the Filter menu. */
export function FilterBar({ text, canClear, onOpen, onClear }: { text: string; canClear: boolean; onOpen: (el: HTMLElement) => void; onClear: () => void }) {
  return (
    <div className="mw-filterbar" data-testid="filter-bar">
      <button className="mw-filterbar-txt" data-tip={t('main.filter.change')} onClick={(e) => onOpen(e.currentTarget)}>
        <FilterGlyph size={13} on />
        <span>{text}</span>
      </button>
      {canClear && <button className="mw-chip-btn" onClick={onClear}>{t('main.filter.clear')}</button>}
    </div>
  );
}

/** Unassigned: "Looks like storefront · Move All (3)" per suggested project, above the rows (the Mac's w16): flat 32 px
    rows on the list's grid — the project's own folder in its colour, "Looks like X" in semibold, a small quiet button
    at the right edge where the times end — and one hairline under the block. No card fill, no sparkle: it is a fact
    about a project, not a feature. */
export function SuggestionsBanner({ groups, onMoveAll }: { groups: { project: ProjectRow; uids: string[] }[]; onMoveAll: (project: string, uids: string[]) => void }) {
  if (!groups.length) return null;
  return (
    <div className="mw-notices" role="group" aria-label={t('main.suggest.label')}>
      {groups.map((g) => (
        <div key={g.project.id} className="mw-notice">
          <span className="mw-notice-ic"><ProjectGlyph id={g.project.id} size={16} /></span>
          <span className="mw-notice-txt" data-tip={t('main.suggest.looks_like', { a: g.project.name })} data-tip-trunc="">{t('main.suggest.looks_like', { a: g.project.name })}</span>
          <button className="mw-chip-btn" onClick={() => onMoveAll(g.project.id, g.uids)} data-tip={g.uids.length > 1 ? t('main.suggest.move_all.tip', { n: g.uids.length, b: g.project.name }) : t('main.list.move.tip', { a: g.project.name })}>
            {g.uids.length > 1 ? t('main.suggest.move_all', { n: g.uids.length }) : t('main.list.move')}
          </button>
        </div>
      ))}
    </div>
  );
}

/** Over a registered project whose folder is gone (moved, renamed, an unplugged disk). */
export function MissingFolderBanner({ onLocate }: { onLocate: () => void }) {
  return (
    <div className="mw-missing" role="group" aria-label={`${t('main.missing.title')}. ${t('main.missing.detail')}`} data-testid="missing-banner">
      <MissingFolderGlyph size={16} />
      <span className="txt">
        <b>{t('main.missing.title')}</b>
        <span className="mw-missing-body">{t('main.missing.detail')}</span>
      </span>
      <button onClick={onLocate}>{t('main.missing.locate_folder')}</button>
    </div>
  );
}

/** The Inbox's notice while captures hang under the island waiting for a project (the Mac's CapturesBanner, attn: they
    wait on you): "3 captures are waiting for a project · Choose projects…" — the island opens with every card down,
    where each one gets its project. Hidden when there are none. */
export function CapturesBanner({ count, onChoose }: { count: number; onChoose: () => void }) {
  if (count <= 0) return null;
  return (
    <div className="mw-captures" role="group" data-testid="captures-banner">
      <Icon name="cards" size={16} />
      <span className="txt">{plural('main.captures.waiting', count)}</span>
      <button onClick={onChoose} data-tip={t('main.captures.tip')}>
        {plural('main.captures.choose', count)}
      </button>
    </div>
  );
}

const MAX_JOB_ROWS = 4;
const JOB_KIND: Record<string, string> = { process: 'spark', route: 'git-branch', snap: 'screenshot', voice: 'voice', record: 'record' };

/** The running jobs above the list (K4): one row each on the rows' grid — its glyph in the kind column, a spinner in
    the ring's, the title, how far in the time column. A click shows it in the detail. */
export function JobsSection({ jobs, selected, projectName, showProject, onSelect }: {
  jobs: Job[];
  selected: string | null;
  projectName: (id: string) => string;
  showProject: boolean;
  onSelect: (j: Job) => void;
}) {
  // the Mac's JobsView: a header "Running · 2 · 1 failed"; more than one folds under it (closed until opened, or until
  // one of them is chosen); failures first — and at most 4 rows
  const [open, setOpen] = useState(false);
  if (!jobs.length) return null;
  const failed = jobs.filter((j) => j.state === 'failed').length;
  const active = jobs.length - failed;
  const head = active === 0 ? plural('main.jobs.header.failed_only', failed) : plural('main.jobs.header', active) + (failed ? ` · ${plural('main.jobs.failed', failed)}` : '');
  // the header as the list's own group headers draw it: the word, its count muted, a chevron when they fold
  const word = active === 0 ? t('main.jobs.label_failed') : t('main.jobs.label');
  const extra = active && failed ? plural('main.jobs.failed', failed) : '';
  const folds = jobs.length > 1;
  const shown = !folds || open || jobs.some((j) => j.id === selected);
  const rank = (j: Job) => (j.state === 'failed' ? 0 : 1);
  const ordered = [...jobs].sort((a, b) => rank(a) - rank(b) || b.created.localeCompare(a.created));
  const rows = shown ? ordered.slice(0, MAX_JOB_ROWS) : [];
  return (
    <div className="mw-jobs" role="list" aria-label={head}>
      <button className="mw-jobs-head" onClick={() => folds && setOpen(!shown)} aria-expanded={folds ? shown : undefined} aria-label={head} data-tip={folds && !shown ? jobs.map((j) => j.title ?? '').filter(Boolean).join(' · ') || undefined : undefined} data-testid="jobs-head">
        <span className="mw-section-name">{word}</span>
        <span className="mw-section-n">{i18n().formatNumber(active || failed)}</span>
        {extra && <span className="mw-section-n">· {extra}</span>}
        {folds && <Icon name={shown ? 'chevron-down' : 'chevron-right'} size={11} />}
      </button>
      {rows.map((j) => {
        const step = j.steps.find((s) => s.state === 'running') ?? j.steps.find((s) => s.state === 'pending');
        const what = t(`job.type.${j.type}`);
        const detail = j.title ?? (j.items.length ? plural('main.items.count', j.items.length) : null);
        // an organizing job that has a name of its own is that name, not "Organizing · AI fill-in"
        const title = j.type === 'process' && j.title ? j.title : detail ? `${what} · ${detail}` : what;
        const status = j.state === 'failed' ? t('job.state.failed') : step ? t(`job.step.${step.id}`) : t(`job.state.${j.state}`);
        const pct = j.progress != null && j.state === 'running' ? `${Math.round(j.progress * 100)}%` : '';
        return (
          <div key={j.id} role="listitem" className={`mw-job ${selected === j.id ? 'sel' : ''} ${j.state === 'failed' ? 'failed' : ''}`} onClick={() => onSelect(j)} data-testid="job-row" data-tip={status}>
            <span className="mw-c-kind"><Icon name={(JOB_KIND[j.type] ?? 'spark') as never} size={15} /></span>
            <span className="mw-c-id">{showProject && j.project ? projectName(j.project) : ''}</span>
            <span className="mw-c-title"><span className="mw-tt">{title}</span><span className="mw-hit">{status}</span></span>
            <span className="mw-c-ring">{j.state === 'failed' ? <Icon name="warning" size={13} /> : <span className="mw-spinner sm" />}</span>
            {/* the percentage when it has one, else how long it has run — a row that visibly moves isn't a stuck one */}
            <span className="mw-c-time">{pct || (j.state === 'running' && j.started ? <Elapsed since={j.started} /> : '')}</span>
          </div>
        );
      })}
      {shown && jobs.length > MAX_JOB_ROWS && <span className="mw-jobs-more">{plural('main.jobs.more', jobs.length - MAX_JOB_ROWS)}</span>}
    </div>
  );
}


/** m:ss since a time, ticking every second (a running job's row). */
function Elapsed({ since }: { since: string }) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const h = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(h);
  }, []);
  const s = Math.max(0, Math.floor((now - Date.parse(since)) / 1000));
  return <>{`${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`}</>;
}
