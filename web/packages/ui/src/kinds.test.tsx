import { readFileSync } from "node:fs";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { contrast } from "./contrast";
import { customKindColor, kindHue, kindIcon, ringShapes, statusRingSvg, WORK_STATES, workStateOf } from "./kinds";
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

describe("work state ring (K8)", () => {
  it("reads work, and maps v2 fix states (K3)", () => {
    expect(workStateOf({ work: { state: "to_verify" } })).toBe("to_verify");
    expect(workStateOf({})).toBe("todo");
    expect(workStateOf({ fix: { state: "fixing" } })).toBe("in_progress");
    expect(workStateOf({ fix: { state: "fixed" } })).toBe("to_verify");
    expect(workStateOf({ fix: { state: "wontfix", agent: "claude" } })).toBe("to_verify");
    expect(workStateOf({ fix: { state: "wontfix", agent: "human" } })).toBe("wontfix");
    expect(workStateOf({ fix: { state: "reopened" } })).toBe("todo");
  });
  it("every state draws inside its box at 14 and 18", () => {
    for (const size of [14, 18])
      for (const s of WORK_STATES)
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
    const svgs = WORK_STATES.map((s) => statusRingSvg(s, 14));
    expect(new Set(svgs).size).toBe(6);
    for (const s of svgs) expect(s).not.toMatch(/<text|[!✓✔]/);
    expect(statusRingSvg("done", 14, "Done")).toContain('aria-label="Done"');
  });
  it("<StatusRing> matches the string version", () => {
    const h = renderToStaticMarkup(<StatusRing state="in_progress" size={18} label="In progress" />);
    expect(h).toContain('class="sring s-in_progress"');
    expect(h).toContain('aria-label="In progress"');
    expect(h).toContain('width="18"');
  });
});
