/* The review canvas's host protocol (design doc §5 C6). The component talks to whatever shows it — review.py's
   browser page, the macOS app's WKWebView, the Tauri app — only through this interface. */
import type { Platform, ThemePref } from "@blurt/ui";

export type Host = "browser" | "macos" | "tauri";

/** items.json v2 as-is (C1); unknown keys are kept and round-tripped. */
export interface Frame {
  path: string;
  t?: number | null;
  caption?: string;
}
export interface FixRecord {
  state: "fixing" | "fixed" | "wontfix" | "reopened";
  agent?: string;
  run_id?: string | null;
  commit?: string | null;
  pr?: string | null;
  note?: string;
  at?: number;
}
export interface Item {
  id: string;
  uid?: string;
  kind?: string;
  title?: string;
  quote?: string;
  time?: { start: number; end: number } | null;
  frames?: Frame[];
  clip?: string;
  status?: "draft" | "confirmed" | "deleted";
  severity?: string;
  type?: string;
  questions?: string[];
  answer?: string;
  tags?: string[];
  source?: { url?: string; [k: string]: unknown };
  merged_from?: string[];
  code_refs?: string[];
  fix?: FixRecord;
  fix_history?: FixRecord[];
  _user?: Record<string, number>;
  _touched?: boolean;
  _dropped?: boolean;
  [k: string]: unknown;
}
export interface SessionDoc {
  schema?: number;
  session?: string;
  title?: string;
  digest?: string;
  language?: string;
  source_video?: string;
  processing?: boolean;
  reviewed?: boolean;
  agent_at?: number;
  /** review.py adds it: false when source_video is missing on disk (shots sessions) */
  _video?: boolean;
  items: Item[];
  [k: string]: unknown;
}

/** What the page sends: only what the user changed (same ops as `items.py user-ops` and review.py POST /api/items). */
export type UserOp =
  | { op: "set"; id: string; set: Record<string, unknown>; unset: string[] }
  | { op: "remove"; id: string; into: string }
  | { op: "add"; item: Item; after: string | null };

/** A frame on screen, in CSS px relative to the viewport, so the native layer can make it draggable as a file. */
export interface DragRect {
  rel: string;
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface LoadResult {
  doc: SessionDoc;
  etag: string;
}
export interface PollResult {
  /** absent = unchanged since `etag` */
  doc?: SessionDoc;
  etag: string;
}
export interface OpsResult {
  ok: boolean;
  etag: string;
  /** the merged file after the write, when the host has it at no extra cost (review.py returns it) */
  doc?: SessionDoc;
}

export interface BlurtHost {
  host: Host;
  load(): Promise<LoadResult>;
  poll(etag: string): Promise<PollResult>;
  sendOps(ops: UserOp[], confirm?: boolean): Promise<OpsResult>;
  /** session-relative path → a URL the page can load */
  fileUrl(rel: string): string;

  // optional native affordances; the component hides the UI when absent
  reveal?(rel: string): void;
  quickLook?(rel: string): void;
  openCode?(ref: string): void;
  fixWithAgent?(itemIds: string[]): void;
  registerDragRects?(rects: DragRect[]): void;
  /** save a session file to the user's Downloads (browser: a plain download link instead) */
  download?(rel: string): void;
  /** the review was confirmed; the host may close its window */
  confirmed?(): void;

  // browser only: hand-written items.json without ids is saved whole, as review.py has always accepted
  saveDoc?(doc: SessionDoc, confirm?: boolean): Promise<void>;
  /** the browser page's download URL for a file (review.py `?download=1`) */
  downloadUrl?(rel: string): string;
  /** inside a Blurt app window (theme follows the system, no theme toggle) */
  inApp?: boolean;
}

export interface MountOptions {
  mode?: "review" | "item";
  /** item mode: the item to show (item id or uid) */
  itemId?: string;
  platform?: Platform;
  theme?: ThemePref;
  /** "en" | "zh"; default: the user's pick, then items.json language, then the browser */
  lang?: string;
}

export interface ReviewHandle {
  /** item mode: show another item without reloading */
  setItem(itemId: string): void;
  setTheme(theme: ThemePref): void;
  setPlatform(p: Platform): void;
  unmount(): void;
}
