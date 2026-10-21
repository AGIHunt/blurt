// The 'tauri' BlurtHost (C6) for one session dir: reads via review_load / review_poll, writes via review_ops
// (→ items.py user-ops), files through the asset protocol. WP3's package ships its own tauri adapter with the same
// calls; until then the app uses this one.

import { api, fileSrc, invoke, joinPath } from './api';
import type { BlurtHost, SessionDoc, UserOp } from './review';

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

export function tauriHost(session: string, cb: HostCallbacks = {}, editor = 'vscode'): BlurtHost {
  const repo = repoOf(session);
  return {
    host: 'tauri',
    load: () => invoke<{ doc: SessionDoc; etag: string }>('review_load', { session }),
    poll: (etag: string) => invoke<{ doc?: SessionDoc; etag: string }>('review_poll', { session, etag }),
    sendOps: (ops: UserOp[], confirm = false) =>
      invoke<{ ok: boolean; etag: string }>('review_ops', { session, ops, confirm }).catch((e) => {
        cb.onError?.(String(e));
        throw e;
      }),
    fileUrl: (rel: string) => fileSrc(joinPath(session, rel)),
    reveal: (rel: string) => void api.reveal(joinPath(session, rel)).catch((e) => cb.onError?.(String(e))),
    openCode: repo ? (ref: string) => void api.openExternal(codeUrl(repo, ref, editor)).catch((e) => cb.onError?.(String(e))) : undefined,
    fixWithAgent: repo && cb.onFixWithAgent ? (ids: string[]) => cb.onFixWithAgent!(session, ids) : undefined,
  };
}
