// Overlay host protocol: the overlay pages ↔ crates/blurt-capture (src/overlay.rs mirrors these names).
// In Tauri the pages talk through events; in a plain browser (vite dev, CI screenshots) a mock host replays the
// `?demo=` scenario and logs what the page would send.

export const EV = {
  /** Rust → hud: one C8 status line as-is ({ev: 'started' | 'level' | 'paused' | …}). */
  status: 'blurt://status',
  /** overlay → Rust: {label, action, n?} — hud: pause/resume/snap/stop/discard; perch: copy/remove/process/clear/note. */
  action: 'blurt://action',
  /** picker → Rust: {label, rect: CssRect | null} (null = cancelled). */
  picked: 'blurt://picked',
  /** perch → Rust: {label, rects: CssRect[]} — where the window takes the mouse (elsewhere it is click-through). */
  hitRects: 'blurt://hit-rects',
  /** Rust → perch: PerchOp. */
  perch: 'blurt://perch',
  /** note → Rust: {label, n, text: string | null} (null = skipped). */
  noteDone: 'blurt://note-done',
  /** overlay → Rust: {label, kind} once the page listens (Rust then sends the current state). */
  ready: 'blurt://ready',
} as const;

export type Kind = 'picker' | 'hud' | 'perch' | 'note';

export interface CssRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export type StatusLine =
  | { ev: 'started'; t0: number }
  | { ev: 'level'; rms: number }
  | { ev: 'paused'; t?: number }
  | { ev: 'resumed'; t?: number }
  | { ev: 'snap'; n: number; file: string; t?: number }
  | { ev: 'stopped'; video: string; duration?: number; shots?: number }
  | { ev: 'discarded' }
  | { ev: 'error'; msg: string; code?: string };

export interface Card {
  n: number;
  /** loadable URL of the shot (asset protocol in Tauri) */
  src: string;
  text?: string | null;
  /** "shots/003.png" */
  file?: string;
}

export type PerchOp =
  | { op: 'set'; cards: Card[] }
  | { op: 'add'; card: Card }
  | { op: 'remove'; n: number }
  | { op: 'show'; hold?: number }
  | { op: 'hide' }
  | { op: 'busy'; on: boolean; label?: string };

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
export const lang: 'zh' | 'en' = (params.get('lang') ?? navigator.language).toLowerCase().startsWith('zh') ? 'zh' : 'en';
export const t = (zh: string, en: string) => (lang === 'zh' ? zh : en);

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
