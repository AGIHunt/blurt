// Settings → Storage → Data location (location.rs): every refusal the backend can give is said in both languages,
// with its numbers, and search finds the row by the words people use ("D盘", "move").
import { afterEach, describe, expect, it } from 'vitest';
import { locationError } from './components/StorageSettings';
import { setLang } from './i18n';
import { results } from './settings/catalog';

const CODES = ['same', 'inside_current', 'contains_current', 'has_data', 'not_writable', 'no_space', 'moving', 'busy_recording', 'busy_dictation', 'busy_download', 'busy_job', 'copy_failed'];

describe('data location', () => {
  afterEach(() => setLang('en'));
  it('says every refusal in both languages', () => {
    for (const lang of ['en', 'zh-Hans']) {
      setLang(lang);
      for (const error of CODES) {
        const s = locationError({ ok: false, error, bytes: 3_820_000_000, free: 1_200_000_000, detail: 'disk full' });
        expect(s, `${lang} ${error}`).not.toMatch(/win\.storage|\{\d\}/);
      }
    }
    setLang('en');
    expect(locationError({ error: 'no_space', bytes: 3_820_000_000, free: 1_200_000_000 })).toBe('Not enough space there: needs 3.8 GB, 1.2 GB free.');
    expect(locationError({ error: 'env', var: 'BLURT_HOME' })).toBe('Set by the BLURT_HOME environment variable');
    expect(locationError({ error: 'copy_failed', detail: 'E:\\x: disk full' })).toContain('E:\\x: disk full');
  });
  it('is found by the words people search for', () => {
    const top = (q: string, l: 'en' | 'zh-Hans') => results(q, l)[0]?.hits[0]?.entry.id;
    expect(top('D盘', 'zh-Hans')).toBe('storage.location');
    expect(top('数据位置', 'zh-Hans')).toBe('storage.location');
    expect(top('data folder', 'en')).toBe('storage.location');
    expect(top('move drive', 'en')).toBe('storage.location');
  });
});
