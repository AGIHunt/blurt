/* tauri host (C6 / C8, protocol v3): invoke('items_doc' | 'items_poll' | 'items_ops' | 'handoff_create' | 'reveal', …)
   with the scope. Uses the IPC global Tauri 2 always injects (__TAURI_INTERNALS__), so the canvas needs no
   @tauri-apps/api import. Files load through the asset protocol (convertFileSrc), which the shell scopes to the
   registered stores, session dirs and $BLURT_HOME/handoff. dispatch / openSession are shell navigation: the desktop
   app adds them to this host (web/apps/desktop/src/host.ts). */
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
    reveal: (p: string) => void invoke("reveal", { path: abs(p) }).catch(() => {}),
    handoff: (uids: string[], what: "instruction" | "full") => invoke<HandoffResult>("handoff_create", { uids, full: what === "full" }),
  };
}
