// The capability model the window follows (capabilities.ts; the Mac's CapabilitiesTests, HomeFeedTests,
// PhoneChecksTests): who owns which key, which places and panes go with a capability, where a link lands, Home's
// timeline and the Phone page's reading of the status.
import { describe, expect, it } from 'vitest';
import type { RemoteStatus } from './api';
import {
  CAPS, feedDays, HOTKEYS, landing, mergeFeed, offSet, owner, paneShown, phoneHeadline, phoneNeedsAttention, phoneProblems, phoneTips, placeShown, rowShown,
  type FeedEntry,
} from './capabilities';

const ACTIONS = ['record', 'menu', 'pause', 'snap', 'stop', 'pen', 'voice', 'project', 'cards', 'text', 'translate', 'reformat'];

describe('capabilities', () => {
  it('every global shortcut but Open Blurt has exactly one owner', () => {
    for (const a of ACTIONS) {
      const owners = CAPS.filter((c) => HOTKEYS[c].includes(a));
      expect(owners.length, a).toBe(a === 'menu' ? 0 : 1);
    }
    expect(owner('snap')).toBe('cards');
    expect(owner('project')).toBe('recording');
    expect(owner('menu')).toBeNull();
  });
  it('off is only what the host names, unknown ids dropped', () => {
    expect([...offSet(['cards', 'nonsense'])]).toEqual(['cards']);
    expect(offSet(undefined).size).toBe(0);
  });
  it('the places follow their capability; Home is always there', () => {
    const off = offSet(['recording', 'phone']);
    expect(placeShown('home', off)).toBe(true);
    expect(placeShown('dictation', off)).toBe(true);
    expect(placeShown('phone', off)).toBe(false);
    for (const p of ['inbox', 'progress', 'unassigned', 'all', 'project:p1'] as const) expect(placeShown(p, off), p).toBe(false);
  });
  it('panes and rows go with their capability; the words while you speak go only with both', () => {
    const off = offSet(['cards']);
    expect(paneShown('cards', off)).toBe(false);
    expect(paneShown('general', off)).toBe(true);
    expect(rowShown('shortcuts.snap', off)).toBe(false);
    expect(rowShown('shortcuts.record', off)).toBe(true);
    expect(rowShown('shortcuts.menu', off)).toBe(true);
    expect(rowShown('projects.capture_into', off)).toBe(false);
    expect(rowShown('general.live_text', off)).toBe(true);
    expect(rowShown('general.live_text', offSet(['cards', 'dictation']))).toBe(false);
    expect(paneShown('projects', offSet(['recording']))).toBe(false);
  });
  it("a link into an off capability lands on its switch in General", () => {
    const off = offSet(['cards']);
    expect(landing('cards', off)).toBe('general/general.feature.cards');
    expect(landing('shortcuts/snap', off)).toBe('general/general.feature.cards');
    expect(landing('shortcuts/record', off)).toBe('shortcuts/record');
    expect(landing('recording/recording.countdown', offSet(['recording']))).toBe('general/general.feature.recording');
    expect(landing('speech', off)).toBe('speech');
  });
});

describe("Home's Recent", () => {
  const e = (kind: FeedEntry['kind'], key: string, time: number): FeedEntry => ({ kind, key, time, source: '', text: key });
  it('one timeline, newest first, off kinds left out, a thing once, cut at the limit', () => {
    const f = mergeFeed(
      { dictations: [e('dictation', 'd1', 30), e('dictation', 'd2', 10)], cards: [e('card', 'c1', 20), e('card', 'c1', 20)], items: [e('item', 'i1', 40)] },
      offSet([]),
      3,
    );
    expect(f.entries.map((x) => x.key)).toEqual(['i1', 'd1', 'c1']);
    expect(f.kinds).toEqual(['dictation', 'card', 'item']);
    expect([...f.cut]).toEqual(['dictation']);
    const g = mergeFeed({ dictations: [e('dictation', 'd1', 30)], cards: [], items: [e('item', 'i1', 40)] }, offSet(['recording']));
    expect(g.entries.map((x) => x.key)).toEqual(['d1']);
    expect(g.kinds).toEqual(['dictation']);
  });
  it('rows of one moment keep the capabilities’ order', () => {
    const f = mergeFeed({ dictations: [e('dictation', 'd', 5)], cards: [e('card', 'c', 5)], items: [e('item', 'i', 5)] }, offSet([]));
    expect(f.entries.map((x) => x.kind)).toEqual(['dictation', 'card', 'item']);
  });
  it('days: newest first, the order kept', () => {
    const day = (y: number, m: number, d: number, h: number) => new Date(y, m, d, h).getTime() / 1000;
    const days = feedDays([e('item', 'a', day(2026, 10, 16, 15)), e('item', 'b', day(2026, 10, 16, 9)), e('item', 'c', day(2026, 10, 15, 22))]);
    expect(days.map((d) => d.rows.map((r) => r.key))).toEqual([['a', 'b'], ['c']]);
  });
});

describe('the Phone page', () => {
  const base: RemoteStatus = {
    listening: false, pairing: null, asking: null, devices: [], connected: null, relay: { address: null, fromPhone: false, reachable: null, goBetween: false, goBetweenProblem: null, fallback: false },
    screenAllowed: true, stayAwake: true, battery: false, service: null, canControl: true, problem: null, firewall: 'ok',
  };
  const phone = { id: 'p', name: 'Pixel', lastSeen: null };
  it('one headline', () => {
    expect(phoneHeadline(base)).toEqual({ kind: 'none' });
    expect(phoneHeadline({ ...base, devices: [phone] })).toEqual({ kind: 'not_connected' });
    expect(phoneHeadline({ ...base, devices: [phone], connected: { id: 'p', name: 'Pixel', route: 'relay', screen: false } })).toEqual({ kind: 'connected', name: 'Pixel', viaRelay: true, route: 'relay' });
  });
  it('only what stands in the way, and only once it matters', () => {
    expect(phoneProblems({ ...base, canControl: false })).toEqual([]);
    expect(phoneProblems({ ...base, devices: [phone], canControl: false })).toEqual(['control']);
    expect(phoneProblems({ ...base, devices: [phone], listening: true, firewall: 'blocked' })).toEqual(['firewall']);
    expect(phoneProblems({ ...base, devices: [phone], problem: 'port taken' })).toEqual(['listen']);
    expect(phoneProblems({ ...base, relay: { ...base.relay, address: 'wss://r', reachable: false } })).toEqual(['relay']);
    expect(phoneNeedsAttention({ ...base, devices: [phone], canControl: false })).toBe(true);
    expect(phoneNeedsAttention({ ...base, devices: [phone], relay: { ...base.relay, address: 'wss://r', reachable: false } })).toBe(false);
  });
  it('what to try: only while a phone should connect and doesn’t', () => {
    expect(phoneTips(base)).toEqual([]);
    expect(phoneTips({ ...base, devices: [phone] })).toEqual(['network', 'open', 'vpn', 'away_none']);
    // no relay, the go-between on: that is the way in from other networks
    expect(phoneTips({ ...base, devices: [phone], relay: { ...base.relay, goBetween: true } })).toEqual(['network', 'open', 'vpn', 'away_go_between']);
    expect(phoneTips({ ...base, devices: [phone], relay: { ...base.relay, address: 'wss://r', reachable: true } })).toEqual(['network', 'open', 'vpn', 'away_ok']);
    expect(phoneTips({ ...base, devices: [phone], connected: { id: 'p', name: '', route: 'local', screen: false } })).toEqual([]);
  });
});
