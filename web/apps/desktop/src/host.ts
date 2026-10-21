// The 'tauri' BlurtHost (C6) for one session dir: WP3's adapter (review_load / review_poll / review_ops → items.py
// user-ops, files through the asset protocol) plus what the shell adds — open code refs in the editor and
// "let agent fix" with feedback in the main window. In a plain browser (mock data) the same calls go to ./mock.

import { api, fileSrc, inTauri, invoke, joinPath } from './api';
import { createTauriHost, type BlurtHost, type UserOp } from './review';

export interface HostCallbacks {
  onFixWithAgent?: (session: string, itemIds: string[]) => void;
  onError?: (msg: string) => void;
}

/** `src/app.py:88` / `src/app.py` → an editor URL. The editor comes from config app.editor (vscode | cursor | zed). */
export function codeUrl(repo: string, ref: string, editor = 'vscode'): string {
  const m = ref.match(/^(.*?)(?::(\d+))?(?::(\d+))?$/);
  const file = joinPath(repo, m?.[1] ?? ref).replace(/\\/g, '/');
  const line = m?.[2] ?? '1';
  const path = file.startsWith('/') ? file : `/${file}`;
  if (editor === 'zed') return `zed://file${path}:${line}`;
  return `${editor === 'cursor' ? 'cursor' : 'vscode'}://file${path}:${line}`;
}

export function repoOf(session: string): string | null {
  const m = session.replace(/\\/g, '/').match(/^(.*)\/\.blurt\/sessions\/[^/]+\/?$/);
  return m ? m[1] : null;
}

function mockHost(session: string): BlurtHost {
  return {
    host: 'tauri',
    inApp: true,
    load: () => invoke('review_load', { session }),
    poll: (etag: string) => invoke('review_poll', { session, etag }),
    sendOps: (ops: UserOp[], confirm = false) => invoke('review_ops', { session, ops, confirm }),
    fileUrl: (rel: string) => fileSrc(joinPath(session, rel)),
  };
}

export function tauriHost(session: string, cb: HostCallbacks = {}, editor = 'vscode'): BlurtHost {
  const repo = repoOf(session);
  const base = inTauri ? createTauriHost(session) : mockHost(session);
  return {
    ...base,
    inApp: true,
    sendOps: (ops, confirm) =>
      base.sendOps(ops, confirm).catch((e) => {
        cb.onError?.(String(e));
        throw e;
      }),
    reveal: (rel: string) => void api.reveal(joinPath(session, rel)).catch((e) => cb.onError?.(String(e))),
    openCode: repo ? (ref: string) => void api.openExternal(codeUrl(repo, ref, editor)).catch((e) => cb.onError?.(String(e))) : undefined,
    dispatch: repo && cb.onFixWithAgent ? (ids: string[]) => cb.onFixWithAgent!(session, ids) : undefined, // protocol v3 name (P6); P8 moves this to sessions_dispatch
  };
}
