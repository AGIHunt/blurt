import { readFileSync } from "node:fs";
import { join } from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, it } from "vitest";
import { ALIASES, Egg, EggSprite, ICON_NAMES, ICONS, Icon, SPRITE, eggSvg, iconSvg, resolveIcon, useIconSvg } from "../src";

// Names the review canvas (web/packages/review) uses.
const REVIEW = ["check", "x", "chevron-up", "chevron-down", "download", "folder", "eye", "wand", "code", "copy", "moon",
  "keyboard", "languages", "play", "film", "video", "help-circle", "quote", "merge", "undo", "external-link", "pencil",
  "search", "git-commit"];
// Brand glyphs the apps use in place of emoji.
const BRAND = ["chicken", "blurt", "egg", "egg-fill", "hatch", "hatched", "nest", "perch", "claw", "peck", "bug", "spark",
  "note", "task", "mic", "waveform", "snap", "snap-to-perch", "agent", "agent-run", "mcp", "ink"];

it("has every name the review canvas and the apps use", () => {
  for (const n of [...REVIEW, ...BRAND]) expect(ICON_NAMES).toContain(n);
});

it("aliases resolve to real icons", () => {
  for (const [a, t] of Object.entries(ALIASES)) {
    expect(ICONS).toHaveProperty(t);
    expect(resolveIcon(a)).toBe(t);
  }
  expect(resolveIcon("nope")).toBeUndefined();
});

it("geometry is absolute M/L/C/Z only", () => {
  for (const n of ICON_NAMES) for (const [, d] of ICONS[n]) expect(d).toMatch(/^M[-\d. MLCZ]+$/);
});

it("<Icon> renders the same markup contract as the canvas stand-in", () => {
  const html = renderToStaticMarkup(<Icon name="check" size={16} className="x" />);
  expect(html).toContain('class="ico x"');
  expect(html).toContain('width="16"');
  expect(html).toContain('stroke-width="1.75"');
  expect(html).toContain('aria-hidden="true"');
  const titled = renderToStaticMarkup(<Icon name="close" title="Close" />);
  expect(titled).toContain("<title>Close</title>");
  expect(titled).toContain('role="img"');
  expect(titled).not.toContain(" width=");
});

it("fill layers paint with currentColor", () => {
  expect(renderToStaticMarkup(<Icon name="egg-fill" />)).toContain('fill="currentColor"');
  expect(iconSvg("record-fill")).toContain('fill="currentColor" stroke="none"');
});

it("string helpers", () => {
  expect(iconSvg("chicken", { size: 14, title: "Process" })).toMatch(/^<svg class="ico" width="14" height="14" viewBox="0 0 24 24".*<title>Process<\/title><path /);
  expect(useIconSvg("pen")).toContain('href="#bi-pencil"');
  for (const n of ICON_NAMES) expect(SPRITE).toContain(`<symbol id="bi-${n}"`);
  for (const k of ["issue", "idea", "note", "task", "custom"]) expect(SPRITE).toContain(`<symbol id="egg-${k}"`);
});

it("eggs: known kinds use their symbol, custom lenses get the shared pastel hue", () => {
  expect(eggSvg("idea")).toContain('href="#egg-idea"');
  const c = renderToStaticMarkup(<Egg kind="perf" />);
  expect(c).toContain('href="#egg-custom"');
  expect(c).toMatch(/color:hsl\(\d+ 62% 80%\)/);
  expect(renderToStaticMarkup(<EggSprite />)).toContain('id="eg-idea"');
});

it("sprite.svg is the generated sprite (kept in sync by build.py)", () => {
  const f = readFileSync(join(__dirname, "../sprite.svg"), "utf8");
  for (const n of ICON_NAMES) expect(f).toContain(`<symbol id="bi-${n}"`);
});
