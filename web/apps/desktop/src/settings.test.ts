// Settings' catalog and search (the Mac's SettingsCatalogTests): every row's words exist in both languages, the
// search finds what the Mac's finds, and the settings strings match key for key.
import { describe, expect, it } from 'vitest';
import SET_EN from './locales/settings.en.json';
import SET_ZH from './locales/settings.zh-Hans.json';
import { ENTRIES, GROUPS, PANES, results, SECTIONS, SHORTCUT_SECTIONS, SUGGESTIONS, textIn } from './settings/catalog';

const ph = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(',');

describe('settings strings', () => {
  it('en and zh-Hans have the same keys and placeholders', () => {
    expect(Object.keys(SET_ZH).sort()).toEqual(Object.keys(SET_EN).sort());
    for (const [k, v] of Object.entries(SET_EN)) expect(ph(SET_ZH[k as keyof typeof SET_ZH]), k).toBe(ph(v));
  });
  it('every pane, group, section and row has its words in both languages', () => {
    const keys = [
      ...PANES.map((p) => p.title),
      ...GROUPS.map((g) => g.title),
      ...Object.values(SECTIONS),
      ...ENTRIES.flatMap((e) => [e.title, e.detail, e.more].filter((k): k is string => !!k)),
      ...SUGGESTIONS,
    ];
    for (const k of keys) {
      expect(textIn(k, 'en'), k).toBeTruthy();
      expect(textIn(k, 'zh-Hans'), k).toBeTruthy();
    }
  });
  it('the Mac says nothing about its own system here', () => {
    for (const k of ENTRIES.flatMap((e) => [e.title, e.detail, e.more].filter((x): x is string => !!x))) {
      expect(textIn(k, 'en'), k).not.toMatch(/⌘|⌥|macOS|Finder|notch|Keychain|Option key/);
      expect(textIn(k, 'zh-Hans'), k).not.toMatch(/⌘|⌥|macOS|访达|刘海|钥匙串/);
    }
  });
  it('ids are unique and every section a row names exists', () => {
    expect(new Set(ENTRIES.map((e) => e.id)).size).toBe(ENTRIES.length);
    for (const e of ENTRIES) if (e.section) expect(SECTIONS[e.section], e.id).toBeTruthy();
    expect(SHORTCUT_SECTIONS.flatMap((s) => s.actions)).not.toContain('marker');
  });
});

describe('settings search', () => {
  const panes = (q: string, l: 'en' | 'zh-Hans' = 'en') => results(q, l).map((g) => g.pane);
  it('a pane named by its start is found as a whole and leads', () => {
    const r = results('short', 'en');
    expect(r[0]).toMatchObject({ pane: 'shortcuts', paneHit: true });
    expect(results('快捷', 'zh-Hans')[0]).toMatchObject({ pane: 'shortcuts', paneHit: true });
  });
  it('a pane found only by its keywords ("hotkey")', () => {
    expect(results('hotkey', 'en')[0]).toMatchObject({ pane: 'shortcuts', paneHit: true });
  });
  it('rows by their own words, in either language', () => {
    expect(results('language', 'en').flatMap((g) => g.hits.map((h) => h.entry.id))).toContain('general.language');
    expect(results('language', 'zh-Hans').flatMap((g) => g.hits.map((h) => h.entry.id))).toContain('general.language');
    expect(panes('翻译', 'zh-Hans')).toEqual(expect.arrayContaining(['dictation', 'screentext']));
    expect(results('voice', 'en').flatMap((g) => g.hits.map((h) => h.entry.id))).toContain('general.voice_end_on_pause');
  });
  it('Restore Defaults only by its own words', () => {
    expect(results('restore', 'en').flatMap((g) => g.hits.map((h) => h.entry.id))).toContain('shortcuts.restore');
    expect(results('snap', 'en').flatMap((g) => g.hits.map((h) => h.entry.id))).not.toContain('shortcuts.restore');
  });
  it('a miss is no results; every suggestion finds something', () => {
    expect(results('zzqx', 'en')).toEqual([]);
    for (const k of SUGGESTIONS) for (const l of ['en', 'zh-Hans'] as const) expect(results(textIn(k, l)!, l).length, `${k} ${l}`).toBeGreaterThan(0);
  });
});
