// src/selection.ts: the hanging cards' multi-select (docs/design/drag-drop.md §2).
import { describe, expect, it } from 'vitest';
import { CardSelection, COPY_AFTER_MS, KEEP_MS } from '../src/selection';

const row = ['a', 'b', 'c', 'd', 'e', 'f', 'g']; // oldest first

describe('the order is the order picked', () => {
  it('Ctrl-click toggles, badges count 1, 2, 3', () => {
    const s = new CardSelection();
    s.toggle('e', 1);
    s.toggle('a', 2);
    s.toggle('c', 3);
    expect(s.order()).toEqual(['e', 'a', 'c']);
    expect([s.badge('e'), s.badge('a'), s.badge('c'), s.badge('b')]).toEqual([1, 2, 3, 0]);
    s.toggle('a', 4);
    expect(s.order()).toEqual(['e', 'c']);
    expect(s.badge('c')).toBe(2);
  });
  it('Shift-click adds the run from the last card clicked, oldest first', () => {
    const s = new CardSelection();
    s.toggle('f', 1);
    s.extend('c', row, 2); // clicked right to left: still oldest first
    expect(s.order()).toEqual(['f', 'c', 'd', 'e']);
    s.extend('g', row, 3); // the anchor moved to c
    expect(s.order()).toEqual(['f', 'c', 'd', 'e', 'g']);
  });
  it('Shift-click with no anchor picks that card alone', () => {
    const s = new CardSelection();
    s.extend('d', row, 1);
    expect(s.order()).toEqual(['d']);
    s.extend('zz', row, 2); // not on the row: nothing
    expect(s.order()).toEqual(['d']);
  });
  it('a gesture on a picked card takes the whole selection; on another card, that card', () => {
    const s = new CardSelection();
    s.toggle('g', 1);
    s.toggle('b', 2);
    expect(s.group('b')).toEqual(['g', 'b']);
    expect(s.group('c')).toEqual(['c']);
  });
  it('cards that left the row leave the selection', () => {
    const s = new CardSelection();
    s.toggle('a', 1);
    s.toggle('b', 2);
    s.toggle('c', 3);
    expect(s.retain(['a', 'c', 'd'])).toBe(true);
    expect(s.order()).toEqual(['a', 'c']);
    expect(s.retain(['a', 'c'])).toBe(false);
    s.extend('d', ['a', 'c', 'd'], 4); // the anchor (b) is gone: d alone
    expect(s.order()).toEqual(['a', 'c', 'd']);
  });
});

describe('the keyboard (Cards panel, Current)', () => {
  it('Ctrl+A: every card joins oldest first, after those already picked', () => {
    const s = new CardSelection();
    s.toggle('d', 1);
    s.pickAll(row, 2);
    expect(s.order()).toEqual(['d', 'a', 'b', 'c', 'e', 'f', 'g']);
    expect(s.copyDue(2 + COPY_AFTER_MS)).toBe(true);
  });
  it('Shift+arrows only add (a card already picked keeps its number)', () => {
    const s = new CardSelection();
    s.add('c', 1);
    s.add('b', 2);
    s.add('c', 3);
    expect(s.order()).toEqual(['c', 'b']);
    expect(s.badge('b')).toBe(2);
  });
});

describe('copied once, after the last change', () => {
  it('not on every toggle', () => {
    const s = new CardSelection();
    s.toggle('a', 1000);
    expect(s.copyDue(1000 + COPY_AFTER_MS - 1)).toBe(false);
    s.toggle('b', 1400);
    expect(s.copyDue(1000 + COPY_AFTER_MS)).toBe(false); // the second click moved it on
    expect(s.copyDue(1400 + COPY_AFTER_MS)).toBe(true);
    s.copied();
    expect(s.copyDue(9999)).toBe(false);
  });
  it('an emptied selection copies nothing', () => {
    const s = new CardSelection();
    s.toggle('a', 0);
    s.toggle('a', 10);
    expect(s.copyDue(10_000)).toBe(false);
  });
});

describe('kept a minute after the cards go up', () => {
  it('ends KEEP_MS after the cards went up, not before', () => {
    const s = new CardSelection();
    s.toggle('a', 0);
    expect(s.cardsUp(true, 5000)).toBe(true);
    expect(s.cardsUp(true, 6000)).toBe(false); // already counting
    expect(s.expired(5000 + KEEP_MS - 1)).toBe(false);
    expect(s.expired(5000 + KEEP_MS)).toBe(true);
  });
  it('coming down again stops the countdown', () => {
    const s = new CardSelection();
    s.toggle('a', 0);
    s.cardsUp(true, 1000);
    s.cardsUp(false, 20_000);
    expect(s.expired(1000 + KEEP_MS)).toBe(false);
    expect(s.cardsUp(true, 30_000)).toBe(true);
    expect(s.expired(30_000 + KEEP_MS)).toBe(true);
  });
  it('nothing picked: nothing to keep', () => {
    const s = new CardSelection();
    expect(s.cardsUp(true, 0)).toBe(false);
    expect(s.expired(KEEP_MS * 2)).toBe(false);
    s.toggle('a', 1);
    s.cardsUp(true, 2);
    s.clear();
    expect(s.expired(KEEP_MS * 2)).toBe(false);
    expect(s.size).toBe(0);
  });
});
