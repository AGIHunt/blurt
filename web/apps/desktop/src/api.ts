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
  sort?: 'updated' | 'created' | 't_start' | 'title' | 'id' | 'kind' | 'state' | 'project';
  /** the sort's direction; none = the key's own (newest first for dates, A to Z for the rest) */
  ascending?: boolean;
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
  /** the In Progress place: handed off + in progress + to verify (older builds: absent) */
  progress?: number;
  discarded?: number;
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
  /** an agent session's items as its hand-off note names them (jobs_list) */
  labels?: { id: string; title: string }[];
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

/** An agent job as the sessions pane reads it (`sessions_rows`): the K4 job, its whole `agent` object, and what the
    page can't read itself — the hand-off sheet's item labels, a worktree folder that's gone, the log, the app runner. */
export interface SessionJob extends Omit<Job, 'agent'> {
  updated?: string | null;
  agent: {
    id: string;
    mode?: string;
    runner?: 'tmux' | 'app' | 'desktop' | string;
    status: AgentStatus;
    status_at?: string | null;
    status_source?: string | null;
    status_message?: string | null;
    tmux?: { name?: string | null; session?: string; window?: string } | null;
    cwd?: string;
    worktree?: { path: string; branch: string; base?: string } | null;
    exit?: number | null;
    handoff?: string | null;
    finish?: { action: string; result?: Record<string, any> | null } | null;
    last_output?: string[];
    changes?: { ahead?: number; dirty?: number } | null;
    started?: boolean;
    model?: string | null;
    stopped_at?: string | null;
    waiting_hint?: string | null;
    continued?: { from?: string } | null;
    desktop?: { mcp?: boolean } | null;
    agent_session_id?: string | null;
  };
  error: (Job['error'] & { fix?: string; reason?: string; reason_i18n?: Record<string, string> }) | null;
  labels: { id: string; title: string }[];
  folder_gone: boolean;
  log: string | null;
  handoff_path: string | null;
  owned: boolean;
  output: boolean;
}

export interface DesktopApp {
  name: string;
  available: boolean;
  /** a running session can continue there (claude --desktop --resume) */
  continue: boolean;
}

export interface SessionRows {
  jobs: SessionJob[];
  panes: Record<string, string> | null;
  terminals: { id: string; name: string }[];
  preferred_terminal: string | null;
  font_size: number | null;
  desktop?: Record<string, DesktopApp>;
}

export interface DispatchWarning {
  code: 'concurrent_edit' | 'no_git' | 'no_tmux' | 'draft_confirmed' | string;
  jobs?: string[];
  items?: string[];
}

export interface DispatchResult {
  ok: boolean;
  jobs: { id: string; project: string; window: string | null; worktree?: string; branch?: string; cwd: string; items: string[]; url?: string }[];
  warnings: DispatchWarning[];
  /** a desktop dry run: is the blurt MCP installed for the agent (false = items need marking by hand) */
  mcp?: boolean | null;
}

export interface DispatchOpts {
  /** the panel just probed the agent's sign-in: sessions.py needn't check again */
  force?: boolean;
  /** "desktop": the agent's desktop app (Claude) — its claude:// link opens there */
  runner?: 'desktop';
  items: string[];
  agent?: string;
  mode?: 'together' | 'parallel';
  worktree?: 'on' | 'off' | 'auto';
  dryRun?: boolean;
  /** the agent's model (agentModels); undefined = the CLI's own setting */
  model?: string;
}

/** `agents.py models ID` */
export interface AgentModels {
  id: string;
  models: { id: string; name: string; description: string; cheap: boolean }[];
  cheapest: string | null;
  cli_default: string | null;
  efforts: string[];
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

export interface DictationModel {
  id: string;
  name: string;
  size_mb: number;
  installed: boolean;
  recommended: boolean;
}
export interface DictationModels {
  recommended: string;
  selected: string;
  ready: boolean;
  models: DictationModel[];
  downloading?: string | null;
}
export interface ModelDownload {
  id: string;
  state: 'running' | 'done' | 'failed';
  done_mb: number;
  total_mb: number;
}
export interface CloudSummary {
  services: { id: string; preset: string; has_key: boolean }[];
  routes: Record<string, { service: string; model: string } | null>;
}

/** onboarding_get: the first-run Welcome (onboarding.rs) */
export interface Onboarding {
  needed: boolean;
  step: number;
  /** uv is there (the speech tools run through it) */
  uv: boolean;
  /** setup.rs's uv install as its events said */
  uv_state: 'running' | 'done' | 'failed' | null;
  /** setup.rs is still to start the first model download */
  first_download_pending: boolean;
  dictation: { available: boolean; key: string; mode: 'auto' | 'tap' | 'hold' | string; enabled: boolean };
}
export interface MicState {
  supported: boolean;
  device: string | null;
  access: 'allowed' | 'denied' | 'unknown';
}
export interface LoginItem {
  supported: boolean;
  enabled: boolean;
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

/** One dictation as `dictation_history` returns it: history.jsonl's entry (the Mac's DictationEntry keys, edits applied
 *  by dictation.py) plus where its recording is. */
export interface DictationEntry {
  id: string;
  /** ISO 8601, local offset */
  t: string;
  app: string | null;
  bundle: string | null;
  duration: number;
  /** what the speech model heard */
  raw: string;
  polished: string | null;
  /** what was typed (or copied): polished, or raw when polish was off or fell back */
  text: string;
  /** the user's correction (the page's Correct) */
  corrected?: string;
  model: string | null;
  fell_back: boolean;
  /** why polish fell back; "asr_failed:<code>" for a take that wasn't recognised */
  reason: string | null;
  insert: 'pasted' | 'copied' | 'none' | 'held' | string;
  /** relative to dictation/ ("audio/<id>.wav") */
  audio: string | null;
  /** the recording on disk, when it is still there (for playback and Retry) */
  audio_path?: string;
  asr_model?: string | null;
  language?: string;
  style?: string;
  terms_applied?: string[];
  item?: string | null;
  item_uid?: string | null;
  [k: string]: unknown;
}
/** A word in $BLURT_HOME/dictation/vocabulary.json (dictation_vocab.py; the Mac's VocabTerm) */
export interface VocabTerm {
  term: string;
  /** active | suggested (learned once, waiting for the user) */
  state: string;
  /** manual | learned | project | default */
  source?: string;
  sounds_like?: string[];
  hits?: number;
  seen?: number;
  /** ISO 8601 */
  added?: string;
}
export interface DictationHistory {
  entries: DictationEntry[];
  retention_days: number;
  enabled: boolean;
  /** dictation's speech model is on this PC (null: not known yet) */
  ready: boolean | null;
  /** Retry runs here (Windows) */
  can_retry: boolean;
}
/** history.jsonl's edit lines, as `dictation_history_edit` takes them */
export type DictationEdit =
  | { op: 'delete'; ids: string[] }
  | { op: 'restore'; entries: DictationEntry[] }
  | { op: 'correct'; id: string; text: string | null }
  | { op: 'clear' };

export const api = {
  status: () => invoke<AppStatus>('app_status'),
  /** captures hanging under the island waiting for a project (the Inbox's notice; `cards://changed` {count}) */
  cardsWaiting: () => invoke<number>('cards_waiting'),
  /** the notice's Choose projects…: the island opens with every card down */
  revealCards: () => invoke<void>('cards_reveal'),
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
  /** Locate… a project whose folder is gone: only its own folder is taken (pick "same") */
  locateProject: (id: string, title: string, near: string) => invoke<{ pick: 'same' | 'other' | 'empty' | 'cancel' }>('projects_locate', { id, title, near }),
  /** the user's K3 action on items (keep, done, send back, discard, …); hand off goes through dispatch / handoff */
  state: (uids: string[], action: Action, note?: string) => invoke('items_state', { uids, action, note }),
  move: (uids: string[], project: string) => invoke('items_move', { uids, project }),
  jobs: (active = false) => invoke<Job[]>('jobs_list', { active }),
  /** `login` false: no sign-in probes (fast); `ids`: only these agents */
  detect: (o: { login?: boolean; ids?: string[] } = {}) => invoke<Detect>('agents_detect', o),
  models: (agent: string) => invoke<AgentModels>('agents_models', { agent }),
  dispatch: (opts: DispatchOpts) => invoke<DispatchResult>('sessions_dispatch', { opts }),
  sessions: (all = false) => invoke<{ sessions: AgentSession[]; owned?: string[] }>('sessions_list', { all }),
  /** `expect` (merge / pr): the diff's `reviewed` token — a worktree that changed since is refused (code changed) */
  finish: (job: string, action: 'diff' | 'merge' | 'pr' | 'discard' | 'keep', expect?: string | null) =>
    invoke<Record<string, any>>('sessions_finish', { job, action, expect: expect ?? null }),
  stopSession: (job: string, kill = false) => invoke('sessions_stop', { job, kill }),
  openExternal: (job: string, terminal?: string | null) => invoke('sessions_open_external', { job, terminal: terminal ?? null }),
  /** ptyId null with ended: what an app-runner session that ended left on screen (Show Output, read only) */
  ptyOpen: (job: string, cols: number, rows: number) =>
    invoke<{ ptyId: number | null; replay: string | null; owned: boolean; ended?: boolean }>('pty_open', { job, cols, rows }),
  /** the sessions pane's agent jobs (SessionsModel) and its memory (ui/terminal.json) */
  sessionRows: () => invoke<SessionRows>('sessions_rows'),
  /** the pane shows this session now; `forget`: Remove Session */
  sessionMemory: (job: string, pane: string | null, forget = false) => invoke<void>('sessions_memory', { job, pane, forget }),
  restartSession: (job: string) => invoke<DispatchResult>('sessions_restart', { job }),
  takeBack: (job: string) => invoke<{ taken_back: string[]; has_changes?: unknown }>('sessions_take_back', { job }),
  openPath: (path: string) => invoke<void>('open_path', { path }),
  /** a copy in the user's Downloads (the detail's ⤓); answers the file's name there */
  saveToDownloads: (path: string) => invoke<string>('save_to_downloads', { path }),
  /** the agents' desktop apps (Claude) and whether each is installed here */
  desktopApps: () => invoke<Record<string, DesktopApp>>('sessions_desktop_apps'),
  /** Go to Claude */
  goDesktop: (agent: string) => invoke<void>('sessions_go_desktop', { agent }),
  desktopCheck: (agent: string) => invoke<{ available: boolean; reason: string | null; version: string | null; mcp: boolean | null }>('sessions_desktop_check', { agent }),
  continueDesktop: (job: string, withoutMcp = false) => invoke<Record<string, any>>('sessions_continue_desktop', { job, withoutMcp }),
  ptyWrite: (ptyId: number, data: string) => invoke<void>('pty_write', { ptyId, data }),
  ptyResize: (ptyId: number, cols: number, rows: number) => invoke<void>('pty_resize', { ptyId, cols, rows }),
  ptyClose: (ptyId: number) => invoke<void>('pty_close', { ptyId }),
  handoff: (uids: string[], full: boolean) => invoke<{ id: string; path: string; text: string }>('handoff_create', { uids, full }),
  settings: () => invoke<Settings>('settings_get'),
  setSettings: (patch: Record<string, unknown>) => invoke<Record<string, any>>('settings_set', { patch }),
  setShortcut: (action: string, combo: string) => invoke<HotkeyResult>('shortcut_set', { action, combo }),
  /** a shortcut field records keys: Blurt's own hotkeys stand down meanwhile (the Mac's HotkeySettings) */
  suspendShortcuts: (on: boolean) => invoke<void>('shortcuts_suspend', { on }),
  /** the main window as the setup assistant (its size, not resizable) while the Welcome shows */
  welcomeWindow: (on: boolean) => invoke<void>('welcome_window', { on }),
  /** every key back to its default, in one write */
  resetShortcuts: () => invoke<HotkeyRow[]>('shortcuts_reset'),
  asrModels: () => invoke<{ models: AsrModel[] }>('asr_models'),
  dictationModels: () => invoke<DictationModels>('dictation_models'),
  modelDownload: (id: string) => invoke<void>('model_download', { id }),
  dictationUse: (id: string | null) => invoke<void>('dictation_use', { id }),
  /** the dictation key pressed in Blurt's own window: the key hook doesn't hear those (engine.rs `forward_key`) */
  dictationKey: (code: string, down: boolean) => invoke<void>('dictation_key_forward', { code, down }),
  dictationHistory: () => invoke<DictationHistory>('dictation_history'),
  dictationEdit: (edit: DictationEdit) => invoke<{ ok: boolean; deleted?: DictationEntry[] }>('dictation_history_edit', { edit }),
  dictationItem: (id: string, project: string | null, lang: string) =>
    invoke<{ item: { id: string; uid: string; title?: string; already?: boolean } }>('dictation_history_item', { id, project, lang }),
  dictationRetry: (id: string) => invoke<{ entry: DictationEntry }>('dictation_retry', { id }),
  copyText: (text: string) => invoke<void>('clipboard_write', { text }),
  cloudSummary: () => invoke<CloudSummary>('cloud_summary'),
  cloudConnect: (preset: string, key: string) =>
    invoke<{ ok: boolean; ms?: number; code?: string; error?: string; summary?: CloudSummary }>('cloud_connect', { preset, key, baseUrl: null }),
  cloudDisconnect: (id: string) => invoke<CloudSummary>('cloud_disconnect', { id }),
  onboarding: () => invoke<Onboarding>('onboarding_get'),
  onboardingStep: (step: number) => invoke<void>('onboarding_step', { step }),
  onboardingFinish: (login: boolean | null) => invoke<LoginItem>('onboarding_finish', { login }),
  onboardingRetrySetup: () => invoke<boolean>('onboarding_retry_setup'),
  mic: () => invoke<MicState>('onboarding_mic'),
  micSettings: () => invoke<void>('onboarding_mic_settings'),
  loginItem: () => invoke<LoginItem>('login_item_get'),
  setLoginItem: (on: boolean) => invoke<LoginItem>('login_item_set', { on }),
  reveal: (path: string) => invoke<void>('reveal', { path }),
  openUrl: (url: string) => invoke<void>('open_external', { url }),
  captureStart: () => invoke<string>('capture_start', { opts: { pick: true } }),
  captureControl: (cmd: string) => invoke<void>('capture_control', { cmd }),
  voice: () => invoke<void>('voice_start'),
  // the main window's writes (docs/design/windows-parity/main-window.md)
  undoState: (uids: string[], to: State) => invoke('items_undo_state', { uids, to }),
  addItem: (project: string, item: Record<string, unknown>) => invoke<{ uid?: string; item?: { uid?: string } } | null>('items_add', { project, item }),
  exportBundle: (uids: string[], name: string, lang: string) => invoke<{ path?: string } | null>('items_export_bundle', { uids, name, lang }),
  pickImages: () => invoke<string[]>('pick_images'),
  removeProject: (id: string) => invoke<Record<string, unknown>>('projects_remove', { id }),
  restoreProject: (removed: unknown) => invoke('projects_restore', { removed }),
  enrich: (uids: string[], project: string | null) => invoke<string>('items_enrich', { uids, project }),
  /** rows dragged out as Windows' own file drag (mainwin.rs); false: not here, the page's own drag goes on */
  dragOut: (uids: string[]) => invoke<boolean>('items_drag_out', { uids }),
  dragOutAvailable: () => invoke<boolean>('items_drag_out_available'),
  /** a pasted / dropped picture's bytes → a temporary file for New Item (its path) */
  saveTempImage: async (f: Blob & { name?: string }) =>
    inTauri
      ? tauriInvoke<string>('save_temp_image', new Uint8Array(await f.arrayBuffer()), { headers: { 'x-name': f.name || 'pasted.png' } })
      : `/tmp/blurt-new-item/${f.name || 'pasted.png'}`,
  updateCheck: () => invoke<{ configured: boolean; available?: boolean; version?: string }>('update_check'),
  // Settings' backends (src-tauri/src/housekeeping.rs; docs/design/windows-parity/settings.md)
  updateInstall: () => invoke<void>('update_install'),
  updateState: () => invoke<{ configured: boolean; pending: string | null }>('update_state'),
  appContract: () => invoke<{ skill: number | null; app: number; mismatch: 'skill_older' | 'app_older' | null }>('app_contract'),
  appContractHelp: () => invoke<void>('app_contract_help'),
  storageScan: () => invoke<StorageScan>('storage_scan'),
  storageTrash: (paths: string[]) => invoke<string[]>('storage_trash', { files: paths }),
  videosTrash: (days: number | null) => invoke<{ count: number; bytes: number }>('videos_trash', { days }),
  videosAutoSet: (days: number | null) => invoke<{ auto_days: number | null }>('videos_auto_set', { days }),
  cloudCurated: () => invoke<{ jobs: Record<string, CuratedOption[]> }>('cloud_curated'),
  cloudJobSet: (job: string, service: string | null, model: string | null) => invoke<CloudSummary>('cloud_job_set', { job, service, model }),
  asrAutoApply: () => invoke<Record<string, unknown>>('asr_auto_apply'),
  agentsRegistry: () => invoke<AgentRegistry>('agents_registry'),
  agentsInstall: (id: string, dryRun: boolean) => invoke<InstallPlan>('agents_install', { id, dryRun }),
  agentsTest: (id: string) => invoke<{ ok: boolean; secs?: number; class?: string | null; timeout?: boolean }>('agents_test', { id }),
  // dictation's microphone and word list (dictation/commands.rs)
  dictationMics: () => invoke<{ default: string | null; devices: string[] }>('dictation_mics'),
  /** an app's icon as Windows shows it (a PNG data URL), null when there is none: dictation/commands.rs `app_icon` */
  appIcon: (exe: string) => invoke<string | null>('app_icon', { exe }),
  dictationWords: () => invoke<{ terms: VocabTerm[] }>('dictation_words'),
  dictationWordsEdit: (op: 'add' | 'remove' | 'rename' | 'accept' | 'reject' | 'restore' | 'suggest', term: string, to?: string) =>
    invoke<Record<string, unknown>>('dictation_words_edit', { op, term, to: to ?? null }),
  feedbackSend: (ids: string[], context: boolean, preview = false) => invoke<Record<string, any>>('feedback_send', { ids, context, preview }),
  /** Volcengine Speech: App ID + Access Token, tested on a short clip, kept as one Credential Manager item */
  cloudConnectSpeech: (appId: string, token: string) =>
    invoke<{ ok: boolean; ms?: number; code?: string; summary?: CloudSummary }>('cloud_connect_speech', { appId, token }),
  cloudSpeechAppId: () => invoke<string | null>('cloud_speech_app_id'),
  modelDownloadCancel: () => invoke<boolean>('model_download_cancel'),
  // Only my voice (housekeeping.rs): the voice profile; the take's progress comes as 'voiceprint://changed'
  voiceprintStatus: () => invoke<VoiceprintStatus>('voiceprint_status'),
  voiceprintPrepare: () => invoke<VoiceprintStatus & { ok: boolean; code?: string }>('voiceprint_prepare'),
  voiceprintStart: () => invoke<void>('voiceprint_start'),
  voiceprintStop: (finish: boolean) => invoke<void>('voiceprint_stop', { finish }),
  voiceprintClear: () => invoke<VoiceprintStatus>('voiceprint_clear'),
  // Set Up with Agent… (control.rs): the instruction, and the live list of what the agent did ('agent-setup://changed')
  agentSetupInstruction: () => invoke<{ guide: string; setup: string }>('agent_setup_instruction'),
  agentSetupState: () => invoke<AgentSetupState>('agent_setup_state'),
  agentSetupStart: (agent: string) => invoke<AgentSetupState>('agent_setup_start', { agent }),
  agentSetupStop: () => invoke<AgentSetupState>('agent_setup_stop'),
  agentSetupDismiss: () => invoke<AgentSetupState>('agent_setup_dismiss'),
};

export interface VoiceprintStatus {
  enrolled: boolean;
  stale: boolean;
  model_ready: boolean;
  recording?: boolean;
}
export interface VoiceprintEvent {
  phase: 'starting' | 'recording' | 'saving' | 'idle';
  progress?: number;
  level?: number;
  can_finish?: boolean;
  failed?: string;
  learned?: boolean;
  enrolled?: boolean;
  stale?: boolean;
}
export interface AgentSetupStep {
  kind: 'connect' | 'use' | 'download' | 'verify' | string;
  subject: string;
  state: 'running' | 'done' | 'failed';
  name?: string;
}
export interface AgentSetupState {
  active: boolean;
  agent: string | null;
  job: string | null;
  steps: AgentSetupStep[];
}

export interface StorageScan {
  folders: { path: string; bytes: number; sessions: number }[];
  videos: { session: string; bytes: number; age_days: number }[];
  models: { path: string; folder: string; bytes: number }[];
  files: { key: string; path: string; bytes: number; removable: boolean }[];
  auto_days: number | null;
  /** free space on Blurt's disk (bytes) */
  available?: number | null;
}
export interface CuratedOption {
  service: string;
  model: string;
  name: string;
  regions?: string[];
  note?: string;
}
export interface AgentDef {
  id: string;
  name: string;
  headless?: boolean;
  fix?: Record<string, string>;
  install?: Record<string, string>;
  processing?: Record<string, unknown>;
  app?: unknown;
}
export interface AgentRegistry {
  agents: AgentDef[];
  failures: { id: string; reason: Record<string, string> }[];
}
export interface InstallChange {
  action: string;
  path?: string;
  target?: string;
  points_to?: string;
  argv?: string[];
  key?: string[];
  ok?: boolean;
  error?: string;
  how?: string;
  what?: string;
  command?: string[];
}
export interface InstallPlan {
  ok?: boolean;
  applied?: boolean;
  changes: InstallChange[];
}
