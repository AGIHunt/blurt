// Blurt on the phone, the parts that aren't drawing: one RemoteStatus for the whole window (the Remote Control page,
// its Settings pane, and the question that shows wherever the window is), the relay address as the Mac reads it (RemoteRelay.address), and the
// pairing code's time left.
import { useEffect, useState } from 'react';
import { api, onRemoteStatus, type RemoteStatus } from '../api';

let latest: RemoteStatus | null = null;
const subs = new Set<(s: RemoteStatus | null) => void>();
let started = false;

/** Every view's copy of the status: a call or an event updates them all. */
export function publish(s: RemoteStatus | null) {
  latest = s;
  subs.forEach((f) => f(s));
}

function start() {
  if (started) return;
  started = true;
  onRemoteStatus(publish);
  api.remoteStatus().then(publish, () => {});
}

/** The phone's status, kept fresh by `remote://status`; null until the host has answered once. */
export function useRemoteStatus(): RemoteStatus | null {
  const [s, setS] = useState(latest);
  useEffect(() => {
    start();
    subs.add(setS);
    setS(latest);
    return () => {
      subs.delete(setS);
    };
  }, []);
  return s;
}

/** A command that answers with the status: its answer is shown at once (the event follows). */
export const apply = (p: Promise<RemoteStatus>) => p.then((s) => (publish(s), s));

/** What was typed as a relay address, as it will be used ("relay.example.com" → "wss://relay.example.com"), or null
 *  when it isn't one: ws or wss, a host, no query or fragment, no trailing slash (RemoteRelay.address). */
export function relayAddress(typed: string): string | null {
  let t = typed.trim();
  if (!t) return null;
  if (!t.includes('://')) t = `wss://${t}`;
  t = t.replace(/\/+$/, '');
  let u: URL;
  try {
    u = new URL(t);
  } catch {
    return null;
  }
  if (u.protocol !== 'wss:' && u.protocol !== 'ws:') return null;
  if (!u.hostname || /\s/.test(t) || u.search || u.hash || t.includes('?') || t.includes('#')) return null;
  return t;
}

/** A `ws://` address to a host that isn't on the owner's own network (RemoteRelay.plainOverInternet): mobile carriers can
 *  cut plaintext WebSockets mid-session, and the secret path travels in the clear (docs/design/remote-relay-setup.md
 *  §ws:// over mobile data). Local: localhost, *.local and single-label names, loopback, private, link-local, and
 *  100.64/10 (Tailscale, CGNAT), whose traffic Tailscale already encrypts. */
export function plainOverInternet(address: string): boolean {
  let u: URL;
  try {
    u = new URL(address);
  } catch {
    return false;
  }
  if (u.protocol !== 'ws:') return false;
  let h = u.hostname.toLowerCase();
  if (!h) return false;
  if (h.startsWith('[') && h.endsWith(']')) h = h.slice(1, -1);
  if (h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.local')) return false;
  const v4 = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(h);
  if (v4) {
    const [a, b] = [Number(v4[1]), Number(v4[2])];
    if (a === 127 || a === 10 || (a === 192 && b === 168) || (a === 169 && b === 254)) return false;
    if ((a === 172 && b >= 16 && b <= 31) || (a === 100 && b >= 64 && b <= 127)) return false;
    return true;
  }
  if (h.includes(':')) {
    // URL has already normalised it: ::1, fc00::/7 (fc…, fd…), fe80::/10
    return !(h === '::1' || /^f[cd][0-9a-f]{0,2}:/.test(h) || /^fe[89ab][0-9a-f]?:/.test(h));
  }
  return h.includes('.'); // a single-label name only resolves on a local network
}

/** Away from home's status line (docs/design/remote-go-between.md §What each end shows): with a phone connected, the
 *  path it uses; otherwise what a phone on another network would use, or why that won't work. `warn`: something to fix.
 *  The order of ways in is the spec's: the same network, an overlay (Tailscale…), the owner's relay, the go-between. */
/** `key` is the line; `route`, when set, is a path's name for it ("Connected · Direct"). Plain path names, standard state
 *  words; a problem says what's wrong and what to do. */
export type AwayLine = { key: string; route?: string; warn: boolean; live: boolean };
export function awayLine(r: Pick<RemoteStatus, 'connected' | 'relay'>): AwayLine {
  const c = r.connected;
  if (c) return { key: 'phone.connected', route: `phone.route.${c.route}`, warn: false, live: true };
  const line = (key: string, warn = false): AwayLine => ({ key, warn, live: false });
  if (r.relay.address) return r.relay.reachable === false ? line('phone.away.relay_down', true) : line('phone.route.relay');
  if (!r.relay.goBetween) return line('phone.away.off');
  if (r.relay.goBetweenProblem === 'noDirect') return line('phone.away.no_direct', true);
  if (r.relay.goBetweenProblem === 'busy') return line('phone.away.busy', true);
  return line('phone.route.goBetween');
}

/** "1:42": seconds left on the code, never below zero. */
export function timeLeft(expiresAt: number, now: number): string {
  const s = Math.max(0, Math.ceil((expiresAt - now) / 1000));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

/** "482 913": the six digits in two groups, easier to compare with the phone's. */
export const groupDigits = (d: string) => (/^\d{6}$/.test(d) ? `${d.slice(0, 3)} ${d.slice(3)}` : d);

/** Ticks once a second while `on`, for countdowns. */
export function useNow(on: boolean): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!on) return;
    setNow(Date.now());
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [on]);
  return now;
}

/** Where to get the phone app: its build steps until it is in the stores. */
export const APP_PAGES = {
  ios: 'https://github.com/AGIHunt/blurt/tree/main/apps/ios#build-it-yourself',
  android: 'https://github.com/AGIHunt/blurt/tree/main/apps/android#build-it-yourself',
};
