import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, it } from "vitest";
import { MASCOT, MASCOT_CLIPS, Mascot, PEEP_STATES, frameAt, mascotHtml, mascotSeconds, peepState, pickTier, stillFrame, talkingFrame } from "../src";

const dir = join(import.meta.dirname, "../peep");
const tiers = MASCOT.tiers as Record<string, { square: number; cell: number; clips: Record<string, { frames: number; fps: number; open?: number[] }> }>;

it("is Peep, from the release package: every tier's clips have their sheet, the island every state it plays", () => {
  expect(MASCOT._).toContain("import_peep.py");
  for (const [t, tier] of Object.entries(tiers)) {
    for (const [s, c] of Object.entries(tier.clips)) {
      expect(PEEP_STATES).toContain(s);
      expect(existsSync(join(dir, `${t}-${s}.webp`))).toBe(true);
      expect(c.frames).toBeGreaterThan(10);
      expect(mascotSeconds(s as never)).toBeGreaterThan(0.5);
    }
  }
  for (const s of ["idle", "listening", "talking", "thinking", "done", "error"]) {
    expect(tiers.s.clips).toHaveProperty(s);
    expect(tiers.xs.clips).toHaveProperty(s);
  }
  for (const s of ["idle", "hello", "done"]) expect(tiers.l.clips).toHaveProperty(s);
  expect(tiers.s.clips.talking.open).toHaveLength(tiers.s.clips.talking.frames);
});

it("stays small: every sheet together under 800 KB, each tier's cell no larger than its use", () => {
  const total = Object.entries(tiers).flatMap(([t, tier]) => Object.keys(tier.clips).map((s) => statSync(join(dir, `${t}-${s}.webp`)).size));
  expect(total.reduce((a, b) => a + b, 0)).toBeLessThan(800 * 1024);
  expect(tiers.xs.square).toBeLessThanOrEqual(40);
  expect(tiers.s.square).toBeLessThanOrEqual(80);
  expect(tiers.l.square).toBeLessThanOrEqual(216);
});

it("maps the 1A chick's clip names to the state the Mac plays there", () => {
  for (const c of ["idle", "listening", "thinking", "wobble", "hatching", "happy", "peck"]) expect(MASCOT_CLIPS).toContain(c);
  expect([peepState("happy"), peepState("hatching"), peepState("wobble"), peepState("peck")]).toEqual(["done", "done", "thinking", "done"]);
  expect(peepState("nonsense")).toBe("idle");
});

it("plays as BlurtCore/Peep.swift: loops wrap, one-shots hold, stills say the state, the beak follows the level", () => {
  const c = { frames: 10, fps: 30 };
  expect(frameAt(0.5, c, true)).toBe(5);
  expect(frameAt(1, c, true)).toBe(0);
  expect(frameAt(5, c, false)).toBe(9);
  expect(stillFrame("idle", c)).toBe(0);
  expect(stillFrame("thinking", { frames: 45, fps: 30 })).toBe(9);
  expect(stillFrame("done", { frames: 42, fps: 30, still: 26 })).toBe(26);
  const talk = tiers.s.clips.talking as { frames: number; fps: number; open: number[] };
  const shut = talkingFrame(0, talk), wide = talkingFrame(1, talk);
  expect(talk.open[shut]).toBe(Math.min(...talk.open));
  expect(talk.open[wide]).toBe(Math.max(...talk.open));
});

it("picks the tier by device pixels: the small ones in the island (by the screen's scale), the large one in the window", () => {
  expect(pickTier(24, "talking", ["xs", "s", "l"])).toBe("xs"); // the 24 px ear at 1×
  expect(pickTier(30, "talking", ["xs", "s", "l"])).toBe("xs"); // 1.25×
  expect(pickTier(36, "talking", ["xs", "s", "l"])).toBe("s"); // 1.5×
  expect(pickTier(48, "talking", ["s", "l"])).toBe("s");
  expect(pickTier(216, "hello", ["s", "l"])).toBe("l");
  expect(pickTier(216, "talking", ["s", "l"])).toBe("s"); // only the small tier has it
  expect(pickTier(48, "hello", ["s"])).toBe("s"); // the island's launch hello plays from the small sheets
  expect(pickTier(48, "listening", ["l"])).toBeUndefined(); // the window's tier has only idle, hello and done
});

it("renders decorative unless titled; legacy names come out as Peep states", () => {
  expect(mascotHtml("happy", { size: 40 })).toBe('<span class="mascot" data-clip="done" style="--mascot-size:40px" aria-hidden="true"></span>');
  expect(mascotHtml("talking", { size: 24, level: true })).toContain('data-clip="talking" data-level');
  const html = renderToStaticMarkup(<Mascot clip="hello" then="idle" size={64} title="Blurt" />);
  expect(html).toContain('data-clip="hello"');
  expect(html).toContain('data-then="idle"');
  expect(html).toContain('aria-label="Blurt"');
  expect(html).toContain("--mascot-size:64px");
});

it("respects reduced motion (the ticker shows the still) and needs no keyframes", () => {
  const src = readFileSync(join(import.meta.dirname, "../src/mascot.ts"), "utf8");
  const css = readFileSync(join(import.meta.dirname, "../src/mascot.css"), "utf8");
  expect(src).toContain("prefers-reduced-motion: reduce");
  expect(css).not.toContain("@keyframes");
});
