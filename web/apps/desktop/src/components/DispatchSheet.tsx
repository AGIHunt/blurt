// The hand-off panel (the Mac's DispatchPanel.swift): hand items to Claude Code / Codex in a new session — which agent,
// one session for all or one per item, on a separate branch (a worktree) or in the project folder. Every change re-runs
// `sessions.py dispatch --dry-run`, which says what would happen and warns — never blocks — when another session is
// already editing the same folder without a worktree (K5). What does block — an agent that isn't signed in, one too old
// for hand-offs, items already in a running session, no agent, a check that failed — is said once, under the items,
// and the way out takes Start's place as the default (Use Codex / Sign In…, Check Again, Open Its Session, Open Agents
// Settings…, Try Again). Sign-in: the panel opens with what is installed (no probes: fast), probes the chosen agent at
// once (a second or two; Start waits for it) and every agent behind it; the choice never moves under the user. No
// items given = New Session: the project's To Do to pick from, the project as a pop-up at the title's right. The
// project (its default agent, the remembered model, the header) is the items' own. The model sits under › Options.
// Where it runs, for an agent whose desktop app is installed (Claude): Blurt's terminal (recommended) or the desktop
// app, remembered per agent (config sessions.target) — under Options with the model. The desktop app still gets
// Blurt's worktree; Start opens its claude:// link and the footer says once that the user confirms the folder and
// presses Send there. Without the blurt MCP for that agent nothing reports progress: a notice says so (Install… opens
// Settings → Agents, whose installer is the Settings pane's).
import { useEffect, useMemo, useRef, useState } from 'react';
import { KindIcon } from '@blurt/ui/react';
import { api, type AgentModels, type DesktopApp, type DispatchWarning, type ProjectRow } from '../api';
import { t } from '../i18n';
import { agentName, errorWords, parseError, shortVersion, type SessionsError } from '../sessions';
import {
  ChoicePopup, CommandText, ItemLine, KindSummary, Panel, PanelBox, PanelDisclosure, PanelFootnote, PanelNotice, PanelSwitch, refWidth,
  SettingRow, Spinner, StatusDot, type PanelItem,
} from './HandoffKit';

interface AgentChoice {
  id: string;
  name: string;
  loggedOut: boolean;
  fix: string;
}

type Block = { k: 'busy'; job: string } | { k: 'loggedOut' } | { k: 'outdated' } | { k: 'noAgent' } | { k: 'failed'; why: string };
type Phase = { k: 'idle' } | { k: 'checking' } | { k: 'starting' } | { k: 'failed'; why: string };

const OPTIONS_KEY = 'blurt.handoff.optionsOpen';
const ROW_H = 29;

const readOptions = () => {
  try {
    return localStorage.getItem(OPTIONS_KEY) === '1';
  } catch {
    return false;
  }
};

/** "run `claude /login`" → the command, and the sentence without the backticks. */
const fixCommand = (fix: string) => fix.match(/`([^`]+)`/)?.[1] ?? null;
const fixSentence = (fix: string) => fix.replace(/`/g, '');

export function DispatchSheet({ uids, project, onClose, onStarted, onOpenSession, onOpenSettings }: {
  uids: string[];
  /** the current project: seeds New Session's picker; the items' own project wins for a hand-off */
  project: ProjectRow | null;
  onClose: () => void;
  onStarted: (job: string, agent: string) => void;
  /** (unused: the panel says everything itself; kept for callers) */
  onToast?: (msg: string) => void;
  /** Open Its Session (the items are already in one) */
  onOpenSession?: (job: string) => void;
  /** Open Agents Settings… (no agent) */
  onOpenSettings?: (pane: string) => void;
}) {
  const pickItems = uids.length === 0;
  const [items, setItems] = useState<PanelItem[]>(() => uids.map((u) => ({ uid: u, ref: '', title: '', kind: 'issue' })));
  const [itemsOpen, setItemsOpen] = useState(false);
  const [projects, setProjects] = useState<ProjectRow[]>([]);
  const [projectID, setProjectID] = useState<string | null>(pickItems ? project?.id ?? null : null);
  const [candidates, setCandidates] = useState<PanelItem[]>([]);
  const [chosen, setChosen] = useState<Set<string>>(new Set());
  const [loadingCandidates, setLoadingCandidates] = useState(false);
  const [candidatesError, setCandidatesError] = useState<string | null>(null);
  const [hovered, setHovered] = useState<string | null>(null);

  const [agents, setAgents] = useState<AgentChoice[]>([]);
  const [agentsLoaded, setAgentsLoaded] = useState(false);
  const [agent, setAgent] = useState('');
  const [probed, setProbed] = useState<Set<string>>(new Set());
  const [cfg, setCfg] = useState<Record<string, any>>({});
  const [models, setModels] = useState<AgentModels | null>(null);
  const [model, setModel] = useState('');
  const [mode, setMode] = useState<'together' | 'parallel'>('together');
  const [worktree, setWorktree] = useState<'auto' | 'on' | 'off'>('auto');
  const [warnings, setWarnings] = useState<DispatchWarning[]>([]);
  const [preview, setPreview] = useState<{ worktree?: string; branch?: string; project?: string }[]>([]);
  const [phase, setPhase] = useState<Phase>({ k: 'idle' });
  const [checkFailed, setCheckFailed] = useState(false);
  const [busyJob, setBusyJob] = useState<string | null>(null);
  const [outdated, setOutdated] = useState<SessionsError | null>(null);
  const [optionsOpen, setOptionsOpen] = useState(readOptions);
  const [desktopApps, setDesktopApps] = useState<Record<string, DesktopApp>>({});
  const [target, setTarget] = useState<'terminal' | 'desktop'>('terminal');
  const [desktopMCP, setDesktopMCP] = useState<boolean | null>(null);
  const [signIn, setSignIn] = useState<'row' | 'footer' | null>(null);
  const gen = useRef(0);

  // ---- loading: the items (their project), the agents (no probes), the config
  useEffect(() => {
    api.projects().then((p) => setProjects(p.projects), () => {});
    api.desktopApps().then((d) => setDesktopApps(d ?? {}), () => {});
    if (!pickItems) {
      Promise.all(uids.map((u) => api.item(u).catch(() => null))).then((rows) => {
        setItems(uids.map((u, i) => {
          const r = rows[i];
          return { uid: u, ref: r?.item_id ?? '', title: r?.title ?? '', kind: r?.kind ?? 'issue' };
        }));
        setProjectID(rows.find((r) => r?.project_id)?.project_id ?? project?.id ?? null);
      });
    } else if (!project?.id) {
      api.projects().then((p) => setProjectID((cur) => cur ?? (p.current && p.current !== 'auto' ? p.current : p.projects[0]?.id ?? null)), () => {});
    }
    Promise.all([api.detect({ login: false }), api.settings().then((s) => s.config).catch(() => ({}) as Record<string, any>)]).then(
      ([d, c]) => {
        setCfg(c);
        const list = d.agents.filter((a) => a.installed && (a.session ?? a.interactive === 'terminal')).map((a) => ({ id: a.id, name: a.name, loggedOut: a.login === 'logged_out', fix: a.fix }));
        setAgents(list);
        setAgentsLoaded(true);
        // the last one used → the project's default → the global one → the pick → the first set up
        const order = [c?.sessions?.agent, project?.default_agent, c?.record?.default_agent, d.pick, list[0]?.id].filter(Boolean) as string[];
        const first = order.find((id) => list.some((a) => a.id === id && !a.loggedOut)) ?? order.find((id) => list.some((a) => a.id === id)) ?? '';
        setAgent(first);
        // the chosen one alone first (Start waits for it), then every agent: neither moves the choice
        if (first) api.detect({ login: true, ids: [first] }).then(applyLogin, () => {});
        api.detect({ login: true }).then(applyLogin, () => {});
      },
      () => setAgentsLoaded(true),
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const applyLogin = (d: { agents: { id: string; login: string; fix: string; state?: string }[] }) => {
    const by = new Map(d.agents.map((a) => [a.id, a]));
    setAgents((cur) => cur.map((a) => {
      const r = by.get(a.id);
      if (!r) return a;
      const out = r.login === 'logged_out' || r.state === 'logged_out';
      return { ...a, loggedOut: out, fix: out ? r.fix : '' };
    }));
    setProbed((p) => new Set([...p, ...by.keys()]));
  };

  // New Session: the project's To Do
  useEffect(() => {
    if (!pickItems || !projectID) return;
    setLoadingCandidates(true);
    api.items({ project: projectID, state: ['todo'], limit: 500 }).then(
      (r) => {
        const list = r.items.map((i) => ({ uid: i.uid, ref: i.item_id, title: i.title, kind: i.kind }));
        setCandidates(list);
        setCandidatesError(null);
        setChosen((c) => new Set([...c].filter((u) => list.some((x) => x.uid === u))));
      },
      () => {
        setCandidates([]);
        setCandidatesError(t('ses.dispatch.pick.failed'));
      },
    ).finally(() => setLoadingCandidates(false));
  }, [pickItems, projectID]);

  // the chosen agent's models; the pick remembered per project and agent (config sessions.models)
  const modelKey = projectID ?? '_';
  useEffect(() => {
    if (!agent) return;
    let alive = true;
    api.models(agent).then(
      (m) => {
        if (!alive) return;
        setModels(m);
        const saved = cfg?.sessions?.models?.[modelKey]?.[agent] ?? '';
        setModel(m.models.some((x) => x.id === saved) ? saved : '');
      },
      () => alive && (setModels(null), setModel('')),
    );
    return () => {
      alive = false;
    };
  }, [agent, modelKey, cfg]);

  const selected = pickItems ? candidates.filter((c) => chosen.has(c.uid)).map((c) => c.uid) : items.map((i) => i.uid);
  const count = selected.length;
  const chosenAgent = agents.find((a) => a.id === agent);
  const alternative = agents.find((a) => a.id !== agent && !a.loggedOut);
  const loginChecked = probed.has(agent);
  const desktopAvailable = !!agent && !!desktopApps[agent]?.available;
  const desktop = target === 'desktop' && desktopAvailable;
  const appName = desktopApps[agent]?.name ?? 'Claude';
  const projectName = projects.find((p) => p.id === (preview[0]?.project ?? projectID))?.name ?? '';
  const worktreeOn = mode === 'parallel' ? true : worktree !== 'auto' ? worktree === 'on' : preview.length ? !!preview[0]?.worktree : true;
  const concurrent = warnings.find((w) => w.code === 'concurrent_edit');
  const noGit = warnings.some((w) => w.code === 'no_git');
  const branchLocked = mode === 'parallel' && count > 1;
  const sessionsToStart = mode === 'parallel' && count > 1 ? count : 1;

  // the remembered place for this agent (config sessions.target), the terminal when its app isn't installed
  useEffect(() => {
    setTarget(desktopAvailable && cfg?.sessions?.target?.[agent] === 'desktop' ? 'desktop' : 'terminal');
  }, [agent, desktopAvailable, cfg]);

  // ---- the dry run: what would happen, what it warns about
  const checkKey = JSON.stringify([selected, agent, mode, worktree, model, desktop]);
  const check = async () => {
    if (!count || !agent) {
      setWarnings([]);
      setPreview([]);
      return;
    }
    const g = ++gen.current;
    setPhase((p) => (p.k === 'starting' ? p : { k: 'checking' }));
    setBusyJob(null);
    setOutdated(null);
    setCheckFailed(false);
    try {
      const r = await api.dispatch({ items: selected, agent, mode, worktree: mode === 'parallel' ? 'on' : worktree, dryRun: true,
        model: desktop ? undefined : model || undefined, runner: desktop ? 'desktop' : undefined });
      if (g !== gen.current) return;
      setWarnings(r.warnings ?? []);
      setPreview(r.jobs ?? []);
      setDesktopMCP(desktop ? r.mcp ?? null : null);
      setPhase((p) => (p.k === 'checking' ? { k: 'idle' } : p));
    } catch (e) {
      if (g !== gen.current) return;
      const s = parseError(e);
      setWarnings([]);
      setPreview([]);
      setBusyJob(s.code === 'already_dispatched' ? s.job ?? null : null);
      setOutdated(s.code === 'outdated' ? s : null);
      setCheckFailed(true);
      setPhase({ k: 'failed', why: errorWords(e, Object.fromEntries(agents.map((a) => [a.id, a.name]))) });
    }
  };
  useEffect(() => {
    void check();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [checkKey]);

  const block: Block | null = (() => {
    if (phase.k === 'failed') {
      if (busyJob) return { k: 'busy', job: busyJob };
      if (outdated) return { k: 'outdated' };
      if (checkFailed) return { k: 'failed', why: phase.why };
    }
    if (agentsLoaded && !agents.length) return { k: 'noAgent' };
    // the desktop app signs in on its own: the CLI's login only matters in the terminal
    if (!desktop && loginChecked && chosenAgent?.loggedOut) return { k: 'loggedOut' };
    return null;
  })();
  const canStart = count > 0 && !!agent && phase.k !== 'starting' && !checkFailed && (desktop || (loginChecked && !chosenAgent?.loggedOut));

  const toTodo = (() => {
    const w = warnings.find((x) => x.code === 'draft_confirmed');
    if (!w) return 0;
    return Math.max((w.items ?? []).filter((u) => selected.includes(u)).length, count === 1 ? 1 : 0);
  })();

  const start = async () => {
    setPhase({ k: 'starting' });
    const sessions = { ...(cfg.sessions ?? {}), agent };
    if (desktopAvailable) {
      const tg = { ...(sessions.target ?? {}) };
      if (target === 'desktop') tg[agent] = 'desktop';
      else delete tg[agent];
      sessions.target = tg;
    }
    const all = { ...(sessions.models ?? {}) };
    const mine = { ...(all[modelKey] ?? {}) };
    if (model) mine[agent] = model;
    else delete mine[agent];
    all[modelKey] = mine;
    sessions.models = all;
    void api.setSettings({ sessions }).catch(() => {});
    try {
      const r = await api.dispatch({
        items: selected, agent, mode, model: desktop ? undefined : model || undefined, force: !desktop && probed.has(agent),
        runner: desktop ? 'desktop' : undefined,
        worktree: mode === 'parallel' ? 'on' : worktree === 'auto' ? (worktreeOn ? 'on' : 'off') : worktree,
      });
      setPhase({ k: 'idle' });
      const job = r.jobs[0]?.id;
      onClose();
      if (job) onStarted(job, agent);
    } catch (e) {
      const s = parseError(e);
      setBusyJob(s.code === 'already_dispatched' ? s.job ?? null : null);
      setOutdated(s.code === 'outdated' ? s : null);
      setCheckFailed(s.code === 'outdated'); // too old: Start would fail the same way until it's updated
      setPhase({ k: 'failed', why: errorWords(e, Object.fromEntries(agents.map((a) => [a.id, a.name]))) });
    }
  };

  // ---- the parts
  const signInInRow = block?.k === 'loggedOut' && !!alternative;
  const modelName = model ? models?.models.find((m) => m.id === model)?.name ?? model : models?.cli_default ? models.models.find((m) => m.id === models.cli_default)?.name ?? models.cli_default : null;
  const agentSummary = modelName && loginChecked ? t('ses.handoff.agent.model_signed_in', { a: modelName }) : modelName ?? (loginChecked ? t('ses.handoff.agent.signed_in') : t('ses.handoff.agent.ready'));

  const agentDetail = desktop && agents.length ? (
    t('ses.handoff.agent.desktop', { a: appName })
  ) : !agentsLoaded || (agents.length && !loginChecked) ? (
    <span className="hk-quiet"><Spinner /> {t('ses.dispatch.checking_login')}</span>
  ) : !agents.length ? (
    <span className="hk-attn"><StatusDot tone="warn" size={9} /> {t('ses.handoff.agent.none')}</span>
  ) : chosenAgent?.loggedOut ? (
    <span className="hk-attn"><StatusDot tone="warn" size={9} /> {t('ses.handoff.agent.signed_out')}</span>
  ) : (
    agentSummary
  );

  const signInPopover = (
    <div className="hk-popover" role="dialog" aria-label={t('ses.agents.fix.sign_in_title', { a: chosenAgent?.name ?? '' })}>
      <b>{t('ses.agents.fix.sign_in_title', { a: chosenAgent?.name ?? '' })}</b>
      {chosenAgent?.fix && <p>{fixSentence(chosenAgent.fix)}</p>}
      {chosenAgent?.fix && fixCommand(chosenAgent.fix) && <CommandText text={fixCommand(chosenAgent.fix)!} />}
      <p className="dim">{t('ses.agents.fix.then')}</p>
      <div className="hk-foot tight">
        <span className="grow" />
        <button className="hk-default" onClick={() => (setSignIn(null), void api.detect({ login: true }).then(applyLogin, () => {}))}>{t('ses.agents.check_again')}</button>
      </div>
    </div>
  );

  const blockText = (b: Block): string => {
    switch (b.k) {
      case 'busy':
      case 'failed':
        return phase.k === 'failed' ? phase.why : t('ses.error.already_dispatched');
      case 'loggedOut':
        return t('ses.handoff.block.logged_out', { a: chosenAgent?.name ?? '' });
      case 'outdated': {
        const name = chosenAgent?.name ?? agentName(agent);
        if (!outdated?.version || !outdated.need) return t('ses.error.outdated');
        return t('ses.handoff.block.outdated', { a: name, b: outdated.version, c: shortVersion(outdated.need) });
      }
      case 'noAgent':
        return t('ses.handoff.block.no_agent');
    }
  };

  const footnote = (() => {
    if (block) return null; // never a promise next to a Start that isn't there
    if (pickItems && !count) return t('ses.handoff.pick.hint');
    if (desktop) return t('ses.dispatch.desktop.send', { a: appName });
    if (count === 1) {
      const ref = (pickItems ? candidates.find((c) => chosen.has(c.uid)) : items[0])?.ref ?? '';
      return toTodo > 0 && ref ? t('ses.handoff.note.todo.one', { a: ref }) : null;
    }
    if (count > 1) return toTodo > 0 ? t('ses.handoff.note.todo.count', { a: count, b: toTodo }) : t('ses.handoff.items.count', { a: count });
    return null;
  })();

  const wayOut = (b: Block) => {
    switch (b.k) {
      case 'busy':
        return <button className="hk-default" onClick={() => (onClose(), (onOpenSession ?? ((j: string) => onStarted(j, agent)))(b.job))}>{t('ses.dispatch.open_session')}</button>;
      case 'loggedOut':
        return alternative ? (
          <button className="hk-default" onClick={() => setAgent(alternative.id)}>{t('ses.dispatch.use_agent', { a: alternative.name })}</button>
        ) : (
          <span className="hk-pop-anchor">
            <button className="hk-default" onClick={() => setSignIn('footer')}>{t('ses.agents.sign_in')}</button>
            {signIn === 'footer' && signInPopover}
          </span>
        );
      case 'outdated':
        return <button className="hk-default" onClick={() => void check()}>{t('ses.agents.check_again')}</button>;
      case 'noAgent':
        return <button className="hk-default" onClick={() => (onClose(), onOpenSettings?.('agents'))}>{t('ses.handoff.open_agents')}</button>;
      case 'failed':
        return <button className="hk-default" onClick={() => void check()}>{t('ses.overlay.retry')}</button>;
    }
  };

  const otherWarnings = warnings.filter((w) => !['concurrent_edit', 'no_git', 'draft_confirmed'].includes(w.code) && t(`ses.warning.${w.code}`) !== `ses.warning.${w.code}`);
  const concurrentAsk = !!concurrent && !worktreeOn;
  const w = useMemo(() => refWidth(pickItems ? candidates : items), [pickItems, candidates, items]);
  const all = candidates.length > 0 && chosen.size === candidates.length;
  const title = t(pickItems ? 'ses.handoff.title.new' : 'ses.dispatch.title');

  return (
    <Panel label={title} onClose={onClose} busy={phase.k === 'starting'} testId="dispatch-sheet">
      <div className="hk-title-row">
        <h3 className="hk-title">{title}</h3>
        {pickItems ? (
          <ChoicePopup label={t('ses.dispatch.project')} value={projectID ?? ''} choices={projects.map((p) => [p.id, p.name] as [string, string])} onChange={setProjectID} />
        ) : (
          projectName && <span className="hk-title-project" title={projectName}>{projectName}</span>
        )}
      </div>

      {/* what goes */}
      <div className="hk-what">
        {pickItems ? (
          // nothing to choose in this project: the box says so and where to go; no "choose at least one" on top of it
          !loadingCandidates && !candidates.length ? null : <span className="hk-quiet">{count === 0 ? t('ses.dispatch.subtitle.none') : t('ses.handoff.pick.count', { a: count })}</span>
        ) : items.length === 1 ? (
          <ItemLine item={items[0]} />
        ) : (
          <PanelDisclosure title={t('ses.handoff.items.count', { a: items.length })} open={itemsOpen} onToggle={() => setItemsOpen(!itemsOpen)} inset={false}>
            <KindSummary items={items} />
          </PanelDisclosure>
        )}
      </div>
      {pickItems ? (
        <PanelBox className="hk-gap" heading={t('ses.handoff.pick.heading')}
          accessory={candidates.length > 0 && (
            <button className="link hk-small-link" onClick={() => setChosen(all ? new Set() : new Set(candidates.map((c) => c.uid)))}>{t(all ? 'ses.handoff.pick.none' : 'ses.handoff.pick.all')}</button>
          )}>
          <div className="hk-pick" style={candidates.length ? { height: Math.min(candidates.length, 7) * ROW_H } : undefined}>
            {loadingCandidates && !candidates.length ? (
              <div className="hk-row hk-quiet"><Spinner /> {t('ses.handoff.pick.loading')}</div>
            ) : candidatesError ? (
              <div className="hk-row hk-quiet">{candidatesError}</div>
            ) : !candidates.length ? (
              <div className="hk-row hk-quiet">{t('ses.dispatch.pick.empty')}</div>
            ) : null}
            {candidates.map((c) => {
              const on = chosen.has(c.uid);
              const flip = () => setChosen((s) => {
                const n = new Set(s);
                if (on) n.delete(c.uid);
                else n.add(c.uid);
                return n;
              });
              return (
                <div key={c.uid} className="hk-row hk-pick-row" role="checkbox" aria-checked={on} tabIndex={0} aria-label={`${t(`kind.${c.kind}`)} ${c.ref} ${c.title}`}
                  onClick={flip} onKeyDown={(e) => (e.key === ' ' || e.key === 'Enter') && (e.preventDefault(), flip())}
                  onMouseEnter={() => setHovered(c.uid)} onMouseLeave={() => setHovered((h) => (h === c.uid ? null : h))}>
                  <span className="hk-pick-glyph">
                    {on || hovered === c.uid ? <input type="checkbox" tabIndex={-1} checked={on} readOnly aria-hidden="true" /> : <KindIcon kind={c.kind} size={16} />}
                  </span>
                  <span className="hk-item-ref" style={{ width: w }}>{c.ref}</span>
                  <span className="hk-item-title" title={c.title}>{c.title || t('ses.dispatch.untitled')}</span>
                </div>
              );
            })}
          </div>
        </PanelBox>
      ) : (
        itemsOpen && items.length > 1 && (
          <PanelBox className="hk-gap-sm">
            <div style={items.length > 7 ? { maxHeight: 7 * ROW_H, overflowY: 'auto' } : undefined}>
              {items.map((i) => <div key={i.uid} className="hk-row"><ItemLine item={i} width={w} /></div>)}
            </div>
          </PanelBox>
        )
      )}

      {/* notices: under the items, above the settings */}
      {block?.k === 'outdated' && outdated ? (
        <div className="hk-notice-wrap">
          <PanelNotice text={blockText(block)} />
          {outdated.fix && <CommandText text={outdated.fix} />}
        </div>
      ) : block && !(block.k === 'loggedOut' && signInInRow) ? (
        <div className="hk-notice-wrap"><PanelNotice text={blockText(block)} /></div>
      ) : !block && phase.k === 'failed' ? (
        <div className="hk-notice-wrap"><PanelNotice text={phase.why} /></div>
      ) : null}
      {concurrentAsk && <div className="hk-notice-wrap"><PanelNotice text={t('ses.warning.concurrent_edit', { a: projectName })} /></div>}
      {desktop && desktopMCP === false && (
        <div className="hk-notice-wrap">
          <PanelNotice tone="off" text={t('ses.dispatch.desktop.no_mcp', { a: appName })}>
            {onOpenSettings && <button className="hk-small" onClick={() => (onClose(), onOpenSettings('agents'))}>{t('ses.dispatch.desktop.install')}</button>}
          </PanelNotice>
        </div>
      )}
      {otherWarnings.map((x) => (
        <div key={x.code} className="hk-notice-wrap"><PanelNotice tone="off" text={t(`ses.warning.${x.code}`)} /></div>
      ))}

      {/* one box of settings */}
      <PanelBox className="hk-gap">
        <SettingRow title={t('ses.dispatch.agent')} detail={agentDetail}>
          {signInInRow && (
            <span className="hk-pop-anchor">
              <button className="hk-small" onClick={() => setSignIn('row')}>{t('ses.agents.sign_in')}</button>
              {signIn === 'row' && signInPopover}
            </span>
          )}
          {agents.length > 0 && (
            <ChoicePopup label={t('ses.dispatch.agent')} value={agent} testId="dispatch-agent"
              choices={agents.map((a) => [a.id, a.loggedOut && a.id !== agent ? t('ses.dispatch.agent.logged_out', { a: a.name }) : a.name] as [string, string])}
              onChange={setAgent} />
          )}
        </SettingRow>
        {count > 1 && (
          <SettingRow title={t('ses.handoff.mode')} detail={t(mode === 'together' ? 'ses.handoff.mode.together.detail' : 'ses.handoff.mode.parallel.detail')}>
            <ChoicePopup label={t('ses.handoff.mode')} value={mode} onChange={setMode}
              choices={[['together', t('ses.handoff.mode.together')], ['parallel', t('ses.handoff.mode.parallel')]]} />
          </SettingRow>
        )}
        <SettingRow title={t('ses.handoff.branch')}
          detail={noGit ? t('ses.handoff.branch.no_git') : branchLocked ? t('ses.handoff.branch.locked') : t(worktreeOn ? 'ses.handoff.branch.on' : 'ses.handoff.branch.off')}
          help={worktreeOn && !noGit && !branchLocked ? (preview[0]?.branch ? preview[0].branch + '\n' : '') + t('ses.handoff.branch.help') : t('ses.handoff.branch.help')}>
          <PanelSwitch label={t('ses.handoff.branch')} on={worktreeOn && !noGit} disabled={branchLocked || noGit} onChange={(on) => setWorktree(on ? 'on' : 'off')} />
        </SettingRow>
      </PanelBox>

      {/* rare: where it runs, the model */}
      {(desktopAvailable || (!!models?.models.length && !desktop)) && (
        <div className="hk-options">
          <PanelDisclosure title={t('ses.handoff.options')} open={optionsOpen} onToggle={() => {
            const v = !optionsOpen;
            setOptionsOpen(v);
            try {
              localStorage.setItem(OPTIONS_KEY, v ? '1' : '0');
            } catch {
              /* not remembered */
            }
          }} />
          {optionsOpen && (
            <PanelBox>
              {desktopAvailable && (
                <SettingRow title={t('ses.handoff.run_in')} detail={t(desktop ? 'ses.handoff.run_in.desktop.detail' : 'ses.handoff.run_in.terminal.detail')}>
                  <ChoicePopup label={t('ses.handoff.run_in')} value={target} onChange={setTarget} testId="dispatch-target"
                    choices={[['terminal', t('ses.handoff.run_in.terminal')], ['desktop', t('ses.handoff.run_in.desktop', { a: appName })]]} />
                </SettingRow>
              )}
              {!!models?.models.length && !desktop && (
              <SettingRow title={t('ses.dispatch.model')}>
                <ChoicePopup label={t('ses.dispatch.model')} value={model} onChange={setModel} testId="dispatch-model" dividers={[1]}
                  choices={[
                    ['', models.cli_default ? t('ses.handoff.model.default_named', { a: models.models.find((m) => m.id === models.cli_default)?.name ?? models.cli_default }) : t('ses.handoff.model.default')],
                    ...models.models.map((m) => [m.id, m.name] as [string, string]),
                  ]} />
              </SettingRow>
              )}
            </PanelBox>
          )}
        </div>
      )}

      <div className="hk-foot">
        <PanelFootnote text={footnote} busy={phase.k === 'starting' ? t('ses.handoff.starting') : null} />
        <button onClick={onClose}>{t('ses.common.cancel')}</button>
        {block ? (
          wayOut(block)
        ) : concurrentAsk ? (
          <>
            <button onClick={start} disabled={!canStart}>{t('ses.warning.concurrent_edit.continue')}</button>
            <button className="hk-default" onClick={() => setWorktree('on')}>{t('ses.warning.concurrent_edit.use_worktree')}</button>
          </>
        ) : (
          <button className="hk-default" onClick={start} disabled={!canStart} data-testid="dispatch-go">
            {desktop ? t('ses.dispatch.start.desktop', { a: appName }) : sessionsToStart > 1 ? t('ses.handoff.start.many', { a: sessionsToStart }) : t('ses.dispatch.start')}
          </button>
        )}
      </div>
    </Panel>
  );
}
