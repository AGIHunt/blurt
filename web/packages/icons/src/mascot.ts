/* @blurt/icons/mascot — Peep, the brand character (a 3D clay chick), for the web apps (Windows / Linux overlays, the
   Tauri app), played as the Mac app plays it (skills/blurt/recorder/macos/Sources/BlurtApp/Icons/Mascot.swift,
   BlurtCore/Peep.swift). Nothing here draws Peep: the frames are the release package's renders, cut into sprite sheets
   by assets/brand/import_peep.py (../peep/<tier>-<state>.webp, peep.json). The states: idle (a breath and a blink),
   hello, listening, talking (the beak; with `level`, it follows the voice), thinking (the eye looks round), done (a peep
   and a hop), error (a shake, a droop).

     mascotHtml('talking', { size: 24, level: true })     plain pages (the island); setMascotLevel(() => 0…1)
     <Mascot clip="hello" then="idle" size={108} />       React ("@blurt/icons")

   The sheets come in tiers, each imported by the app that shows it, so an app ships only its own: `@blurt/icons/peep-s`
   (Peep ≤ 32 px: the island) and `@blurt/icons/peep-l` (the app window, ≤ 108 px). The sheets are 2-D grids (10
   columns), so one small shared ticker (requestAnimationFrame at the clips' 30 fps; it stops when nothing moves) moves
   each `.mascot`'s background over its sheet; `mascot.css` lays it out. Reduced motion: the clip's still frame. The
   1A round chick's clip names still work: happy → done, hatching → done, wobble → thinking, peck → done. */
import manifest from "../peep/peep.json";

export const PEEP_STATES = ["idle", "hello", "listening", "talking", "thinking", "done", "error"] as const;
export type PeepState = (typeof PEEP_STATES)[number];
/** The 1A chick's clip names, mapped to the Peep state the Mac plays in their place. */
export const LEGACY_CLIPS = { happy: "done", hatching: "done", wobble: "thinking", peck: "done" } as const satisfies Record<string, PeepState>;
export type MascotClip = PeepState | keyof typeof LEGACY_CLIPS;
export const MASCOT_CLIPS = [...PEEP_STATES, ...Object.keys(LEGACY_CLIPS)] as MascotClip[];
export const MASCOT = manifest;

export type PeepTier = keyof typeof manifest.tiers;
interface Clip {
  frames: number;
  fps: number;
  open?: number[];
  still?: number;
}
type Tier = { square: number; cell: number; bleed: number; clips: Partial<Record<PeepState, Clip>> };
const TIERS = manifest.tiers as Record<PeepTier, Tier>;
const COLS = manifest.cols;

export function peepState(clip: string | undefined): PeepState {
  if (!clip) return "idle";
  if ((PEEP_STATES as readonly string[]).includes(clip)) return clip as PeepState;
  return (LEGACY_CLIPS as Record<string, PeepState>)[clip] ?? "idle";
}

export const loops = (s: PeepState) => s === "idle" || s === "listening" || s === "talking" || s === "thinking";

function anyClip(s: PeepState): Clip | undefined {
  for (const t of Object.values(TIERS)) if (t.clips[s]) return t.clips[s];
  return undefined;
}

/** Seconds one pass of the clip takes (a loop repeats it). */
export function mascotSeconds(clip: MascotClip): number {
  const c = anyClip(peepState(clip));
  return c ? c.frames / c.fps : 1;
}

// ------------------------------------------------------------------ the numbers (BlurtCore/Peep.swift PeepPlayback)

/** The frame at `t` seconds from the clip's start: a loop wraps, a one-shot holds its last frame. */
export function frameAt(t: number, c: Clip, loop: boolean): number {
  const i = Math.floor(Math.max(0, t) * c.fps);
  return loop ? i % c.frames : Math.min(i, c.frames - 1);
}

/** The moment a clip shows with reduced motion: the state in one frame — the eye up while thinking, the beak open
 *  while talking, the happy eye after the peep, the droop. */
export function stillFrame(s: PeepState, c: Clip): number {
  if (s === "done" && c.still !== undefined) return Math.min(c.frames - 1, c.still);
  const f = { idle: 0, hello: 0, listening: 0.4, talking: 0.29, thinking: 0.22, done: 0.62, error: 0.62 }[s];
  return Math.min(c.frames - 1, Math.floor(f * c.frames));
}

/** Talking driven by a voice level (0…1): the frame whose beak opening is nearest the level on the clip's range, with
 *  a soft knee (quiet speech moves the beak a little, shouting does not pin it open). */
export function talkingFrame(level: number, c: Clip): number {
  const open = c.open ?? [];
  if (open.length !== c.frames) return 0;
  const lo = Math.min(...open), hi = Math.max(...open);
  if (hi <= lo) return 0;
  const target = lo + (hi - lo) * Math.pow(Math.min(1, Math.max(0, level)), 0.7);
  let best = 0, gap = Infinity;
  open.forEach((o, i) => {
    if (Math.abs(o - target) < gap) {
      best = i;
      gap = Math.abs(o - target);
    }
  });
  return best;
}

/** A level that opens fast and closes a little slower, as a beak would (per tick of `dt` seconds). */
export function smoothLevel(current: number, level: number, dt: number): number {
  const rate = level > current ? 18 : 7;
  return current + (level - current) * Math.min(1, rate * Math.max(0, dt));
}

/** The tier for Peep `px` device pixels across: the smallest registered one that is at least ~as large (the browser
 *  only ever shrinks a little), else the largest; one that has the clip. */
export function pickTier(px: number, s: PeepState, have: readonly PeepTier[] = registered()): PeepTier | undefined {
  const usable = have.filter((t) => TIERS[t].clips[s]).sort((a, b) => TIERS[a].square - TIERS[b].square);
  return usable.find((t) => TIERS[t].square >= px * 0.9) ?? usable[usable.length - 1];
}

// ------------------------------------------------------------------ the sheets an app ships

const sheets: Partial<Record<PeepTier, Partial<Record<PeepState, string>>>> = {};
const registered = () => Object.keys(sheets) as PeepTier[];

/** Called by `@blurt/icons/peep-s` / `peep-l` with the URLs of their sheets (the bundler's). */
export function registerPeepSheets(tier: PeepTier, urls: Partial<Record<PeepState, string>>): void {
  sheets[tier] = { ...sheets[tier], ...urls };
  kick();
}

// ------------------------------------------------------------------ markup

export interface MascotOptions {
  /** px: Peep's square (body and beak at rest); the hop and the shake reach a little past it */
  size?: number;
  className?: string;
  /** accessible name; without it Peep is decorative (aria-hidden) */
  title?: string;
  /** after a one-shot (hello, done, error): go on with this clip */
  then?: MascotClip;
  /** talking follows the voice level (setMascotLevel) instead of its own beats */
  level?: boolean;
}

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

/** `<span class="mascot" data-clip="…">` — a loop keeps playing; a one-shot plays once from when it is shown. */
export function mascotHtml(clip: MascotClip, { size = 48, className, title, then, level }: MascotOptions = {}): string {
  const a11y = title ? ` role="img" aria-label="${esc(title)}"` : ` aria-hidden="true"`;
  const extra = (then ? ` data-then="${peepState(then)}"` : "") + (level ? " data-level" : "");
  return `<span class="mascot${className ? " " + esc(className) : ""}" data-clip="${peepState(clip)}"${extra} style="--mascot-size:${size}px"${a11y}></span>`;
}

/** Plays a clip again on an existing element (or switches it to another clip). */
export function playMascot(el: HTMLElement, clip?: MascotClip): void {
  if (clip) el.dataset.clip = peepState(clip);
  runs.delete(el);
  kick();
}

let levelOf: () => number = () => 0;
/** Where talking Peeps (`level: true`) read the voice level, 0…1, each frame. */
export function setMascotLevel(fn: () => number): void {
  levelOf = fn;
}

// ------------------------------------------------------------------ the ticker

interface Run {
  asked: string;
  clip: PeepState;
  start: number;
  hold: number;
  last: number;
  smoothed: number;
  ended: boolean;
  px: number;
  shown: string;
  sheet: string;
}

const runs = new WeakMap<HTMLElement, Run>();
let raf = 0;
let lastTick = 0;
// the system setting, or a page's own switch (<html data-reduce-motion="1">: the overlays' ?reduce-motion)
const reduced = () =>
  (typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches) || document.documentElement.dataset.reduceMotion === "1";

function kick(): void {
  if (raf || typeof document === "undefined" || typeof requestAnimationFrame !== "function") return;
  raf = requestAnimationFrame(tick);
}

function tick(now: number): void {
  raf = 0;
  // the clips' own rate: 30 fps (a 60 / 120 Hz screen draws each frame twice or four times — no work in between)
  if (now - lastTick < 1000 / 30 - 2) {
    raf = requestAnimationFrame(tick);
    return;
  }
  lastTick = now;
  let moving = false;
  for (const el of document.querySelectorAll<HTMLElement>(".mascot[data-clip]")) moving = step(el, now / 1000) || moving;
  if (moving) raf = requestAnimationFrame(tick);
}

function begin(el: HTMLElement, clip: PeepState, now: number): Run {
  const r: Run = { asked: el.dataset.clip ?? "", clip, start: now, hold: 0, last: now, smoothed: 0, ended: false, px: 0, shown: "", sheet: "" };
  runs.set(el, r);
  return r;
}

/** Shows `el`'s frame for now; true while it still moves. */
function step(el: HTMLElement, now: number): boolean {
  let r = runs.get(el);
  if (!r || r.asked !== el.dataset.clip) r = begin(el, peepState(el.dataset.clip), now);
  if (!r.px) {
    const w = el.getBoundingClientRect().width;
    if (!w) return true; // not laid out yet (or hidden): look again next frame
    r.px = w * (window.devicePixelRatio || 1);
  }
  const tier = pickTier(r.px, r.clip);
  const c = tier && TIERS[tier].clips[r.clip];
  if (!tier || !c) return false;
  const dt = now - r.last;
  r.last = now;
  let frame: number;
  let moving = true;
  if (reduced()) {
    // the still moment; a one-shot's `then` follows at once (its still)
    const then = el.dataset.then;
    if (!loops(r.clip) && then && !r.ended) {
      r.ended = true;
      el.dispatchEvent(new CustomEvent("mascotend", { bubbles: false }));
      r.clip = peepState(then);
      return step(el, now);
    }
    if (!loops(r.clip) && !r.ended) {
      r.ended = true;
      el.dispatchEvent(new CustomEvent("mascotend", { bubbles: false }));
    }
    frame = stillFrame(r.clip, c);
    moving = false;
  } else if (r.clip === "talking" && el.hasAttribute("data-level")) {
    r.smoothed = smoothLevel(r.smoothed, levelOf(), dt);
    frame = talkingFrame(r.smoothed, c);
  } else if (now < r.hold) {
    frame = 0;
  } else {
    const t = now - r.start;
    const dur = c.frames / c.fps;
    if (!loops(r.clip) && t >= dur) {
      // a one-shot rests on its last frame (error on its droop), or goes on with `then`
      if (!r.ended) {
        r.ended = true;
        el.dispatchEvent(new CustomEvent("mascotend", { bubbles: false }));
      }
      const then = el.dataset.then;
      if (then && peepState(then) !== r.clip) {
        r.clip = peepState(then);
        r.start = now;
        return step(el, now);
      }
      frame = r.clip === "error" ? stillFrame("error", c) : c.frames - 1;
      moving = false;
    } else if (r.clip === "idle" && t >= dur) {
      // one breath and blink done: rest on the first frame 0–2 s (so two Peeps never blink together), then again
      r.start = now + 2 * Math.random();
      r.hold = r.start;
      frame = 0;
    } else {
      frame = frameAt(t, c, loops(r.clip));
    }
  }
  draw(el, r, tier, frame);
  return moving;
}

function draw(el: HTMLElement, r: Run, tier: PeepTier, frame: number): void {
  const T = TIERS[tier];
  const c = T.clips[r.clip]!;
  const url = sheets[tier]?.[r.clip];
  if (!url) return;
  const rows = Math.ceil(c.frames / COLS);
  const key = `${tier}-${r.clip}`;
  if (r.sheet !== key) {
    r.sheet = key;
    el.style.setProperty("--peep-sheet", `url("${url}")`);
    el.style.setProperty("--peep-size", `${COLS * 100}% ${rows * 100}%`);
    el.style.setProperty("--peep-bleed", String(T.bleed));
  }
  const col = frame % COLS, row = Math.floor(frame / COLS);
  // a background larger than its box: p % puts the picture's p % on the box's p %, so column c of n is at c / (n − 1)
  const pos = `${COLS > 1 ? ((100 * col) / (COLS - 1)).toFixed(4) : 0}% ${rows > 1 ? ((100 * row) / (rows - 1)).toFixed(4) : 0}%`;
  if (pos !== r.shown) {
    r.shown = pos;
    el.style.setProperty("--peep-pos", pos);
  }
}

if (typeof document !== "undefined" && typeof MutationObserver === "function") {
  // a Peep inserted by markup (innerHTML) or a clip switched on one starts the ticker
  new MutationObserver(kick).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ["data-clip"] });
  if (typeof matchMedia === "function") matchMedia("(prefers-reduced-motion: reduce)").addEventListener?.("change", kick);
  // a screen with another pixel ratio picks its tier again
  window.addEventListener?.("resize", () => {
    for (const el of document.querySelectorAll<HTMLElement>(".mascot[data-clip]")) {
      const r = runs.get(el);
      if (r) r.px = 0;
    }
    kick();
  });
  kick();
}
