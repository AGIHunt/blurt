// Renaming a paired device or computer in place (remote-1.1.md §6): Enter saves, Esc cancels, an emptied name goes back to the one
// the device gives itself; the name is this computer's alone. The row's field, its ⋯ line, both languages, and the stand-in's list.
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { DeviceRow, nameKey, renamed, renameEntry, type Rename } from './components/DeviceRows';
import { CATALOGS } from './i18n';
import { mockInvoke } from './mock';
import type { ComputersStatus } from './viewer/computers';

const rename = (o: Partial<Rename> = {}): Rename => ({ editing: false, setEditing: () => {}, own: 'DESKTOP-7Q2', save: () => {}, ...o });
const row = (r: Rename) => renderToStaticMarkup(createElement(DeviceRow, { icon: 'screen', name: 'Studio PC', state: null, rename: r }));

describe('the inline rename', () => {
  it('Enter saves, Esc cancels, other keys type', () => {
    expect(nameKey('Enter')).toBe('save');
    expect(nameKey('Escape')).toBe('cancel');
    for (const k of ['a', 'Tab', 'Backspace', ' ']) expect(nameKey(k), k).toBeNull();
  });
  it('sends the name trimmed, nothing when nothing changed, and "" to go back to its own', () => {
    expect(renamed('Studio PC', '  Den PC ', 'save')).toBe('Den PC');
    expect(renamed('Studio PC', 'Den PC', 'cancel')).toBeNull();
    expect(renamed('Studio PC', ' Studio PC', 'save')).toBeNull();
    expect(renamed('Studio PC', '   ', 'save')).toBe('');
  });
  it('the name is a field while renaming, with its own name as the placeholder', () => {
    const at = row(rename());
    expect(at).not.toContain('<input');
    expect(at).toContain('Studio PC');
    const editing = row(rename({ editing: true }));
    expect(editing).toMatch(/<input[^>]*value="Studio PC"/);
    expect(editing).toContain('placeholder="DESKTOP-7Q2"');
    expect(editing).toContain('maxLength="64"');
  });
  it('⋯ → Rename… turns the name into the field', () => {
    let on = false;
    const e = renameEntry(rename({ setEditing: (v) => (on = v) }));
    expect('run' in e && e.label).toBeTruthy();
    if ('run' in e) e.run?.();
    expect(on).toBe(true);
  });
  it('says it in both languages', () => {
    for (const k of ['phone.rename', 'phone.rename.named', 'mw.rename.keys']) {
      expect((CATALOGS.en as Record<string, string>)[k], k).toBeTruthy();
      expect((CATALOGS['zh-Hans'] as Record<string, string>)[k], k).toBeTruthy();
    }
    expect(CATALOGS.en['phone.rename' as keyof typeof CATALOGS.en]).toBe('Rename…');
    expect(CATALOGS['zh-Hans']['phone.rename' as keyof (typeof CATALOGS)['zh-Hans']]).toBe('重命名…');
  });
});

describe('the stand-in list', () => {
  it('keeps a computer’s new name, and an emptied one goes back to the host’s own', async () => {
    const before = await mockInvoke<ComputersStatus>('computers_browse', { on: false });
    const id = before.computers[0].id;
    const own = before.computers[0].name;
    let s = await mockInvoke<ComputersStatus>('computers_rename', { id, name: '  Kitchen Mac ' });
    expect(s.computers.find((c) => c.id === id)).toMatchObject({ name: 'Kitchen Mac', ownName: own });
    s = await mockInvoke<ComputersStatus>('computers_rename', { id, name: '' });
    expect(s.computers.find((c) => c.id === id)?.name).toBe(own);
  });
});
