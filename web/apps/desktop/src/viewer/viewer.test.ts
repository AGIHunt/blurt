import { describe, expect, it } from 'vitest';
import { pairingLink, pathLine, rowPlan, type ComputerRow } from './computers';
import { contained, packFrame, parseFrame, toPicture, wheelPoints } from './decode';
import { CATALOGS } from '../i18n';

const row = (o: Partial<ComputerRow>): ComputerRow => ({ id: 'a', name: 'Studio', platform: 'mac', state: 'offline', route: null, lastSeen: null, windows: 0, ...o });

describe('the list of computers', () => {
  it('says each state with its one button', () => {
    expect(rowPlan(row({ state: 'connected', route: 'direct' }))).toEqual({ state: 'computers.state.connected', route: 'direct', when: null, action: 'open' });
    expect(rowPlan(row({ state: 'available', route: 'goBetween' }))).toMatchObject({ state: 'computers.state.available', route: 'goBetween', action: 'connect' });
    expect(rowPlan(row({ state: 'offline', lastSeen: 5 }))).toEqual({ state: 'computers.state.offline', route: null, when: 5, action: 'remove' });
    expect(rowPlan(row({ state: 'offline' })).state).toBe('computers.state.offline_never');
  });

  it('takes a pasted pairing link and nothing else', () => {
    const l = 'blurtremote://pair?v=1&mac=H1&id=D1&k=abcDEF_-12&n=Studio&p=4242&a=192.168.1.2';
    expect(pairingLink(`  ${l}\n`)).toBe(l);
    expect(pairingLink('https://example.com/pair')).toBeNull();
    expect(pairingLink('blurtremote://pair?v=1&id=D1')).toBeNull();
  });

  it('names the path and the round trip as the toolbar shows them', () => {
    expect(pathLine('直连', 18.4)).toBe('直连 · 18 ms');
    expect(pathLine('Same network', 0.3)).toBe('Same network · 1 ms');
    expect(pathLine('Own relay', null)).toBe('Own relay');
  });

  it('has every word in both languages, with the agreed terms', () => {
    const en = CATALOGS.en as Record<string, string>;
    const zh = CATALOGS['zh-Hans'] as Record<string, string>;
    const keys = Object.keys(en).filter((k) => k.startsWith('computers.') || k.startsWith('viewer.'));
    expect(keys.length).toBeGreaterThan(40);
    for (const k of keys) expect(zh[k], k).toBeTruthy();
    // copy.md's agreed terms
    expect([zh['computers.section'], zh['computers.open'], zh['computers.connect'], zh['viewer.keys'], zh['viewer.follow'], zh['phone.pane.title']]).toEqual(['电脑', '打开窗口', '连接', '按键发往远端', '跟着远端指针换屏', '手机和电脑']);
    expect([en['computers.section'], en['computers.open'], en['computers.connect'], en['viewer.keys'], en['viewer.follow'], en['phone.pane.title']]).toEqual(['Computers', 'Open Window', 'Connect', 'Keys to Remote', 'Follow the Pointer', 'Phones and Computers']);
    expect(zh['viewer.hint']).toBe('按 Ctrl+Alt 交还键盘和鼠标');
    expect(zh['computers.state.connected']).toMatch(/^已连接/);
    expect(zh['computers.state.available']).toMatch(/^可连接/);
    expect(zh['computers.state.offline']).toMatch(/^离线/);
  });
});

describe('the picture', () => {
  it('reads frames as the app packs them', () => {
    const data = new Uint8Array([0, 0, 0, 1, 0x67, 1, 2]);
    const f = parseFrame(packFrame({ id: 0xfffffffe, key: true, codec: 'avc1.640028', data }))!;
    expect(f.id).toBe(0xfffffffe);
    expect(f.key).toBe(true);
    expect(f.codec).toBe('avc1.640028');
    expect([...f.data]).toEqual([...data]);
    expect(parseFrame(new Uint8Array([2, 0, 0, 0, 0, 0, 0]).buffer)).toBeNull();
    expect(parseFrame(new Uint8Array([1, 0]).buffer)).toBeNull();
  });

  it('letterboxes and maps the pointer onto the picture', () => {
    // a 16:9 picture in a 1000 × 1000 box: bands top and bottom
    const r = contained(1000, 1000, 1600, 900);
    expect(r).toEqual({ x: 0, y: 218.75, w: 1000, h: 562.5 });
    expect(toPicture(500, 500, r)).toEqual({ x: 0.5, y: 0.5 });
    expect(toPicture(500, 100, r)).toBeNull();
    expect(toPicture(0, 218.75, r)).toEqual({ x: 0, y: 0 });
  });

  it('turns the wheel into points in the content’s direction', () => {
    expect(wheelPoints({ deltaX: 0, deltaY: 100, deltaMode: 0 }, 800)).toEqual({ dx: -0, dy: -100 });
    expect(wheelPoints({ deltaX: 2, deltaY: -3, deltaMode: 1 }, 800)).toEqual({ dx: -32, dy: 48 });
    expect(wheelPoints({ deltaX: 0, deltaY: 1, deltaMode: 2 }, 800)).toEqual({ dx: -0, dy: -800 });
  });
});
