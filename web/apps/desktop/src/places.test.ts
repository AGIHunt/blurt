import { describe, expect, it } from 'vitest';
import type { ItemRow, Job, ProjectRow } from './api';
import { actionForListKey, bannerPlan, bySuggestion, group, grouping, handOffBlock, listDate, orderedProjects, placeQuery, NO_FILTER } from './places';

const row = (uid: string, state: ItemRow['state'], project = 'p1', more: Partial<ItemRow> = {}) => ({ uid, state, project_id: project, item_id: uid.toUpperCase(), title: uid, ...more }) as ItemRow;
const proj = (id: string, more: Partial<ProjectRow> = {}) => ({ id, name: id, key: id.toUpperCase(), ...more }) as ProjectRow;

describe('places (MainModel.query)', () => {
  it('queries each place as the Mac does', () => {
    expect(placeQuery('inbox', NO_FILTER, '', 'updated', false, 10).state).toEqual(['new', 'to_verify']);
    expect(placeQuery('progress', NO_FILTER, '', 'updated', false, 10).state).toEqual(['handed_off', 'in_progress', 'to_verify']);
    expect(placeQuery('progress', { kinds: [], state: 'done' }, '', 'updated', false, 10).state).toEqual(['done']);
    expect(placeQuery('unassigned', NO_FILTER, '', 'updated', false, 10).project).toBe('inbox');
    expect(placeQuery('project:p2', { kinds: ['idea'], state: null }, ' x ', 'title', true, 10)).toMatchObject({ project: 'p2', kind: ['idea'], query: 'x', sort: 'title', ascending: true });
    // the Inbox has no State control: a saved state never narrows it
    expect(placeQuery('inbox', { kinds: [], state: 'done' }, '', 'updated', false, 10).state).toEqual(['new', 'to_verify']);
  });
  it('groups: the Inbox by project (Unassigned last), the rest by state, none while searching', () => {
    expect(grouping('inbox', false)).toBe('project');
    expect(grouping('all', false)).toBe('state');
    expect(grouping('all', true)).toBe('none');
    expect(grouping('unassigned', false)).toBe('none');
    const g = group([row('a', 'new', 'inbox'), row('b', 'new', 'p2'), row('c', 'to_verify', 'p1'), row('d', 'new', 'p2')], 'project', ['p1', 'p2']);
    expect(g.rows.map((r) => r.uid)).toEqual(['c', 'b', 'd', 'a']);
    expect([...g.sections.values()].map((s) => [s.key, s.count])).toEqual([['p1', 1], ['p2', 2], ['inbox', 1]]);
    const s = group([row('a', 'new'), row('b', 'done'), row('c', 'to_verify')], 'state', []);
    expect(s.rows.map((r) => r.uid)).toEqual(['c', 'a', 'b']);
    // one run alone has no header
    expect(group([row('a', 'new'), row('b', 'new')], 'state', []).sections.size).toBe(0);
  });
  it('orders projects pinned first, then the most recently used', () => {
    const ps = [proj('a', { last_used: '2026-10-01' }), proj('b', { last_used: '2026-10-05' }), proj('c', { pinned: true, last_used: '2026-01-01' })];
    expect(orderedProjects(ps).map((p) => p.id)).toEqual(['c', 'b', 'a']);
  });
  it('puts suggested Unassigned items first, by project name', () => {
    const rows = [row('a', 'new', 'inbox'), row('b', 'new', 'inbox', { suggested_project: 'zed' }), row('c', 'new', 'inbox', { suggested_project: 'atlas' })];
    expect(bySuggestion(rows, [proj('zed'), proj('atlas')]).map((r) => r.uid)).toEqual(['c', 'b', 'a']);
  });
});

describe('keys and hand-off (Lifecycle, HandOffCheck)', () => {
  it('maps the list keys from each item’s own state', () => {
    expect(actionForListKey('r', 'to_verify')).toBe('send_back');
    expect(actionForListKey('R', 'done')).toBe('reopen');
    expect(actionForListKey('r', 'discarded')).toBe('restore');
    expect(actionForListKey('Delete', 'new')).toBe('discard');
    expect(actionForListKey('a', 'todo')).toBeNull();
  });
  it('says why a hand-off can’t go', () => {
    const none = () => null;
    expect(handOffBlock([row('a', 'new', 'inbox')], none)).toEqual({ why: 'needs_project' });
    expect(handOffBlock([row('a', 'new', 'p1'), row('b', 'todo', 'p2')], none)).toEqual({ why: 'mixed_projects' });
    expect(handOffBlock([row('a', 'done')], none)).toEqual({ why: 'finished', state: 'done' });
    expect(handOffBlock([row('a', 'discarded')], none)).toEqual({ why: 'discarded' });
    expect(handOffBlock([row('a', 'in_progress')], () => 'j1')).toEqual({ why: 'with_session', item: 'A', job: 'j1' });
    expect(handOffBlock([row('a', 'new')], none)).toBeNull();
  });
  it('dates the rows like Loc.listDate', () => {
    const now = new Date(2026, 10, 2, 15, 0);
    const at = (d: Date) => d.getTime() / 1000;
    expect(listDate(at(new Date(2026, 10, 2, 9, 5)), 'en-US', 'Yesterday', now)).toMatch(/9:05/);
    expect(listDate(at(new Date(2026, 10, 1, 9, 5)), 'en-US', 'Yesterday', now)).toBe('Yesterday');
    expect(listDate(at(new Date(2026, 9, 29)), 'en-US', 'Yesterday', now)).toBe('Thu');
    expect(listDate(at(new Date(2026, 6, 4)), 'en-US', 'Yesterday', now)).toBe('Jul 4');
  });
});

import { prefillFromText } from './components/NewItemSheet';
import { keyValid } from './components/ProjectSettingsSheet';

describe('New Item and Project Settings', () => {
  it('takes pasted text as a title and details', () => {
    expect(prefillFromText('Login is slow\nTakes 8 s on Wi-Fi')).toEqual({ title: 'Login is slow', details: 'Takes 8 s on Wi-Fi', images: [] });
    const long = 'x'.repeat(80);
    expect(prefillFromText(long).title).toHaveLength(60);
    expect(prefillFromText(long).details).toBe(long);
  });
  it('checks a project key as projects.py does', () => {
    expect(keyValid('SF')).toBe(true);
    expect(keyValid('IOS2')).toBe(true);
    expect(keyValid('IN')).toBe(false);
    expect(keyValid('2X')).toBe(false);
    expect(keyValid('TOOLONG')).toBe(false);
  });
});

describe('the item banner (WebHostController.ItemBanner + SessionBannerPlan)', () => {
  const w = { agent: (id: string) => (id === 'claude' ? 'Claude Code' : id), why: (j: Job) => j.error?.message ?? 'error', t: (k: string) => k };
  const job = (more: Partial<Job> & { status?: string; worktree?: boolean }): Job =>
    ({ id: 'j1', type: 'agent', state: 'running', project: 'p1', session: null, title: null, items: ['a'], steps: [], progress: null, created: '2026-11-02T10:00:00Z', started: '2026-11-02T10:00:01Z', ended: null, error: null,
      agent: { id: 'claude', mode: 'auto', runner: 'tmux', status: (more.status ?? 'running') as never, cwd: '/p', worktree: more.worktree ? { path: '/w', branch: 'b', base: 'main' } : null }, ...more }) as Job;
  const item = (state: ItemRow['state'], more: Partial<ItemRow> = {}) => row('a', state, 'p1', { work_to: 'session', work_agent: 'claude', ...more });
  it('says who has it and offers Open Session while the session lives', () => {
    const p = bannerPlan(item('in_progress'), [job({})], w)!;
    expect(p).toMatchObject({ kind: 'session', tone: 'brand', actions: ['session'], primary: 'session', job: 'j1' });
    expect(p.text).toEqual({ key: 'main.banner.with_agent', args: ['Claude Code', 'session.running'] });
    expect(bannerPlan(item('in_progress'), [job({ status: 'waiting_input' })], w)!.tone).toBe('attn');
  });
  it('after the session: review a worktree, restart a plain end, restart or take back a failure', () => {
    expect(bannerPlan(item('in_progress'), [job({ state: 'done', status: 'exited', worktree: true })], w)).toMatchObject({ actions: ['review', 'take_back'], more: ['done'] });
    expect(bannerPlan(item('in_progress'), [job({ state: 'done', status: 'exited' })], w)).toMatchObject({ actions: ['session', 'restart'], more: ['done', 'take_back'] });
    const f = bannerPlan(item('handed_off'), [job({ state: 'failed', status: 'error', ended: '2026-11-02T10:00:05Z', error: { code: 'x', message: 'not logged in' } })], w)!;
    expect(f).toMatchObject({ icon: 'error', actions: ['restart', 'take_back'], more: ['session'] });
    expect(f.text).toEqual({ key: 'main.banner.failed_start', args: ['Claude Code', 'not logged in'] });
    // no record of the session any more
    expect(bannerPlan(item('in_progress'), [], w)).toMatchObject({ actions: ['take_back', 'done'], job: null });
  });
  it("the user's own agent: Won't Do, then Mark as Done as the primary", () => {
    expect(bannerPlan(item('handed_off', { work_to: 'external' }), [], w)).toMatchObject({ kind: 'external', actions: ['wontfix', 'done'], primary: 'done' });
  });
  it('organising its batch; nothing for to verify, new without a job, or discarded', () => {
    const p = { ...job({}), id: 'p9', type: 'process', session: '/s1', agent: undefined } as Job;
    expect(bannerPlan(item('new', { work_to: null, session_dir: '/s1' }), [p], w)).toMatchObject({ kind: 'organizing', actions: ['progress'], job: 'p9' });
    expect(bannerPlan(item('new', { work_to: null, session_dir: '/s2' }), [p], w)).toBeNull();
    expect(bannerPlan(item('to_verify'), [job({})], w)).toBeNull();
    expect(bannerPlan(item('in_progress', { work_to: null, work_agent: null }), [], w)).toMatchObject({ kind: 'external', primary: 'done' });
    expect(bannerPlan(item('discarded'), [job({})], w)).toBeNull();
  });
});
