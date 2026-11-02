// The recording chrome's geometry (rec.ts): the countdown ring's clock and the paused frame's dashes.

/** The time left as the ring shows it: `n - 1 + p` of `total` seconds, `p` the part of this second still to go. */
export function ringLeft(n: number, total: number, p: number): number {
  return Math.max(0, Math.min(1, (n - 1 + Math.max(0, Math.min(1, p))) / Math.max(1, total)));
}

/** The paused frame as SVG path data (BorderView.dashedPieces): four solid corners (the arc and a `leg` each way),
 *  and on each side between them dashes of about `dash` with `gap` gaps, stretched so a whole number of them fits with
 *  a gap at both ends. `x0, y0, x1, y1`: the stroke's rectangle, y down. */
export function dashedPieces(x0: number, y0: number, x1: number, y1: number, r = 4, leg = 5, dash = 10, gap = 6): string[] {
  const k = r + leg;
  const f = (v: number) => Math.round(v * 100) / 100;
  const out = [
    `M${f(x0)},${f(y0 + k)}L${f(x0)},${f(y0 + r)}A${r},${r} 0 0 1 ${f(x0 + r)},${f(y0)}L${f(x0 + k)},${f(y0)}`,
    `M${f(x1 - k)},${f(y0)}L${f(x1 - r)},${f(y0)}A${r},${r} 0 0 1 ${f(x1)},${f(y0 + r)}L${f(x1)},${f(y0 + k)}`,
    `M${f(x1)},${f(y1 - k)}L${f(x1)},${f(y1 - r)}A${r},${r} 0 0 1 ${f(x1 - r)},${f(y1)}L${f(x1 - k)},${f(y1)}`,
    `M${f(x0 + k)},${f(y1)}L${f(x0 + r)},${f(y1)}A${r},${r} 0 0 1 ${f(x0)},${f(y1 - r)}L${f(x0)},${f(y1 - k)}`,
  ];
  const sides: [number, number, number, number][] = [
    [x0 + k, y0, x1 - k, y0],
    [x1, y0 + k, x1, y1 - k],
    [x1 - k, y1, x0 + k, y1],
    [x0, y1 - k, x0, y0 + k],
  ];
  for (const [ax, ay, bx, by] of sides) {
    const len = Math.hypot(bx - ax, by - ay);
    const n = Math.max(0, Math.round((len - gap) / (dash + gap)));
    if (!n) continue;
    const u = len / (n * dash + (n + 1) * gap);
    const d = dash * u;
    const g = gap * u;
    const dx = (bx - ax) / len;
    const dy = (by - ay) / len;
    for (let i = 0; i < n; i++) {
      const s0 = g + i * (d + g);
      out.push(`M${f(ax + dx * s0)},${f(ay + dy * s0)}L${f(ax + dx * (s0 + d))},${f(ay + dy * (s0 + d))}`);
    }
  }
  return out;
}

/** A finished stroke for the log: its kept points (≥ 3 px apart) at most ~120 of them, as 0–1 of the area. */
export function strokePoints(kept: { x: number; y: number }[], w: number, h: number, isShape: boolean): number[][] {
  let keep = kept;
  if (!isShape && keep.length > 120) {
    const step = Math.floor(keep.length / 120) + 1;
    keep = [...keep.filter((_, i) => i % step === 0), keep[keep.length - 1]];
  }
  const r3 = (v: number) => Math.round(Math.max(0, Math.min(1, v)) * 1000) / 1000;
  return keep.map((p) => [r3(p.x / Math.max(1, w)), r3(p.y / Math.max(1, h))]);
}
