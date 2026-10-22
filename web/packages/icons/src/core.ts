/* @blurt/icons/core — no React. The icon family as data + string helpers for plain pages (overlays, single-file HTML).
   Geometry is generated from assets/icons/*.svg (python3 assets/icons/tools/build.py); never edit generated.ts. */
import { ALIASES, GROUPS, ICONS, TITLES, type CanonicalIconName, type IconLayer } from "./generated";

export { ALIASES, GROUPS, ICONS, TITLES, type CanonicalIconName, type IconLayer };

/** Every name <Icon> accepts: the canonical names plus aliases (close → x, pen → pencil, process → chicken…). */
export type IconName = CanonicalIconName | keyof typeof ALIASES;

export const ICON_NAMES = Object.keys(ICONS) as CanonicalIconName[];

export function resolveIcon(name: IconName | string): CanonicalIconName | undefined {
  if (name in ICONS) return name as CanonicalIconName;
  return (ALIASES as Record<string, CanonicalIconName>)[name];
}

/** The <svg> root attributes every icon shares. */
export const SVG_ATTRS = {
  viewBox: "0 0 24 24",
  fill: "none",
  stroke: "currentColor",
  "stroke-width": "1.75",
  "stroke-linecap": "round",
  "stroke-linejoin": "round",
} as const;

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

export function innerMarkup(name: IconName): string {
  const n = resolveIcon(name);
  if (!n) throw new Error(`unknown icon: ${name}`);
  return (ICONS[n] as readonly IconLayer[])
    .map(([mode, d, op]) => `<path d="${d}"${mode === 1 ? ' fill="currentColor" stroke="none"' : ""}${op != null ? ` opacity="${op}"` : ""}/>`)
    .join("");
}

export interface IconSvgOptions {
  size?: number;
  className?: string;
  title?: string;
}

/** A complete inline <svg> string (class "ico", like the React <Icon>). Decorative unless `title` is given. */
export function iconSvg(name: IconName, { size, className, title }: IconSvgOptions = {}): string {
  const attrs = Object.entries(SVG_ATTRS).map(([k, v]) => `${k}="${v}"`).join(" ");
  const wh = size ? ` width="${size}" height="${size}"` : "";
  const a11y = title ? ` role="img"><title>${esc(title)}</title>` : ` aria-hidden="true">`;
  return `<svg class="ico${className ? " " + esc(className) : ""}"${wh} ${attrs}${a11y}${innerMarkup(name)}</svg>`;
}

/** All icons as <symbol id="bi-NAME">. Inline once per page, then useIconSvg(). */
export const SPRITE: string = (() => {
  const syms = ICON_NAMES.map(
    (n) =>
      `<symbol id="bi-${n}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">${innerMarkup(n)}</symbol>`,
  ).join("");
  return `<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0" style="position:absolute" aria-hidden="true" focusable="false"><defs>${syms}</defs></svg>`;
})();

/** <svg><use href="#bi-NAME"/></svg> — for pages that inlined SPRITE (or sprite.svg). */
export function useIconSvg(name: IconName, { size, className, title }: IconSvgOptions = {}): string {
  const n = resolveIcon(name);
  if (!n) throw new Error(`unknown icon: ${name}`);
  const wh = size ? ` width="${size}" height="${size}"` : "";
  const a11y = title ? ` role="img"><title>${esc(title)}</title>` : ` aria-hidden="true">`;
  return `<svg class="ico${className ? " " + esc(className) : ""}" viewBox="0 0 24 24"${wh}${a11y}<use href="#bi-${n}"/></svg>`;
}
