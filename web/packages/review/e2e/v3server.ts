/* A v3 review server for the Playwright suite: the built page + the K1 doc API (GET/POST /api/items, /api/confirm,
   /api/handoff, /files/<one encoded absolute path>) over the in-memory store double (test/v3store.ts), and /bridge,
   which plays the macOS app's message bridge for the macos host. review.py v3 is P1's; this stands in for it so the
   component's half of the contract is tested on its own. */
import { readFileSync, statSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { extname, join, resolve } from "node:path";
import type { HandoffResult, Item, Scope, UserOp } from "../src/host";
import { MemStore, PROJECTS, V3_ITEMS } from "../test/v3store";
import { REPO } from "./harness";

const PAGE = join(REPO, "skills/blurt/scripts/review.html");
const ICON = join(REPO, "skills/blurt/assets/icon.png");
const TYPES: Record<string, string> = { ".png": "image/png", ".jpg": "image/jpeg", ".mp4": "video/mp4" };

export interface V3Server {
  url: string;
  store: MemStore;
  /** every op the page sent, in order */
  ops: UserOp[];
  handoffs: { uids: string[]; what: string }[];
  calls: { method: string; params: Record<string, unknown> }[];
  stop(): void;
}

/** `frames`: uid → absolute image paths (the files the server may serve) */
export async function startV3(scope: Scope, frames: Record<string, string[]> = {}, items: Item[] = V3_ITEMS): Promise<V3Server> {
  const allowed = new Set(Object.values(frames).flat().map((p) => resolve(p)));
  const store = new MemStore(
    items.map((i) => (frames[i.uid!] ? { ...i, frames: frames[i.uid!].map((path, n) => ({ path, t: n * 3.2 + (i.time?.start ?? 0) })) } : i)),
    PROJECTS,
    { title: "Login and pricing walkthrough", digest: "## Overview\n- Login is broken on Safari\n- Pricing needs a calculator", language: "en" },
  );
  const ops: UserOp[] = [];
  const handoffs: V3Server["handoffs"] = [];
  const calls: V3Server["calls"] = [];
  let seq = 12;

  const doc = () => ({ ...store.doc(scope), _caps: ["handoff"] });
  const handoff = (uids: string[], what: string): HandoffResult => {
    handoffs.push({ uids, what });
    const id = `H-${String(++seq).padStart(4, "0")}`;
    for (const u of uids) {
      const it = store.items.find((i) => i.uid === u)!;
      if (it.work) it.work_history = [...(it.work_history || []), { ...it.work, state: it.state }];
      it.state = "handed_off";
      it.work = { to: "external", handoff: id, by: "user", at: new Date().toISOString() };
    }
    store.rev++;
    const ids = uids.map((u) => store.items.find((i) => i.uid === u)!.id);
    const path = `/Users/me/.blurt/handoff/${id}.md`;
    const text = what === "full" ? `# ${ids.length} items\n\n${ids.join("\n")}` :
      ids.length === 1 ? `Please handle ${ids[0]} — details and screenshots are in ${path}. When you're done, call mark_fixed if the blurt MCP is available.`
        : `Please handle these ${ids.length} items — details and screenshots are in ${path}. When you're done, call mark_fixed for each if the blurt MCP is available.`;
    return { id, path, text };
  };
  const send = (res: ServerResponse, code: number, body: unknown, headers: Record<string, string> = {}) => {
    res.writeHead(code, { "Content-Type": "application/json", ...headers });
    res.end(body === undefined ? undefined : JSON.stringify(body));
  };
  const body = (req: IncomingMessage) =>
    new Promise<Record<string, unknown>>((ok) => {
      let b = "";
      req.on("data", (c) => (b += c));
      req.on("end", () => ok(b ? JSON.parse(b) : {}));
    });

  const server = createServer(async (req, res) => {
    const u = new URL(req.url!, "http://x");
    const path = u.pathname;
    if (req.method === "GET" && (path === "/" || path === "/index.html")) {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(readFileSync(PAGE));
    }
    if (path === "/icon.png") {
      res.writeHead(200, { "Content-Type": "image/png" });
      return res.end(readFileSync(ICON));
    }
    if (path === "/favicon.png" || path === "/peep-done.webp" || path === "/peep-done-dark.webp") {
      res.writeHead(200, { "Content-Type": path.endsWith(".webp") ? "image/webp" : "image/png" });
      return res.end(readFileSync(join(ICON, "..", path.slice(1))));
    }
    if (path.startsWith("/files/")) {
      const abs = resolve(decodeURIComponent(path.slice(7)));
      if (!allowed.has(abs)) return send(res, 403, { ok: false, code: "forbidden" });
      res.writeHead(200, { "Content-Type": TYPES[extname(abs)] || "application/octet-stream", "Content-Length": String(statSync(abs).size) });
      return res.end(readFileSync(abs));
    }
    if (path === "/api/items" && req.method === "GET") {
      if (req.headers["if-none-match"] === store.etag) return send(res, 304, undefined, { ETag: store.etag });
      return send(res, 200, doc(), { ETag: store.etag });
    }
    if ((path === "/api/items" || path === "/api/confirm") && req.method === "POST") {
      const b = (await body(req)) as { ops: UserOp[] };
      ops.push(...b.ops);
      store.apply(b.ops, path === "/api/confirm");
      return send(res, 200, doc(), { ETag: store.etag });
    }
    if (path === "/api/handoff" && req.method === "POST") {
      const b = (await body(req)) as { uids: string[]; what: string };
      return send(res, 200, handoff(b.uids, b.what));
    }
    if (path === "/bridge" && req.method === "POST") {
      const { method, params } = (await body(req)) as { method: string; params: Record<string, unknown> };
      calls.push({ method, params });
      if (method === "load") return send(res, 200, { doc: doc(), etag: store.etag });
      if (method === "poll") return send(res, 200, params.etag === store.etag ? { etag: store.etag } : { doc: doc(), etag: store.etag });
      if (method === "sendOps") {
        ops.push(...(params.ops as UserOp[]));
        store.apply(params.ops as UserOp[], !!params.confirm);
        return send(res, 200, { ok: true, etag: store.etag }); // the bridge only acknowledges, like items.py user-ops
      }
      if (method === "handoff") return send(res, 200, handoff(params.uids as string[], params.what as string));
      return send(res, 200, null);
    }
    send(res, 404, { ok: false });
  });
  await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}/`;
  return { url, store, ops, handoffs, calls, stop: () => server.close() };
}

/** an init script that turns the page into the macOS main window's canvas: webkit.messageHandlers.blurt → /bridge */
export const BRIDGE = (scope: Scope, methods: string[]) => `
  window.blurtHostInfo = ${JSON.stringify({ host: "macos", scope, methods })};
  window.webkit = { messageHandlers: { blurt: { postMessage(m) {
    fetch("/bridge", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(m) })
      .then((r) => r.json()).then((v) => { if (m.id) window.__blurtReply(m.id, v, null); })
      .catch((e) => { if (m.id) window.__blurtReply(m.id, null, String(e)); });
  } } } };`;
