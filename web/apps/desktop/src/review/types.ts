// The host protocol of the shared review component (contract C6, web/packages/review/src/host.ts in WP3).
// Kept here byte-for-byte in shape so swapping the stub for @blurt/review is a one-line change in ./index.ts.

export type Host = 'browser' | 'macos' | 'tauri';

export interface Frame {
  path: string;
  t?: number;
  caption?: string;
}

export interface FixInfo {
  state: 'fixing' | 'fixed' | 'wontfix' | 'reopened';
  agent: string;
  run_id: string | null;
  commit: string | null;
  pr: string | null;
  note: string;
  at: number;
}

export interface Item {
  id: string;
  uid?: string;
  kind: string;
  title: string;
  quote?: string;
  status?: 'draft' | 'confirmed' | 'deleted';
  severity?: string;
  frames?: Frame[];
  clip?: string;
  tags?: string[];
  code_refs?: string[];
  fix?: FixInfo;
  fix_history?: FixInfo[];
  _user?: Record<string, number>;
  [field: string]: unknown;
}

/** items.json as-is (C1) */
export interface SessionDoc {
  schema?: number;
  session?: string;
  title?: string;
  digest?: string;
  reviewed?: boolean;
  processing?: boolean;
  language?: string;
  items: Item[];
  [k: string]: unknown;
}

export type UserOp =
  | { op: 'set'; id: string; set?: Record<string, unknown>; unset?: string[] }
  | { op: 'remove'; id: string; into: string }
  | { op: 'add'; item: Item; after: string | null };

export interface DragRect {
  rel: string;
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface BlurtHost {
  host: Host;
  load(): Promise<{ doc: SessionDoc; etag: string }>;
  poll(etag: string): Promise<{ doc?: SessionDoc; etag: string }>; // no doc = unchanged
  sendOps(ops: UserOp[], confirm?: boolean): Promise<{ ok: boolean; etag: string }>;
  fileUrl(rel: string): string; // session-relative → loadable URL
  // optional native affordances; the component hides the UI when absent
  reveal?(rel: string): void;
  quickLook?(rel: string): void;
  openCode?(ref: string): void;
  fixWithAgent?(itemIds: string[]): void;
  registerDragRects?(rects: DragRect[]): void;
}

export interface MountOptions {
  mode: 'review' | 'item';
  itemId?: string;
  platform: 'mac' | 'win' | 'gnome';
  theme: 'auto' | 'light' | 'dark';
}

export interface ReviewHandle {
  unmount(): void;
}
