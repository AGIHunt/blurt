import React, { createContext, useContext } from "react";
import { Easing, interpolate, spring, useCurrentFrame } from "remotion";
import { loadFont as loadInter } from "@remotion/google-fonts/Inter";
import { loadFont as loadMono } from "@remotion/google-fonts/JetBrainsMono";
import tl from "./timeline.json";

export const TL = tl;
export const FPS = tl.fps;
export const cue = (k: keyof typeof tl.cues) => tl.cues[k];
export const scene = (k: keyof typeof tl.scenes) => tl.scenes[k] as [number, number];

const inter = loadInter("normal", { weights: ["400", "500", "600", "700", "800", "900"], subsets: ["latin"] });
const mono = loadMono("normal", { weights: ["400", "500", "700"], subsets: ["latin"] });
export const SANS = `${inter.fontFamily}, "PingFang SC", "Hiragino Sans GB", sans-serif`;
export const CJK = `"PingFang SC", "Hiragino Sans GB", ${inter.fontFamily}, sans-serif`;
export const MONO = `${mono.fontFamily}, Menlo, monospace`;

export const C = {
  bg: "#08080B",
  panel: "#131318",
  panel2: "#1B1B22",
  line: "rgba(255,255,255,0.08)",
  text: "#F5F5F7",
  muted: "#A1A1AA",
  dim: "#71717A",
  yellow: "#FFC93C",
  red: "#FF5A36",
  issue: "#FF5F57",
  idea: "#FFC93C",
  note: "#4ADE80",
  task: "#60A5FA",
};

// ------------------------------------------------------------------ time
const SceneStart = createContext(0);
export const SceneTime: React.FC<{ start: number; children: React.ReactNode }> = ({ start, children }) => (
  <SceneStart.Provider value={start}>{children}</SceneStart.Provider>
);
/** Absolute time in seconds (timeline.json is in absolute seconds). */
export const useT = () => useContext(SceneStart) + useCurrentFrame() / FPS;

export const EXPO = Easing.bezier(0.16, 1, 0.3, 1);
export const INOUT = Easing.bezier(0.65, 0, 0.35, 1);

/** Clamped interpolate over absolute seconds. */
export const lin = (t: number, a: number, b: number, from = 0, to = 1, ease = EXPO) =>
  interpolate(t, [a, b], [from, to], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: ease });

/** Spring progress starting at absolute second t0 (0 before). */
export const spr = (t: number, t0: number, cfg: { damping?: number; stiffness?: number; mass?: number } = {}) =>
  t < t0 ? 0 : spring({ frame: (t - t0) * FPS, fps: FPS, config: { damping: 14, stiffness: 160, mass: 0.8, ...cfg } });

/** Short "punch" 0→1→0 pulse. */
export const pulse = (t: number, t0: number, d = 0.25) => (t < t0 || t > t0 + d ? 0 : Math.sin(((t - t0) / d) * Math.PI));

export const typed = (s: string, t: number, t0: number, cps = 28) => s.slice(0, Math.max(0, Math.floor((t - t0) * cps)));

/** Chicken calls from timeline.json (drive the peck / crow animations). */
export const chickenAt = (kind: string) => (TL as unknown as { chicken: [number, string, number, number][] }).chicken.filter((c) => c[1] === kind).map((c) => c[0]);
/** 0..1 forward-peck amount at time t for the given peck times. */
export const peckAmt = (t: number, times: number[]) => Math.max(0, ...times.map((p) => (t >= p - 0.04 && t < p + 0.12 ? Math.sin(((t - p + 0.04) / 0.16) * Math.PI) : 0)));
