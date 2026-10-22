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
  /** note → Rust: {label, n, text: string | null} (null = skipped). */
  noteDone: 'blurt://note-done',
  /** overlay → Rust: {label, kind} once the page listens (Rust then sends the current state). */
  ready: 'blurt://ready',
} as const;

export type Kind = 'picker' | 'island' | 'note';

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
}

export interface JobRow {
  id: string;
  type: string;
  title?: string | null;
  /** K4 step id under way */
  step?: string | null;
  progress?: number | null;
}

export interface SessionRow {
  job: string;
  /** agents.json id */
  agent: string;
  /** K5: waiting_input | turn_done | error */
  status: string;
  /** item ids the window works on */
  items: string[];
}

/** What the app shows in the island (apps/desktop/src-tauri/src/island.rs `state`). Elapsed times are seconds at `at`
    (epoch seconds) and keep running while not paused. */
export interface IslandState {
  project: ProjectRef | null;
  projects: ProjectRef[];
  toReview: number;
  recording: { elapsed: number | null; paused: boolean; shots: number; at: number } | null;
  voice: { elapsed: number; at: number } | null;
  /** process jobs under way: the hatching egg */
  hatching: number;
  jobs: JobRow[];
  sessions: SessionRow[];
  hotkeys: Partial<Record<'record' | 'snap' | 'voice' | 'project', string>>;
  lang?: string;
  /** tests / demo: start expanded */
  expanded?: boolean;
}

export type IslandOp =
  | { op: 'state'; state: IslandState }
  | { op: 'cards'; cards: Card[] }
  /** a new capture flies up and a thread catches it; pull = straight on into the island (a project is current) */
  | { op: 'card'; card: Card; pull: boolean }
  | { op: 'toast'; kind: 'sorted' | 'failed' | 'error'; n?: number; job?: string; code?: string; type?: string }
  | { op: 'switcher'; open: boolean }
  | { op: 'peek' }
  | { op: 'attention'; job: string; status: string }
  | { op: 'status'; line: StatusLine }
  | { op: 'level'; rms: number };

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
export const plural = (key: string, n: number, p?: Record<string, string | number>) => i18n.plural(key, n, p);
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
