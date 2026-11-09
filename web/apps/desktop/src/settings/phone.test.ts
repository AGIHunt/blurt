// Settings → Phone: the relay address as the Mac reads it, the code's countdown, the pane's words in both languages,
// search, and the browser stand-in's pairing (code → a phone asks with six digits → Allow → connected).
import { afterEach, describe, expect, it, vi } from 'vitest';
import EN from '../locales/en.json';
import ZH from '../locales/zh-Hans.json';
import { mockInvoke, mockListen } from '../mock';
import type { RemoteStatus } from '../api';
import { MOVED, results } from './catalog';
import { groupDigits, relayAddress, timeLeft } from './phone';

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
    expect(results('phone', 'en')[0]).toMatchObject({ pane: 'phone', paneHit: true });
    expect(results('手机', 'zh-Hans')[0]).toMatchObject({ pane: 'phone', paneHit: true });
    expect(ids('relay')).toContain('phone.relay.address');
    expect(ids('中转', 'zh-Hans')).toContain('phone.relay.address');
    expect(ids('QR')).toContain('phone.add');
    expect(results('trackpad', 'en').map((g) => g.pane)).toContain('phone');
  });
  it('the Mac’s pane name for it lands here', () => {
    expect(MOVED.remote).toBe('phone');
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
  it('a relay address: refused when it isn’t one, cleared with ""', async () => {
    await expect(mockInvoke('remote_set_relay', { address: 'http://x' })).rejects.toBeTruthy();
    let s = await mockInvoke<RemoteStatus>('remote_set_relay', { address: 'wss://relay.example.com' });
    expect(s.relay.address).toBe('wss://relay.example.com');
    s = await mockInvoke<RemoteStatus>('remote_set_relay', { address: '' });
    expect(s.relay.address).toBeNull();
    expect(await mockInvoke<string>('remote_relay_instructions')).toContain('tools/remote-relay');
  });
});
