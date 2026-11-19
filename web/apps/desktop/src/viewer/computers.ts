// One computer driving another (docs/design/remote-desktop-viewer.md), the parts that aren't drawing: the list's status from
// src-tauri/src/viewer.rs (`computers://status`), its commands, and the words a row and the window's toolbar show.
import { useEffect, useState } from 'react';
import { invoke, listen, type RemoteRoute } from '../api';

/** noDirect: the public connection service found no direct path last time (until it connects, or Connect tries again) */
export type ComputerState = 'connected' | 'available' | 'noDirect' | 'offline';
export interface ComputerRow {
  id: string;
  name: string;
  platform: 'mac' | 'windows' | 'linux' | null;
  state: ComputerState;
  route: RemoteRoute | null;
  /** unix ms */
  lastSeen: number | null;
  windows: number;
}
export type PairingError = 'unreachable' | 'notTaken' | 'declined' | 'invalid';
export interface ComputersStatus {
  computers: ComputerRow[];
  /** found on this network and not paired yet */
  nearby: { id: string; name: string }[];
  pairing: null | { name: string; state: 'connecting' | 'asking' | 'failed'; digits: string | null; error: PairingError | null };
  browsing: boolean;
}

export const computers = {
  status: () => invoke<ComputersStatus>('computers_status'),
  /** look for computers nearby while the list shows */
  browse: (on: boolean) => invoke<ComputersStatus>('computers_browse', { on }),
  pairNearby: (id: string) => invoke<ComputersStatus>('computers_pair', { nearby: id, link: null }),
  pairLink: (link: string) => invoke<ComputersStatus>('computers_pair', { nearby: null, link }),
  cancelPairing: () => invoke<ComputersStatus>('computers_cancel_pairing'),
  remove: (id: string) => invoke<ComputersStatus>('computers_remove', { id }),
  /** Open Window / Connect */
  open: (id: string) => invoke<ComputersStatus>('computers_open', { id }),
};

let latest: ComputersStatus | null = null;
const subs = new Set<(s: ComputersStatus | null) => void>();
let started = false;

export function publishComputers(s: ComputersStatus | null) {
  latest = s;
  subs.forEach((f) => f(s));
}

/** The list, kept fresh by `computers://status`; null until it has answered once. */
export function useComputers(): ComputersStatus | null {
  const [s, setS] = useState(latest);
  useEffect(() => {
    if (!started) {
      started = true;
      listen<ComputersStatus>('computers://status', publishComputers);
      computers.status().then(publishComputers, () => {});
    }
    subs.add(setS);
    setS(latest);
    return () => {
      subs.delete(setS);
    };
  }, []);
  return s;
}

export const applyComputers = (p: Promise<ComputersStatus>) => p.then((s) => (publishComputers(s), s));

/** A row's state line and its button (the spec's table; Remove is in the row's menu): Connected · <path> → Open Window;
 *  Available · <path> → Connect; Can't Connect Directly → Connect (a fresh try); Offline · <when last seen> → Connect.
 *  Keys into the locale; `route` and `when` fill them. `warn`: the line is a problem. */
export function rowPlan(c: ComputerRow): { state: string; route: RemoteRoute | null; when: number | null; action: 'open' | 'connect'; warn: boolean } {
  if (c.state === 'connected') return { state: 'computers.state.connected', route: c.route ?? 'local', when: null, action: 'open', warn: false };
  if (c.state === 'available') return { state: 'computers.state.available', route: c.route ?? 'local', when: null, action: 'connect', warn: false };
  if (c.state === 'noDirect') return { state: 'computers.state.no_direct', route: null, when: null, action: 'connect', warn: true };
  return { state: c.lastSeen ? 'computers.state.offline' : 'computers.state.offline_never', route: null, when: c.lastSeen, action: 'connect', warn: false };
}

/** A pasted pairing link, as the host makes it (blurtremote://pair?…), trimmed; null when it isn't one. */
export function pairingLink(text: string): string | null {
  const t = text.trim();
  return /^blurtremote:\/\/pair\?\S*\bk=[A-Za-z0-9_-]+/.test(t) && /[?&]mac=/.test(t) ? t : null;
}

/** The toolbar's path and round trip: "直连 · 18 ms". The route's words are the agreed ones (copy.md). */
export function pathLine(routeWord: string, rttMs: number | null): string {
  return rttMs == null ? routeWord : `${routeWord} · ${Math.max(1, Math.round(rttMs))} ms`;
}
