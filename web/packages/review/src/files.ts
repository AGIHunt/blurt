/* An item's attached files (`attachments`: absolute paths, written by `items.py attach` when a PDF, a video or a
   document is dropped on the item): which entries are files, the name and the folder as people read them, and the
   kind of file its icon is picked by. Pure functions. */

export type FileKind = "pdf" | "video" | "audio" | "image" | "archive" | "code" | "text" | "sheet" | "doc" | "slides" | "file";

const KINDS: Record<Exclude<FileKind, "file">, string> = {
  pdf: "pdf",
  video: "mp4 mov m4v webm mkv avi wmv mpg mpeg 3gp",
  audio: "mp3 wav m4a aac flac ogg opus aif aiff caf wma",
  image: "png jpg jpeg gif webp heic heif tif tiff bmp svg ico avif psd",
  archive: "zip rar 7z tar gz tgz bz2 xz dmg pkg iso",
  code: "js mjs cjs ts tsx jsx py rb go rs swift kt java c h cc cpp hpp cs php sh zsh bash sql json yaml yml toml xml html htm css scss vue lua ipynb",
  text: "txt md markdown log rtf tex srt vtt ini conf",
  sheet: "xls xlsx xlsm csv tsv numbers ods",
  doc: "doc docx pages odt epub",
  slides: "ppt pptx key odp",
};
const BY_EXT = new Map<string, FileKind>();
for (const [kind, exts] of Object.entries(KINDS)) for (const e of exts.split(" ")) BY_EXT.set(e, kind as FileKind);

/** [the entry's place in the stored list, its path]: the strings of `attachments`; anything else in the list is
    left alone (never shown, never dropped by an edit here). A lone string is a list of one. */
export function attachedFiles(v: unknown): [number, string][] {
  const list = Array.isArray(v) ? v : typeof v === "string" ? [v] : [];
  return list.flatMap((p, n): [number, string][] => (typeof p === "string" && p.trim() ? [[n, p]] : []));
}

const trimEnd = (p: string) => p.replace(/[\\/]+$/, "");

/** "/Users/me/Documents/specs/spec-v2.pdf" → "spec-v2.pdf" */
export const fileName = (p: string) => trimEnd(p).split(/[\\/]/).pop() || p;

export function fileKind(p: string): FileKind {
  const m = /\.([A-Za-z0-9]+)$/.exec(fileName(p));
  return (m && BY_EXT.get(m[1].toLowerCase())) || "file";
}

/** The folder the file is in, the home folder as "~": "/Users/me/Documents/specs/spec-v2.pdf" → "~/Documents/specs".
    "" when the path names no folder. */
export function fileFolder(p: string): string {
  const t = trimEnd(p);
  const cut = Math.max(t.lastIndexOf("/"), t.lastIndexOf("\\"));
  if (cut < 0) return "";
  const dir = t.slice(0, cut) || t[0];
  return dir.replace(/^(?:\/Users|\/home|[A-Za-z]:[\\/]Users)[\\/][^\\/]+(?=[\\/]|$)/, "~");
}

/** A long name in two parts, so the row can cut it in the middle and keep its end — the extension — in sight:
    ["Quarterly planning notes (reviewed,", " final).docx"]. A short name is one part. */
export function nameParts(name: string): [string, string] {
  const cs = [...name];
  const dot = cs.lastIndexOf(".");
  const ext = dot > 0 && cs.length - dot <= 8 ? cs.length - dot : 0;
  const keep = ext + 7;
  return cs.length > keep + 10 ? [cs.slice(0, -keep).join(""), cs.slice(-keep).join("")] : [name, ""];
}
