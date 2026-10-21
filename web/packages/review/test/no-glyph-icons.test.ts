// UI rule: icons come from <Icon name="…"> (SVG, 24 grid, 1.75 stroke) — never emoji or ✓ / ✕ / ● / ▶-style glyphs.
// Key legends in <kbd> (⌘ ⏎ ← → ↑ ↓ ⌫) are text, not icons, and stay.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, it } from "vitest";

const SRC = join(__dirname, "../src");
const files = (d: string): string[] =>
  readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? files(join(d, e.name)) : [join(d, e.name)]));
const BAD = /\p{Extended_Pictographic}|[✓✔✕✖✗✘●◉○◎▶►◀◁▷⧉★☆♥⚠⇄“”]/u;

it("no emoji or glyph icons in the canvas source", () => {
  const hits: string[] = [];
  for (const f of files(SRC).filter((f) => /\.(tsx?|css)$/.test(f))) {
    readFileSync(f, "utf8")
      .split("\n")
      .forEach((line, n) => {
        const code = line.replace(/\/\/.*$|\/\*.*?\*\//g, ""); // comments may say anything
        if (BAD.test(code)) hits.push(`${f.slice(SRC.length + 1)}:${n + 1}: ${line.trim()}`);
      });
  }
  expect(hits).toEqual([]);
});

it("the built page has none either", () => {
  let html = "";
  try {
    html = readFileSync(join(__dirname, "../dist/index.html"), "utf8");
  } catch {
    return; // not built yet
  }
  const m = html.match(new RegExp(BAD.source, "gu")) || [];
  expect(m).toEqual([]);
});
