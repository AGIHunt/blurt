// The review component's host in the main window (protocol v3, contract K1 + "审核组件宿主协议 v3"): the canvas's
// own tauri host (items_doc / items_poll / items_ops / handoff_create by scope, files through the asset protocol)
// plus the shell's navigation — dispatch opens the hand-off sheet, openSession the agent's terminal, openCode the
// editor. In a plain browser (mock data) the same calls go to ./mock.

import { api, fileSrc, inTauri, invoke } from './api';
import { createTauriHost, type BlurtHost, type HandoffResult, type Scope, type UserOp } from './review';

export interface HostCallbacks {
  onDispatch?: (uids: string[]) => void;
  onOpenSession?: (job: string) => void;
  onHandoff?: (r: HandoffResult, what: 'instruction' | 'full') => void;
  onError?: (e: unknown) => void;
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
  return {
    ...base,
    inApp: true,
    sendOps: (ops, confirm) => base.sendOps(ops, confirm).catch(fail),
    openCode: projectPath ? (ref: string) => void api.openUrl(codeUrl(projectPath, ref, editor)).catch(cb.onError) : undefined,
    dispatch: cb.onDispatch,
    openSession: cb.onOpenSession,
    handoff: base.handoff
      ? async (uids, what) => {
          const r = await base.handoff!(uids, what).catch(fail);
          cb.onHandoff?.(r, what);
          return r;
        }
      : undefined,
  };
}
