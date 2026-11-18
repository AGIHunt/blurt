// src/extdrop.ts: the island's drawer for another app's drag (docs/design/drag-drop.md §3).
import { describe, expect, it } from 'vitest';
import { createI18n } from '@blurt/i18n';
import EN from '../src/locales/en.json';
import ZH from '../src/locales/zh-Hans.json';
import { cardsMade, extTargets, extWhatOf, filePaths, hangSubtitle, pageDrop, refName, whatSummary, type ExtWhat, type Tr } from '../src/extdrop';

const tr = (lang: 'en' | 'zh-Hans'): Tr => {
  const i = createI18n({ en: EN, 'zh-Hans': ZH }, lang);
  const cat = (lang === 'zh-Hans' ? ZH : EN) as Record<string, unknown>;
  return {
    t: (k, p) => i.t(k, p),
    plural: (k, n, p) => (n === 1 && typeof cat[`${k}_one`] === 'string' ? i.t(`${k}_one`, { n, ...p }) : i.plural(k, n, p)),
  };
};
const what = (w: Partial<ExtWhat>): ExtWhat => ({ pictures: 0, files: 0, text: false, folders: 0, ...w });

describe('what the Hang row says', () => {
  it('counts pictures and files, one card each', () => {
    const w = what({ pictures: 1, files: 2 });
    expect(cardsMade(w)).toBe(3);
    expect(hangSubtitle(w, tr('en'))).toBe('1 picture, 2 files · one card each');
    expect(hangSubtitle(w, tr('zh-Hans'))).toBe('1 张图片、2 个文件 · 每样一张卡片');
  });
  it('a single thing: a note after', () => {
    expect(hangSubtitle(what({ files: 1 }), tr('en'))).toBe('1 file · add a note after');
    expect(hangSubtitle(what({ pictures: 1 }), tr('zh-Hans'))).toBe('1 张图片 · 之后可以加备注');
    expect(hangSubtitle(what({ text: true }), tr('en'))).toBe('Text · add a note after');
  });
  it('text is said only when nothing else came; folders are never cards', () => {
    expect(whatSummary(what({ pictures: 3, text: true }), tr('en'))).toBe('3 pictures');
    expect(cardsMade(what({ files: 1, folders: 2 }))).toBe(1);
    expect(whatSummary(what({ files: 4 }), tr('zh-Hans'))).toBe('4 个文件');
  });
});

describe('the drawer for another app’s drag', () => {
  it('Hang first, the projects, More…, Unassigned last; no Organize', () => {
    expect(extTargets(['p1', 'p2'], true)).toEqual(['hang', 'project:p1', 'project:p2', 'more', 'inbox']);
    expect(extTargets([], false)).toEqual(['hang', 'inbox']);
  });
  it('a file card is named by its file', () => {
    expect(refName('C:\\Users\\Ana\\Documents\\Q3 report.pdf')).toBe('Q3 report.pdf');
    expect(refName('/home/ana/clip.mp4')).toBe('clip.mp4');
  });
});

describe('Linux: the island page takes the drop itself', () => {
  it('what a drag carries, from its types and items (Blurt’s own drags are not taken)', () => {
    expect(extWhatOf(['Files', 'text/uri-list'], [{ kind: 'file', type: 'image/png' }, { kind: 'file', type: 'application/pdf' }])).toEqual({ pictures: 1, files: 1, text: false, folders: 0 });
    // WebKitGTK may list Files before the files themselves: one is assumed
    expect(extWhatOf(['Files'], [])).toEqual({ pictures: 0, files: 1, text: false, folders: 0 });
    expect(extWhatOf(['text/plain'], [{ kind: 'string', type: 'text/plain' }])).toEqual({ pictures: 0, files: 0, text: true, folders: 0 });
    expect(extWhatOf(['Files', 'application/x-blurt-cards'], [{ kind: 'file', type: 'image/png' }])).toBeNull();
    expect(extWhatOf(['application/x-blurt-items', 'text/plain'], [])).toBeNull();
    expect(extWhatOf(['text/html'], [])).toBeNull();
  });
  it('paths from a file manager’s uri-list; only local files', () => {
    expect(filePaths('# comment\r\nfile:///home/ana/My%20Spec.pdf\r\nhttps://example.com/a\nfile://otherhost/x\nfile://localhost/tmp/a.png')).toEqual(['/home/ana/My Spec.pdf', '/tmp/a.png']);
  });
  it('what goes to Rust: paths, the pictures with none (read as bytes), text only when no file came', () => {
    const files = [
      { name: 'My Spec.pdf', type: 'application/pdf' },
      { name: 'photo.jpg', type: 'image/jpeg' }, // a browser's picture: no path
      { name: 'notes.txt', type: 'text/plain' }, // no path, not a picture: left out
    ];
    expect(pageDrop(files, 'file:///home/ana/My%20Spec.pdf', 'ignored')).toEqual({ paths: ['/home/ana/My Spec.pdf'], bytes: [1], text: null });
    expect(pageDrop([], 'https://example.com/a', '')).toEqual({ paths: [], bytes: [], text: 'https://example.com/a' });
    expect(pageDrop([], '', '  hello ')).toEqual({ paths: [], bytes: [], text: 'hello' });
    expect(pageDrop([], '', '')).toEqual({ paths: [], bytes: [], text: null });
  });
});
