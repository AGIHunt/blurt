import { describe, expect, it } from 'vitest';
import { pairingLink, pairingPlan, pathLine, rowPlan, type ComputerRow, type Pairing } from './computers';
import { contained, packFrame, parseFrame, toPicture, wheelPoints } from './decode';
import { CATALOGS } from '../i18n';

const row = (o: Partial<ComputerRow>): ComputerRow => ({ id: 'a', name: 'Studio', platform: 'mac', state: 'offline', key: true, route: null, lastSeen: null, windows: 0, ...o });
const failed = (o: Partial<Pairing>): Pairing => ({ name: 'Studio', state: 'failed', digits: null, error: 'unreachable', link: false, ...o });

describe('the list of computers', () => {
  it('says each state with its one button (Remove is in the menu)', () => {
    expect(rowPlan(row({ state: 'connected', route: 'direct' }))).toEqual({ state: 'computers.state.connected', route: 'direct', when: null, action: 'open', warn: false });
    expect(rowPlan(row({ state: 'available', route: 'goBetween' }))).toMatchObject({ state: 'computers.state.available', route: 'goBetween', action: 'connect' });
    expect(rowPlan(row({ state: 'noDirect' }))).toEqual({ state: 'computers.state.no_direct', route: null, when: null, action: 'connect', warn: true });
    expect(rowPlan(row({ state: 'offline', lastSeen: 5 }))).toEqual({ state: 'computers.state.offline', route: null, when: 5, action: 'connect', warn: false });
    expect(rowPlan(row({ state: 'offline' })).state).toBe('computers.state.offline_never');
  });

  it('offers Add Again… for a computer that removed this one, in place of Connect', () => {
    expect(rowPlan(row({ state: 'removed', key: false }))).toEqual({ state: 'computers.state.removed', route: null, when: null, action: 'add', warn: true });
    // refused this run (its key kept): said the same; Connect stays in ⋯ (ComputersGroup)
    expect(rowPlan(row({ state: 'removed', key: true })).action).toBe('add');
  });

  it('says why a pairing failed and what to do next, never a dead end', () => {
    // can't reach: what to check, and Try Again (the same link or computer); a link lasts 10 minutes
    expect(pairingPlan(failed({ error: 'unreachable' }))).toEqual({ title: 'computers.error.unreachable', help: 'computers.error.unreachable.help', retry: true });
    expect(pairingPlan(failed({ error: 'unreachable', link: true })).help).toBe('computers.error.unreachable.help_link');
    // refused before anyone was asked: a link has expired or was used (Back, for a new one); nearby, not now (Try Again)
    expect(pairingPlan(failed({ error: 'spent', link: true }))).toEqual({ title: 'computers.error.spent', help: 'computers.error.new_link', retry: false });
    expect(pairingPlan(failed({ error: 'spent' }))).toEqual({ title: 'computers.error.not_now', help: null, retry: true });
    // a no, and nobody answering, are told apart; a link's code is spent either way, nearby asks again
    expect(pairingPlan(failed({ error: 'declined', link: true }))).toEqual({ title: 'computers.error.declined', help: 'computers.error.new_link', retry: false });
    expect(pairingPlan(failed({ error: 'unanswered' }))).toEqual({ title: 'computers.error.unanswered', help: null, retry: true });
    expect(pairingPlan(failed({ error: 'unanswered', link: true })).retry).toBe(false);
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
    expect([zh['computers.section'], zh['computers.open'], zh['computers.connect'], zh['viewer.keys'], zh['viewer.follow'], zh['feature.phone']]).toEqual(['本机可控制的电脑', '打开窗口', '连接', '按键发往远端', '跟着远端指针换屏', '远程控制']);
    expect([en['computers.section'], en['computers.open'], en['computers.connect'], en['viewer.keys'], en['viewer.follow'], en['feature.phone']]).toEqual(['Computers You Can Control', 'Open Window', 'Connect', 'Keys to Remote', 'Follow the Pointer', 'Remote Control']);
    expect(zh['viewer.hint']).toBe('按 Ctrl+Alt 交还键盘和鼠标');
    expect(zh['computers.state.connected']).toMatch(/^已连接/);
    expect(zh['computers.state.available']).toMatch(/^可连接/);
    expect(zh['computers.state.offline']).toMatch(/^离线/);
    expect([zh['computers.state.no_direct'], en['computers.state.no_direct']]).toEqual(['需要自建中转', 'Needs its own relay']);
    // the Mac's words (Phone.strings), "this Mac" as this computer
    expect([en['computers.error.unanswered'], zh['computers.error.unanswered']]).toEqual(['No one answered on “{1}” in time.', '“{1}”那边没有人及时回应。']);
    expect([en['computers.state.removed'], zh['computers.state.removed'], zh['computers.add_again']]).toEqual(['Removed this computer', '已移除本机', '重新添加…']);
    for (const k of ['spent', 'new_link', 'not_now', 'declined', 'unreachable', 'unreachable.help', 'unreachable.help_link']) expect(en[`computers.error.${k}`], k).toBeTruthy();
    expect(en['computers.error.notTaken']).toBeUndefined();
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

describe('the cover over the picture', () => {
  it('keeps the last picture, darker, through a drop and a lock', async () => {
    const { coverFor } = await import('./ViewerWindow');
    expect(coverFor('connecting', 'Studio', null, false, true)?.kind).toBe('connecting');
    const drop = coverFor('connecting', 'Studio', null, false, true, false, true);
    expect(drop?.kind).toBe('reconnecting');
    expect(drop?.over).toBe(true);
    const lock = coverFor('connected', 'Studio', null, false, true, true, true);
    expect(lock?.kind).toBe('locked');
    expect(lock?.over).toBe(true);
    expect(coverFor('connected', 'Studio', null, false, true, false, true)).toBeNull();
  });

  it('says a computer removed this one, and a refused key the same (Add Again…)', async () => {
    const { coverFor } = await import('./ViewerWindow');
    expect(coverFor('removed', 'Studio', null, false, true)?.kind).toBe('removed');
    expect(coverFor('forgotten', 'Studio', null, false, true)?.kind).toBe('removed');
  });
});
