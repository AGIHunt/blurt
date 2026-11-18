/* tauri host (C6 / C8, protocol v3): invoke('items_doc' | 'items_poll' | 'items_ops' | 'handoff_create' | 'review_file' |
   'items_add_files', …) with the scope. A file is shown in its folder (or opened in its default app: Windows and Linux
   have no Quick Look) only when a doc the page loaded names it — an item's attached PDF may be anywhere on disk, but
   the page can't reveal or open any other path (review_file). Uses the IPC global Tauri 2 always injects (__TAURI_INTERNALS__), so the canvas needs no
   @tauri-apps/api import. Files load through the asset protocol (convertFileSrc), which the shell scopes to the
   registered stores, session dirs and $BLURT_HOME/handoff. Hand off is `handoff_create` (handoff.py --to external
   --mark; the shell copies the instruction or the full text). */
import { isAbs, type BlurtHost, type HandoffResult, type LoadResult, type OpsResult, type PollResult, type Scope, type UserOp } from "../host";

interface Internals {
  invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T>;
  convertFileSrc?(path: string, protocol?: string): string;
}
type W = Window & {
  __TAURI_INTERNALS__?: Internals;
  __TAURI__?: { core?: { invoke: Internals["invoke"]; convertFileSrc?: Internals["convertFileSrc"] } };
};

export const isTauri = (win: Window = window) => !!((win as W).__TAURI_INTERNALS__ || (win as W).__TAURI__);

/** `scope`: {session: abs} | {project: id, …}; a plain string is a session dir (v2 callers). */
export function createTauriHost(scope: Scope | string, win: W = window as W): BlurtHost {
  const core = win.__TAURI__?.core ?? win.__TAURI_INTERNALS__;
  if (!core) throw new Error("tauri host: no Tauri IPC");
  const sc: Scope = typeof scope === "string" ? { session: scope } : scope;
  const invoke = <T,>(cmd: string, args?: Record<string, unknown>) => core.invoke<T>(cmd, args);
  const convert = core.convertFileSrc ?? win.__TAURI_INTERNALS__?.convertFileSrc;
  const session = "session" in sc ? sc.session : "";
  const sep = /^[A-Za-z]:\\|\\/.test(session) ? "\\" : "/";
  const abs = (p: string) => (isAbs(p) ? p : session.replace(/[\\/]+$/, "") + sep + p.split("/").join(sep));
  return {
    host: "tauri",
    inApp: true,
    scope: sc,
    load: () => invoke<LoadResult>("items_doc", { scope: sc }),
    poll: (etag: string) => invoke<PollResult>("items_poll", { scope: sc, etag }),
    sendOps: (ops: UserOp[], confirm?: boolean) => invoke<OpsResult>("items_ops", { scope: sc, ops, confirm: !!confirm }),
    fileUrl: (p: string) => {
      if (!p) return "";
      const a = abs(p);
      return convert ? convert(a, "asset") : "asset://localhost/" + encodeURIComponent(a);
    },
    reveal: (p: string) => void invoke("review_file", { path: abs(p), open: false }).catch(() => {}),
    quickLook: (p: string) => void invoke("review_file", { path: abs(p), open: true }).catch(() => {}),
    // "Add image or file…": the system's Open dialog, any files; pictures become the item's pictures, other files its
    // attachments, as a drop would (the page sees them at its next poll)
    addFiles: (uid: string) => void invoke("items_add_files", { uid }).catch(() => {}),
    handoff: (uids: string[], what: "instruction" | "full") => invoke<HandoffResult>("handoff_create", { uids, full: what === "full" }),
  };
}
