import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, it } from "vitest";
import { MASCOT, MASCOT_CLIPS, Mascot, mascotHtml, mascotSeconds } from "../src";

const dir = join(import.meta.dirname, "../mascot");
const css = readFileSync(join(dir, "mascot.css"), "utf8");

it("has the clips the apps play, each with its strip and a CSS animation", () => {
  for (const c of ["idle", "listening", "thinking", "wobble", "hatching", "happy", "peck"]) expect(MASCOT_CLIPS).toContain(c);
  for (const [name, c] of Object.entries(MASCOT.clips)) {
    expect(existsSync(join(dir, `${c.sheet}.webp`))).toBe(true);
    expect(css).toContain(`@keyframes blurt-mascot-${name} {`);
    expect(css).toContain(`.mascot[data-clip="${name}"]`);
    for (const [f, t] of c.timeline) {
      expect(f).toBeGreaterThanOrEqual(0);
      expect(f).toBeLessThan(c.frames);
      expect(t).toBeGreaterThan(0);
    }
    expect(c.still).toBeLessThan(c.frames);
    expect(mascotSeconds(name as keyof typeof MASCOT.clips)).toBeGreaterThan(0.5);
  }
});

it("stays small: every strip together under 2.5 MB", () => {
  const sheets = new Set(Object.values(MASCOT.clips).map((c) => c.sheet));
  const total = [...sheets].reduce((s, n) => s + statSync(join(dir, `${n}.webp`)).size, 0);
  expect(total).toBeLessThan(2.5 * 1024 * 1024);
});

it("respects reduced motion and plays one-shots once", () => {
  expect(css).toMatch(/@media \(prefers-reduced-motion: reduce\) \{\s+\.mascot \{ animation: none !important; \}/);
  expect(css).toMatch(/data-clip="peck"\][^}]*1 forwards/);
  expect(css).toMatch(/data-clip="idle"\][^}]*infinite/);
});

it("renders decorative unless titled", () => {
  expect(mascotHtml("happy", { size: 40 })).toBe('<span class="mascot" data-clip="happy" style="--mascot-size:40px" aria-hidden="true"></span>');
  const html = renderToStaticMarkup(<Mascot clip="idle" size={64} title="Blurt" />);
  expect(html).toContain('data-clip="idle"');
  expect(html).toContain('aria-label="Blurt"');
  expect(html).toContain("--mascot-size:64px");
});
