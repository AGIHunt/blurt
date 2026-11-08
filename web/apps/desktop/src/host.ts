// The review component's host in the main window (protocol v3, contract K1 + "审核组件宿主协议 v3"): the canvas's
// own tauri host (items_doc / items_poll / items_ops / handoff_create by scope, files through the asset protocol)
// plus the shell's navigation — openCode the editor. Hand Off is the copied note for the user's own agent (handoff).
// In a plain browser (mock data) the same calls go to ./mock.

import { api, fileSrc, inTauri, invoke } from './api';
import { createTauriHost, type BlurtHost, type HandoffResult, type Scope, type UserOp } from './review';

export interface HostCallbacks {
  onHandoff?: (r: HandoffResult, what: 'instruction' | 'full') => void;
  onError?: (e: unknown) => void;
  /** Esc on the page with nothing left to cancel, ⇧Tab from its first control: back to the list */
  onFocusList?: () => void;
  /** the page's toast, shown as the window's (one place for the main window's toasts): "undo" when its Undo was
      clicked, "gone" when it went without */
  onToast?: (t: { msg: string; undo: boolean; icon?: string; label?: string }) => Promise<string>;
  /** one undo stack per window: the page's step, Ctrl+Z on the page outside a field, an undone step's item */
  onRegisterUndo?: (label: string) => void;
  onWindowUndo?: (redo: boolean) => void;
  onUndone?: (uid: string) => void;
  /** a file the page saved to Downloads ("" = it couldn't) */
  onDownloaded?: (name: string) => void;
}

/** a path from the doc → absolute (v3 docs are; a v2 session's are relative to it) */
export function absPath(scope: Scope, p: string): string {
  if (/^(\/|[A-Za-z]:[\\/]|\\\\)/.test(p) || !('session' in scope)) return p;
  const s = scope.session;
  const sep = /^[A-Za-z]:\\|\\/.test(s) ? '\\' : '/';
  return s.replace(/[\\/]+$/, '') + sep + p.split('/').join(sep);
}

/** `src/app.py:88` / `src/app.py` → an editor URL. The editor comes from config app.editor (vscode | cursor | zed). */
export function codeUrl(root: string, ref: string, editor = 'vscode'): string {
  const m = ref.match(/^(.*?)(?::(\d+))?(?::(\d+))?$/);
  const rel = (m?.[1] ?? ref).replace(/\\/g, '/');
  const file = /^([a-zA-Z]:)?\//.test(rel) ? rel : `${root.replace(/\\/g, '/').replace(/\/+$/, '')}/${rel.replace(/^\/+/, '')}`;
  const line = m?.[2] ?? '1';
  const path = file.startsWith('/') ? file : `/${file}`;
  if (editor === 'zed') return `zed://file${path}:${line}`;
  return `${editor === 'cursor' ? 'cursor' : 'vscode'}://file${path}:${line}`;
}

function mockHost(scope: Scope): BlurtHost {
  return {
    host: 'tauri',
    inApp: true,
    scope,
    load: () => invoke('items_doc', { scope }),
    poll: (etag: string) => invoke('items_poll', { scope, etag }),
    sendOps: (ops: UserOp[], confirm = false) => invoke('items_ops', { scope, ops, confirm }),
    fileUrl: (p: string) => fileSrc(p),
    handoff: (uids: string[], what: 'instruction' | 'full') => invoke<HandoffResult>('handoff_create', { uids, full: what === 'full' }),
  };
}

/** `projectPath`: the project folder code refs are relative to (none for the inbox). */
export function hostFor(scope: Scope, projectPath: string | null, cb: HostCallbacks = {}, editor = 'vscode'): BlurtHost {
  const base = inTauri ? createTauriHost(scope) : mockHost(scope);
  const fail = (e: unknown) => {
    cb.onError?.(e);
    throw e;
  };
  const abs = (p: string) => absPath(scope, p);
  return {
    ...base,
    inApp: true,
    sendOps: (ops, confirm) => base.sendOps(ops, confirm).catch(fail),
    reveal: (p: string) => void api.reveal(abs(p)).catch(cb.onError),
    // Space / the stage's look button: Windows has no Quick Look — the system's own viewer (as Space in the list)
    quickLook: (p: string) => void api.openPath(abs(p)).catch(cb.onError),
    download: (p: string) => void api.saveToDownloads(abs(p)).then((n) => cb.onDownloaded?.(n), () => cb.onDownloaded?.('')),
    focusList: cb.onFocusList,
    toast: cb.onToast,
    registerUndo: cb.onRegisterUndo,
    windowUndo: cb.onRegisterUndo ? cb.onWindowUndo : undefined,
    undone: cb.onUndone,
    openCode: projectPath ? (ref: string) => void api.openUrl(codeUrl(projectPath, ref, editor)).catch(cb.onError) : undefined,
    handoff: base.handoff
      ? async (uids, what) => {
          const r = await base.handoff!(uids, what).catch(fail);
          cb.onHandoff?.(r, what);
          return r;
        }
      : undefined,
  };
}
