// The main window (§2.1): toolbar · sidebar (inbox, all items, sessions, agent runs, projects, settings) · items table
// with filters and search · item detail (the review component in mode=item). R opens the session in review mode.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { api, fileSrc, invoke, listen, type AppStatus, type ItemQuery, type ItemRow, type SessionRow, type Summary, type Workspace } from './api';
import { tauriHost } from './host';
import { ReviewPane } from './components/ReviewPane';
import { SettingsView } from './components/SettingsView';
import { AgentsView } from './components/AgentsView';
import { isImeKey } from './review/ime';
import { ago, debounce, egg, inField, kindIcon, setLang, t } from './util';

type View = 'inbox' | 'items' | 'sessions' | 'agents' | 'settings' | 'review';
const KINDS = ['issue', 'idea', 'note', 'task'] as const;
const FIX_FILTERS: [string, string, string][] = [
  ['any', '全部', 'Any'],
  ['none', '未交给 agent', 'Not handed off'],
  ['fixing', '修复中', 'Fixing'],
  ['fixed', '已修', 'Fixed'],
  ['wontfix', '不修', "Won't fix"],
  ['reopened', '重新打开', 'Reopened'],
];
const STATUS_FILTERS: [string, string, string][] = [
  ['open', '待处理 + 已确认', 'Draft + confirmed'],
  ['draft', '待处理', 'Draft'],
  ['confirmed', '已确认', 'Confirmed'],
  ['deleted', '已删除', 'Deleted'],
];
const PAGE = 200;

function useToast() {
  const [msg, setMsg] = useState<string | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const show = useCallback((m: string) => {
    setMsg(m);
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setMsg(null), 4500);
  }, []);
  return { msg, show };
}

function Highlight({ text }: { text: string }) {
  // snippet(): matches are wrapped in [ ]
  const parts = text.split(/(\[[^\]]*\])/g);
  return <>{parts.map((p, i) => (p.startsWith('[') && p.endsWith(']') ? <mark key={i}>{p.slice(1, -1)}</mark> : p))}</>;
}

function FixBadge({ state }: { state: string | null }) {
  if (!state) return null;
  const label = { fixing: t('修复中', 'fixing'), fixed: t('已修', 'fixed'), wontfix: t('不修', "won't fix"), reopened: t('重开', 'reopened') }[state] ?? state;
  return <span className={`fix fix-${state}`}>{state === 'fixed' ? '✓ ' : state === 'fixing' ? '● ' : ''}{label}</span>;
}

function SessionList({ rows, onReview, onProcess, onReveal }: {
  rows: SessionRow[]; onReview: (s: SessionRow) => void; onProcess: (s: SessionRow) => void; onReveal: (s: SessionRow) => void;
}) {
  if (!rows.length) return <div className="empty">{t('这里是空的。录一段或截几张图，会出现在这里。', 'Nothing here. Record or snap something and it shows up here.')}</div>;
  return (
    <ul className="sessions" data-testid="sessions">
      {rows.map((s) => {
        const e = egg(s);
        return (
          <li key={s.id} onDoubleClick={() => s.processed && onReview(s)}>
            <span className={e.cls} title={e.label}>{e.icon}</span>
            <div className="s-main">
              <div className="s-title">{s.title || s.dir.split(/[\\/]/).pop()}</div>
              <div className="dim small">
                {s.workspace_name} · {s.mode === 'shots' ? `${s.shot_count} ${t('张截图', 'shots')}` : s.duration ? `${Math.round(s.duration)}s` : t('录屏', 'video')} ·{' '}
                {s.item_count} {t('条', 'items')}{s.fixed_count ? ` · ${s.fixed_count} ${t('已修', 'fixed')}` : ''} · {ago(s.created)}
              </div>
            </div>
            <span className="dim small">{e.label}</span>
            {!s.processed && !s.processing && <button onClick={() => onProcess(s)}>{t('整理', 'Process')} ↩</button>}
            {!!s.processed && <button onClick={() => onReview(s)}>{t('审核', 'Review')}</button>}
            <button className="link" onClick={() => onReveal(s)}>{t('打开文件夹', 'Show folder')}</button>
          </li>
        );
      })}
    </ul>
  );
}

const KEYMAP: [string, string, string][] = [
  ['Ctrl+K', '命令面板', 'Command palette'],
  ['/', '搜索', 'Search'],
  ['J / K', '下一条 / 上一条', 'Next / previous'],
  ['↩', '打开', 'Open'],
  ['Ctrl+↩', '交给 agent', 'Hand to an agent'],
  ['E', '编辑标题', 'Edit title'],
  ['1–4', '改 kind', 'Set kind'],
  ['S', '改状态', 'Cycle status'],
  ['R', '审核模式', 'Review mode'],
  ['?', '键位表', 'This list'],
];

export default function App() {
  const [status, setStatus] = useState<AppStatus | null>(null);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [workspaces, setWorkspaces] = useState<Workspace[]>([]);
  const [view, setView] = useState<View>('items');
  const [workspace, setWorkspace] = useState<string | undefined>();
  const [kinds, setKinds] = useState<string[]>([]);
  const [statusF, setStatusF] = useState('open');
  const [fixF, setFixF] = useState('any');
  const [query, setQuery] = useState('');
  const [items, setItems] = useState<ItemRow[]>([]);
  const [total, setTotal] = useState(0);
  const [missing, setMissing] = useState(false);
  const [limit, setLimit] = useState(PAGE);
  const [sel, setSel] = useState<string | null>(null);
  const [sessions, setSessions] = useState<SessionRow[]>([]);
  const [review, setReview] = useState<{ dir: string; title: string } | null>(null);
  const [palette, setPalette] = useState(false);
  const [help, setHelp] = useState(false);
  const [capture, setCapture] = useState<{ recording: boolean; picking?: boolean }>({ recording: false });
  const [scanning, setScanning] = useState(false);
  const [tick, setTick] = useState(0);
  const [recordKey, setRecordKey] = useState('');
  const toast = useToast();
  const searchRef = useRef<HTMLInputElement>(null);

  const platform = status?.platform ?? 'win';
  const refresh = useMemo(() => debounce(() => setTick((n) => n + 1), 150), []);

  useEffect(() => {
    api.status().then((s) => {
      setLang(s.lang);
      setStatus(s);
      setCapture(s.capture);
      document.documentElement.dataset.platform = s.platform;
      const sv = s.start_view;
      if (sv?.startsWith('review:')) {
        setReview({ dir: sv.slice(7), title: '' });
        setView('review');
      } else if (sv && ['items', 'inbox', 'sessions', 'agents', 'settings'].includes(sv)) setView(sv as View);
    });
    const offs = [
      listen('index://changed', refresh),
      listen<{ scanning: boolean; error?: string }>('index://status', (p) => {
        setScanning(p.scanning);
        if (p.error) toast.show(p.error);
      }),
      listen<{ ev: string; msg?: string; session?: string }>('capture://status', (p) => {
        if (p.ev === 'started') setCapture({ recording: true });
        else if (p.ev === 'picking') setCapture({ recording: false, picking: true });
        else if (['stopped', 'discarded', 'cancelled'].includes(p.ev)) setCapture({ recording: false });
        if (p.ev === 'error' && p.msg) toast.show(p.msg);
        if (p.ev === 'stopped') { toast.show(t('录制已保存到收件箱', 'Recording saved to the inbox')); refresh(); }
      }),
      listen<{ item?: string; session?: string }>('nav', async (p) => {
        if (p.item) {
          setView('items');
          setWorkspace(undefined);
          setQuery('');
          setSel(p.item);
        } else if (p.session) {
          setReview({ dir: p.session, title: p.session.split(/[\\/]/).pop() ?? '' });
          setView('review');
        }
      }),
      listen('agent://exit', refresh),
      listen<{ action: string; label: string }[]>('hotkeys://changed', (rows) => setRecordKey(rows.find((r) => r.action === 'record')?.label ?? '')),
    ];
    api.settings().then((s) => setRecordKey(s.hotkeys.find((r) => r.action === 'record')?.label ?? ''), () => {});
    return () => offs.forEach((o) => o());
  }, []);

  // sidebar data
  useEffect(() => {
    api.summary().then(setSummary);
    api.workspaces().then(setWorkspaces);
  }, [tick]);

  // the items page
  const q: ItemQuery = useMemo(() => {
    const out: ItemQuery = { limit, sort: 'updated' };
    if (query.trim()) out.query = query.trim();
    if (kinds.length) out.kind = kinds;
    if (statusF !== 'open') out.status = [statusF];
    if (fixF !== 'any') out.fix_state = [fixF];
    if (workspace) out.workspace = workspace;
    return out;
  }, [query, kinds, statusF, fixF, workspace, limit]);

  useEffect(() => {
    if (view !== 'items') return;
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
  }, [q, view, tick]);

  useEffect(() => {
    if (view !== 'inbox' && view !== 'sessions') return;
    api.sessions({ state: view === 'inbox' ? 'inbox' : undefined, workspace }).then(setSessions, (e) => toast.show(String(e)));
  }, [view, workspace, tick]);

  // keep a deep-linked item selected even when it isn't on the first page
  const [extra, setExtra] = useState<ItemRow | null>(null);
  useEffect(() => {
    if (sel && !items.some((i) => i.uid === sel)) api.item(sel).then(setExtra);
    else setExtra(null);
  }, [sel, items]);
  const current = items.find((i) => i.uid === sel) ?? (extra?.uid === sel ? extra : null);

  useEffect(() => {
    if (!sel && items.length && view === 'items') setSel(items[0].uid);
  }, [items, sel, view]);

  const fixWithAgent = useCallback(async (session: string, ids: string[]) => {
    try {
      const r = await api.fixWithAgent(session, ids);
      toast.show(t(`已交给 ${r.agent}（${r.run_id}）`, `Handed to ${r.agent} (${r.run_id})`));
      refresh();
    } catch (e) {
      toast.show(String(e));
    }
  }, []);

  const host = useMemo(
    () => (current ? tauriHost(current.session_dir, { onFixWithAgent: fixWithAgent, onError: toast.show }) : null),
    [current?.session_dir, fixWithAgent],
  );
  const reviewHost = useMemo(() => (review ? tauriHost(review.dir, { onFixWithAgent: fixWithAgent, onError: toast.show }) : null), [review?.dir, fixWithAgent]);

  const setItemField = async (row: ItemRow, set: Record<string, unknown>) => {
    try {
      await invoke('review_ops', { session: row.session_dir, ops: [{ op: 'set', id: row.item_id, set }], confirm: false });
      refresh();
    } catch (e) {
      toast.show(String(e));
    }
  };

  const openReview = (dir: string, title: string) => {
    setReview({ dir, title });
    setView('review');
  };

  const record = async () => {
    try {
      if (capture.recording) await api.captureControl('stop');
      else await api.captureStart();
    } catch (e) {
      if (String(e) !== 'cancelled') toast.show(String(e));
    }
  };

  // keyboard (§2.5)
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
        else if (help) setHelp(false);
        else if (view === 'review') setView('items');
        return;
      }
      if (inField(e.target) || isImeKey(e) || palette) return;
      if (view === 'review') return; // the review component has its own keys
      const k = e.key;
      if (k === '/') {
        e.preventDefault();
        setView('items');
        setTimeout(() => searchRef.current?.focus());
      } else if (k === '?') setHelp((h) => !h);
      else if (view === 'items' && (k === 'j' || k === 'k' || k === 'ArrowDown' || k === 'ArrowUp')) {
        const ix = items.findIndex((i) => i.uid === sel);
        const n = items[Math.max(0, Math.min(items.length - 1, ix + (k === 'j' || k === 'ArrowDown' ? 1 : -1)))];
        if (n) {
          setSel(n.uid);
          document.querySelector(`[data-uid="${n.uid}"]`)?.scrollIntoView({ block: 'nearest' });
        }
        e.preventDefault();
      } else if (!current) return;
      else if (k === 'Enter' && mod) fixWithAgent(current.session_dir, [current.item_id]);
      else if (k === 'Enter') (document.querySelector('[data-testid="item-title"]') as HTMLElement | null)?.scrollIntoView({ block: 'nearest' });
      else if (k === 'e' || k === 'E') {
        e.preventDefault();
        (document.querySelector('[data-testid="item-title"]') as HTMLInputElement | null)?.focus();
      } else if ('1234'.includes(k) && k.length === 1) setItemField(current, { kind: KINDS[Number(k) - 1] });
      else if (k === 's' || k === 'S') setItemField(current, { status: current.status === 'draft' ? 'confirmed' : current.status === 'confirmed' ? 'deleted' : 'draft' });
      else if (k === 'r' || k === 'R') openReview(current.session_dir, current.session_title ?? '');
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [items, sel, current, view, palette, help]);

  const nav = (v: View, ws?: string) => {
    setView(v);
    setWorkspace(ws);
  };
  const wsName = (id: string) => workspaces.find((w) => w.id === id)?.name ?? '';

  return (
    <div className="app" data-platform={platform}>
      <header className="toolbar">
        <button className={`rec ${capture.recording ? 'on' : ''}`} onClick={record} data-testid="record" disabled={capture.picking}>
          <span className="dot" /> {capture.recording ? t('结束录制', 'Finish') : t('录制', 'Record')} {recordKey && <kbd>{recordKey}</kbd>}
        </button>
        <button onClick={() => api.captureControl('snap').catch((e) => toast.show(String(e)))} disabled={!capture.recording}>📸 {t('截图', 'Snap')}</button>
        <label className="project">
          {t('项目', 'Project')}
          <select
            value={workspace ?? ''}
            onChange={async (e) => {
              const id = e.target.value || undefined;
              setWorkspace(id);
              const w = workspaces.find((x) => x.id === id);
              await api.setSettings({ record: { workspace: w && w.kind === 'repo' ? w.path : null } }).catch(() => {});
            }}
          >
            <option value="">{t('全部', 'All')}</option>
            {workspaces.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select>
        </label>
        <div className="spacer" />
        {scanning && <span className="dim small">{t('建索引…', 'Indexing…')}</span>}
        {!!summary?.fixing && <span className="pill" onClick={() => nav('agents')}>● {summary.fixing} {t('修复中', 'fixing')}</span>}
        <div className="search">
          <input
            ref={searchRef}
            data-testid="search"
            placeholder={t('搜索条目  /', 'Search items  /')}
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setLimit(PAGE);
              setSel(null);
              if (view !== 'items') setView('items');
            }}
            onKeyDown={(e) => {
              if (e.key === 'Escape') (e.target as HTMLInputElement).blur();
              if (e.key === 'Enter' && !isImeKey(e)) (e.target as HTMLInputElement).blur();
            }}
          />
          <kbd onClick={() => setPalette(true)}>Ctrl K</kbd>
        </div>
      </header>

      <nav className="sidebar">
        <a className={view === 'inbox' ? 'sel' : ''} onClick={() => nav('inbox', workspace)} data-testid="nav-inbox">📥 {t('收件箱', 'Inbox')}<span className="count">{summary?.inbox || ''}</span></a>
        <a className={view === 'items' && !workspace ? 'sel' : ''} onClick={() => nav('items')} data-testid="nav-items">🗂 {t('全部条目', 'All items')}<span className="count">{summary?.items ?? ''}</span></a>
        <a className={view === 'sessions' ? 'sel' : ''} onClick={() => nav('sessions', workspace)}>🎞 {t('会话', 'Sessions')}<span className="count">{summary?.sessions || ''}</span></a>
        <a className={view === 'agents' ? 'sel' : ''} onClick={() => nav('agents')}>🤖 {t('Agent 运行', 'Agent runs')}{summary?.fixing ? <span className="live">●</span> : null}</a>
        <div className="section">{t('项目', 'Projects')}</div>
        {workspaces.map((w) => (
          <a key={w.id} className={view === 'items' && workspace === w.id ? 'sel' : ''} onClick={() => nav('items', w.id)} title={w.path}>
            {w.kind === 'default' ? '🏠' : '📁'} {w.name}<span className="count">{w.open_items || ''}</span>
          </a>
        ))}
        <div className="grow" />
        <a className={view === 'settings' ? 'sel' : ''} onClick={() => nav('settings')} data-testid="nav-settings">⚙ {t('设置', 'Settings')}</a>
      </nav>

      <main className={`content view-${view}`}>
        {view === 'items' && (
          <div className="items-split">
            <section className="items">
              <div className="filters">
                {KINDS.map((k, i) => (
                  <button key={k} className={`chip ${kinds.includes(k) ? 'on' : ''}`} title={`${i + 1}`}
                    onClick={() => setKinds((ks) => (ks.includes(k) ? ks.filter((x) => x !== k) : [...ks, k]))}>
                    {kindIcon(k)} {k}
                  </button>
                ))}
                <select value={statusF} onChange={(e) => setStatusF(e.target.value)} aria-label="status">
                  {STATUS_FILTERS.map(([v, zh, en]) => <option key={v} value={v}>{t(zh, en)}</option>)}
                </select>
                <select value={fixF} onChange={(e) => setFixF(e.target.value)} aria-label="fix state">
                  {FIX_FILTERS.map(([v, zh, en]) => <option key={v} value={v}>{t('修复', 'Fix')}: {t(zh, en)}</option>)}
                </select>
                <span className="dim small total" data-testid="total">{total} {t('条', 'items')}</span>
              </div>
              {missing ? (
                <div className="empty">
                  {status?.uv ? t('还没有索引，正在建…', 'No index yet — building it…') : t('还没有索引。安装 uv 后 Blurt 会自动建索引。', 'No index yet. Install uv and Blurt builds it.')}
                  <button onClick={() => api.rescan()}>{t('重建索引', 'Rebuild index')}</button>
                </div>
              ) : !items.length ? (
                <div className="empty">{query ? t('没有匹配的条目', 'No matching items') : t('没有条目', 'No items')}</div>
              ) : (
                <div className="table" role="grid" data-testid="items">
                  {items.map((r) => (
                    <div key={r.uid} role="row" data-uid={r.uid} data-testid="item-row"
                      className={`row ${r.uid === sel ? 'sel' : ''} st-${r.status} ${r.fix_state === 'fixed' ? 'done' : ''}`}
                      onClick={() => setSel(r.uid)} onDoubleClick={() => openReview(r.session_dir, r.session_title ?? '')}>
                      <span className="kind" title={r.kind}>{kindIcon(r.kind)}</span>
                      <span className="title">
                        {r.title || <i className="dim">{t('（无标题）', '(untitled)')}</i>}
                        {r.snippet && <span className="snippet"><Highlight text={r.snippet} /></span>}
                      </span>
                      <FixBadge state={r.fix_state} />
                      {r.severity && <span className={`sev sev-${r.severity}`}>{r.severity}</span>}
                      <span className="ws dim">{wsName(r.workspace_id)}</span>
                      <span className="age dim">{ago(r.updated)}</span>
                    </div>
                  ))}
                  {total > items.length && <button className="more" onClick={() => setLimit((l) => l + PAGE)}>{t('加载更多', 'Load more')} ({total - items.length})</button>}
                </div>
              )}
            </section>
            <aside className="detail" data-testid="detail">
              {current && host ? (
                <>
                  <div className="detail-bar">
                    <span className="dim small">{current.session_title || current.session_dir.split(/[\\/]/).pop()}</span>
                    <div className="spacer" />
                    <button className="link" onClick={() => openReview(current.session_dir, current.session_title ?? '')}>{t('审核整个会话', 'Review session')} R</button>
                    <button className="link" onClick={() => api.reveal(current.session_dir)}>{t('打开文件夹', 'Folder')}</button>
                  </div>
                  <ReviewPane host={host} hostKey={current.session_dir} opts={{ mode: 'item', itemId: current.item_id, platform: platform === 'mac' ? 'mac' : platform, theme: 'auto' }} />
                </>
              ) : (
                <div className="empty">{current === null && sel ? '' : t('选一条看详情', 'Pick an item')}</div>
              )}
            </aside>
          </div>
        )}
        {(view === 'inbox' || view === 'sessions') && (
          <section className="pad">
            <h2>{view === 'inbox' ? t('收件箱', 'Inbox') : t('会话', 'Sessions')}{workspace ? ` · ${wsName(workspace)}` : ''}</h2>
            <SessionList rows={sessions}
              onReview={(s) => openReview(s.dir, s.title ?? '')}
              onProcess={async (s) => {
                try {
                  const r = await api.processSession(s.dir);
                  toast.show(t(`${r.agent} 正在整理`, `${r.agent} is processing it`));
                } catch (e) {
                  toast.show(String(e));
                }
              }}
              onReveal={(s) => api.reveal(s.dir)} />
          </section>
        )}
        {view === 'agents' && <section className="pad"><AgentsView onToast={toast.show} /></section>}
        {view === 'settings' && status && <section className="pad"><SettingsView status={status} onToast={toast.show} /></section>}
        {view === 'review' && review && reviewHost && (
          <section className="review-full" data-testid="review-mode">
            <div className="detail-bar">
              <button className="link" onClick={() => setView('items')}>← {t('返回', 'Back')} Esc</button>
              <b>{review.title || review.dir.split(/[\\/]/).pop()}</b>
            </div>
            <ReviewPane host={reviewHost} hostKey={review.dir} opts={{ mode: 'review', platform: platform === 'mac' ? 'mac' : platform, theme: 'auto' }} />
          </section>
        )}
      </main>

      {palette && (
        <Palette
          onClose={() => setPalette(false)}
          onPick={(a) => {
            setPalette(false);
            if (a.startsWith('item:')) {
              setView('items');
              setSel(a.slice(5));
            } else if (a === 'record') record();
            else if (a === 'rescan') api.rescan();
            else nav(a as View);
          }}
        />
      )}
      {help && (
        <div className="overlay" onClick={() => setHelp(false)}>
          <div className="sheet keys" onClick={(e) => e.stopPropagation()}>
            <h3>{t('键位', 'Keys')}</h3>
            <table><tbody>{KEYMAP.map(([k, zh, en]) => <tr key={k}><td><kbd>{k}</kbd></td><td>{t(zh, en)}</td></tr>)}</tbody></table>
          </div>
        </div>
      )}
      {toast.msg && <div className="toast" role="status">{toast.msg}</div>}
    </div>
  );
}

function Palette({ onClose, onPick }: { onClose: () => void; onPick: (action: string) => void }) {
  const [q, setQ] = useState('');
  const [hits, setHits] = useState<ItemRow[]>([]);
  const [ix, setIx] = useState(0);
  const cmds: [string, string][] = [
    ['inbox', t('打开收件箱', 'Go to inbox')],
    ['items', t('全部条目', 'All items')],
    ['sessions', t('会话', 'Sessions')],
    ['agents', t('Agent 运行', 'Agent runs')],
    ['settings', t('设置', 'Settings')],
    ['record', t('开始 / 结束录制', 'Start / finish recording')],
    ['rescan', t('重建索引', 'Rebuild the index')],
  ];
  useEffect(() => {
    if (!q.trim()) return setHits([]);
    const h = setTimeout(() => api.items({ query: q.trim(), limit: 8 }).then((r) => setHits(r.items)), 80);
    return () => clearTimeout(h);
  }, [q]);
  const list: [string, string, string?][] = [
    ...cmds.filter(([, l]) => !q || l.toLowerCase().includes(q.toLowerCase())).map(([a, l]) => [a, l] as [string, string]),
    ...hits.map((h) => [`item:${h.uid}`, `${kindIcon(h.kind)} ${h.title}`, h.primary_frame ?? undefined] as [string, string, string?]),
  ];
  return (
    <div className="overlay" onClick={onClose}>
      <div className="sheet palette" onClick={(e) => e.stopPropagation()}>
        <input autoFocus value={q} placeholder={t('输入命令或搜索条目…', 'Type a command or search items…')}
          onChange={(e) => { setQ(e.target.value); setIx(0); }}
          onKeyDown={(e) => {
            if (e.key === 'ArrowDown') { e.preventDefault(); setIx((i) => Math.min(list.length - 1, i + 1)); }
            else if (e.key === 'ArrowUp') { e.preventDefault(); setIx((i) => Math.max(0, i - 1)); }
            else if (e.key === 'Enter' && !isImeKey(e) && list[ix]) onPick(list[ix][0]);
            else if (e.key === 'Escape') onClose();
          }} />
        <ul>
          {list.map(([a, l, img], i) => (
            <li key={a} className={i === ix ? 'sel' : ''} onMouseEnter={() => setIx(i)} onClick={() => onPick(a)}>
              {img && <img src={fileSrc(img)} alt="" />}{l}
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
