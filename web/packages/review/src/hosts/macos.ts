/* macos host (C6, protocol v3): the main window loads blurt-app://ui/index.html?host=macos&… through a
   WKURLSchemeHandler and every call goes through one message handler:

     JS → native   webkit.messageHandlers.blurt.postMessage({id, method, params})      id 0 = no reply wanted
     native → JS   window.__blurtReply(id, result, error)       (or: a WKScriptMessageHandlerWithReply's promise)

   load / poll / sendOps carry the scope ({session: abs} | {project: id, …}); files are
   blurt-app://file/<percent-encoded absolute path> (v3) or blurt-app://session/<rel> (a v2 session). The native side
   describes itself with a document-start user script:
     window.blurtHostInfo = {host: "macos", scope: {project: "3f2a…"}, methods: ["reveal", "handoff", …], accent: "#0a84ff"} */
import { isAbs, type BlurtHost, type DragRect, type HandoffResult, type LoadResult, type OpsResult, type PollResult, type Scope, type UserOp } from "../host";
import { encodeRel } from "./browser";

interface Handler {
  postMessage(m: unknown): unknown;
}
export interface HostInfo {
  host?: string;
  /** optional methods the native side implements */
  methods?: string[];
  accent?: string;
  scope?: Scope;
  /** v2: the session dir (same as scope {session}) */
  session?: string;
  /** the native banner above the page has the item's Open Session (BlurtHost.sessionBanner) */
  sessionBanner?: boolean;
  /** review.py asked for this batch and waits for its confirmation (BlurtHost.agentWaiting) */
  agentWaiting?: boolean;
}
type W = Window & {
  webkit?: { messageHandlers?: { blurt?: Handler } };
  __blurtReply?: (id: number, result: unknown, error?: unknown) => void;
  blurtHostInfo?: HostInfo;
};

export const OPTIONAL = ["reveal", "quickLook", "openCode", "dispatch", "handoff", "openSession", "registerDragRects", "download"] as const;

/** the scope from blurtHostInfo, else the page URL (?project= / ?session=) */
export function scopeFrom(win: Window, info: HostInfo = {}): Scope | undefined {
  if (info.scope) return info.scope;
  const q = new URLSearchParams(win.location.search);
  const project = q.get("project");
  if (project) return { project };
  const session = info.session || q.get("session");
  return session ? { session } : undefined;
}

// a toast's answer can take as long as the island holds it (a hover holds it, a newer toast puts an Undo back): the
// app answers "gone" itself when the island lets it go, so this is only a backstop
const TOAST_TIMEOUT_MS = 10 * 60 * 1000;

export function createMacosHost(win: W = window as W, timeoutMs = 30000, toastTimeoutMs = TOAST_TIMEOUT_MS): BlurtHost {
  const handler = win.webkit?.messageHandlers?.blurt;
  if (!handler) throw new Error("macos host: webkit.messageHandlers.blurt is missing");
  let seq = 0;
  const pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> }>();
  const prevReply = win.__blurtReply;
  win.__blurtReply = (id, result, error) => {
    const p = pending.get(id);
    if (!p) return prevReply?.(id, result, error);
    pending.delete(id);
    clearTimeout(p.timer);
    if (error != null && error !== "") p.reject(new Error(typeof error === "string" ? error : JSON.stringify(error)));
    else p.resolve(result);
  };

  function call<T>(method: string, params: Record<string, unknown> = {}, ms = timeoutMs): Promise<T> {
    const id = ++seq;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`macos host: ${method} timed out`));
      }, ms);
      pending.set(id, { resolve: resolve as (v: unknown) => void, reject, timer });
      let r: unknown;
      try {
        r = handler!.postMessage({ id, method, params });
      } catch (e) {
        pending.delete(id);
        clearTimeout(timer);
        reject(e as Error);
        return;
      }
      if (r && typeof (r as Promise<unknown>).then === "function") {
        // WKScriptMessageHandlerWithReply answers through this promise. Recent WebKit also returns a promise for a
        // plain handler, resolved with undefined — then the answer still comes through __blurtReply.
        (r as Promise<T>).then(
          (v) => {
            if (v === undefined || !pending.has(id)) return;
            pending.delete(id);
            clearTimeout(timer);
            resolve(v);
          },
          (e) => {
            if (!pending.has(id)) return;
            pending.delete(id);
            clearTimeout(timer);
            reject(e instanceof Error ? e : new Error(String(e)));
          },
        );
      }
    });
  }
  const notify = (method: string, params: Record<string, unknown>) => {
    try {
      handler.postMessage({ id: 0, method, params });
    } catch {
      /* best effort */
    }
  };

  const info = win.blurtHostInfo || {};
  const scope = scopeFrom(win, info);
  const has = new Set<string>(info.methods ?? OPTIONAL);
  const host: BlurtHost = {
    host: "macos",
    inApp: true,
    scope,
    load: () => call<LoadResult>("load", { scope }),
    poll: (etag: string) => call<PollResult>("poll", { etag, scope }),
    sendOps: (ops: UserOp[], confirm?: boolean) => call<OpsResult>("sendOps", { ops, confirm: !!confirm, scope }),
    fileUrl: (p: string) => (!p ? "" : isAbs(p) ? "blurt-app://file/" + encodeURIComponent(p) : "blurt-app://session/" + encodeRel(p)),
    confirmed: () => notify("confirmed", { scope }),
  };
  if (has.has("reveal")) host.reveal = (path) => notify("reveal", { path });
  if (has.has("quickLook")) host.quickLook = (path) => notify("quickLook", { path });
  if (has.has("openCode")) host.openCode = (ref) => notify("openCode", { ref });
  if (has.has("dispatch")) host.dispatch = (uids) => notify("dispatch", { uids });
  if (has.has("handoff")) host.handoff = (uids, what) => call<HandoffResult>("handoff", { uids, what });
  if (has.has("openSession")) host.openSession = (job) => notify("openSession", { job });  // WebHostController reads {job}
  if (info.sessionBanner) host.sessionBanner = true;
  if (info.agentWaiting) host.agentWaiting = true;
  if (has.has("registerDragRects")) host.registerDragRects = (rects: DragRect[]) => notify("registerDragRects", { rects });
  if (has.has("download")) host.download = (path) => notify("download", { path });
  // the answer: "undo" when its Undo is clicked, "gone" when the island let it go without (or, as a backstop, timed out)
  if (has.has("toast")) host.toast = (t) => call<string>("toast", { ...t }, toastTimeoutMs).catch(() => "gone");
  return host;
}
