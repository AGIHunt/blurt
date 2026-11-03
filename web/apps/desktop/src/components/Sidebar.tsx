// The source list (the Mac's SidebarController): the places — Inbox, In Progress, Unassigned, All Items, Dictation —
// then the projects, the folders opened in Blurt in the one project order (pinned, then the most recently used), with
// "+ Open Folder…" at the bottom. A count is the Inbox's mint pill (what's new for you) or quiet digits; a project's
// count is what needs you there. The current project carries the scope mark after its name. A project renames in place
// (double-click, F2 — Windows' key for it — or Rename in its menu); its right-click menu is the Mac's. Items dragged
// onto a project or Unassigned move there. Windows has no app menu, so Settings is the gear at the bottom right.
import { useEffect, useRef, useState } from 'react';
import { Icon } from '@blurt/icons';
import type { ProjectRow, Summary } from '../api';
import { i18n, t } from '../i18n';
import type { Place } from '../places';
import { DRAG_TYPE } from './ItemList';
import { MissingFolderGlyph, ProgressGlyph, ProjectGlyph, ScopeGlyph, UnassignedGlyph } from './glyphs';

function Count({ n, mint }: { n: number; mint?: boolean }) {
  if (!n) return null;
  return <span className={mint ? 'mw-count mint' : 'mw-count'}>{i18n().formatNumber(n)}</span>;
}

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
}: {
  place: Place;
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
}) {
  const [over, setOver] = useState<string | null>(null);
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
      webview()?.postMessageWithAdditionalObjects?.('blurt-drop-folders', e.dataTransfer.files);
    },
  };
  const drop = (target: string) => ({
    onDragOver: (e: React.DragEvent) => {
      const native = !!dragging?.current && e.dataTransfer.types.includes('Files');
      if (!e.dataTransfer.types.includes(DRAG_TYPE) && !native) return;
      e.preventDefault();
      // Windows' own file drag (rows dragged out as files) allows only a copy: asking for a move refuses the drop
      e.dataTransfer.dropEffect = native ? 'copy' : 'move';
      setOver(target);
    },
    onDragLeave: () => setOver((o) => (o === target ? null : o)),
    onDrop: (e: React.DragEvent) => {
      setOver(null);
      const raw = e.dataTransfer.getData(DRAG_TYPE);
      const uids = raw ? (JSON.parse(raw) as string[]) : dragging?.current;
      if (!uids?.length) return;
      e.preventDefault();
      onMove(uids, target);
    },
  });
  const s = summary;
  const progress = s ? s.progress ?? s.active + s.to_verify : 0;
  const row = (p: Place, label: string, icon: React.ReactNode, n: number, opts: { mint?: boolean; ax?: string; testId: string; dropTo?: string } = { testId: '' }) => (
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
      <span className="mw-side-ic">{icon}</span>
      <span className="mw-side-name">{label}</span>
      <Count n={n} mint={opts.mint} />
    </a>
  );
  return (
    <nav className={`mw-sidebar ${folderOver ? 'folder-drop' : ''}`} aria-label={t('main.sidebar.label')} {...folderDrop}>
      <div className="mw-side-list" role="listbox" aria-label={t('main.sidebar.label')}>
        {row('inbox', t('main.place.inbox'), <Icon name="inbox" size={16} />, s?.inbox ?? 0, { mint: true, ax: t('main.sidebar.inbox.ax'), testId: 'nav-inbox' })}
        {row('progress', t('main.place.progress'), <ProgressGlyph size={15} />, progress, { ax: t('main.sidebar.progress.ax'), testId: 'nav-progress' })}
        {row('unassigned', t('project.inbox'), <UnassignedGlyph size={16} />, s?.unassigned ?? 0, { ax: t('main.sidebar.unassigned.ax'), testId: 'nav-unassigned', dropTo: 'inbox' })}
        {row('all', t('main.place.all'), <Icon name="list-box" size={16} />, s?.items ?? 0, { testId: 'nav-all' })}
        {row('dictation', t('dictation.history.sidebar'), <Icon name="character-cursor" size={16} />, 0, { ax: t('main.sidebar.dictation.ax'), testId: 'nav-dictation' })}
        {projects.length > 0 && <div className="mw-side-head">{t('main.sidebar.projects')}</div>}
        {projects.map((p) => {
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
        <button className="mw-side-open" onClick={onOpenFolder} data-tip={t(webview()?.postMessageWithAdditionalObjects ? 'main.sidebar.open_folder.tip_drop' : 'main.sidebar.open_folder.tip', { a: 'Ctrl+O' })} data-testid="open-folder">
          <Icon name="plus" size={12} />
          {t('project.open_folder')}
        </button>
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
const webview = () =>
  (window as unknown as { chrome?: { webview?: { postMessageWithAdditionalObjects?: (m: string, o: FileList) => void } } }).chrome?.webview;
