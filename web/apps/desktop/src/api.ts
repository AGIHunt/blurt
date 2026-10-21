// Typed wrappers for the Rust commands (contract C8, apps/desktop/src-tauri/src/lib.rs). Outside Tauri (vite dev in a
// browser, unit tests) calls go to ./mock so the UI can be worked on without the app.

import { invoke as tauriInvoke, convertFileSrc } from '@tauri-apps/api/core';
import { listen as tauriListen } from '@tauri-apps/api/event';
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

export function fileSrc(abs: string): string {
  if (inTauri) return convertFileSrc(abs);
  // browser preview: a neutral placeholder instead of the frame
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="400"><rect width="640" height="400" fill="#8884"/><text x="320" y="205" font-family="sans-serif" font-size="18" text-anchor="middle" fill="#888">${abs.split('/').pop()}</text></svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

export function joinPath(dir: string, rel: string): string {
  if (/^([a-zA-Z]:[\\/]|\/)/.test(rel)) return rel;
  const sep = dir.includes('\\') && !dir.includes('/') ? '\\' : '/';
  return dir.replace(/[\\/]+$/, '') + sep + rel.replace(/^[\\/]+/, '').replace(/\//g, sep);
}

// ---- rows (C3 ItemRow + the extra columns the Rust side selects)
export interface ItemRow {
  uid: string;
  session_id: string;
  session_dir: string;
  item_id: string;
  kind: string;
  title: string;
  status: string;
  fix_state: string | null;
  severity: string | null;
  primary_frame: string | null;
  updated: number;
  snippet: string | null;
  workspace_id: string;
  created: number | null;
  session_title: string | null;
  quote: string;
  tags: string;
  frame_count: number;
  has_code_refs: number;
}

export interface ItemQuery {
  query?: string;
  kind?: string[];
  status?: string[];
  fix_state?: string[];
  severity?: string[];
  workspace?: string;
  session?: string;
  has_code_refs?: boolean;
  sort?: 'updated' | 'created' | 't_start';
  limit?: number;
  offset?: number;
}

export interface Workspace {
  id: string;
  path: string;
  name: string;
  kind: 'default' | 'repo';
  sessions: number;
  open_items: number;
}

export interface SessionRow {
  id: string;
  workspace_id: string;
  workspace_name: string;
  workspace_path: string;
  dir: string;
  mode: 'video' | 'shots';
  title: string | null;
  created: number | null;
  duration: number | null;
  shot_count: number;
  item_count: number;
  processed: number;
  processing: number;
  reviewed: number;
  fixed_count: number;
}

export interface Summary {
  missing: boolean;
  items: number;
  sessions: number;
  inbox: number;
  fixing: number;
}

export interface AppStatus {
  version: string;
  os: string;
  platform: 'win' | 'gnome' | 'mac';
  wayland: boolean;
  lang: 'zh' | 'en';
  blurt_home: string;
  index_db: string;
  index_exists: boolean;
  default_workspace: string;
  scripts: string | null;
  uv: string | null;
  capture: { recording: boolean; paused: boolean; session: string | null; engine: string };
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
}

export interface Detect {
  order: string[];
  pick: string | null;
  agents: AgentInfo[];
}

export interface AgentRun {
  run_id: string;
  agent: string;
  repo: string;
  prompt: string;
  state: 'running' | 'done' | 'failed' | 'stopped';
  started: number;
  ended: number | null;
  exit: number | null;
  cost_usd: number | null;
  items: { session: string; id: string }[];
  lines: string[];
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
  hint?: string;
}

export interface HotkeyResult {
  result: 'ok' | 'duplicate' | 'system' | 'taken' | 'invalid';
  action?: string;
  name?: string;
  spec?: string;
  label?: string;
  error?: string;
  hint?: string;
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
  sessions: (q: { workspace?: string; state?: string; limit?: number } = {}) => invoke<SessionRow[]>('index_sessions', { q }),
  workspaces: () => invoke<Workspace[]>('index_workspaces'),
  summary: () => invoke<Summary>('index_summary'),
  item: (uid: string) => invoke<ItemRow | null>('index_item', { uid }),
  rescan: () => invoke<void>('index_rescan'),
  detect: () => invoke<Detect>('agents_detect'),
  runs: () => invoke<AgentRun[]>('agent_runs'),
  stopRun: (runId: string) => invoke<boolean>('agent_stop', { runId }),
  fixWithAgent: (session: string, itemIds: string[], agent?: string) =>
    invoke<{ run_id: string; agent: string; repo: string }>('fix_with_agent', { session, itemIds, agent }),
  processSession: (session: string, agent?: string) => invoke<{ run_id: string; agent: string }>('process_session', { session, agent }),
  prompt: (uids: string[]) => invoke<{ prompt: string }>('agent_prompt', { uids }),
  settings: () => invoke<Settings>('settings_get'),
  setSettings: (patch: Record<string, unknown>) => invoke<Record<string, any>>('settings_set', { patch }),
  setShortcut: (action: string, combo: string) => invoke<HotkeyResult>('shortcut_set', { action, combo }),
  asrModels: () => invoke<{ models: AsrModel[]; models_dir?: string; configured?: unknown }>('asr_models'),
  reveal: (path: string) => invoke<void>('reveal', { path }),
  openExternal: (url: string) => invoke<void>('open_external', { url }),
  captureStart: () => invoke<string>('capture_start', { opts: { pick: true } }),
  captureState: () => invoke<AppStatus['capture']>('capture_state'),
  captureControl: (cmd: string) => invoke<void>('capture_control', { cmd }),
  updateCheck: () => invoke<{ configured: boolean; available?: boolean; version?: string }>('update_check'),
};
