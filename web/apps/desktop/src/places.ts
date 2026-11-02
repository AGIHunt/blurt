// The main window's model, the Mac's MainModel.swift / ListSections.swift / PlaceFilters.swift / HandOffCheck.swift
// in plain functions: the places, their queries, how each groups its rows, the per-place filters, the list's date,
// the one project order, what blocks a hand-off, and the undo stack's steps. No React here (places.test.ts).
import { ACTIONS, canDo, TRANSITIONS, type Action, type State } from '@blurt/ui';
import type { ItemQuery, ItemRow, Job, ProjectRow } from './api';

/** inbox · progress · unassigned · all · dictation · project:<id> (the Mac's Scope keys) */
export type Place = 'inbox' | 'progress' | 'unassigned' | 'all' | 'dictation' | `project:${string}`;

export const isProject = (p: Place): p is `project:${string}` => p.startsWith('project:');
export const projectOf = (p: Place): string | null => (isProject(p) ? p.slice(8) : p === 'unassigned' ? 'inbox' : null);

/** K3: what the In Progress place lists (Lifecycle.active) */
export const ACTIVE: readonly State[] = ['handed_off', 'in_progress', 'to_verify'];
export const CLOSED: readonly State[] = ['done', 'wontfix'];
const LIVE: readonly State[] = ['new', 'todo', 'handed_off', 'in_progress', 'to_verify', 'done', 'wontfix'];
/** the State filter's values, in the menu's order */
export const LIVE_STATES = LIVE;

/** Each place keeps its own kinds and State filter (PlaceFilters): null = all but discarded. */
export interface PlaceFilter {
  kinds: string[];
  state: State | null;
}
export const NO_FILTER: PlaceFilter = { kinds: [], state: null };
/** The State control shows everywhere but the Inbox (which is a state group itself) and Dictation. */
export const showsState = (p: Place) => p !== 'inbox' && p !== 'dictation';

export type Grouping = 'none' | 'project' | 'state';
/** The Inbox groups by project; In Progress, All Items and a project by state; a search is one ranked list. */
export function grouping(p: Place, searching: boolean): Grouping {
  if (searching) return 'none';
  if (p === 'inbox') return 'project';
  if (p === 'progress' || p === 'all' || isProject(p)) return 'state';
  return 'none';
}

export const SORT_KEYS = ['updated', 'title', 'id', 'kind', 'state', 'project'] as const;
export type SortKey = (typeof SORT_KEYS)[number];
/** A key's natural direction: newest first for the date, A to Z (and the lifecycle's order) for the rest. */
export const ascendsByDefault = (k: SortKey) => k !== 'updated';

/** The index query of a place with its filters, search and order. */
export function placeQuery(p: Place, f: PlaceFilter, text: string, sort: SortKey, ascending: boolean, limit: number): ItemQuery {
  const state = showsState(p) ? f.state : null;
  const q: ItemQuery = { limit, sort, ascending };
  const t = text.trim();
  if (t) q.query = t;
  if (f.kinds.length) q.kind = [...f.kinds];
  if (state) q.state = [state];
  if (p === 'inbox') q.state = ['new', 'to_verify'];
  else if (p === 'progress' && !state) q.state = [...ACTIVE];
  else if (p === 'unassigned') q.project = 'inbox';
  else if (isProject(p)) q.project = p.slice(8);
  return q;
}

/** What needs you first, then what is moving, then what is new or waiting, then what is closed (ListSections.stateOrder). */
export const STATE_ORDER: readonly State[] = ['to_verify', 'in_progress', 'handed_off', 'new', 'todo', 'done', 'wontfix', 'discarded'];

/** The projects in the one order every list uses: pinned, then the most recently used (ProjectStore.projects). */
export function orderedProjects(ps: ProjectRow[]): ProjectRow[] {
  return ps
    .map((p, i) => ({ p, i }))
    .sort((a, b) => Number(!!b.p.pinned) - Number(!!a.p.pinned) || (b.p.last_used ?? '').localeCompare(a.p.last_used ?? '') || a.i - b.i)
    .map((x) => x.p);
}

export interface Section {
  key: string;
  start: number;
  count: number;
}
export interface Grouped {
  rows: ItemRow[];
  /** the run starting at a row (only when there is more than one) */
  sections: Map<number, Section>;
}

/** Rows bucketed by key in rank order (ties: the order a key first shows up), each bucket in the rows' own order. */
export function group(rows: ItemRow[], how: Grouping, projectIds: string[]): Grouped {
  if (how === 'none') return { rows, sections: new Map() };
  const keyOf = (r: ItemRow) => (how === 'project' ? r.project_id : r.state);
  const at = new Map(projectIds.map((id, i) => [id, i]));
  const rank = (k: string) =>
    how === 'state' ? (STATE_ORDER.indexOf(k as State) + 1 || 99) : k === 'inbox' ? Number.MAX_SAFE_INTEGER : at.get(k) ?? projectIds.length;
  const order: string[] = [];
  const buckets = new Map<string, ItemRow[]>();
  for (const r of rows) {
    const k = keyOf(r);
    if (!buckets.has(k)) {
      order.push(k);
      buckets.set(k, []);
    }
    buckets.get(k)!.push(r);
  }
  const first = new Map(order.map((k, i) => [k, i]));
  const keys = [...order].sort((a, b) => rank(a) - rank(b) || first.get(a)! - first.get(b)!);
  const out: ItemRow[] = [];
  const sections = new Map<number, Section>();
  for (const k of keys) {
    const b = buckets.get(k)!;
    sections.set(out.length, { key: k, start: out.length, count: b.length });
    out.push(...b);
  }
  return { rows: out, sections: sections.size > 1 ? sections : new Map() };
}

/** Unassigned: the items an organizing run suggested a registered project for come first, each project's together
    (by the project's name), then the rest (IndexReader's bySuggestion). */
export function bySuggestion(rows: ItemRow[], projects: ProjectRow[]): ItemRow[] {
  const known = new Map(projects.map((p) => [p.id, p.name.toLowerCase()]));
  const sug = rows.filter((r) => r.suggested_project && known.has(r.suggested_project));
  const rest = rows.filter((r) => !(r.suggested_project && known.has(r.suggested_project)));
  sug.sort((a, b) => known.get(a.suggested_project!)!.localeCompare(known.get(b.suggested_project!)!));
  return [...sug, ...rest];
}

/** "Looks like X · Move All (3)": the suggested runs above the Unassigned list. */
export function suggestionGroups(rows: ItemRow[], projects: ProjectRow[]): { project: ProjectRow; uids: string[] }[] {
  const out: { project: ProjectRow; uids: string[] }[] = [];
  for (const r of rows) {
    const p = r.state !== 'discarded' && r.suggested_project ? projects.find((x) => x.id === r.suggested_project) : undefined;
    if (!p) continue;
    const g = out.find((x) => x.project.id === p.id);
    if (g) g.uids.push(r.uid);
    else out.push({ project: p, uids: [r.uid] });
  }
  return out;
}

/** The list's date (Loc.listDate): "10:42" today, "Yesterday", a weekday within the week, "Oct 24" this year, else
    the short date. */
export function listDate(epoch: number, locale: string, yesterday: string, now = new Date()): string {
  const d = new Date(epoch * 1000);
  const day = (x: Date) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const days = Math.round((day(now) - day(d)) / 86_400_000);
  if (days <= 0) return new Intl.DateTimeFormat(locale, { hour: 'numeric', minute: '2-digit' }).format(d);
  if (days === 1) return yesterday;
  if (days < 7) return new Intl.DateTimeFormat(locale, { weekday: 'short' }).format(d);
  if (d.getFullYear() === now.getFullYear()) return new Intl.DateTimeFormat(locale, { month: 'short', day: 'numeric' }).format(d);
  return new Intl.DateTimeFormat(locale, { dateStyle: 'short' }).format(d);
}

// ---------------------------------------------------------------- the state actions (StateMenu)

/** The actions offered for these items, in lifecycle order. */
export function actionsFor(items: ItemRow[], canHandOff: boolean): Action[] {
  return ACTIONS.filter((a) => (a !== 'hand_off' || canHandOff) && items.some((i) => canDo(a, i.state)));
}
export const validFor = (a: Action, items: ItemRow[]) => items.filter((i) => canDo(a, i.state));
/** The list keys: A keep, D done, R the one way back, W won't do, X / Delete / Backspace discard. */
export function actionForListKey(key: string, state: State): Action | null {
  const k = key.length === 1 ? key.toLowerCase() : key;
  if (k === 'r') return (['send_back', 'take_back', 'reopen', 'restore'] as const).find((a) => canDo(a, state)) ?? null;
  const a = ({ a: 'keep', d: 'done', w: 'wontfix', x: 'discard', Delete: 'discard', Backspace: 'discard' } as Record<string, Action>)[k];
  return a && canDo(a, state) ? a : null;
}
/** The key a state action shows in menus (A D R W ⌫ / Ctrl+↩). */
export function actionKey(a: Action, mac: boolean): string {
  if (a === 'hand_off') return mac ? '⌘↩' : 'Ctrl+Enter';
  if (a === 'discard') return mac ? '⌫' : 'Del';
  return TRANSITIONS[a].key.length === 1 ? TRANSITIONS[a].key.toUpperCase() : '';
}

// ---------------------------------------------------------------- hand-off check (HandOffCheck)

export type HandOffBlock =
  | { why: 'discarded' }
  | { why: 'finished'; state: State }
  | { why: 'with_session'; item: string; job: string }
  | { why: 'mixed_projects' }
  | { why: 'needs_project' };

/** nil = they can go. `liveJob`: the running agent session an item is with, if any. */
export function handOffBlock(items: ItemRow[], liveJob: (uid: string) => string | null): HandOffBlock | null {
  if (!items.length) return null;
  const live = items.filter((i) => i.state !== 'discarded');
  if (!live.length) return { why: 'discarded' };
  const f = live.find((i) => CLOSED.includes(i.state) || i.state === 'to_verify');
  if (f) return { why: 'finished', state: f.state };
  for (const i of live) {
    const j = (i.state === 'handed_off' || i.state === 'in_progress') && liveJob(i.uid);
    if (j) return { why: 'with_session', item: i.item_id, job: j };
  }
  if (new Set(live.map((i) => i.project_id)).size > 1) return { why: 'mixed_projects' };
  if (live[0].project_id === 'inbox') return { why: 'needs_project' };
  return null;
}

/** The running agent session that has this item, from the jobs list. */
export function jobFor(jobs: Job[], uid: string): Job | null {
  return jobs.find((j) => j.type === 'agent' && (j.state === 'running' || j.state === 'queued') && j.items.includes(uid)) ?? null;
}

/** An item still with an agent session that is over and never said it was done (In Progress' stuck work). */
export function sessionEnded(r: ItemRow, jobs: Job[]): boolean {
  if (r.state !== 'handed_off' && r.state !== 'in_progress') return false;
  if (r.work_to === 'external') return false;
  const j = jobs.find((x) => x.type === 'agent' && x.items.includes(r.uid));
  return !!j && (j.state === 'done' || j.state === 'failed' || j.state === 'cancelled' || j.agent?.status === 'exited');
}

// ---------------------------------------------------------------- undo (the window's NSUndoManager, in steps)

export type UndoStep =
  | { kind: 'state'; name: string; action: Action; before: [string, State][] }
  | { kind: 'move'; name: string; to: string; before: [string, string][] }
  | { kind: 'edit'; name: string; project: string; uid: string; before: Record<string, unknown>; after: Record<string, unknown> }
  | { kind: 'remove_project'; name: string; id: string; removed: unknown }
  /** a step of the review page on show (host.registerUndo): the page undoes / redoes it itself */
  | { kind: 'page'; name: string };

/** The Inbox's "3 new · 2 to verify" parts (a zero part left out). */
export function needsYouParts(fresh: number, verify: number, t: (k: string, p?: { n: number }) => string): string {
  return [fresh ? t('main.inbox.new', { n: fresh }) : '', verify ? t('main.inbox.verify', { n: verify }) : ''].filter(Boolean).join(' · ');
}

// ---------------------------------------------------------------- the line above an item (the Mac's ItemBanner)

/** What the banner above an item's detail says and offers (WebHostController.ItemBanner + SessionBannerPlan):
    - with an agent session: who has it and how it is going (working / waiting / ended / failed), Open Session and
      what the session's outcome calls for (restart, review changes, take back, done) — the page leaves its own Open
      Session out then (host.sessionBanner);
    - handed to the user's own agent: Mark as Done (primary) and Won't Do;
    - its batch still being organised: Show Progress.
    To verify, new, closed and discarded items have no banner: the page's own work card asks. */
export interface BannerPlan {
  kind: 'session' | 'external' | 'organizing';
  tone: 'brand' | 'attn' | 'neutral';
  /** the icon: the item's state ring, the error mark, or the organising spinner */
  icon: 'ring' | 'error' | 'spinner';
  /** the sentence: a catalog key and its {a} {b} arguments (the Mac's %@ in order) */
  text: { key: string; args: string[] };
  /** inline buttons, in the Mac's order; `primary` is the brand one (the first, but for the external line's Won't Do ·
      Mark as Done); and the ⋯ menu's */
  actions: string[];
  primary: string;
  more: string[];
  /** the agent session / process job the actions are about */
  job: string | null;
}

/** `agent(id)`: an agent's display name; `why(job)`: a failed job's words; `t`: the catalog (the sentence's parts). */
export function bannerPlan(r: ItemRow, jobs: Job[], w: { agent: (id: string) => string; why: (j: Job) => string; t: (k: string) => string }): BannerPlan | null {
  const { agent, why, t: t0 } = w;
  if (r.state === 'discarded' || r.state === 'to_verify') return null;
  const active = r.state === 'handed_off' || r.state === 'in_progress';
  const sessionJobs = jobs.filter((j) => j.type === 'agent' && j.items.includes(r.uid));
  // the newest session that has it (a restart's replaces the old one)
  const job = sessionJobs.sort((a, b) => (b.created || '').localeCompare(a.created || ''))[0] ?? null;
  if (active && r.work_to === 'external') {
    return { kind: 'external', tone: 'brand', icon: 'ring', text: { key: 'main.banner.external', args: [] }, actions: ['wontfix', 'done'], primary: 'done', more: [], job: null };
  }
  if (active && (r.work_to === 'session' || job)) {
    const who = (job?.agent?.id && agent(job.agent.id)) || (r.work_agent && agent(r.work_agent)) || t0('main.banner.agent');
    const a = job?.agent;
    const live = !!job && (job.state === 'running' || job.state === 'queued') && a?.status !== 'exited' && a?.status !== 'error';
    const ring = (key: string, ...args: string[]) => ({ key, args });
    if (!job) return { kind: 'session', tone: 'neutral', icon: 'ring', text: ring('main.banner.with_agent', who, t0('main.banner.ended')), actions: ['take_back', 'done'], primary: 'take_back', more: [], job: null };
    if (live) {
      const st = a?.status ?? 'running';
      return { kind: 'session', tone: st === 'waiting_input' ? 'attn' : 'brand', icon: 'ring', text: ring('main.banner.with_agent', who, t0(`session.${st}`)), actions: ['session'], primary: 'session', more: [], job: job.id };
    }
    // ended: how (SessionOutcome.of, without the finish record and the diff the Mac reads: a failed run, a worktree
    // to review, or a plain end)
    if (a?.status === 'error' || job.state === 'failed') {
      const lived = job.started && job.ended ? (Date.parse(job.ended) - Date.parse(job.started)) / 1000 : 0;
      const atStart = !job.started || lived < 20;
      return { kind: 'session', tone: 'neutral', icon: 'error', text: ring(atStart ? 'main.banner.failed_start' : 'main.banner.failed', who, why(job)), actions: ['restart', 'take_back'], primary: 'restart', more: ['session'], job: job.id };
    }
    if (a?.worktree) return { kind: 'session', tone: 'neutral', icon: 'ring', text: ring('main.banner.with_agent', who, t0('main.banner.ended_review')), actions: ['review', 'take_back'], primary: 'review', more: ['done'], job: job.id };
    return { kind: 'session', tone: 'neutral', icon: 'ring', text: ring('main.banner.with_agent', who, t0('main.banner.ended')), actions: ['session', 'restart'], primary: 'session', more: ['done', 'take_back'], job: job.id };
  }
  // with an agent but no session of Blurt's (set by hand, or copied out): the Mac's ItemBanner says the same as for
  // the user's own agent — mark it done here when it's finished (WebHostController.set: active && !inSession)
  if (active) return { kind: 'external', tone: 'neutral', icon: 'ring', text: { key: 'main.banner.manual', args: [] }, actions: ['wontfix', 'done'], primary: 'done', more: [], job: null };
  if (r.session_dir) {
    const p = jobs.find((j) => j.type === 'process' && (j.state === 'running' || j.state === 'queued') && j.session === r.session_dir);
    if (p) return { kind: 'organizing', tone: 'brand', icon: 'spinner', text: { key: 'main.banner.organizing', args: [] }, actions: ['progress'], primary: 'progress', more: [], job: p.id };
  }
  return null;
}
