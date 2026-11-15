// What a drag over the main window is and what its drop brings (docs/design/drag-drop.md §4), as pure rules App.tsx
// drives: the zones (the "Drop for a new item" band and the list's empty area → New Item; an item's row → add to that
// item; a project in the sidebar → New Item there, or the cards filed there), the label next to the pointer, and the
// sorting of dropped files into pictures (frames, copied), other files (referenced by path) and folders (projects,
// the sidebar's own behaviour).
//
// A page learns no file paths. On Windows, WebView2 gives them (folder_drop.rs: the File objects posted back with
// postMessageWithAdditionalObjects); on Linux (WebKitGTK) a file manager's drag may carry them as file:// URIs in
// text/uri-list, matched to the files by name — else a picture is read as bytes and any other file is skipped, said so.

/** The cards an island drag carries (card_drop.rs CARDS_MIME): which ones, `[{session, n}]`. */
export const CARDS_MIME = 'application/x-blurt-cards';
/** Rows of the list dragged inside the window (ItemList's DRAG_TYPE; repeated here to keep this module pure). */
export const ROWS_MIME = 'application/x-blurt-items';

export interface CardRef {
  session: string;
  n: number;
}

export type DragKind = 'cards' | 'rows' | 'external' | 'none';

/** What a drag is, from what a dragover can see (its types, not its data). `rows`: the list's own rows are being
 *  dragged out as Windows' file drag; `cards`: Rust says island cards are being dragged (cards_dragging); `inner`: it
 *  began in this window (DragState). */
export function dragKind(types: readonly string[], opts: { rows?: boolean; cards?: boolean; inner?: boolean } = {}): DragKind {
  if (types.includes(CARDS_MIME)) return 'cards';
  if (types.includes(ROWS_MIME) || opts.rows) return 'rows';
  // dragged inside the window (a picture out of the detail page): nothing to add or file
  if (opts.inner) return 'none';
  if (types.includes('Files') && opts.cards) return 'cards';
  if (types.includes('Files') || types.includes('text/plain') || types.includes('text/uri-list')) return 'external';
  return 'none';
}

/** The cards in a drop's CARDS_MIME data (anything malformed: none). */
export function parseCards(raw: string | null | undefined): CardRef[] {
  if (!raw) return [];
  try {
    const v = JSON.parse(raw);
    if (!Array.isArray(v)) return [];
    return v.filter((c) => c && typeof c.session === 'string' && Number.isInteger(c.n)).map((c) => ({ session: c.session, n: c.n }));
  } catch {
    return [];
  }
}

const IMAGE_EXT = /\.(png|jpe?g|gif|webp|bmp|heic|heif|tiff?)$/i;
/** A picture (it becomes a frame): by its type, else its name. */
export const isImage = (name: string, type: string) => type.startsWith('image/') || IMAGE_EXT.test(name);

export const baseName = (p: string) => p.split(/[\\/]/).filter(Boolean).pop() ?? p;

/** A dropped File and what the host knows of it: its path ('' when none), whether it is a folder. */
export interface DropEntry {
  name: string;
  type: string;
  path: string;
  dir?: boolean;
}

/** What a drop brought, sorted. `bytes`: the indexes of pictures with no path (read as bytes, save_temp_image);
 *  `skipped`: other files with no path (nothing to reference). */
export interface Sorted {
  images: string[];
  files: string[];
  folders: string[];
  bytes: number[];
  skipped: string[];
}

export function sortEntries(entries: DropEntry[]): Sorted {
  const out: Sorted = { images: [], files: [], folders: [], bytes: [], skipped: [] };
  entries.forEach((e, i) => {
    if (e.dir) out.folders.push(e.path);
    else if (isImage(e.name, e.type)) {
      if (e.path) out.images.push(e.path);
      else out.bytes.push(i);
    } else if (e.path) out.files.push(e.path);
    else out.skipped.push(e.name);
  });
  return out;
}

/** Local paths in a text/uri-list (file:// URIs; comments and other schemes left out). */
export function filePaths(uriList: string): string[] {
  return uriList
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#') && l.toLowerCase().startsWith('file://'))
    .map((l) => {
      try {
        const u = new URL(l);
        const p = decodeURIComponent(u.pathname);
        // file:///C:/x → C:/x
        return /^\/[A-Za-z]:\//.test(p) ? p.slice(1) : p;
      } catch {
        return '';
      }
    })
    .filter(Boolean);
}

/** Each file's path from a uri-list, matched by name (WebKitGTK's File objects have none); '' when there is none. */
export function pathsByName(names: string[], uriList: string): string[] {
  const left = filePaths(uriList);
  return names.map((n) => {
    const i = left.findIndex((p) => baseName(p) === n);
    return i < 0 ? '' : left.splice(i, 1)[0];
  });
}

/** Text a drop brought when it brought no files: a link (not a file's) or the plain text. */
export function droppedText(plain: string, uriList: string): string {
  const links = uriList
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#') && !l.toLowerCase().startsWith('file://'));
  const t = plain.trim();
  if (t) return t;
  return links.join('\n');
}

/** New Item's title when only files came: the first file's name without its extension. */
export const titleFromFiles = (paths: string[]) => {
  const n = paths.length ? baseName(paths[0]) : '';
  return n.replace(/\.[^.]+$/, '') || n;
};

/** Where a drag is over, and the one line next to the pointer that says what letting go does. */
export type Zone =
  | { kind: 'new'; project: string } // the band, the list's empty area, an empty list
  | { kind: 'item'; uid: string; title: string }
  | { kind: 'project'; project: string; name: string } // a sidebar row (Unassigned: "inbox")
  | { kind: 'none' };

export function dropLabel(zone: Zone, what: DragKind, projectName: (id: string) => string): { key: string; vars?: Record<string, string> } | null {
  if (what === 'rows' || what === 'none') return null;
  switch (zone.kind) {
    case 'new':
      return what === 'cards' ? { key: 'main.drop.file_into', vars: { a: projectName(zone.project) } } : { key: 'main.drop.new' };
    case 'item':
      return { key: 'main.drop.add', vars: { a: zone.title } };
    case 'project':
      return what === 'cards' ? { key: 'main.drop.file_into', vars: { a: zone.name } } : { key: 'main.drop.new_in', vars: { a: zone.name } };
    default:
      return null;
  }
}

/** One drag over the window at a time, and what the window learned about it. It all resets when the drag is over
 *  (dropped, gone out of the window, cancelled) — and an answer that comes after that (Rust's `cards_dragging`, asked
 *  as the drag came in) was about a drag that is over: dropped, never carried into the next one (a drag of files from
 *  Explorer right after a card's drag would otherwise count as cards). `inner`: a drag that began in this window (a
 *  picture dragged out of the detail page) — never something to add here; it ends with its own dragend, or the next
 *  press. */
export class DragState {
  inner = false;
  cards: CardRef[] | null = null;
  private asked = false;
  private gen = 0;

  /** dragstart in this document; `prevented`: the page made it something else (the rows' own system drag) */
  started(prevented: boolean): void {
    if (!prevented) this.inner = true;
  }
  /** the drag that began here ended (dragend), or a new press began: nothing of it is left */
  innerEnded(): void {
    this.inner = false;
  }
  /** Rust may be asked now (once a drag): the token its answer comes back with; null when asked already. */
  ask(): number | null {
    if (this.asked) return null;
    this.asked = true;
    return this.gen;
  }
  /** Rust's answer to `ask()` (the cards of the drag under way, or none): kept only while that drag is on. */
  answer(token: number, cards: CardRef[] | null): void {
    if (token === this.gen) this.cards = cards?.length ? cards : null;
  }
  /** the drag over the window is over */
  end(): void {
    this.cards = null;
    this.asked = false;
    this.gen++;
  }
}

/** The detail pane takes a drag for the item on show (drag-drop.md §4, the Mac's DetailWebView): files, pictures and
 *  the island's cards. Text and links are the page's own (its fields take them; elsewhere nothing happens), and so is
 *  anything dragged inside the window. */
export function detailTakes(what: DragKind, types: readonly string[]): boolean {
  return what === 'cards' || (what === 'external' && types.includes('Files'));
}

/** Where Ctrl+V goes (drag-drop.md §0.6, the Mac's MainWindowController.paste / DetailWebView.paste):
 *  - `item`: the detail shows an item and the clipboard has files or a picture (or may: outside a text field Rust
 *    looks) — they are added to it; text found there goes into the field that had the focus
 *  - `page`: the page's own paste (a text field, the detail with only text on the clipboard)
 *  - `new`: the list, the sidebar, nothing focused — New Item, filled with what the clipboard holds
 *  - `none`: not the main list's screen (Settings, Dictation) */
export type PasteTo = 'item' | 'page' | 'new' | 'none';
export function pasteTarget(o: { field: boolean; detail: boolean; item: boolean; files: boolean; main: boolean }): PasteTo {
  if (o.detail) return o.item && (o.files || !o.field) ? 'item' : 'page';
  if (o.field) return 'page';
  return o.main ? 'new' : 'none';
}

/** An item's frames, attachments and details after `items.py attach` added `added` to `before` (its result): what Redo
 *  puts back (attach --restore). */
export function attachedAfter(before: unknown, added: unknown): Record<string, unknown> {
  const b = (before && typeof before === 'object' ? before : {}) as Record<string, unknown>;
  const a = (added && typeof added === 'object' ? added : {}) as Record<string, unknown>;
  const list = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
  const frames = [...list(b.frames), ...list(a.frames).map((p) => (typeof p === 'string' ? { path: p } : p))];
  const attachments = [...list(b.attachments), ...list(a.attachments)];
  const was = typeof b.details === 'string' ? b.details.trimEnd() : '';
  const words = typeof a.details === 'string' ? a.details : '';
  return {
    frames: frames.length ? frames : (b.frames ?? null),
    attachments: attachments.length ? attachments : (b.attachments ?? null),
    details: words ? (was ? `${was}\n\n${words}` : words) : (b.details ?? null),
  };
}
