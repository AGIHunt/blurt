// Typed wrappers for the Rust commands (names fixed by the v0.7 contract, apps/desktop/src-tauri/src/lib.rs). Outside
// Tauri (vite dev in a browser, unit tests) calls go to ./mock so the UI can be worked on without the app.

import { invoke as tauriInvoke, convertFileSrc } from '@tauri-apps/api/core';
import { listen as tauriListen } from '@tauri-apps/api/event';
import type { Action, State } from '@blurt/ui';
import { mockInvoke, mockListen } from './mock';

export const inTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

export function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  return inTauri ? tauriInvoke<T>(cmd, args) : mockInvoke<T>(cmd, args);
}

export function listen<T>(event: string, cb: (payload: T) => void): () => void {
  if (!inTauri) return mockListen(event, cb as (p: unknown) => void);
  let off: (() => void) | null = null;
  let dead = false;
  tauriListen<T>(event, (e) => cb(e.payload)).then((u) => (dead ? u() : (off = u)));
  return () => {
    dead = true;
    off?.();
  };
}

export function fileSrc(abs: string | null | undefined): string {
  if (!abs) return '';
  if (inTauri) return convertFileSrc(abs);
  if (abs.startsWith('data:')) return abs;
  // browser preview: a neutral placeholder instead of the frame
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="400"><rect width="640" height="400" fill="#8884"/></svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

// ---- rows

/** ItemRow v3 (K1; one K3 `state`) + what the list shows besides. Times are epoch seconds. */
export interface ItemRow {
  uid: string;
  project_id: string;
  project_name: string;
  project_key: string;
  session_id: string | null;
  session_dir: string | null;
  path: string;
  item_id: string;
  kind: string;
  title: string;
  state: State;
  work_to: 'session' | 'external' | null;
  work_agent: string | null;
  severity: string | null;
  primary_frame: string | null;
  created: number;
  updated: number;
  snippet: string | null;
  suggested_project: string | null;
  suggested_confidence: number | null;
  project_by: string | null;
  quote: string;
  frame_count: number;
}

export interface ItemQuery {
  query?: string;
  kind?: string[];
  /** K3 states; none = everything but discarded */
  state?: State[];
  severity?: string[];
  /** project id, its path, or "inbox" */
  project?: string;
  session?: string;
  sort?: 'updated' | 'created' | 't_start' | 'title';
  limit?: number;
  offset?: number;
}

export interface ProjectRow {
  id: string;
  name: string;
  key: string;
  slug: string;
  path: string;
  store: string;
  kind: 'repo' | 'folder' | 'inbox';
  exists: boolean;
  description?: string;
  default_agent?: string | null;
  worktree?: boolean;
  pinned?: boolean;
  last_used?: string;
  /** K3 counts over items that aren't discarded: open = new … in progress; inbox = new + to verify */
  items: number;
  open_items: number;
  inbox: number;
  new: number;
  to_verify: number;
}

export interface ProjectList {
  current: string; // "auto" | id
  projects: ProjectRow[];
  inbox: ProjectRow;
}

/** A capture session ("batch"), from index.db. */
export interface BatchRow {
  id: string;
  project_id: string;
  project_name: string;
  project_key: string;
  project_path: string;
  dir: string;
  mode: 'video' | 'shots' | 'voice';
  title: string | null;
  created: number | null;
  duration: number | null;
  shot_count: number;
  item_count: number;
  /** its items still new */
  new_count: number;
  processed: number;
  processing: number;
  reviewed: number;
}

/** index_summary (K3 groups): inbox = "needs you" = new + to verify; active = handed off + in progress. */
export interface Summary {
  missing: boolean;
  items: number;
  inbox: number;
  new: number;
  to_verify: number;
  active: number;
  open: number;
  unassigned: number;
  batches: number;
}

export interface JobStep {
  id: string;
  state: 'pending' | 'running' | 'done' | 'failed' | 'skipped';
  progress?: number | null;
}

/** K4 job, effective state. */
export interface Job {
  id: string;
  type: 'record' | 'snap' | 'voice' | 'process' | 'route' | 'agent';
  state: 'queued' | 'running' | 'done' | 'failed' | 'cancelled';
  project: string | null;
  session: string | null;
  title: string | null;
  items: string[];
  steps: JobStep[];
  progress: number | null;
  created: string;
  started: string | null;
  ended: string | null;
  error: { code: string; message: string } | null;
  agent?: {
    id: string;
    mode: string;
    runner: 'tmux' | 'app';
    status: AgentStatus;
    tmux?: { name: string } | null;
    cwd: string;
    worktree?: { path: string; branch: string; base: string } | null;
    exit?: number | null;
  };
}

export type AgentStatus = 'running' | 'waiting_input' | 'turn_done' | 'exited' | 'error';

/** `sessions.py list` row (K5). */
export interface AgentSession {
  job: string;
  project: string;
  agent: string;
  items: string[];
  window: string | null;
  status: AgentStatus;
  status_at: string | null;
  worktree: string | null;
  branch: string | null;
  cwd: string;
  started: string | null;
  ended: string | null;
  exit: number | null;
  attached?: boolean;
}

export interface DispatchWarning {
  code: 'concurrent_edit' | 'no_git' | 'no_tmux' | 'draft_confirmed' | string;
  jobs?: string[];
  items?: string[];
}

export interface DispatchResult {
  ok: boolean;
  jobs: { id: string; project: string; window: string | null; worktree?: string; branch?: string; cwd: string; items: string[] }[];
  warnings: DispatchWarning[];
}

export interface DispatchOpts {
  items: string[];
  agent?: string;
  mode?: 'together' | 'parallel';
  worktree?: 'on' | 'off' | 'auto';
  dryRun?: boolean;
}

export interface AppStatus {
  version: string;
  os: string;
  platform: 'win' | 'gnome' | 'mac';
  wayland: boolean;
  lang: string;
  blurt_home: string;
  inbox_store: string;
  handoff_dir: string;
  index_ready: boolean;
  scripts: string | null;
  uv: string | null;
  tmux: boolean;
  capture: { recording: boolean; paused: boolean; session: string | null; voice: unknown };
  hotkey_mode: string;
  start_view?: string | null;
}

export interface AgentInfo {
  id: string;
  name: string;
  path: string | null;
  state: string;
  why: string;
  fix: string;
  installed: boolean;
  version: string | null;
  login: 'ok' | 'logged_out' | 'unknown' | 'n/a';
  headless: boolean;
  interactive: string | null;
  session?: boolean;
}

export interface Detect {
  order: string[];
  pick: string | null;
  agents: AgentInfo[];
}

export interface HotkeyRow {
  action: string;
  spec: string;
  label: string;
  default: string;
  active: boolean;
  result: 'ok' | 'off' | 'duplicate' | 'system' | 'taken' | 'idle' | 'unsupported' | 'invalid' | 'portal' | 'pending' | 'manual';
  of?: string;
  name?: string;
  hint_url?: string;
}

export interface HotkeyResult {
  result: 'ok' | 'duplicate' | 'system' | 'taken' | 'invalid';
  action?: string;
  name?: string;
  spec?: string;
  label?: string;
  hint_url?: string;
}

export interface Settings {
  config: Record<string, any>;
  hotkeys: HotkeyRow[];
  hotkey_mode: string;
  wayland: boolean;
  export_targets: { id: string; name: string; configured: boolean; needs?: string }[];
  config_path: string;
}

export interface AsrModel {
  id?: string;
  name?: string;
  backend?: string;
  installed?: boolean;
  size_mb?: number;
  languages?: string[] | string;
  [k: string]: unknown;
}

export const api = {
  status: () => invoke<AppStatus>('app_status'),
  items: (q: ItemQuery) => invoke<{ total: number; items: ItemRow[]; missing: boolean }>('index_query', { q }),
  item: (uid: string) => invoke<ItemRow | null>('index_item', { uid }),
  batches: (q: { project?: string; state?: string; limit?: number } = {}) => invoke<BatchRow[]>('index_sessions', { q }),
  summary: () => invoke<Summary>('index_summary'),
  rescan: () => invoke<void>('index_rescan'),
  projects: () => invoke<ProjectList>('projects_list'),
  addProject: (path: string) => invoke<{ project: ProjectRow }>('projects_add', { path }),
  useProject: (id: string) => invoke('projects_use', { id }),
  setProject: (id: string, patch: Record<string, unknown>) => invoke('projects_set', { id, patch }),
  openFolder: () => invoke<void>('projects_open_folder', { makeCurrent: false }),
  /** the user's K3 action on items (keep, done, send back, discard, …); hand off goes through dispatch / handoff */
  state: (uids: string[], action: Action, note?: string) => invoke('items_state', { uids, action, note }),
  move: (uids: string[], project: string) => invoke('items_move', { uids, project }),
  jobs: (active = false) => invoke<Job[]>('jobs_list', { active }),
  detect: () => invoke<Detect>('agents_detect'),
  dispatch: (opts: DispatchOpts) => invoke<DispatchResult>('sessions_dispatch', { opts }),
  sessions: (all = false) => invoke<{ sessions: AgentSession[]; owned?: string[] }>('sessions_list', { all }),
  finish: (job: string, action: 'diff' | 'merge' | 'pr' | 'discard' | 'keep') => invoke<Record<string, any>>('sessions_finish', { job, action }),
  stopSession: (job: string, kill = false) => invoke('sessions_stop', { job, kill }),
  openExternal: (job: string) => invoke('sessions_open_external', { job }),
  ptyOpen: (job: string, cols: number, rows: number) => invoke<{ ptyId: number; replay: string | null; owned: boolean }>('pty_open', { job, cols, rows }),
  ptyWrite: (ptyId: number, data: string) => invoke<void>('pty_write', { ptyId, data }),
  ptyResize: (ptyId: number, cols: number, rows: number) => invoke<void>('pty_resize', { ptyId, cols, rows }),
  ptyClose: (ptyId: number) => invoke<void>('pty_close', { ptyId }),
  handoff: (uids: string[], full: boolean) => invoke<{ id: string; path: string; text: string }>('handoff_create', { uids, full }),
  settings: () => invoke<Settings>('settings_get'),
  setSettings: (patch: Record<string, unknown>) => invoke<Record<string, any>>('settings_set', { patch }),
  setShortcut: (action: string, combo: string) => invoke<HotkeyResult>('shortcut_set', { action, combo }),
  asrModels: () => invoke<{ models: AsrModel[] }>('asr_models'),
  reveal: (path: string) => invoke<void>('reveal', { path }),
  openUrl: (url: string) => invoke<void>('open_external', { url }),
  captureStart: () => invoke<string>('capture_start', { opts: { pick: true } }),
  captureControl: (cmd: string) => invoke<void>('capture_control', { cmd }),
  voice: () => invoke<void>('voice_start'),
  updateCheck: () => invoke<{ configured: boolean; available?: boolean; version?: string }>('update_check'),
};
