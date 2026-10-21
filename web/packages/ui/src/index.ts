/** Platform + theme selection for Blurt web surfaces. The CSS lives in tokens.css / base.css. */
export type Platform = "mac" | "win" | "gnome";
export type ThemePref = "auto" | "light" | "dark";
export type Theme = "light" | "dark";

export const PLATFORMS: readonly Platform[] = ["mac", "win", "gnome"];

export function isPlatform(v: unknown): v is Platform {
  return v === "mac" || v === "win" || v === "gnome";
}

/** Best guess from the user agent: macOS → mac, Windows → win, everything else (Linux, BSD) → gnome. */
export function detectPlatform(nav: { userAgent?: string; platform?: string; userAgentData?: { platform?: string } } =
  typeof navigator === "undefined" ? {} : (navigator as never)): Platform {
  const p = `${nav.userAgentData?.platform ?? ""} ${nav.platform ?? ""} ${nav.userAgent ?? ""}`.toLowerCase();
  if (/mac|iphone|ipad/.test(p)) return "mac";
  if (/win/.test(p)) return "win";
  return "gnome";
}

export interface ThemeController {
  /** the theme on screen now */
  readonly theme: Theme;
  /** set the preference; "auto" follows the system and keeps following it */
  set(pref: ThemePref): void;
  dispose(): void;
}

/** Puts data-theme on `el` (default <html>) and keeps it in sync with the system while the preference is "auto". */
export function applyTheme(pref: ThemePref, el: HTMLElement = document.documentElement,
  onChange?: (t: Theme) => void): ThemeController {
  const mq = typeof matchMedia === "function" ? matchMedia("(prefers-color-scheme: dark)") : null;
  let cur: ThemePref = pref;
  let shown: Theme = "light";
  const paint = () => {
    const t: Theme = cur === "auto" ? (mq?.matches ? "dark" : "light") : cur;
    if (el.dataset.theme !== t) el.dataset.theme = t;
    if (t !== shown) {
      shown = t;
      onChange?.(t);
    }
  };
  const listener = () => {
    if (cur === "auto") paint();
  };
  mq?.addEventListener?.("change", listener);
  paint();
  return {
    get theme() {
      return shown;
    },
    set(p) {
      cur = p;
      paint();
    },
    dispose() {
      mq?.removeEventListener?.("change", listener);
    },
  };
}

export function applyPlatform(p: Platform, el: HTMLElement = document.documentElement) {
  el.dataset.platform = p;
}

/** The system accent colour from the host (e.g. NSColor.controlAccentColor as #rrggbb); null clears it. */
export function setSystemAccent(color: string | null, el: HTMLElement = document.documentElement) {
  if (color) el.style.setProperty("--sys-accent", color);
  else el.style.removeProperty("--sys-accent");
}

// ---------------------------------------------------------------- contrast (used by the token tests)
export type RGBA = [number, number, number, number];

export function parseColor(c: string): RGBA {
  c = c.trim().toLowerCase();
  let m = c.match(/^#([0-9a-f]{6})$/);
  if (m) {
    const n = parseInt(m[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255, 1];
  }
  m = c.match(/^rgba?\(([^)]+)\)$/);
  if (m) {
    const p = m[1].split(",").map((x) => parseFloat(x));
    return [p[0], p[1], p[2], p[3] ?? 1];
  }
  throw new Error(`unsupported colour ${c}`);
}

export function over(fg: RGBA, bg: RGBA): RGBA {
  const a = fg[3];
  return [fg[0] * a + bg[0] * (1 - a), fg[1] * a + bg[1] * (1 - a), fg[2] * a + bg[2] * (1 - a), 1];
}

function lum([r, g, b]: RGBA) {
  const f = (v: number) => {
    v /= 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
}

export function contrast(fg: string, bg: string): number {
  const b = parseColor(bg);
  const f = over(parseColor(fg), b);
  const [l1, l2] = [lum(f), lum(b)].sort((x, y) => y - x);
  return (l1 + 0.05) / (l2 + 0.05);
}
