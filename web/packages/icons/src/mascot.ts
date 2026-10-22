/* @blurt/icons/mascot — the colour mascot (the 1A round chick) for moments: done, hatching, listening, thinking,
   empty states. Frame strips + timelines come from assets/mascot (python3 assets/mascot/tools/build.py); the playing is
   pure CSS (`@blurt/icons/mascot.css`: steps(1) keyframes per clip, the still frame under prefers-reduced-motion), so
   import that stylesheet once in the app. No React here; <Mascot> in "@blurt/icons" wraps the same markup. */
import manifest from "../mascot/mascot.json";

export type MascotClip = keyof typeof manifest.clips;
export const MASCOT_CLIPS = Object.keys(manifest.clips) as MascotClip[];
export const MASCOT = manifest;

/** Seconds one pass of the clip takes (a loop repeats it). */
export function mascotSeconds(clip: MascotClip): number {
  const c = manifest.clips[clip];
  return c.timeline.reduce((s, [, t]) => s + t, 0) / manifest.fps;
}

export interface MascotOptions {
  /** px (the strips are 160 px frames: crisp up to 80 px on a 2× screen) */
  size?: number;
  className?: string;
  /** accessible name; without it the chick is decorative (aria-hidden) */
  title?: string;
}

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

/** `<span class="mascot" data-clip="…">` — a loop keeps playing; a one-shot plays once from when it is inserted. */
export function mascotHtml(clip: MascotClip, { size = 48, className, title }: MascotOptions = {}): string {
  const a11y = title ? ` role="img" aria-label="${esc(title)}"` : ` aria-hidden="true"`;
  return `<span class="mascot${className ? " " + esc(className) : ""}" data-clip="${clip}" style="--mascot-size:${size}px"${a11y}></span>`;
}

/** Plays a clip again on an existing element (or switches it to another clip). */
export function playMascot(el: HTMLElement, clip?: MascotClip): void {
  if (clip) el.dataset.clip = clip;
  el.style.animation = "none";
  void el.offsetWidth;
  el.style.animation = "";
}
