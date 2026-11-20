// Settings → Remote Control: the relay address as the Mac reads it, the code's countdown, the pane's words in both languages,
// search, and the browser stand-in's pairing (code → a phone asks with six digits → Allow → connected).
import { afterEach, describe, expect, it, vi } from 'vitest';
import EN from '../locales/en.json';
import ZH from '../locales/zh-Hans.json';
import { mockInvoke, mockListen } from '../mock';
import type { RemoteStatus } from '../api';
import { MOVED, redirect, results } from './catalog';
import { awayLine, groupDigits, relayAddress, timeLeft } from './phone';

describe('relay address', () => {
  it('takes what the Mac takes', () => {
    expect(relayAddress('relay.example.com')).toBe('wss://relay.example.com');
    expect(relayAddress('  wss://relay.example.com/ ')).toBe('wss://relay.example.com');
    expect(relayAddress('ws://203.0.113.7:8080')).toBe('ws://203.0.113.7:8080');
    expect(relayAddress('wss://relay.example.com/blurt')).toBe('wss://relay.example.com/blurt');
  });
  it('refuses what isn’t one', () => {
    for (const t of ['', '   ', 'https://relay.example.com', 'wss://', 'wss://relay.example.com?x=1', 'wss://relay.example.com#a', 'relay example.com'])
      expect(relayAddress(t), t).toBeNull();
  });
});

describe('away from home', () => {
  type R = Pick<RemoteStatus, 'connected' | 'relay'>;
  const none: R = { connected: null, relay: { address: null, fromPhone: false, reachable: null, goBetween: true, goBetweenProblem: null, fallback: false } };
  const on = (route: NonNullable<RemoteStatus['connected']>['route']): R => ({ ...none, connected: { id: 'p', name: 'Pixel', route, screen: false } });
  it('a connected phone: the path it uses, whatever else is set', () => {
    for (const route of ['local', 'tailscale', 'overlay', 'direct', 'relay', 'goBetween'] as const)
      expect(awayLine(on(route))).toEqual({ key: 'phone.connected', route: `phone.route.${route}`, warn: false, live: true });
    expect(awayLine({ ...on('local'), relay: { ...none.relay, goBetweenProblem: 'busy' } }).route).toBe('phone.route.local');
  });
  it('the owner’s relay wins over the public connection service', () => {
    expect(awayLine({ ...none, relay: { ...none.relay, address: 'wss://r', reachable: true, goBetweenProblem: 'noDirect' } })).toEqual({ key: 'phone.route.relay', warn: false, live: false });
    expect(awayLine({ ...none, relay: { ...none.relay, address: 'wss://r', reachable: null } }).key).toBe('phone.route.relay');
    expect(awayLine({ ...none, relay: { ...none.relay, address: 'wss://r', reachable: false } })).toEqual({ key: 'phone.away.relay_down', warn: true, live: false });
  });
  it('no relay: the public connection service, or why it couldn’t, or not set', () => {
    expect(awayLine(none)).toEqual({ key: 'phone.route.goBetween', warn: false, live: false });
    expect(awayLine({ ...none, relay: { ...none.relay, goBetweenProblem: 'noDirect' } })).toEqual({ key: 'phone.away.no_direct', warn: true, live: false });
    expect(awayLine({ ...none, relay: { ...none.relay, goBetweenProblem: 'busy' } })).toEqual({ key: 'phone.away.busy', warn: true, live: false });
    expect(awayLine({ ...none, relay: { ...none.relay, goBetween: false, goBetweenProblem: 'busy' } })).toEqual({ key: 'phone.away.off', warn: false, live: false });
  });
  it('every line and route has its words, in both languages', () => {
    const keys = ['local', 'tailscale', 'overlay', 'direct', 'relay', 'goBetween'].map((r) => `phone.route.${r}`)
      .concat(['relay_down', 'no_direct', 'busy', 'off'].map((k) => `phone.away.${k}`), ['phone.away', 'phone.connected', 'phone.relay.own']);
    for (const k of keys) {
      expect((EN as Record<string, string>)[k], k).toBeTruthy();
      expect((ZH as Record<string, string>)[k], k).toBeTruthy();
    }
  });
  it('the words are the founder’s: plain names, no coined terms', () => {
    expect(EN['phone.go_between']).toBe('Public connection service');
    expect(ZH['phone.go_between']).toBe('公共连接服务');
    expect(EN['phone.go_between.detail']).toBe('Free, with no guarantee. If a network can’t connect directly, set up your own relay.');
    expect(ZH['phone.go_between.detail']).toBe('免费，不保证可用。无法直连时，请设置自建中转。');
    expect(ZH['phone.relay.own']).toBe('自建中转（推荐）');
    expect(EN['phone.away.no_direct']).toBe('Can’t connect directly. Set up your own relay on the computer.');
    expect(ZH['phone.away.busy']).toBe('公共连接服务今日已达上限。请稍后再试，或使用自建中转。');
    expect(ZH['phone.away.off']).toBe('未设置');
    const all = JSON.stringify(EN) + JSON.stringify(ZH);
    expect(all).not.toMatch(/牵线|go-between/i);
  });
});

describe('pairing code', () => {
  it('counts down in minutes and seconds, never below zero', () => {
    expect(timeLeft(120_000, 0)).toBe('2:00');
    expect(timeLeft(120_000, 18_500)).toBe('1:42');
    expect(timeLeft(1000, 5000)).toBe('0:00');
  });
  it('shows six digits as two groups', () => {
    expect(groupDigits('482913')).toBe('482 913');
    expect(groupDigits('1234')).toBe('1234');
  });
});

const phoneKeys = Object.keys(EN).filter((k) => k.startsWith('phone.') || k.startsWith('settings.kw.phone') || k === 'settings.kw.pane.phone');
const ph = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(',');

describe('Phone strings', () => {
  it('every one in both languages with the same placeholders', () => {
    expect(phoneKeys.length).toBeGreaterThan(40);
    for (const k of phoneKeys) {
      const zh = (ZH as Record<string, string>)[k];
      expect(zh, k).toBeTruthy();
      expect(ph(zh), k).toBe(ph((EN as Record<string, string>)[k]));
    }
  });
  it('say computer, not Mac, and no marketing words', () => {
    for (const k of phoneKeys) {
      const en = (EN as Record<string, string>)[k];
      const zh = (ZH as Record<string, string>)[k];
      expect(en, k).not.toMatch(/\bMac\b|⌘|⌥|Finder|seamless|effortless|instantly|one[- ]click/i);
      expect(zh, k).not.toMatch(/Mac|一键|随手|轻松|就出字|递给/);
    }
  });
});

describe('Phone in search', () => {
  const ids = (q: string, l: 'en' | 'zh-Hans' = 'en') => results(q, l).flatMap((g) => g.hits.map((h) => h.entry.id));
  it('finds the pane by name, the rows by their words', () => {
    expect(results('remote control', 'en')[0]).toMatchObject({ pane: 'phone', paneHit: true });
    expect(results('phone', 'en')[0]).toMatchObject({ pane: 'phone' });
    expect(results('远程控制', 'zh-Hans')[0]).toMatchObject({ pane: 'phone', paneHit: true });
    expect(results('手机', 'zh-Hans')[0]).toMatchObject({ pane: 'phone' });
    expect(ids('relay')).toContain('phone.relay.address');
    expect(ids('中转', 'zh-Hans')).toContain('phone.relay.address');
    expect(ids('QR')).toContain('phone.devices');
    expect(results('trackpad', 'en').map((g) => g.pane)).toContain('phone');
  });
  it('the Mac’s pane name for it lands here', () => {
    expect(MOVED.remote).toBe('phone');
    // the device lists moved to the page: their old rows land on the row that goes there
    expect([redirect('phone/phone.add'), redirect('phone/phone.computers.add')]).toEqual(['phone/phone.devices', 'phone/phone.devices']);
    expect(ids('computer')).toContain('phone.devices');
    expect(ids('电脑', 'zh-Hans')).toContain('phone.devices');
  });
});

describe('browser stand-in', () => {
  afterEach(() => vi.useRealTimers());
  it('pairs a phone: code, digits, Allow, connected', async () => {
    vi.useFakeTimers();
    const seen: RemoteStatus[] = [];
    const off = mockListen('remote://status', (s) => seen.push(s as RemoteStatus));
    let s = await mockInvoke<RemoteStatus>('remote_status');
    expect(s.devices).toEqual([]);
    expect(s.listening).toBe(false);

    s = await mockInvoke<RemoteStatus>('remote_show_pairing', { on: true });
    expect(s.listening).toBe(true);
    expect(s.pairing?.qrSvg).toMatch(/^<svg[\s\S]*<\/svg>$/);
    expect(s.pairing!.expiresAt - Date.now()).toBe(120_000);

    await vi.advanceTimersByTimeAsync(5000);
    s = seen[seen.length - 1];
    expect(s.pairing).toBeNull();
    expect(s.asking?.digits).toMatch(/^\d{6}$/);

    s = await mockInvoke<RemoteStatus>('remote_answer_pairing', { yes: true, digits: s.asking!.digits });
    expect(s.asking).toBeNull();
    expect(s.devices).toHaveLength(1);
    expect(s.connected?.id).toBe(s.devices[0].id);

    s = await mockInvoke<RemoteStatus>('remote_remove_device', { id: s.devices[0].id });
    expect(s.devices).toEqual([]);
    expect(s.connected).toBeNull();
    off();
  });
  it('Windows Firewall: ?phone=firewall starts blocked, Allow… makes it ok', async () => {
    vi.resetModules();
    vi.stubGlobal('location', { search: '?phone=firewall' });
    try {
      const m = await import('../mock');
      let s = await m.mockInvoke<RemoteStatus>('remote_status');
      expect(s.firewall).toBe('blocked');
      s = await m.mockInvoke<RemoteStatus>('remote_allow_firewall');
      expect(s.firewall).toBe('ok');
    } finally {
      vi.unstubAllGlobals();
      vi.resetModules();
    }
  });
  it('off Windows, or allowed: the firewall is ok', async () => {
    expect((await mockInvoke<RemoteStatus>('remote_status')).firewall).toBe('ok');
  });
  it('the firewall notice in plain words', () => {
    expect(EN['phone.firewall']).toBe('Windows Firewall is blocking phones on this network.');
    expect(ZH['phone.firewall']).toBe('Windows 防火墙挡住了这个网络上的手机。');
    expect(EN['phone.firewall.allow']).toBe('Allow…');
    expect(ZH['phone.firewall.allow']).toBe('允许…');
  });
  it('the go-between switch: on by default, off and on again; a relay keeps it as set', async () => {
    let s = await mockInvoke<RemoteStatus>('remote_status');
    expect(s.relay.goBetween).toBe(true);
    s = await mockInvoke<RemoteStatus>('remote_set_go_between', { on: false });
    expect(s.relay.goBetween).toBe(false);
    expect(awayLine(s).key).toBe('phone.away.off');
    s = await mockInvoke<RemoteStatus>('remote_set_go_between', { on: true });
    expect(awayLine(s).key).toBe('phone.route.goBetween');
    s = await mockInvoke<RemoteStatus>('remote_set_relay', { address: 'wss://relay.example.com' });
    expect(s.relay.goBetween).toBe(true);
    s = await mockInvoke<RemoteStatus>('remote_set_relay', { address: '' });
    expect(s.relay.goBetween).toBe(true);
  });
  it('?phone_away=noDirect: two phones and a computer, no relay, the go-between couldn’t carry the last one', async () => {
    vi.resetModules();
    vi.stubGlobal('location', { search: '?phone_away=noDirect' });
    try {
      const m = await import('../mock');
      const s = await m.mockInvoke<RemoteStatus>('remote_status');
      expect(s.devices).toHaveLength(3);
      expect(s.connected).toBeNull();
      expect(s.relay.address).toBeNull();
      expect(awayLine(s)).toMatchObject({ key: 'phone.away.no_direct', warn: true });
    } finally {
      vi.unstubAllGlobals();
      vi.resetModules();
    }
  });
  it('a relay address: refused when it isn’t one, cleared with ""', async () => {
    await expect(mockInvoke('remote_set_relay', { address: 'http://x' })).rejects.toBeTruthy();
    let s = await mockInvoke<RemoteStatus>('remote_set_relay', { address: 'wss://relay.example.com' });
    expect(s.relay.address).toBe('wss://relay.example.com');
    s = await mockInvoke<RemoteStatus>('remote_set_relay', { address: '' });
    expect(s.relay.address).toBeNull();
    expect(await mockInvoke<string>('remote_relay_instructions')).toContain('tools/remote-relay');
  });
});
