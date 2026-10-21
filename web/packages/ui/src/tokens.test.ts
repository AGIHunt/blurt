import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { contrast, customKindColor, detectPlatform, parseColor, PLATFORMS, type Platform } from "./index";

const css = readFileSync(new URL("./tokens.css", import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");

/** Resolve the custom properties for one platform × theme the way the cascade would (later blocks win). */
function tokens(platform: Platform, theme: "light" | "dark"): Record<string, string> {
  const out: Record<string, string> = {};
  const attrs = { platform, theme };
  for (const m of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const selectors = m[1].split(",").map((s) => s.trim());
    const hit = selectors.some((s) => {
      if (s === ":root") return true;
      const conds = [...s.matchAll(/\[data-(platform|theme)="(\w+)"\]/g)];
      return conds.length > 0 && conds.every(([, k, v]) => attrs[k as "platform" | "theme"] === v);
    });
    if (!hit) continue;
    for (const d of m[2].matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) out[d[1]] = d[2].trim();
  }
  // var(--sys-accent, #xxx) -> the fallback
  for (const [k, v] of Object.entries(out)) {
    const f = v.match(/^var\(--sys-accent,\s*(#[0-9a-f]{6})\)$/i);
    if (f) out[k] = f[1];
  }
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
      "--accent", "--accent-ink", "--keep", "--keep-ink", "--drop", "--drop-ink", "--amber", "--focus", "--font",
      "--r", "--r-sm", "--fs"]) {
      expect(k[name], name).toBeTruthy();
    }
  });

  it("text is readable on every surface", () => {
    for (const s of ["--bg", "--bg-2", "--panel", "--raise"]) {
      expect(contrast(k["--ink"], k[s]), `ink on ${s}`).toBeGreaterThanOrEqual(7);
      expect(contrast(k["--ink-2"], k[s]), `ink-2 on ${s}`).toBeGreaterThanOrEqual(4.5);
      expect(contrast(k["--mute"], k[s]), `mute on ${s}`).toBeGreaterThanOrEqual(4.5);
    }
    expect(contrast(k["--faint"], k["--bg"]), "faint").toBeGreaterThanOrEqual(2.2);
  });

  it("state colours read as text and carry text", () => {
    for (const c of ["--keep-ink", "--drop-ink", "--amber"]) {
      expect(contrast(k[c], k["--bg"]), c).toBeGreaterThanOrEqual(4.5);
    }
    expect(contrast(k["--accent-ink"], k["--accent"]), "on accent").toBeGreaterThanOrEqual(3);
    expect(contrast("#ffffff", k["--keep"]), "on keep").toBeGreaterThanOrEqual(3);
    expect(contrast(k["--sev-medium"], k["--bg"]), "sev-medium").toBeGreaterThanOrEqual(3);
  });

  it("K8: kind colours, the ring colours and custom lenses stand out (3:1) on every surface", () => {
    const surfaces = ["--bg", "--bg-2", "--panel", "--raise"].map((s) => k[s]);
    const colours = ["--kind-issue", "--kind-idea", "--kind-note", "--kind-task", "--warn", "--keep"].map((c) => [c, k[c]]);
    for (let h = 0; h < 360; h += 7) colours.push([`custom ${h}`, customKindColor(String.fromCharCode(h), t)]);
    for (const [name, c] of colours)
      for (const s of surfaces) expect(contrast(c, s), `${name} on ${s}`).toBeGreaterThanOrEqual(3);
    // the glyph inside a filled ring
    expect(contrast(t === "dark" ? "#2a1a00" : "#ffffff", k["--warn"]), "! on warn").toBeGreaterThanOrEqual(3);
    expect(contrast("#ffffff", k["--keep"]), "check on keep").toBeGreaterThanOrEqual(3);
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
      expect(k["--accent"]).toBe("#ff7a5c");
    });
  }
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
