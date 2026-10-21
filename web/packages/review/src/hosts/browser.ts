/* browser host: review.py's HTTP API, unchanged (GET /api/items with ETag, POST /api/items {ops},
   POST /api/confirm {ops}, /files/<rel>). Also what the Blurt app's current review window uses: it loads
   review.py's page in a WKWebView and injects window.blurtApp; the page then reports "confirmed" through
   webkit.messageHandlers.blurt (the window closes itself). */
import type { BlurtHost, OpsResult, PollResult, SessionDoc } from "../host";

interface AppWindow {
  blurtApp?: unknown;
  webkit?: { messageHandlers?: { blurt?: { postMessage(m: unknown): unknown } } };
}

export const encodeRel = (rel: string) => String(rel).split("/").map(encodeURIComponent).join("/");

export function createBrowserHost(opts: { base?: string; win?: Window } = {}): BlurtHost {
  const win = (opts.win ?? window) as Window & AppWindow;
  // relative to the page, so the API works wherever review.py (or a proxy) serves it
  const base = opts.base ?? "";
  const inApp = !!win.blurtApp;

  async function json(r: Response): Promise<SessionDoc> {
    return (await r.json()) as SessionDoc;
  }
  async function post(path: string, body: string): Promise<Response> {
    const r = await fetch(base + path, { method: "POST", headers: { "Content-Type": "application/json" }, body });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return r;
  }

  return {
    host: "browser",
    inApp,
    async load() {
      const r = await fetch(base + "api/items");
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return { doc: await json(r), etag: r.headers.get("ETag") || "" };
    },
    async poll(etag: string): Promise<PollResult> {
      const r = await fetch(base + "api/items", { headers: etag ? { "If-None-Match": etag } : {} });
      if (r.status === 304) return { etag };
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return { doc: await json(r), etag: r.headers.get("ETag") || etag };
    },
    async sendOps(ops, confirm): Promise<OpsResult> {
      const r = await post(confirm ? "api/confirm" : "api/items", JSON.stringify({ ops }));
      const etag = r.headers.get("ETag") || "";
      let doc: SessionDoc | undefined;
      try {
        doc = await json(r);
      } catch {
        doc = undefined;
      }
      return { ok: true, etag, doc: doc && Array.isArray(doc.items) ? doc : undefined };
    },
    async saveDoc(doc, confirm) {
      const d: Record<string, unknown> = { ...doc };
      delete d._video;
      await post(confirm ? "api/confirm" : "api/items", JSON.stringify(d));
    },
    fileUrl: (rel) => (rel ? base + "files/" + encodeRel(rel) : ""),
    downloadUrl: (rel) => base + "files/" + encodeRel(rel) + "?download=1",
    confirmed() {
      win.webkit?.messageHandlers?.blurt?.postMessage({ type: "confirmed" }); // the app window closes itself
    },
  };
}
