// drops.ts: what a drag over the main window is and what its drop brings (docs/design/drag-drop.md §4).
import { describe, expect, it } from 'vitest';
import { CARDS_MIME, DragState, ROWS_MIME, attachedAfter, detailTakes, dragKind, droppedText, dropLabel, filePaths, isImage, parseCards, pasteTarget, pathsByName, sortEntries, titleFromFiles } from './drops';
import { DRAG_TYPE } from './components/ItemList';
import EN from './locales/en.json';
import ZH from './locales/zh-Hans.json';

describe('what is dragged', () => {
  it('the island cards by their own type, or by Rust saying so for a drag of files', () => {
    expect(dragKind(['Files', CARDS_MIME])).toBe('cards');
    expect(dragKind(['Files'], { cards: true })).toBe('cards');
    expect(dragKind(['Files'])).toBe('external');
  });
  it("the list's own rows keep their drag", () => {
    expect(ROWS_MIME).toBe(DRAG_TYPE);
    expect(dragKind([ROWS_MIME])).toBe('rows');
    expect(dragKind(['Files'], { rows: true, cards: true })).toBe('rows');
  });
  it('text and links from another app; nothing else', () => {
    expect(dragKind(['text/plain'])).toBe('external');
    expect(dragKind(['text/uri-list'])).toBe('external');
    expect(dragKind(['text/html'])).toBe('none');
    expect(dragKind([])).toBe('none');
  });
  it('the cards a drop names; anything malformed is none', () => {
    expect(parseCards('[{"session":"C:\\\\s\\\\b","n":3},{"session":"/x","n":1.5},{"n":2}]')).toEqual([{ session: 'C:\\s\\b', n: 3 }]);
    expect(parseCards('{"session":"/x","n":1}')).toEqual([]);
    expect(parseCards('nope')).toEqual([]);
    expect(parseCards('')).toEqual([]);
  });
});

describe('what a drop brings', () => {
  it('pictures become frames, other files are referenced, folders are projects', () => {
    const s = sortEntries([
      { name: 'shot.png', type: 'image/png', path: 'C:\\a\\shot.png' },
      { name: 'spec.pdf', type: 'application/pdf', path: 'C:\\a\\spec.pdf' },
      { name: 'repo', type: '', path: 'C:\\code\\repo', dir: true },
      { name: 'web.jpg', type: 'image/jpeg', path: '' }, // a browser's picture: no path, its bytes
      { name: 'clip.mov', type: 'video/quicktime', path: '' }, // no path, not a picture: left out
      { name: 'IMG_1.HEIC', type: '', path: '/home/a/IMG_1.HEIC' },
    ]);
    expect(s.images).toEqual(['C:\\a\\shot.png', '/home/a/IMG_1.HEIC']);
    expect(s.files).toEqual(['C:\\a\\spec.pdf']);
    expect(s.folders).toEqual(['C:\\code\\repo']);
    expect(s.bytes).toEqual([3]);
    expect(s.skipped).toEqual(['clip.mov']);
    expect(isImage('a.webp', '')).toBe(true);
    expect(isImage('a.pdf', 'application/pdf')).toBe(false);
  });
  it("Linux: a file manager's uri-list gives the paths, matched by name", () => {
    const uris = '# copied\r\nfile:///home/ana/Docs/spec%20v2.pdf\r\nfile:///home/ana/a.png\r\nhttps://example.com/x\n';
    expect(filePaths(uris)).toEqual(['/home/ana/Docs/spec v2.pdf', '/home/ana/a.png']);
    expect(pathsByName(['a.png', 'spec v2.pdf', 'other.txt'], uris)).toEqual(['/home/ana/a.png', '/home/ana/Docs/spec v2.pdf', '']);
    expect(filePaths('file:///C:/Users/a/x.txt')).toEqual(['C:/Users/a/x.txt']);
  });
  it('text: the plain text, else the links', () => {
    expect(droppedText('  a note \n', 'https://x.test/a')).toBe('a note');
    expect(droppedText('', 'https://x.test/a\n# c\nfile:///tmp/a')).toBe('https://x.test/a');
    expect(droppedText('', '')).toBe('');
  });
  it("New Item's title from the first file", () => {
    expect(titleFromFiles(['C:\\Users\\a\\Q3 report.final.pdf', '/x/b.mp4'])).toBe('Q3 report.final');
    expect(titleFromFiles(['/x/.env'])).toBe('.env');
    expect(titleFromFiles([])).toBe('');
  });
});

describe('the label next to the pointer', () => {
  const name = (id: string) => (id === 'inbox' ? 'Unassigned' : 'Blurt');
  it('says what letting go does, by the item title, in both languages', () => {
    expect(dropLabel({ kind: 'new', project: 'p1' }, 'external', name)).toEqual({ key: 'main.drop.new' });
    expect(dropLabel({ kind: 'new', project: 'p1' }, 'cards', name)).toEqual({ key: 'main.drop.file_into', vars: { a: 'Blurt' } });
    expect(dropLabel({ kind: 'item', uid: 'u', title: 'Home page rivals' }, 'cards', name)).toEqual({ key: 'main.drop.add', vars: { a: 'Home page rivals' } });
    expect(dropLabel({ kind: 'project', project: 'inbox', name: 'Unassigned' }, 'external', name)).toEqual({ key: 'main.drop.new_in', vars: { a: 'Unassigned' } });
    expect(dropLabel({ kind: 'new', project: 'p1' }, 'rows', name)).toBeNull();
    expect(dropLabel({ kind: 'none' }, 'external', name)).toBeNull();
    for (const k of ['main.drop.new', 'main.drop.new_in', 'main.drop.add', 'main.drop.file_into', 'main.drop.folders', 'main.drop.added', 'main.drop.text', 'main.new_item.remove_file']) {
      expect((EN as Record<string, string>)[k], k).toBeTruthy();
      expect((ZH as Record<string, string>)[k], k).toBeTruthy();
    }
    for (const k of ['main.drop.n_pictures', 'main.drop.n_files', 'main.drop.filed', 'main.drop.skipped']) {
      expect((EN as Record<string, string>)[`${k}_other`], k).toContain('{n}');
      expect((ZH as Record<string, string>)[`${k}_other`], k).toContain('{n}');
    }
  });
});

describe('one drag at a time (DragState): nothing of a drag outlives it', () => {
  it("Rust's answer about the cards is asked once a drag, and kept only while that drag is on", () => {
    const d = new DragState();
    const tok = d.ask();
    expect(tok).not.toBeNull();
    expect(d.ask()).toBeNull(); // the dragovers after: not asked again
    d.answer(tok!, [{ session: '/s', n: 1 }]);
    expect(d.cards).toEqual([{ session: '/s', n: 1 }]);
    d.end();
    expect(d.cards).toBeNull();
    // the next drag asks anew
    expect(d.ask()).not.toBeNull();
  });
  it('an answer that comes after its drag ended never makes the next drag (files from Explorer) count as cards', () => {
    const d = new DragState();
    const late = d.ask()!;
    d.end(); // dropped before Rust answered
    const next = d.ask()!;
    d.answer(late, [{ session: '/s', n: 1 }]);
    expect(d.cards).toBeNull();
    expect(dragKind(['Files'], { cards: !!d.cards?.length })).toBe('external');
    d.answer(next, null);
    expect(d.cards).toBeNull();
  });
  it('a drag that began in the window (a picture out of the detail page) is nothing to add, until it ends', () => {
    const d = new DragState();
    d.started(true); // the rows' own system drag: the page took it over
    expect(d.inner).toBe(false);
    d.started(false);
    expect(dragKind(['Files', 'text/uri-list'], { inner: d.inner })).toBe('none');
    expect(dragKind([ROWS_MIME], { inner: d.inner })).toBe('rows');
    d.end(); // gone out of the window and back: still the same drag
    expect(d.inner).toBe(true);
    d.innerEnded(); // its dragend, or the next press
    expect(dragKind(['Files'], { inner: d.inner })).toBe('external');
  });
});

describe('the detail pane', () => {
  it('takes files, pictures and the island cards for the item on show; text stays the page’s', () => {
    expect(detailTakes('external', ['Files'])).toBe(true);
    expect(detailTakes('cards', ['Files', CARDS_MIME])).toBe(true);
    expect(detailTakes('external', ['text/plain'])).toBe(false);
    expect(detailTakes('external', ['text/uri-list', 'text/plain'])).toBe(false);
    expect(detailTakes('rows', [ROWS_MIME])).toBe(false);
    expect(detailTakes('none', ['Files'])).toBe(false);
  });
});

describe('Ctrl+V (pasteTarget)', () => {
  const at = (o: Partial<Parameters<typeof pasteTarget>[0]>) => pasteTarget({ field: false, detail: false, item: false, files: false, main: true, ...o });
  it('the list, the sidebar or nothing focused: New Item', () => {
    expect(at({})).toBe('new');
    expect(at({ files: true })).toBe('new');
    expect(at({ main: false })).toBe('none'); // Settings, Dictation
  });
  it('a text field outside the detail (search): its own paste', () => {
    expect(at({ field: true, files: true })).toBe('page');
  });
  it('the detail with an item: files or a picture are added; text in a field is the page’s', () => {
    expect(at({ detail: true, item: true, files: true, field: true })).toBe('item');
    expect(at({ detail: true, item: true, field: true })).toBe('page');
    expect(at({ detail: true, item: true })).toBe('item'); // outside a field Rust looks (files the page may not see)
    expect(at({ detail: true, files: true })).toBe('page'); // a batch, a job: no one item
  });
});

describe('Redo of an add (attachedAfter)', () => {
  it('the item as items.py attach left it', () => {
    expect(attachedAfter({ frames: [{ path: '/a.png', t: 3 }], attachments: null, details: 'Steps\n' }, { frames: ['/b.png'], attachments: ['/x.pdf'], details: 'more' })).toEqual({
      frames: [{ path: '/a.png', t: 3 }, { path: '/b.png' }],
      attachments: ['/x.pdf'],
      details: 'Steps\n\nmore',
    });
    expect(attachedAfter({ frames: null, attachments: null, details: null }, { attachments: ['/x.pdf'] })).toEqual({ frames: null, attachments: ['/x.pdf'], details: null });
    expect(attachedAfter(undefined, { details: 'only' })).toEqual({ frames: null, attachments: null, details: 'only' });
  });
});
