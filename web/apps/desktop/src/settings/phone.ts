// Blurt on the phone, the parts that aren't drawing: one RemoteStatus for the whole window (Settings → Phone and the
// question that shows wherever the window is), the relay address as the Mac reads it (RemoteRelay.address), and the
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

// Settings → Phone shows the question itself while it is open; the window's own dialog waits for it to close.
let paneOpen = 0;
const paneSubs = new Set<(n: number) => void>();
export function usePhonePaneOpen(): boolean {
  const [n, setN] = useState(paneOpen);
  useEffect(() => {
    paneSubs.add(setN);
    return () => {
      paneSubs.delete(setN);
    };
  }, []);
  return n > 0;
}
export function usePhonePaneMounted() {
  useEffect(() => {
    paneOpen++;
    paneSubs.forEach((f) => f(paneOpen));
    return () => {
      paneOpen--;
      paneSubs.forEach((f) => f(paneOpen));
    };
  }, []);
}

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
