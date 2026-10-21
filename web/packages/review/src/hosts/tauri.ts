/* tauri host (C6 / C8): invoke('review_load' | 'review_poll' | 'review_ops' | 'reveal' | 'fix_with_agent', …).
   Uses the IPC global Tauri 2 always injects (__TAURI_INTERNALS__), so the canvas needs no @tauri-apps/api import.
   Session files are loaded through the asset protocol (convertFileSrc), which the shell must scope to the session dirs. */
import type { BlurtHost, LoadResult, OpsResult, PollResult, UserOp } from "../host";

interface Internals {
  invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T>;
  convertFileSrc?(path: string, protocol?: string): string;
}
type W = Window & {
  __TAURI_INTERNALS__?: Internals;
  __TAURI__?: { core?: { invoke: Internals["invoke"]; convertFileSrc?: Internals["convertFileSrc"] } };
};

export const isTauri = (win: Window = window) => !!((win as W).__TAURI_INTERNALS__ || (win as W).__TAURI__);

export function createTauriHost(session: string, win: W = window as W): BlurtHost {
  const core = win.__TAURI__?.core ?? win.__TAURI_INTERNALS__;
  if (!core) throw new Error("tauri host: no Tauri IPC");
  const invoke = <T,>(cmd: string, args?: Record<string, unknown>) => core.invoke<T>(cmd, args);
  const convert = core.convertFileSrc ?? win.__TAURI_INTERNALS__?.convertFileSrc;
  const sep = /^[A-Za-z]:\\|\\/.test(session) ? "\\" : "/";
  const abs = (rel: string) => session.replace(/[\\/]+$/, "") + sep + rel.split("/").join(sep);
  return {
    host: "tauri",
    inApp: true,
    load: () => invoke<LoadResult>("review_load", { session }),
    poll: (etag: string) => invoke<PollResult>("review_poll", { session, etag }),
    sendOps: (ops: UserOp[], confirm?: boolean) => invoke<OpsResult>("review_ops", { session, ops, confirm: !!confirm }),
    fileUrl: (rel: string) => {
      if (!rel) return "";
      const p = abs(rel);
      return convert ? convert(p, "asset") : "asset://localhost/" + encodeURIComponent(p);
    },
    reveal: (rel: string) => void invoke("reveal", { path: abs(rel) }).catch(() => {}),
    fixWithAgent: (itemIds: string[]) => void invoke("fix_with_agent", { session, itemIds }).catch(() => {}),
  };
}
