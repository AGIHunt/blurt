/* The review canvas's host protocol, v3 (design doc §5 C6 + next-round.md "审核组件宿主协议 v3"). The component talks
   to whatever shows it — review.py's browser page, the macOS main window's WKWebView, the Tauri app — only through
   this interface. It reads both doc shapes: v2 (a session's items.json, paths relative to the session) and v3
   (K1 `items.py doc`: a session or a project, absolute paths, uid identity, work state, projects). */
import type { Platform, ThemePref } from "@blurt/ui";

export type Host = "browser" | "macos" | "tauri";

/** What the canvas shows: one capture session's batch, or a project (or the inbox) with filters (K1 doc scope). */
export type Scope =
  | { session: string }
  | { project: string; status?: string[]; work?: string[]; kind?: string[] };

export interface Frame {
  path: string;
  t?: number | null;
  caption?: string;
}
/** v2 fix record (read only; v3 files carry `work`) */
export interface FixRecord {
  state: "fixing" | "fixed" | "wontfix" | "reopened";
  agent?: string;
  run_id?: string | null;
  commit?: string | null;
  pr?: string | null;
  note?: string;
  at?: number;
}
export type WorkStateName = "todo" | "handed_off" | "in_progress" | "to_verify" | "done" | "wontfix";
/** K3 work record */
export interface WorkRecord {
  state: WorkStateName;
  to?: "session" | "external" | null;
  agent?: string | null;
  job?: string | null;
  handoff?: string | null;
  claim?: "fixed" | "wontfix" | null;
  note?: string;
  commit?: string | null;
  pr?: string | null;
  at?: string | number | null;
  by?: "user" | "agent" | "app";
}
export interface ItemSource {
  type?: "recording" | "snap" | "voice" | "url" | "import" | "service";
  by?: string | null;
  role?: string | null;
  app?: string | null;
  url?: string | null;
  session?: string | null;
  shot?: number | null;
  local_id?: string | null;
  [k: string]: unknown;
}
export interface Item {
  /** display id: "I-001" (v2) or "BA-12" (v3; changes when the item moves project) */
  id: string;
  /** identity (ULID); v3 ops address items by it */
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
  source?: ItemSource;
  merged_from?: string[];
  code_refs?: string[];
  fix?: FixRecord;
  fix_history?: FixRecord[];
  work?: WorkRecord;
  work_history?: WorkRecord[];
  project?: string;
  project_by?: "capture" | "ai" | "user" | "migrate";
  project_confidence?: number | null;
  suggested_project?: { id: string; confidence?: number; reason?: string } | null;
  aliases?: string[];
  created?: string;
  updated?: string;
  /** absolute path of the item's .md (v3) */
  path?: string;
  _user?: Record<string, number>;
  _touched?: boolean;
  _dropped?: boolean;
  [k: string]: unknown;
}
export interface ProjectRef {
  id: string;
  name: string;
  key: string;
  path?: string;
}
export interface ReviewDoc {
  schema?: number;
  /** v3 */
  scope?: Scope;
  /** v2: the session's dir name */
  session?: string;
  title?: string;
  digest?: string;
  language?: string;
  source_video?: string | null;
  processing?: boolean;
  reviewed?: boolean;
  agent_at?: number | string;
  /** false when source_video is missing on disk (shots sessions) */
  _video?: boolean;
  items: Item[];
  _removed?: Record<string, string>;
  /** v3: every project an item can move to (the inbox has id "inbox") */
  projects?: ProjectRef[];
  [k: string]: unknown;
}
/** @deprecated v2 name */
export type SessionDoc = ReviewDoc;

/** What the page sends: only what the user changed (`items.py user-ops`, review.py POST /api/items). `id` is the
    uid on a v3 doc (it survives a project move), the display id on v2. A `set` with `project` moves the item. */
export type UserOp =
  | { op: "set"; id: string; set: Record<string, unknown>; unset: string[] }
  | { op: "remove"; id: string; into: string }
  | { op: "add"; item: Item; after: string | null }
  | { op: "work"; id: string; state: WorkStateName; note?: string };

/** A frame on screen, in CSS px relative to the viewport, so the native layer can make it draggable as a file.
    `rel` is the path as the doc has it (absolute on v3). */
export interface DragRect {
  rel: string;
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface LoadResult {
  doc: ReviewDoc;
  etag: string;
}
export interface PollResult {
  /** absent = unchanged since `etag` */
  doc?: ReviewDoc;
  etag: string;
}
export interface OpsResult {
  ok: boolean;
  etag: string;
  /** the merged doc after the write, when the host has it at no extra cost */
  doc?: ReviewDoc;
}
export interface HandoffResult {
  /** H-0012 */
  id: string;
  path: string;
  /** what was copied */
  text: string;
}

export interface BlurtHost {
  host: Host;
  /** the scope the host serves (load / poll / sendOps are about it); undefined = the session review.py was started on */
  scope?: Scope;
  load(): Promise<LoadResult>;
  poll(etag: string): Promise<PollResult>;
  sendOps(ops: UserOp[], confirm?: boolean): Promise<OpsResult>;
  /** a path from the doc (absolute on v3, session-relative on v2) → a URL the page can load */
  fileUrl(path: string): string;

  // optional native affordances; the component hides the UI when absent
  reveal?(path: string): void;
  quickLook?(path: string): void;
  openCode?(ref: string): void;
  /** open the host's dispatch panel (agent, together / parallel, worktree, the concurrent-edit reminder) for these uids */
  dispatch?(uids: string[]): void;
  /** K6: create a handoff, copy the instruction or the full text, mark the items handed off (external) */
  handoff?(uids: string[], what: "instruction" | "full"): Promise<HandoffResult>;
  /** show the agent session (job id) in the host's terminal */
  openSession?(job: string): void;
  registerDragRects?(rects: DragRect[]): void;
  /** save a file to the user's Downloads (browser: a plain download link instead) */
  download?(path: string): void;
  /** the review was confirmed */
  confirmed?(): void;

  // browser only: hand-written items.json without ids is saved whole, as review.py has always accepted
  saveDoc?(doc: ReviewDoc, confirm?: boolean): Promise<void>;
  /** the browser page's download URL for a file (review.py `?download=1`) */
  downloadUrl?(path: string): string;
  /** inside a Blurt app window (theme follows the system, no theme toggle) */
  inApp?: boolean;
}

export interface MountOptions {
  mode?: "review" | "item";
  /** item mode: the item to show (uid, id or an alias) */
  itemId?: string;
  platform?: Platform;
  theme?: ThemePref;
  /** "en" | "zh" | "zh-Hans"; default: the user's pick, then the doc's language, then the system */
  lang?: string;
  /** inside the app's main window: no brand, theme or language controls, no document title, fills its container */
  embedded?: boolean;
}

export interface ReviewHandle {
  /** item mode: show another item without reloading */
  setItem(itemId: string): void;
  setTheme(theme: ThemePref): void;
  setPlatform(p: Platform): void;
  /** the UI language ("en" | "zh-Hans"; "zh" accepted) */
  setLang(lang: string): void;
  unmount(): void;
}

/** an absolute path (POSIX, Windows drive or UNC) — v3 docs; v2 paths are relative to the session */
export const isAbs = (p: string) => /^(\/|[A-Za-z]:[\\/]|\\\\)/.test(p);
