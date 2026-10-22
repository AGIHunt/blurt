import { describe, expect, it } from 'vitest';
import { checkCatalogs, createI18n } from '@blurt/i18n';
import { meterBars } from '../src/clock';
import EN from '../src/locales/en.json';
import ZH from '../src/locales/zh-Hans.json';
import { clampRect, isClick, moveRect, parseRect, rectFrom, sizeLabel, toolbarPos } from '../src/geom';
import { EnterGuard } from '../src/ime';
import { Pendulum, Spring } from '../src/spring';

describe('geom', () => {
  it('drag in any direction', () => {
    expect(rectFrom({ x: 50, y: 80 }, { x: 10, y: 20 })).toEqual({ x: 10, y: 20, w: 40, h: 60 });
  });
  it('clamps and moves inside the window', () => {
    const b = { w: 100, h: 100 };
    expect(clampRect({ x: -10, y: 90, w: 50, h: 50 }, b)).toEqual({ x: 0, y: 90, w: 40, h: 10 });
    expect(moveRect({ x: 10, y: 10, w: 50, h: 50 }, 80, -30, b)).toEqual({ x: 50, y: 0, w: 50, h: 50 });
  });
  it('a tiny drag is a click', () => {
    expect(isClick({ x: 0, y: 0, w: 30, h: 5 })).toBe(true);
    expect(isClick({ x: 0, y: 0, w: 30, h: 30 })).toBe(false);
  });
  it('size label is physical and even, like record.py', () => {
    expect(sizeLabel({ x: 0, y: 0, w: 640.4, h: 360.9 }, 1.5)).toBe('960 × 540');
  });
  it('toolbar goes below, else above, else inside', () => {
    const bar = { w: 200, h: 40 };
    const b = { w: 1000, h: 800 };
    expect(toolbarPos({ x: 100, y: 100, w: 400, h: 300 }, bar, b)).toEqual({ x: 300, y: 410 });
    expect(toolbarPos({ x: 100, y: 500, w: 400, h: 280 }, bar, b)).toEqual({ x: 300, y: 450 });
    expect(toolbarPos({ x: 0, y: 0, w: 1000, h: 800 }, bar, b)).toEqual({ x: 792, y: 750 });
  });
  it('parses ?last=', () => {
    expect(parseRect('1,2,3,4')).toEqual({ x: 1, y: 2, w: 3, h: 4 });
    expect(parseRect('1,2,3')).toBeNull();
    expect(parseRect(null)).toBeNull();
  });
});

describe('island', () => {
  it('meters the mic level', () => {
    expect(meterBars(0)).toBe(0);
    expect(meterBars(0.003)).toBe(0); // ≈ −50 dB
    expect(meterBars(0.3)).toBe(5);
    expect(meterBars(0.3, 12)).toBe(12);
  });
  it('en and zh-Hans catalogs match (K10)', () => {
    expect(checkCatalogs(EN, ZH)).toEqual([]);
    for (const k of Object.keys(EN)) expect(EN[k as keyof typeof EN].trim(), k).not.toBe('');
  });
  it('every job type and step the island names has words', () => {
    const i = createI18n({ en: EN, 'zh-Hans': ZH }, 'zh-Hans');
    for (const k of ['job.type.process', 'job.step.write', 'session.waiting_input', 'project.ai_sort', 'project.open_folder'])
      expect(i.has(k), k).toBe(true);
    expect(i.plural('island.open_inbox', 5)).toBe('5 条需要你看');
    expect(createI18n({ en: EN }, 'en').plural('island.open_inbox', 1)).toBe('1 item needs you');
  });
});

describe('IME Enter guard (C6)', () => {
  it('ignores composing Enter and the one right after compositionend', () => {
    let now = 1000;
    const g = new EnterGuard(() => now);
    expect(g.isSubmit({ key: 'Enter' })).toBe(true);
    expect(g.isSubmit({ key: 'Enter', isComposing: true })).toBe(false);
    expect(g.isSubmit({ key: 'Enter', keyCode: 229 })).toBe(false);
    expect(g.isSubmit({ key: 'Enter', shiftKey: true })).toBe(false);
    g.compositionEnd();
    now += 30;
    expect(g.isSubmit({ key: 'Enter' })).toBe(false);
    now += 40;
    expect(g.isSubmit({ key: 'Enter' })).toBe(true);
  });
});

describe('motion', () => {
  it('spring settles on its target', () => {
    const s = new Spring(-1);
    s.target = 0;
    for (let i = 0; i < 120; i++) s.step(1 / 60);
    expect(s.resting).toBe(true);
  });
  it('pendulum swings then rests; holding damps it faster', () => {
    const a = new Pendulum();
    const b = new Pendulum();
    a.kick(2.5);
    b.kick(2.5);
    let crossed = false;
    for (let i = 0; i < 30; i++) {
      a.step(1 / 60);
      b.step(1 / 60, true);
      if (a.angle < 0) crossed = true;
    }
    expect(crossed).toBe(true); // it swings back past the rest position
    expect(Math.abs(b.velocity)).toBeLessThan(Math.abs(a.velocity) + 1e-9);
    for (let i = 0; i < 60 * 8; i++) a.step(1 / 60);
    expect(a.resting).toBe(true);
  });
});
