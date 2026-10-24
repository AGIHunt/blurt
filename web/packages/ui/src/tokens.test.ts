import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { contrast, customKindColor, detectPlatform, parseColor, PLATFORMS, type Platform } from "./index";

const raw = readFileSync(new URL("./tokens.css", import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
/** The block parser below is naive (selector { decls }), so drop @media … { … } blocks (Increase Contrast, Reduce
    Transparency) first: they are overrides for those settings, not the default cascade. */
function stripMedia(s: string): string {
  let out = "";
  let i = 0;
  for (;;) {
    const at = s.indexOf("@media", i);
    if (at < 0) return out + s.slice(i);
    out += s.slice(i, at);
    let j = s.indexOf("{", at);
    let depth = 0;
    for (; j < s.length; j++) {
      if (s[j] === "{") depth++;
      else if (s[j] === "}" && --depth === 0) break;
    }
    i = j + 1;
  }
}
const css = stripMedia(raw);

/** assets/color/tokens.json, the one source of colour: the contrast floors come from here. */
const SPEC = JSON.parse(readFileSync(new URL("../../../../assets/color/tokens.json", import.meta.url), "utf8"));

/** Resolve the custom properties for one platform × theme the way the cascade would (later blocks win). */
function tokens(platform: Platform, theme: "light" | "dark"): Record<string, string> {
  const out: Record<string, string> = {};
  const attrs = { platform, theme };
  for (const m of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const selectors = m[1].split(",").map((s) => s.trim());
    const hit = selectors.some((s) => {
      if (s === ":root") return true;
      const conds = [...s.matchAll(/\[data-(platform|theme)(?:="(\w+)")?\]/g)];
      return conds.length > 0 && conds.every(([, k, v]) => v === undefined || attrs[k as "platform" | "theme"] === v);
    });
    if (!hit) continue;
    for (const d of m[2].matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) out[d[1]] = d[2].trim();
  }
  // var(--x) / var(--sys-accent, var(--x)) -> the value (the host's --sys-accent is not set here)
  const resolve = (v: string, depth = 0): string => {
    const m = v.match(/^var\((--[\w-]+)(?:,\s*(.+))?\)$/);
    if (!m || depth > 8) return v;
    if (out[m[1]] !== undefined) return resolve(out[m[1]], depth + 1);
    return m[2] ? resolve(m[2].trim(), depth + 1) : v;
  };
  for (const k of Object.keys(out)) out[k] = resolve(out[k]);
  return out;
}

const lum = (c: string) => {
  const [r, g, b] = parseColor(c);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};

describe.each(PLATFORMS.flatMap((p) => (["light", "dark"] as const).map((t) => [p, t] as const)))("%s %s", (p, t) => {
  const k = tokens(p, t);

  it("defines every token", () => {
    for (const name of ["--bg", "--bg-2", "--panel", "--raise", "--ink", "--ink-2", "--mute", "--faint", "--line",
      "--brand", "--brand-ink", "--brand-tint", "--on-brand", "--brand-accent", "--brand-button", "--on-brand-button",
      "--brand-gradient", "--brand-gradient-v", "--brand-gradient-h", "--brand-text", "--brand-field", "--grain",
      "--ok", "--ok-soft", "--on-ok", "--attn", "--attn-ink", "--attn-soft", "--on-attn", "--err", "--info", "--rec",
      "--drop", "--focus", "--font", "--r", "--r-sm", "--fs"]) {
      expect(k[name], name).toBeTruthy();
    }
  });

  it("keeps the old names as deprecated aliases of the new ones", () => {
    const alias: Record<string, string> = { "--accent": "--brand", "--accent-ink": "--on-brand", "--accent-soft": "--brand-tint",
      "--keep": "--ok", "--keep-ink": "--ok", "--drop-ink": "--err", "--amber": "--attn-ink", "--warn": "--attn",
      "--sev-high": "--kind-issue", "--sev-medium": "--attn-ink", "--sev-low": "--info" };
    for (const [old, now] of Object.entries(alias)) expect(k[old], old).toBe(k[now]);
  });

  it("focus and native controls use the brand accent unless the host injects one", () => {
    expect(k["--focus"]).toBe(k["--brand-accent"]);
  });

  it("text is readable on every surface", () => {
    for (const s of ["--bg", "--bg-2", "--panel", "--raise"]) {
      expect(contrast(k["--ink"], k[s]), `ink on ${s}`).toBeGreaterThanOrEqual(7);
      expect(contrast(k["--ink-2"], k[s]), `ink-2 on ${s}`).toBeGreaterThanOrEqual(4.5);
      expect(contrast(k["--mute"], k[s]), `mute on ${s}`).toBeGreaterThanOrEqual(4.5);
    }
    expect(contrast(k["--faint"], k["--bg"]), "faint").toBeGreaterThanOrEqual(2.2);
  });

  it("brand and state colours keep the floors in tokens.json on the app's surfaces", () => {
    const floors: [string, number][] = [
      ["--brand-ink", SPEC.brand.ink.min],
      ["--ok", SPEC.semantic.ok.min],
      ["--err", SPEC.semantic.err.min],
      ["--attn-ink", SPEC.semantic.attnInk.min],
      ["--attn", SPEC.semantic.attn.min],
      ["--info", SPEC.semantic.info.min],
    ];
    // tokens.json checks its floors on the mac surfaces; here every platform's bg and panel, and the raised surface
    // where it is one of those (GNOME dark's #383838 popovers take --err at 4.2 : 1, below the text floor)
    const checked = (SPEC.checks[t] as string[]).map((c) => c.toLowerCase());
    for (const s of ["--bg", "--panel", "--raise"].filter((s) => s !== "--raise" || checked.includes(k[s])))
      for (const [c, min] of floors) expect(contrast(k[c], k[s]), `${c} on ${s}`).toBeGreaterThanOrEqual(min);
    // text on fills
    expect(contrast(k["--on-brand"], k["--brand"]), "on-brand").toBeGreaterThanOrEqual(SPEC.brand.on.min);
    expect(contrast(k["--on-ok"], k["--ok"]), "on-ok").toBeGreaterThanOrEqual(SPEC.semantic.onOk.min);
    expect(contrast(k["--on-attn"], k["--attn"]), "on-attn").toBeGreaterThanOrEqual(SPEC.semantic.onAttn.min);
    // the button gradient carries white text along all of it
    for (const stop of k["--brand-button"].match(/#[0-9a-f]{6}/gi)!)
      expect(contrast(k["--on-brand-button"], stop), `white on ${stop}`).toBeGreaterThanOrEqual(4.5);
    // brand ink on the selection tint (a selected row keeps its icons)
    expect(contrast(k["--brand-ink"], parseRgbaOver(k["--brand-tint"], k["--panel"])), "ink on tint").toBeGreaterThanOrEqual(4.5);
  });

  it("K8: kind colours, the ring colours and custom lenses stand out (3:1) on every surface", () => {
    const surfaces = ["--bg", "--bg-2", "--panel", "--raise"].map((s) => k[s]);
    const colours = ["--kind-issue", "--kind-idea", "--kind-note", "--kind-task", "--attn", "--ok", "--brand-ink"].map((c) => [c, k[c]]);
    for (let h = 0; h < 360; h += 7) colours.push([`custom ${h}`, customKindColor(String.fromCharCode(h), t)]);
    for (const [name, c] of colours)
      for (const s of surfaces) expect(contrast(c, s), `${name} on ${s}`).toBeGreaterThanOrEqual(SPEC.kind.issue.min);
    // the glyph inside a filled ring
    expect(contrast(k["--on-attn"], k["--attn"]), "! on attn").toBeGreaterThanOrEqual(3);
    expect(contrast(k["--on-ok"], k["--ok"]), "check on ok").toBeGreaterThanOrEqual(3);
  });

  it("matches tokens.json (the generated block is current and nothing hand-written overrides it)", () => {
    const hex = (v: string) => v.slice(0, 7).toLowerCase();
    expect(k["--brand"]).toBe(hex(SPEC.brand.fill[t]));
    expect(k["--brand-ink"]).toBe(hex(SPEC.brand.ink[t]));
    expect(k["--ok"]).toBe(hex(SPEC.semantic.ok[t]));
    expect(k["--attn"]).toBe(hex(SPEC.semantic.attn[t]));
    for (const kind of ["issue", "idea", "note", "task"]) expect(k[`--kind-${kind}`], kind).toBe(hex(SPEC.kind[kind][t]));
  });

  if (t === "dark") {
    it("dark: elevation goes up in lightness, hairlines are faint white", () => {
      expect(lum(k["--panel"])).toBeGreaterThan(lum(k["--bg"]));
      expect(lum(k["--raise"])).toBeGreaterThan(lum(k["--panel"]));
      expect(lum(k["--bg-2"])).toBeGreaterThan(lum(k["--bg"]));
      expect(k["--line"]).toBe("rgba(255, 255, 255, 0.08)");
      expect(k["--ink"]).toBe("rgba(255, 255, 255, 0.92)");
      expect(k["--mute"]).toBe("rgba(255, 255, 255, 0.64)");
      expect(k["--faint"]).toBe("rgba(255, 255, 255, 0.4)");
    });
  }
});

/** a translucent colour flattened over a surface, as #rrggbb */
function parseRgbaOver(fg: string, bg: string): string {
  const [r, g, b, a] = parseColor(fg);
  const [R, G, B] = parseColor(bg);
  const mix = (x: number, y: number) => Math.round(x * a + y * (1 - a)).toString(16).padStart(2, "0");
  return `#${mix(r, R)}${mix(g, G)}${mix(b, B)}`;
}

it("no hand-written brand, state or kind colours outside the generated block", () => {
  const hand = raw.slice(raw.indexOf("/* @end generated colour */"));
  for (const name of ["--brand", "--ok", "--attn", "--err", "--rec", "--info", "--kind-issue", "--kind-idea", "--kind-note", "--kind-task"])
    expect(hand, name).not.toMatch(new RegExp(`${name}:\\s*#`));
  expect(hand.toLowerCase()).not.toMatch(/#f55b3e|#ff7a5c|245, 91, 62|255, 122, 92/); // the retired coral
});

it("uses the surfaces the design doc names for dark mode", () => {
  expect([tokens("mac", "dark")["--bg"], tokens("mac", "dark")["--panel"], tokens("mac", "dark")["--raise"]])
    .toEqual(["#1e1e1e", "#2a2a2a", "#323232"]);
  expect([tokens("win", "dark")["--bg"], tokens("win", "dark")["--panel"]]).toEqual(["#202020", "#2b2b2b"]);
  expect([tokens("gnome", "dark")["--bg"], tokens("gnome", "dark")["--panel"]]).toEqual(["#242424", "#303030"]);
});

it("detects the platform from the user agent", () => {
  expect(detectPlatform({ userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)" })).toBe("mac");
  expect(detectPlatform({ userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" })).toBe("win");
  expect(detectPlatform({ userAgent: "Mozilla/5.0 (X11; Linux x86_64)" })).toBe("gnome");
  expect(detectPlatform({ userAgentData: { platform: "Windows" } })).toBe("win");
});
