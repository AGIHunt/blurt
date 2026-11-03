// src/cards.ts: the Mac's BlurtCore CardRow / CardShape rules (CardRowTests.swift, IslandLayoutTests.swift) and the
// Windows placement of the row under the island at any display scale.
import { describe, expect, it } from 'vitest';
import { CardReveal, DeferredClick, cardRow, cardShape, fills, rowBounds, rowCentre, stepAside, threadX, MAX_WIDTH, MAX_SHOWN } from '../src/cards';

const shot = 112;
const voice = 168;
const layout = (widths: number[], centre = 720, screen = 1440) => cardRow(widths, centre, [12, screen - 12], { tile: shot });

describe('the hanging row (CardRow)', () => {
  it('newest first, left to right, centred under the island', () => {
    const l = layout([shot, shot, shot]);
    expect(l.shown).toEqual([2, 1, 0]);
    expect(l.more).toBe(0);
    expect(l.tileX).toBeNull();
    expect(l.centres).toEqual([...l.centres].sort((a, b) => a - b));
    expect((l.span[0] + l.span[1]) / 2).toBeCloseTo(720, 2);
  });
  it('many cards: the newest five and a count', () => {
    const l = layout(Array(16).fill(shot));
    expect(l.shown).toEqual([15, 14, 13, 12, 11]);
    expect(l.more).toBe(11);
    expect(l.tileX!).toBeGreaterThan(l.centres[l.centres.length - 1]);
    expect(l.span[1] - l.span[0]).toBeLessThanOrEqual(MAX_WIDTH);
  });
  it('voice cards are wider, so fewer hang', () => {
    const l = layout(Array(8).fill(voice));
    expect(l.shown.length).toBeLessThan(MAX_SHOWN);
    expect(l.span[1] - l.span[0]).toBeLessThanOrEqual(MAX_WIDTH);
    expect(l.shown.length + l.more).toBe(8);
  });
  it('never off the screen', () => {
    expect(layout(Array(9).fill(shot), 40, 1280).span[0]).toBeGreaterThanOrEqual(12);
    const narrow = layout(Array(6).fill(voice), 300, 600);
    expect(narrow.span[1]).toBeLessThanOrEqual(588);
    expect(narrow.shown.length).toBeGreaterThanOrEqual(1);
  });
  it('no "+1" tile for a card that would fit', () => {
    // five snaps of 150 are 798 wide: all of them hang, not four and a "+1" the size of the card it hid
    const l = layout(Array(5).fill(150));
    expect(l.more).toBe(0);
    expect(l.shown.length).toBe(5);
  });
  it('empty', () => expect(layout([]).shown).toEqual([]));
});

// The founder's RDP screen (2000 × 1250 physical) at 100–200 %: the window's CSS width is the physical width over
// the scale; the single card must hang under the island's centre, never at the window's left edge.
describe('the row under the island at every display scale', () => {
  for (const scale of [1, 1.25, 1.5, 2]) {
    it(`${scale * 100} %`, () => {
      const css = 2000 / scale;
      const l = cardRow([shot], rowCentre(css, css), rowBounds(css));
      expect(l.centres[0]).toBeCloseTo(css / 2, 5);
    });
  }
  it('a window not laid out yet falls back to the screen, never to x = 0', () => {
    expect(rowCentre(0, 1600)).toBe(800);
    const l = cardRow([shot], rowCentre(0, 1600), rowBounds(1600));
    expect(l.centres[0]).toBe(800);
  });
  it('a secondary monitor: the window is the monitor\'s, so the centre is its own', () => {
    const l = cardRow([shot, shot], rowCentre(1280, 1280), rowBounds(1280));
    expect((l.span[0] + l.span[1]) / 2).toBeCloseTo(640, 5);
  });
});

describe('threads and lifting', () => {
  it('threads hang straight while the row fits under the island', () => {
    expect(threadX(700, [650, 790], [620, 820])).toBe(700);
    expect(threadX(600, [560, 700], [620, 820])).toBe(620);
  });
  it('a wider row maps onto the island edge in order', () => {
    const xs = [480, 600, 720, 840, 940].map((x) => threadX(x, [420, 1000], [620, 820]));
    expect(xs).toEqual([...xs].sort((a, b) => a - b));
    expect(Math.min(...xs)).toBeGreaterThanOrEqual(620);
    expect(Math.max(...xs)).toBeLessThanOrEqual(820);
  });
  it('stepping aside moves every item on each side', () => {
    expect(stepAside(5, null)).toEqual([0, 0, 0, 0, 0]);
    expect(stepAside(5, 2)).toEqual([-8, -8, 0, 8, 8]);
    expect(stepAside(3, 0)).toEqual([0, 8, 8]);
  });
});

describe('card shape (CardShape)', () => {
  it('an ordinary snap keeps the classic card', () => expect(cardShape({ w: 1440, h: 1080 })).toEqual({ w: 112, h: 84, fills: true }));
  it('a wide-screen snap is wider and still fills', () => {
    const f = cardShape({ w: 1920, h: 1080 });
    expect(f.w).toBe(149);
    expect(f.fills).toBe(true);
  });
  it('a toolbar or a sidebar is shown whole', () => {
    expect(cardShape({ w: 2400, h: 120 })).toEqual({ w: 150, h: 84, fills: false });
    expect(cardShape({ w: 320, h: 1800 })).toEqual({ w: 84, h: 84, fills: false });
  });
  it('a portrait snap fills a square card', () => expect(cardShape({ w: 900, h: 1200 })).toEqual({ w: 84, h: 84, fills: true }));
  it('fills rule', () => {
    expect(fills({ w: 4, h: 3 }, { w: 56, h: 40 })).toBe(true);
    expect(fills({ w: 20, h: 1 }, { w: 56, h: 40 })).toBe(false);
    expect(cardShape(null).fills).toBe(true);
  });
});

describe('reveal and clicks', () => {
  it('brought down on purpose: stays until visited and left, or 10 s', () => {
    expect(CardReveal.staysDown(false, false, 3000)).toBe(true);
    expect(CardReveal.staysDown(false, false, 11000)).toBe(false);
    expect(CardReveal.staysDown(true, true, 20000)).toBe(true);
    expect(CardReveal.staysDown(true, false, 1000)).toBe(false);
  });
  it('a click copies after the double-click interval; a double-click edits and never copies', () => {
    const d = new DeferredClick<number>();
    expect(d.click(1, 1, 0, 500)).toBe('copy');
    expect(d.fire(400)).toBeNull();
    expect(d.fire(500)).toBe(1);
    expect(d.fire(600)).toBeNull();
    d.click(2, 1, 1000, 500);
    expect(d.click(2, 2, 1200, 500)).toBe('edit');
    expect(d.fire(2000)).toBeNull();
  });
});

import { CardsPanelRules as R, cardAgo, daysLeft, gridColumns, panelKey } from '../src/cards';

describe('the Cards panel (CardsPanelKeys, CardGrid)', () => {
  it('opens on Current while a card hangs, else History; nothing: nothing', () => {
    expect(R.toggle(false, 2, 5)).toBe('hanging');
    expect(R.toggle(false, 0, 5)).toBe('used');
    expect(R.toggle(false, 0, 0)).toBe('nothing');
    expect(R.toggle(true, 2, 0)).toBe('close');
  });
  it('the grid never leaves an orphan', () => {
    expect([1, 4, 5, 6, 7, 8, 9].map(gridColumns)).toEqual([1, 4, 3, 3, 4, 4, 4]);
  });
  it('arrows switch segments with no card focused, move in the grid with one', () => {
    expect(R.action('right', 'hanging', null, 5, 3)).toEqual({ a: 'segment', seg: 'used' });
    expect(R.action('left', 'hanging', null, 5, 3)).toEqual({ a: 'none' });
    expect(R.action('down', 'hanging', null, 5, 3)).toEqual({ a: 'focus', i: 0 });
    expect(R.action('down', 'hanging', 1, 5, 3)).toEqual({ a: 'focus', i: 4 });
    expect(R.action('down', 'hanging', 3, 5, 3)).toEqual({ a: 'none' });
    expect(R.action('up', 'hanging', 1, 5, 3)).toEqual({ a: 'focus', i: null });
    expect(R.action('right', 'hanging', 4, 5, 3)).toEqual({ a: 'none' });
    expect(R.action('tab', 'used', 2, 5, 3)).toEqual({ a: 'segment', seg: 'hanging' });
  });
  it('Space previews the focused card or the pointed one; Enter copies and closes; Esc closes', () => {
    expect(R.action('space', 'hanging', null, 5, 3, 2)).toEqual({ a: 'preview', i: 2 });
    expect(R.action('enter', 'hanging', 1, 5, 3)).toEqual({ a: 'copyAndClose', i: 1 });
    expect(R.action('enter', 'hanging', null, 5, 3)).toEqual({ a: 'none' });
    expect(R.action('delete', 'used', 0, 1, 1)).toEqual({ a: 'delete', i: 0 });
    expect(R.action('escape', 'used', 0, 1, 1)).toEqual({ a: 'close' });
    expect(R.previewAction('right')).toEqual({ a: 'step', d: 1 });
    expect(R.previewAction('space')).toEqual({ a: 'close' });
  });
  it('Windows keys: Ctrl where the Mac has ⌘', () => {
    expect(panelKey({ key: 'c', ctrlKey: true })).toBe('copy');
    expect(panelKey({ key: ' ' })).toBe('space');
    expect(panelKey({ key: 'Delete' })).toBe('delete');
    expect(panelKey({ key: 'x' })).toBeNull();
  });
  it('how long ago, and the days a used card has left', () => {
    expect(cardAgo(20)).toEqual({ k: 'just' });
    expect(cardAgo(300)).toEqual({ k: 'min', n: 5 });
    expect(cardAgo(7200)).toEqual({ k: 'hr', n: 2 });
    expect(cardAgo(90000)).toEqual({ k: 'yesterday' });
    expect(cardAgo(3 * 86400)).toEqual({ k: 'days', n: 3 });
    expect(daysLeft(0, 6.5 * 86400)).toBe(1);
  });
});
