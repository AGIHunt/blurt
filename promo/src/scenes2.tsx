import React from "react";
import { AbsoluteFill, Img, staticFile } from "remotion";
import { C, SANS, MONO, cue, lin, spr, pulse, typed, useT, INOUT, chickenAt, peckAmt } from "./lib";
import { APP, Backdrop, Chip, Cursor, DrawBox, FakeApp, Headline, Kbd, KIND, Logo, MacWindow, Ripple, Words } from "./ui";

// ------------------------------------------------------------------ shared: a crop of the app (the "frame" blurt picked)
const Frame: React.FC<{ w: number; h: number; boxT0?: number; ring?: number }> = ({ w, h, boxT0 = -1, ring = 0 }) => {
  // crop app region x 300..1260, y 330..730 (960×400) into w×h
  const s = w / 960;
  return (
    <div style={{ width: w, height: h, overflow: "hidden", borderRadius: 14, position: "relative", border: "1px solid rgba(255,255,255,0.12)" }}>
      <div style={{ position: "absolute", left: -300 * s, top: -330 * s, width: APP.w, height: APP.h, transform: `scale(${s})`, transformOrigin: "0 0" }}>
        <FakeApp
          overlay={
            <>
              {boxT0 > 0 && <DrawBox x={APP.cancel.x - 14} y={APP.cancel.y - 14} w={APP.save.x + APP.save.w - APP.cancel.x + 28} h={APP.save.h + 34} t0={boxT0} dur={0.5} width={6} />}
              {ring > 0 && (
                <div
                  style={{
                    position: "absolute",
                    left: APP.save.x + APP.save.w / 2 - 20,
                    top: APP.save.y + APP.save.h / 2 - 20,
                    width: 40,
                    height: 40,
                    borderRadius: 99,
                    border: `4px solid ${C.yellow}`,
                    transform: `scale(${ring})`,
                    boxShadow: `0 0 20px ${C.yellow}`,
                  }}
                />
              )}
            </>
          }
        />
      </div>
    </div>
  );
};

// ================================================================== 5. record: living screencast
const WS = 0.92, WX = (1920 - APP.w * WS) / 2, WY = 104;
const toDesk = (ax: number, ay: number) => [WX + ax * WS, WY + (40 + ay) * WS] as const;
const WW = APP.w * WS, WH = (APP.h + 40) * WS;

type KF = [number, number, number];
const path = (t: number, kfs: KF[]) => {
  if (t <= kfs[0][0]) return [kfs[0][1], kfs[0][2]];
  for (let i = 1; i < kfs.length; i++) {
    const [t1, x1, y1] = kfs[i];
    const [t0, x0, y0] = kfs[i - 1];
    if (t <= t1) {
      const p = lin(t, t0, t1, 0, 1, INOUT);
      return [x0 + (x1 - x0) * p, y0 + (y1 - y0) * p];
    }
  }
  const l = kfs[kfs.length - 1];
  return [l[1], l[2]];
};

export const Record: React.FC = () => {
  const t = useT();
  const key = cue("record.key"), overlay = cue("record.overlay"), drag = cue("record.drag"), dragEnd = cue("record.dragEnd");
  const count = cue("record.count"), rec = cue("record.rec"), point = cue("record.point"), click = cue("record.click");
  const [sx, sy] = toDesk(APP.save.x + APP.save.w / 2, APP.save.y + APP.save.h / 2);
  const [ex, ey] = toDesk(APP.empty.x + APP.empty.w / 2, APP.empty.y + APP.empty.h / 2);
  const r0 = [WX - 10, WY - 10], r1 = [WX + WW + 10, WY + WH + 10];
  const [cx, cy] = path(t, [
    [32.35, 1100, 620], [overlay, 1100, 620], [drag, r0[0], r0[1]], [dragEnd, r1[0], r1[1]], [rec + 0.05, r1[0], r1[1]],
    [36.7, sx + 10, sy + 6], [point + 0.1, sx + 10, sy + 6], [point + 0.25, sx - 30, sy + 14], [point + 0.4, sx + 40, sy - 4], [point + 0.5, sx + 6, sy + 8],
    [click - 0.02, ex, ey], [37.9, ex, ey], [38.3, ex - 90, ey + 60], [38.7, ex + 60, ey - 40], [39.2, ex + 10, ey + 20],
  ]);
  const down = (t > drag && t < dragEnd ? 1 : 0) || pulse(t, point, 0.16) || pulse(t, click, 0.16);
  // camera: screen-studio style auto zoom
  const z1 = lin(t, 36.0, 36.6, 0, 1, INOUT), zPan = lin(t, 37.15, 37.6, 0, 1, INOUT), zOut = lin(t, 39.3, 39.95, 0, 1, INOUT);
  const s = 1 + 0.55 * z1 * (1 - zOut);
  const fx0 = 960 + (sx - 960) * z1, fy0 = 540 + (sy - 540) * z1;
  const fx = fx0 + (ex - sx) * zPan * z1, fy = fy0 + (ey - sy) * zPan * z1;
  const fxx = fx + (960 - fx) * zOut, fyy = fy + (540 - fy) * zOut;
  const selP = t < drag ? 0 : 1;
  const selW = lin(t, drag, dragEnd, 0, 1, INOUT);
  const selRect = { x: r0[0], y: r0[1], w: (r1[0] - r0[0]) * selW, h: (r1[1] - r0[1]) * selW };
  const dim = t > overlay && t < rec ? lin(t, overlay, overlay + 0.2) * (1 - lin(t, rec - 0.1, rec)) : 0;
  const recOn = t >= rec;
  const hudP = spr(t, rec, { damping: 16, stiffness: 220 });
  const secs = Math.max(0, t - rec);
  const bubbles: [number, string][] = [
    [cue("record.b1"), "This Save button sits lower than Cancel…"],
    [cue("record.b2"), "and this empty state feels dead — maybe an illustration?"],
    [cue("record.b3"), "wait, no — a tip card instead."],
  ];
  return (
    <AbsoluteFill style={{ background: "#000" }}>
      <AbsoluteFill style={{ transformOrigin: "0 0", transform: `translate(${960 - fxx * s}px, ${540 - fyy * s}px) scale(${s})` }}>
        {/* wallpaper */}
        <AbsoluteFill style={{ background: "radial-gradient(80% 90% at 20% 10%, #3B2A6B, transparent 60%), radial-gradient(70% 80% at 90% 90%, #7A3B2A, transparent 60%), #0D0B14" }} />
        {/* menu bar */}
        <div style={{ position: "absolute", left: 0, top: 0, width: 1920, height: 36, background: "rgba(20,20,26,0.55)", backdropFilter: "blur(20px)", display: "flex", alignItems: "center", padding: "0 20px", gap: 26, fontFamily: SANS, fontSize: 16, color: "#EDEDF2" }}>
          <b>Orbit</b>
          <span>File</span>
          <span>Edit</span>
          <span>View</span>
          <div style={{ flex: 1 }} />
          <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "2px 8px", borderRadius: 6, background: recOn ? "rgba(255,95,87,0.25)" : `rgba(255,255,255,${pulse(t, key + 0.3, 0.5) * 0.25})` }}>
            <Img src={staticFile("menuicon.png")} style={{ height: 20, filter: "invert(1)" }} />
            {recOn && <span style={{ color: "#FF6B63", fontWeight: 700, fontFamily: MONO }}>● {`0:${String(Math.floor(secs)).padStart(2, "0")}`}</span>}
          </div>
          <span>Tue 10:24</span>
        </div>
        {/* app window */}
        <div style={{ position: "absolute", left: WX, top: WY, transform: `scale(${WS})`, transformOrigin: "0 0" }}>
          <MacWindow>
            <FakeApp />
          </MacWindow>
        </div>
        {/* picker overlay */}
        {dim > 0 && (
          <>
            {selP > 0 ? (
              <div
                style={{
                  position: "absolute",
                  left: selRect.x,
                  top: selRect.y,
                  width: selRect.w,
                  height: selRect.h,
                  boxShadow: `0 0 0 4000px rgba(0,0,0,${0.55 * dim})`,
                  border: `3px dashed ${C.yellow}`,
                  borderRadius: 6,
                }}
              />
            ) : (
              <AbsoluteFill style={{ background: `rgba(0,0,0,${0.55 * dim})` }} />
            )}
            <div style={{ position: "absolute", left: 0, right: 0, top: 58, textAlign: "center", opacity: dim }}>
              <span style={{ fontFamily: SANS, fontSize: 20, color: "#fff", background: "rgba(0,0,0,0.6)", padding: "10px 20px", borderRadius: 999 }}>
                Drag to select an area · click a window · F for full screen
              </span>
            </div>
          </>
        )}
        {/* countdown */}
        {t > count && t < rec && (
          <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
            {(() => {
              const i = Math.min(2, Math.floor((t - count) / 0.25));
              const p = lin(t, count + i * 0.25, count + i * 0.25 + 0.25);
              return (
                <div style={{ fontFamily: SANS, fontWeight: 900, fontSize: 260, color: "#fff", opacity: 1 - p * 0.6, transform: `scale(${1.3 - p * 0.4})`, textShadow: "0 10px 60px rgba(0,0,0,0.6)" }}>
                  {3 - i}
                </div>
              );
            })()}
          </AbsoluteFill>
        )}
        {/* recording frame + HUD */}
        {recOn && (
          <>
            <div style={{ position: "absolute", left: r0[0], top: r0[1], width: r1[0] - r0[0], height: r1[1] - r0[1], border: "3px solid rgba(255,95,87,0.9)", borderRadius: 6, opacity: 0.4 + 0.6 * Math.abs(Math.sin(secs * 2.2)) }} />
            <div
              style={{
                position: "absolute",
                left: 960 - 190,
                top: 48,
                width: 380,
                height: 50,
                borderRadius: 999,
                background: "rgba(22,22,28,0.92)",
                border: "1px solid rgba(255,255,255,0.14)",
                display: "flex",
                alignItems: "center",
                gap: 14,
                padding: "0 16px",
                fontFamily: MONO,
                fontSize: 17,
                color: C.text,
                transform: `scale(${hudP})`,
                boxShadow: "0 10px 30px rgba(0,0,0,0.5)",
              }}
            >
              <span style={{ color: "#FF5F57" }}>●</span>
              {`00:${String(Math.floor(secs)).padStart(2, "0")}`}
              <div style={{ display: "flex", gap: 3, alignItems: "flex-end", height: 20 }}>
                {[0, 1, 2, 3, 4].map((i) => (
                  <div key={i} style={{ width: 4, height: 5 + 15 * Math.abs(Math.sin(t * 9 + i)), background: "#4ADE80", borderRadius: 2 }} />
                ))}
              </div>
              <div style={{ flex: 1 }} />
              <span style={{ color: C.muted }}>⏸</span>
              <span style={{ color: C.muted }}>↺</span>
              <span style={{ background: "#FF5F57", color: "#fff", borderRadius: 999, padding: "4px 12px", fontFamily: SANS, fontWeight: 700, fontSize: 15 }}>Done</span>
            </div>
          </>
        )}
        <Ripple x={sx} y={sy} t0={point} />
        <Ripple x={ex} y={ey} t0={click} />
        <Cursor x={cx} y={cy} down={down} />
      </AbsoluteFill>
      {/* screen-space: hotkey + live transcript */}
      {t > key - 0.15 && t < overlay + 0.1 && (
        <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 18, flexDirection: "row", opacity: 1 - lin(t, overlay - 0.2, overlay + 0.1) }}>
          {["⌥", "⇧", "R"].map((k, i) => {
            const p = spr(t, key - 0.15 + i * 0.05, { damping: 14 });
            const pr = t > key + i * 0.14 && t < 33.5 ? 1 : 0;
            return (
              <div key={k} style={{ transform: `scale(${p * 1.25})` }}>
                <Kbd k={k} size={110} pressed={pr} accent={C.yellow} />
              </div>
            );
          })}
        </AbsoluteFill>
      )}
      <div style={{ position: "absolute", right: 60, top: 560, width: 560, display: "flex", flexDirection: "column", gap: 12, alignItems: "flex-end" }}>
        {bubbles.map(([t0, s], i) => {
          const p = spr(t, t0, { damping: 16, stiffness: 220 });
          if (p <= 0) return null;
          return (
            <div
              key={i}
              style={{
                display: "flex",
                gap: 12,
                alignItems: "center",
                padding: "12px 18px",
                borderRadius: 18,
                background: "rgba(18,18,24,0.88)",
                border: "1px solid rgba(255,255,255,0.12)",
                boxShadow: "0 20px 50px rgba(0,0,0,0.45)",
                fontFamily: SANS,
                fontSize: 22,
                color: C.text,
                opacity: Math.min(1, p * 1.5) * (1 - lin(t, 39.6, 40.0)),
                transform: `translateY(${(1 - p) * 30}px) scale(${0.9 + p * 0.1})`,
              }}
            >
              <span style={{ fontSize: 22 }}>🎙️</span>
              {typed(s, t, t0, 45)}
            </div>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};

// ================================================================== 6. items: the agent does the tedious part
const LINES = [
  ["00:04", "this Save button sits lower than Cancel"],
  ["00:07", "and this empty state feels dead…"],
  ["00:09", "maybe an illustration — wait, no, a tip card"],
  ["00:12", "ask design for the copy"],
  ["00:15", "settings feels crowded on my laptop"],
];
const CARDS: [string, string, string][] = [
  ["issue", "Save button sits 6px below Cancel", "Settings · actions bar"],
  ["idea", "Swap the empty state for a tip card", "Reports · first-run"],
  ["task", "Ask design for empty-state copy", "Owner: design"],
  ["note", "Settings feels crowded on a 13″ laptop", "Layout · density"],
];

export const Items: React.FC = () => {
  const t = useT();
  const z = cue("items.zoomout"), fr = cue("items.frame"), box = cue("items.box"), code = cue("items.code");
  const cardT = [cue("items.card1"), cue("items.card2"), cue("items.card3"), cue("items.card4")];
  const tileP = spr(t, z, { damping: 18, stiffness: 120 });
  const focus = lin(t, fr - 0.1, fr + 0.45, 0, 1, INOUT);
  return (
    <AbsoluteFill>
      <Backdrop glow={1} />
      {/* left: recording + transcript */}
      <div style={{ position: "absolute", left: 80, top: 130, width: 540, opacity: 1 - focus * 0.65 }}>
        <div style={{ transform: `scale(${2.6 - tileP * 1.6}) translate(${(1 - tileP) * 120}px, ${(1 - tileP) * 60}px)`, transformOrigin: "0 0" }}>
          <div style={{ width: 540, height: 338, borderRadius: 14, overflow: "hidden", position: "relative", border: "1px solid rgba(255,255,255,0.14)" }}>
            <div style={{ position: "absolute", transform: `scale(${540 / APP.w})`, transformOrigin: "0 0", width: APP.w, height: APP.h }}>
              <FakeApp />
            </div>
            <div style={{ position: "absolute", left: 0, bottom: 0, height: 5, width: `${lin(t, z, 48, 10, 100, (x) => x)}%`, background: C.yellow }} />
            <div style={{ position: "absolute", left: 12, top: 10, fontFamily: MONO, fontSize: 15, color: "#fff", background: "rgba(0,0,0,0.6)", padding: "3px 8px", borderRadius: 6 }}>recording.mp4 · 0:18</div>
          </div>
        </div>
        <div style={{ marginTop: 26, fontFamily: MONO, fontSize: 18, lineHeight: 1.75, color: C.muted, opacity: tileP }}>
          {LINES.map(([ts, s], i) => {
            const p = lin(t, z + 0.4 + i * 0.25, z + 0.7 + i * 0.25);
            return (
              <div key={i} style={{ opacity: p, transform: `translateX(${(1 - p) * -20}px)` }}>
                <span style={{ color: C.dim }}>[{ts}]</span> {s}
              </div>
            );
          })}
        </div>
      </div>
      {/* middle: the chicken at work */}
      <div style={{ position: "absolute", left: 660, top: 380, opacity: tileP * (1 - focus), transformOrigin: "45% 85%", transform: `rotate(${Math.sin(t * 6) * 3 + peckAmt(t, chickenAt("peck")) * 26}deg) scale(${1 + pulse(t, cardT[0], 0.3) * 0.1 + pulse(t, cardT[2], 0.3) * 0.1})` }}>
        <Logo size={170} />
        <div style={{ position: "absolute", left: 170, top: 70, width: 90, height: 4, background: `repeating-linear-gradient(90deg, ${C.yellow} 0 12px, transparent 12px 22px)`, backgroundPositionX: t * 120 }} />
      </div>
      {/* right: item cards */}
      <div style={{ position: "absolute", left: 950, top: 150, width: 890 }}>
        {CARDS.map(([k, title, sub], i) => {
          const p = spr(t, cardT[i], { damping: 14, stiffness: 200 });
          const isMain = i === 0;
          const hide = isMain ? 0 : focus;
          return (
            <div
              key={i}
              style={{
                height: 128,
                marginBottom: 20,
                borderRadius: 18,
                background: "#15151B",
                border: `1px solid ${KIND[k].color}44`,
                boxShadow: `0 20px 50px rgba(0,0,0,0.4), inset 4px 0 0 ${KIND[k].color}`,
                padding: "22px 28px",
                display: "flex",
                flexDirection: "column",
                justifyContent: "center",
                gap: 10,
                opacity: Math.min(1, p * 1.5) * (1 - hide),
                transform: `translateX(${(1 - p) * 200}px) scale(${0.85 + p * 0.15})`,
              }}
            >
              <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
                <Chip kind={k} size={16} />
                <span style={{ fontFamily: SANS, fontSize: 16, color: C.dim }}>{sub}</span>
              </div>
              <div style={{ fontFamily: SANS, fontSize: 31, fontWeight: 700, color: C.text, letterSpacing: -0.5 }}>{title}</div>
            </div>
          );
        })}
      </div>
      {/* focus: the issue, with its evidence */}
      {focus > 0 && (
        <div
          style={{
            position: "absolute",
            left: 330,
            top: 110,
            width: 1260,
            padding: 34,
            borderRadius: 24,
            background: "#121217",
            border: `1px solid ${C.issue}55`,
            boxShadow: "0 50px 140px rgba(0,0,0,0.7)",
            opacity: focus,
            transform: `scale(${0.85 + focus * 0.15}) translateY(${(1 - focus) * 60}px)`,
          }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
            <Chip kind="issue" size={18} />
            <span style={{ fontFamily: SANS, fontSize: 34, fontWeight: 800, color: C.text, letterSpacing: -0.6 }}>Save button sits 6px below Cancel</span>
          </div>
          <div style={{ display: "flex", gap: 28, marginTop: 24 }}>
            <div style={{ position: "relative" }}>
              <Frame w={720} h={300} boxT0={box} ring={spr(t, box + 0.4, { damping: 10 })} />
              <div style={{ position: "absolute", left: 12, top: 12, fontFamily: MONO, fontSize: 15, color: "#fff", background: "rgba(0,0,0,0.65)", padding: "3px 8px", borderRadius: 6 }}>frame @ 00:04.2</div>
              {pulse(t, fr, 0.2) > 0 && <div style={{ position: "absolute", inset: 0, background: "#fff", opacity: pulse(t, fr, 0.2) * 0.8, borderRadius: 14 }} />}
            </div>
            <div style={{ flex: 1, fontFamily: SANS, fontSize: 20, color: C.muted, lineHeight: 1.5 }}>
              <div style={{ color: C.dim, fontSize: 14, fontWeight: 700, letterSpacing: 1 }}>ACTUAL</div>
              <div style={{ color: C.text }}>“Save changes” renders 6px lower than “Cancel”.</div>
              <div style={{ color: C.dim, fontSize: 14, fontWeight: 700, letterSpacing: 1, marginTop: 14 }}>EXPECTED</div>
              <div style={{ color: C.text }}>Both buttons share one baseline.</div>
              <div style={{ color: C.dim, fontSize: 14, fontWeight: 700, letterSpacing: 1, marginTop: 14 }}>QUOTE</div>
              <div style={{ fontStyle: "italic" }}>“this Save button sits lower than Cancel…”</div>
            </div>
          </div>
          <div style={{ marginTop: 22, borderRadius: 14, background: "#0B0B0F", border: "1px solid rgba(255,255,255,0.08)", padding: "16px 20px", fontFamily: MONO, fontSize: 19, opacity: lin(t, code - 0.1, code + 0.2) }}>
            <div style={{ color: C.yellow, marginBottom: 10 }}>{typed("src/settings/SaveBar.tsx:42", t, code, 40)}</div>
            {[
              [41, `  <Button variant="ghost">Cancel</Button>`],
              [42, `  <Button style={{ marginTop: 6 }}>Save changes</Button>`],
            ].map(([n, s]) => (
              <div key={n as number} style={{ color: n === 42 ? C.text : C.dim, background: n === 42 ? `${C.issue}22` : "none", borderRadius: 6, padding: "2px 8px", opacity: lin(t, code + 0.5, code + 0.8) }}>
                <span style={{ color: C.dim, marginRight: 18 }}>{n}</span>
                {s}
              </div>
            ))}
          </div>
        </div>
      )}
    </AbsoluteFill>
  );
};

// ================================================================== 7. review
const REVIEW = [
  { k: "issue", title: "Save button sits 6px below Cancel", a: "“Save changes” renders 6px lower than “Cancel”.", b: "One shared baseline." },
  { k: "idea", title: "Swap the empty state for a tip card", a: "The empty Reports page feels dead.", b: "A tip that gets people to their first report." },
  { k: "task", title: "Ask design for empty-state copy", a: "Need copy + illustration for the tip card.", b: "Owner: design · this week" },
  { k: "note", title: "Settings feels crowded on a 13″ laptop", a: "Rows and actions compete for attention.", b: "Revisit density later." },
];

export const Review: React.FC = () => {
  const t = useT();
  const inn = cue("review.in"), keep = cue("review.keep"), drop = cue("review.drop"), next = cue("review.next");
  const winP = spr(t, inn, { damping: 18, stiffness: 140 });
  const idx = t < keep ? 0 : t < drop ? 1 : t < next ? 2 : 3;
  const events = [keep, drop, next];
  const ev = idx > 0 ? events[idx - 1] : -10;
  const since = t - ev;
  const inP = lin(t, ev, ev + 0.35);
  const outKind = idx === 2 ? "drop" : "up";
  const cur = REVIEW[idx];
  const prev = idx > 0 ? REVIEW[idx - 1] : null;
  const card = (it: (typeof REVIEW)[0], style: React.CSSProperties, stamp?: React.ReactNode) => (
    <div style={{ position: "absolute", inset: 0, display: "flex", gap: 34, padding: 34, ...style }}>
      <div style={{ position: "relative" }}>
        {it.k === "issue" ? <Frame w={820} h={470} boxT0={inn + 0.4} /> : (
          <div style={{ width: 820, height: 470, borderRadius: 14, overflow: "hidden", position: "relative", border: "1px solid rgba(255,255,255,0.12)" }}>
            <div style={{ position: "absolute", left: -600 * 1.25, top: -120 * 1.25, width: APP.w, height: APP.h, transform: "scale(1.25)", transformOrigin: "0 0" }}>
              <FakeApp />
            </div>
          </div>
        )}
        {stamp}
      </div>
      <div style={{ flex: 1, fontFamily: SANS }}>
        <Chip kind={it.k} size={17} />
        <div style={{ fontSize: 36, fontWeight: 800, color: C.text, marginTop: 18, letterSpacing: -0.6, lineHeight: 1.15 }}>{it.title}</div>
        <div style={{ fontSize: 14, fontWeight: 700, letterSpacing: 1, color: C.dim, marginTop: 26 }}>{it.k === "idea" ? "WHY" : "DETAILS"}</div>
        <div style={{ fontSize: 22, color: C.muted, marginTop: 6, lineHeight: 1.45 }}>{it.a}</div>
        <div style={{ fontSize: 22, color: C.text, marginTop: 14, lineHeight: 1.45 }}>{it.b}</div>
      </div>
    </div>
  );
  const keys: [string, string, number, string][] = [
    ["A", "Keep", keep, "#4ADE80"],
    ["X", "Drop", drop, C.issue],
    ["J", "Next", next, C.yellow],
  ];
  return (
    <AbsoluteFill>
      <Backdrop glow={0.9} />
      <AbsoluteFill style={{ alignItems: "center", paddingTop: 70 }}>
        <div style={{ width: 1520, height: 720, borderRadius: 18, overflow: "hidden", background: "#0E0E12", border: "1px solid rgba(255,255,255,0.12)", boxShadow: "0 50px 140px rgba(0,0,0,0.6)", transform: `perspective(2200px) rotateX(${(1 - winP) * 20}deg) scale(${0.9 + winP * 0.1})`, opacity: winP }}>
          <div style={{ height: 48, background: "#18181D", display: "flex", alignItems: "center", gap: 8, padding: "0 18px", borderBottom: "1px solid rgba(255,255,255,0.06)" }}>
            {["#FF5F57", "#FEBC2E", "#28C840"].map((c) => (
              <div key={c} style={{ width: 13, height: 13, borderRadius: 99, background: c }} />
            ))}
            <div style={{ marginLeft: 20, flex: 1, height: 30, borderRadius: 8, background: "#0E0E12", fontFamily: SANS, fontSize: 15, color: C.muted, display: "flex", alignItems: "center", padding: "0 12px" }}>localhost:4817 · blurt review</div>
          </div>
          <div style={{ height: 64, display: "flex", alignItems: "center", gap: 14, padding: "0 34px", borderBottom: "1px solid rgba(255,255,255,0.06)", fontFamily: SANS }}>
            <Logo size={36} style={{ transformOrigin: "45% 85%", transform: `rotate(${peckAmt(t, chickenAt("peck")) * 30}deg) scale(${1 + peckAmt(t, chickenAt("peck")) * 0.35})` }} />
            <span style={{ fontSize: 20, fontWeight: 700, color: C.text }}>Settings walkthrough</span>
            <div style={{ flex: 1 }} />
            <span style={{ fontFamily: MONO, fontSize: 18, color: C.muted }}>{idx + 1} / 4</span>
            <div style={{ display: "flex", gap: 6 }}>
              {[0, 1, 2, 3].map((i) => (
                <div key={i} style={{ width: 34, height: 6, borderRadius: 9, background: i < idx ? C.yellow : i === idx ? "#fff" : "#2A2A33" }} />
              ))}
            </div>
          </div>
          <div style={{ position: "relative", height: 720 - 48 - 64, overflow: "hidden" }}>
            {prev && since < 0.4 &&
              card(prev, {
                transform: outKind === "drop" ? `translateX(${inP * 900}px) rotate(${inP * 12}deg)` : `translateY(${-inP * 620}px)`,
                opacity: 1 - inP * 0.6,
              },
              <div style={{ position: "absolute", left: 250, top: 180, fontFamily: SANS, fontWeight: 900, fontSize: 70, padding: "4px 26px", borderRadius: 14, transform: "rotate(-10deg)", color: outKind === "drop" ? C.issue : "#4ADE80", border: `8px solid ${outKind === "drop" ? C.issue : "#4ADE80"}` }}>
                {outKind === "drop" ? "DROPPED" : "KEPT"}
              </div>)}
            {card(cur, { transform: idx > 0 ? `translateY(${(1 - inP) * 620}px)` : "none" })}
          </div>
        </div>
        <div style={{ display: "flex", gap: 46, marginTop: 30 }}>
          {keys.map(([k, label, t0, col]) => {
            const pr = t > t0 && t < t0 + 0.22 ? 1 : 0;
            return (
              <div key={k} style={{ display: "flex", alignItems: "center", gap: 14, fontFamily: SANS, fontSize: 26, fontWeight: 700, color: pr ? col : C.muted }}>
                <Kbd k={k} size={64} pressed={pr} accent={col} />
                {label}
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

// ================================================================== 8. peak: 2 days → 30 minutes
export const Peak: React.FC = () => {
  const t = useT();
  const drop = cue("peak.drop"), slash = cue("peak.slash"), thirty = cue("peak.thirty");
  const a = spr(t, drop, { damping: 11, stiffness: 230 });
  const sl = lin(t, slash, slash + 0.22);
  const b = spr(t, thirty, { damping: 9, stiffness: 260 });
  const shake = t > thirty && t < thirty + 0.35 ? Math.sin(t * 95) * 14 * (1 - (t - thirty) / 0.35) : 0;
  const flash = Math.max(1 - lin(t, drop, drop + 0.2), t >= thirty ? 1 - lin(t, thirty, thirty + 0.2) : 0);
  return (
    <AbsoluteFill style={{ transform: `translate(${shake}px, ${shake * 0.4}px)` }}>
      <Backdrop glow={1.6} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <div style={{ position: "relative", transform: `scale(${(2 - a) * (1 - b * 0.45)}) translateY(${-b * 200}px)`, opacity: Math.min(1, a * 1.5) * (1 - b * 0.35) }}>
          <Headline size={280} style={{ color: sl > 0 ? C.dim : C.text, letterSpacing: -12 }}>
            2 days
          </Headline>
          <div style={{ position: "absolute", left: -20, top: "52%", height: 22, width: `${sl * 108}%`, background: C.issue, borderRadius: 12, transform: "rotate(-6deg)", boxShadow: `0 0 30px ${C.issue}` }} />
        </div>
        {b > 0 && (
          <div style={{ position: "absolute", top: 470, transform: `scale(${2.4 - b * 1.4})`, opacity: Math.min(1, b * 2) }}>
            <Headline size={330} style={{ color: C.yellow, letterSpacing: -14, textShadow: `0 0 80px ${C.yellow}66` }}>
              30 min
            </Headline>
          </div>
        )}
      </AbsoluteFill>
      {(() => {
        const c = chickenAt("cluck1").find((x) => x > 57 && x < 58) ?? 57.5;
        const p = spr(t, c - 0.15, { damping: 10, stiffness: 240 });
        const pk = peckAmt(t, [c, c + 0.18]);
        return p > 0 ? (
          <div style={{ position: "absolute", left: 1640, top: 760, transform: `scale(${p}) rotate(${-10 - pk * 14}deg)`, transformOrigin: "40% 90%" }}>
            <Logo size={180} />
            <div style={{ position: "absolute", left: -10, top: -70, whiteSpace: "nowrap", fontFamily: SANS, fontWeight: 900, fontSize: 40, color: "#111", background: C.yellow, padding: "6px 18px", borderRadius: 18, transform: `scale(${spr(t, c, { damping: 11 })}) rotate(-8deg)` }}>bok bok!</div>
          </div>
        ) : null;
      })()}
      <AbsoluteFill style={{ background: "#fff", opacity: flash * 0.75 }} />
    </AbsoluteFill>
  );
};

// ================================================================== 9. export / fix
const DEST: [string, string, string, string][] = [
  ["export.lark", "Lark / Feishu Base", "+4 rows", "▦"],
  ["export.github", "GitHub Issues", "#128 opened", "◉"],
  ["export.md", "Markdown · CSV", "items.md", "¶"],
];
export const Export: React.FC = () => {
  const t = useT();
  const say = cue("export.say");
  const out = lin(t, say - 0.1, say + 0.4, 0, 1, INOUT);
  return (
    <AbsoluteFill>
      <Backdrop glow={1} />
      <AbsoluteFill style={{ transform: `translateX(${-out * 700}px)`, opacity: 1 - out }}>
        {/* stack */}
        <div style={{ position: "absolute", left: 200, top: 300 }}>
          {[3, 2, 1, 0].map((i) => {
            const [k, title] = CARDS[i];
            return (
              <div key={i} style={{ position: "absolute", left: i * 16, top: i * 16, width: 560, height: 150, borderRadius: 18, background: "#15151B", border: `1px solid ${KIND[k].color}44`, boxShadow: `0 20px 60px rgba(0,0,0,0.5), inset 4px 0 0 ${KIND[k].color}`, padding: "28px 30px", fontFamily: SANS }}>
                <Chip kind={k} size={15} />
                <div style={{ fontSize: 27, fontWeight: 700, color: C.text, marginTop: 14 }}>{title}</div>
              </div>
            );
          })}
        </div>
        {DEST.map(([ck, name, res, icon], i) => {
          const t0 = cue(ck as never);
          const p = spr(t, 57.93 + i * 0.12, { damping: 16 });
          const fly = lin(t, t0, t0 + 0.4, 0, 1, INOUT);
          const landed = t > t0 + 0.38;
          const y = 190 + i * 230;
          return (
            <React.Fragment key={ck}>
              <div
                style={{
                  position: "absolute",
                  left: 1150,
                  top: y,
                  width: 620,
                  height: 180,
                  borderRadius: 22,
                  background: landed ? "#17171E" : "#121217",
                  border: `2px solid ${landed ? C.yellow : "rgba(255,255,255,0.1)"}`,
                  boxShadow: landed ? `0 0 ${40 * (1 - lin(t, t0 + 0.38, t0 + 1))}px ${C.yellow}88` : "none",
                  display: "flex",
                  alignItems: "center",
                  gap: 28,
                  padding: "0 36px",
                  opacity: p,
                  transform: `translateX(${(1 - p) * 120}px) scale(${1 + pulse(t, t0 + 0.38, 0.25) * 0.05})`,
                  fontFamily: SANS,
                }}
              >
                <div style={{ width: 90, height: 90, borderRadius: 20, background: "#23232B", fontSize: 54, display: "flex", alignItems: "center", justifyContent: "center", color: C.text }}>{icon}</div>
                <div>
                  <div style={{ fontSize: 32, fontWeight: 800, color: C.text }}>{name}</div>
                  <div style={{ fontSize: 24, color: landed ? "#4ADE80" : C.dim, marginTop: 6, fontFamily: MONO }}>{landed ? `✓ ${res}` : "waiting…"}</div>
                </div>
              </div>
              {fly > 0 && fly < 1 && (
                <div
                  style={{
                    position: "absolute",
                    left: 250 + (1150 - 250) * fly,
                    top: 330 + (y + 20 - 330) * fly - Math.sin(fly * Math.PI) * 160,
                    width: 300 - fly * 120,
                    height: 80 - fly * 30,
                    borderRadius: 12,
                    background: "#1F1F27",
                    border: `2px solid ${C.yellow}`,
                    transform: `rotate(${fly * 12}deg)`,
                    boxShadow: `0 0 30px ${C.yellow}66`,
                  }}
                />
              )}
            </React.Fragment>
          );
        })}
      </AbsoluteFill>
      {/* terminal: just say "fix them" */}
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: out, transform: `translateX(${(1 - out) * 700}px)` }}>
        <div style={{ width: 1280, height: 520, borderRadius: 18, background: "#0B0B0F", border: "1px solid rgba(255,255,255,0.14)", boxShadow: "0 50px 140px rgba(0,0,0,0.6)", overflow: "hidden", marginTop: -80 }}>
          <div style={{ height: 44, background: "#18181D", display: "flex", alignItems: "center", gap: 8, padding: "0 16px" }}>
            {["#FF5F57", "#FEBC2E", "#28C840"].map((c) => (
              <div key={c} style={{ width: 13, height: 13, borderRadius: 99, background: c }} />
            ))}
            <div style={{ flex: 1, textAlign: "center", fontFamily: SANS, fontSize: 15, color: C.muted, marginRight: 60 }}>~/orbit — agent</div>
          </div>
          <div style={{ padding: "34px 40px", fontFamily: MONO, fontSize: 30, lineHeight: 1.7, color: C.text }}>
            <div>
              <span style={{ color: C.yellow }}>›</span> {typed("fix them", t, say + 0.3, 11)}
              {t < cue("export.fix") && <span style={{ opacity: Math.floor(t * 3) % 2 ? 1 : 0 }}>▍</span>}
            </div>
            {[
              [cue("export.fix") + 0.15, <span style={{ color: C.muted }}>● reading items.json — 1 issue · 1 idea · 1 to-do</span>],
              [cue("export.ok1"), <span><span style={{ color: "#4ADE80" }}>✓</span> SaveBar.tsx:42 — removed stray marginTop</span>],
              [cue("export.ok2"), <span><span style={{ color: "#4ADE80" }}>✓</span> Reports/Empty.tsx — tip card added</span>],
            ].map(([t0, el], i) => (
              <div key={i} style={{ opacity: lin(t, t0 as number, (t0 as number) + 0.15), transform: `translateY(${(1 - lin(t, t0 as number, (t0 as number) + 0.2)) * 12}px)` }}>
                {el as React.ReactNode}
              </div>
            ))}
          </div>
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

// ================================================================== 10. beyond bugs, and teams
const TILES: [string, string, string, string][] = [
  ["beyond.bugs", "🐞", "Bugs", "Polish what your AI shipped"],
  ["beyond.ideas", "💡", "Ideas", "Grab inspiration while you browse"],
  ["beyond.notes", "📝", "Notes", "Research & walkthroughs, with proof"],
  ["beyond.todos", "✅", "To-dos", "Action items, straight to your list"],
];
export const Beyond: React.FC = () => {
  const t = useT();
  const team = cue("beyond.team"), local = cue("beyond.local");
  const up = lin(t, team - 0.1, team + 0.5, 0, 1, INOUT);
  const people: [string, string, string][] = [["D", "Design", "#EC4899"], ["P", "PM", "#8B5CF6"], ["S", "Support", "#06B6D4"], ["Y", "You", C.yellow]];
  return (
    <AbsoluteFill>
      <Backdrop glow={1.1} />
      <div style={{ position: "absolute", left: 0, right: 0, top: 150 - up * 90, display: "flex", justifyContent: "center", gap: 30, transform: `scale(${1 - up * 0.3})` }}>
        {TILES.map(([ck, icon, name, sub], i) => {
          const p = spr(t, cue(ck as never), { damping: 13, stiffness: 200 });
          return (
            <div key={ck} style={{ width: 400, height: 330, borderRadius: 26, background: "#131318", border: "1px solid rgba(255,255,255,0.1)", padding: 34, fontFamily: SANS, opacity: Math.min(1, p * 1.5), transform: `translateY(${(1 - p) * 80}px) scale(${0.8 + p * 0.2})`, boxShadow: "0 30px 80px rgba(0,0,0,0.45)" }}>
              <div style={{ fontSize: 86 }}>{icon}</div>
              <div style={{ fontSize: 50, fontWeight: 800, color: C.text, marginTop: 20, letterSpacing: -1 }}>{name}</div>
              <div style={{ fontSize: 23, color: C.muted, marginTop: 10, lineHeight: 1.35 }}>{sub}</div>
            </div>
          );
        })}
      </div>
      {up > 0 && (
        <div style={{ position: "absolute", left: 0, right: 0, top: 470, display: "flex", justifyContent: "center", alignItems: "center", gap: 70, opacity: up }}>
          {people.map(([l, n, col], i) => {
            const p = spr(t, team + 0.25 + i * 0.18, { damping: 12 });
            const fly = lin(t, team + 0.5 + i * 0.18, team + 1.1 + i * 0.18, 0, 1, INOUT);
            return (
              <div key={n} style={{ textAlign: "center", fontFamily: SANS, transform: `scale(${p})`, position: "relative" }}>
                <div style={{ width: 120, height: 120, borderRadius: 99, background: col, color: "#111", fontSize: 52, fontWeight: 900, display: "flex", alignItems: "center", justifyContent: "center", margin: "0 auto" }}>{l}</div>
                <div style={{ fontSize: 24, color: C.muted, marginTop: 12 }}>{n}</div>
                {fly > 0 && fly < 1 && (
                  <div style={{ position: "absolute", left: 30, top: -20 - fly * 60, width: 64, height: 42, borderRadius: 8, background: "#23232B", border: `2px solid ${col}`, opacity: 1 - fly, fontSize: 18, lineHeight: "38px" }}>▶</div>
                )}
              </div>
            );
          })}
          <div style={{ fontSize: 60, color: C.dim }}>→</div>
          <div style={{ width: 260, height: 170, borderRadius: 22, background: "#15151B", border: `2px solid ${C.yellow}88`, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 6, fontFamily: SANS, transform: `scale(${spr(t, team + 0.2, { damping: 14 })})` }}>
            <Logo size={80} />
            <div style={{ fontSize: 22, color: C.text, fontWeight: 700 }}>one workspace</div>
          </div>
        </div>
      )}
      {t > local - 0.1 && (
        <div style={{ position: "absolute", left: 0, right: 0, top: 750, display: "flex", justifyContent: "center" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 18, padding: "18px 34px", borderRadius: 999, background: "#14141A", border: "1px solid rgba(74,222,128,0.4)", fontFamily: SANS, fontSize: 28, color: C.text, transform: `scale(${spr(t, local, { damping: 13 })})` }}>
            <span style={{ fontSize: 32 }}>🔒</span>
            Speech-to-text runs on your machine
            <span style={{ color: C.dim, fontSize: 22 }}>SenseVoice · Whisper · or your own key</span>
          </div>
        </div>
      )}
    </AbsoluteFill>
  );
};

// ================================================================== 11. CTA
export const CTA: React.FC = () => {
  const t = useT();
  const drop = cue("cta.drop"), name = cue("cta.name"), oss = cue("cta.oss"), cmd = cue("cta.cmd"), done = cue("cta.cmdDone");
  const lp = spr(t, drop, { damping: 12, stiffness: 150 });
  const flash = 1 - lin(t, drop, drop + 0.25);
  const end = lin(t, 80.9, 81.75);
  const command = "npx skills add AGIHunt/blurt";
  const nod = peckAmt(t, chickenAt("cluck1").concat(chickenAt("cluck3")).filter((x) => x > 78));
  return (
    <AbsoluteFill>
      <Backdrop glow={1.3} />
      <AbsoluteFill style={{ alignItems: "center", paddingTop: 120, transform: `scale(${1 + (t - drop) * 0.008})` }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <Logo size={230} style={{ transformOrigin: "40% 85%", transform: `scale(${lp * (1 + nod * 0.08)}) rotate(${(1 - lp) * 20 + nod * 18}deg)` }} />
          <div style={{ fontFamily: SANS, fontWeight: 900, fontSize: 170, color: C.text, letterSpacing: -8, opacity: lin(t, drop + 0.1, drop + 0.4), transform: `translateX(${(1 - lin(t, drop + 0.1, drop + 0.5)) * -40}px)` }}>
            blurt
          </div>
          <div style={{ fontFamily: `"PingFang SC", sans-serif`, fontWeight: 700, fontSize: 56, color: C.yellow, marginLeft: 26, marginTop: 40, opacity: lin(t, name, name + 0.4) }}>口喷鸡</div>
        </div>
        <div style={{ fontFamily: SANS, fontWeight: 700, fontSize: 48, color: C.muted, letterSpacing: -1, marginTop: 10, opacity: lin(t, drop + 0.4, drop + 0.8) }}>
          Show it. Say it. <span style={{ color: C.yellow }}>Your AI gets it.</span>
        </div>
        <div style={{ marginTop: 56, display: "flex", alignItems: "center", gap: 18, padding: "22px 36px", borderRadius: 18, background: "#0B0B0F", border: `2px solid ${t > done ? C.yellow : "rgba(255,255,255,0.14)"}`, fontFamily: MONO, fontSize: 44, color: C.text, opacity: lin(t, cmd - 0.3, cmd), boxShadow: t > done ? `0 0 ${50 * (1 - lin(t, done, done + 1.2)) + 10}px ${C.yellow}55` : "none" }}>
          <span style={{ color: C.yellow }}>$</span>
          {typed(command, t, cmd, 22)}
          <span style={{ opacity: Math.floor(t * 2.5) % 2 ? 1 : 0.2 }}>▍</span>
        </div>
        <div style={{ display: "flex", gap: 18, marginTop: 40 }}>
          {["Open source · MIT", "Claude Code · Codex · any agent with skills", "macOS · Windows"].map((s, i) => {
            const p = spr(t, oss + i * 0.12, { damping: 15 });
            return (
              <div key={s} style={{ fontFamily: SANS, fontSize: 24, color: C.text, padding: "10px 22px", borderRadius: 999, border: "1px solid rgba(255,255,255,0.16)", background: "rgba(255,255,255,0.04)", opacity: p, transform: `translateY(${(1 - p) * 20}px)` }}>
                {s}
              </div>
            );
          })}
        </div>
        <div style={{ fontFamily: MONO, fontSize: 30, color: C.muted, marginTop: 36, opacity: lin(t, done, done + 0.5) }}>github.com/AGIHunt/blurt</div>
      </AbsoluteFill>
      <AbsoluteFill style={{ background: "#fff", opacity: flash * 0.8 }} />
      <AbsoluteFill style={{ background: "#000", opacity: end }} />
    </AbsoluteFill>
  );
};

export { Words };
