/* macos host (C6): the page is loaded from blurt-app://ui/index.html?session=<abs>&mode=… by a WKURLSchemeHandler,
   session files come from blurt-app://session/<rel>, and every call goes through one message handler:

     JS → native   webkit.messageHandlers.blurt.postMessage({id, method, params})
     native → JS   window.__blurtReply(id, result, error)       (or: a WKScriptMessageHandlerWithReply's promise)

   method names = BlurtHost method names. The native side may describe itself before the page loads with a
   document-start user script: window.blurtHostInfo = {host: "macos", methods: ["reveal", …], accent: "#0a84ff"}. */
import type { BlurtHost, DragRect, LoadResult, OpsResult, PollResult, UserOp } from "../host";
import { encodeRel } from "./browser";

interface Handler {
  postMessage(m: unknown): unknown;
}
export interface HostInfo {
  host?: string;
  /** optional methods the native side implements (reveal, quickLook, openCode, fixWithAgent, registerDragRects, download) */
  methods?: string[];
  accent?: string;
  session?: string;
}
type W = Window & {
  webkit?: { messageHandlers?: { blurt?: Handler } };
  __blurtReply?: (id: number, result: unknown, error?: unknown) => void;
  blurtHostInfo?: HostInfo;
};

const OPTIONAL = ["reveal", "quickLook", "openCode", "fixWithAgent", "registerDragRects", "download"] as const;

export function createMacosHost(win: W = window as W, timeoutMs = 30000): BlurtHost {
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

  function call<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    const id = ++seq;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`macos host: ${method} timed out`));
      }, timeoutMs);
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
  const has = new Set(info.methods ?? OPTIONAL);
  const host: BlurtHost = {
    host: "macos",
    inApp: true,
    load: () => call<LoadResult>("load"),
    poll: (etag: string) => call<PollResult>("poll", { etag }),
    sendOps: (ops: UserOp[], confirm?: boolean) => call<OpsResult>("sendOps", { ops, confirm: !!confirm }),
    fileUrl: (rel: string) => (rel ? "blurt-app://session/" + encodeRel(rel) : ""),
    confirmed: () => notify("confirmed", {}),
  };
  if (has.has("reveal")) host.reveal = (rel) => notify("reveal", { rel });
  if (has.has("quickLook")) host.quickLook = (rel) => notify("quickLook", { rel });
  if (has.has("openCode")) host.openCode = (ref) => notify("openCode", { ref });
  if (has.has("fixWithAgent")) host.fixWithAgent = (itemIds) => notify("fixWithAgent", { itemIds });
  if (has.has("registerDragRects")) host.registerDragRects = (rects: DragRect[]) => notify("registerDragRects", { rects });
  if (has.has("download")) host.download = (rel) => notify("download", { rel });
  return host;
}
