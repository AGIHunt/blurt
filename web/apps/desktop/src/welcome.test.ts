import { describe, expect, it } from 'vitest';
import { stepsFor, welcomeLine } from './components/Welcome';
import EN from './locales/en.json';
import ZH from './locales/zh-Hans.json';

describe('Welcome', () => {
  it('has dictation steps only where dictation runs', () => {
    expect(stepsFor(true)).toEqual(['welcome', 'dictation', 'models', 'try']);
    expect(stepsFor(false)).toEqual(['welcome', 'try']);
  });

  it('names only keys that work now (WelcomeLine)', () => {
    expect(welcomeLine('works', 'Right Alt', 'Alt+Shift+A')).toEqual({ key: 'welcome.line', params: { dictate: 'Right Alt', snap: 'Alt+Shift+A' } });
    expect(welcomeLine('works', 'Right Alt', null).key).toBe('welcome.line_dictation_only');
    expect(welcomeLine('no_model', 'Right Alt', 'Alt+Shift+A').key).toBe('welcome.line_no_model');
    expect(welcomeLine('off', '', 'Alt+Shift+A').key).toBe('welcome.line_snap_only');
    expect(welcomeLine('off', '', null).key).toBe('welcome.line_plain');
  });

  it('has every welcome string in both languages', () => {
    const en = Object.keys(EN).filter((k) => k.startsWith('welcome.'));
    const zh = Object.keys(ZH).filter((k) => k.startsWith('welcome.'));
    expect(en.length).toBeGreaterThan(50);
    expect(zh.sort()).toEqual(en.sort());
  });
});
