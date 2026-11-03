// What the sessions pane knows about an agent session — the Mac's SessionsModel / AgentSessionRow / SessionOutcome /
// SessionMark (Terminal/SessionsModel.swift, BlurtCore Sessions/SessionOutcome.swift), on the agent jobs `sessions_rows`
// returns. One wording per state everywhere (the list, the header, the ended card), one mark per state.
import type { ItemRow, SessionJob } from './api';
import { plural, t } from './i18n';

export type Status = 'running' | 'waiting_input' | 'turn_done' | 'exited' | 'error';

/** How a session stands: still going, finished by the user (merge | pr | discard | keep | restart | take_back), ended
    with changes to review, failed (at start or later), ended in a worktree with nothing on it, ended in the folder. */
export type Outcome =
  | { kind: 'live'; status: Status }
  | { kind: 'finished'; action: string }
  | { kind: 'review' }
  | { kind: 'failed'; atStart: boolean }
  | { kind: 'noChanges' }
  | { kind: 'ended' };

/** One shape per state (the island's rule): working · waiting (the user's move) · done (merged / PR) · failed · idle
    (over, nothing to do) · elsewhere (in the agent's desktop app). */
export type Mark = 'working' | 'waiting' | 'done' | 'failed' | 'idle' | 'elsewhere';

/** A session that fails within this long of starting "couldn't start". */
export const STARTUP_WINDOW = 20;

const AGENTS: Record<string, string> = { claude: 'Claude Code', codex: 'Codex', kimi: 'Kimi Code', opencode: 'OpenCode', human: 'You' };
export const agentName = (id: string | null | undefined, names: Record<string, string> = {}) =>
  !id ? '' : names[id] ?? (id === 'human' ? t('ses.agent.you') : AGENTS[id] ?? id.charAt(0).toUpperCase() + id.slice(1));

const secs = (v: string | null | undefined) => (v ? Date.parse(v) / 1000 : NaN);

export const isActive = (j: Pick<SessionJob, 'state'>) => j.state === 'queued' || j.state === 'running';
export const isDesktop = (j: SessionJob) => j.agent.runner === 'desktop';
export const stalled = (j: SessionJob) => j.agent.status_source === 'watchdog';
export const hasChanges = (j: SessionJob) => {
  const c = j.agent.changes;
  return !!j.agent.worktree && (c ? (c.ahead ?? 0) + (c.dirty ?? 0) > 0 : true);
};

export function outcome(j: SessionJob, now = Date.now() / 1000): Outcome {
  const a = j.agent;
  if (a.finish?.action) return { kind: 'finished', action: a.finish.action };
  if (isActive(j) && a.status !== 'exited' && a.status !== 'error') return { kind: 'live', status: a.status };
  // it quit at its own folder-trust question: it never started
  if (a.stopped_at === 'trust' && !hasChanges(j)) return { kind: 'failed', atStart: true };
  if (hasChanges(j)) return { kind: 'review' };
  if (a.status === 'error' || j.state === 'failed') {
    const end = secs(j.ended) || now;
    const start = secs(j.started) || secs(j.created) || end;
    return { kind: 'failed', atStart: !a.started || end - start < STARTUP_WINDOW };
  }
  return a.worktree ? { kind: 'noChanges' } : { kind: 'ended' };
}

/** The status the list sorts by (and notifications see): once the user decided, a failure is past news. */
export function status(j: SessionJob): Status {
  if (j.agent.finish) return 'exited';
  if (isActive(j)) return j.agent.status;
  return j.agent.status === 'error' || j.state === 'failed' ? 'error' : 'exited';
}

/** The state a person has to act on first sorts first. */
export const URGENCY: Record<Status, number> = { waiting_input: 0, error: 1, turn_done: 2, running: 3, exited: 4 };

export function mark(j: SessionJob): Mark {
  if (isDesktop(j) && isActive(j)) return 'elsewhere';
  const o = outcome(j);
  switch (o.kind) {
    case 'live':
      if (stalled(j)) return 'waiting';
      return o.status === 'running' ? 'working' : o.status === 'error' ? 'failed' : o.status === 'exited' ? 'idle' : 'waiting';
    case 'review':
      return 'waiting';
    case 'failed':
      return 'failed';
    case 'finished':
      return o.action === 'merge' || o.action === 'pr' ? 'done' : 'idle';
    default:
      return 'idle';
  }
}

/** The one wording of a session's state: its live status ("No response" once the watchdog gave up), else how it ended. */
export function stateText(j: SessionJob, desktopName = 'Claude'): string {
  if (j.folder_gone && outcome(j).kind === 'review') return t('ses.row.folder_gone');
  const o = outcome(j);
  switch (o.kind) {
    case 'live':
      if (isDesktop(j)) return t(j.agent.desktop?.mcp === false ? 'ses.row.desktop.no_mcp' : 'ses.row.desktop', { a: desktopName });
      return stalled(j) ? t('ses.row.no_response') : t(`ses.status.${o.status}`);
    case 'review':
      return t('ses.row.ready_to_review');
    case 'failed':
      return t(o.atStart ? 'ses.row.failed_start' : 'ses.row.failed');
    case 'noChanges':
      return t('ses.row.no_changes');
    case 'ended':
      return t('ses.status.exited');
    case 'finished':
      // "pr" without a pull request url = only pushed (no gh, or a host it doesn't know)
      return t(o.action === 'pr' && typeof j.agent.finish?.result?.pr !== 'string' ? 'ses.finish.state.pushed' : `ses.finish.state.${o.action}`);
  }
}

/** Ink of the state's words: attention when it waits on you, error when it failed, else secondary. */
export const tone = (m: Mark): 'attn' | 'err' | 'dim' => (m === 'waiting' ? 'attn' : m === 'failed' ? 'err' : 'dim');

export interface Row {
  id: string;
  job: SessionJob;
  projectID: string;
  projectName: string;
  /** "BA-12, BA-13" — the window's name, else the item ids, else the job's title */
  label: string;
  /** the first item's title ("Title +1"), else the job's title */
  subtitle: string;
  agentName: string;
  /** when it started (epoch s) */
  since: number;
  alive: boolean;
  inDesktop: boolean;
  isAppRunner: boolean;
  outcome: Outcome;
  status: Status;
  mark: Mark;
  stateText: string;
  /** ended with changes nobody merged, opened a PR for or discarded yet */
  awaitsFinish: boolean;
  /** its window (tmux) or its screen (the app runner, until Blurt quits) is still there to read (Show Output) */
  hasOutput: boolean;
  /** it's the user's move, or it failed: never dimmed */
  needsYou: boolean;
}

export interface Group {
  id: string;
  name: string;
  rows: Row[];
}

const GONE_WINDOW = ['merge', 'discard', 'restart', 'take_back'];

export function toRow(j: SessionJob, projectName: (id: string, j: SessionJob) => string, names: Record<string, string> = {}): Row {
  const a = j.agent;
  const pid = j.project ?? 'inbox';
  const w = a.tmux?.name;
  const label = w ? w.replace(/,/g, ', ') : j.labels.length ? j.labels.map((l) => l.id).join(', ') : j.title ?? '';
  const first = j.labels[0];
  const subtitle = !first ? j.title ?? '' : j.labels.length > 1 ? t('ses.session.items.more', { a: first.title, b: j.labels.length - 1 }) : first.title;
  const o = outcome(j);
  const m = mark(j);
  const appRunner = a.runner === 'app';
  return {
    id: j.id,
    job: j,
    projectID: pid,
    projectName: projectName(pid, j),
    label,
    subtitle,
    agentName: agentName(a.id, names),
    since: secs(j.started) || secs(j.created) || 0,
    alive: isActive(j),
    inDesktop: isActive(j) && isDesktop(j),
    isAppRunner: appRunner,
    outcome: o,
    status: status(j),
    mark: m,
    stateText: stateText(j),
    awaitsFinish: o.kind === 'review',
    // the app runner's screen lives as long as the app (pty.rs keeps it): not after a relaunch
    hasOutput: (appRunner ? j.output : !!a.tmux?.window) && !GONE_WINDOW.includes(a.finish?.action ?? ''),
    needsYou: m === 'waiting' || m === 'failed',
  };
}

/** Live first (the one that needs you on top), then ended newest first; grouped by project in that order. */
export function build(jobs: SessionJob[], projectName: (id: string, j: SessionJob) => string, names: Record<string, string> = {}): { rows: Row[]; groups: Group[] } {
  const rows = jobs.map((j) => toRow(j, projectName, names));
  rows.sort((l, r) => {
    if (l.alive !== r.alive) return l.alive ? -1 : 1;
    if (l.alive && URGENCY[l.status] !== URGENCY[r.status]) return URGENCY[l.status] - URGENCY[r.status];
    return (secs(r.job.created) || 0) - (secs(l.job.created) || 0) || r.id.localeCompare(l.id);
  });
  const groups: Group[] = [];
  for (const r of rows) {
    const g = groups.find((x) => x.id === r.projectID);
    if (g) g.rows.push(r);
    else groups.push({ id: r.projectID, name: r.projectName, rows: [r] });
  }
  return { rows, groups };
}

/** The session to show when a pane opens with no choice: the one that needs you, else the newest live one, else the first. */
export function preferred(rows: Row[]): Row | null {
  const alive = rows.filter((r) => r.alive);
  if (alive.length) return [...alive].sort((l, r) => URGENCY[l.status] - URGENCY[r.status] || r.since - l.since)[0];
  return rows[0] ?? null;
}

/** "1 working · 1 waiting on you", by the same marks as the rows; null when neither. */
export function countText(rows: Row[]): string | null {
  const working = rows.filter((r) => r.mark === 'working').length;
  const waiting = rows.filter((r) => r.mark === 'waiting').length;
  const parts = [working ? t('ses.list.count.working', { a: working }) : '', waiting ? t('ses.list.count.waiting', { a: waiting }) : ''].filter(Boolean);
  return parts.length ? parts.join(' · ') : null;
}

/** "blurt/aw-12-create-hello" → "create-hello": without the blurt/ prefix and the item key it repeats. */
export function branchWords(b: string, items: string[]): string {
  let s = b.startsWith('blurt/') ? b.slice(6) : b;
  for (const id of items) {
    if (!id) continue;
    const k = id.toLowerCase();
    if (s.toLowerCase().startsWith(k + '-')) {
      s = s.slice(k.length + 1);
      break;
    }
  }
  return s || b;
}

// ---- the ended card (SessionOverlay.endedSummary)

export type ItemInfo = Pick<ItemRow, 'uid' | 'item_id' | 'kind' | 'title' | 'state'>;

/** Some of its items are still with this session (handed off or in progress; not indexed counts as with it). */
export const itemsWithIt = (r: Row, items: Record<string, ItemInfo | null | undefined>) =>
  r.job.items.some((u) => {
    const it = items[u];
    return !it || it.state === 'handed_off' || it.state === 'in_progress';
  });

/** Its items waiting to be verified (after a merge or a pull request). */
export const toVerify = (r: Row, items: Record<string, ItemInfo | null | undefined>) => r.job.items.filter((u) => items[u]?.state === 'to_verify');

export const itemID = (uid: string, r: Row, items: Record<string, ItemInfo | null | undefined>) => items[uid]?.item_id ?? r.job.labels[0]?.id ?? '';

/** "Ready to review", "Codex couldn’t start", "Ended with no changes", "Merged"… — a sentence, never a log line. */
export function endedTitle(r: Row): string {
  if (r.job.folder_gone && r.outcome.kind === 'review') return t('ses.overlay.gone.title');
  const o = r.outcome;
  switch (o.kind) {
    case 'failed':
      if (r.job.agent.stopped_at === 'trust') return t('ses.overlay.stopped_trust.title', { a: r.agentName });
      return t(o.atStart ? 'ses.overlay.failed_start.title' : 'ses.overlay.failed.title', { a: r.agentName });
    case 'review':
      return t('ses.overlay.review.title');
    case 'noChanges':
      return t('ses.overlay.no_changes.title');
    case 'finished':
      return r.stateText;
    default:
      return t('ses.overlay.ended.title');
  }
}

/** What the session's items wait for now (an exit moves nothing; only the agent's report does). */
export function endedHint(r: Row, items: Record<string, ItemInfo | null | undefined>): string | null {
  if (r.job.folder_gone && r.outcome.kind === 'review') return t('ses.overlay.gone.body');
  const o = r.outcome;
  if (o.kind === 'review') return t('ses.overlay.ended.review_hint');
  if (o.kind === 'failed') return r.job.agent.stopped_at === 'trust' ? t('ses.overlay.stopped_trust.body') : null;
  if (o.kind === 'finished' && (o.action === 'merge' || o.action === 'pr')) {
    const waiting = toVerify(r, items);
    if (!waiting.length) return null;
    const who = waiting.length === 1 ? itemID(waiting[0], r, items) : t('ses.finish.items_n', { a: waiting.length });
    return o.action === 'merge'
      ? t('ses.overlay.merged.verify_hint', { a: r.job.agent.worktree?.base ?? 'main', b: who })
      : t('ses.overlay.pr.verify_hint', { a: who });
  }
  // restarted, discarded…: its items went on elsewhere
  if (o.kind === 'finished' && o.action !== 'keep') return null;
  const states = r.job.items.map((u) => items[u]?.state).filter(Boolean);
  if (states.some((s) => s === 'handed_off' || s === 'in_progress')) return t('ses.overlay.ended.unreported_hint');
  if (states.includes('to_verify')) return t('ses.overlay.ended.verify_hint');
  return null;
}

/** The job's own reason for failing (its error, in the app's language), when its last output doesn't say it already. */
export function errorText(j: SessionJob, lang: string): string | null {
  const e = j.error;
  if (!e) return null;
  const pick = e.reason_i18n?.[lang.startsWith('zh') ? 'zh' : 'en'] ?? e.reason_i18n?.[lang] ?? e.reason ?? null;
  const why = pick || null;
  if (!why || (j.agent.last_output ?? []).some((l) => l.includes(why))) return null;
  return why;
}

// ---- sessions.py errors in words (sessionsErrorText)

export interface SessionsError {
  code: string;
  job?: string;
  version?: string;
  need?: string;
  fix?: string;
  item_id?: string;
  agent?: string;
}

/** The CLI's failure as the app passes it on: "… {extra json} [code]". */
export function parseError(e: unknown): SessionsError {
  const s = String(e);
  const code = s.match(/\[([a-z_]+)\]\s*$/)?.[1] ?? 'unknown';
  let extra: Record<string, unknown> = {};
  const m = s.match(/(\{.*\})\s*\[[a-z_]+\]\s*$/);
  if (m) {
    try {
      extra = JSON.parse(m[1]);
    } catch {
      /* not ours */
    }
  }
  const str = (k: string) => (typeof extra[k] === 'string' ? (extra[k] as string) : undefined);
  return { code, job: str('job'), version: str('version'), need: str('need'), fix: str('fix'), item_id: str('item_id'), agent: str('agent') };
}

/** "0.164.0" → "0.164": how people write a minimum version. */
export const shortVersion = (v: string) => (v.endsWith('.0') ? v.slice(0, -2) : v);

/** A sessions.py error code → a sentence for people, never the code or the script's own message. */
export function errorWords(e: unknown, names: Record<string, string> = {}): string {
  const s = parseError(e);
  const who = s.agent ? agentName(s.agent, names) : 'Agent';
  if (s.code === 'auth') return s.fix ? t('ses.error.auth.fix', { a: who, b: s.fix }) : t('ses.error.auth', { a: who });
  if (s.code === 'outdated' && s.version && s.need)
    return t('ses.handoff.block.outdated', { a: who, b: s.version, c: shortVersion(s.need) }) + (s.fix ? ' ' + s.fix : '');
  if (s.code === 'already_dispatched' && s.item_id) return t('ses.error.already_dispatched.named', { a: s.item_id });
  const k = `ses.error.${s.code}`;
  const w = t(k);
  return w === k ? t('ses.error.unknown') : w;
}

/** The files of a review, as the sheet counts them. */
export const filesText = (n: number) => plural('ses.finish.files', n);
