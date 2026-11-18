import { describe, expect, it } from 'vitest';
import type { ScreenTextEntry } from './api';
import { byDay, click, copied, keepLine, matches, NONE, step } from './screentext';

const e = (id: string, time: number, text: string, more: Partial<ScreenTextEntry> = {}): ScreenTextEntry => ({ id, time, translated: false, text, ...more });

describe('the Text & Translation page', () => {
  const tr = e('t', 30, '文件名带空格时导出会失败', { translated: true, source: 'The export fails when the name has spaces', app: 'Microsoft Edge' });
  const cp = e('c', 20, 'npm ERR! code ERESOLVE', { app: 'Windows Terminal' });

  it('search: every word in the text, the original or the app', () => {
    expect(matches(tr, 'export spaces')).toBe(true);
    expect(matches(tr, 'edge 导出')).toBe(true);
    expect(matches(cp, 'terminal eresolve')).toBe(true);
    expect(matches(cp, 'export')).toBe(false);
    expect(matches(cp, '  ')).toBe(true);
  });

  it('days: newest first, the order kept', () => {
    const at = (d: number, h: number) => new Date(2026, 10, d, h).getTime() / 1000;
    const days = byDay([e('a', at(16, 15), 'a'), e('b', at(16, 9), 'b'), e('c', at(15, 22), 'c')]);
    expect(days.map((d) => d.rows.map((r) => r.id))).toEqual([['a', 'b'], ['c']]);
  });

  it('click, Ctrl-click, Shift-click', () => {
    const order = ['a', 'b', 'c', 'd'];
    let s = click(NONE, 'b', order, {});
    expect(s.ids).toEqual(['b']);
    s = click(s, 'd', order, { range: true });
    expect(s.ids).toEqual(['b', 'c', 'd']);
    s = click(s, 'c', order, { toggle: true });
    expect(s.ids).toEqual(['b', 'd']);
    s = click(s, 'a', order, { toggle: true });
    expect(s.ids).toEqual(['b', 'd', 'a']);
    expect(click(s, 'c', order, {}).ids).toEqual(['c']);
  });

  it('the arrows move, with Shift they extend from the anchor', () => {
    const order = ['a', 'b', 'c', 'd'];
    expect(step(NONE, order, 1, false).ids).toEqual(['a']);
    let s = step({ ids: ['b'], anchor: 'b' }, order, 1, false);
    expect(s.ids).toEqual(['c']);
    s = step(s, order, 1, true);
    expect(s.ids).toEqual(['c', 'd']);
    s = step(s, order, -1, true);
    expect(s.ids).toEqual(['c']);
    s = step(s, order, -1, true);
    expect(s.ids).toEqual(['b', 'c']);
    expect(step({ ids: ['d'], anchor: 'd' }, order, 1, false).ids).toEqual(['d']);
  });

  it('copy: in the list’s order, a blank line between; Copy Original takes a translation’s original', () => {
    expect(copied([tr, cp], ['c', 't'])).toBe('文件名带空格时导出会失败\n\nnpm ERR! code ERESOLVE');
    expect(copied([tr, cp], ['t', 'c'], true)).toBe('The export fails when the name has spaces\n\nnpm ERR! code ERESOLVE');
  });

  it('how long it keeps', () => {
    const t = (k: string, p?: Record<string, string | number>) => `${k}${p ? JSON.stringify(p) : ''}`;
    expect(keepLine(0, 5, t)).toBe('home.screen_text.summary.off');
    expect(keepLine(-1, 5, t)).toBe('home.screen_text.summary.forever{"n":5}');
    expect(keepLine(7, 5, t)).toBe('home.screen_text.summary{"n":5,"a":"home.screen_text.days{\\"n\\":7}"}');
  });
});
