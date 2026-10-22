/* @blurt/icons — React components over the generated icon data. Non-React pages import "@blurt/icons/core".
   UI rule: icons come from <Icon name="…">, never emoji or text glyphs. */
import type { CSSProperties } from "react";
import { ICONS, resolveIcon, type IconLayer, type IconName } from "./core";

export * from "./core";

export interface IconProps {
  name: IconName;
  /** px; omit to size with CSS (`.ico { width: 1em; height: 1em }` or similar) */
  size?: number;
  className?: string;
  /** accessible name; without it the icon is decorative (aria-hidden) */
  title?: string;
  style?: CSSProperties;
}

export function Icon({ name, size, className, title, style }: IconProps) {
  const n = resolveIcon(name);
  const layers = (n ? ICONS[n] : []) as readonly IconLayer[];
  return (
    <svg
      className={"ico" + (className ? " " + className : "")}
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden={title ? undefined : true}
      role={title ? "img" : undefined}
      style={style}
    >
      {title ? <title>{title}</title> : null}
      {layers.map(([mode, d, op], i) =>
        mode === 1 ? <path key={i} d={d} fill="currentColor" stroke="none" opacity={op} /> : <path key={i} d={d} opacity={op} />,
      )}
    </svg>
  );
}
