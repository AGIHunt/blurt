// One computer driving another (docs/design/remote-desktop-viewer.md), the parts that aren't drawing: the list's status from
// src-tauri/src/viewer.rs (`computers://status`), its commands, and the words a row and the window's toolbar show.
import { useEffect, useState } from 'react';
import { invoke, listen, type RemoteRoute } from '../api';

/** noDirect: the public connection service found no direct path last time (until it connects, or Connect tries again) */
/** asleep: its relay says it went to sleep (lastSeen is then when) */
/** removed: it removed this computer (its key is gone), or refused this computer's key this run (`key` still true): Add Again */
export type ComputerState = 'connected' | 'available' | 'noDirect' | 'asleep' | 'offline' | 'removed';
export interface ComputerRow {
  id: string;
  /** what this computer calls it: the owner's name for it (rename), else the one its sessions give */
  name: string;
  /** the name the host gives itself: an emptied rename goes back to it */
  ownName?: string;
  platform: 'mac' | 'windows' | 'linux' | null;
  state: ComputerState;
  /** its key is still here (false once it removed this computer in a session) */
  key: boolean;
  route: RemoteRoute | null;
  /** unix ms */
  lastSeen: number | null;
  windows: number;
}
/** How a pairing ended without a key, read from when (the host never says why): unreachable (still trying meanwhile: the digits
 *  replace it if the host asks), spent (refused before anyone was asked), declined (a no), unanswered (nobody answered in the host's
 *  two minutes), invalid (not a pairing link) */
export type PairingError = 'unreachable' | 'spent' | 'declined' | 'unanswered' | 'invalid';
export interface Pairing {
  name: string;
  state: 'connecting' | 'asking' | 'failed';
  digits: string | null;
  error: PairingError | null;
  /** begun from a pasted link (else from a computer found nearby) */
  link: boolean;
}
export interface ComputersStatus {
  computers: ComputerRow[];
  /** found on this network and not paired yet */
  nearby: { id: string; name: string }[];
  pairing: Pairing | null;
  browsing: boolean;
  /** goes up with each Add Again… from a computer's window: the list opens Add Computer */
  addRequests: number;
  /** goes up with each pairing that ended paired: the Add Computer panel's job is done */
  paired: number;
}

export const computers = {
  status: () => invoke<ComputersStatus>('computers_status'),
  /** look for computers nearby while the list shows */
  browse: (on: boolean) => invoke<ComputersStatus>('computers_browse', { on }),
  pairNearby: (id: string) => invoke<ComputersStatus>('computers_pair', { nearby: id, link: null }),
  pairLink: (link: string) => invoke<ComputersStatus>('computers_pair', { nearby: null, link }),
  /** Cancel, or Back to the panel's first page (the link stays in its field) */
  cancelPairing: () => invoke<ComputersStatus>('computers_cancel_pairing'),
  /** the failed panel's Try Again: the same link, or the computer found nearby, once more */
  retryPairing: () => invoke<ComputersStatus>('computers_retry_pairing'),
  /** a computer's window: its computer removed this one; the main window's list opens Add Computer, and the window closes */
  addAgain: () => invoke<ComputersStatus>('computers_add_again'),
  remove: (id: string) => invoke<ComputersStatus>('computers_remove', { id }),
  /** a name this computer alone uses (nothing is sent); '' goes back to the host's own */
  rename: (id: string, name: string) => invoke<ComputersStatus>('computers_rename', { id, name }),
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
 *  Available · <path> → Connect; Needs its own relay → Connect (a fresh try); Offline · <when last seen> → Connect; Removed this
 *  computer → Add Again… (Connect stays in ⋯ while the key is here: a refusal alone, said this run).
 *  Keys into the locale; `route` and `when` fill them. `warn`: the line is a problem. */
export function rowPlan(c: ComputerRow): { state: string; route: RemoteRoute | null; when: number | null; action: 'open' | 'connect' | 'add'; warn: boolean } {
  if (c.state === 'removed') return { state: 'computers.state.removed', route: null, when: null, action: 'add', warn: true };
  if (c.state === 'connected') return { state: 'computers.state.connected', route: c.route ?? 'local', when: null, action: 'open', warn: false };
  if (c.state === 'available') return { state: 'computers.state.available', route: c.route ?? 'local', when: null, action: 'connect', warn: false };
  if (c.state === 'noDirect') return { state: 'computers.state.no_direct', route: null, when: null, action: 'connect', warn: true };
  if (c.state === 'asleep') return { state: 'computers.state.asleep', route: null, when: c.lastSeen, action: 'connect', warn: false };
  return { state: c.lastSeen ? 'computers.state.offline' : 'computers.state.offline_never', route: null, when: c.lastSeen, action: 'connect', warn: false };
}

/** A failed pairing, what the panel says and offers (the Mac's AddComputerView): what went wrong, then what to do, and never a dead
 *  end: Try Again where the same link or nearby computer can still work, else Back to the link field (the link still in it).
 *  Keys into the locale, filled with the computer's name. */
export function pairingPlan(p: Pairing): { title: string; help: string | null; retry: boolean } {
  switch (p.error) {
    case 'unreachable':
      return { title: 'computers.error.unreachable', help: p.link ? 'computers.error.unreachable.help_link' : 'computers.error.unreachable.help', retry: true };
    // a link's code is spent by now whatever happened (Back, for a new one); nearby, asking again is a new question
    case 'spent':
      return p.link ? { title: 'computers.error.spent', help: 'computers.error.new_link', retry: false } : { title: 'computers.error.not_now', help: null, retry: true };
    case 'declined':
    case 'unanswered':
      return { title: `computers.error.${p.error}`, help: p.link ? 'computers.error.new_link' : null, retry: !p.link };
    default:
      return { title: 'computers.error.invalid', help: null, retry: false };
  }
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
