import { describe, expect, it } from 'vitest';
import { checkCatalogs, createI18n } from '@blurt/i18n';
import { comboFromEvent, comboLabel, nextSelection } from './util';
import { codeUrl } from './host';
import { isImeKey, _setCompositionEnd } from './ime';
import { CATALOGS, errText, setLang } from './i18n';

const ev = (code: string, mods: Partial<Record<'ctrlKey' | 'altKey' | 'shiftKey' | 'metaKey', boolean>> = {}) => ({
  ctrlKey: false, altKey: false, shiftKey: false, metaKey: false, key: '', code, ...mods,
});

describe('shortcut recorder', () => {
  it('writes the config grammar', () => {
    expect(comboFromEvent(ev('KeyR', { altKey: true, shiftKey: true }))).toBe('opt+shift+R');
    expect(comboFromEvent(ev('KeyV', { altKey: true, shiftKey: true }))).toBe('opt+shift+V');
    expect(comboFromEvent(ev('F5', { ctrlKey: true }))).toBe('ctrl+F5');
    expect(comboFromEvent(ev('ArrowLeft', { altKey: true }))).toBe('opt+Left');
    expect(comboFromEvent(ev('ShiftLeft', { shiftKey: true }))).toBeNull();
  });
  it('labels per platform', () => {
    expect(comboLabel('opt+shift+R', 'win')).toBe('Alt+Shift+R');
    expect(comboLabel('cmd+shift+S', 'win')).toBe('Win+Shift+S');
    expect(comboLabel('cmd+Space', 'gnome')).toBe('Super+Space');
    expect(comboLabel('opt+shift+R', 'mac')).toBe('⌥⇧R');
    expect(comboLabel('off')).toBe('');
  });
});

describe('IME guard (C6)', () => {
  it('ignores composing / 229 / right after compositionend', () => {
    _setCompositionEnd(-1e9);
    expect(isImeKey({ isComposing: true }, 1000)).toBe(true);
    expect(isImeKey({ keyCode: 229 }, 1000)).toBe(true);
    expect(isImeKey({ keyCode: 13 }, 1000)).toBe(false);
    _setCompositionEnd(1000);
    expect(isImeKey({ keyCode: 13 }, 1030)).toBe(true);
    expect(isImeKey({ keyCode: 13 }, 1060)).toBe(false);
  });
});

describe('editor links and errors', () => {
  it('builds editor links from a project folder', () => {
    expect(codeUrl('/r/my-saas', 'api/avatar.py:88')).toBe('vscode://file/r/my-saas/api/avatar.py:88');
    expect(codeUrl('C:\\code\\app', 'src/x.ts', 'cursor')).toBe('cursor://file/C:/code/app/src/x.ts:1');
    expect(codeUrl('/r', '/abs/file.rs:3', 'zed')).toBe('zed://file/abs/file.rs:3');
  });
  it('finds the CLI code in an error', () => {
    setLang('en');
    expect(errText('sessions.py dispatch: items must be in a project [needs_project]')).toBe('Move these items to a project folder first.');
    expect(errText(new Error('boom'))).toBe('Something went wrong.');
    expect(errText('x [no_such_code]')).toBe('Something went wrong.');
  });
});

describe('selection', () => {
  const order = ['a', 'b', 'c', 'd'];
  it('one, toggle, range', () => {
    expect([...nextSelection(order, new Set(['a']), 'a', 'c', 'one')]).toEqual(['c']);
    expect([...nextSelection(order, new Set(['a']), 'a', 'c', 'toggle')]).toEqual(['a', 'c']);
    expect([...nextSelection(order, new Set(['a', 'c']), 'c', 'a', 'toggle')]).toEqual(['c']);
    expect([...nextSelection(order, new Set(['b']), 'b', 'd', 'range')]).toEqual(['b', 'c', 'd']);
    expect([...nextSelection(order, new Set(['d']), 'd', 'b', 'range')]).toEqual(['b', 'c', 'd']);
  });
});

describe('catalogs (K10)', () => {
  it('en and zh-Hans have the same keys and placeholders', () => {
    expect(checkCatalogs(CATALOGS.en, CATALOGS['zh-Hans'])).toEqual([]);
  });
  it('the K5 reminder is word for word', () => {
    const en = createI18n(CATALOGS, 'en');
    const zh = createI18n(CATALOGS, 'zh-Hans');
    expect(en.t('dispatch.warn.concurrent_edit', { project: 'bug-agent' })).toBe(
      'Another session is already changing files in bug-agent. Editing the same files at the same time can cause conflicts — a worktree keeps them apart.',
    );
    expect(zh.t('dispatch.warn.concurrent_edit', { project: 'bug-agent' })).toBe('bug-agent 里已经有一个会话在直接改文件。同时改同一批文件可能冲突，建议用 worktree 分开。');
    expect([en.t('dispatch.warn.use_worktree'), en.t('dispatch.warn.continue')]).toEqual(['Use a worktree', 'Continue']);
    expect([zh.t('dispatch.warn.use_worktree'), zh.t('dispatch.warn.continue')]).toEqual(['用 worktree', '继续']);
  });
  it('plurals and common words', () => {
    const en = createI18n(CATALOGS, 'en');
    expect(en.plural('list.count', 1)).toBe('1 item');
    expect(en.plural('list.count', 1200)).toBe('1,200 items');
    expect(en.t('work.to_verify')).toBe('To verify');
    expect(createI18n(CATALOGS, 'zh-Hans').t('project.open_folder')).toBe('打开文件夹…');
  });
});
