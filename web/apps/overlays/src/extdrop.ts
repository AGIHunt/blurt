// Another app's drag over the island (docs/design/drag-drop.md §3; Rust: island_drop_win.rs, the catcher over the
// notch): what the drawer says and offers, as pure rules the island page renders.
//  • The first row hangs what came under the island ("Keep as cards under the notch"), its subtitle says what that is: "1
//    picture, 2 files · one card each" — a single thing: "… · add a note after". Letting go on the notch itself does
//    the same.
//  • Then the projects (as every drawer lists them), More… (which takes nothing), and Unassigned last. No Organize:
//    another app's things are filed where the user points, never sorted by a guess.
//  • Folders aren't taken (the main window's sidebar opens them as projects): never counted as a card.
// No DOM: the page passes its translator.

/** What a drag carries (island_drop_win.rs `DropIn::summary`). */
export interface ExtWhat {
  pictures: number;
  files: number;
  text: boolean;
  folders: number;
}

export interface Tr {
  t(key: string, p?: Record<string, string | number>): string;
  plural(key: string, n: number, p?: Record<string, string | number>): string;
}

/** How many cards letting go makes: one each. */
export const cardsMade = (w: ExtWhat): number => w.pictures + w.files + (w.text ? 1 : 0);

/** "1 picture, 2 files", "3 files", "text" (the Mac's DropIn.summary): pictures and files counted, text only when
 *  nothing else came. */
export function whatSummary(w: ExtWhat, tr: Tr): string {
  const parts: string[] = [];
  if (w.pictures > 0) parts.push(tr.plural('island.ext.pictures', w.pictures));
  if (w.files > 0) parts.push(tr.plural('island.ext.files', w.files));
  if (!parts.length && w.text) parts.push(tr.t('island.ext.text'));
  return parts.join(tr.t('island.ext.and'));
}

/** The Hang row's subtitle: what came, then what happens ("· one card each", one thing: "· add a note after"). */
export function hangSubtitle(w: ExtWhat, tr: Tr): string {
  return tr.t(cardsMade(w) > 1 ? 'island.ext.hang_several' : 'island.ext.hang_single', { what: whatSummary(w, tr) });
}

/** The drawer's targets for another app's drag, in order (`data-drop` values; `more` takes nothing). */
export function extTargets(projectIds: string[], more: boolean): string[] {
  return ['hang', ...projectIds.map((id) => `project:${id}`), ...(more ? ['more'] : []), 'inbox'];
}

/** A file card's file name (its `ref`, a Windows or POSIX path). */
export const refName = (ref: string): string => ref.split(/[\\/]/).filter(Boolean).pop() ?? ref;

// ------------------------------------------------------------------ Linux: the island page takes the drop itself
// WebKitGTK hands the island's window another app's drag over what the island draws (its input region: the notch,
// the strip at the top, the open drawer). A page learns no file paths: a file manager's drag names its files in
// text/uri-list (file:// URIs), matched to the dropped File objects by name; a picture with no path (a browser's) is
// read as bytes; text only when nothing else came.

/** What a drag carries, from what a dragover can see (its types and items, not its data). Null: nothing the island
 *  takes (or Blurt's own drag). WebKitGTK may list "Files" before it lists the files: one is assumed. */
export function extWhatOf(types: readonly string[], items: readonly { kind: string; type: string }[]): ExtWhat | null {
  if (types.includes('application/x-blurt-cards') || types.includes('application/x-blurt-items')) return null;
  const files = items.filter((i) => i.kind === 'file');
  if (files.length || types.includes('Files')) {
    const pictures = files.filter((i) => i.type.startsWith('image/')).length;
    return { pictures, files: Math.max(files.length - pictures, files.length ? 0 : 1), text: false, folders: 0 };
  }
  if (types.includes('text/uri-list') || types.includes('text/plain')) return { pictures: 0, files: 0, text: true, folders: 0 };
  return null;
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
        return u.host && u.host !== 'localhost' ? '' : decodeURIComponent(u.pathname);
      } catch {
        return '';
      }
    })
    .filter(Boolean);
}

/** What the page sends Rust for a drop (island.rs `ext.drop`): the paths (from the uri-list), the dropped files that
 *  have none and are pictures (to be read as bytes: their indexes), the text when no file came. */
export function pageDrop(files: readonly { name: string; type: string }[], uriList: string, plain: string): { paths: string[]; bytes: number[]; text: string | null } {
  const paths = filePaths(uriList);
  const left = [...paths];
  const bytes: number[] = [];
  files.forEach((f, i) => {
    const at = left.findIndex((p) => refName(p) === f.name);
    if (at >= 0) left.splice(at, 1);
    else if (f.type.startsWith('image/')) bytes.push(i);
  });
  const links = uriList
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#') && !l.toLowerCase().startsWith('file://'));
  const text = files.length || paths.length ? null : plain.trim() || links.join('\n') || null;
  return { paths, bytes, text };
}
