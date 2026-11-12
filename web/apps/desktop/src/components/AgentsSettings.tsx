// Settings → Agents (the Mac's Settings/AgentsPane.swift, all of it): which agent Blurt uses and whether it works.
//   lead        the rule (the first agent that works, from the top) with Check Again at its end
//   the list    one compact row per installed agent, in the order Blurt tries them (drag a row, or Move Up / Down in
//               its ⋯ menu): its status mark (§3.3: ok only for one known to run, attn = needs you, err = nothing can
//               run, a hollow ring = off / not installed / nothing to check), its name and In use, a neutral state
//               ("Not signed in") with its version and ⓘ, the one fix it needs (Sign In… / Install… / Get X… /
//               Connect…) and a switch (record.agents). The ⋯ menu (and the right-click menu): Details…, Test, Connect
//               Skill and MCP…, Move Up / Down, Check Again. Agents that aren't installed: one folded line at the foot.
//   Organizing  one shared model (the agent's default / the cheapest) and effort for recordings and for snaps and
//               voice notes (record.agent_processing["*"] and each agent that follows it); an agent set differently
//               keeps its own, named in the footnote, changed in its Details sheet ("Default (Haiku)").
//   other apps  installed agent apps Blurt can't run (Cursor, WorkBuddy): Connect… adds blurt to them.
//   Ask         the closing footnote with Examples… (three requests, copyable).
// Connect (agents.py install) always shows its dry run first; nothing is written before the user says Connect.
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Icon } from '@blurt/icons';
import { api, type AgentInfo, type AgentModels, type AgentRegistry, type InstallChange, type InstallPlan } from '../api';
import { i18n } from '../i18n';
import { Group, InfoTip, Page, Popup, S, Switch, TextLink, lang } from '../settings/kit';

type Kind = 'recording' | 'cards';
const KINDS: Kind[] = ['recording', 'cards'];
const SHARED = '*';
const shippedModel = (k: Kind) => (k === 'recording' ? 'default' : 'cheapest');
const SHIPPED_EFFORT = 'low';
type Spec = { model?: string; effort?: string };

/** One kind's {model, effort} out of a processing spec (per kind, or v0.8's one {model, effort}) — ProcessingSpec.of. */
function specOf(spec: unknown, k: Kind): Spec {
  if (!spec || typeof spec !== 'object') return {};
  const d = spec as Record<string, any>;
  if (d[k] && typeof d[k] === 'object') return { model: d[k].model, effort: d[k].effort };
  return { model: typeof d.model === 'string' ? d.model : undefined, effort: typeof d.effort === 'string' ? d.effort : undefined };
}
/** The user's spec with one kind changed (undefined = back to the default); per kind always. */
function withKind(over: unknown, k: Kind, model?: string, effort?: string): Record<string, Spec> | undefined {
  const out: Record<string, Spec> = {};
  for (const x of KINDS) {
    const c = specOf(over, x);
    if (c.model || c.effort) out[x] = c;
  }
  const mine: Spec = {};
  if (model) mine.model = model;
  if (effort) mine.effort = effort;
  if (mine.model || mine.effort) out[k] = mine;
  else delete out[k];
  return Object.keys(out).length ? out : undefined;
}

/** "2.1.259 (Claude Code)" → "2.1.259" */
const shortVersion = (v: string) => v.match(/\d+\.\d+(\.\d+)?/)?.[0] ?? v.slice(0, 16);
const isCommand = (s: string) => s.includes('`') || ['npm ', 'curl ', 'brew ', 'pip ', 'uv ', 'npx ', 'winget ', 'irm '].some((p) => s.startsWith(p));
const commandOf = (s: string) => s.match(/`([^`]+)`/)?.[1] ?? s;
function siteOf(s: string): string | null {
  if (isCommand(s)) return null;
  const m = s.match(/(https?:\/\/)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(\/[^\s，。)）]*)?/);
  return m ? (m[0].startsWith('http') ? m[0] : `https://${m[0]}`) : null;
}
function sentence(s: string): string {
  const t = s.replace(/`/g, '').trim();
  if (!t) return t;
  const ascii = /^[\x00-\x7f]/.test(t);
  return t[0].toUpperCase() + t.slice(1) + (t.endsWith('.') || t.endsWith('。') || !ascii ? '' : '.');
}

type Tone = 'good' | 'warn' | 'bad' | 'off' | 'busy';
function Dot({ tone }: { tone: Tone }) {
  // still checking: a spinner — an empty ring on every row read as radio buttons beside the switches
  if (tone === 'busy') return <span className="st-dot busy" aria-hidden><span className="st-spin" /></span>;
  return <span className={`st-dot ${tone}`} aria-hidden>{tone === 'good' ? <Icon name="check" size={9} /> : tone === 'warn' ? '!' : tone === 'bad' ? '×' : null}</span>;
}

function stateText(a: AgentInfo): string {
  if (!a.headless) return S(a.installed ? 'agents.state.manual' : 'agents.state.not_installed');
  const known = ['not_installed', 'ready', 'checking', 'unknown', 'configured', 'logged_out'];
  return known.includes(a.state) ? S(`agents.state.${a.state}`) : a.why || S('agents.state.unknown');
}
function shortState(a: AgentInfo): string {
  if (!a.headless) return S(a.installed ? 'agents.state.installed' : 'agents.state.not_installed');
  return a.state === 'unknown' || a.state === 'configured' ? S('agents.state.unchecked') : stateText(a);
}
function stateHelp(a: AgentInfo): string | undefined {
  if (!a.installed) return undefined;
  if (!a.headless) return S('agents.state.manual.help');
  return a.state === 'unknown' || a.state === 'configured' ? S('agents.state.unchecked.help') : undefined;
}

// ------------------------------------------------------------------ the model

function useAgents(cfg: Record<string, any>, save: (patch: Record<string, unknown>) => Promise<void>, onToast: (m: string) => void) {
  const [rows, setRows] = useState<AgentInfo[]>([]);
  const [enabled, setEnabled] = useState<Set<string>>(new Set());
  const [pick, setPick] = useState<string | null>(null);
  const [signInChecked, setSignInChecked] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [reg, setReg] = useState<AgentRegistry | null>(null);
  const [models, setModels] = useState<Record<string, AgentModels>>({});
  const [connected, setConnected] = useState<Record<string, boolean>>({});
  const [tests, setTests] = useState<Record<string, { ok: boolean; text: string }>>({});
  const [testing, setTesting] = useState<string | null>(null);
  const [installing, setInstalling] = useState<string | null>(null);
  const [plan, setPlan] = useState<{ agent: AgentInfo; plan: InstallPlan; applied: boolean } | null>(null);
  const order: string[] | undefined = cfg.record?.agents;
  const processing: Record<string, unknown> = cfg.record?.agent_processing ?? {};
  const def = (id: string) => reg?.agents.find((d) => d.id === id);

  const defIds = useRef<string[] | null>(null);
  /** bumped by every save: a check that started before it read the old config and mustn't set the switches back */
  const saves = useRef(0);
  const load = useCallback(async (login = true) => {
    setLoading(true);
    const at = saves.current;
    try {
      // every agent, not only the configured order: one switched off has to stay listed so it can be switched back on
      // (as the Mac's detectAll). Registry ids plus record.agent_defs; configured order first, then the rest.
      defIds.current ??= (await api.agentsRegistry()).agents.map((a) => a.id);
      const ids = [...new Set([...defIds.current, ...Object.keys(cfg.record?.agent_defs ?? {})])];
      const d = await api.detect({ login, ids });
      const pos = new Map(d.order.map((id, i) => [id, i]));
      const rank = (id: string) => pos.get(id) ?? 1000 + ids.indexOf(id);
      d.agents.sort((a, b) => rank(a.id) - rank(b.id));
      let fresh = d.agents;
      if (!login) {
        // a quick look can't tell who is signed in: keep what the last full check found
        setRows((old) => {
          const known = new Map(old.map((r) => [r.id, r]));
          fresh = fresh.map((r) => {
            const o = known.get(r.id);
            // the quick look starts no CLI (no version, no sign-in): both come from the last full check
            if (o?.state === 'checking' && r.installed && r.state === 'unknown') return { ...r, state: 'checking', version: r.version ?? o.version };
            return o && o.installed === r.installed && o.state !== 'unknown' ? { ...r, state: o.state, why: o.why, fix: o.fix, login: o.login, version: r.version ?? o.version } : r;
          });
          return fresh;
        });
      } else setRows(fresh);
      if (at === saves.current) setPick(['ready', 'configured', 'unknown'].map((want) => d.order.find((id) => fresh.some((a) => a.id === id && a.headless && a.state === want))).find(Boolean) ?? d.pick);
      // d.order is what the config file says right now (record.agents, else every headless agent) — not `order`, which
      // this callback may hold from before the save that called it
      if (at === saves.current) setEnabled(new Set(d.order));
      if (login) setSignInChecked(true);
      setError(null);
      for (const a of fresh.filter((x) => x.headless && x.installed)) {
        api.models(a.id).then((m) => m.models?.length && setModels((x) => ({ ...x, [a.id]: m })), () => {});
      }
      return fresh;
    } catch (e) {
      setError(String(e));
      setRows((r) => r.map((x) => (x.state === 'checking' ? { ...x, state: 'unknown' } : x)));
      return null;
    } finally {
      setLoading(false);
    }
  }, [cfg.record?.agent_defs]);

  const checkConnected = useCallback(async (list: AgentInfo[]) => {
    for (const a of list.filter((x) => x.installed)) {
      try {
        const p = await api.agentsInstall(a.id, true);
        setConnected((c) => ({ ...c, [a.id]: !p.changes.some((x) => ['symlink', 'run', 'json_merge'].includes(x.action)) }));
      } catch {
        /* unknown: no Connect state */
      }
    }
  }, []);

  const opened = useRef(false);
  useEffect(() => {
    if (opened.current) return;
    opened.current = true;
    api.agentsRegistry().then((r) => {
      setReg(r);
      // the first frame: the registry's agents in the saved order, each "Checking…"
      setRows((cur) => (cur.length ? cur : [...r.agents]
        .sort((a, b) => ((order ?? []).indexOf(a.id) + 1 || 1000) - ((order ?? []).indexOf(b.id) + 1 || 1000))
        .map((d) => ({ id: d.id, name: d.name, path: null, state: 'checking', why: '', fix: '', installed: false, version: null, login: 'unknown', headless: d.headless !== false, interactive: null }))));
    }, () => {});
    (async () => {
      await load(false);
      const full = await load(true);
      if (full) await checkConnected(full);
    })();
  }, [load, checkConnected, order]);

  const headless = rows.filter((r) => r.headless);
  const manual = rows.filter((r) => !r.headless);

  /** record.agents = the ticked headless agents in the shown order */
  const saveOrder = async (list: AgentInfo[], en: Set<string>) => {
    const ids = list.filter((a) => a.headless && en.has(a.id)).map((a) => a.id);
    saves.current += 1;
    await save({ record: { agents: ids.length ? ids : null } });
    load(false);
  };
  const move = (id: string, to: number) => {
    const h = [...headless];
    const from = h.findIndex((a) => a.id === id);
    if (from < 0 || to < 0 || to >= h.length) return;
    const [x] = h.splice(from, 1);
    h.splice(to, 0, x);
    const next = [...h, ...manual];
    setRows(next);
    saveOrder(next, enabled);
  };
  const toggle = (id: string, on: boolean) => {
    const en = new Set(enabled);
    if (on) en.add(id);
    else en.delete(id);
    setEnabled(en);
    saveOrder(rows, en);
  };
  const recheck = async () => {
    setConnected({});
    const full = await load(true);
    if (full) await checkConnected(full);
  };

  // organizing
  const shipped = (id: string, k: Kind) => {
    const b = specOf(def(id)?.processing, k);
    return { model: b.model ?? shippedModel(k), effort: b.effort ?? SHIPPED_EFFORT };
  };
  const sharedSetting = (k: Kind) => {
    const o = specOf(processing[SHARED], k);
    return { model: o.model ?? shippedModel(k), effort: o.effort ?? SHIPPED_EFFORT };
  };
  const modelOf = (id: string, k: Kind) => specOf(processing[id], k).model ?? shipped(id, k).model;
  const effortOf = (id: string, k: Kind) => specOf(processing[id], k).effort ?? shipped(id, k).effort;
  const followsModel = (id: string, k: Kind) => modelOf(id, k) === sharedSetting(k).model;
  const followsEffort = (id: string, k: Kind) => effortOf(id, k) === sharedSetting(k).effort;
  const writeProcessing = (next: Record<string, unknown>) => save({ record: { agent_processing: Object.keys(next).length ? next : null } });
  /** one agent's value (its shipped default stored as nothing, so a better default later reaches everyone) */
  const setOne = (p: Record<string, unknown>, id: string, k: Kind, model?: string, effort?: string) => {
    const base = shipped(id, k);
    const m = model ?? specOf(p[id], k).model;
    const e = effort ?? specOf(p[id], k).effort;
    const v = withKind(p[id], k, m === base.model ? undefined : m, e === base.effort ? undefined : e);
    if (v) p[id] = v;
    else delete p[id];
  };
  const setProcessing = (id: string, k: Kind, model?: string, effort?: string) => {
    const p = { ...processing };
    setOne(p, id, k, model, effort);
    writeProcessing(p);
  };
  /** a new shared choice: every agent that followed the old one follows the new one */
  const setShared = (k: Kind, model?: string, effort?: string) => {
    const old = sharedSetting(k);
    const p = { ...processing };
    for (const a of headless) {
      if (model && modelOf(a.id, k) === old.model) setOne(p, a.id, k, model, undefined);
      if (effort && effortOf(a.id, k) === old.effort) setOne(p, a.id, k, undefined, effort);
    }
    const m = model ?? old.model;
    const e = effort ?? old.effort;
    const v = withKind(p[SHARED], k, m === shippedModel(k) ? undefined : m, e === SHIPPED_EFFORT ? undefined : e);
    if (v) p[SHARED] = v;
    else delete p[SHARED];
    writeProcessing(p);
  };
  const ownSettings = headless.filter((a) => a.installed && KINDS.some((k) => !followsModel(a.id, k) || !followsEffort(a.id, k)));
  const sharedEfforts = useMemo(() => {
    const known = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max'];
    const all = new Set(Object.values(models).flatMap((m) => m.efforts ?? []));
    const list = known.filter((e) => all.has(e));
    return list.length ? list : ['low', 'medium', 'high'];
  }, [models]);

  // Connect and Test
  const preview = async (a: AgentInfo) => {
    setInstalling(a.id);
    try {
      setPlan({ agent: a, plan: await api.agentsInstall(a.id, true), applied: false });
    } catch (e) {
      setError(String(e));
    }
    setInstalling(null);
  };
  const apply = async () => {
    if (!plan) return;
    setInstalling(plan.agent.id);
    try {
      const p = await api.agentsInstall(plan.agent.id, false);
      setPlan({ agent: plan.agent, plan: p, applied: true });
      if (p.applied) setConnected((c) => ({ ...c, [plan.agent.id]: true }));
    } catch (e) {
      setError(String(e));
    }
    setInstalling(null);
  };
  const test = async (a: AgentInfo) => {
    setTesting(a.id);
    try {
      const r = await api.agentsTest(a.id);
      const reason = (cls?: string | null) => {
        const f = reg?.failures.find((x) => x.id === cls);
        const text = f?.reason[lang() === 'zh-Hans' ? 'zh' : 'en'];
        const fix = def(a.id)?.fix?.[lang() === 'zh-Hans' ? 'zh' : 'en'] ?? '';
        if (!text) return S('agents.test.failed', a.name);
        const t = text.replace('{name}', a.name);
        return t.includes('{fix}') ? (fix ? t.replace('{fix}', fix.replace(/`/g, '')) : t.split('{fix}')[0].replace(/[：:—– ]+$/, '')) : t;
      };
      setTests((x) => ({
        ...x,
        [a.id]: r.ok
          ? { ok: true, text: S('agents.test.ok', i18n().formatNumber(r.secs ?? 0, { minimumFractionDigits: 1, maximumFractionDigits: 1 })) }
          : { ok: false, text: r.timeout ? S('agents.test.timeout') : r.class === 'no_command' ? S('agents.test.no_command') : reason(r.class) },
      }));
    } catch (e) {
      setTests((x) => ({ ...x, [a.id]: { ok: false, text: String(e) } }));
    }
    setTesting(null);
  };
  void onToast;
  return {
    rows, headless, manual, enabled, pick, signInChecked, loading, error, reg, def, models, connected, tests, testing, installing, plan, setPlan,
    move, toggle, recheck, preview, apply, test, sharedSetting, setShared, setProcessing, modelOf, effortOf, followsModel, followsEffort, ownSettings, sharedEfforts,
  };
}
type Model = ReturnType<typeof useAgents>;

// ------------------------------------------------------------------ the pane

export function AgentsPane({ cfg, save, onToast }: { cfg: Record<string, any>; save: (patch: Record<string, unknown>) => Promise<void>; onToast: (m: string) => void }) {
  const m = useAgents(cfg, save, onToast);
  const [details, setDetails] = useState<string | null>(null);
  const [fixFor, setFixFor] = useState<string | null>(null);
  const [showMissing, setShowMissing] = useState(false);
  const [menu, setMenu] = useState<{ id: string; x: number; y: number; alignEnd?: boolean } | null>(null);
  const [drag, setDrag] = useState<{ id: string; over: string | null } | null>(null);
  const checked = m.signInChecked && !m.rows.some((r) => r.state === 'checking');
  const listed = m.headless.filter((a) => a.installed || a.state === 'checking');
  const missing = m.rows.filter((a) => !a.installed && a.state !== 'checking');
  const apps = m.manual.filter((a) => a.installed);
  const on = (a: AgentInfo, ordered: boolean) => !ordered || m.enabled.has(a.id);
  const tone = (a: AgentInfo, ordered: boolean): Tone => {
    if (a.state === 'checking') return 'busy';
    if (!a.installed) return 'off';
    if (!ordered) return m.connected[a.id] ? 'good' : 'off';
    if (!on(a, ordered)) return 'off';
    if (a.state === 'ready') return 'good';
    if (a.state === 'configured' || a.state === 'unknown') return 'off';
    if (a.state === 'logged_out') return !m.pick && checked ? 'bad' : 'warn';
    return 'warn';
  };
  const needsSignIn = (a: AgentInfo, ordered: boolean) => ordered && a.installed && on(a, true) && a.state === 'logged_out';
  const L = lang() === 'zh-Hans' ? 'zh' : 'en';

  const menuItems = (a: AgentInfo, ordered: boolean): ({ label: string; run: () => void; disabled?: boolean } | null)[] => {
    const i = m.headless.findIndex((x) => x.id === a.id);
    return [
      ...(a.headless && a.installed ? [{ label: S('agents.details'), run: () => setDetails(a.id) }, { label: S('agents.test'), run: () => m.test(a), disabled: !!m.testing }] : []),
      ...(a.installed ? [m.connected[a.id] ? { label: S('agents.connected.menu'), run: () => {}, disabled: true } : { label: S('agents.connect.menu'), run: () => m.preview(a), disabled: !!m.installing }] : []),
      ...(needsSignIn(a, ordered) ? [{ label: S('agents.sign_in'), run: () => setFixFor(a.id) }] : []),
      ...(!a.installed && a.headless ? [{ label: S('agents.install_cli'), run: () => setFixFor(a.id) }] : []),
      ...(ordered && a.installed && m.headless.filter((x) => x.installed).length > 1 ? [null, { label: S('agents.move_up'), run: () => m.move(a.id, i - 1), disabled: i === 0 }, { label: S('agents.move_down'), run: () => m.move(a.id, i + 1), disabled: i >= m.headless.length - 1 || !m.headless[i + 1]?.installed }] : []),
      null,
      { label: S('agents.check_again'), run: () => m.recheck(), disabled: m.loading },
    ];
  };

  const fixButton = (a: AgentInfo, ordered: boolean) => {
    if (needsSignIn(a, ordered)) return <button className="st-small" onClick={() => setFixFor(a.id)}>{S('agents.sign_in')}</button>;
    if (!a.installed && a.state !== 'checking') {
      const text = m.def(a.id)?.install?.[L] ?? '';
      const site = !a.headless ? siteOf(text) : null;
      if (site) return <button className="st-small" title={site} onClick={() => api.openUrl(site)}>{S('agents.get_app', a.name)}</button>;
      return <button className="st-small" onClick={() => setFixFor(a.id)}>{S('agents.install_cli')}</button>;
    }
    if (!a.headless && a.installed && !m.connected[a.id]) return <button className="st-small" title={S('agents.install.help')} onClick={() => m.preview(a)}>{S('agents.install')}</button>;
    return null;
  };

  const row = (a: AgentInfo, ordered: boolean) => {
    const t = m.tests[a.id];
    const version = a.version && a.installed ? shortVersion(a.version) : null;
    const help = stateHelp(a);
    const dragging = drag?.id && drag.over === a.id && drag.id !== a.id;
    const below = dragging && m.headless.findIndex((x) => x.id === drag!.id) < m.headless.findIndex((x) => x.id === a.id);
    return (
      <div key={a.id} className={`st-row st-agent ${dragging ? (below ? 'drop-below' : 'drop-above') : ''}`} data-testid={`agent-${a.id}`}
        draggable={ordered && a.installed}
        onDragStart={(e) => {
          e.dataTransfer.setData('text/plain', a.id);
          setDrag({ id: a.id, over: null });
        }}
        onDragOver={(e) => {
          if (!drag || !ordered) return;
          e.preventDefault();
          if (drag.over !== a.id) setDrag({ ...drag, over: a.id });
        }}
        onDragEnd={() => setDrag(null)}
        onDrop={(e) => {
          e.preventDefault();
          const id = e.dataTransfer.getData('text/plain');
          setDrag(null);
          if (id && id !== a.id) m.move(id, m.headless.findIndex((x) => x.id === a.id));
        }}
        onContextMenu={(e) => {
          e.preventDefault();
          setMenu({ id: a.id, x: e.clientX, y: e.clientY });
        }}
        onDoubleClick={() => a.headless && a.installed && setDetails(a.id)}>
        <span className="st-icon">
          <Dot tone={tone(a, ordered)} />
          {ordered && a.installed && <span className="st-handle" title={S('agents.drag')} aria-hidden><Icon name="lines" size={12} /></span>}
        </span>
        <div className="st-text">
          <div className="st-row-title">
            <span className={on(a, ordered) && (a.installed || a.state === 'checking') ? 'st-name' : 'st-name dim'}>{a.name}</span>
            {ordered && a.id === m.pick && checked && <span className="st-badge">{S('agents.in_use')}</span>}
          </div>
          {t && <div className={`st-detail ${t.ok ? 'st-ok' : 'st-err'}`}>{t.text}</div>}
        </div>
        <div className="st-ctl">
          {m.installing === a.id || m.testing === a.id ? (
            <span className="st-detail">{S(m.testing === a.id ? 'agents.test' : 'agents.install')}…</span>
          ) : (
            <button className="link st-more" aria-label={S('agents.more.named', a.name)} onClick={(e) => {
              const r = e.currentTarget.getBoundingClientRect();
              setMenu({ id: a.id, x: r.right, y: r.bottom + 4, alignEnd: true });
            }}><Icon name="more" size={14} /></button>
          )}
          <span className="st-detail">{shortState(a)}</span>
          {version && <span className="st-detail st-faint" title={S('agents.details.version', version)}>{version}</span>}
          {help && <InfoTip text={help} />}
          {fixButton(a, ordered)}
          {ordered && (a.installed || a.state === 'checking') && (
            <span title={S(m.enabled.has(a.id) ? 'agents.use.on.help' : 'agents.use.off.help')}>
              <Switch on={m.enabled.has(a.id)} set={(v) => m.toggle(a.id, v)} label={S('agents.use', a.name)} />
            </span>
          )}
        </div>
        {fixFor === a.id && <FixPopover m={m} a={a} install={!a.installed} close={() => setFixFor(null)} />}
      </div>
    );
  };

  const organizeFooter = [S('agents.organize.footer'), m.ownSettings.length ? S('agents.organize.own', i18n().formatList(m.ownSettings.map((a) => a.name))) : ''].filter(Boolean).join(' ');
  const menuAgent = menu ? m.rows.find((r) => r.id === menu.id) : null;

  return (
    <Page id="agents" lead={<>
      <span>{S('agents.lead')}</span>
      <span className="st-lead-end">
        {m.loading && <span className="st-detail">{S('agents.state.checking')}</span>}
        <TextLink onClick={() => m.recheck()}>{S('agents.check_again')}</TextLink>
      </span>
    </>}>
      <Group id="agents.list" title="" footer={m.error ? <span className="st-warn">{m.error}</span> : undefined}>
        {listed.map((a) => row(a, true))}
        {missing.length > 0 && (
          <button className="st-row st-missing" aria-expanded={showMissing} onClick={() => setShowMissing((x) => !x)}>
            <span className="st-icon"><Icon name={showMissing ? 'chevron-down' : 'chevron-right'} size={12} /></span>
            <span className="st-dim">{S('agents.missing')}</span>
            {!showMissing && <span className="st-detail st-ellipsis">{missing.length > 4 ? S('agents.missing.more', i18n().formatList(missing.slice(0, 3).map((a) => a.name)), missing.length - 3) : i18n().formatList(missing.map((a) => a.name))}</span>}
          </button>
        )}
        {showMissing && missing.map((a) => row(a, a.headless))}
      </Group>

      <Group id="agents.organize" footer={organizeFooter} accessory={<span className="st-cols"><span>{S('agents.details.model')}</span><span>{S('agents.effort')}</span></span>}>
        {KINDS.map((k) => {
          const cur = m.sharedSetting(k);
          return (
            <div key={k} className="st-row" data-setting={k === 'recording' ? 'agents.organize' : undefined}>
              <div className="st-text" title={S(`agents.processing.${k}.help`)}>{S(`agents.organize.${k}`)}</div>
              <div className="st-ctl">
                <Popup label={S(`agents.processing.${k}`)} value={cur.model} choices={[['default', S('agents.processing.default')], ['cheapest', S('agents.processing.cheapest')]]} onChange={(v) => m.setShared(k, v)} />
                <Popup label={S('agents.effort')} value={cur.effort} dividers={[1]} choices={[['default', S('agents.effort.default')], ...m.sharedEfforts.map((e) => [e, S(`agents.effort.${e}`)] as [string, string])]}
                  onChange={(v) => m.setShared(k, undefined, v)} />
              </div>
            </div>
          );
        })}
      </Group>

      {apps.length > 0 && (
        <Group id="agents.manual" title={S('agents.manual.header')} footer={S('agents.manual.footer')}>
          {apps.map((a) => row(a, false))}
        </Group>
      )}

      <AskNote />

      {menu && menuAgent && (
        <ContextMenu x={menu.x} y={menu.y} alignEnd={menu.alignEnd} items={menuItems(menuAgent, menuAgent.headless)} close={() => setMenu(null)} />
      )}
      {details && <DetailSheet m={m} id={details} close={() => setDetails(null)} onSignIn={(id) => setFixFor(id)} />}
      {m.plan && <InstallSheet m={m} close={() => m.setPlan(null)} />}
    </Page>
  );
}

function ContextMenu({ x, y, alignEnd, items, close }: { x: number; y: number; alignEnd?: boolean; items: ({ label: string; run: () => void; disabled?: boolean } | null)[]; close: () => void }) {
  const el = useRef<HTMLDivElement>(null);
  const [at, setAt] = useState<{ left: number; top: number } | null>(null);
  useLayoutEffect(() => {
    const r = el.current?.getBoundingClientRect();
    if (!r) return;
    const left = Math.max(8, Math.min(alignEnd ? x - r.width : x, innerWidth - 8 - r.width));
    const top = y + r.height > innerHeight - 8 ? Math.max(8, (alignEnd ? y - 8 - r.height - 24 : y - r.height)) : y;
    setAt({ left, top });
  }, [x, y, alignEnd]);
  useEffect(() => {
    const k = (e: KeyboardEvent) => e.key === 'Escape' && close();
    const c = () => close();
    window.addEventListener('keydown', k);
    setTimeout(() => window.addEventListener('mousedown', c), 0);
    return () => {
      window.removeEventListener('keydown', k);
      window.removeEventListener('mousedown', c);
    };
  }, [close]);
  return (
    <div ref={el} className="st-menu" role="menu" style={at ? { left: at.left, top: at.top } : { left: -9999, top: -9999 }} onMouseDown={(e) => e.stopPropagation()}>
      {items.map((it, i) =>
        it ? (
          <button key={i} role="menuitem" disabled={it.disabled} onClick={() => (close(), it.run())}>{it.label}</button>
        ) : (
          <div key={i} className="st-menu-sep" />
        ),
      )}
    </div>
  );
}

/** How to sign in to an agent, or to install it: its own words (agents.json), its command copyable, or its site. */
function FixPopover({ m, a, install, close }: { m: Model; a: AgentInfo; install: boolean; close: () => void }) {
  const L = lang() === 'zh-Hans' ? 'zh' : 'en';
  const d = m.def(a.id);
  const text = install ? d?.install?.[L] ?? '' : a.fix || d?.fix?.[L] || '';
  // the command that signs in: from the English text, where agents.json marks commands (both languages copy one)
  const cmd = install ? (isCommand(text) ? commandOf(text) : null) : [d?.fix?.en ?? '', a.fix].find((s) => s.includes('`'));
  const site = install && !cmd ? siteOf(text) : null;
  return (
    <div className="st-popover" role="dialog" onMouseDown={(e) => e.stopPropagation()}>
      <div className="st-pop-title">{S(install ? 'agents.fix.install_title' : 'agents.fix.sign_in_title', a.name)}</div>
      {install ? (
        cmd ? (<><div>{S('agents.fix.run')}</div><Command text={cmd} /></>) : site ? (<><div>{S('agents.fix.site')}</div><TextLink ink onClick={() => api.openUrl(site)}>{site.replace(/^https?:\/\//, '')}</TextLink></>) : <div>{text}</div>
      ) : (
        <><div>{sentence(text)}</div>{cmd && <Command text={commandOf(cmd)} />}</>
      )}
      <div className="st-detail">{S('agents.fix.then')}</div>
      <div className="st-ctl" style={{ justifyContent: 'flex-end' }}>
        <button onClick={close}>{S('action.cancel')}</button>
        <button className="primary" onClick={() => (close(), m.recheck())}>{S('agents.check_again')}</button>
      </div>
    </div>
  );
}

function Command({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <span className="st-cmdrow">
      <code className="st-cmd">{text}</code>
      <button className="link" aria-label={S('settings.kit.copy')} onClick={() => api.copyText(text).then(() => (setCopied(true), setTimeout(() => setCopied(false), 1500)))}>
        <Icon name={copied ? 'check' : 'copy'} size={13} />
      </button>
    </span>
  );
}

/** Ask your agent: the page's closing footnote, with Examples… — three requests, each copyable. The examples are a
 *  flyout anchored to the link (the Mac's popover with its arrow on "Examples…"): it opens above the link when there
 *  isn't room below — at the page foot, nearly always — stays 12 px inside the window, and closes on a click outside
 *  or Esc (no Done). A request copies with a click on its line; the copy mark shows on hover and turns to a check. */
function AskNote() {
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState<string | null>(null);
  const [pos, setPos] = useState<{ left: number; top: number; arrow: number; up: boolean } | null>(null);
  const wrap = useRef<HTMLDivElement>(null);
  const pop = useRef<HTMLDivElement>(null);
  const quoted = (s: string) => (lang() === 'zh-Hans' ? `「${s}」` : `“${s}”`);
  useLayoutEffect(() => {
    if (!open) return setPos(null);
    const link = wrap.current?.querySelector<HTMLElement>('.st-link');
    const p = pop.current;
    if (!link || !p) return;
    const place = () => {
      const a = link.getBoundingClientRect();
      const r = p.getBoundingClientRect();
      const m = 12;
      const below = innerHeight - a.bottom - m;
      const up = below < r.height + 10 && a.top - m > below;
      const top = up ? Math.max(m, a.top - 10 - r.height) : Math.min(innerHeight - m - r.height, a.bottom + 10);
      const cx = a.left + a.width / 2;
      const left = Math.min(Math.max(m, cx - r.width / 2), innerWidth - m - r.width);
      setPos({ left, top, arrow: Math.min(Math.max(16, cx - left), r.width - 16), up });
    };
    place();
    const down = (e: MouseEvent) => {
      if (!(e.target as HTMLElement).closest?.('.st-flyout, .st-ask-link')) setOpen(false);
    };
    const key = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        setOpen(false);
      }
    };
    addEventListener('mousedown', down, true);
    addEventListener('keydown', key, true);
    addEventListener('resize', place);
    return () => {
      removeEventListener('mousedown', down, true);
      removeEventListener('keydown', key, true);
      removeEventListener('resize', place);
    };
  }, [open]);
  const copy = (k: string) => api.copyText(S(k)).then(() => {
    setCopied(k);
    setTimeout(() => setCopied((c) => (c === k ? null : c)), 1500);
  });
  return (
    <div ref={wrap} className="st-about" data-setting="agents.ask" data-kind="section">
      <span>{S('agents.ask.line')}</span>
      <span className="st-ask-link"><TextLink ink onClick={() => setOpen((o) => !o)}>{S('agents.ask.examples')}</TextLink></span>
      {open && createPortal(
        <div ref={pop} className={`st-popover st-flyout ${pos?.up ? 'up' : 'down'}`} role="dialog" aria-label={S('agents.ask.header')}
          style={pos ? { left: pos.left, top: pos.top, ['--arrow' as string]: `${pos.arrow}px` } : { left: -9999, top: -9999 }}>
          <div className="st-pop-title">{S('agents.ask.header')}</div>
          {['agents.ask.1', 'agents.ask.2', 'agents.ask.3'].map((k) => (
            <button key={k} type="button" className={`st-example ${copied === k ? 'copied' : ''}`} title={S('agents.ask.copy')} onClick={() => copy(k)}>
              <span>{quoted(S(k))}</span>
              <Icon name={copied === k ? 'check' : 'copy'} size={14} />
            </button>
          ))}
          <div className="st-detail">{S('agents.ask.footer')}</div>
        </div>,
        document.body,
      )}
    </div>
  );
}

// ------------------------------------------------------------------ sheets

function Sheet({ label, close, children, width = 560 }: { label: string; close: () => void; children: React.ReactNode; width?: number }) {
  useEffect(() => {
    const k = (e: KeyboardEvent) => e.key === 'Escape' && close();
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [close]);
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && close()}>
      <div className="sheet st-sheet" role="dialog" aria-label={label} style={{ width }}>
        <div className="st-sheet-body">{children}</div>
      </div>
    </div>
  );
}

/** One agent's settings: its header, Organizing as on the page (its pop-ups say the inherited value "Default
 *  (Haiku)"), the blurt skill + MCP and a test run. Done is the sheet's default. */
function DetailSheet({ m, id, close, onSignIn }: { m: Model; id: string; close: () => void; onSignIn: (id: string) => void }) {
  const a = m.rows.find((r) => r.id === id);
  if (!a) return null;
  const ms = m.models[a.id];
  const name = (x: string | null | undefined) => ms?.models.find((y) => y.id === x)?.name;
  const facts = a.version ? S('agents.details.version', shortVersion(a.version)) : '';
  const modelChoices = (k: Kind): [string, string][] => {
    const shared = m.sharedSetting(k).model;
    const named = shared === 'cheapest' ? name(ms?.cheapest) : name(ms?.cli_default);
    const follow = S('agents.organize.inherit', named ?? S(shared === 'cheapest' ? 'agents.processing.cheapest' : 'agents.processing.default'));
    const cli = name(ms?.cli_default) ? S('agents.processing.default_named', name(ms?.cli_default)!) : S('agents.processing.default');
    const cheap = name(ms?.cheapest) ? S('agents.processing.cheapest_named', name(ms?.cheapest)!) : S('agents.processing.cheapest');
    return [[SHARED, follow], ['default', cli], ['cheapest', cheap], ...(ms?.models ?? []).map((x) => [x.id, x.name] as [string, string])];
  };
  const effortChoices = (k: Kind): [string, string][] => [
    [SHARED, S('agents.organize.inherit', S(`agents.effort.${m.sharedSetting(k).effort}`))],
    ['default', S('agents.effort.default')],
    ...(ms?.efforts ?? []).map((e) => [e, S(`agents.effort.${e}`)] as [string, string]),
  ];
  const tone: Tone = !a.installed ? 'off' : a.state === 'ready' ? 'good' : a.state === 'logged_out' ? 'warn' : 'off';
  const t = m.tests[a.id];
  return (
    <Sheet label={a.name} close={close} width={700}>
      <div className="st-sheet-head">
        <div>
          <div className="st-sheet-title">{a.name}</div>
          {facts && <div className="st-detail">{facts}</div>}
        </div>
        <span className="st-ctl"><Dot tone={tone} /><span className="st-detail">{stateText(a)}</span>
          {a.headless && a.installed && a.state === 'logged_out' && <button className="st-small" onClick={() => (close(), onSignIn(a.id))}>{S('agents.sign_in')}</button>}
        </span>
      </div>
      <Group id="agentSheetOrganize" title={S('agents.organize.header')}
        footer={[S('agents.details.models.note'), a.id === 'codex' ? S('agents.codex_trust') : null].filter(Boolean).join(' ')}
        accessory={ms ? <span className="st-cols wide1"><span>{S('agents.details.model')}</span>{ms.efforts?.length ? <span>{S('agents.effort')}</span> : null}</span> : undefined}>
        {ms ? KINDS.map((k) => (
          <div key={k} className="st-row">
            <div className="st-text" title={S(`agents.processing.${k}.help`)}>{S(`agents.organize.${k}`)}</div>
            <div className="st-ctl">
              <Popup wide label={S(`agents.processing.${k}`)} value={m.followsModel(a.id, k) ? SHARED : m.modelOf(a.id, k)} choices={modelChoices(k)} dividers={[1, 3]}
                onChange={(v) => m.setProcessing(a.id, k, v === SHARED ? m.sharedSetting(k).model : v)} />
              {ms.efforts?.length ? (
                <Popup label={S('agents.effort')} value={m.followsEffort(a.id, k) ? SHARED : m.effortOf(a.id, k)} choices={effortChoices(k)} dividers={[1, 2]}
                  onChange={(v) => m.setProcessing(a.id, k, undefined, v === SHARED ? m.sharedSetting(k).effort : v)} />
              ) : null}
            </div>
          </div>
        )) : <div className="st-row"><span className="st-detail">{S('agents.details.no_models')}</span></div>}
      </Group>
      <Group id="agentSheetConnect" title={S('agents.details.more')}>
        <div className="st-row">
          <div className="st-text"><div>{S('agents.details.skill')}</div><div className="st-detail">{S(m.connected[a.id] ? 'agents.connected.help' : 'agents.not_connected.help')}</div></div>
          <div className="st-ctl">
            {m.installing === a.id ? <span className="st-detail">{S('install.working')}</span> : m.connected[a.id] ? <span className="st-detail">{S('agents.details.connected')}</span> : <button onClick={() => m.preview(a)}>{S('agents.install')}</button>}
          </div>
        </div>
        <div className="st-row">
          <div className="st-text">
            <div>{S('agents.details.test')}</div>
            <div className="st-detail">{S('agents.test.help')}</div>
            {t && <div className={`st-detail ${t.ok ? 'st-ok' : 'st-err'}`}>{t.text}</div>}
          </div>
          <div className="st-ctl">{m.testing === a.id ? <span className="st-detail">{S('agents.test')}…</span> : <button disabled={!!m.testing} onClick={() => m.test(a)}>{S('agents.test')}</button>}</div>
        </div>
      </Group>
      <div className="st-ctl st-sheet-foot"><button className="primary" onClick={close}>{S('dictation.feedback.done')}</button></div>
    </Sheet>
  );
}

const tilde = (p: string) => p.replace(/^(C:\\Users\\[^\\]+|\/Users\/[^/]+|\/home\/[^/]+)/i, '~');
const changesSomething = (c: InstallChange) => ['symlink', 'run', 'json_merge'].includes(c.action);
const subject = (c: InstallChange) => (c.what ? (c.what === 'skill' ? 'skill' : 'mcp') : c.action === 'symlink' || c.action === 'conflict' ? 'skill' : c.action === 'exists' ? (!c.argv && !c.key ? 'skill' : 'mcp') : 'mcp');
/** a conflict with another copy of Blurt (a checkout, an older install): it keeps working, so it is in place */
const otherIsBlurt = (c: InstallChange) => c.action === 'conflict' && /([\\/]skills[\\/]blurt|[\\/]blurt)$/.test(c.points_to ?? '');
const group = (c: InstallChange) => (c.ok === false || c.action === 'error' || c.action === 'manual' ? 1 : c.action === 'conflict' ? (otherIsBlurt(c) ? 2 : 1) : changesSomething(c) ? 0 : 2);
function technical(c: InstallChange): string | null {
  const words = (a: string[]) => a.map((w) => (tilde(w).includes(' ') ? `'${tilde(w)}'` : tilde(w))).join(' ');
  switch (c.action) {
    case 'symlink': return c.path ? `${tilde(c.path)} → ${tilde(c.target ?? '?')}` : null;
    case 'conflict': return c.path ? `${tilde(c.path)} → ${tilde(c.points_to ?? '?')}` : null;
    case 'run': return c.argv ? words(c.argv) : null;
    case 'json_merge': return c.path ? `${tilde(c.path)}: ${(c.key ?? []).join('.')}` : null;
    case 'exists': return c.argv ? words(c.argv) : c.path && c.key ? `${tilde(c.path)}: ${c.key.join('.')}` : c.path ? tilde(c.path) : null;
    case 'manual': return c.command ? words(c.command) : null;
    default: return c.path ? tilde(c.path) : null;
  }
}

/** Connect's confirmation (a dry run, nothing written yet) and, after Connect, its result: what Connect adds, what
 *  needs the user, what is already in place; the exact commands and paths only under Details. */
function InstallSheet({ m, close }: { m: Model; close: () => void }) {
  const [details, setDetails] = useState(false);
  const [copied, setCopied] = useState(false);
  const p = m.plan!;
  const name = p.agent.name;
  const L = lang() === 'zh-Hans' ? 'zh' : 'en';
  const rows = p.plan.changes.map((c) => {
    const skill = subject(c) === 'skill';
    const about = S(skill ? 'install.row.about.skill' : 'install.row.about.mcp', name);
    const inPlace = S(skill ? 'install.row.in_place.skill' : 'install.row.in_place.mcp');
    let r: { tone: 'add' | 'added' | 'in' | 'attn' | 'err'; title: string; detail?: string; reveal?: string };
    if (c.action === 'manual') r = { tone: 'attn', title: S(skill ? 'install.row.manual.skill' : 'install.row.manual.mcp'), detail: m.def(p.agent.id)?.fix?.[L] || c.how || S('install.row.manual.none', name) };
    else if (c.action === 'error') r = { tone: 'err', title: S(skill ? 'install.row.failed.skill' : 'install.row.failed.mcp'), detail: c.path ? S('install.error.path', tilde(c.path)) : S('install.error') };
    else if (c.ok === false) r = { tone: 'err', title: S(skill ? 'install.row.failed.skill' : 'install.row.failed.mcp'), detail: S('install.row.failed.detail', name) };
    else if (changesSomething(c)) {
      const done = p.applied && c.ok === true;
      r = { tone: done ? 'added' : 'add', title: S(done ? (skill ? 'install.row.added.skill' : 'install.row.added.mcp') : skill ? 'install.row.add.skill' : 'install.row.add.mcp'), detail: about };
    } else if (c.action === 'conflict' && otherIsBlurt(c)) r = { tone: 'in', title: inPlace, detail: S('install.row.other_copy', tilde((c.points_to ?? '?').replace(/[\\/]skills[\\/]blurt$/, ''))) };
    else if (c.action === 'conflict') r = { tone: 'attn', title: S('install.row.conflict.title'), detail: S('install.row.conflict', tilde(c.path ?? '?')), reveal: c.path };
    else r = { tone: 'in', title: inPlace, detail: S('install.row.exists') };
    return { ...r, group: group(c), line: technical(c) };
  }).map((r, i) => ({ r, i })).sort((a, b) => a.r.group - b.r.group || a.i - b.i).map((x) => x.r);
  const nothing = !p.applied && !p.plan.changes.some(changesSomething);
  const failed = p.applied && !p.plan.applied;
  const title = p.applied ? S(failed ? 'install.title.failed' : 'install.title.applied', name) : S(nothing ? 'install.title.nothing' : 'install.title', name);
  const subtitle = p.applied ? (failed ? S('install.benefit.failed') : S('install.benefit.applied', name)) : S(nothing ? 'install.benefit.nothing' : 'install.benefit', name);
  const tech = rows.filter((r) => r.line);
  const showInPlace = rows.some((r) => r.group !== 2) && rows.some((r) => r.group === 2);
  const glyph = { add: 'plus', added: 'check', in: 'check', attn: 'warning', err: 'x' } as const;
  return (
    <Sheet label={title} close={close} width={480}>
      <div className="st-sheet-head"><div><div className="st-sheet-title">{title}</div><div className="st-detail">{subtitle}</div></div></div>
      <div className="st-install">
        {rows.map((r, i) => (
          <div key={i}>
            {showInPlace && r.group === 2 && (i === 0 || rows[i - 1].group !== 2) && <div className="st-rsec">{S('install.group.in_place')}</div>}
            <div className={`st-install-row ${r.tone}`}>
              <Icon name={glyph[r.tone]} size={14} />
              <div>
                <div>{r.title}</div>
                {r.detail && <div className="st-detail">{r.detail}</div>}
                {r.reveal && <TextLink ink onClick={() => api.reveal(r.reveal!)}>{S('win.projects.reveal')}</TextLink>}
              </div>
            </div>
          </div>
        ))}
      </div>
      {tech.length > 0 && (
        <div className="st-tech">
          <TextLink onClick={() => setDetails((d) => !d)}><Icon name={details ? 'chevron-down' : 'chevron-right'} size={11} /> {S('install.details')}</TextLink>
          {details && (
            <div className="st-well">
              <button className="link st-well-copy" aria-label={S('settings.kit.copy')} onClick={() => api.copyText(tech.map((r) => r.line).join('\n')).then(() => setCopied(true))}><Icon name={copied ? 'check' : 'copy'} size={12} /></button>
              {tech.map((r, i) => <div key={i}><div className="st-detail">{r.title}</div><code>{r.line}</code></div>)}
            </div>
          )}
        </div>
      )}
      <div className="st-ctl st-sheet-foot">
        <span className="st-detail" style={{ marginInlineEnd: 'auto' }}>
          {m.installing ? S('install.working') : !p.applied && !nothing ? S('install.footnote') : p.applied && !failed ? S('install.next', name) : ''}
        </span>
        {p.applied || nothing ? (
          <button className="primary" onClick={() => (close(), m.recheck())}>{S('dictation.feedback.done')}</button>
        ) : (
          <>
            <button disabled={!!m.installing} onClick={close}>{S('action.cancel')}</button>
            <button className="primary" disabled={!!m.installing} onClick={() => m.apply()}>{S('install.confirm')}</button>
          </>
        )}
      </div>
    </Sheet>
  );
}
