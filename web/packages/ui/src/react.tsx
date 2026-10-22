/* K8 components: <KindIcon kind/> and <StatusRing state/>. Colours come from tokens.css + base.css. */
import { Icon, type IconName } from "@blurt/icons";
import type { CSSProperties } from "react";
import { kindIcon, kindStyle, ringAttrs, ringShapes, type WorkState } from "./kinds";

export interface KindIconProps {
  kind: string;
  /** px (default 16) */
  size?: number;
  /** accessible name (the localized kind); without it the icon is decorative */
  title?: string;
  className?: string;
}

/** A kind's icon in its colour: issue = bug, idea = light bulb, note = document, task = checklist, custom lens = tag. */
export function KindIcon({ kind, size = 16, title, className }: KindIconProps) {
  return (
    <span className={"kind-ic k-" + kind.replace(/[^\w-]/g, "_") + (className ? " " + className : "")} style={kindStyle(kind) as CSSProperties}>
      <Icon name={kindIcon(kind) as IconName} size={size} title={title} />
    </span>
  );
}

export interface StatusRingProps {
  state: WorkState;
  /** px: 14 in lists, 18 in the detail */
  size?: number;
  /** accessible name: the localized `work.<state>` */
  label?: string;
  className?: string;
}

/** The work-state ring (K8): todo empty · handed off dot · in progress half · to verify ! · done check · won't do slash. */
export function StatusRing({ state, size = 14, label, className }: StatusRingProps) {
  return (
    <svg
      className={"sring s-" + state + (className ? " " + className : "")}
      width={size}
      height={size}
      viewBox={`0 0 ${size} ${size}`}
      strokeWidth={1.5}
      strokeLinecap="round"
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
    >
      {ringShapes(state, size).map((s, i) => {
        const a = ringAttrs(s);
        return s.el === "circle" ? <circle key={i} {...a} /> : <path key={i} {...a} />;
      })}
    </svg>
  );
}
