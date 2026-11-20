// The source list (the Mac's SidebarController), by capability (docs/design/capabilities.md): Home, then a page per
// capability that is on — Dictation, Cards, Text & Translation (where the build has it), Phone —, then Recording & Items' two groups: Items (Inbox, In Progress,
// Unassigned, All Items) and the projects; with Recording off neither group (nor + Open Folder…) shows. The projects: the folders opened in Blurt in the user's own order (pinned first; drag one to move it — using a project never does), with
// "+ Open Folder…" at the bottom. A count is the Inbox's mint pill (what's new for you) or quiet digits; a project's
// count is what needs you there. The current project carries the scope mark after its name. A project renames in place
// (double-click, F2 — Windows' key for it — or Rename in its menu); its right-click menu is the Mac's. Items dragged
// onto a project or Unassigned move there; files from another app or the island's cards dropped on one go there
// (onDropAt: New Item in that project, the cards filed — drag-drop.md §4). Windows has no app menu, so Settings is the
// gear at the bottom right.
import { useEffect, useRef, useState } from 'react';
import { Icon } from '@blurt/icons';
import type { ProjectRow, Summary } from '../api';
import { i18n, t } from '../i18n';
import type { Place } from '../places';
import type { Off } from '../capabilities';
import { DRAG_TYPE } from './ItemList';
import { MissingFolderGlyph, ProgressGlyph, ProjectGlyph, ScopeGlyph, UnassignedGlyph } from './glyphs';

function Count({ n, mint }: { n: number; mint?: boolean }) {
  if (!n) return null;
  return <span className={mint ? 'mw-count mint' : 'mw-count'}>{i18n().formatNumber(n)}</span>;
}

/** A project row dragged within the sidebar (a new place in the user's order). */
const PROJECT_DRAG = 'application/x-blurt-project';

export function Sidebar({
  place,
  onGo,
  summary,
  projects,
  current,
  onMove,
  onOpenFolder,
  onSettings,
  onProjectMenu,
  renaming,
  onRename,
  onRenameDone,
  dragging,
  fresh,
  onDropAt,
  onReorder,
  off,
  screenText = false,
  cards = 0,
  phoneAlert,
}: {
  place: Place;
  /** the capabilities that are off: their places aren't listed */
  off: Off;
  /** this build has Text & Translation (Windows, Linux): its page's row */
  screenText?: boolean;
  /** cards at the top of the screen (the Cards row's count) */
  cards?: number;
  /** a paired phone can't do anything here (the Phone row's mark) */
  phoneAlert?: boolean;
  /** focusList false: the click keeps the focus on the row (App.go) */
  onGo: (p: Place, opts?: { focusList?: boolean }) => void;
  summary: Summary | null;
  /** registered projects, in the one order */
  projects: ProjectRow[];
  /** the current project's id (where new captures go), or null */
  current: string | null;
  onMove: (uids: string[], project: string) => void;
  onOpenFolder: () => void;
  onSettings: () => void;
  onProjectMenu: (p: ProjectRow, at: { x: number; y: number }) => void;
  /** the project whose name is being typed in place */
  renaming: string | null;
  onRename: (id: string) => void;
  onRenameDone: (id: string, name: string | null) => void;
  /** the rows of a drag under way as Windows' own file drag (it carries their files, not their uids) */
  dragging?: { current: string[] | null };
  /** a project just added (a folder dropped or opened): its row glows once, tying the toast to it */
  fresh?: string | null;
  /** files, text or the island's cards dragged over / dropped on a project row (null: the sidebar, not a row — a
      folder drop): true when the app takes it (App.sidebarDrop) */
  onDropAt?: (e: React.DragEvent, project: string | null, phase: 'over' | 'drop' | 'leave') => boolean;
  /** a project dragged onto another (before it, or after it when `after`) */
  onReorder?: (moving: string, onto: string, after: boolean) => void;
}) {
  const [over, setOver] = useState<string | null>(null);
  /** a project being dragged to a new place, and where it would land */
  const [moving, setMoving] = useState<string | null>(null);
  const [lands, setLands] = useState<{ id: string; after: boolean } | null>(null);
  // folders dragged in from Explorer (the Mac's sidebar takes file URLs): the whole sidebar lights up, and on the drop
  // their File objects go to the app (folder_drop.rs reads the paths; a page can't). A drag of Blurt's own rows or
  // cards (files with a type) isn't a folder drag.
  const [folderOver, setFolderOver] = useState(false);
  const folderDrag = (e: React.DragEvent) =>
    !dragging?.current && !e.dataTransfer.types.includes(DRAG_TYPE) && [...e.dataTransfer.items].some((i) => i.kind === 'file' && i.type === '');
  const folderDrop = {
    onDragOver: (e: React.DragEvent) => {
      if (!folderDrag(e)) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'link';
      setFolderOver(true);
    },
    onDragLeave: (e: React.DragEvent) => {
      if (!(e.currentTarget as HTMLElement).contains(e.relatedTarget as Node)) setFolderOver(false);
    },
    onDrop: (e: React.DragEvent) => {
      setFolderOver(false);
      if (!folderDrag(e)) return;
      e.preventDefault();
      // the folders open as projects; files dropped with them go to the row they were let go on (App.sidebarDrop)
      const row = (e.target as HTMLElement).closest<HTMLElement>('[data-drop-to]')?.dataset.dropTo ?? null;
      if (!onDropAt?.(e, row, 'drop')) webview()?.postMessageWithAdditionalObjects?.('blurt-drop-folders', e.dataTransfer.files);
    },
  };
  const drop = (target: string) => ({
    'data-drop-to': target,
    onDragOver: (e: React.DragEvent) => {
      const native = !!dragging?.current && e.dataTransfer.types.includes('Files');
      if (!e.dataTransfer.types.includes(DRAG_TYPE) && !native) {
        // from outside or the island: the app says whether this row takes it (a folder drag is the sidebar's)
        if (folderDrag(e) || !onDropAt?.(e, target, 'over')) return;
        e.preventDefault();
        e.stopPropagation();
        setOver(target);
        return;
      }
      e.preventDefault();
      // Windows' own file drag (rows dragged out as files) allows only a copy: asking for a move refuses the drop
      e.dataTransfer.dropEffect = native ? 'copy' : 'move';
      setOver(target);
    },
    onDragLeave: (e: React.DragEvent) => {
      setOver((o) => (o === target ? null : o));
      if (!(e.currentTarget as HTMLElement).contains(e.relatedTarget as Node | null)) onDropAt?.(e, target, 'leave');
    },
    onDrop: (e: React.DragEvent) => {
      setOver(null);
      const raw = e.dataTransfer.getData(DRAG_TYPE);
      const uids = raw ? (JSON.parse(raw) as string[]) : dragging?.current;
      if (!uids?.length) {
        if (folderDrag(e) || !onDropAt?.(e, target, 'drop')) return;
        e.preventDefault();
        e.stopPropagation();
        return;
      }
      e.preventDefault();
      onMove(uids, target);
    },
  });
  const s = summary;
  const progress = s ? s.progress ?? s.active + s.to_verify : 0;
  const recording = !off.has('recording');
  const row = (p: Place, label: string, icon: React.ReactNode, n: number, opts: { mint?: boolean; ax?: string; testId: string; dropTo?: string; alert?: boolean } = { testId: '' }) => (
    <a
      key={p}
      role="option"
      aria-selected={place === p}
      aria-label={[opts.ax ?? label, n ? i18n().formatNumber(n) : ''].filter(Boolean).join(', ')}
      className={`mw-side-row ${place === p ? 'sel' : ''} ${opts.dropTo && over === opts.dropTo ? 'drop' : ''}`}
      onClick={() => onGo(p, { focusList: false })}
      data-testid={opts.testId}
      {...(opts.dropTo ? drop(opts.dropTo) : {})}
    >
      {/* the attention mark sits on the icon, so a long name (Remote Control) keeps its room */}
      <span className={`mw-side-ic ${opts.alert ? 'alert' : ''}`}>{icon}{opts.alert && <i className="mw-side-alert" aria-hidden="true" />}</span>
      <span className="mw-side-name">{label}</span>
      {!opts.alert && <Count n={n} mint={opts.mint} />}
    </a>
  );
  return (
    <nav className={`mw-sidebar ${folderOver ? 'folder-drop' : ''}`} aria-label={t('main.sidebar.label')} {...folderDrop}>
      <div className="mw-side-list" role="listbox" aria-label={t('main.sidebar.label')}>
        {row('home', t('home.title'), <Icon name="home" size={16} />, 0, { testId: 'nav-home' })}
        {!off.has('dictation') && row('dictation', t('dictation.history.sidebar'), <Icon name="character-cursor" size={16} />, 0, { ax: t('main.sidebar.dictation.ax'), testId: 'nav-dictation' })}
        {!off.has('cards') && row('cards', t('cards.title'), <Icon name="cards" size={16} />, cards, { testId: 'nav-cards' })}
        {screenText && !off.has('screen_text') && row('screen_text', t('feature.screen_text'), <Icon name="text-viewfinder" size={16} />, 0, { testId: 'nav-screen-text' })}
        {!off.has('phone') && row('phone', t('feature.phone'), <Icon name="devices" size={16} />, 0, { testId: 'nav-phone', alert: phoneAlert })}
        {recording && <div className="mw-side-head">{t('main.sidebar.items')}</div>}
        {recording && row('inbox', t('main.place.inbox'), <Icon name="inbox" size={16} />, s?.inbox ?? 0, { mint: true, ax: t('main.sidebar.inbox.ax'), testId: 'nav-inbox' })}
        {recording && row('progress', t('main.place.progress'), <ProgressGlyph size={15} />, progress, { ax: t('main.sidebar.progress.ax'), testId: 'nav-progress' })}
        {recording && row('unassigned', t('project.inbox'), <UnassignedGlyph size={16} />, s?.unassigned ?? 0, { ax: t('main.sidebar.unassigned.ax'), testId: 'nav-unassigned', dropTo: 'inbox' })}
        {recording && row('all', t('main.place.all'), <Icon name="list-box" size={16} />, s?.items ?? 0, { testId: 'nav-all' })}
        {recording && projects.length > 0 && <div className="mw-side-head">{t('main.sidebar.projects')}</div>}
        {(recording ? projects : []).map((p) => {
          const pl: Place = `project:${p.id}`;
          const cur = current === p.id;
          const tip = [p.key ? t('main.sidebar.project_tip', { a: p.name, b: p.key }) : p.name, cur ? t('main.project.current_mark') : ''].filter(Boolean).join('\n');
          return (
            <a
              key={p.id}
              role="option"
              aria-selected={place === pl}
              aria-label={[p.name, p.path, !p.exists ? t('main.sidebar.missing') : '', cur ? t('main.project.current_mark') : '', p.inbox ? i18n().formatNumber(p.inbox) : ''].filter(Boolean).join(', ')}
              className={`mw-side-row ${place === pl ? 'sel' : ''} ${over === p.id ? 'drop' : ''} ${p.exists ? '' : 'dim'} ${fresh === p.id ? 'fresh' : ''}`}
              data-tip={tip}
              tabIndex={0}
              onClick={() => onGo(pl, { focusList: false })}
              onDoubleClick={() => place === pl && onRename(p.id)}
              onKeyDown={(e) => {
                if (e.key === 'F2') {
                  e.preventDefault();
                  onRename(p.id);
                }
              }}
              onContextMenu={(e) => {
                e.preventDefault();
                const box = (e.currentTarget as HTMLElement).getBoundingClientRect();
                onProjectMenu(p, { x: e.clientX, y: Math.max(e.clientY, box.bottom + 2) });
              }}
              data-testid={`nav-project-${p.id}`}
              {...drop(p.id)}
              draggable={!!onReorder && renaming !== p.id}
              onDragStart={(e) => {
                e.dataTransfer.setData(PROJECT_DRAG, p.id);
                e.dataTransfer.effectAllowed = 'move';
                setMoving(p.id);
              }}
              onDragEnd={() => (setMoving(null), setLands(null))}
              onDragOverCapture={(e) => {
                if (!moving || !e.dataTransfer.types.includes(PROJECT_DRAG)) return;
                e.preventDefault();
                e.stopPropagation();
                const box = (e.currentTarget as HTMLElement).getBoundingClientRect();
                setLands({ id: p.id, after: e.clientY > box.top + box.height / 2 });
              }}
              onDropCapture={(e) => {
                const id = e.dataTransfer.getData(PROJECT_DRAG);
                if (!id) return;
                e.preventDefault();
                e.stopPropagation();
                const box = (e.currentTarget as HTMLElement).getBoundingClientRect();
                onReorder?.(id, p.id, e.clientY > box.top + box.height / 2);
                setMoving(null);
                setLands(null);
              }}
              style={lands?.id === p.id && moving !== p.id ? { boxShadow: `inset 0 ${lands.after ? -2 : 2}px 0 var(--brand-ink)` } : undefined}
            >
              <span className="mw-side-ic">{p.exists ? <ProjectGlyph id={p.id} size={16} /> : <MissingFolderGlyph size={16} />}</span>
              {renaming === p.id ? (
                <RenameField name={p.name} onDone={(n) => onRenameDone(p.id, n)} />
              ) : (
                <MidName name={p.name} />
              )}
              {cur && renaming !== p.id && <ScopeGlyph size={11} className="mw-side-cur" />}
              {renaming !== p.id && <Count n={p.inbox} />}
            </a>
          );
        })}
        {/* a folder dragged in from Explorer: where it will land, said in words (the drag badge is the OS's) */}
        {folderOver && (
          <div className="mw-side-row mw-side-drop-row" aria-hidden="true">
            <span className="mw-side-ic"><Icon name="folder-plus" size={16} /></span>
            <span className="mw-side-name">{t('main.sidebar.drop_hint')}</span>
          </div>
        )}
      </div>
      <div className="mw-side-foot">
        {recording && <button className="mw-side-open" onClick={onOpenFolder} data-tip={t(webview()?.postMessageWithAdditionalObjects ? 'main.sidebar.open_folder.tip_drop' : 'main.sidebar.open_folder.tip', { a: 'Ctrl+O' })} data-testid="open-folder">
          <Icon name="plus" size={12} />
          {t('project.open_folder')}
        </button>}
        <span className="grow" />
        <button className="mw-side-gear" onClick={onSettings} aria-label={t('mw.settings')} data-tip={`${t("mw.settings")} (Ctrl+,)`} data-testid="nav-settings">
          <Icon name="settings-gear" size={15} />
        </button>
      </div>
    </nav>
  );
}

/** The name typed in place: Enter, Tab or a click away commits, Esc puts it back; an empty name is refused there. */
function RenameField({ name, onDone }: { name: string; onDone: (name: string | null) => void }) {
  const [v, setV] = useState(name);
  const el = useRef<HTMLInputElement>(null);
  const done = useRef(false);
  useEffect(() => {
    el.current?.focus();
    el.current?.select();
  }, []);
  const finish = (save: boolean) => {
    if (done.current) return;
    if (save && !v.trim()) return;
    done.current = true;
    onDone(save && v.trim() !== name ? v.trim() : null);
  };
  return (
    <input
      ref={el}
      className={`mw-rename ${v.trim() ? '' : 'bad'}`}
      value={v}
      aria-label={t('main.project.rename')}
      onChange={(e) => setV(e.target.value)}
      onClick={(e) => e.stopPropagation()}
      onBlur={() => finish(!!v.trim())}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === 'Enter' || e.key === 'Tab') {
          e.preventDefault();
          finish(true);
        } else if (e.key === 'Escape') finish(false);
      }}
    />
  );
}

export { RenameField };

/** A long name cut in the middle, as the Mac's sidebar does ("Billing API（支付对…新的结算中心）"): the end stays
    whole (it is what tells two similar names apart), the start gives way. Short names read as one run. */
export function MidName({ name, tail = 6 }: { name: string; tail?: number }) {
  const chars = [...name];
  if (chars.length <= tail + 4) return <span className="mw-side-name">{name}</span>;
  // the tail starts on a word: a cut inside "Native" left a lone "e" — take the whole word (or drop the fragment
  // when the word is long)
  let n = tail;
  const latin = (c: string | undefined) => !!c && /[A-Za-z0-9]/.test(c);
  if (latin(chars[chars.length - n]) && latin(chars[chars.length - n - 1])) {
    let k = n;
    while (k < chars.length - 4 && latin(chars[chars.length - k - 1])) k++;
    if (k - n <= 8) n = k;
    else while (n > 1 && latin(chars[chars.length - n])) n--;
  }
  const tl = chars.slice(-n).join('').trimStart();
  return (
    <span className="mw-side-name mid">
      <span className="mid-head">{chars.slice(0, -n).join('').trimEnd()}</span>
      <span className="mid-tail">{tl}</span>
    </span>
  );
}

/** WebView2's host bridge (Windows): how dropped folders reach the app (folder_drop.rs) */
export const webview = () =>
  (window as unknown as { chrome?: { webview?: { postMessageWithAdditionalObjects?: (m: string, o: FileList) => void } } }).chrome?.webview;
