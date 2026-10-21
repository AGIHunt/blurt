import { describe, expect, it } from 'vitest';
import { comboFromEvent, comboLabel, egg } from './util';
import { codeUrl, repoOf } from './host';
import { isImeKey, _setCompositionEnd } from './review/ime';
import { joinPath } from './api';

const ev = (code: string, mods: Partial<Record<'ctrlKey' | 'altKey' | 'shiftKey' | 'metaKey', boolean>> = {}) => ({
  ctrlKey: false, altKey: false, shiftKey: false, metaKey: false, key: '', code, ...mods,
});

describe('shortcut recorder', () => {
  it('writes the config grammar', () => {
    expect(comboFromEvent(ev('KeyR', { altKey: true, shiftKey: true }))).toBe('opt+shift+R');
    expect(comboFromEvent(ev('F5', { ctrlKey: true }))).toBe('ctrl+F5');
    expect(comboFromEvent(ev('Digit3', { metaKey: true, ctrlKey: true }))).toBe('ctrl+cmd+3');
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
    expect(isImeKey({ nativeEvent: { keyCode: 229 } }, 5000)).toBe(true);
  });
});

describe('paths', () => {
  it('finds the repo of a session and builds editor links', () => {
    expect(repoOf('/r/my-saas/.blurt/sessions/20261021-101500')).toBe('/r/my-saas');
    expect(repoOf('C:\\code\\app\\.blurt\\sessions\\20261021-101500')).toBe('C:/code/app');
    expect(repoOf('/h/Blurt/recordings/20261021-101500')).toBeNull();
    expect(codeUrl('/r/my-saas', 'api/avatar.py:88')).toBe('vscode://file/r/my-saas/api/avatar.py:88');
    expect(codeUrl('C:/code/app', 'src/x.ts', 'cursor')).toBe('cursor://file/C:/code/app/src/x.ts:1');
    expect(joinPath('/s/dir', 'frames/a.jpg')).toBe('/s/dir/frames/a.jpg');
    expect(joinPath('C:\\s\\dir', 'frames/a.jpg')).toBe('C:\\s\\dir\\frames\\a.jpg');
  });
  it('egg states', () => {
    expect(egg({ processed: 0, processing: 0, reviewed: 0 }).icon).toBe('🥚');
    expect(egg({ processed: 1, processing: 1, reviewed: 0 }).cls).toContain('wobble');
    expect(egg({ processed: 1, processing: 0, reviewed: 0 }).icon).toBe('🐣');
  });
});
