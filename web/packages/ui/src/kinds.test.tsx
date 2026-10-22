import { readFileSync } from "node:fs";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { contrast } from "./contrast";
import { customKindColor, kindHue, kindIcon, ringShapes, statusRingSvg } from "./kinds";
import { STATES } from "./lifecycle";
import { KindIcon, StatusRing } from "./react";

const css = readFileSync(new URL("./tokens.css", import.meta.url), "utf8");
const val = (theme: "light" | "dark", name: string) => {
  const block = theme === "light" ? css.split('[data-theme="dark"]')[0] : css.split('[data-theme="dark"] {')[1];
  return block.match(new RegExp(`${name}:\\s*(#[0-9a-f]{6})`, "i"))![1];
};
const SURFACES = { light: ["#ffffff", "#f6f6f6", "#ececec", "#f3f3f3", "#eaeaea", "#fafafa", "#ebebeb", "#fbfbfb"],
  dark: ["#1e1e1e", "#242424", "#2a2a2a", "#323232", "#202020", "#2b2b2b", "#333333", "#303030", "#383838"] };

describe("kinds (K8)", () => {
  it("maps kinds to icons; custom lenses get a tag", () => {
    expect(["issue", "idea", "note", "task", "perf"].map(kindIcon)).toEqual(["bug", "lightbulb", "document", "checklist", "tag"]);
  });
  it.each(["light", "dark"] as const)("%s: kind colours and the to-verify colour have 3:1 on every surface", (t) => {
    for (const name of ["--kind-issue", "--kind-idea", "--kind-note", "--kind-task", "--warn"])
      for (const s of SURFACES[t]) expect(contrast(val(t, name), s), `${name} on ${s}`).toBeGreaterThanOrEqual(3);
  });
  it("custom lens colours are stable per name and readable in both themes", () => {
    expect(kindHue("perf")).toBe(kindHue("perf"));
    for (const k of ["perf", "competitor", "a11y", "copy", "legal", "研究", "y"]) {
      for (const t of ["light", "dark"] as const)
        for (const s of SURFACES[t]) expect(contrast(customKindColor(k, t), s), `${k} ${t}`).toBeGreaterThanOrEqual(3);
    }
  });
  it("<KindIcon> carries the kind class and an accessible name when given", () => {
    const h = renderToStaticMarkup(<KindIcon kind="idea" title="Idea" />);
    expect(h).toContain('class="kind-ic k-idea"');
    expect(h).toContain("<title>Idea</title>");
    expect(renderToStaticMarkup(<KindIcon kind="perf" />)).toMatch(/--kc-light:#[0-9a-f]{6};--kc-dark:#[0-9a-f]{6}/);
  });
});

describe("state ring (K8)", () => {
  it("every state draws inside its box at 14 and 18", () => {
    for (const size of [14, 18])
      for (const s of STATES)
        for (const sh of ringShapes(s, size)) {
          // circles (plus half the 1.5 line for stroked ones), and the absolute M/L/V points of the glyph paths
          const pts =
            sh.el === "circle"
              ? [sh.cx - sh.r, sh.cx + sh.r, sh.cy - sh.r, sh.cy + sh.r].map((n, i) => n + (sh.paint === "stroke" ? (i % 2 ? 0.75 : -0.75) : 0))
              : /[aA]/.test(sh.d) ? [] : (sh.d.match(/-?\d+(?:\.\d+)?/g) || []).map(Number);
          for (const n of pts) {
            expect(n, `${s}@${size}`).toBeGreaterThanOrEqual(0);
            expect(n, `${s}@${size}`).toBeLessThanOrEqual(size);
          }
        }
  });
  it("distinct drawing per state; glyphs are shapes, never text", () => {
    const svgs = STATES.map((s) => statusRingSvg(s, 14));
    expect(new Set(svgs).size).toBe(8);
    for (const s of svgs) expect(s).not.toMatch(/<text|[!\u2713\u2714]/);
    expect(statusRingSvg("done", 14, "Done")).toContain('aria-label="Done"');
  });
  it("new is a ring of 8 dashes from 12 o'clock; discarded a ring and a cross (K8 geometry)", () => {
    for (const size of [14, 18]) {
      const c = size / 2, R = c - 1.25, u = size / 14;
      const [d] = ringShapes("new", size);
      expect(d.el === "path" && d.d.startsWith(`M${c} ${c - R}A`)).toBe(true);
      expect(d.el === "path" ? d.dash : 0).toBeCloseTo((2 * Math.PI * R) / 16, 1);
      const [ring, x] = ringShapes("discarded", size);
      expect(ring).toMatchObject({ el: "circle", r: R, paint: "stroke" });
      const n = (x.el === "path" ? x.d : "").match(/-?\d+(?:\.\d+)?/g)!.map(Number);
      const a = c - 2.1 * u, b = c + 2.1 * u;
      [a, a, b, b, b, a, a, b].forEach((v, k) => expect(n[k]).toBeCloseTo(v, 1));
    }
    expect(statusRingSvg("new", 14)).toMatch(/stroke-dasharray="2\.26" stroke-linecap="butt"/);
  });
  it("<StatusRing> matches the string version", () => {
    expect(renderToStaticMarkup(<StatusRing state="new" />)).toContain('stroke-dasharray="2.26"');
    const h = renderToStaticMarkup(<StatusRing state="in_progress" size={18} label="In progress" />);
    expect(h).toContain('class="sring s-in_progress"');
    expect(h).toContain('aria-label="In progress"');
    expect(h).toContain('width="18"');
  });
});
