/* browser host: review.py's HTTP API — GET /api/items (ETag), POST /api/items {ops}, POST /api/confirm {ops},
   files at /files/<path>: a v2 session-relative path segment by segment, a v3 absolute path as ONE percent-encoded
   segment (`files/%2FUsers%2Fjohn%2F…`; review.py unquotes it and serves it only from registered stores, session
   dirs and $BLURT_HOME/handoff). */
import { isAbs, type BlurtHost, type HandoffResult, type OpsResult, type PollResult, type ReviewDoc } from "../host";

export const encodeRel = (rel: string) => String(rel).split("/").map(encodeURIComponent).join("/");
export const filePath = (p: string) => (isAbs(p) ? encodeURIComponent(p) : encodeRel(p));

export function createBrowserHost(opts: { base?: string; win?: Window } = {}): BlurtHost {
  // relative to the page, so the API works wherever review.py (or a proxy) serves it
  const base = opts.base ?? "";

  async function json(r: Response): Promise<ReviewDoc> {
    return (await r.json()) as ReviewDoc;
  }
  async function post(path: string, body: string): Promise<Response> {
    const r = await fetch(base + path, { method: "POST", headers: { "Content-Type": "application/json" }, body });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return r;
  }

  return {
    host: "browser",
    inApp: false,
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
      let doc: ReviewDoc | undefined;
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
    /* review.py POST /api/handoff {uids, what} → {id, path, text}; the page copies the text. Offered only when the
       doc says review.py has it (`_caps` includes "handoff", see ReviewStore.canHandoff). */
    handoff(uids, what) {
      const r = post("api/handoff", JSON.stringify({ uids, what })).then((x) => x.json() as Promise<HandoffResult>);
      copyLater(r.then((x) => x.text));
      return r;
    },
    fileUrl: (p) => (p ? base + "files/" + filePath(p) : ""),
    downloadUrl: (p) => base + "files/" + filePath(p) + "?download=1",
  };
}

/** Copy text that is still on its way, inside the click that asked for it: Safari / WKWebView only allow a clipboard
    write during the user gesture, so hand it a ClipboardItem whose content is a promise. */
export function copyLater(text: Promise<string>) {
  const clip = typeof navigator === "undefined" ? undefined : navigator.clipboard;
  const plain = () => void text.then((t) => clip?.writeText(t)).catch(() => {});
  try {
    if (typeof ClipboardItem !== "undefined" && clip?.write) {
      clip.write([new ClipboardItem({ "text/plain": text.then((t) => new Blob([t], { type: "text/plain" })) })]).catch(plain);
      return;
    }
  } catch {
    /* fall through */
  }
  plain();
}
