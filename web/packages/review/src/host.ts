/* The review canvas's host protocol, v3 (design doc §5 C6 + next-round.md "审核组件宿主协议 v3"). The component talks
   to whatever shows it — review.py's browser page, the macOS main window's WKWebView, the Tauri app — only through
   this interface. It reads both doc shapes: v2 (a session's items.json, paths relative to the session) and v3
   (K1 `items.py doc`: a session or a project, absolute paths, uid identity, the K3 state, projects). */
import type { Action, Platform, State, ThemePref } from "@blurt/ui";

export type Host = "browser" | "macos" | "tauri";

/** What the canvas shows: one capture session's batch, or a project (or the inbox) with filters (K1 doc scope). */
export type Scope =
  | { session: string }
  | { project: string; state?: string[]; kind?: string[] };

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
/** K3 work record: the latest hand-off's details. The item's state is `Item.state`; a `work_history` entry carries
    the state it had (and pre-v0.7 files keep one in `work.state`, read through stateOf). */
export interface WorkRecord {
  state?: State;
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
  /** K3: new | todo | handed_off | in_progress | to_verify | done | wontfix | discarded (server-owned) */
  state?: State;
  /** a discarded item: where Restore puts it back */
  restore_to?: State;
  /** pre-v0.7 review status (read only: stateOf migrates it) */
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
    uid on a v3 doc (it survives a project move), the display id on v2. A `set` with `project` moves the item.
    `state` (K3): the user's action; undo puts back the exact state it had (`undo: true`). */
export type UserOp =
  | { op: "set"; id: string; set: Record<string, unknown>; unset: string[] }
  | { op: "remove"; id: string; into: string }
  | { op: "add"; item: Item; after: string | null }
  | { op: "state"; id: string; action: Action; note?: string }
  | { op: "state"; id: string; state: State; undo: true };

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

export type ToastIcon = "check" | "x" | "copy" | "folder";

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
  /** the host puts the item's Open Session above the page while it is with an agent (the Mac app's banner): the
      work panel leaves its own out then, so there is one button */
  sessionBanner?: boolean;
  registerDragRects?(rects: DragRect[]): void;
  /** save a file to the user's Downloads (browser: a plain download link instead) */
  download?(path: string): void;
  /** the review was confirmed */
  confirmed?(): void;
  /** the host shows the page's toast itself (the Mac app: on the island, the one place for the main window's toasts);
      resolves "undo" when its Undo was clicked, anything else when it went without one. `label`: the undo step the
      toast is for (its Edit-menu name), so the host's Undo takes back only that step, never a later one */
  toast?(t: { msg: string; undo: boolean; icon?: ToastIcon; label?: string }): Promise<string>;
  /** One undo stack per window (the Mac app): the page's undoable step, named for the Edit menu ("Change State").
      The host calls the handle's undo() / redo() when ⌘Z / ⇧⌘Z reach that step. */
  registerUndo?(label: string): void;
  /** ⌘Z / ⇧⌘Z (or Z, a toast's Undo) on the page outside a text field: the window's undo, whatever step is next */
  windowUndo?(redo: boolean): void;
  /** an undo / redo on the page was about this item (uid): the host shows it if it isn't the one selected */
  undone?(uid: string): void;
  /** Esc with nothing left to cancel: the focus goes back to the host's list (its selection kept) */
  focusList?(): void;

  // browser only: hand-written items.json without ids is saved whole, as review.py has always accepted
  saveDoc?(doc: ReviewDoc, confirm?: boolean): Promise<void>;
  /** the browser page's download URL for a file (review.py `?download=1`) */
  downloadUrl?(path: string): string;
  /** inside a Blurt app window (theme follows the system, no theme toggle) */
  inApp?: boolean;
  /** an agent (review.py) waits for this review's confirmation: "hand it back" is true. In the app it is only when
   * review.py asked for the batch; a review the user started in Blurt hands nothing to anyone. Browser pages are
   * always review.py's. */
  agentWaiting?: boolean;
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
  /** item mode: show another item without reloading. false: the loaded doc doesn't have it — load one that does
      (the page shows "not here" meanwhile, never the item it showed before) */
  setItem(itemId: string): boolean;
  /** the host's ⌘Z / ⇧⌘Z reached a step the page registered (BlurtHost.registerUndo) */
  undo(): void;
  redo(): void;
  /** the host wrote behind the page (its own list's keys, a move): fetch the doc again, in place */
  pollNow(): void;
  /** the host's Return on its list: the title, caret at the end */
  focusTitle(): void;
  setTheme(theme: ThemePref): void;
  setPlatform(p: Platform): void;
  /** the UI language ("en" | "zh-Hans"; "zh" accepted) */
  setLang(lang: string): void;
  unmount(): void;
}

/** an absolute path (POSIX, Windows drive or UNC) — v3 docs; v2 paths are relative to the session */
export const isAbs = (p: string) => /^(\/|[A-Za-z]:[\\/]|\\\\)/.test(p);
