/* @blurt/icons — React components over the generated icon data. Non-React pages import "@blurt/icons/core".
   UI rule: icons come from <Icon name="…"> / <Egg kind="…">, never emoji or text glyphs. */
import type { CSSProperties } from "react";
import { EGG_SPRITE, ICONS, eggRef, resolveIcon, type IconLayer, type IconName } from "./core";

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

/** The kind-egg sprite (gradients + <symbol id="egg-KIND">). Render once per page, before any <Egg>. */
export function EggSprite() {
  return (
    <svg
      width="0"
      height="0"
      style={{ position: "absolute" }}
      aria-hidden="true"
      focusable="false"
      dangerouslySetInnerHTML={{ __html: EGG_SPRITE_INNER }}
    />
  );
}
const EGG_SPRITE_INNER = EGG_SPRITE.replace(/^<svg[^>]*>|<\/svg>$/g, "");

/** A kind egg: issue / idea / note / task, anything else = a custom lens's pastel egg. */
export function Egg({ kind, className, title }: { kind: string; className?: string; title?: string }) {
  const { id, color } = eggRef(kind);
  return (
    <svg
      className={"egg" + (className ? " " + className : "")}
      viewBox="0 0 16 16"
      aria-hidden={title ? undefined : true}
      role={title ? "img" : undefined}
      style={color ? { color } : undefined}
    >
      {title ? <title>{title}</title> : null}
      <use href={`#${id}`} />
    </svg>
  );
}
