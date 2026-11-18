// A recording is always findable, with its state (docs/design/capabilities.md §4; the Mac's
// BlurtCore Recordings.swift): Home's Recent lists every recording, and the items' places list the ones that have
// no items to be found by — at the top of the list, where the organising job's row used to be. One recording is one
// row: its process job (running, failed) is drawn as that row, never as a job row beside it.
//
//   state     what became of it, from its newest process job (record.py take_state's rules): 整理中 while a job
//             runs, 未完成 when the last one failed (until it is dismissed or retried), N 个事项 once organised,
//             仅保存视频 (Save Video Only), else 未整理
//   actions   what the row offers in that state, the first being the click's
//   place     which recordings an items' place lists
// No React here (recordings.test.ts).
import type { BatchRow, Job } from './api';
import type { Place } from './places';

/** recordings_list's row (apps/desktop/src-tauri/src/recordings.rs): the index's session plus its folder's facts. */
export interface RecordingInfo extends Pick<BatchRow, 'id' | 'dir' | 'project_id' | 'project_name' | 'title' | 'created' | 'duration' | 'item_count' | 'processed' | 'processing'> {
  /** recording.mp4, while it is there (housekeeping deletes organised recordings' videos after a while) */
  video: string | null;
  /** the first thing said in it */
  first_line: string | null;
  /** saved with Save Video Only */
  video_only: boolean;
}

/** a failure put away with Dismiss (`job_dismiss`) */
type JobLike = Job & { dismissed?: boolean };

export type RecState =
  | { kind: 'organising'; job: Job | null; step: string | null }
  | { kind: 'failed'; job: Job; code: string }
  | { kind: 'items'; n: number }
  | { kind: 'video_only' }
  | { kind: 'unorganised' };

export interface Recording {
  info: RecordingInfo;
  state: RecState;
}

/** Two spellings of one folder ("C:\\a\\b" and "c:/a/b/"). */
export function samePath(a: string | null | undefined, b: string | null | undefined): boolean {
  if (!a || !b) return false;
  const n = (p: string) => {
    const s = p.replace(/\\/g, '/').replace(/\/+$/, '');
    return /^[a-z]:\//i.test(s) ? s.toLowerCase() : s;
  };
  return n(a) === n(b);
}

/** The newest process job that organises this folder. */
export function jobOf(dir: string, jobs: readonly Job[]): Job | null {
  let best: Job | null = null;
  for (const j of jobs) {
    if (j.type !== 'process' || !samePath(j.session, dir)) continue;
    if (!best || (j.created || j.id) > (best.created || best.id)) best = j;
  }
  return best;
}

export function recState(r: RecordingInfo, jobs: readonly Job[]): RecState {
  const job = jobOf(r.dir, jobs) as JobLike | null;
  if (job && (job.state === 'running' || job.state === 'queued')) {
    const step = job.steps.find((s) => s.state === 'running') ?? null;
    return { kind: 'organising', job, step: step?.id ?? null };
  }
  if (!job && r.processing) return { kind: 'organising', job: null, step: null };
  if (job && job.state === 'failed' && !job.dismissed) return { kind: 'failed', job, code: job.error?.code || 'unknown' };
  if (job?.state === 'done' || r.processed || r.item_count > 0) return { kind: 'items', n: Math.max(r.item_count, job?.state === 'done' ? job.items.length : 0) };
  if (r.video_only) return { kind: 'video_only' };
  return { kind: 'unorganised' };
}

export const recordings = (infos: readonly RecordingInfo[], jobs: readonly Job[]): Recording[] => infos.map((info) => ({ info, state: recState(info, jobs) }));

/** It has items to be found by. */
export const hasItems = (r: Recording) => r.state.kind === 'items' && r.state.n > 0;

export type RecAction = 'review' | 'progress' | 'play' | 'reveal' | 'organise' | 'retry' | 'set_up_agent' | 'copy_request' | 'dismiss';

/** What a recording's row offers, the first being its click. `agent`: an agent can organise in the background (null
 *  while that isn't known yet: as if it could). */
export function recActions(r: Recording, agent: boolean | null): RecAction[] {
  const can = agent !== false;
  const play: RecAction[] = r.info.video ? ['play'] : [];
  // nothing to organise once the video is gone
  const organise: RecAction[] = !r.info.video ? [] : can ? ['organise'] : ['set_up_agent', 'copy_request'];
  switch (r.state.kind) {
    case 'organising':
      return [...(r.state.job ? ['progress' as const] : []), ...play, 'reveal'];
    case 'failed':
      return [...(can ? ['retry' as const] : ['set_up_agent' as const, 'copy_request' as const]), ...play, 'reveal', 'progress', 'dismiss'];
    case 'items':
      return r.state.n > 0 ? ['review', ...play, 'reveal'] : [...play, ...organise, 'reveal'];
    case 'video_only':
    case 'unorganised':
      return [...play, ...organise, 'reveal'];
  }
}

/** A recording's detail (its own, or its run's): one primary button — Retry or Organize when an agent can, else Set Up
 *  an Agent… (never both); Play Video for one saved with Save Video Only (kept, not organised: it was the user's
 *  choice) — and the rest secondary, what to say to an agent first. Its items' detail is elsewhere. */
export function detailActions(r: Recording, agent: boolean | null): { primary: RecAction | null; rest: RecAction[] } {
  const acts = recActions(r, agent).filter((a) => a !== 'progress');
  const lead = r.state.kind === 'video_only' ? (['play'] as RecAction[]) : ['retry', 'organise', 'set_up_agent', 'review'];
  const primary = acts.find((a) => lead.includes(a)) ?? null;
  const rest = acts.filter((a) => a !== primary);
  return { primary, rest: [...rest.filter((a) => a === 'copy_request'), ...rest.filter((a) => a !== 'copy_request')] };
}

/** The one action drawn on the row itself, beside its time: a failure's way forward, or Organise for one never
 *  organised (only with an agent to do it — without one, Home's Recording row already says how). */
export function inlineAction(r: Recording, agent: boolean | null): RecAction | null {
  const can = agent !== false;
  if (r.state.kind === 'failed') return can ? 'retry' : 'set_up_agent';
  if (r.state.kind === 'unorganised' && can && r.info.video) return 'organise';
  return null;
}

/** The recordings an items' place lists, newest first: Needs You and In Progress the ones under way or failed; Unassigned
 *  and a project their own that have no items (with items, the items are where it is). */
export function placeRecordings(rs: readonly Recording[], place: Place): Recording[] {
  const out = rs.filter((r) => {
    const k = r.state.kind;
    if (place === 'inbox') return k === 'failed' || k === 'organising';
    if (place === 'progress') return k === 'organising';
    if (place === 'unassigned') return r.info.project_id === 'inbox' && !hasItems(r);
    if (place.startsWith('project:')) return r.info.project_id === place.slice(8) && !hasItems(r);
    return false;
  });
  return out.sort((a, b) => (b.info.created ?? 0) - (a.info.created ?? 0));
}

/** The jobs section beside the recordings: a process job of a listed recording is that recording's row. */
export const jobsBesideRecordings = (jobs: readonly Job[], rs: readonly Recording[]) =>
  jobs.filter((j) => !(j.type === 'process' && rs.some((r) => samePath(r.info.dir, j.session))));

/** The jobs section of an items' place (the Mac's MainModel.reloadJobs): the running jobs, and the failures still
 *  waiting for a Retry or Dismiss (jobs.rs `waiting`, BlurtCore JobFailures) — a recording's own job is that
 *  recording's row, never a job row beside it. */
export function placeJobList(jobs: readonly Job[], rs: readonly Recording[], place: Place): Job[] {
  const shown = jobsBesideRecordings(jobs, rs).filter((j) => j.state === 'running' || j.state === 'queued' || j.waiting);
  if (place === 'unassigned') return shown.filter((j) => !j.project || j.project === 'inbox');
  if (place.startsWith('project:')) return shown.filter((j) => j.project === place.slice(8));
  return place === 'inbox' || place === 'progress' ? shown : [];
}

/** A place's empty state ("All filed", "Nothing needs you") only when neither items nor recordings are listed. */
export const emptyStateShown = (itemRows: number, recordingRows: number) => itemRows === 0 && recordingRows === 0;
