import { describe, expect, it, vi } from "vitest";
import { createBrowserHost, createMacosHost, createTauriHost, detectHost } from "../src/hosts";

const doc = { items: [{ id: "I-001", title: "t" }] };
type Reply = { __blurtReply: (i: number, r: unknown, e?: unknown) => void };

function fakeWindow(extra: Record<string, unknown> = {}, href = "http://127.0.0.1:5000/") {
  const u = new URL(href);
  return { location: { search: u.search, protocol: u.protocol }, ...extra } as unknown as Window;
}

describe("browser host (review.py)", () => {
  it("GET / poll with ETag / POST ops / files (v2 relative, v3 absolute)", async () => {
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
    const r = await h.sendOps([{ op: "set", id: "01JB", set: { project: "p1" }, unset: [] }]);
    expect(r).toMatchObject({ ok: true, etag: '"e2"', doc });
    await h.sendOps([{ op: "state", id: "01JB", action: "done" }], true);
    expect(calls.map(([u, i]) => `${i?.method || "GET"} ${u}`)).toEqual([
      "GET api/items", "GET api/items", "GET api/items", "POST api/items", "POST api/confirm",
    ]);
    expect(JSON.parse(String(calls[4][1]!.body))).toEqual({ ops: [{ op: "state", id: "01JB", action: "done" }] });
    expect(h.fileUrl("frames/a b#1.jpg")).toBe("files/frames/a%20b%231.jpg");
    expect(h.fileUrl("/Users/me/p/.blurt/assets/01JB/1.png")).toBe("files/%2FUsers%2Fme%2Fp%2F.blurt%2Fassets%2F01JB%2F1.png");
    expect(h.fileUrl("C:\\p\\1.png")).toBe("files/C%3A%5Cp%5C1.png");
    expect(h.downloadUrl!("clips/I-001.mp4")).toBe("files/clips/I-001.mp4?download=1");
    expect(h.inApp).toBe(false);
    expect(h.handoff).toBeTypeOf("function"); // offered only when the doc has _caps: ["handoff"]
    vi.unstubAllGlobals();
  });
});

describe("macos host (WKWebView bridge, protocol v3)", () => {
  it("round-trips {id, method, params} with the scope through window.__blurtReply", async () => {
    const sent: { id: number; method: string; params: Record<string, unknown> }[] = [];
    const win = fakeWindow({ webkit: { messageHandlers: { blurt: { postMessage: (m: never) => void sent.push(m) } } } }, "blurt-app://ui/index.html?project=3f2a");
    const h = createMacosHost(win as never);
    expect(h.scope).toEqual({ project: "3f2a" });
    const p = h.load();
    expect(sent[0]).toMatchObject({ method: "load", params: { scope: { project: "3f2a" } } });
    (win as unknown as Reply).__blurtReply(sent[0].id, { doc, etag: '"e"' });
    await expect(p).resolves.toEqual({ doc, etag: '"e"' });
    const q = h.sendOps([], true);
    expect(sent[1]).toMatchObject({ method: "sendOps", params: { ops: [], confirm: true, scope: { project: "3f2a" } } });
    (win as unknown as Reply).__blurtReply(sent[1].id, null, "items.py failed");
    await expect(q).rejects.toThrow("items.py failed");
    expect(h.fileUrl("frames/I-001 1.jpg")).toBe("blurt-app://session/frames/I-001%201.jpg");
    expect(h.fileUrl("/Users/me/p/.blurt/assets/U/1.png")).toBe("blurt-app://file/%2FUsers%2Fme%2Fp%2F.blurt%2Fassets%2FU%2F1.png");
    h.reveal!("/Users/me/p/.blurt/sessions/s");
    expect(sent[2]).toEqual({ id: 0, method: "reveal", params: { path: "/Users/me/p/.blurt/sessions/s" } });
    h.dispatch!(["01JB", "01JC"]);
    expect(sent[3]).toEqual({ id: 0, method: "dispatch", params: { uids: ["01JB", "01JC"] } });
    const ho = h.handoff!(["01JB"], "instruction");
    expect(sent[4]).toMatchObject({ method: "handoff", params: { uids: ["01JB"], what: "instruction" } });
    (win as unknown as Reply).__blurtReply(sent[4].id, { id: "H-0012", path: "/h/H-0012.md", text: "Please handle BA-12 …" });
    await expect(ho).resolves.toMatchObject({ id: "H-0012" });
    h.openSession!("j-20261022-101500-ab12");
    // the exact payload WebHostController reads (ReviewHostParams.job; Swift WorkSessionTests.testOpenSessionPayload)
    expect(sent[5]).toEqual({ id: 0, method: "openSession", params: { job: "j-20261022-101500-ab12" } });
    expect(h.sessionBanner).toBeUndefined();
  });
  it("sessionBanner: the native banner has the item's Open Session", () => {
    const post = { postMessage: () => {} };
    const h = createMacosHost(fakeWindow({ webkit: { messageHandlers: { blurt: post } }, blurtHostInfo: { sessionBanner: true } }) as never);
    expect(h.sessionBanner).toBe(true);
  });
  it("agentWaiting: only a batch review.py asked for is handed back to an agent", () => {
    const post = { postMessage: () => {} };
    const mk = (info: object) => createMacosHost(fakeWindow({ webkit: { messageHandlers: { blurt: post } }, blurtHostInfo: info }) as never);
    expect(mk({}).agentWaiting).toBeUndefined();
    expect(mk({ agentWaiting: true }).agentWaiting).toBe(true);
  });
  it("takes the scope from blurtHostInfo first, a session from the URL otherwise", () => {
    const post = { postMessage: () => {} };
    expect(createMacosHost(fakeWindow({ webkit: { messageHandlers: { blurt: post } }, blurtHostInfo: { scope: { project: "inbox" } } }, "blurt-app://ui/?session=%2Fx") as never).scope).toEqual({ project: "inbox" });
    expect(createMacosHost(fakeWindow({ webkit: { messageHandlers: { blurt: post } } }, "blurt-app://ui/?session=%2Fx") as never).scope).toEqual({ session: "/x" });
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
    (win as unknown as Reply).__blurtReply(sent[0].id, { doc, etag: '"q"' });
    await expect(p).resolves.toEqual({ doc, etag: '"q"' });
  });
  it("only exposes the optional methods the native side lists", () => {
    const win = fakeWindow({ webkit: { messageHandlers: { blurt: { postMessage: () => {} } } }, blurtHostInfo: { host: "macos", methods: ["quickLook", "handoff"] } });
    const h = createMacosHost(win as never);
    expect(h.quickLook).toBeTypeOf("function");
    expect(h.handoff).toBeTypeOf("function");
    expect(h.reveal).toBeUndefined();
    expect(h.dispatch).toBeUndefined();
  });
  it("is detected from blurt-app://", () => {
    const win = fakeWindow({ webkit: { messageHandlers: { blurt: { postMessage: () => {} } } } }, "blurt-app://ui/index.html?session=%2Fx");
    expect(detectHost(win).host).toBe("macos");
  });
});

describe("tauri host", () => {
  it("maps to the v3 commands with the scope, and the asset protocol", async () => {
    const invoke = vi.fn(async (cmd: string) => (cmd === "items_doc" ? { doc, etag: "e" } : cmd === "handoff_create" ? { id: "H-1", path: "/h", text: "x" } : { ok: true, etag: "f" }));
    const win = fakeWindow({ __TAURI_INTERNALS__: { invoke, convertFileSrc: (p: string) => "asset://localhost/" + encodeURIComponent(p) } }, "http://tauri.localhost/?session=%2Fs%2Fx");
    const h = detectHost(win);
    expect(h.host).toBe("tauri");
    await h.load();
    await h.poll("e");
    await h.sendOps([{ op: "remove", id: "U2", into: "U1" }], false);
    await h.handoff!(["U1"], "full");
    expect(invoke.mock.calls).toEqual([
      ["items_doc", { scope: { session: "/s/x" } }],
      ["items_poll", { scope: { session: "/s/x" }, etag: "e" }],
      ["items_ops", { scope: { session: "/s/x" }, ops: [{ op: "remove", id: "U2", into: "U1" }], confirm: false }],
      ["handoff_create", { uids: ["U1"], full: true }],
    ]);
    expect(h.fileUrl("frames/a.jpg")).toBe("asset://localhost/" + encodeURIComponent("/s/x/frames/a.jpg"));
    expect(h.fileUrl("/p/.blurt/assets/U/1.png")).toBe("asset://localhost/" + encodeURIComponent("/p/.blurt/assets/U/1.png"));
  });
  it("a project scope; Windows paths with backslashes", () => {
    const tw = (s: never) => createTauriHost(s, fakeWindow({ __TAURI_INTERNALS__: { invoke: vi.fn(), convertFileSrc: (p: string) => p } }) as never);
    expect(tw({ project: "3f2a" } as never).scope).toEqual({ project: "3f2a" });
    expect(tw("C:\\Users\\me\\s" as never).fileUrl("frames/a.jpg")).toBe("C:\\Users\\me\\s\\frames\\a.jpg");
  });
});
