/* K8 — kind icons and the state ring, as data and plain SVG strings (no React; see ./react.tsx for components).
   The same rules are in Swift (Sources/BlurtApp/Icons/KindStyle.swift, StatusRing.swift); tests keep them in step. */
import { contrast } from "./contrast";
import type { State } from "./lifecycle";

export const KINDS = ["issue", "idea", "note", "task"] as const;
export type BuiltinKind = (typeof KINDS)[number];

const KIND_ICON: Record<BuiltinKind, string> = { issue: "bug", idea: "lightbulb", note: "document", task: "checkbox" };

export const isBuiltinKind = (k: string): k is BuiltinKind => (KINDS as readonly string[]).includes(k);

/** The icon name for a kind (@blurt/icons): bug / lightbulb / document (a page) / checkbox; a custom lens is a tag. */
export const kindIcon = (kind: string): string => (isBuiltinKind(kind) ? KIND_ICON[kind] : "tag");

/** A custom lens's hue: h = (h·31 + code unit) mod 360 over the name (same hash as the old eggs, Swift and Rust). */
export function kindHue(kind: string): number {
  let h = 0;
  for (let i = 0; i < kind.length; i++) h = (h * 31 + kind.charCodeAt(i)) % 360;
  return h;
}

/** Surfaces a kind colour must stand out from (≥ 3:1): the lightest / darkest panels of every platform's tokens. */
const SURFACE = { light: "#eaeaea", dark: "#383838" } as const;

export function hslHex(h: number, s: number, l: number): string {
  s /= 100;
  l /= 100;
  const k = (n: number) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n: number) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  return "#" + [f(0), f(8), f(4)].map((x) => Math.round(x * 255).toString(16).padStart(2, "0")).join("");
}

/** Hashed hues in this band (HSL degrees, inclusive) move 60° on, so no lens reads as brand mint or success green
    (assets/color/tokens.json kind.customHueGap; Swift KindStyle does the same). */
export const CUSTOM_HUE_GAP = [145, 190] as const;

/** The hue a custom lens is drawn in: kindHue, moved out of CUSTOM_HUE_GAP. */
export function customKindHue(kind: string): number {
  let h = kindHue(kind);
  if (h >= CUSTOM_HUE_GAP[0] && h <= CUSTOM_HUE_GAP[1]) h += 60;
  return h;
}

/** A custom lens's colour: HSL(h, 55%, 42%) light / HSL(h, 70%, 68%) dark (h = customKindHue), darkened / lightened
    in 2% steps until it has 3:1 against every surface (yellows and greens would not otherwise). */
export function customKindColor(kind: string, theme: "light" | "dark"): string {
  const h = customKindHue(kind);
  if (theme === "light") {
    for (let l = 42; l > 10; l -= 2) {
      const c = hslHex(h, 55, l);
      if (contrast(c, SURFACE.light) >= 3) return c;
    }
    return hslHex(h, 55, 10);
  }
  for (let l = 68; l < 95; l += 2) {
    const c = hslHex(h, 70, l);
    if (contrast(c, SURFACE.dark) >= 3) return c;
  }
  return hslHex(h, 70, 95);
}

/** Inline style for a kind's colour: built-in kinds use the theme tokens; a custom lens sets --kc-light / --kc-dark
    (base.css `.kind-ic` picks the one for the theme). */
export function kindStyle(kind: string): Record<string, string> {
  if (isBuiltinKind(kind)) return { color: `var(--kind-${kind})` };
  return { "--kc-light": customKindColor(kind, "light"), "--kc-dark": customKindColor(kind, "dark") };
}

// ---------------------------------------------------------------- the ring
/** One shape of the ring, in a size×size box: stroke = the state colour at 1.5, fill = the colour, cut = the glyph
    colour on a filled disk (white on done; dark on the dark theme's amber); dash = a dashed stroke (new). */
export type RingShape =
  | { el: "circle"; cx: number; cy: number; r: number; paint: "stroke" | "fill" }
  | { el: "path"; d: string; paint: "stroke" | "fill" | "cut-stroke" | "cut-fill"; dash?: number };

const r2 = (n: number) => Math.round(n * 100) / 100;
/** a filled dot as a path (two arcs), so "cut" shapes are all paths */
const dot = (cx: number, cy: number, r: number) => `M${r2(cx - r)} ${cy}a${r} ${r} 0 1 0 ${r2(2 * r)} 0a${r} ${r} 0 1 0 ${r2(-2 * r)} 0Z`;

/** Geometry for a state at `size` px (14 in lists, 18 in the detail). Line width 1.5 at every size. */
export function ringShapes(state: State, size: number): RingShape[] {
  const c = size / 2;
  const R = r2(c - 0.75 - 0.5); // outer edge half a pixel inside the box
  const ring = { el: "circle", cx: c, cy: c, r: R, paint: "stroke" } as const;
  const u = size / 14; // glyph scale: designed at 14
  switch (state) {
    case "new": {
      // the ring as a path from 12 o'clock, clockwise, cut into 16 equal parts: 8 dashes, 8 gaps (butt ends)
      const d = `M${c} ${r2(c - R)}A${R} ${R} 0 1 1 ${c} ${r2(c + R)}A${R} ${R} 0 1 1 ${c} ${r2(c - R)}`;
      return [{ el: "path", d, paint: "stroke", dash: r2((2 * Math.PI * R) / 16) }];
    }
    case "todo":
      return [ring];
    case "handed_off":
      return [ring, { el: "circle", cx: c, cy: c, r: 2 * u, paint: "fill" }];
    case "in_progress": {
      const ri = r2(R - 1.75 * u);
      return [ring, { el: "path", d: `M${c} ${r2(c - ri)}A${ri} ${ri} 0 0 1 ${c} ${r2(c + ri)}Z`, paint: "fill" }];
    }
    case "to_verify":
      return [
        { el: "circle", cx: c, cy: c, r: r2(R + 0.75), paint: "fill" },
        { el: "path", d: `M${c} ${r2(c - 3 * u)}V${r2(c + 0.6 * u)}`, paint: "cut-stroke" },
        { el: "path", d: dot(c, r2(c + 2.85 * u), r2(0.95 * u)), paint: "cut-fill" },
      ];
    case "done":
      return [
        { el: "circle", cx: c, cy: c, r: r2(R + 0.75), paint: "fill" },
        { el: "path", d: `M${r2(c - 2.9 * u)} ${r2(c + 0.1 * u)}L${r2(c - 0.9 * u)} ${r2(c + 2 * u)}L${r2(c + 3 * u)} ${r2(c - 2.2 * u)}`, paint: "cut-stroke" },
      ];
    case "wontfix": {
      const o = r2(R * Math.SQRT1_2);
      return [ring, { el: "path", d: `M${r2(c - o)} ${r2(c + o)}L${r2(c + o)} ${r2(c - o)}`, paint: "stroke" }];
    }
    case "discarded": {
      const a = r2(c - 2.1 * u), b = r2(c + 2.1 * u);
      return [ring, { el: "path", d: `M${a} ${a}L${b} ${b}M${b} ${a}L${a} ${b}`, paint: "stroke" }];
    }
  }
}

const attrs = (s: RingShape): Record<string, string> => {
  const base: Record<string, string> =
    s.el === "circle" ? { cx: String(s.cx), cy: String(s.cy), r: String(s.r) } : { d: s.d };
  if (s.paint === "stroke")
    return { ...base, fill: "none", stroke: "currentColor", ...(s.el === "path" && s.dash ? { "stroke-dasharray": String(s.dash), "stroke-linecap": "butt" } : {}) };
  if (s.paint === "fill") return { ...base, fill: "currentColor" };
  if (s.paint === "cut-fill") return { ...base, fill: "var(--ring-cut)" };
  return { ...base, fill: "none", stroke: "var(--ring-cut)" };
};
export const ringAttrs = attrs;

/** A complete <svg> for non-React pages (class "sring s-<state>"; colours come from base.css). */
export function statusRingSvg(state: State, size = 14, label?: string): string {
  const esc = (x: string) => x.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");
  const body = ringShapes(state, size)
    .map((s) => `<${s.el} ${Object.entries(attrs(s)).map(([k, v]) => `${k}="${v}"`).join(" ")}/>`)
    .join("");
  const a11y = label ? ` role="img" aria-label="${esc(label)}"` : ` aria-hidden="true"`;
  return `<svg class="sring s-${state}" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" stroke-width="1.5" stroke-linecap="round"${a11y}>${body}</svg>`;
}
