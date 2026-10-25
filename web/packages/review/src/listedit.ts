/* Editing a list field (steps "1. …", other lists "- …") as a list, not as plain text (micro 21):
     Return        continues the list: a new marker, the numbers follow
     Return on an empty item   ends the list (the empty marker goes, the field commits)
     ⌫ right after a marker    removes the marker (an empty item goes with it)
     ⌃⌘↑ / ⌃⌘↓     moves the item up / down
   Pure functions on (value, caret); the inspector applies the result. The marker syntax is the field's own format
   (Inspector's format / parse), not language. */

export type ListKey = "enter" | "backspace" | "up" | "down";
export interface ListEdit {
  value: string;
  caret: number;
  /** the list ended: commit the field */
  done?: boolean;
}

const MARKER = /^\s*(\d+[.)、]|[-*•])\s*/;

function renumber(lines: string[], numbered: boolean): string[] {
  let n = 0;
  return lines.map((l) => {
    const m = l.match(MARKER);
    if (!m) return l;
    n++;
    return (numbered ? `${n}. ` : "- ") + l.slice(m[0].length);
  });
}

/** where the caret is: the line and the column in it */
function at(lines: string[], caret: number): [number, number] {
  let off = 0;
  for (let i = 0; i < lines.length; i++) {
    if (caret <= off + lines[i].length) return [i, caret - off];
    off += lines[i].length + 1;
  }
  return [lines.length - 1, lines[lines.length - 1].length];
}
const offsetOf = (lines: string[], i: number) => lines.slice(0, i).reduce((s, l) => s + l.length + 1, 0);

/** null: not a list key here (the textarea does what it does) */
export function listKey(value: string, caret: number, key: ListKey, numbered: boolean): ListEdit | null {
  const lines = value.split("\n");
  const [i, col] = at(lines, caret);
  const line = lines[i];
  const mk = line.match(MARKER)?.[0] ?? "";
  if (key === "enter") {
    if (!mk) return null; // plain text (or nothing yet) in a list field: Return as usual
    if (mk && line.slice(mk.length).trim() === "") {
      lines.splice(i, 1);
      const out = renumber(lines, numbered);
      return { value: out.join("\n"), caret: i > 0 ? offsetOf(out, i - 1) + out[i - 1].length : 0, done: true };
    }
    const before = line.slice(0, Math.max(col, mk.length));
    const after = line.slice(Math.max(col, mk.length)).trimStart();
    lines.splice(i, 1, before, "- " + after);
    const out = renumber(lines, numbered);
    const nm = out[i + 1].match(MARKER)?.[0].length ?? 0;
    return { value: out.join("\n"), caret: offsetOf(out, i + 1) + nm };
  }
  if (key === "backspace") {
    if (!mk || col !== mk.length) return null;
    if (line.slice(mk.length).trim() === "" && lines.length > 1) {
      lines.splice(i, 1);
      const out = renumber(lines, numbered);
      const j = Math.max(0, i - 1);
      return { value: out.join("\n"), caret: offsetOf(out, j) + out[j].length };
    }
    lines[i] = line.slice(mk.length);
    const out = renumber(lines, numbered);
    return { value: out.join("\n"), caret: offsetOf(out, i) };
  }
  const j = key === "up" ? i - 1 : i + 1;
  if (j < 0 || j >= lines.length) return { value, caret };
  [lines[i], lines[j]] = [lines[j], lines[i]];
  const out = renumber(lines, numbered);
  const nm = out[j].match(MARKER)?.[0].length ?? 0;
  return { value: out.join("\n"), caret: offsetOf(out, j) + Math.min(out[j].length, Math.max(nm, col)) };
}
