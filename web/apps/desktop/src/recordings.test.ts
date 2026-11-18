import { describe, expect, it } from 'vitest';
import type { Job } from './api';
import { detailActions, emptyStateShown, inlineAction, jobOf, jobsBesideRecordings, placeJobList, placeRecordings, recActions, recordings, recState, samePath, type RecordingInfo } from './recordings';

const info = (dir: string, more: Partial<RecordingInfo> = {}): RecordingInfo => ({
  id: `inbox:${dir}`, dir, project_id: 'inbox', project_name: 'Unassigned', title: null, created: 100, duration: 60,
  item_count: 0, processed: 0, processing: 0, video: `${dir}/recording.mp4`, first_line: null, video_only: false, ...more,
});
const job = (id: string, session: string | null, state: Job['state'], more: Partial<Job> & { dismissed?: boolean } = {}): Job => ({
  id, type: 'process', state, project: null, session, title: null, items: [], steps: [], progress: null,
  created: `2026-11-18T10:${id.slice(-2)}:00+08:00`, started: null, ended: null, error: null, ...more,
});

describe('a recording’s state', () => {
  it('follows its newest process job, as record.py take_state does', () => {
    const r = info('/s/a');
    expect(recState(r, []).kind).toBe('unorganised');
    expect(recState(r, [job('j01', '/s/a', 'running', { steps: [{ id: 'transcribe', state: 'running' }] })])).toMatchObject({ kind: 'organising', step: 'transcribe' });
    expect(recState(r, [job('j01', '/s/a', 'failed', { error: { code: 'no_agent', message: '' } })])).toMatchObject({ kind: 'failed', code: 'no_agent' });
    // a retry after the failure: the newer run counts
    expect(recState(r, [job('j01', '/s/a', 'failed'), job('j02', '/s/a', 'running')]).kind).toBe('organising');
    expect(recState(r, [job('j01', '/s/a', 'failed'), job('j02', '/s/a', 'done', { items: ['u1', 'u2'] })])).toEqual({ kind: 'items', n: 2 });
    // another folder's job, or a snap job, isn't this one's
    expect(recState(r, [job('j01', '/s/b', 'failed'), { ...job('j02', '/s/a', 'failed'), type: 'snap' }]).kind).toBe('unorganised');
  });

  it('a dismissed failure is just not organised; Save Video Only stays that; the index says processing / items', () => {
    expect(recState(info('/s/a'), [job('j01', '/s/a', 'failed', { dismissed: true })]).kind).toBe('unorganised');
    expect(recState(info('/s/a', { video_only: true }), []).kind).toBe('video_only');
    expect(recState(info('/s/a', { processing: 1 }), [])).toEqual({ kind: 'organising', job: null, step: null });
    expect(recState(info('/s/a', { processed: 1, item_count: 3 }), [])).toEqual({ kind: 'items', n: 3 });
    expect(recState(info('/s/a', { processed: 1 }), [])).toEqual({ kind: 'items', n: 0 });
  });

  it('matches a job to its folder however the path is spelled', () => {
    expect(samePath('C:\\Users\\m\\Blurt\\inbox\\sessions\\x', 'c:/Users/m/Blurt/inbox/sessions/x/')).toBe(true);
    expect(samePath('/home/m/a', '/home/m/A')).toBe(false);
    expect(jobOf('C:\\a\\s', [job('j01', 'c:/a/s', 'failed')])?.id).toBe('j01');
  });
});

describe('what a recording’s row offers', () => {
  const rec = (state: Parameters<typeof recordings>[1], more: Partial<RecordingInfo> = {}) => recordings([info('/s/a', more)], state)[0];

  it('a failure: Retry with an agent, else Set Up an Agent… and what to say; Dismiss last', () => {
    const r = rec([job('j01', '/s/a', 'failed')]);
    expect(recActions(r, true)).toEqual(['retry', 'play', 'reveal', 'progress', 'dismiss']);
    expect(recActions(r, false)).toEqual(['set_up_agent', 'copy_request', 'play', 'reveal', 'progress', 'dismiss']);
    expect(inlineAction(r, true)).toBe('retry');
    expect(inlineAction(r, false)).toBe('set_up_agent');
    // not known yet: as if an agent could
    expect(inlineAction(r, null)).toBe('retry');
  });

  it('never organised: play it, Organise it; organised: its items first', () => {
    expect(recActions(rec([]), true)).toEqual(['play', 'organise', 'reveal']);
    expect(inlineAction(rec([]), true)).toBe('organise');
    expect(inlineAction(rec([]), false)).toBe(null);
    expect(recActions(rec([], { item_count: 2, processed: 1 }), true)).toEqual(['review', 'play', 'reveal']);
    expect(recActions(rec([job('j01', '/s/a', 'running')]), true)).toEqual(['progress', 'play', 'reveal']);
  });

  it('its detail: one primary — Retry or Organize with an agent, else Set Up an Agent…, never both', () => {
    const failed = rec([job('j01', '/s/a', 'failed', { error: { code: 'no_agent', message: '' } })]);
    expect(detailActions(failed, true)).toEqual({ primary: 'retry', rest: ['play', 'reveal', 'dismiss'] });
    expect(detailActions(failed, false)).toEqual({ primary: 'set_up_agent', rest: ['copy_request', 'play', 'reveal', 'dismiss'] });
    expect(detailActions(rec([]), true)).toEqual({ primary: 'organise', rest: ['play', 'reveal'] });
    expect(detailActions(rec([]), false)).toEqual({ primary: 'set_up_agent', rest: ['copy_request', 'play', 'reveal'] });
    expect(detailActions(rec([job('j01', '/s/a', 'running')]), true)).toEqual({ primary: null, rest: ['play', 'reveal'] });
    // Save Video Only was the user's choice: the video first, organising still there
    expect(detailActions(rec([], { video_only: true }), false)).toEqual({ primary: 'play', rest: ['copy_request', 'set_up_agent', 'reveal'] });
  });

  it('the video gone: no Play, nothing to organise, Show in Folder stays', () => {
    expect(recActions(rec([], { video: null }), true)).toEqual(['reveal']);
    expect(recActions(rec([], { video: null, item_count: 1, processed: 1 }), true)).toEqual(['review', 'reveal']);
    expect(inlineAction(rec([], { video: null }), true)).toBe(null);
  });
});

describe('where recordings are listed', () => {
  const infos = [
    info('/i/failed', { created: 5 }),
    info('/i/never', { created: 4 }),
    info('/i/done', { created: 3, processed: 1, item_count: 2 }),
    info('/p/running', { created: 2, project_id: 'p1' }),
    info('/i/video', { created: 1, video_only: true }),
  ];
  const jobs = [job('j01', '/i/failed', 'failed'), job('j02', '/p/running', 'running'), job('j03', '/x/shots', 'running')];
  const rs = recordings(infos, jobs);
  const dirs = (p: Parameters<typeof placeRecordings>[1]) => placeRecordings(rs, p).map((r) => r.info.dir);

  it('Needs You: failed and under way; In Progress: under way; a place: its own without items', () => {
    expect(dirs('inbox')).toEqual(['/i/failed', '/p/running']);
    expect(dirs('progress')).toEqual(['/p/running']);
    expect(dirs('unassigned')).toEqual(['/i/failed', '/i/never', '/i/video']);
    expect(dirs('project:p1')).toEqual(['/p/running']);
    expect(dirs('all')).toEqual([]);
    expect(dirs('home')).toEqual([]);
  });

  it('one recording is one row: its organising job leaves the jobs section; other jobs stay', () => {
    expect(jobsBesideRecordings(jobs, rs).map((j) => j.id)).toEqual(['j03']);
  });

  it('the jobs section keeps failures waiting for Retry or Dismiss, but never a listed recording’s own', () => {
    const more = [
      ...jobs,
      // a waiting failure of a listed recording: drawn as that recording's row
      job('j04', '/i/failed', 'failed', { waiting: true }),
      // a routing failure waiting for Retry, and an old one no longer waiting
      { ...job('j05', null, 'failed', { waiting: true, project: 'p1' }), type: 'route' as const },
      { ...job('j06', null, 'failed'), type: 'route' as const },
    ];
    expect(placeJobList(more, rs, 'inbox').map((j) => j.id)).toEqual(['j03', 'j05']);
    expect(placeJobList(more, rs, 'project:p1').map((j) => j.id)).toEqual(['j05']);
    expect(placeJobList(more, rs, 'unassigned').map((j) => j.id)).toEqual(['j03']);
    expect(placeJobList(more, rs, 'all')).toEqual([]);
  });

  it('an empty state only when neither items nor recordings are listed (no "All filed" over unorganised recordings)', () => {
    expect(emptyStateShown(0, 0)).toBe(true);
    expect(emptyStateShown(0, dirs('unassigned').length)).toBe(false);
    expect(emptyStateShown(3, 0)).toBe(false);
  });
});
