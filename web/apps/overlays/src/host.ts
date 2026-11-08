// Overlay host protocol: the overlay pages ↔ crates/blurt-capture (src/overlay.rs mirrors these names) and the
// Tauri app (apps/desktop/src-tauri/src/island.rs feeds the island). In Tauri the pages talk through events; in a
// plain browser (vite dev, CI screenshots) a mock host replays the `?demo=` scenario and logs what the page sends.
import { createI18n, resolveLang, type I18n } from '@blurt/i18n';
import EN from './locales/en.json';
import ZH from './locales/zh-Hans.json';

export const EV = {
  /** Rust → island: IslandOp */
  island: 'blurt://island',
  /** overlay → Rust: {label, action, …} — island: record / snap / voice / pause / … / card.assign …; see island.ts */
  action: 'blurt://action',
  /** picker → Rust: {label, rect: CssRect | null} (null = cancelled). */
  picked: 'blurt://picked',
  /** island → Rust: {label, rects: CssRect[]} — where the window takes the mouse (elsewhere it is click-through). */
  hitRects: 'blurt://hit-rects',
  /** note → Rust: {label, n, text: string | null} (null = skipped); a fresh snap's note sends its whole outcome
      (note.ts `SnapDone`). */
  noteDone: 'blurt://note-done',
  /** Rust → a fresh snap's note: NoteOp (the picture, the mic's level, the words heard, commit). */
  note: 'blurt://note',
  /** overlay → Rust: {label, kind} once the page listens (Rust then sends the current state). */
  ready: 'blurt://ready',
} as const;

export type Kind = 'picker' | 'island' | 'note' | 'textcard' | 'rec';

export interface CssRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** One C8 status line of a take, as record.py prints it. */
export type StatusLine =
  | { ev: 'started'; t0: number }
  | { ev: 'level'; rms: number }
  | { ev: 'paused'; t?: number }
  | { ev: 'resumed'; t?: number }
  | { ev: 'snap'; n: number; file: string; t?: number }
  | { ev: 'stopped'; video: string; duration?: number; shots?: number }
  | { ev: 'discarded' }
  | { ev: 'error'; msg: string; code?: string };

/** A capture hanging from the island (K7): a screenshot with its note, or a voice note — not in a project yet. */
export interface Card {
  n: number;
  /** when it was captured (epoch seconds) */
  wall?: number | null;
  /** loadable thumbnail URL (asset protocol in Tauri); "" for a voice note */
  src: string;
  text?: string | null;
  /** "shots/003.png" */
  file?: string | null;
  kind?: 'shot' | 'voice';
  /** the shots batch it belongs to */
  session?: string | null;
}

export interface ProjectRef {
  id: string;
  name: string;
  key: string;
  /** false: its folder is gone (moved, renamed, a drive not plugged in) — said so, and choosing it asks where */
  exists?: boolean;
}

export interface JobRow {
  id: string;
  type: string;
  title?: string | null;
  /** K4 step id under way */
  step?: string | null;
  progress?: number | null;
}

/** What the app shows in the island (apps/desktop/src-tauri/src/island.rs `state`). Elapsed times are seconds at `at`
    (epoch seconds) and keep running while not paused. */
export interface IslandState {
  project: ProjectRef | null;
  projects: ProjectRef[];
  toReview: number;
  /** `spotted`: items live.py has drafted so far ("6 snaps · 4 items spotted") */
  recording: { elapsed: number | null; paused: boolean; shots: number; spotted?: number; pen?: boolean; at: number } | null;
  /** `structured`: the note's Structured chip (shown only when the app says); `limit`: its cap in seconds (the time
   *  left in its last minute) */
  voice: { elapsed: number; at: number; hold?: boolean; ends?: 'hold' | 'pause' | 'key'; structured?: boolean; limit?: number } | null;
  /** dictation (apps/desktop/src-tauri/src/dictation): listening while the take listens, else the oldest take's stage */
  dictation?: { phase: 'listening' | 'transcribing' | 'polishing'; elapsed: number; at: number; style?: 'light' | 'structured'; translate?: boolean; /** the translate target's ear label: EN, 中, ⇄ … */ target?: string } | null;
  /** process jobs under way: the hatching egg */
  hatching: number;
  jobs: JobRow[];
  hotkeys: Partial<Record<'record' | 'snap' | 'voice' | 'project' | 'pen', string>>;
  lang?: string;
  /** Settings → General → Cards: the shutter on a snap; what a dragged card carries (paste | caption | picture) */
  cardPrefs?: { snapSound?: boolean; drag?: 'paste' | 'caption' | 'picture' };
  /** tests / demo: start expanded */
  expanded?: boolean;
}

export type IslandOp =
  | { op: 'state'; state: IslandState }
  /** dictation's live text under the island: the finished pieces, then the piece still being said (quieter);
   *  `typed`: the text actually typed, shown ~1.5 s after the stop; empty text hides it */
  | { op: 'live'; text: string; partial?: string; typed?: boolean }
  | { op: 'cards'; cards: Card[] }
  /** a new capture flies up and a thread catches it; pull = straight on into the island (a project is current) */
  /** `from`: where the capture was taken (the island page's CSS px; island.rs screen_to_css) — it flies from there */
  | { op: 'card'; card: Card; pull: boolean; from?: CssRect | null }
  | { op: 'toast'; kind: 'sorted' | 'failed' | 'error'; n?: number; job?: string; code?: string; type?: string }
  /** a card dragged into another app (island.rs): taken, Undo puts it back; `note`: its note went on the clipboard */
  | { op: 'toast'; kind: 'taken'; cards: { n: number; session?: string | null }[]; what?: 'picture' | 'note' | 'text' | 'files' | 'files_note' }
  /** a dictation line: `msg` a catalog key, `vars` its values, `action` one button (sent back as `data-a`); `key` what
   *  it is about (a newer line with the same key replaces it; dictation/flow.rs `toast_keys`), `passive` a tip or a
   *  reminder that never covers another line, `mark` the ok check for a done line */
  | { op: 'toast'; kind: 'dictation'; msg: string; vars?: Record<string, string>; action?: { a: string; label: string; vars?: Record<string, string>; extra?: Record<string, unknown> }; second?: { a: string; label: string; vars?: Record<string, string> }; ms?: number; key?: string; passive?: boolean; mark?: 'mic' | 'check' | 'warning' | 'spinner' | 'folder'; moment?: 'keyboard'; project?: string }
  /** dictation: what the island says under these keys is over */
  | { op: 'toast_drop'; keys: string[] }
  | { op: 'switcher'; open: boolean }
  | { op: 'peek' }
  /** the pointer came over what the island draws, or left all of it (`out`) — the hit tester, ~30 Hz: a pointer that
   *  arrives or leaves in one jump and rests sends the page no mouse event; CSS px */
  | { op: 'hover'; x: number; y: number; out: boolean }
  | { op: 'status'; line: StatusLine }
  | { op: 'level'; rms: number }
  /** the system's drag of a card ended: `dropped` in another app (taken), else `cancel` (it comes back) */
  | { op: 'dragout'; n: number; session?: string | null; result: 'dropped' | 'cancel' }
  /** the cards come down and stay a while (a hotkey, the tray, the main window) */
  /** `open`: the island opens too (the main window's "Choose projects…"), until the pointer has come and gone */
  | { op: 'reveal'; open?: boolean }
  /** a snap was just taken and record.snap_sound is on: the shutter */
  | { op: 'shutter' }
  /** while recording: the newest line live.py heard, as the caption under the island (record.live_caption) */
  | { op: 'caption'; text: string }
  /** a take was just finished (kept): its length, for the ears' ✓ moment (the Mac's RecordingDone) */
  | { op: 'rec_done'; length: string }
  /** the project picker for something else: `title` a catalog key, `current` the place checked (null = Unassigned);
   *  choosing sends the action `rec.move:<id | inbox>|<token>` (a recording's Change, recording.md §6.2) */
  | { op: 'pick'; title: string; current: string | null; token: string }
  /** the Cards panel's History: cards used in other apps in the last 7 days (`taken`, `wall`: epoch seconds) */
  | { op: 'history'; cards: (Card & { taken?: number })[] }
  /** Show Cards: the Cards panel opens (on Current, or History when nothing hangs), or closes when open */
  | { op: 'panel'; toggle?: boolean }
  /** a line from the app: `msg` a catalog key with `vars`, `mark` its leading glyph (island.rs: Locate…) */
  | { op: 'toast'; kind: 'line'; msg: string; vars?: Record<string, string>; mark?: 'check' | 'warning' }
  /** a capture's line (a snap, Copy Text / Translate, a recording, a filing): as `dictation`, but it never leads with
   *  the mic — `mark` the ok check, the attention triangle, or nothing (a working line ending in "…" gets the spinner);
   *  `action.extra` rides along with the button's action */
  | { op: 'toast'; kind: 'capture'; msg: string; vars?: Record<string, string>; action?: { a: string; label: string; extra?: Record<string, unknown> }; ms?: number; key?: string; passive?: boolean; mark?: 'check' | 'warning' | 'peep'; /** where it went: the project's folder in its colour leads the line (`inbox`: Unassigned) */ project?: string }
  /** a picker, a snap's note or a take starting is up: the island steps back; its waiting lines hold until after */
  | { op: 'busy'; on: boolean }
  /** Copy Text / Translate read what was dragged over: Peep thinks in the ear until its line comes */
  | { op: 'working'; on: boolean }
  /** Edit Note is open over a card (snap.rs edit_note): the row stays down so its tail points at a real card */
  | { op: 'editing'; on: boolean };

export interface OverlayHost {
  host: 'tauri' | 'browser';
  label: string;
  emit(event: string, payload: Record<string, unknown>): Promise<void>;
  on<T>(event: string, cb: (payload: T) => void): Promise<() => void>;
}

/** Page parameters: the query string (browser preview) overlaid with what Rust injects (Tauri windows). */
export const params = new URLSearchParams({
  ...Object.fromEntries(new URLSearchParams(location.search)),
  ...((globalThis as { __BLURT_OVERLAY_PARAMS__?: Record<string, string> }).__BLURT_OVERLAY_PARAMS__ ?? {}),
});

/** The overlays' strings (K10): this package's catalogs over @blurt/i18n's common words. */
export let i18n: I18n = createI18n({ en: EN, 'zh-Hans': ZH }, resolveLang(params.get('lang')));
export const t = (key: string, p?: Record<string, string | number>) => i18n.t(key, p);
/** n = 1 takes the `_one` string in every language: Chinese's plural rule is always "other", so "已删除 1 张卡片" said
 *  more than "Deleted" for one card (the same fact, two different lines). */
export const plural = (key: string, n: number, p?: Record<string, string | number>) => {
  const cat = (i18n.lang === 'zh-Hans' ? ZH : EN) as Record<string, unknown>;
  return n === 1 && typeof cat[`${key}_one`] === 'string' ? i18n.t(`${key}_one`, { n, ...p }) : i18n.plural(key, n, p);
};
/** The app may switch language at run time (settings): the island re-renders after this. */
export function setLang(lang: string) {
  if (resolveLang(lang) !== i18n.lang) i18n = createI18n({ en: EN, 'zh-Hans': ZH }, resolveLang(lang));
  document.documentElement.lang = i18n.lang;
}

const inTauri = () => typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

async function tauriHost(): Promise<OverlayHost> {
  const [{ emit, listen }, { getCurrentWebviewWindow }] = await Promise.all([
    import('@tauri-apps/api/event'),
    import('@tauri-apps/api/webviewWindow'),
  ]);
  const label = getCurrentWebviewWindow().label;
  return {
    host: 'tauri',
    label,
    emit: (event, payload) => emit(event, { label, ...payload }),
    on: (event, cb) => listen(event, (e) => cb(e.payload as never)),
  };
}

/** Browser stand-in: records what the page emits (window.__overlaySent) and lets tests / demos push events. */
function browserHost(kind: Kind): OverlayHost {
  type Cb = (p: unknown) => void;
  const subs = new Map<string, Set<Cb>>();
  const w = window as unknown as {
    __overlaySent: { event: string; payload: unknown }[];
    __overlayPush: (event: string, payload: unknown) => void;
  };
  w.__overlaySent = [];
  w.__overlayPush = (event, payload) => subs.get(event)?.forEach((cb) => cb(payload));
  return {
    host: 'browser',
    label: `blurt-overlay-${kind}`,
    async emit(event, payload) {
      w.__overlaySent.push({ event, payload });
      console.debug('[overlay →]', event, payload);
    },
    async on(event, cb) {
      if (!subs.has(event)) subs.set(event, new Set());
      subs.get(event)!.add(cb as Cb);
      return () => subs.get(event)?.delete(cb as Cb);
    },
  };
}

export async function connect(kind: Kind): Promise<OverlayHost> {
  document.documentElement.dataset.platform = params.get('platform') ?? guessPlatform();
  document.documentElement.dataset.kind = kind;
  document.documentElement.lang = i18n.lang;
  if (matchMedia('(prefers-reduced-motion: reduce)').matches || params.has('reduce-motion')) {
    document.documentElement.dataset.reduceMotion = '1';
  }
  return inTauri() ? tauriHost() : browserHost(kind);
}

/** Tell Rust the page listens; in the browser, play the ?demo= scenario instead. */
export async function ready(host: OverlayHost, kind: Kind, demo: (push: (event: string, p: unknown) => void) => void) {
  if (host.host === 'tauri') {
    await host.emit(EV.ready, { kind });
  } else if (params.has('demo')) {
    demo((event, p) => (window as unknown as { __overlayPush: (e: string, p: unknown) => void }).__overlayPush(event, p));
  }
}

function guessPlatform() {
  const ua = navigator.userAgent;
  return /Windows/.test(ua) ? 'win' : /Mac OS X/.test(ua) ? 'mac' : 'gnome';
}

export const reduceMotion = () => document.documentElement.dataset.reduceMotion === '1';
