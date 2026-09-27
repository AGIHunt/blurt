import React from "react";
import { AbsoluteFill, Img, staticFile, random } from "remotion";
import { C, SANS, MONO, CJK, lin, spr, useT, TL, EXPO } from "./lib";

// ------------------------------------------------------------------ background, grain, vignette
export const Backdrop: React.FC<{ glow?: number; hue?: "warm" | "cool" }> = ({ glow = 1, hue = "warm" }) => {
  const t = useT();
  const a = hue === "warm" ? C.yellow : "#7C83FF";
  const b = hue === "warm" ? C.red : "#38BDF8";
  const x1 = 30 + 12 * Math.sin(t * 0.21);
  const y1 = 35 + 10 * Math.cos(t * 0.17);
  const x2 = 72 + 10 * Math.cos(t * 0.19);
  const y2 = 70 + 12 * Math.sin(t * 0.23);
  return (
    <AbsoluteFill style={{ background: C.bg }}>
      <AbsoluteFill
        style={{
          opacity: 0.55 * glow,
          background: `radial-gradient(40% 45% at ${x1}% ${y1}%, ${a}33, transparent 70%), radial-gradient(45% 50% at ${x2}% ${y2}%, ${b}2a, transparent 70%)`,
        }}
      />
      <AbsoluteFill
        style={{
          opacity: 0.35,
          backgroundImage: `linear-gradient(${C.line} 1px, transparent 1px), linear-gradient(90deg, ${C.line} 1px, transparent 1px)`,
          backgroundSize: "80px 80px",
          maskImage: "radial-gradient(60% 60% at 50% 50%, black, transparent)",
        }}
      />
    </AbsoluteFill>
  );
};

export const Grain: React.FC = () => {
  const t = useT();
  const seed = Math.floor(t * 30) % 8;
  return (
    <AbsoluteFill style={{ pointerEvents: "none" }}>
      <svg width="100%" height="100%" style={{ position: "absolute", opacity: 0.07, mixBlendMode: "overlay" }}>
        <filter id={`g${seed}`}>
          <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed={seed} stitchTiles="stitch" />
        </filter>
        <rect width="100%" height="100%" filter={`url(#g${seed})`} />
      </svg>
      <AbsoluteFill style={{ background: "radial-gradient(120% 90% at 50% 50%, transparent 55%, rgba(0,0,0,0.55))" }} />
    </AbsoluteFill>
  );
};

// ------------------------------------------------------------------ captions (bilingual)
export const Captions: React.FC = () => {
  const t = useT();
  const cur = (TL.captions as unknown as [number, number, string, string][]).find(([a, b]) => t >= a - 0.05 && t <= b + 0.15);
  if (!cur) return null;
  const [a, b, en, zh] = cur as [number, number, string, string];
  const o = Math.min(lin(t, a - 0.05, a + 0.15), 1 - lin(t, b, b + 0.15));
  const y = (1 - lin(t, a - 0.05, a + 0.25)) * 10;
  return (
    <AbsoluteFill style={{ justifyContent: "flex-end", alignItems: "center", paddingBottom: 54, pointerEvents: "none" }}>
      <div
        style={{
          opacity: o,
          transform: `translateY(${y}px)`,
          padding: "12px 28px 14px",
          borderRadius: 16,
          background: "rgba(8,8,11,0.62)",
          backdropFilter: "blur(14px)",
          boxShadow: "0 10px 40px rgba(0,0,0,0.35)",
          textAlign: "center",
          maxWidth: 1500,
        }}
      >
        <div style={{ fontFamily: SANS, fontSize: 34, fontWeight: 600, color: C.text, letterSpacing: -0.2, lineHeight: 1.25 }}>{en}</div>
        <div style={{ fontFamily: CJK, fontSize: 27, fontWeight: 500, color: "#D4D4D8", marginTop: 4, lineHeight: 1.3 }}>{zh}</div>
      </div>
    </AbsoluteFill>
  );
};

// ------------------------------------------------------------------ small pieces
export const Logo: React.FC<{ size: number; style?: React.CSSProperties }> = ({ size, style }) => (
  <Img src={staticFile("logo.png")} style={{ width: size, height: size, ...style }} />
);

export const Kbd: React.FC<{ k: string; pressed?: number; size?: number; accent?: string }> = ({ k, pressed = 0, size = 84, accent }) => (
  <div
    style={{
      minWidth: size,
      height: size,
      padding: "0 18px",
      borderRadius: size * 0.22,
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      fontFamily: SANS,
      fontWeight: 700,
      fontSize: size * 0.42,
      color: pressed > 0.5 && accent ? "#111" : C.text,
      background: pressed > 0.5 && accent ? accent : `linear-gradient(180deg, #2A2A33, #1C1C22)`,
      border: `1px solid rgba(255,255,255,${0.12 + pressed * 0.2})`,
      boxShadow: `0 ${6 - pressed * 5}px 0 #0B0B0E, 0 ${10 - pressed * 6}px 24px rgba(0,0,0,0.5)`,
      transform: `translateY(${pressed * 5}px)`,
    }}
  >
    {k}
  </div>
);

export const KIND: Record<string, { color: string; label: string; icon: string }> = {
  issue: { color: C.issue, label: "Issue", icon: "🐞" },
  idea: { color: C.idea, label: "Idea", icon: "💡" },
  task: { color: C.task, label: "To-do", icon: "✅" },
  note: { color: C.note, label: "Note", icon: "📝" },
};

export const Chip: React.FC<{ kind: string; size?: number }> = ({ kind, size = 20 }) => {
  const k = KIND[kind];
  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: size * 0.3,
        fontFamily: SANS,
        fontWeight: 700,
        fontSize: size,
        color: k.color,
        background: `${k.color}1f`,
        border: `1px solid ${k.color}55`,
        padding: `${size * 0.2}px ${size * 0.55}px`,
        borderRadius: 999,
        letterSpacing: 0.3,
        textTransform: "uppercase",
      }}
    >
      <span style={{ fontSize: size * 0.9 }}>{k.icon}</span>
      {k.label}
    </span>
  );
};

export const Cursor: React.FC<{ x: number; y: number; down?: number; scale?: number }> = ({ x, y, down = 0, scale = 1 }) => (
  <div style={{ position: "absolute", left: x, top: y, transform: `scale(${scale * (1 - down * 0.12)})`, transformOrigin: "0 0", zIndex: 50 }}>
    <svg width="34" height="40" viewBox="0 0 34 40" style={{ filter: "drop-shadow(0 3px 6px rgba(0,0,0,0.45))" }}>
      <path d="M3 2 L3 31 L10.5 24 L15.5 36 L20.5 34 L15.6 22.5 L26 22.5 Z" fill="#111" stroke="#fff" strokeWidth="2.4" strokeLinejoin="round" />
    </svg>
  </div>
);

export const Ripple: React.FC<{ x: number; y: number; t0: number; color?: string }> = ({ x, y, t0, color = C.yellow }) => {
  const t = useT();
  if (t < t0 || t > t0 + 0.6) return null;
  const p = lin(t, t0, t0 + 0.6);
  return (
    <div
      style={{
        position: "absolute",
        left: x - 40,
        top: y - 40,
        width: 80,
        height: 80,
        borderRadius: 999,
        border: `4px solid ${color}`,
        transform: `scale(${0.2 + p * 1.2})`,
        opacity: 1 - p,
        zIndex: 49,
      }}
    />
  );
};

/** Animated rectangle outline that "draws" itself. */
export const DrawBox: React.FC<{ x: number; y: number; w: number; h: number; t0: number; color?: string; dur?: number; width?: number; radius?: number }> = ({
  x, y, w, h, t0, color = C.red, dur = 0.45, width = 5, radius = 10,
}) => {
  const t = useT();
  const p = lin(t, t0, t0 + dur, 0, 1);
  if (p <= 0) return null;
  const per = 2 * (w + h);
  return (
    <svg style={{ position: "absolute", left: x - 10, top: y - 10, overflow: "visible", zIndex: 40 }} width={w + 20} height={h + 20}>
      <rect
        x={10} y={10} width={w} height={h} rx={radius}
        fill="none" stroke={color} strokeWidth={width}
        strokeDasharray={per} strokeDashoffset={per * (1 - p)}
        style={{ filter: `drop-shadow(0 0 10px ${color}aa)` }}
      />
    </svg>
  );
};

// ------------------------------------------------------------------ mac window + the fictional app ("Orbit")
export const APP = {
  w: 1280,
  h: 800,
  save: { x: 718, y: 640, w: 150, h: 46 },
  cancel: { x: 596, y: 634, w: 110, h: 46 },
  empty: { x: 900, y: 150, w: 340, h: 380 },
};

export const MacWindow: React.FC<{ title?: string; children: React.ReactNode; w?: number; h?: number; style?: React.CSSProperties }> = ({
  title = "Orbit", children, w = APP.w, h = APP.h, style,
}) => (
  <div
    style={{
      width: w,
      height: h + 40,
      borderRadius: 14,
      overflow: "hidden",
      background: "#0E0E12",
      border: "1px solid rgba(255,255,255,0.12)",
      boxShadow: "0 40px 120px rgba(0,0,0,0.6), 0 0 0 1px rgba(0,0,0,0.6)",
      ...style,
    }}
  >
    <div style={{ height: 40, display: "flex", alignItems: "center", gap: 8, padding: "0 16px", background: "#18181D", borderBottom: "1px solid rgba(255,255,255,0.06)" }}>
      {["#FF5F57", "#FEBC2E", "#28C840"].map((c) => (
        <div key={c} style={{ width: 13, height: 13, borderRadius: 99, background: c }} />
      ))}
      <div style={{ flex: 1, textAlign: "center", fontFamily: SANS, fontSize: 15, color: C.muted, marginRight: 60 }}>{title}</div>
    </div>
    <div style={{ position: "relative", width: w, height: h }}>{children}</div>
  </div>
);

const Row: React.FC<{ label: string; value: string; toggle?: boolean; on?: boolean }> = ({ label, value, toggle, on }) => (
  <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "18px 0", borderBottom: "1px solid rgba(255,255,255,0.06)" }}>
    <div>
      <div style={{ fontSize: 17, color: C.text, fontWeight: 600 }}>{label}</div>
      <div style={{ fontSize: 14, color: C.dim, marginTop: 3 }}>{value}</div>
    </div>
    {toggle ? (
      <div style={{ width: 46, height: 26, borderRadius: 99, background: on ? "#6366F1" : "#2A2A33", position: "relative" }}>
        <div style={{ position: "absolute", top: 3, left: on ? 23 : 3, width: 20, height: 20, borderRadius: 99, background: "#fff" }} />
      </div>
    ) : (
      <div style={{ width: 220, height: 38, borderRadius: 8, background: "#1B1B22", border: "1px solid rgba(255,255,255,0.08)", fontSize: 15, color: C.muted, display: "flex", alignItems: "center", padding: "0 12px" }}>
        {value}
      </div>
    )}
  </div>
);

/** A fictional SaaS settings page, with a slightly-low Save button and a lifeless empty state. */
export const FakeApp: React.FC<{ overlay?: React.ReactNode; variant?: number }> = ({ overlay, variant = 0 }) => {
  const accent = ["#6366F1", "#10B981", "#F59E0B", "#EC4899", "#06B6D4"][variant % 5];
  return (
    <div style={{ position: "absolute", inset: 0, fontFamily: SANS, background: "#0B0B0F", display: "flex" }}>
      <div style={{ width: 220, background: "#101015", borderRight: "1px solid rgba(255,255,255,0.06)", padding: "26px 18px" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, fontWeight: 800, fontSize: 21, color: C.text }}>
          <div style={{ width: 28, height: 28, borderRadius: 8, background: `conic-gradient(${accent}, #22D3EE, ${accent})` }} />
          Orbit
        </div>
        {["Home", "Projects", "Reports", "Settings"].map((n, i) => (
          <div
            key={n}
            style={{
              marginTop: i === 0 ? 34 : 6,
              padding: "11px 12px",
              borderRadius: 9,
              fontSize: 16,
              color: i === 3 ? C.text : C.muted,
              background: i === 3 ? "rgba(255,255,255,0.07)" : "transparent",
              fontWeight: i === 3 ? 600 : 500,
            }}
          >
            {n}
          </div>
        ))}
      </div>
      <div style={{ flex: 1, position: "relative" }}>
        <div style={{ position: "absolute", left: 40, top: 36, fontSize: 30, fontWeight: 800, color: C.text, letterSpacing: -0.5 }}>Settings</div>
        <div style={{ position: "absolute", left: 40, top: 86, display: "flex", gap: 22, fontSize: 15, color: C.muted }}>
          <span style={{ color: C.text, borderBottom: `2px solid ${accent}`, paddingBottom: 6 }}>Workspace</span>
          <span>Members</span>
          <span>Billing</span>
        </div>
        <div style={{ position: "absolute", left: 40, top: 140, width: 600, height: 560, borderRadius: 14, background: "#121217", border: "1px solid rgba(255,255,255,0.07)", padding: "8px 28px" }}>
          <Row label="Workspace name" value="Acme Studio" />
          <Row label="Default language" value="English" />
          <Row label="Weekly digest" value="Email a summary every Monday" toggle on />
          <Row label="Public share links" value="Anyone with the link can view" toggle />
          <Row label="Time zone" value="UTC−08:00" />
        </div>
        {/* bottom action bar (Save is 6px low on purpose) */}
        <div
          style={{ position: "absolute", left: APP.cancel.x - 220, top: APP.cancel.y, width: APP.cancel.w, height: APP.cancel.h, borderRadius: 10, border: "1px solid rgba(255,255,255,0.14)", color: C.muted, fontSize: 16, fontWeight: 600, display: "flex", alignItems: "center", justifyContent: "center" }}
        >
          Cancel
        </div>
        <div
          style={{ position: "absolute", left: APP.save.x - 220, top: APP.save.y, width: APP.save.w, height: APP.save.h, borderRadius: 10, background: accent, color: "#fff", fontSize: 16, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center" }}
        >
          Save changes
        </div>
        <div
          style={{ position: "absolute", left: APP.empty.x - 220, top: APP.empty.y, width: APP.empty.w, height: APP.empty.h, borderRadius: 14, border: "2px dashed rgba(255,255,255,0.12)", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", color: C.dim }}
        >
          <div style={{ width: 54, height: 54, borderRadius: 12, background: "#1B1B22", marginBottom: 16 }} />
          <div style={{ fontSize: 18, fontWeight: 600, color: C.muted }}>No reports yet</div>
          <div style={{ fontSize: 14, marginTop: 6 }}>Reports will appear here.</div>
        </div>
        <div style={{ position: "absolute", left: APP.empty.x - 220, top: 560, width: APP.empty.w, height: 140, borderRadius: 14, background: "#121217", border: "1px solid rgba(255,255,255,0.07)", padding: 20 }}>
          <div style={{ fontSize: 14, color: C.dim }}>Storage</div>
          <div style={{ marginTop: 14, height: 8, borderRadius: 9, background: "#23232B" }}>
            <div style={{ width: "62%", height: 8, borderRadius: 9, background: accent }} />
          </div>
          <div style={{ fontSize: 14, color: C.muted, marginTop: 12 }}>6.2 GB of 10 GB</div>
        </div>
      </div>
      <div style={{ position: "absolute", inset: 0 }}>{overlay}</div>
    </div>
  );
};

/** A tiny abstract "screen" thumbnail. */
export const MiniScreen: React.FC<{ i: number; w: number; h: number; bug?: number }> = ({ i, w, h, bug = 0 }) => {
  const hue = (i * 47) % 360;
  const r = (k: number) => random(`m${i}-${k}`);
  return (
    <div style={{ width: w, height: h, borderRadius: 8, background: "#121217", border: "1px solid rgba(255,255,255,0.08)", position: "relative", overflow: "hidden" }}>
      <div style={{ position: "absolute", left: 0, top: 0, bottom: 0, width: w * 0.2, background: "#0E0E13" }} />
      <div style={{ position: "absolute", left: w * 0.27, top: h * 0.12, width: w * (0.3 + r(1) * 0.3), height: h * 0.1, borderRadius: 3, background: `hsl(${hue} 70% 62%)` }} />
      {[0, 1, 2].map((k) => (
        <div key={k} style={{ position: "absolute", left: w * 0.27, top: h * (0.34 + k * 0.17), width: w * (0.35 + r(k + 3) * 0.35), height: h * 0.07, borderRadius: 3, background: "rgba(255,255,255,0.12)" }} />
      ))}
      <div style={{ position: "absolute", right: w * 0.07, bottom: h * 0.1, width: w * 0.2, height: h * 0.12, borderRadius: 3, background: `hsl(${hue} 70% 55%)` }} />
      {bug > 0 && (
        <div
          style={{
            position: "absolute",
            left: w * (0.3 + r(9) * 0.4),
            top: h * (0.25 + r(10) * 0.4),
            width: 26,
            height: 26,
            borderRadius: 99,
            background: C.issue,
            transform: `scale(${bug})`,
            boxShadow: `0 0 0 6px ${C.issue}44`,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: 15,
            fontWeight: 900,
            color: "#fff",
            fontFamily: SANS,
          }}
        >
          !
        </div>
      )}
    </div>
  );
};

export const Headline: React.FC<{ children: React.ReactNode; size?: number; style?: React.CSSProperties }> = ({ children, size = 84, style }) => (
  <div style={{ fontFamily: SANS, fontWeight: 800, fontSize: size, color: C.text, letterSpacing: -size * 0.03, lineHeight: 1.05, ...style }}>{children}</div>
);

/** Word-by-word spring reveal. */
export const Words: React.FC<{ text: string; t0: number; gap?: number; size?: number; color?: string; accent?: Record<string, string> }> = ({
  text, t0, gap = 0.06, size = 84, color = C.text, accent = {},
}) => {
  const t = useT();
  return (
    <span>
      {text.split(" ").map((w, i) => {
        const p = spr(t, t0 + i * gap, { damping: 16, stiffness: 190 });
        return (
          <span
            key={i}
            style={{
              display: "inline-block",
              marginRight: size * 0.25,
              opacity: Math.min(1, p * 1.4),
              transform: `translateY(${(1 - p) * size * 0.5}px)`,
              filter: `blur(${(1 - p) * 8}px)`,
              color: accent[w] ?? color,
            }}
          >
            {w}
          </span>
        );
      })}
    </span>
  );
};

export { MONO, EXPO };
