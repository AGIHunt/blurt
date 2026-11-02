// The sessions model against the Mac's rules (SessionsModel.swift, SessionOutcome.swift, SessionsViews.swift).
import { beforeEach, describe, expect, it } from 'vitest';
import type { SessionJob } from './api';
import { setLang } from './i18n';
import { branchWords, build, countText, endedHint, endedTitle, errorWords, mark, outcome, parseError, preferred, stateText, toRow } from './sessions';

const now = Date.now() / 1000;
const iso = (ago: number) => new Date((now - ago) * 1000).toISOString();

function job(o: Omit<Partial<SessionJob>, 'agent'> & { agent?: Partial<SessionJob['agent']> } = {}): SessionJob {
  const { agent, ...rest } = o;
  return {
    id: 'j-1', type: 'agent', state: 'running', project: 'p1', session: null, title: null, items: ['u1'], steps: [], progress: null,
    created: iso(600), started: iso(600), ended: null, error: null, labels: [{ id: 'SF-9', title: 'Avatar upload returns 500' }],
    folder_gone: false, log: null, handoff_path: null, owned: true, output: true,
    agent: { id: 'claude', status: 'running', runner: 'app', started: true, ...agent },
    ...rest,
  } as SessionJob;
}
const name = () => 'storefront';

beforeEach(() => void setLang('en'));

describe('outcome and marks', () => {
  it('live statuses', () => {
    expect(mark(job())).toBe('working');
    expect(mark(job({ agent: { status: 'waiting_input' } }))).toBe('waiting');
    expect(mark(job({ agent: { status: 'turn_done' } }))).toBe('waiting');
    expect(mark(job({ agent: { status: 'running', status_source: 'watchdog' } }))).toBe('waiting');
    expect(stateText(job({ agent: { status: 'running', status_source: 'watchdog' } }))).toBe('No response');
    expect(stateText(job({ agent: { status: 'turn_done' } }))).toBe('Waiting for you');
  });
  it('ended with changes is to review; without them, no changes', () => {
    const wt = { path: '/w', branch: 'blurt/sf-9-avatar', base: 'main' };
    const review = job({ state: 'done', ended: iso(10), agent: { status: 'exited', worktree: wt, changes: { ahead: 1, dirty: 0 } } });
    expect(outcome(review).kind).toBe('review');
    expect(mark(review)).toBe('waiting');
    expect(stateText(review)).toBe('Ready to review');
    expect(stateText({ ...review, folder_gone: true })).toBe('Folder is gone');
    const none = job({ state: 'done', ended: iso(10), agent: { status: 'exited', worktree: wt, changes: { ahead: 0, dirty: 0 } } });
    expect(outcome(none).kind).toBe('noChanges');
    expect(mark(none)).toBe('idle');
  });
  it('failed at start vs later', () => {
    const early = job({ state: 'failed', started: iso(30), ended: iso(25), agent: { status: 'error', started: false } });
    expect(outcome(early)).toEqual({ kind: 'failed', atStart: true });
    expect(stateText(early)).toBe('Couldn’t start');
    const late = job({ state: 'failed', started: iso(600), ended: iso(10), agent: { status: 'error', started: true } });
    expect(outcome(late)).toEqual({ kind: 'failed', atStart: false });
    expect(mark(late)).toBe('failed');
    expect(endedTitle(toRow(late, name))).toBe('Claude Code stopped with an error');
    expect(endedTitle(toRow(job({ state: 'done', agent: { status: 'exited', stopped_at: 'trust' } }), name))).toBe('Claude Code stopped at its trust question');
  });
  it('finished by the user', () => {
    expect(mark(job({ state: 'done', agent: { status: 'exited', finish: { action: 'merge' } } }))).toBe('done');
    expect(stateText(job({ state: 'done', agent: { status: 'exited', finish: { action: 'pr', result: {} } } }))).toBe('Pushed');
    expect(stateText(job({ state: 'done', agent: { status: 'exited', finish: { action: 'pr', result: { pr: 'https://x/1' } } } }))).toBe('Pull request opened');
    expect(mark(job({ state: 'cancelled', agent: { status: 'exited', finish: { action: 'restart' } } }))).toBe('idle');
  });
  it('the desktop app: an outward arrow, not working', () => {
    expect(mark(job({ agent: { runner: 'desktop', status: 'running' } }))).toBe('elsewhere');
  });
});

describe('rows', () => {
  it('label, subtitle, sorting, groups, the count', () => {
    const a = job({ id: 'a', created: iso(100), agent: { status: 'running', tmux: { name: 'SF-1,SF-2' } }, labels: [{ id: 'SF-1', title: 'One' }, { id: 'SF-2', title: 'Two' }] });
    const b = job({ id: 'b', project: 'p2', created: iso(50), agent: { status: 'waiting_input' } });
    const c = job({ id: 'c', state: 'done', created: iso(10), ended: iso(5), agent: { status: 'exited' } });
    const { rows, groups } = build([c, a, b], (id) => (id === 'p1' ? 'storefront' : 'mobile'));
    expect(rows.map((r) => r.id)).toEqual(['b', 'a', 'c']);
    expect(rows[1].label).toBe('SF-1, SF-2');
    expect(rows[1].subtitle).toBe('One +1');
    expect(groups.map((g) => g.name)).toEqual(['mobile', 'storefront']);
    expect(countText(rows)).toBe('1 working · 1 waiting on you');
    expect(preferred(rows)?.id).toBe('b');
    expect(rows[2].needsYou).toBe(false);
  });
  it('branch words', () => {
    expect(branchWords('blurt/aw-12-create-hello', ['AW-12'])).toBe('create-hello');
    expect(branchWords('blurt/aw-12', ['AW-12'])).toBe('aw-12');
    expect(branchWords('feature/x', [])).toBe('feature/x');
  });
  it('what waits after a merge', () => {
    const r = toRow(job({ state: 'done', agent: { status: 'exited', finish: { action: 'merge' }, worktree: { path: '/w', branch: 'b', base: 'main' } } }), name);
    expect(endedHint(r, { u1: { uid: 'u1', item_id: 'SF-9', kind: 'issue', title: 'x', state: 'to_verify' } })).toBe('Merged into main · SF-9 is waiting for you to verify.');
    const e = toRow(job({ state: 'done', agent: { status: 'exited' } }), name);
    expect(endedHint(e, { u1: { uid: 'u1', item_id: 'SF-9', kind: 'issue', title: 'x', state: 'in_progress' } })).toMatch(/didn’t report back/);
  });
});

describe('errors', () => {
  it('reads the code and what the CLI said with it', () => {
    const e = 'sessions.py dispatch: SF-9 is already in a session {"job":"j-7","item_id":"SF-9"} [already_dispatched]';
    expect(parseError(e)).toMatchObject({ code: 'already_dispatched', job: 'j-7', item_id: 'SF-9' });
    expect(errorWords(e)).toBe('SF-9 is already in a running session.');
    expect(errorWords('x {"agent":"codex","version":"0.157.0","need":"0.164.0","fix":"npm i -g @openai/codex"} [outdated]'))
      .toBe('Codex 0.157.0 is too old for hand-offs (needs 0.164 or later). Update it in a terminal, then check again. npm i -g @openai/codex');
    expect(errorWords('boom [weird_code]')).toMatch(/That didn’t work/);
  });
});
