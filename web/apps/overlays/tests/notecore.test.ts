// The Mac's BlurtCore tests for the snap note's rules (NoteKeysTests, InkTests, CaptureRulesTests, AssignmentTests),
// on the TypeScript port the Windows bubble uses.
import { describe, expect, it } from 'vitest';
import {
  InkStroke,
  clock,
  dock,
  dragShape,
  filterPlaces,
  inkFit,
  inkWidth,
  joined,
  kindForDigit,
  merged,
  editApply,
  noteAction,
  placeChoices,
  shapePoints,
  snapTool,
  takenNote,
  type KeyState,
} from '../src/notecore';

const st = (o: Partial<KeyState> = {}): KeyState => ({
  mode: 'fresh',
  voice: 'none',
  typed: '',
  composing: false,
  picking: false,
  pickingKind: false,
  ...o,
});

describe('NoteKeys', () => {
  it('↩ commits in every state', () => {
    for (const mode of ['fresh', 'edit', 'recording'] as const)
      for (const voice of ['none', 'listening', 'words'] as const)
        expect(noteAction({ k: 'return' }, st({ mode, voice, typed: 'x' }))).toEqual({ a: 'commit' });
  });
  it('Tab takes the grey words, else opens the places', () => {
    expect(noteAction({ k: 'tab' }, st({ voice: 'words' }))).toEqual({ a: 'takeWords', newLine: false });
    expect(noteAction({ k: 'tab' }, st({ voice: 'listening' }))).toEqual({ a: 'openPlaces' });
    expect(noteAction({ k: 'tab' }, st({ voice: 'words', typed: 'typed over' }))).toEqual({ a: 'openPlaces' });
    expect(noteAction({ k: 'tab' }, st({ mode: 'edit', voice: 'words' }))).toEqual({ a: 'takeWords', newLine: false });
    expect(noteAction({ k: 'tab' }, st({ mode: 'recording' }))).toEqual({ a: 'pass' });
  });
  it('⇧↩ breaks the line; over grey words takes them first; on an empty fresh note does nothing', () => {
    expect(noteAction({ k: 'shiftReturn' }, st({ typed: 'a' }))).toEqual({ a: 'newLine' });
    expect(noteAction({ k: 'shiftReturn' }, st({ voice: 'words' }))).toEqual({ a: 'takeWords', newLine: true });
    expect(noteAction({ k: 'shiftReturn' }, st())).toEqual({ a: 'ignore' });
    expect(noteAction({ k: 'shiftReturn' }, st({ mode: 'edit' }))).toEqual({ a: 'newLine' });
  });
  it('typing replaces the grey words; before speaking it is a typed note; elsewhere just typing', () => {
    expect(noteAction({ k: 'typing' }, st({ voice: 'words' }))).toEqual({ a: 'typeOver' });
    expect(noteAction({ k: 'typing' }, st({ voice: 'listening' }))).toEqual({ a: 'typedNote' });
    expect(noteAction({ k: 'typing' }, st())).toEqual({ a: 'pass' });
    expect(noteAction({ k: 'typing' }, st({ mode: 'edit', voice: 'words' }))).toEqual({ a: 'pass' });
  });
  it('Esc: typed text first, then the snap', () => {
    expect(noteAction({ k: 'escape' }, st({ typed: 'x' }))).toEqual({ a: 'clearText' });
    expect(noteAction({ k: 'escape' }, st({ typed: '  ' }))).toEqual({ a: 'close' });
    expect(noteAction({ k: 'escape' }, st({ mode: 'edit', typed: 'x' }))).toEqual({ a: 'close' });
  });
  it('an input method keeps its keys, Ctrl+digits too', () => {
    for (const k of ['return', 'tab', 'escape', 'shiftReturn'] as const) expect(noteAction({ k }, st({ composing: true }))).toEqual({ a: 'pass' });
    expect(noteAction({ k: 'command', d: 1 }, st({ composing: true }))).toEqual({ a: 'pass' });
  });
  it('the place list keeps its keys but Esc', () => {
    expect(noteAction({ k: 'escape' }, st({ picking: true }))).toEqual({ a: 'closePlaces' });
    expect(noteAction({ k: 'return' }, st({ picking: true }))).toEqual({ a: 'pass' });
    expect(noteAction({ k: 'down' }, st({ picking: true }))).toEqual({ a: 'pass' });
  });
  it('Ctrl+1–4 set the type, Ctrl+0 clears it, in every mode and with either list open; 5–9 are not the bubble’s', () => {
    expect(noteAction({ k: 'command', d: 1 }, st())).toEqual({ a: 'setKind', kind: 'issue' });
    expect(noteAction({ k: 'command', d: 4 }, st({ mode: 'recording' }))).toEqual({ a: 'setKind', kind: 'task' });
    expect(noteAction({ k: 'command', d: 0 }, st({ picking: true }))).toEqual({ a: 'setKind', kind: null });
    expect(noteAction({ k: 'command', d: 2 }, st({ pickingKind: true }))).toEqual({ a: 'setKind', kind: 'idea' });
    expect(noteAction({ k: 'command', d: 5 }, st())).toEqual({ a: 'pass' });
    expect(kindForDigit(3)).toBe('note');
  });
  it('the type list takes ↑↓ ↩ Esc Tab; typing goes into the note; arrows are the field’s otherwise', () => {
    const p = st({ pickingKind: true });
    expect(noteAction({ k: 'up' }, p)).toEqual({ a: 'moveKind', d: -1 });
    expect(noteAction({ k: 'down' }, p)).toEqual({ a: 'moveKind', d: 1 });
    expect(noteAction({ k: 'return' }, p)).toEqual({ a: 'pickKind' });
    expect(noteAction({ k: 'escape' }, p)).toEqual({ a: 'closeKinds' });
    expect(noteAction({ k: 'tab' }, p)).toEqual({ a: 'closeKinds' });
    expect(noteAction({ k: 'shiftReturn' }, p)).toEqual({ a: 'ignore' });
    expect(noteAction({ k: 'typing' }, st({ pickingKind: true, voice: 'words' }))).toEqual({ a: 'typeOver' });
    expect(noteAction({ k: 'up' }, st())).toEqual({ a: 'pass' });
  });
});

describe('the note’s text', () => {
  it('merges typed and said as the card does', () => {
    expect(merged('fix this', 'the button')).toBe('fix this\nthe button');
    expect(merged('the button is faint', 'button')).toBe('the button is faint');
    expect(merged(null, ' said ')).toBe('said');
    expect(merged(' ', null)).toBeNull();
  });
  it('joins the taken words and what was typed after them', () => {
    expect(joined('save button', 'too faint')).toBe('save button too faint');
    expect(joined('保存按钮', '太浅')).toBe('保存按钮太浅');
    expect(joined('words', ' ')).toBe('words');
    expect(joined('make the border of', 'Also the Apply button')).toBe('make the border of. Also the Apply button');
    expect(joined('看不见。', '另外按钮太灰')).toBe('看不见。另外按钮太灰');
    expect(joined('the API is slow', 'API keys too')).toBe('the API is slow API keys too');
  });
  it('NoteEdit: untouched taken words keep the final words, an edit replaces them', () => {
    expect(takenNote('the save button', 'The save button.', 'the save button')).toEqual({ typed: null, said: 'The save button.' });
    expect(takenNote('the save button', null, 'the save button is faint')).toEqual({ typed: null, said: 'the save button is faint' });
    expect(takenNote('the save button', null, '  ')).toEqual({ typed: null, said: 'the save button' });
  });
});

describe('NoteEdit', () => {
  it('an untouched field keeps the note; an edit of spoken words replaces them; typed text stays typed', () => {
    expect(editApply('fix', 'the button', 'the button', 'fix\nthe button', true, false)).toEqual({ typed: 'fix', said: 'the button' });
    expect(editApply(null, 'the button', 'the button', 'the save button', true, false)).toEqual({ typed: null, said: 'the save button' });
    expect(editApply(null, 'the button', 'the button', ' ', true, false)).toEqual({ typed: null, said: 'the button' });
    expect(editApply('fix', null, null, 'fix it', true, false)).toEqual({ typed: 'fix it', said: null });
  });
  it('a kept re-record: the field is the typed part, the words are to come', () => {
    expect(editApply('fix', 'old words', 'old words', 'fix', false, true)).toEqual({ typed: 'fix', said: null });
  });
  it('a re-record not kept: the words said stay', () => {
    expect(editApply('fix', 'old words', 'old words', 'fix', false, false)).toEqual({ typed: 'fix', said: 'old words' });
  });
});

describe('the pen', () => {
  it('Shift box, Alt ellipse, Shift wins', () => {
    expect(snapTool(true, true)).toBe('box');
    expect(snapTool(false, true)).toBe('ellipse');
    expect(snapTool(false, false)).toBe('free');
  });
  it('a straight stroke snaps to a line, a level one exactly level', () => {
    const pts = Array.from({ length: 20 }, (_, i) => ({ x: i * 5, y: 100 + (i % 2) }));
    const s = inkFit(pts)!;
    expect(s.s).toBe('line');
    if (s.s === 'line') expect(s.b.y).toBe(s.a.y);
  });
  it('a closed loop snaps to an ellipse or a box, a scribble stays', () => {
    const circle = Array.from({ length: 60 }, (_, i) => {
      const a = (i / 59) * 2 * Math.PI;
      return { x: 100 + 50 * Math.cos(a), y: 100 + 30 * Math.sin(a) };
    });
    expect(inkFit(circle)?.s).toBe('ellipse');
    const box: { x: number; y: number }[] = [];
    for (let i = 0; i <= 20; i++) box.push({ x: i * 5, y: 0 });
    for (let i = 0; i <= 20; i++) box.push({ x: 100, y: i * 4 });
    for (let i = 0; i <= 20; i++) box.push({ x: 100 - i * 5, y: 80 });
    for (let i = 0; i <= 20; i++) box.push({ x: 0, y: 80 - i * 4 });
    expect(inkFit(box)?.s).toBe('rect');
    expect(inkFit([{ x: 0, y: 0 }, { x: 3, y: 2 }, { x: 1, y: 4 }])).toBeNull();
  });
  it('a box keeps its corners doubled, an ellipse is 73 points', () => {
    expect(shapePoints(dragShape('box', { x: 0, y: 0 }, { x: 10, y: 10 })!)).toHaveLength(10);
    expect(shapePoints(dragShape('ellipse', { x: 0, y: 0 }, { x: 10, y: 10 })!)).toHaveLength(73);
    expect(dragShape('box', { x: 0, y: 0 }, { x: 2, y: 2 })).toBeNull();
  });
  it('a stroke resting at its end snaps; moving on after a snap is freehand again', () => {
    const s = new InkStroke({ x: 0, y: 0 }, 'free', 0);
    for (let i = 1; i <= 20; i++) s.move({ x: i * 5, y: 0 }, 'free', i * 0.01);
    expect(s.checkRest(0.3)).toBe(false);
    expect(s.checkRest(0.8)).toBe(true);
    expect(s.kind).toBe('line');
    s.move({ x: 140, y: 40 }, 'free', 0.9);
    expect(s.snappedAs).toBeNull();
  });
  it('a tap keeps one point; Shift mid-drag shows a box', () => {
    const t = new InkStroke({ x: 5, y: 5 }, 'free', 0);
    expect(t.kept(2)).toHaveLength(1);
    const b = new InkStroke({ x: 0, y: 0 }, 'free', 0);
    b.move({ x: 50, y: 40 }, 'box', 0.1);
    expect(b.display).toHaveLength(10);
  });
  it('the line is wider on a bigger display', () => {
    expect(inkWidth(700)).toBe(3);
    expect(inkWidth(1080)).toBe(4);
    expect(inkWidth(2160)).toBe(6);
  });
});

describe('BubbleDock', () => {
  const screen = { x: 0, y: 0, w: 1440, h: 900 };
  const b = { w: 400, h: 140 };
  it('right of the selection, its top at the selection’s top', () => {
    expect(dock(b, { x: 100, y: 200, w: 500, h: 300 }, screen)).toEqual({ x: 612, y: 200, side: 'right' });
  });
  it('left when there is no room on the right', () => {
    expect(dock(b, { x: 800, y: 200, w: 600, h: 300 }, screen).side).toBe('left');
  });
  it('below, then above, then inside', () => {
    expect(dock(b, { x: 100, y: 100, w: 1300, h: 400 }, screen).side).toBe('below');
    expect(dock(b, { x: 100, y: 400, w: 1300, h: 450 }, screen).side).toBe('above');
    const full = dock(b, { x: 0, y: 0, w: 1440, h: 900 }, screen);
    expect(full.side).toBe('inside');
    expect(full).toMatchObject({ x: 1440 - 400 - 12, y: 900 - 140 - 12 });
  });
  it('kept on the screen near its bottom', () => {
    expect(dock(b, { x: 100, y: 820, w: 300, h: 60 }, screen).y).toBe(900 - 8 - 140);
  });
});

describe('ProjectPick', () => {
  const ps = [
    { id: 'a', name: 'website-refresh', key: 'WR' },
    { id: 'b', name: 'bug-agent', key: 'BA' },
    { id: 'c', name: 'Café notes', key: 'CN' },
    { id: 'd', name: 'abacus', key: 'AB' },
  ];
  it('the key exactly, then names starting with it, a word starting with it, the key starting with it, containing', () => {
    expect(filterPlaces(ps, 'ba').map((p) => p.id)).toEqual(['b', 'd']);
    expect(filterPlaces(ps, 'refresh').map((p) => p.id)).toEqual(['a']);
    expect(filterPlaces(ps, 'cafe').map((p) => p.id)).toEqual(['c']);
    expect(filterPlaces(ps, '').map((p) => p.id)).toEqual(['a', 'b', 'c', 'd']);
  });
  it('Unassigned last, while nothing is typed or its own name matches', () => {
    expect(placeChoices(ps, '', 'Unassigned').at(-1)).toBeNull();
    expect(placeChoices(ps, 'bug', 'Unassigned').includes(null)).toBe(false);
    expect(placeChoices(ps, 'unas', 'Unassigned')).toEqual([null]);
    expect(placeChoices(ps, '', 'Unassigned', 2)).toHaveLength(3);
  });
  it('the running time', () => {
    expect(clock(4.6)).toBe('0:04');
    expect(clock(75)).toBe('1:15');
  });
});
