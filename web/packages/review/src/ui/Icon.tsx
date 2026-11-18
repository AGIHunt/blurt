/* The one place the canvas gets its icons from: <Icon name="…"/> — the blurt icon family (web/packages/icons, generated
   from assets/icons/*.svg). No emoji or text glyphs as icons anywhere in the UI. */
import { Icon, type IconName } from "@blurt/icons";
import type { FileKind } from "../files";

export { Icon, ICON_NAMES, type IconName } from "@blurt/icons";

/* A file's kind as an icon (an item's attached files). The family's glyph where it has one; the kinds it has none
   for are drawn here to its rules (24 grid, 1.75 line, round caps and joins, stroke only) until they move into
   assets/icons. */
const PAGE = "M13.5 3.75v3.5a1.5 1.5 0 0 0 1.5 1.5h3.5";
const DRAWN: Partial<Record<FileKind, string>> = {
  // a blank page
  file: `M13.5 3.75H8.25A2.75 2.75 0 0 0 5.5 6.5v11a2.75 2.75 0 0 0 2.75 2.75h7.5a2.75 2.75 0 0 0 2.75-2.75V8.75Z${PAGE}`,
  // a page with its label across the left edge
  pdf: `M5.5 11.5v-5a2.75 2.75 0 0 1 2.75-2.75h5.25l5 5v8.75a2.75 2.75 0 0 1-2.75 2.75h-7.5A2.75 2.75 0 0 1 5.5 17.5${PAGE}M4.75 11.5h6.5a1.5 1.5 0 0 1 1.5 1.5v3a1.5 1.5 0 0 1-1.5 1.5h-6.5a1.5 1.5 0 0 1-1.5-1.5v-3a1.5 1.5 0 0 1 1.5-1.5Z`,
  // a picture: the sun, a slope
  image: "M6 4h12a3 3 0 0 1 3 3v10a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3V7a3 3 0 0 1 3-3ZM8.5 9.25h.01M21 14.5l-3.2-3.2a1.75 1.75 0 0 0-2.5 0L6.5 20",
  // a table: its header row and first column
  sheet: "M6 4.5h12a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3v-9a3 3 0 0 1 3-3ZM3 10h18M9.5 10v9.5",
  // a slide on its stand
  slides: "M3 4.5h18M4.75 4.5v8.75a2.5 2.5 0 0 0 2.5 2.5h9.5a2.5 2.5 0 0 0 2.5-2.5V4.5M12 15.75v2.5M9 20.5l3-2.25 3 2.25",
};
const NAMED: Partial<Record<FileKind, IconName>> = { video: "film", audio: "waveform", archive: "archive", code: "code", text: "align-left", doc: "document" };

export function FileIcon({ kind }: { kind: FileKind }) {
  const d = DRAWN[kind];
  if (!d) return <Icon name={NAMED[kind] ?? "document"} />;
  return (
    <svg className="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={d} />
    </svg>
  );
}
