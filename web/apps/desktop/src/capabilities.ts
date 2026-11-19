// The five things Blurt does, as the one list the main window, Settings, the onboarding and Home follow
// (docs/design/capabilities.md; the Mac's BlurtCore Capabilities.swift, HomeFeed.swift and PhoneChecks.swift; the
// switches themselves live in apps/desktop/src-tauri/src/capabilities.rs). Each can be turned off as a whole, and off
// means gone: its place in the sidebar, its Settings pane, its rows in the palette, the toolbar and the tray. Home and
// Settings → General list all five with their switches. No React here (capabilities.test.ts).
import type { Place } from './places';
import type { RemoteRoute, RemoteStatus } from './api';

export const CAPS = ['dictation', 'cards', 'screen_text', 'recording', 'phone'] as const;
export type Capability = (typeof CAPS)[number];
export type Off = ReadonlySet<Capability>;

export const isCapability = (s: string): s is Capability => (CAPS as readonly string[]).includes(s);
export const offSet = (ids: readonly string[] | null | undefined): Set<Capability> => new Set((ids ?? []).filter(isCapability));

/** The global shortcuts that are a capability's (hotkeys.rs action names; "menu" — Open Blurt — is nobody's). */
export const HOTKEYS: Record<Capability, readonly string[]> = {
  dictation: ['reformat'],
  cards: ['snap', 'voice', 'cards'],
  screen_text: ['text', 'translate'],
  recording: ['record', 'pause', 'pen', 'stop', 'project'],
  phone: [],
};
export const owner = (action: string): Capability | null => CAPS.find((c) => HOTKEYS[c].includes(action)) ?? null;

/** The keys Home and the onboarding show for a capability, one group of caps per shortcut. */
export const SHOWN_KEYS: Record<Capability, readonly string[]> = {
  dictation: [],
  cards: ['snap', 'voice'],
  screen_text: ['text', 'translate'],
  recording: ['record'],
  phone: [],
};

/** The capability a place of the main window belongs to: the items' places and the projects are Recording's. */
export function placeCapability(p: Place): Capability | null {
  if (p === 'home') return null;
  if (p === 'dictation') return 'dictation';
  if (p === 'cards') return 'cards';
  if (p === 'screen_text') return 'screen_text';
  if (p === 'phone') return 'phone';
  return 'recording';
}
export const placeShown = (p: Place, off: Off) => {
  const c = placeCapability(p);
  return !c || !off.has(c);
};

/** The capability a Settings pane is the settings of (null: the app's own panes, always there). */
export function paneCapability(pane: string): Capability | null {
  switch (pane) {
    case 'dictation':
      return 'dictation';
    case 'cards':
      return 'cards';
    case 'screentext':
      return 'screen_text';
    case 'recording':
    case 'projects':
      return 'recording';
    case 'phone':
      return 'phone';
    default:
      return null;
  }
}
export const paneShown = (pane: string, off: Off) => {
  const c = paneCapability(pane);
  return !c || !off.has(c);
};

/** The capability a row belongs to when that isn't its pane's: a shortcut's owner (the Shortcuts pane lists every
 *  capability's keys), the dictation key, and Projects' "new snaps and voice notes go to" (Cards'). */
export function rowCapability(id: string): Capability | null {
  if (id === 'shortcuts.dictation_key' || id === 'shortcuts.dictation') return 'dictation';
  if (id.startsWith('shortcuts.')) return owner(id.slice('shortcuts.'.length));
  if (id === 'projects.capture_into' || id === 'projects.capture') return 'cards';
  if (id === 'speech.dictation' || id === 'speech.polish' || id === 'speech.translate') return 'dictation';
  if (id === 'speech.vision') return 'screen_text';
  return null;
}

/** Whether a row (or a section) is drawn and found: its pane is there and so is the capability it belongs to. The
 *  words at the top of the screen while you speak are dictation's and the voice note's alike: gone only with both. */
export function rowShown(id: string, off: Off): boolean {
  const pane = id.split('.')[0];
  if (!paneShown(pane, off)) return false;
  if (id === 'general.live_text') return !(off.has('dictation') && off.has('cards'));
  const c = rowCapability(id);
  return !c || !off.has(c);
}

/** A capability's switch in General's Features section. */
export const featureRow = (c: Capability) => `general.feature.${c}`;

/** Where a link ("cards", "recording/recording.countdown", "shortcuts/snap") lands with these capabilities off: where it
 *  says, or — its pane or its row being an off capability's — General at that capability's switch. */
export function landing(link: string, off: Off): string {
  const [pane, rest] = link.split('/');
  const c = paneCapability(pane);
  if (c && off.has(c)) return `general/${featureRow(c)}`;
  if (!rest) return link;
  const row = rest.includes('.') ? rest : `${pane}.${rest}`;
  const rc = rowCapability(row);
  if (rc && off.has(rc)) return `general/${featureRow(rc)}`;
  return link;
}

// ---------------------------------------------------------------- Home's Recent (HomeFeed)

export type FeedKind = 'dictation' | 'card' | 'screen_text' | 'recording' | 'item';
export const FEED_KINDS: readonly FeedKind[] = ['dictation', 'card', 'screen_text', 'recording', 'item'];
export const FEED_CAPABILITY: Record<FeedKind, Capability> = { dictation: 'dictation', card: 'cards', screen_text: 'screen_text', recording: 'recording', item: 'recording' };

/** One row of the timeline. `key` is the thing's own id (a dictation's id, a card's "<session>#<n>", a screen text's
 *  id, a recording's folder, an item's uid);
 *  `time` epoch seconds; `source` the quiet line over the text; `text` what was made. */
export interface FeedEntry {
  kind: FeedKind;
  key: string;
  time: number;
  source: string;
  text: string;
  /** what sort of thing it is, for its glyph: an item's kind; a card's shot | voice | file | text; a screen text's
   *  copy | translate; a recording's state (recordings.ts RecState kind) */
  sub?: string;
}
export const feedId = (e: FeedEntry) => `${e.kind}:${e.key}`;

export interface Feed {
  /** newest first, at most the limit */
  entries: FeedEntry[];
  /** the kinds that had rows (before the cut), in the capabilities' order: each gets a "Show all" link */
  kinds: FeedKind[];
  /** the kinds some of whose rows were cut */
  cut: Set<FeedKind>;
}

export const FEED_LIMIT = 40;

/** The lists as one: kinds whose capability is off left out, a thing listed twice once, newest first (rows of one
 *  moment in the capabilities' order, then by key), cut at `limit`. */
export function mergeFeed(lists: { dictations: FeedEntry[]; cards: FeedEntry[]; screenTexts?: FeedEntry[]; recordings?: FeedEntry[]; items: FeedEntry[] }, off: Off, limit = FEED_LIMIT): Feed {
  const order: Record<FeedKind, number> = { dictation: 0, card: 1, screen_text: 2, recording: 3, item: 4 };
  const seen = new Set<string>();
  const all = [...lists.dictations, ...lists.cards, ...(lists.screenTexts ?? []), ...(lists.recordings ?? []), ...lists.items]
    .filter((e) => !off.has(FEED_CAPABILITY[e.kind]))
    .filter((e) => (seen.has(feedId(e)) ? false : (seen.add(feedId(e)), true)))
    .sort((a, b) => b.time - a.time || order[a.kind] - order[b.kind] || (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  const entries = all.slice(0, Math.max(0, limit));
  const kinds = FEED_KINDS.filter((k) => all.some((e) => e.kind === k));
  const cut = new Set(kinds.filter((k) => entries.filter((e) => e.kind === k).length < all.filter((e) => e.kind === k).length));
  return { entries, kinds, cut };
}

/** The rows under their days (each day's first moment, local time), the order kept. */
export function feedDays(entries: FeedEntry[]): { day: number; rows: FeedEntry[] }[] {
  const out: { day: number; rows: FeedEntry[] }[] = [];
  for (const e of entries) {
    const d = new Date(e.time * 1000);
    const day = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime() / 1000;
    const last = out[out.length - 1];
    if (last && last.day === day) last.rows.push(e);
    else out.push({ day, rows: [e] });
  }
  return out;
}

// ---------------------------------------------------------------- the Phone page (PhoneChecks)

export type PhoneHeadline = { kind: 'none' } | { kind: 'not_connected' } | { kind: 'connected'; name: string; viaRelay: boolean; route: RemoteRoute };

/** Something on this computer that stands in a phone's way, each with one fix. */
export type PhoneProblem = 'control' | 'firewall' | 'listen' | 'relay';
export type PhoneTip = 'network' | 'open' | 'vpn' | 'away_none' | 'away_ok' | 'away_go_between';

export function phoneHeadline(r: RemoteStatus): PhoneHeadline {
  if (r.connected) return { kind: 'connected', name: r.connected.name, viaRelay: r.connected.route === 'relay', route: r.connected.route };
  return r.devices.length ? { kind: 'not_connected' } : { kind: 'none' };
}

/** The lines under "This computer", most in the way first; empty: all is well (one line on the page). Control counts
 *  only once a phone is paired (Windows: an elevated window in front; Linux: Remote Desktop not allowed yet — both are
 *  only known once a phone asks); the port only while it should be open. */
export function phoneProblems(r: RemoteStatus): PhoneProblem[] {
  const out: PhoneProblem[] = [];
  const should = r.devices.length > 0 || !!r.pairing;
  if (!r.canControl && r.devices.length > 0) out.push('control');
  if (r.firewall === 'blocked' && should) out.push('firewall');
  if (should && !r.listening && r.problem) out.push('listen');
  if (r.relay.address && r.relay.reachable === false) out.push('relay');
  return out;
}

/** A paired phone would connect and find it can do nothing here (Home's row and the tray say so). */
export const phoneNeedsAttention = (r: RemoteStatus) =>
  r.devices.length > 0 && phoneProblems(r).some((p) => p === 'control' || p === 'listen' || p === 'firewall');

/** What to try while a phone should connect and doesn't, in the order to try it. */
export function phoneTips(r: RemoteStatus): PhoneTip[] {
  if (r.connected || (!r.devices.length && !r.pairing)) return [];
  const near: PhoneTip[] = ['network', 'open', 'vpn'];
  // no relay of the owner's: Blurt's go-between, when it's on (docs/design/remote-go-between.md)
  if (!r.relay.address) return [...near, r.relay.goBetween ? 'away_go_between' : 'away_none'];
  return r.relay.reachable === false ? near : [...near, 'away_ok'];
}
