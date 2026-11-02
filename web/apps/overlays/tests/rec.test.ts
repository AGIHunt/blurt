import { describe, expect, it } from 'vitest';
import { dashedPieces, ringLeft, strokePoints } from '../src/recgeom';

describe('countdown ring (CountdownView.ringLeft)', () => {
  it('drains once over the whole countdown, on the number’s own clock', () => {
    expect(ringLeft(3, 3, 1)).toBe(1);
    expect(ringLeft(3, 3, 0)).toBeCloseTo(2 / 3);
    expect(ringLeft(1, 3, 0)).toBe(0);
    expect(ringLeft(2, 5, 0.5)).toBeCloseTo(1.5 / 5);
  });
});

describe('paused frame (BorderView.dashedPieces)', () => {
  it('four solid corners, then whole dashes with a gap at both ends of each side', () => {
    const p = dashedPieces(2, 2, 402, 302);
    expect(p.slice(0, 4).every((d) => d.includes('A4,4'))).toBe(true);
    // a side of 400 - 2 × 9 = 382 px: round((382 - 6) / 16) = 24 dashes; 300 - 18 = 282: round(276 / 16) = 17
    expect(p.length).toBe(4 + 2 * 24 + 2 * 17);
    const first = p[4].match(/M([\d.]+),([\d.]+)L([\d.]+),/)!.map(Number);
    expect(first[1]).toBeGreaterThan(11); // starts a gap after the corner's leg (2 + 4 + 5)
  });
});

describe('a recording stroke for events.jsonl (InkView.end)', () => {
  it('0–1 of the area, freehand thinned to about 120 points, the last kept', () => {
    const pts = Array.from({ length: 500 }, (_, i) => ({ x: i, y: 50 }));
    const out = strokePoints(pts, 1000, 100, false);
    expect(out.length).toBeLessThanOrEqual(122);
    expect(out[0]).toEqual([0, 0.5]);
    expect(out[out.length - 1]).toEqual([0.499, 0.5]);
    expect(strokePoints([{ x: -5, y: 120 }], 100, 100, true)).toEqual([[0, 1]]);
  });
});
