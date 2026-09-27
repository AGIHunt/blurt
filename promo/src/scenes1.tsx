import React from "react";
import { AbsoluteFill } from "remotion";
import { C, SANS, MONO, cue, lin, spr, pulse, typed, useT, scene, INOUT, chickenAt } from "./lib";
import { APP, Backdrop, FakeApp, Headline, Logo, MacWindow, MiniScreen, Words, DrawBox } from "./ui";

// ================================================================== 1. hook: 40 screens overnight
export const Hook: React.FC = () => {
  const t = useT();
  const fail = cue("hook.fail");
  const cols = 8, rows = 5, w = 170, h = 106, g = 18;
  const push = 1 + t * 0.02;
  const desat = lin(t, fail, fail + 0.4);
  return (
    <AbsoluteFill>
      <Backdrop glow={0.8} hue="cool" />
      <AbsoluteFill style={{ alignItems: "center", paddingTop: 92 }}>
        <div style={{ fontFamily: MONO, fontSize: 22, color: C.muted, opacity: lin(t, 0.1, 0.5), marginBottom: 26 }}>
          <span style={{ color: "#4ADE80" }}>✓</span> agent finished · 40 screens · 12,408 lines ·{" "}
          <span style={{ color: C.text }}>03:12 AM</span>
        </div>
        <Headline size={78} style={{ textAlign: "center", height: 90 }}>
          {t < fail ? (
            <Words text="40 screens. Overnight." t0={0.45} gap={0.12} size={78} accent={{ "40": C.yellow }} />
          ) : (
            <Words text="Now tell it what's wrong." t0={fail} gap={0.08} size={78} accent={{ "wrong.": C.issue }} />
          )}
        </Headline>
        <div
          style={{
            marginTop: 40,
            display: "grid",
            gridTemplateColumns: `repeat(${cols}, ${w}px)`,
            gap: g,
            transform: `scale(${push}) perspective(1600px) rotateX(${14 - t * 1.5}deg)`,
            filter: `saturate(${1 - desat * 0.7}) brightness(${1 - desat * 0.25})`,
          }}
        >
          {Array.from({ length: cols * rows }, (_, i) => {
            const t0 = 0.5 + ((i * 7) % 40) * 0.05;
            const p = spr(t, t0, { damping: 15, stiffness: 220 });
            const bugIdx = [3, 9, 14, 22, 29, 35].indexOf(i);
            const bug = bugIdx >= 0 ? spr(t, fail + 0.35 + bugIdx * 0.28, { damping: 9, stiffness: 260 }) : 0;
            return (
              <div key={i} style={{ opacity: p, transform: `scale(${0.6 + p * 0.4}) translateY(${(1 - p) * 30}px)` }}>
                <MiniScreen i={i} w={w} h={h} bug={bug} />
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

// ================================================================== 2. pain: the screenshot grind
const repeatTimes = (() => {
  const out: number[] = [];
  let t = cue("pain.repeat"), gap = 0.42;
  while (t < cue("pain.stamp") - 0.12) {
    out.push(t);
    t += gap;
    gap = Math.max(0.09, gap * 0.86);
  }
  return out;
})();

export const Pain: React.FC = () => {
  const t = useT();
  const [s0] = scene("pain");
  const shot = cue("pain.shot"), box = cue("pain.box"), type = cue("pain.type"), paste = cue("pain.paste"), stamp = cue("pain.stamp");
  const flash = pulse(t, shot, 0.22);
  const done = repeatTimes.filter((x) => x <= t).length;
  const count = t < paste + 0.3 ? 0 : 1 + done;
  const pasteP = lin(t, paste, paste + 0.45, 0, 1, INOUT);
  const stampP = spr(t, stamp, { damping: 11, stiffness: 240 });
  const shake = t > stamp && t < stamp + 0.3 ? Math.sin(t * 90) * 10 * (1 - (t - stamp) / 0.3) : 0;
  const msg = "The Save button on Settings is a few px too low, compared to Cancel. Should line up…";
  const windowScale = 0.98 - pasteP * 0.04;
  const loopShake = t > cue("pain.repeat") ? Math.sin(t * 40) * Math.min(1, (t - cue("pain.repeat")) / 3) * 2 : 0;
  return (
    <AbsoluteFill>
      <Backdrop glow={0.6} hue="cool" />
      <AbsoluteFill style={{ transform: `translate(${shake + loopShake}px, 0)`, filter: `brightness(${1 - stampP * 0.55}) blur(${stampP * 3}px)` }}>
        {/* app under inspection */}
        <div
          style={{
            position: "absolute",
            left: 60,
            top: 50,
            transform: `scale(${windowScale}) perspective(2000px) rotateY(${8 - (t - s0) * 0.4}deg)`,
            transformOrigin: "0 0",
          }}
        >
          <MacWindow>
            <FakeApp
              overlay={
                <>
                  <DrawBox x={APP.cancel.x - 14} y={APP.cancel.y - 14} w={APP.save.x + APP.save.w - APP.cancel.x + 28} h={APP.save.h + 34} t0={box} dur={0.5} />
                </>
              }
            />
          </MacWindow>
          {/* camera frame corners on screenshot */}
          {t > shot && t < shot + 0.9 && (
            <div style={{ position: "absolute", inset: -10, border: "3px solid rgba(255,255,255,0.8)", borderRadius: 18, opacity: 1 - lin(t, shot + 0.3, shot + 0.9) }} />
          )}
        </div>
        {/* typed ticket */}
        {t > type - 0.1 && (
          <div
            style={{
              position: "absolute",
              left: 1130 + pasteP * 220,
              top: 610 - pasteP * 380,
              width: 640 - pasteP * 320,
              padding: 26,
              borderRadius: 16,
              background: "#16161C",
              border: "1px solid rgba(255,255,255,0.12)",
              boxShadow: "0 30px 80px rgba(0,0,0,0.5)",
              fontFamily: SANS,
              fontSize: 24 - pasteP * 8,
              color: C.text,
              opacity: 1 - lin(t, paste + 0.35, paste + 0.5),
              transform: `scale(${spr(t, type - 0.1, { damping: 18 })})`,
            }}
          >
            <div style={{ fontSize: 15, color: C.dim, marginBottom: 10, fontWeight: 600 }}>NEW TICKET</div>
            {typed(msg, t, type, 70)}
            <span style={{ opacity: Math.floor(t * 3) % 2 ? 1 : 0 }}>▍</span>
          </div>
        )}
        {/* ticket stack */}
        <div style={{ position: "absolute", right: 70, top: 150, width: 330 }}>
          <div style={{ fontFamily: SANS, fontSize: 18, color: C.dim, fontWeight: 700, marginBottom: 14, opacity: lin(t, paste, paste + 0.3) }}>TICKETS</div>
          {Array.from({ length: Math.min(count, 9) }, (_, i) => {
            const idx = count - 1 - i;
            const born = idx === 0 ? paste + 0.3 : repeatTimes[idx - 1];
            const p = spr(t, born, { damping: 16, stiffness: 260 });
            return (
              <div
                key={idx}
                style={{
                  height: 58,
                  marginBottom: 10,
                  borderRadius: 12,
                  background: "#16161C",
                  border: "1px solid rgba(255,255,255,0.09)",
                  display: "flex",
                  alignItems: "center",
                  gap: 12,
                  padding: "0 14px",
                  opacity: p * (1 - i * 0.09),
                  transform: `translateX(${(1 - p) * 120}px)`,
                  fontFamily: SANS,
                  fontSize: 17,
                  color: C.muted,
                }}
              >
                <div style={{ width: 54, height: 34, borderRadius: 6, background: "#23232B", border: `2px solid ${C.issue}88` }} />
                Screenshot + notes #{idx + 1}
              </div>
            );
          })}
        </div>
        {/* counter + clock */}
        {count > 1 && (
          <div style={{ position: "absolute", right: 80, bottom: 170, textAlign: "right", fontFamily: SANS }}>
            <div style={{ fontSize: 120, fontWeight: 900, color: C.text, letterSpacing: -4, lineHeight: 1 }}>×{Math.min(40, Math.round(1 + (count - 1) * 1.9))}</div>
            <div style={{ fontSize: 26, color: C.muted, marginTop: 8, fontFamily: MONO }}>
              {`Day ${t > cue("pain.repeat") + 1.8 ? 2 : 1} · ${String(9 + Math.floor((t - cue("pain.repeat")) * 5.5) % 24).padStart(2, "0")}:${String(Math.floor(t * 97) % 60).padStart(2, "0")}`}
            </div>
          </div>
        )}
        {flash > 0 && <AbsoluteFill style={{ background: "#fff", opacity: flash * 0.8 }} />}
      </AbsoluteFill>
      {/* the stamp */}
      {stampP > 0 && (
        <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
          <div
            style={{
              fontFamily: SANS,
              fontWeight: 900,
              fontSize: 230,
              color: C.issue,
              border: `14px solid ${C.issue}`,
              borderRadius: 30,
              padding: "0 60px",
              letterSpacing: -6,
              transform: `rotate(-8deg) scale(${2.2 - stampP * 1.2})`,
              opacity: Math.min(1, stampP * 1.5),
              textShadow: `0 0 60px ${C.issue}66`,
            }}
          >
            2 DAYS
          </div>
        </AbsoluteFill>
      )}
      {(() => {
        // endless explaining: "blah blah" bubbles pile up (sound: audio/fx/babble.wav)
        const c = chickenAt("babble")[0];
        if (t < c) return null;
        const B: [number, number, number, string][] = [
          [120, 690, -6, "blah blah blah…"], [1300, 150, 5, "…and the button…"], [260, 170, -4, "blah blah"],
          [1180, 700, 4, "you know what I mean?"], [700, 820, -2, "blah blah blah blah"], [1500, 430, 7, "also this one…"], [80, 420, 3, "blah…"],
        ];
        return (
          <>
            {B.map(([x, y, r, s], i) => {
              const p = spr(t, c + i * 0.2, { damping: 11, stiffness: 240 });
              const out = lin(t, 17.8, 18.09);
              return p > 0 ? (
                <div key={i} style={{ position: "absolute", left: x, top: y, transform: `scale(${p * (1 - out * 0.3)}) rotate(${r + Math.sin(t * 9 + i) * 2}deg)`, opacity: 1 - out, fontFamily: SANS, fontWeight: 800, fontSize: 40, color: "#111", background: i % 2 ? "#E4E4E7" : "#fff", padding: "12px 26px", borderRadius: 26, whiteSpace: "nowrap", boxShadow: "0 16px 40px rgba(0,0,0,0.5)" }}>
                  {s}
                </div>
              ) : null;
            })}
          </>
        );
      })()}
    </AbsoluteFill>
  );
};

// ================================================================== 3. blind: voice alone can't point
export const Blind: React.FC = () => {
  const t = useT();
  const mic = cue("blind.mic"), but = cue("blind.but"), title = cue("blind.title"), dark = cue("blind.dark");
  const qs = [cue("blind.q1"), cue("blind.q2"), cue("blind.q3")];
  const phase1 = 1 - lin(t, title - 0.1, title + 0.25);
  const text: [string, number][] = [
    ["The button ", 0], ["here", 1], [" is a bit off… and ", 0], ["this thing", 2], [" looks weird… no, not ", 0], ["that one", 3], [".", 0],
  ];
  let shown = typed(text.map((x) => x[0]).join(""), t, mic + 0.2, 34).length;
  const darkP = lin(t, dark, dark + 0.5);
  return (
    <AbsoluteFill>
      <Backdrop glow={0.5 * (1 - darkP)} hue="cool" />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: phase1 }}>
        {/* waveform */}
        <div style={{ display: "flex", gap: 7, alignItems: "center", height: 150, marginBottom: 50 }}>
          {Array.from({ length: 36 }, (_, i) => {
            const live = t > mic && t < but + 1.5 ? 1 : 0.15;
            const a = (0.25 + 0.75 * Math.abs(Math.sin(t * 7 + i * 0.7) * Math.sin(t * 3.1 + i * 0.33))) * live;
            return <div key={i} style={{ width: 10, height: 12 + a * 130, borderRadius: 9, background: `linear-gradient(${C.yellow}, ${C.red})`, opacity: 0.5 + a * 0.5 }} />;
          })}
        </div>
        <div style={{ fontFamily: SANS, fontSize: 52, fontWeight: 600, color: C.text, maxWidth: 1400, textAlign: "center", lineHeight: 1.35 }}>
          {text.map(([s, q], i) => {
            const part = s.slice(0, Math.max(0, shown));
            shown -= s.length;
            if (!part) return null;
            const qi = q - 1;
            const qp = q ? spr(t, qs[qi], { damping: 9, stiffness: 260 }) : 0;
            return (
              <span key={i} style={{ position: "relative", color: q ? C.yellow : C.text, background: q ? `${C.yellow}1a` : "none", borderRadius: 8, padding: q ? "0 6px" : 0 }}>
                {part}
                {q > 0 && qp > 0 && (
                  <span
                    style={{
                      position: "absolute",
                      right: -26,
                      top: -40,
                      width: 52,
                      height: 52,
                      borderRadius: 99,
                      background: C.issue,
                      color: "#fff",
                      fontSize: 34,
                      fontWeight: 900,
                      display: "flex",
                      alignItems: "center",
                      justifyContent: "center",
                      transform: `scale(${qp})`,
                      boxShadow: `0 8px 30px ${C.issue}88`,
                    }}
                  >
                    ?
                  </span>
                )}
              </span>
            );
          })}
        </div>
        <div style={{ marginTop: 50, fontFamily: MONO, fontSize: 24, color: C.dim, opacity: lin(t, but, but + 0.4) }}>
          AI: which button? which thing? which one?
        </div>
      </AbsoluteFill>
      {/* title */}
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: (1 - phase1) * (1 - lin(t, dark - 0.1, dark + 0.3)) }}>
        <Headline size={130} style={{ textAlign: "center" }}>
          <Words text="Voice alone is" t0={title} gap={0.07} size={130} />
          <span style={{ display: "inline-block", filter: `blur(${lin(t, title + 0.4, title + 1.2, 0, 14)}px)`, color: C.muted }}>blind.</span>
        </Headline>
      </AbsoluteFill>
      {/* darkness + "give it eyes" */}
      <AbsoluteFill style={{ background: "#000", opacity: darkP * 0.9 }} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <div style={{ fontFamily: SANS, fontWeight: 700, fontSize: 64, color: C.text, opacity: lin(t, dark + 0.5, dark + 1.1) * (1 - lin(t, 26.2, 26.45)), letterSpacing: -1.5 }}>
          So give it <span style={{ color: C.yellow }}>eyes.</span>
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

// ================================================================== 4. reveal
export const Reveal: React.FC = () => {
  const t = useT();
  const drop = cue("reveal.drop"), name = cue("reveal.name");
  const lp = spr(t, drop, { damping: 10, stiffness: 150, mass: 0.9 });
  const flash = 1 - lin(t, drop, drop + 0.25);
  const ring = lin(t, drop, drop + 1.1);
  const push = 1 + (t - drop) * 0.012;
  return (
    <AbsoluteFill>
      <Backdrop glow={1.4} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", transform: `scale(${push})` }}>
        <div style={{ position: "absolute", width: 900, height: 900, borderRadius: 999, border: `6px solid ${C.yellow}`, transform: `scale(${0.2 + ring * 1.6})`, opacity: (1 - ring) * 0.7 }} />
        <div style={{ position: "absolute", width: 700, height: 700, borderRadius: 999, background: `radial-gradient(${C.yellow}55, transparent 65%)`, opacity: lp }} />
        <div style={{ display: "flex", alignItems: "center", gap: 20, marginTop: -110 }}>
          <Logo size={330} style={{ transform: `scale(${lp}) rotate(${(1 - lp) * -25}deg)` }} />
          <div style={{ fontFamily: SANS, fontWeight: 900, fontSize: 200, color: C.text, letterSpacing: -9, display: "flex" }}>
            {"blurt".split("").map((ch, i) => {
              const p = spr(t, name + i * 0.05, { damping: 12, stiffness: 240 });
              return (
                <span key={i} style={{ display: "inline-block", transform: `translateY(${(1 - p) * 90}px) scale(${0.5 + p * 0.5})`, opacity: Math.min(1, p * 1.5) }}>
                  {ch}
                </span>
              );
            })}
          </div>
        </div>
        <div style={{ position: "absolute", top: 640, fontFamily: SANS, fontWeight: 800, fontSize: 72, letterSpacing: -2, display: "flex", gap: 30 }}>
          {[
            ["Show it.", cue("reveal.show"), C.text],
            ["Say it.", cue("reveal.say"), C.text],
            ["Your AI gets it.", cue("reveal.gets"), C.yellow],
          ].map(([s, t0, col]) => {
            const p = spr(t, t0 as number, { damping: 15, stiffness: 200 });
            return (
              <span key={s as string} style={{ color: col as string, opacity: Math.min(1, p * 1.4), transform: `translateY(${(1 - p) * 40}px)`, filter: `blur(${(1 - p) * 10}px)` }}>
                {s}
              </span>
            );
          })}
        </div>
        <div style={{ position: "absolute", top: 750, fontFamily: `"PingFang SC", sans-serif`, fontSize: 34, fontWeight: 600, color: C.muted, letterSpacing: 8, opacity: lin(t, name + 0.4, name + 0.9) }}>
          口喷鸡 · 边看边喷，AI 全懂
        </div>
      </AbsoluteFill>
      <AbsoluteFill style={{ background: "#fff", opacity: flash * 0.9 }} />
    </AbsoluteFill>
  );
};
