import { describe, expect, it } from 'vitest';
import type { DictationEntry } from './api';
import { appName, byDay, changes, exception, marked, matches, preview, stats, units } from './dictation';
import EN from './locales/en.json';
import ZH from './locales/zh-Hans.json';
import { checkCatalogs } from '@blurt/i18n';

const e = (o: Partial<DictationEntry>): DictationEntry => ({
  id: 'd-1', t: '2026-11-02T10:00:00+08:00', app: 'chrome', bundle: 'chrome.exe', duration: 3, raw: 'um hello', polished: 'Hello.',
  text: 'Hello.', model: 'm', fell_back: false, reason: null, insert: 'pasted', audio: null, ...o,
});

describe('dictation page rules', () => {
  it('says how a take went in, one fact', () => {
    expect(exception(e({}))).toBeNull();
    expect(exception(e({ insert: 'copied' }))).toBe('copied');
    expect(exception(e({ insert: 'copied', fell_back: true }))).toBe('copied_raw');
    expect(exception(e({ fell_back: true }))).toBe('fell_back');
  });

  it('names Windows apps by what people call them', () => {
    expect(appName(e({ app: 'WINWORD' }))).toBe('Word');
    expect(appName(e({ app: 'chrome' }))).toBe('Chrome');
    expect(appName(e({ app: 'myapp' }))).toBe('Myapp');
    expect(appName(e({ app: null, bundle: null }))).toBeNull();
  });

  it('searches the text as it stands, what was heard and the app', () => {
    const x = e({ corrected: 'Hello there.' });
    expect(matches(x, 'there', appName)).toBe(true);
    expect(matches(x, 'um', appName)).toBe(true);
    expect(matches(x, 'chrome', appName)).toBe(true);
    expect(matches(x, 'slack', appName)).toBe(false);
  });

  it('marks the search words', () => {
    expect(marked('Hello hello', ['hel'])).toEqual([['Hel', true], ['lo ', false], ['hel', true], ['lo', false]]);
  });

  it('counts a CJK character as a word and the minutes saved', () => {
    expect(units('记得问 the design')).toEqual([3, 2]);
    expect(stats([e({ text: 'word '.repeat(80), duration: 30 })]).savedMinutes).toBe(1);
  });

  it('groups by local day, newest first', () => {
    const g = byDay([e({ id: 'a', t: '2026-11-02T10:00:00' }), e({ id: 'b', t: '2026-11-02T08:00:00' }), e({ id: 'c', t: '2026-11-01T22:00:00' })]);
    expect(g.map((x) => x.rows.map((r) => r.id))).toEqual([['a', 'b'], ['c']]);
  });

  it('marks what polish left out and added, never punctuation alone', () => {
    const r = changes('um can you push the release', 'Can you push the release?');
    expect(r.filter((x) => x.op === 'removed').map((x) => x.text.trim())).toEqual(['um']);
    expect(r.filter((x) => x.op === 'added').map((x) => x.text)).toEqual(['Can']);
    expect(r.map((x) => (x.op === 'removed' ? '' : x.text)).join('')).toBe('Can you push the release?');
    expect(changes('hello big world', 'hello world').map((x) => x.text).join('')).toBe('hello big world');
    expect(changes('那个结算按钮', '结算按钮。').filter((x) => x.op === 'removed').map((x) => x.text)).toEqual(['那个']);
  });

  it('keeps a list typed on several lines as one paragraph in the row', () => {
    expect(preview('Three things:\n1. A\n2. B')).toBe('Three things: 1. A 2. B');
  });

  it('has every dictation_page string in both languages', () => {
    const pick = (c: Record<string, string>) => Object.fromEntries(Object.entries(c).filter(([k]) => k.startsWith('dictation_page.')));
    expect(checkCatalogs(pick(EN), pick(ZH))).toEqual([]);
  });
});
