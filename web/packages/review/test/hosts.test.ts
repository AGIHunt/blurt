import { describe, expect, it, vi } from "vitest";
import { createBrowserHost, createMacosHost, createTauriHost, detectHost } from "../src/hosts";

const doc = { items: [{ id: "I-001", title: "t" }] };

function fakeWindow(extra: Record<string, unknown> = {}, href = "http://127.0.0.1:5000/") {
  const u = new URL(href);
  return { location: { search: u.search, protocol: u.protocol }, ...extra } as unknown as Window;
}

describe("browser host (review.py, unchanged API)", () => {
  it("GET / poll with ETag / POST ops / files", async () => {
    const calls: [string, RequestInit | undefined][] = [];
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      calls.push([url, init]);
      const h = (init?.headers || {}) as Record<string, string>;
      if (h["If-None-Match"] === '"e1"') return new Response(null, { status: 304 });
      return new Response(JSON.stringify(doc), { status: 200, headers: { ETag: '"e2"' } });
    });
    vi.stubGlobal("fetch", fetchMock);
    const h = createBrowserHost({ win: fakeWindow() });
    expect((await h.load()).etag).toBe('"e2"');
    expect(await h.poll('"e1"')).toEqual({ etag: '"e1"' });
    expect((await h.poll('"e0"')).doc).toEqual(doc);
    const r = await h.sendOps([{ op: "set", id: "I-001", set: { title: "x" }, unset: [] }]);
    expect(r).toMatchObject({ ok: true, etag: '"e2"', doc });
    await h.sendOps([], true);
    expect(calls.map(([u, i]) => `${i?.method || "GET"} ${u}`)).toEqual([
      "GET api/items", "GET api/items", "GET api/items", "POST api/items", "POST api/confirm",
    ]);
    expect(JSON.parse(String(calls[3][1]!.body))).toEqual({ ops: [{ op: "set", id: "I-001", set: { title: "x" }, unset: [] }] });
    expect(h.fileUrl("frames/a b#1.jpg")).toBe("files/frames/a%20b%231.jpg");
    expect(h.downloadUrl!("clips/I-001.mp4")).toBe("files/clips/I-001.mp4?download=1");
    expect(h.inApp).toBe(false);
    vi.unstubAllGlobals();
  });
  it("in the app's current review window: reports confirmed to webkit", () => {
    const post = vi.fn();
    const h = createBrowserHost({ win: fakeWindow({ blurtApp: { version: 1 }, webkit: { messageHandlers: { blurt: { postMessage: post } } } }) });
    expect(h.inApp).toBe(true);
    h.confirmed!();
    expect(post).toHaveBeenCalledWith({ type: "confirmed" });
  });
});

describe("macos host (WKWebView bridge)", () => {
  it("round-trips {id, method, params} through window.__blurtReply", async () => {
    const sent: { id: number; method: string; params: Record<string, unknown> }[] = [];
    const win = fakeWindow({ webkit: { messageHandlers: { blurt: { postMessage: (m: never) => void sent.push(m) } } } }, "blurt-app://ui/index.html?session=/x");
    const h = createMacosHost(win as never);
    const p = h.load();
    expect(sent[0]).toMatchObject({ method: "load", params: {} });
    (win as unknown as { __blurtReply: (i: number, r: unknown, e?: unknown) => void }).__blurtReply(sent[0].id, { doc, etag: '"e"' });
    await expect(p).resolves.toEqual({ doc, etag: '"e"' });
    const q = h.sendOps([], true);
    expect(sent[1]).toMatchObject({ method: "sendOps", params: { ops: [], confirm: true } });
    (win as unknown as { __blurtReply: (i: number, r: unknown, e?: unknown) => void }).__blurtReply(sent[1].id, null, "items.py failed");
    await expect(q).rejects.toThrow("items.py failed");
    expect(h.fileUrl("frames/I-001 1.jpg")).toBe("blurt-app://session/frames/I-001%201.jpg");
    h.reveal!("frames/a.jpg");
    expect(sent[2]).toEqual({ id: 0, method: "reveal", params: { rel: "frames/a.jpg" } });
  });
  it("uses a WKScriptMessageHandlerWithReply promise when postMessage returns one", async () => {
    const win = fakeWindow({ webkit: { messageHandlers: { blurt: { postMessage: async () => ({ etag: '"z"' }) } } } });
    const h = createMacosHost(win as never);
    await expect(h.poll('"z"')).resolves.toEqual({ etag: '"z"' });
  });
  it("a plain handler whose postMessage returns a promise of undefined (macOS 26 WebKit) still waits for __blurtReply", async () => {
    const sent: { id: number }[] = [];
    const win = fakeWindow({ webkit: { messageHandlers: { blurt: { postMessage: async (m: never) => void sent.push(m) } } } });
    const h = createMacosHost(win as never);
    const p = h.load();
    await Promise.resolve();
    await Promise.resolve();
    (win as unknown as { __blurtReply: (i: number, r: unknown) => void }).__blurtReply(sent[0].id, { doc, etag: '"q"' });
    await expect(p).resolves.toEqual({ doc, etag: '"q"' });
  });
  it("only exposes the optional methods the native side lists", () => {
    const win = fakeWindow({ webkit: { messageHandlers: { blurt: { postMessage: () => {} } } }, blurtHostInfo: { host: "macos", methods: ["quickLook"] } });
    const h = createMacosHost(win as never);
    expect(h.quickLook).toBeTypeOf("function");
    expect(h.reveal).toBeUndefined();
    expect(h.fixWithAgent).toBeUndefined();
  });
  it("is detected from blurt-app://", () => {
    const win = fakeWindow({ webkit: { messageHandlers: { blurt: { postMessage: () => {} } } } }, "blurt-app://ui/index.html?session=%2Fx");
    expect(detectHost(win).host).toBe("macos");
  });
});

describe("tauri host", () => {
  it("maps to the C8 commands and the asset protocol", async () => {
    const invoke = vi.fn(async (cmd: string) => (cmd === "review_load" ? { doc, etag: "e" } : { ok: true, etag: "f" }));
    const win = fakeWindow({ __TAURI_INTERNALS__: { invoke, convertFileSrc: (p: string) => "asset://localhost/" + encodeURIComponent(p) } }, "http://tauri.localhost/?session=%2Fs%2Fx");
    const h = detectHost(win);
    expect(h.host).toBe("tauri");
    await h.load();
    await h.poll("e");
    await h.sendOps([{ op: "remove", id: "I-2", into: "I-1" }], false);
    h.fixWithAgent!(["U1"]);
    expect(invoke.mock.calls).toEqual([
      ["review_load", { session: "/s/x" }],
      ["review_poll", { session: "/s/x", etag: "e" }],
      ["review_ops", { session: "/s/x", ops: [{ op: "remove", id: "I-2", into: "I-1" }], confirm: false }],
      ["fix_with_agent", { session: "/s/x", itemIds: ["U1"] }],
    ]);
    expect(h.fileUrl("frames/a.jpg")).toBe("asset://localhost/" + encodeURIComponent("/s/x/frames/a.jpg"));
  });
  it("builds Windows paths with backslashes", () => {
    const h = createTauriHost("C:\\Users\\me\\s", fakeWindow({ __TAURI_INTERNALS__: { invoke: vi.fn(), convertFileSrc: (p: string) => p } }) as never);
    expect(h.fileUrl("frames/a.jpg")).toBe("C:\\Users\\me\\s\\frames\\a.jpg");
  });
});
