// The main window on Windows / Linux (v0.7): sidebar (Inbox · Agent Sessions · All Items · Projects) · the item list
// of a project with its filters · the item in the review component (protocol v3) · agent sessions in an embedded
// terminal. Capture lives in the island; the toolbar here offers the same three actions.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Icon } from '@blurt/icons';
import { applyPlatform, applyTheme, CLOSED_STATES, INBOX_STATES, OPEN_STATES, targetOf, type Action, type State } from '@blurt/ui';
import { KindIcon } from '@blurt/ui/react';
import {
  api,
  
  fileSrc,
  listen,
  type AppStatus,
  type BatchRow,
  type ItemQuery,
  type ItemRow,
  type Job,
  type ProjectList,
  type ProjectRow,
  type Summary,
} from './api';
import { hostFor } from './host';
import { i18n, plural, setLang, t, errText } from './i18n';
import { isImeKey } from './ime';
import { debounce, inField, nextSelection } from './util';
import { DispatchSheet } from './components/DispatchSheet';
import { InboxView } from './components/InboxView';
import { ItemList } from './components/ItemList';
import { ReviewPane } from './components/ReviewPane';
import { SessionsView } from './components/SessionsView';
import { SettingsView } from './components/SettingsView';
import { Sidebar, type View } from './components/Sidebar';

/** the list's filters are K3's groups: needs you, not finished, finished, everything (but discarded), discarded */
type Filter = 'inbox' | 'open' | 'closed' | 'all' | 'discarded';
const FILTERS: Filter[] = ['inbox', 'open', 'closed', 'all', 'discarded'];
const FILTER_STATES: Record<Filter, readonly State[] | undefined> = {
  inbox: INBOX_STATES, open: OPEN_STATES, closed: CLOSED_STATES, all: undefined, discarded: ['discarded'],
};
const KINDS = ['issue', 'idea', 'note', 'task'] as const;
const PAGE = 200;

function useToast() {
  const [msg, setMsg] = useState<string | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const show = useCallback((m: string) => {
    setMsg(m);
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setMsg(null), 4200);
  }, []);
  return { msg, show };
}

function startView(sv: string | null | undefined): View | null {
  if (!sv) return null;
  if (sv.startsWith('review:')) return { kind: 'review', session: sv.slice(7), title: '', back: { kind: 'inbox' } };
  if (sv.startsWith('project:')) return { kind: 'project', id: sv.slice(8) };
  if (sv.startsWith('sessions')) return { kind: 'sessions', job: sv.split(':')[1] ?? null };
  if (sv === 'inbox' || sv === 'all' || sv === 'settings') return { kind: sv } as View;
  return null;
}

export default function App() {
  const [status, setStatus] = useState<AppStatus | null>(null);
  const [, setLangTick] = useState(0);
  const [projects, setProjects] = useState<ProjectList | null>(null);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [jobs, setJobs] = useState<Job[]>([]);
  const [view, setView] = useState<View>({ kind: 'inbox' });
  const [filter, setFilter] = useState<Filter>('open');
  const [kinds, setKinds] = useState<string[]>([]);
  const [query, setQuery] = useState('');
  const [items, setItems] = useState<ItemRow[]>([]);
  const [total, setTotal] = useState(0);
  const [missing, setMissing] = useState(false);
  const [limit, setLimit] = useState(PAGE);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [focus, setFocus] = useState<string | null>(null);
  const [batches, setBatches] = useState<BatchRow[] | null>(null);
  const [verify, setVerify] = useState<ItemRow[] | null>(null);
  const [dispatch, setDispatch] = useState<string[] | null>(null);
  const [palette, setPalette] = useState(false);
  const [recording, setRecording] = useState(false);
  const [scanning, setScanning] = useState(false);
  const [tick, setTick] = useState(0);
  const [editor, setEditor] = useState('vscode');
  const toast = useToast();
  const searchRef = useRef<HTMLInputElement>(null);
  const refresh = useMemo(() => debounce(() => setTick((n) => n + 1), 150), []);

  const relang = useCallback((l: string) => {
    setLang(l);
    setLangTick((n) => n + 1);
  }, []);

  useEffect(() => {
    api.status().then((s) => {
      relang(s.lang);
      setStatus(s);
      setRecording(s.capture.recording);
      applyPlatform(s.platform);
      applyTheme('auto');
      const v = startView(s.start_view);
      if (v) setView(v);
    });
    api.settings().then((s) => typeof s.config?.app?.editor === 'string' && setEditor(s.config.app.editor), () => {});
    const offs = [
      listen('index://changed', refresh),
      listen('projects://changed', refresh),
      listen<Job[]>('jobs://changed', () => refresh()),
      listen<{ scanning: boolean }>('index://status', (p) => setScanning(p.scanning)),
      listen<{ ev: string; code?: string }>('capture://status', (p) => {
        if (p.ev === 'started') setRecording(true);
        else if (['stopped', 'discarded', 'cancelled', 'error'].includes(p.ev)) setRecording(false);
        if (p.ev === 'error' && p.code) toast.show(t(`error.${p.code}`) === `error.${p.code}` ? t('error.unknown') : t(`error.${p.code}`));
      }),
      listen<{ view?: string; item?: string; session?: string; job?: string | null; project?: string }>('nav', (p) => {
        if (p.view === 'inbox') setView({ kind: 'inbox' });
        else if (p.job !== undefined) setView({ kind: 'sessions', job: p.job });
        else if (p.project) setView({ kind: 'project', id: p.project });
        else if (p.session) setView({ kind: 'review', session: p.session, title: '', back: { kind: 'inbox' } });
        else if (p.item) {
          setView({ kind: 'all' });
          setSelected(new Set([p.item]));
          setFocus(p.item);
        }
      }),
    ];
    return () => offs.forEach((o) => o());
  }, []);

  // sidebar data
  useEffect(() => {
    api.projects().then(setProjects, () => {});
    api.summary().then(setSummary, () => {});
    api.jobs(true).then(setJobs, () => {});
  }, [tick]);

  const projectOf = useCallback((id: string): ProjectRow | null => (id === 'inbox' ? projects?.inbox ?? null : projects?.projects.find((p) => p.id === id) ?? null), [projects]);
  const projectName = useCallback((id: string) => projectOf(id)?.name ?? id, [projectOf]);
  const listView = view.kind === 'project' || view.kind === 'all';

  // the list
  const q: ItemQuery = useMemo(() => {
    const states = FILTER_STATES[query.trim() ? 'all' : filter];
    const out: ItemQuery = { limit, sort: 'updated', ...(states ? { state: [...states] } : {}) };
    if (query.trim()) out.query = query.trim();
    if (kinds.length) out.kind = kinds;
    if (view.kind === 'project') out.project = view.id;
    return out;
  }, [query, kinds, filter, view, limit]);

  useEffect(() => {
    if (!listView) return;
    let alive = true;
    api.items(q).then(
      (r) => {
        if (!alive) return;
        setItems(r.items);
        setTotal(r.total);
        setMissing(r.missing);
      },
      (e) => toast.show(String(e)),
    );
    return () => {
      alive = false;
    };
  }, [q, listView, tick]);

  useEffect(() => {
    if (view.kind !== 'inbox') return;
    api.batches({ state: 'to_review', limit: 100 }).then((b) => setBatches(b.filter((x) => x.new_count > 0)), () => setBatches([]));
    api.items({ state: ['to_verify'], sort: 'updated', limit: 100 }).then((r) => setVerify(r.items), () => setVerify([]));
  }, [view, tick]);

  useEffect(() => {
    setSelected(new Set());
    setFocus(null);
    setLimit(PAGE);
  }, [view.kind, view.kind === 'project' ? view.id : '', filter]);

  // keep a deep-linked item selected even when it isn't on the first page
  const [extra, setExtra] = useState<ItemRow | null>(null);
  useEffect(() => {
    if (focus && !items.some((i) => i.uid === focus)) api.item(focus).then(setExtra);
    else setExtra(null);
  }, [focus, items]);
  const current = items.find((i) => i.uid === focus) ?? (extra?.uid === focus ? extra : null);
  useEffect(() => {
    if (!focus && items.length && listView) {
      setFocus(items[0].uid);
      setSelected(new Set([items[0].uid]));
    }
  }, [items, focus, listView]);

  const openSession = useCallback((job: string | null) => setView({ kind: 'sessions', job }), []);
  const cb = useMemo(
    () => ({
      onDispatch: (uids: string[]) => setDispatch(uids),
      onOpenSession: (job: string) => openSession(job),
      onHandoff: (_r: unknown, what: 'instruction' | 'full') => toast.show(t(what === 'full' ? 'act.copied_full' : 'act.copied')),
      onError: (e: unknown) => toast.show(errText(e)),
    }),
    [],
  );
  const detailProject = current ? projectOf(current.project_id) : null;
  const host = useMemo(
    () => (current ? hostFor({ project: current.project_id }, detailProject?.kind === 'inbox' ? null : detailProject?.path ?? null, cb, editor) : null),
    [current?.project_id, detailProject?.path, cb, editor],
  );
  const reviewHost = useMemo(() => {
    if (view.kind !== 'review') return null;
    const b = batches?.find((x) => x.dir === view.session);
    return hostFor({ session: view.session }, b && b.project_id !== 'inbox' ? b.project_path : null, cb, editor);
  }, [view, cb, editor]);

  const record = async () => {
    try {
      if (recording) await api.captureControl('stop');
      else await api.captureStart();
    } catch (e) {
      if (String(e) !== 'cancelled') toast.show(errText(e));
    }
  };

  const select = (uid: string, how: 'one' | 'toggle' | 'range') => {
    setSelected((cur) => nextSelection(items.map((i) => i.uid), cur, focus, uid, how));
    setFocus(uid);
  };
  /** a pick from a row's state menu (K3): hand off opens the dispatch sheet, the rest is `items.py state --action` */
  const act = useCallback(async (r: ItemRow, a: Action) => {
    if (a === 'hand_off') return setDispatch([r.uid]);
    try {
      await api.state([r.uid], a);
      refresh();
      const to = targetOf(a, { state: r.state });
      toast.show(a === 'restore' || !to ? t('act.restored', { id: r.item_id }) : t('act.state', { state: t(`state.${to}`), id: r.item_id }));
    } catch (e) {
      toast.show(errText(e));
    }
  }, []);
  const moveItems = async (uids: string[], project: string) => {
    try {
      await api.move(uids, project);
      refresh();
    } catch (e) {
      toast.show(errText(e));
    }
  };
  const selectedUids = [...selected];
  const dispatchProject = useMemo(() => {
    const ids = new Set(items.filter((i) => selected.has(i.uid)).map((i) => i.project_id));
    if (dispatch && current && dispatch.includes(current.uid)) ids.add(current.project_id);
    return ids.size === 1 ? projectOf([...ids][0]) : null;
  }, [dispatch, selected, items, current, projectOf]);

  // keyboard
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const mod = e.ctrlKey || e.metaKey;
      if (mod && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setPalette((p) => !p);
        return;
      }
      if (e.key === 'Escape') {
        if (palette) setPalette(false);
        else if (dispatch) setDispatch(null);
        else if (view.kind === 'review' && !document.querySelector('.modal, .lightbox')) setView(view.back);
        return;
      }
      if (e.defaultPrevented || inField(e.target) || isImeKey(e) || palette || dispatch) return;
      if (view.kind === 'review' || view.kind === 'sessions' || view.kind === 'settings') return;
      const k = e.key;
      if (k === '/') {
        e.preventDefault();
        searchRef.current?.focus();
      } else if (listView && ['j', 'k', 'ArrowDown', 'ArrowUp'].includes(k)) {
        const ix = items.findIndex((i) => i.uid === focus);
        const n = items[Math.max(0, Math.min(items.length - 1, ix + (k === 'j' || k === 'ArrowDown' ? 1 : -1)))];
        if (n) {
          select(n.uid, e.shiftKey ? 'range' : 'one');
          document.querySelector(`[data-uid="${n.uid}"]`)?.scrollIntoView({ block: 'nearest' });
        }
        e.preventDefault();
      } else if (listView && mod && k === 'Enter' && selected.size) {
        e.preventDefault();
        setDispatch([...selected]);
      } else if (listView && k === 'Enter' && current) {
        (document.querySelector('.review-pane textarea.title') as HTMLElement | null)?.focus();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [items, focus, selected, current, view, palette, dispatch, listView]);

  const platform = status?.platform ?? 'win';
  const cur = projects?.current && projects.current !== 'auto' ? projectOf(projects.current) : null;
  const waiting = jobs.filter((j) => j.type === 'agent' && j.agent?.status === 'waiting_input').length;
  const lang = i18n().lang;

  const header = (() => {
    if (view.kind === 'project') {
      const p = projectOf(view.id);
      if (!p) return null;
      return (
        <header className="project-head">
          <Icon name={p.kind === 'inbox' ? 'inbox' : 'folder'} size={20} />
          <div className="txt">
            <h1>
              {p.name} {p.kind !== 'inbox' && <span className="pkey">{p.key}</span>}
            </h1>
            <div className="sub">
              {p.kind === 'inbox' ? t('project.inbox.lead') : <code>{p.path}</code>}
              {p.kind !== 'inbox' && p.kind !== 'repo' && <span className="dim"> · {t('project.header.not_git')}</span>}
            </div>
          </div>
          {p.kind === 'repo' && (
            <label className="check small">
              <input type="checkbox" checked={p.worktree !== false} onChange={async (e) => {
                await api.setProject(p.id, { worktree: e.target.checked }).catch(cb.onError);
                refresh();
              }} />
              {t('project.header.worktree')}
            </label>
          )}
          <button className="link" onClick={() => api.reveal(p.kind === 'inbox' ? p.store : p.path)}>
            <Icon name="reveal" size={14} />
            {t('project.header.reveal')}
          </button>
        </header>
      );
    }
    if (view.kind === 'all') return <header className="project-head"><Icon name="list" size={20} /><div className="txt"><h1>{t('nav.all')}</h1></div></header>;
    return null;
  })();

  return (
    <div className="app" data-platform={platform} lang={lang}>
      <header className="topbar">
        <button className={`rec ${recording ? 'on' : ''}`} onClick={record} data-testid="record">
          <Icon name={recording ? 'stop-fill' : 'record-fill'} size={13} className="rec-dot" />
          {recording ? t('app.finish') : t('app.record')}
        </button>
        <button onClick={() => api.captureControl('snap').catch(cb.onError)} aria-label={t('app.snap')} title={t('app.snap')}><Icon name="screenshot" size={16} /></button>
        <button onClick={() => api.voice().catch(cb.onError)} aria-label={t('app.voice')} title={t('app.voice')}><Icon name="voice" size={16} /></button>
        <button className="proj-chip" onClick={() => cur && setView({ kind: 'project', id: cur.id })} title={cur?.path} data-testid="current-project">
          <Icon name={cur ? 'folder' : 'spark'} size={14} />
          {cur ? cur.name : t('project.auto')}
        </button>
        <div className="spacer" />
        {scanning && <span className="dim small">{t('app.indexing')}</span>}
        <div className="searchbox">
          <Icon name="search" size={14} />
          <input
            ref={searchRef}
            data-testid="search"
            placeholder={t('app.search')}
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setLimit(PAGE);
              setFocus(null);
              if (!listView) setView({ kind: 'all' });
            }}
            onKeyDown={(e) => {
              if (e.key === 'Escape' || (e.key === 'Enter' && !isImeKey(e))) (e.target as HTMLInputElement).blur();
            }}
          />
          <kbd onClick={() => setPalette(true)}>Ctrl K</kbd>
        </div>
      </header>

      <Sidebar
        view={view}
        onNav={(v) => {
          setView(v);
          if (v.kind !== 'all') setQuery('');
        }}
        projects={projects}
        summary={summary}
        jobs={jobs}
        waiting={waiting}
        onOpenFolder={() => api.openFolder()}
        onMove={moveItems}
      />

      <main className={`content view-${view.kind}`}>
        {view.kind === 'inbox' && (
          <InboxView
            batches={batches}
            summary={summary}
            verify={verify}
            onReview={(b) => setView({ kind: 'review', session: b.dir, title: b.title ?? '', back: { kind: 'inbox' } })}
            onUnassigned={() => setView({ kind: 'project', id: 'inbox' })}
            onOpenItem={(r) => {
              setView({ kind: 'project', id: r.project_id });
              setFilter('inbox');
              setFocus(r.uid);
              setSelected(new Set([r.uid]));
            }}
            onAction={act}
            projectName={projectName}
            mac={platform === 'mac'}
          />
        )}
        {listView && (
          <div className="items-split">
            <section className="items">
              {header}
              <div className="filters">
                <div className="seg" role="tablist">
                  {FILTERS.map((f) => (
                    <button key={f} role="tab" aria-selected={!query && filter === f} className={!query && filter === f ? 'on' : ''} onClick={() => { setFilter(f); setQuery(''); }}>
                      {t(`list.filter.${f}`)}
                    </button>
                  ))}
                </div>
                <span className="grow" />
                {KINDS.map((k) => (
                  <button key={k} className={`fchip ${kinds.includes(k) ? 'on' : ''}`} aria-pressed={kinds.includes(k)} aria-label={t(`kind.${k}`)} title={t(`kind.${k}`)}
                    onClick={() => setKinds((ks) => (ks.includes(k) ? ks.filter((x) => x !== k) : [...ks, k]))}>
                    <KindIcon kind={k} size={14} />
                  </button>
                ))}
              </div>
              {selected.size > 1 && (
                <div className="bulk" role="toolbar">
                  <b>{plural('list.selected', selected.size)}</b>
                  <button className="primary" onClick={() => setDispatch(selectedUids)}><Icon name="send" size={14} />{t('act.dispatch')}</button>
                  <button onClick={() => api.handoff(selectedUids, false).then(() => toast.show(t('act.copied')), cb.onError)}><Icon name="copy" size={14} />{t('handoff.copy_instruction')}</button>
                  <select value="" aria-label={t('list.move')} onChange={(e) => e.target.value && moveItems(selectedUids, e.target.value)}>
                    <option value="">{t('list.move')}</option>
                    {projects?.projects.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                    <option value="inbox">{t('project.inbox')}</option>
                  </select>
                  <span className="grow" />
                  <button className="link" onClick={() => setSelected(new Set(focus ? [focus] : []))}>{t('list.clear')}</button>
                </div>
              )}
              {missing ? (
                <div className="blank">
                  {status?.uv ? t('list.no_index') : t('list.no_uv')}
                  <button onClick={() => api.rescan()}>{t('list.rebuild')}</button>
                </div>
              ) : !items.length ? (
                <div className="blank">{query ? t('list.empty.search', { q: query }) : t('list.empty')}</div>
              ) : (
                <>
                  <ItemList rows={items} selected={selected} focus={focus} showProject={view.kind === 'all'} projectName={projectName} onSelect={select}
                    onOpen={(r) => r.session_dir && setView({ kind: 'review', session: r.session_dir, title: '', back: view })}
                    onAction={act} mac={platform === 'mac'} />
                  <div className="list-foot">
                    <span className="dim small" data-testid="total">{plural('list.count', total)}</span>
                    {total > items.length && <button className="link" onClick={() => setLimit((l) => l + PAGE)}>{t('list.more', { n: total - items.length })}</button>}
                  </div>
                </>
              )}
            </section>
            <aside className="detail" data-testid="detail">
              {current && host ? (
                <>
                  <div className="detail-bar">
                    <span className="pkey">{current.project_key}</span>
                    <span className="dim small">{current.project_name}</span>
                    <span className="grow" />
                    {current.session_dir && (
                      <button className="link" onClick={() => setView({ kind: 'review', session: current.session_dir!, title: '', back: view })}>{t('detail.review_batch')}</button>
                    )}
                    <button className="link" onClick={() => api.reveal(current.path)}><Icon name="reveal" size={14} />{t('detail.reveal')}</button>
                  </div>
                  <ReviewPane host={host} hostKey={`${current.project_id}`} opts={{ mode: 'item', itemId: current.uid, platform, theme: 'auto', lang }} />
                </>
              ) : (
                <div className="blank">{t('detail.pick')}</div>
              )}
            </aside>
          </div>
        )}
        {view.kind === 'review' && reviewHost && (
          <section className="review-full" data-testid="review-mode">
            <div className="detail-bar">
              <button className="link" onClick={() => setView(view.back)}><Icon name="arrow-left" size={14} />{t(view.back.kind === 'inbox' ? 'nav.inbox' : 'nav.all')} <kbd>Esc</kbd></button>
            </div>
            <ReviewPane host={reviewHost} hostKey={view.session} opts={{ mode: 'review', platform, theme: 'auto', lang }} />
          </section>
        )}
        {view.kind === 'sessions' && (
          <SessionsView job={view.job} onPick={(job) => setView({ kind: 'sessions', job })} projects={projects?.projects ?? []} onToast={toast.show} />
        )}
        {view.kind === 'settings' && status && (
          <section className="pad">
            <SettingsView status={status} onToast={toast.show} onLang={(l) => (l === 'auto' ? api.status().then((s) => relang(s.lang)) : relang(l))} />
          </section>
        )}
      </main>

      {dispatch && (
        <DispatchSheet uids={dispatch} project={dispatchProject} onClose={() => setDispatch(null)} onStarted={(job) => { refresh(); openSession(job); }} onToast={toast.show} />
      )}
      {palette && (
        <Palette
          onClose={() => setPalette(false)}
          projects={projects?.projects ?? []}
          onPick={(a) => {
            setPalette(false);
            if (a.startsWith('item:')) {
              setView({ kind: 'all' });
              setFocus(a.slice(5));
              setSelected(new Set([a.slice(5)]));
            } else if (a.startsWith('project:')) setView({ kind: 'project', id: a.slice(8) });
            else if (a === 'record') record();
            else if (a === 'open_folder') api.openFolder();
            else setView({ kind: a } as View);
          }}
        />
      )}
      {toast.msg && <div className="shell-toast" role="status">{toast.msg}</div>}
    </div>
  );
}

function Palette({ onClose, onPick, projects }: { onClose: () => void; onPick: (action: string) => void; projects: ProjectRow[] }) {
  const [q, setQ] = useState('');
  const [hits, setHits] = useState<ItemRow[]>([]);
  const [ix, setIx] = useState(0);
  const cmds: [string, string, string][] = [
    ['inbox', t('nav.inbox'), 'inbox'],
    ['sessions', t('nav.sessions'), 'terminal'],
    ['all', t('nav.all'), 'list'],
    ['record', t('app.record'), 'record'],
    ['open_folder', t('nav.open_folder'), 'folder-plus'],
    ['settings', t('nav.settings'), 'settings'],
    ...projects.map((p) => [`project:${p.id}`, p.name, 'folder'] as [string, string, string]),
  ];
  useEffect(() => {
    if (!q.trim()) return setHits([]);
    const h = setTimeout(() => api.items({ query: q.trim(), limit: 8 }).then((r) => setHits(r.items)), 80);
    return () => clearTimeout(h);
  }, [q]);
  const list: [string, string, string, string?][] = [
    ...cmds.filter(([, l]) => !q || l.toLowerCase().includes(q.toLowerCase())),
    ...hits.map((h) => [`item:${h.uid}`, h.title, 'document', h.primary_frame ?? undefined] as [string, string, string, string?]),
  ];
  return (
    <div className="overlay" onClick={onClose}>
      <div className="sheet palette" role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()}>
        <input autoFocus value={q} placeholder={t('app.palette')}
          onChange={(e) => { setQ(e.target.value); setIx(0); }}
          onKeyDown={(e) => {
            if (e.key === 'ArrowDown') { e.preventDefault(); setIx((i) => Math.min(list.length - 1, i + 1)); }
            else if (e.key === 'ArrowUp') { e.preventDefault(); setIx((i) => Math.max(0, i - 1)); }
            else if (e.key === 'Enter' && !isImeKey(e) && list[ix]) onPick(list[ix][0]);
            else if (e.key === 'Escape') onClose();
          }} />
        <ul role="listbox">
          {list.map(([a, l, icon, img], i) => (
            <li key={a} role="option" aria-selected={i === ix} className={i === ix ? 'sel' : ''} onMouseEnter={() => setIx(i)} onClick={() => onPick(a)}>
              {img ? <img src={fileSrc(img)} alt="" /> : <Icon name={icon as never} size={16} />}
              {l}
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
