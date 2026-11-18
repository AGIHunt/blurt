import { describe, expect, it } from 'vitest';
import { dropSuperseded, queueLine } from '../src/toastqueue';

describe('lines waiting for the take’s ✓ moment', () => {
  it('keeps one line per key, the newest, in its first place', () => {
    const q: { key?: string; msg: string }[] = [];
    queueLine(q, { key: 'refile.a', msg: 'rec.preparing' });
    queueLine(q, { key: 'cards', msg: 'cards' });
    queueLine(q, { key: 'refile.a', msg: 'rec.saved_no_agent' });
    expect(q.map((l) => l.msg)).toEqual(['rec.saved_no_agent', 'cards']);
  });
  it('keeps lines with no key, in order', () => {
    const q: { key?: string; msg: string }[] = [];
    queueLine(q, { msg: 'one' });
    queueLine(q, { msg: 'two' });
    expect(q.map((l) => l.msg)).toEqual(['one', 'two']);
  });
  it('drops a waiting line once a later one of its key is shown', () => {
    const q = [{ key: 'refile.a', msg: 'rec.preparing' }];
    dropSuperseded(q, { key: 'refile.a', msg: 'rec.organizing' });
    expect(q).toEqual([]);
  });
});
