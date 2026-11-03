// The sessions pane (the Mac's SessionsPane.swift / SessionsViews.swift): the sessions list on the left (grouped by
// project, the state marks, the count under it; hide it and New Session in its own strip), the selected session's
// terminal on the right under a header with its mark, title, state, agent, branch and — one stable set — Open in
// ‹terminal› (a live tmux session only) and ⋯. When the terminal has nothing to show, the overlay does: Connecting…,
// Disconnected (Reconnect), the card a session ends on (how it ended in words, its items, what the agent said last when
// it failed, the one next step: Review Changes… / Restart Session / Show ‹item›, with Take Back and Show Output beside
// it), the desktop card, a failure with Try Again, or the empty state. The pane remembers what it showed
// ($BLURT_HOME/ui/terminal.json), so a relaunched app shows the same session. Embedded in the main window (`embedded`),
// the item list already picks the session: no sessions list, no toggle or compose button in the header.
// On Windows a session always runs in Blurt's own ConPTY (no tmux): no Open in ‹terminal›, and it ends when Blurt quits.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Icon } from '@blurt/icons';
import { KindIcon } from '@blurt/ui/react';
import { menuCase } from '@blurt/ui';
import { api, listen, type AppStatus, type ProjectRow, type SessionRows } from '../api';
import { i18n, t } from '../i18n';
import {
  branchWords, build, countText, endedHint, endedTitle, errorText, errorWords, itemID, itemsWithIt, preferred, tone, toVerify,
  type ItemInfo, type Row,
} from '../sessions';
import { EmptyState } from './EmptyState';
import { FinishSheet } from './FinishSheet';
import { DispatchSheet } from './DispatchSheet';
import { CommandText, Panel, Spinner } from './HandoffKit';
import { Menu, tidy, type MenuAt, type MenuEntry } from './Menu';
import { StatusMark } from './StatusMark';
import { Terminal } from './Terminal';

/** Kept for callers that name an agent the way the list does. */
export { agentName } from '../sessions';

type TermState = 'connecting' | 'attached' | 'detached' | { failed: string };

const HINTS = ['trust', 'hooks'];

/** sessions.py desktop-check, asked once per agent and kept for ten minutes (DesktopApp.continueCheck). */
const CHECK_LIFE = 600_000;
const checks = new Map<string, { at: number; available: boolean; mcp: boolean | null }>();
const asking = new Set<string>();
const WINDOW_GONE = ['merge', 'discard', 'restart', 'take_back'];

export function SessionsView({ job, onPick, projects, onToast, embedded = false, onShowItem, onOpenSettings, openFinish, onFinishShown }: {
  job: string | null;
  onPick: (job: string | null) => void;
  projects: ProjectRow[];
  onToast: (m: string) => void;
  /** in the main window's detail: its item list picks the session (no sessions list here) */
  embedded?: boolean;
  /** Show Items in List / Show ‹item› (the main window reveals it) */
  onShowItem?: (uid: string) => void;
  /** Open Agents Settings… from the hand-off panel */
  onOpenSettings?: (pane: string) => void;
  /** open `job`'s Review Changes sheet as soon as its row is here (the item banner's Review Changes…) */
  openFinish?: boolean;
  onFinishShown?: () => void;
}) {
  const pane = embedded ? 'main' : 'window';
  const [data, setData] = useState<SessionRows | null>(null);
  const [status, setStatus] = useState<AppStatus | null>(null);
  const [listShown, setListShown] = useState(!embedded);
  const [, setTick] = useState(0);
  const [term, setTerm] = useState<TermState>('connecting');
  const [reconnect, setReconnect] = useState(0);
  const [outputShown, setOutputShown] = useState<string | null>(null);
  const [finishing, setFinishing] = useState<string | null>(null);
  const [confirmEnd, setConfirmEnd] = useState<string | null>(null);
  const [newSession, setNewSession] = useState(false);
  const [recovering, setRecovering] = useState<Set<string>>(new Set());
  const [items, setItems] = useState<Record<string, ItemInfo | null>>({});
  const [menu, setMenu] = useState<{ at: MenuAt; entries: MenuEntry[] } | null>(null);
  const [listW, setListW] = useState(250);
  const [continuing, setContinuing] = useState<{ job: string; noMCP: boolean; busy?: boolean } | null>(null);
  const [, setChecked] = useState(0);

  const load = useCallback(() => api.sessionRows().then(setData, () => setData((d) => d ?? { jobs: [], panes: null, terminals: [], preferred_terminal: null, font_size: null })), []);
  useEffect(() => {
    void load();
    api.status().then(setStatus, () => {});
    const off = listen('jobs://changed', () => void load());
    const off2 = listen('index://changed', () => void load());
    // the rows' "2 min. ago", every 30 s
    const iv = setInterval(() => setTick((n) => n + 1), 30_000);
    return () => {
      off();
      off2();
      clearInterval(iv);
    };
  }, [load]);

  const pname = useCallback(
    (id: string, j: { agent: { cwd?: string } }) =>
      id === 'blurt-setup' ? t('ses.setup_session') : projects.find((p) => p.id === id)?.name ?? (id === 'inbox' ? t('ses.unassigned') : (j.agent.cwd ?? '').split(/[\\/]/).filter(Boolean).pop() ?? id),
    [projects],
  );
  const { rows, groups } = useMemo(() => build(data?.jobs ?? [], pname), [data, pname]);
  const cur = rows.find((r) => r.id === job) ?? null;
  useEffect(() => {
    if (openFinish && job && rows.some((r) => r.id === job)) {
      setFinishing(job);
      onFinishShown?.();
    }
  }, [openFinish, job, rows]);

  // nil = the session this pane showed last (if it's still listed), else the one that needs you, else the newest
  useEffect(() => {
    if (!data || job) return;
    const last = data.panes?.[pane];
    const pick = (last && rows.some((r) => r.id === last) ? last : null) ?? preferred(rows)?.id ?? null;
    if (pick) onPick(pick);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [data, job]);
  useEffect(() => {
    setOutputShown(null);
    setTerm('connecting');
    if (job && cur) void api.sessionMemory(job, pane).catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [job]);

  // its items as the index knows them (kind, id, state): the ended card's lines, Take Back, what waits
  const itemKey = cur ? cur.job.items.join(',') + '|' + (data?.jobs.length ?? 0) + (cur.job.updated ?? '') : '';
  useEffect(() => {
    if (!cur) return;
    let alive = true;
    Promise.all(cur.job.items.map((u) => api.item(u).then((r) => [u, r] as const, () => [u, null] as const))).then((pairs) => {
      if (alive) setItems((m) => ({ ...m, ...Object.fromEntries(pairs) }));
    });
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [itemKey]);

  // ---- actions (SessionActions)
  const fail = (e: unknown) => onToast(errorWords(e));
  const desktopName = (agent: string) => data?.desktop?.[agent]?.name ?? 'Claude';
  const goDesktop = (agent: string) => void api.goDesktop(agent).catch(fail);
  /** Continue in Claude Desktop…: only where it can work — the app is installed and can resume, the session is alive
      in Blurt's terminal and has said which conversation it is, and desktop-check said yes. Unknown = hidden. */
  const continueOffered = (r: Row) => {
    const a = r.job.agent;
    const d = data?.desktop?.[a.id];
    if (!d?.available || !d.continue || !r.alive || !['tmux', 'app'].includes(a.runner ?? '') || !a.agent_session_id) return false;
    const c = checks.get(a.id);
    if ((!c || Date.now() - c.at > CHECK_LIFE) && !asking.has(a.id)) {
      asking.add(a.id);
      api.desktopCheck(a.id).then(
        (x) => checks.set(a.id, { at: Date.now(), available: x.available, mcp: x.mcp }),
        () => checks.set(a.id, { at: Date.now(), available: false, mcp: null }),
      ).finally(() => (asking.delete(a.id), setChecked((n) => n + 1)));
    }
    return c?.available === true;
  };
  // ask desktop-check as soon as a session that could continue there is shown (the menu then has its answer)
  useEffect(() => {
    if (cur) continueOffered(cur);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cur?.id, cur?.alive, data?.desktop]);
  const continueDesktop = async (job: string, withoutMcp: boolean) => {
    setContinuing((c) => c && { ...c, busy: true });
    try {
      await api.continueDesktop(job, withoutMcp);
      setContinuing(null);
      await load();
    } catch (e) {
      setContinuing(null);
      fail(e);
      void load();
    }
  };
  const restart = async (id: string) => {
    if (recovering.has(id)) return;
    setRecovering((s) => new Set(s).add(id));
    try {
      const r = await api.restartSession(id);
      await load();
      const n = r.jobs[0]?.id;
      if (n) onPick(n);
    } catch (e) {
      fail(e);
    } finally {
      setRecovering((s) => {
        const n = new Set(s);
        n.delete(id);
        return n;
      });
    }
  };
  const takeBack = async (id: string) => {
    if (recovering.has(id)) return;
    setRecovering((s) => new Set(s).add(id));
    try {
      const r = await api.takeBack(id);
      if (r.has_changes) onToast(t('ses.take_back.changes_kept'));
      await load();
    } catch (e) {
      fail(e);
    } finally {
      setRecovering((s) => {
        const n = new Set(s);
        n.delete(id);
        return n;
      });
    }
  };
  const remove = async (id: string) => {
    await api.sessionMemory(id, null, true).catch(() => {});
    await load();
    if (job === id) onPick(null);
  };
  const markDone = async (uids: string[]) => {
    await api.state(uids, 'done').catch(fail);
    await load();
  };
  const end = async (id: string) => {
    setConfirmEnd(null);
    await api.stopSession(id, true).catch(fail);
    await load();
  };
  const interrupt = async (id: string) => {
    await api.stopSession(id, false).catch(fail);
    await load();
  };
  const openExternal = (id: string, terminal: string | null) => void api.openExternal(id, terminal).catch(fail);

  // ---- what the terminal area shows (TerminalSurface.attach)
  type Mode = 'none' | 'terminal' | 'ended' | 'desktop' | { failed: string };
  const mode: Mode = (() => {
    if (!cur) return 'none';
    if (cur.inDesktop) return 'desktop';
    if (!cur.alive && outputShown !== cur.id) return 'ended';
    const a = cur.job.agent;
    if (cur.isAppRunner && !cur.job.owned && !cur.job.output) return cur.alive ? { failed: t('ses.error.app_runner_lost') } : 'ended';
    if (!cur.isAppRunner && !cur.alive) {
      const gone = cur.job.state === 'cancelled' || WINDOW_GONE.includes(a.finish?.action ?? '');
      if (!a.tmux?.window || gone) return 'ended';
    }
    return 'terminal';
  })();
  const attached = mode === 'terminal' && term === 'attached';
  const platform = status?.platform ?? 'win';

  // ---- the list
  const chrome = (shown: boolean) => (
    <span className="ses-chrome">
      <button className="ses-icon" onClick={() => setListShown(!shown)} title={t(shown ? 'ses.header.hide_list' : 'ses.header.show_list')} aria-label={t(shown ? 'ses.header.hide_list' : 'ses.header.show_list')}>
        <Icon name="sidebar" size={16} />
      </button>
      <button className="ses-icon" onClick={() => setNewSession(true)} title={t('ses.list.new.help')} aria-label={t('ses.list.new')} data-testid="new-session">
        <Icon name="pencil" size={16} />
      </button>
    </span>
  );

  const list = (
    <aside className="ses-list" aria-label={t('ses.window.title')} style={{ width: listW }}>
      <div className="ses-strip">
        <span className="ses-strip-title">{t('ses.window.title')}</span>
        <span className="grow" />
        {chrome(true)}
      </div>
      <div className="ses-rows" role="listbox" aria-label={t('ses.window.title')}>
        {groups.map((g) => (
          <div key={g.id} role="group" aria-label={g.name}>
            <div className="ses-group">{g.name}</div>
            {g.rows.map((r) => (
              <div key={r.id} role="option" aria-selected={r.id === job} tabIndex={0} data-testid="session-row"
                className={`ses-row ${r.id === job ? 'sel' : ''} ${r.alive || r.needsYou ? '' : 'quiet'}`}
                onClick={() => onPick(r.id)} onKeyDown={(e) => (e.key === 'Enter' || e.key === ' ') && (e.preventDefault(), onPick(r.id))}>
                <span className="ses-row-mark"><StatusMark mark={r.mark} /></span>
                <span className="ses-row-txt">
                  <span className="ses-row-top">
                    <b>{r.label}</b>
                    <span className="grow" />
                    <time>{r.since ? i18n().formatRelative(r.since, Date.now(), 'short') : ''}</time>
                  </span>
                  {r.subtitle && <span className="ses-row-sub">{r.subtitle}</span>}
                  <span className="ses-row-state">
                    <span className={`t-${tone(r.mark)}`}>{r.stateText}</span>
                    <span className="faint">·</span>
                    <span>{r.agentName}</span>
                  </span>
                </span>
              </div>
            ))}
          </div>
        ))}
      </div>
      {countText(rows) && <div className="ses-count">{countText(rows)}</div>}
    </aside>
  );

  // ---- the header
  const moreEntries = (r: Row): MenuEntry[] => {
    const a = r.job.agent;
    const folder = a.worktree?.path ?? a.cwd;
    return tidy([
      r.alive && (a.runner === 'desktop'
        ? { label: t('ses.header.go_desktop', { a: desktopName(a.id) }), run: () => goDesktop(a.id) }
        : { label: t('ses.header.interrupt'), run: () => void interrupt(r.id) }),
      r.alive && { label: t(a.runner === 'desktop' ? 'ses.header.end_desktop' : 'ses.header.end'), run: () => setConfirmEnd(r.id) },
      continueOffered(r) && {
        label: t('ses.header.continue_desktop', { a: desktopName(a.id) }),
        run: () => setContinuing({ job: r.id, noMCP: checks.get(a.id)?.mcp === false }),
      },
      r.alive && r.job.agent.status_source === 'watchdog' && { label: t('ses.overlay.restart'), run: () => void restart(r.id) },
      r.alive && { kind: 'separator' },
      !r.alive && !attached && r.hasOutput && { label: t('ses.overlay.show_output'), run: () => setOutputShown(r.id) },
      !r.alive && !attached && r.hasOutput && { kind: 'separator' },
      r.awaitsFinish && r.alive && { label: t('ses.header.review'), run: () => setFinishing(r.id) },
      !!r.job.items.length && !!onShowItem && { label: t('ses.header.show_items'), run: () => onShowItem(r.job.items[0]) },
      !!folder && { label: t(platform === 'gnome' ? 'ses.header.reveal_folder.linux' : 'ses.header.reveal_folder'), run: () => void api.reveal(folder).catch(fail) },
      !!r.job.handoff_path && { label: t('ses.header.open_handoff'), run: () => void api.openPath(r.job.handoff_path!).catch(fail) },
      !!r.job.log && { label: t('ses.header.show_log'), run: () => void api.openPath(r.job.log!).catch(fail) },
    ]);
  };

  const header = (r: Row | null) => {
    const live = r && r.alive && !r.isAppRunner && r.job.agent.runner !== 'desktop';
    const terms = data?.terminals ?? [];
    const pref = terms.find((x) => x.id === data?.preferred_terminal) ?? terms[0];
    return (
      <header className="ses-head" style={{ paddingLeft: !embedded && !listShown ? 12 : undefined }}>
        {!listShown && !embedded && chrome(false)}
        {r ? (
          <>
            <StatusMark mark={r.mark} size={12} />
            <div className="ses-head-txt">
              <div className="ses-head-top">
                <b>{r.label}</b>
                <span className="dim">{r.projectName}</span>
              </div>
              <div className="ses-head-sub">
                {!r.inDesktop && (
                  <>
                    <span className={`t-${tone(r.mark)}`}>{r.stateText}</span>
                    <span className="faint">·</span>
                  </>
                )}
                <span>{r.agentName}</span>
                {!r.job.agent.finish && r.job.agent.worktree?.branch && (
                  <>
                    <span className="faint">·</span>
                    <span className="ses-branch" title={t('ses.header.branch.help', { a: r.job.agent.worktree.branch, b: r.job.agent.worktree.base ?? 'HEAD' })}>
                      <Icon name="git-branch" size={11} />
                      <code>{branchWords(r.job.agent.worktree.branch, r.job.labels.map((l) => l.id))}</code>
                    </span>
                  </>
                )}
                {r.isAppRunner && r.alive && (
                  <>
                    <span className="faint">·</span>
                    <span className="dim" title={t(platform === 'win' ? 'ses.header.app_runner.help.win' : 'ses.header.app_runner.help.linux')}>{t('ses.header.app_runner')}</span>
                  </>
                )}
              </div>
            </div>
            <span className="grow" />
            <span className="ses-head-acts">
              {/* the ended card has the primary Review Changes…; while its output is shown instead, a plain one here */}
              {r.awaitsFinish && !r.alive && attached && (
                <button className="ses-small" onClick={() => setFinishing(r.id)} title={t('ses.header.review.help')}>{t('ses.header.review')}</button>
              )}
              {live && pref && (
                <span className="ses-open" title={t('ses.header.open_external.help')}>
                  <button className="ses-small" onClick={() => openExternal(r.id, pref.id)}>{t('ses.header.open_in', { a: pref.name })}</button>
                  <button className="ses-small ses-split-arrow" aria-label={t('ses.header.open_external.help')} aria-haspopup="menu"
                    onClick={(e) => setMenu({ at: { x: 0, y: 0, anchor: e.currentTarget }, entries: terms.map((x) => ({ label: x.name, run: () => openExternal(r.id, x.id) })) })}>
                    <Icon name="chevron-down" size={10} />
                  </button>
                </span>
              )}
              <button className="ses-icon" aria-label={t('ses.header.more')} title={t('ses.header.more')} aria-haspopup="menu" data-testid="session-more"
                onClick={(e) => setMenu({ at: { x: 0, y: 0, anchor: e.currentTarget }, entries: moreEntries(r) })}>
                <Icon name="more" size={16} />
              </button>
            </span>
          </>
        ) : (
          <span className="dim">{t('ses.header.none')}</span>
        )}
      </header>
    );
  };

  // one plain line while the agent waits at a startup question its terminal shows
  const hint = cur && cur.alive && cur.job.agent.status === 'waiting_input' && HINTS.includes(cur.job.agent.waiting_hint ?? '') ? (
    <div className="ses-hint" title={t(`ses.hint.${cur.job.agent.waiting_hint}`, { a: cur.agentName })}>
      <Icon name="info" size={13} />
      <span>{t(`ses.hint.${cur.job.agent.waiting_hint}`, { a: cur.agentName })}</span>
    </div>
  ) : null;

  // ---- the overlay's cards
  const itemLines = (r: Row) => {
    const lines = r.job.items.slice(0, 5).map((u, n) => {
      const it = items[u];
      const lab = r.job.labels[n];
      return { uid: u, kind: it?.kind ?? 'issue', id: it?.item_id ?? lab?.id ?? '', title: it?.title ?? lab?.title ?? '' };
    }).filter((l) => l.id || l.title);
    if (!lines.length) return null;
    return (
      <div className="ses-items">
        {lines.map((l) => (
          <div key={l.uid} className="ses-item">
            <KindIcon kind={l.kind} size={16} title={t(`kind.${l.kind}`)} />
            <span className="ses-item-id">{l.id}</span>
            <span className="ses-item-title">{l.title}</span>
          </div>
        ))}
      </div>
    );
  };

  const endedCard = (r: Row) => {
    const o = r.outcome;
    const inFlight = recovering.has(r.id);
    const withIt = itemsWithIt(r, items);
    const why = o.kind === 'failed' ? errorText(r.job, i18n().lang) : null;
    const last = r.job.agent.last_output ?? [];
    const fix = o.kind === 'failed' ? r.job.error?.fix : null;
    const hintText = endedHint(r, items);
    const output = r.hasOutput;
    const showOut = output && <button onClick={() => setOutputShown(r.id)}>{t('ses.overlay.show_output')}</button>;
    let acts: React.ReactNode;
    if (r.job.folder_gone && o.kind === 'review') {
      acts = withIt ? (
        <button className="hk-default" disabled={inFlight} onClick={() => void takeBack(r.id)}>{t('ses.overlay.gone.take_back')}</button>
      ) : (
        <button className="hk-default" onClick={() => void remove(r.id)}>{t('ses.overlay.gone.remove')}</button>
      );
    } else if (o.kind === 'review') {
      // the Mac's FinishPanel row: Take Back and Show Output beside the default Review Changes… (agent-sessions 4.3)
      acts = (
        <>
          {withIt && <button disabled={inFlight} onClick={() => void takeBack(r.id)}>{t('ses.overlay.take_back')}</button>}
          {showOut}
          <button className="hk-default" onClick={() => setFinishing(r.id)}>{t('ses.header.review')}</button>
        </>
      );
    } else if (o.kind === 'failed' || o.kind === 'noChanges' || o.kind === 'ended') {
      acts = (
        <>
          {withIt && <button disabled={inFlight} onClick={() => void takeBack(r.id)}>{t('ses.overlay.take_back')}</button>}
          {showOut}
          {withIt && <button className={o.kind === 'failed' ? 'hk-default' : ''} disabled={inFlight} onClick={() => void restart(r.id)}>{t('ses.overlay.restart')}</button>}
          {inFlight && <Spinner size={14} />}
        </>
      );
    } else if (o.kind === 'finished' && (o.action === 'merge' || o.action === 'pr') && toVerify(r, items).length) {
      const waiting = toVerify(r, items);
      acts = (
        <>
          {showOut}
          {waiting.length === 1 ? (
            <>
              <button onClick={() => void markDone(waiting)}>{menuCase(t('action.done'))}</button>
              <button className="hk-default" onClick={() => onShowItem?.(waiting[0])}>{t('ses.finish.show_item', { a: itemID(waiting[0], r, items) })}</button>
            </>
          ) : (
            <button className="hk-default" onClick={() => onShowItem?.(waiting[0])}>{t('ses.finish.show_items')}</button>
          )}
        </>
      );
    } else {
      acts = showOut;
    }
    return (
      <>
        <StatusMark mark={r.mark} size={24} />
        <h2 className="ses-card-title">{endedTitle(r)}</h2>
        {itemLines(r)}
        {why && <p className="ses-card-body">{why}</p>}
        {o.kind === 'failed' && last.length > 0 && <pre className="ses-last">{last.slice(-8).join('\n')}</pre>}
        {fix && <CommandText text={fix} />}
        {hintText && <p className="ses-card-body">{hintText}</p>}
        <div className="ses-card-acts" data-testid="ended-actions">{acts}</div>
      </>
    );
  };

  const desktopCard = (r: Row) => {
    const a = r.job.agent;
    const app = desktopName(a.id);
    return (
      <>
        <Icon name="window" size={22} />
        <h2 className="ses-card-title">{t('ses.overlay.desktop.title', { a: app })}</h2>
        <p className="ses-card-body">
          {t(a.desktop?.mcp === false ? 'ses.overlay.desktop.body_nomcp' : a.continued?.from ? 'ses.overlay.desktop.body_continued' : 'ses.overlay.desktop.body', { a: app })}
        </p>
        {itemLines(r)}
        <div className="ses-card-acts">
          {a.worktree && <button onClick={() => setFinishing(r.id)}>{t('ses.header.review')}</button>}
          <button className="hk-default" onClick={() => goDesktop(a.id)}>{t('ses.header.go_desktop', { a: app })}</button>
        </div>
      </>
    );
  };

  const overlay = (() => {
    if (!cur) {
      return rows.length ? <div className="ses-card"><p className="dim">{t('ses.overlay.pick')}</p></div> : null;
    }
    if (mode === 'ended') return <div className="ses-card" data-testid="ended-card">{endedCard(cur)}</div>;
    if (mode === 'desktop') return <div className="ses-card">{desktopCard(cur)}</div>;
    if (typeof mode === 'object') {
      return (
        <div className="ses-card">
          <span className="t-attn"><Icon name="warning" size={20} /></span>
          <p className="ses-card-body selectable">{mode.failed}</p>
          <div className="ses-card-acts">
            <button onClick={() => (setTerm('connecting'), setReconnect((n) => n + 1), void load())}>{t('ses.overlay.retry')}</button>
          </div>
        </div>
      );
    }
    if (term === 'attached') return null;
    if (term === 'connecting') {
      return (
        <div className="ses-card fade">
          <Spinner size={16} />
          <p className="dim">{t('ses.overlay.connecting')}</p>
        </div>
      );
    }
    if (term === 'detached') {
      return (
        <div className="ses-card">
          <span className="dim"><Icon name="restart" size={22} /></span>
          <h2 className="ses-card-title sm">{t('ses.overlay.detached.title')}</h2>
          <p className="ses-card-body">{t('ses.overlay.detached.body')}</p>
          <div className="ses-card-acts">
            <button className="hk-default" onClick={() => (setTerm('connecting'), setReconnect((n) => n + 1))}>{t('ses.overlay.reconnect')}</button>
          </div>
        </div>
      );
    }
    return (
      <div className="ses-card">
        <span className="t-attn"><Icon name="warning" size={20} /></span>
        <p className="ses-card-body selectable">{term.failed}</p>
        <div className="ses-card-acts">
          <button onClick={() => (setTerm('connecting'), setReconnect((n) => n + 1))}>{t('ses.overlay.retry')}</button>
        </div>
      </div>
    );
  })();

  const latest = useRef(cur);
  latest.current = cur;

  // ---- the pane
  const noSessions = data != null && !rows.length;
  const dispatch = newSession && (
    <DispatchSheet uids={[]} project={projects.find((p) => p.id === cur?.projectID) ?? null} onClose={() => setNewSession(false)}
      onStarted={(id) => void load().then(() => onPick(id))} onOpenSession={(id) => onPick(id)} onOpenSettings={onOpenSettings} />
  );
  if (noSessions) {
    // no sessions: the list steps aside; the empty state is the one story (its middle at about 40 % of the pane)
    return (
      <div className="ses-empty">
        <EmptyState title={t('ses.overlay.empty.title')} body={t('ses.overlay.empty.body')} testId="sessions-empty">
          <button className="hk-default ses-large" onClick={() => setNewSession(true)}>{t('ses.list.new')}</button>
        </EmptyState>
        {dispatch}
      </div>
    );
  }
  const finishRow = finishing ? rows.find((r) => r.id === finishing) : null;
  return (
    <div className={`ses-split ${embedded ? 'embedded' : ''}`}>
      {listShown && !embedded && (
        <>
          {list}
          <div className="ses-divider" role="separator" aria-orientation="vertical"
            onMouseDown={(e) => {
              const x0 = e.clientX;
              const w0 = listW;
              const move = (ev: MouseEvent) => setListW(Math.min(340, Math.max(220, w0 + ev.clientX - x0)));
              const up = () => (removeEventListener('mousemove', move), removeEventListener('mouseup', up));
              addEventListener('mousemove', move);
              addEventListener('mouseup', up);
            }} />
        </>
      )}
      <section className="ses-main">
        {header(cur)}
        {hint}
        <div className="ses-body">
          {cur && mode === 'terminal' && (
            <Terminal key={`${cur.id}:${reconnect}:${outputShown === cur.id ? 'o' : 'l'}`} job={cur.id} fontSize={data?.font_size}
              onAttached={() => setTerm('attached')}
              onExit={() => {
                // the client ended while the session lives on (tmux): Disconnected; else it's over — the rows say how
                if (latest.current?.alive && !latest.current.isAppRunner) setTerm('detached');
                void load();
              }}
              onError={(e) => setTerm({ failed: errorWords(e) })} />
          )}
          {overlay && <div className="ses-overlay">{overlay}</div>}
        </div>
      </section>
      {menu && <Menu at={menu.at} entries={menu.entries} onClose={() => setMenu(null)} />}
      {finishRow && (
        <FinishSheet row={finishRow} items={items} onClose={() => setFinishing(null)} onShowItem={onShowItem} onChanged={() => void load()} />
      )}
      {continuing && (() => {
        // say first what changes (the terminal here closes, live status stops, progress comes from the agent); without
        // the blurt MCP for the app, that the items then need marking by hand, with Install… (Settings → Agents)
        const r = rows.find((x) => x.id === continuing.job);
        const app = desktopName(r?.job.agent.id ?? '');
        return (
          <Panel label={t('ses.continue_desktop.title', { a: app })} onClose={() => setContinuing(null)} width={380} busy={continuing.busy}>
            <b className="hk-alert-title">{t('ses.continue_desktop.title', { a: app })}</b>
            <p className="hk-alert-body">{t(continuing.noMCP ? 'ses.continue_desktop.body_nomcp' : 'ses.continue_desktop.body', { a: app })}</p>
            <div className="hk-foot">
              {continuing.busy && <Spinner />}
              <span className="grow" />
              <button disabled={continuing.busy} onClick={() => setContinuing(null)}>{t('ses.common.cancel')}</button>
              {continuing.noMCP && onOpenSettings && (
                <button disabled={continuing.busy} onClick={() => (setContinuing(null), onOpenSettings('agents'))}>{t('ses.dispatch.desktop.install')}</button>
              )}
              <button className="hk-default" disabled={continuing.busy} onClick={() => void continueDesktop(continuing.job, continuing.noMCP)}>
                {t('ses.continue_desktop.confirm')}
              </button>
            </div>
          </Panel>
        );
      })()}
      {confirmEnd && (() => {
        const r = rows.find((x) => x.id === confirmEnd);
        const desktop = r?.job.agent.runner === 'desktop';
        return (
          <Panel label={t(desktop ? 'ses.end_desktop.title' : 'ses.end.title')} onClose={() => setConfirmEnd(null)} width={360}>
            <b className="hk-alert-title">{t(desktop ? 'ses.end_desktop.title' : 'ses.end.title')}</b>
            <p className="hk-alert-body">{desktop ? t('ses.end_desktop.body', { a: desktopName(r?.job.agent.id ?? '') }) : t('ses.end.body')}</p>
            <div className="hk-foot">
              <span className="grow" />
              {/* Windows: a destructive confirm defaults to Cancel (Enter doesn't end a session by accident) */}
              <button data-default data-autofocus onClick={() => setConfirmEnd(null)}>{t('ses.common.cancel')}</button>
              <button className="danger" onClick={() => void end(confirmEnd)}>{t(desktop ? 'ses.end_desktop.confirm' : 'ses.end.confirm')}</button>
            </div>
          </Panel>
        );
      })()}
      {dispatch}
    </div>
  );
}
