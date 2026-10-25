import { describe, expect, it, vi } from "vitest";
import type { BlurtHost, SessionDoc, UserOp } from "../src/host";
import { applyUserOps } from "./apply";
import { ReviewStore } from "../src/store";
import { clone } from "../src/sync";

/** an in-memory host that behaves like the macOS bridge: sendOps only acknowledges (no doc), like `items.py user-ops` */
function memHost(doc: SessionDoc, withDoc = false) {
  let file = clone(doc);
  let n = 1;
  const etag = () => `"${n}"`;
  const sent: { ops: UserOp[]; confirm?: boolean }[] = [];
  const host: BlurtHost = {
    host: "macos",
    load: async () => ({ doc: clone(file), etag: etag() }),
    poll: async (e) => (e === etag() ? { etag: e } : { doc: clone(file), etag: etag() }),
    sendOps: async (ops, confirm) => {
      sent.push({ ops, confirm });
      file = applyUserOps(file, ops);
      if (confirm) file.reviewed = true;
      n++;
      return withDoc ? { ok: true, etag: etag(), doc: clone(file) } : { ok: true, etag: etag() };
    },
    fileUrl: (r) => "blurt-app://session/" + r,
  };
  return {
    host,
    sent,
    file: () => file,
    agentWrite: (f: (d: SessionDoc) => void) => {
      f(file);
      n++;
    },
  };
}

const DOC: SessionDoc = {
  title: "t",
  items: [
    { id: "I-001", kind: "issue", title: "a", status: "draft" },
    { id: "I-002", kind: "issue", title: "b", status: "draft" },
  ],
};

describe("ReviewStore over an acknowledging host (macos / tauri)", () => {
  it("saves a diff, then re-reads the file so base includes the write (no resend)", async () => {
    vi.useFakeTimers();
    const m = memHost(DOC);
    const s = new ReviewStore(m.host);
    await s.load();
    s.setField(s.item!, "title", "a2");
    await vi.advanceTimersByTimeAsync(500);
    expect(m.sent).toHaveLength(1);
    expect(m.file().items[0].title).toBe("a2");
    expect(m.file().items[0]._user?.title).toBeTypeOf("number");
    expect(s.pendingOps()).toEqual([]); // base caught up
    s.save();
    await vi.advanceTimersByTimeAsync(500);
    expect(m.sent).toHaveLength(1); // nothing new to send
    s.dispose();
    vi.useRealTimers();
  });
  it("keeps the user's edit when the agent writes the same field meanwhile, picks up the agent's other fields", async () => {
    vi.useFakeTimers();
    const m = memHost(DOC);
    const s = new ReviewStore(m.host);
    await s.load();
    s.setField(s.item!, "actual", "mine");
    m.agentWrite((d) => {
      d.items[0].actual = "agent";
      d.items[0].frames = [{ path: "f.jpg" }];
    });
    await vi.advanceTimersByTimeAsync(2100); // the idle poll
    expect(s.item!.actual).toBe("mine");
    expect(s.item!.frames).toEqual([{ path: "f.jpg" }]);
    await vi.advanceTimersByTimeAsync(500);
    expect(m.file().items[0].actual).toBe("mine");
    s.dispose();
    vi.useRealTimers();
  });
  it("finish sends the confirm with what was typed but not yet saved", async () => {
    vi.useFakeTimers();
    const m = memHost(DOC, true);
    const s = new ReviewStore(m.host);
    const confirmed = vi.fn();
    m.host.confirmed = confirmed;
    await s.load();
    s.setField(s.item!, "title", "typed");
    await s.finish(); // before the autosave timer
    expect(m.sent.at(-1)!.confirm).toBe(true);
    expect(m.file().reviewed).toBe(true);
    expect(m.file().items.map((i) => [i.title, i.state])).toEqual([["typed", "todo"], ["b", "todo"]]); // the rest is kept
    expect(confirmed).toHaveBeenCalled();
    expect(s.confirmed).toBe(true);
    s.dispose();
    vi.useRealTimers();
  });
  it("item mode follows the item by uid; review-only keys do nothing, the state keys work in place", async () => {
    const m = memHost({ items: [{ id: "I-001", uid: "U1" }, { id: "I-002", uid: "U2" }] });
    const s = new ReviewStore(m.host, { mode: "item", itemId: "U2" });
    await s.load();
    expect(s.item!.id).toBe("I-002");
    const key = (k: string) => s.onKeyDown(new KeyboardEvent("keydown", { key: k, cancelable: true }));
    key("j");
    key("Enter"); // keep-and-next is the review's
    expect(s.item!.id).toBe("I-002");
    expect(s.stateOf(s.item!)).toBe("new");
    key("a");
    expect(s.stateOf(s.item!)).toBe("todo");
    key("x");
    expect([s.item!.id, s.stateOf(s.item!), s.item!.restore_to]).toEqual(["I-002", "discarded", "todo"]);
    key("r");
    expect(s.stateOf(s.item!)).toBe("todo");
    expect(s.setItem("I-001")).toBe(true);
    expect(s.item!.id).toBe("I-001");
    s.dispose();
  });
  it("item mode never shows another item in place of one the doc doesn't have (a discarded one, say)", async () => {
    const m = memHost({ items: [{ id: "I-001", uid: "U1" }, { id: "I-002", uid: "U2" }] });
    // asked for at load: not item 0
    const cold = new ReviewStore(m.host, { mode: "item", itemId: "U9" });
    await cold.load();
    expect([cold.missing, cold.item]).toEqual([true, undefined]);
    cold.dispose();
    // asked for later: setItem says so (the host then loads a doc that has it), and nothing stale stays on show
    const s = new ReviewStore(m.host, { mode: "item", itemId: "U2" });
    await s.load();
    expect(s.setItem("U9")).toBe(false);
    expect(s.item).toBeUndefined();
    const key = (k: string) => s.onKeyDown(new KeyboardEvent("keydown", { key: k, cancelable: true }));
    key("x"); // no key acts on the item shown before
    expect(s.pendingOps()).toEqual([]);
    expect(s.setItem("U1")).toBe(true);
    expect(s.item!.id).toBe("I-001");
    s.dispose();
  });
});

describe("K3 state actions", () => {
  const doc = (): SessionDoc => ({
    title: "t",
    items: [
      { id: "I-001", kind: "issue", title: "a", state: "new" },
      { id: "I-002", kind: "issue", title: "b", state: "to_verify", work: { to: "session", agent: "claude", claim: "fixed" } },
      { id: "I-003", kind: "issue", title: "c", status: "draft", work: { state: "wontfix" } }, // an old file: won't do
    ],
  });
  it("review keys: keep and discard go on to the next new item; D R W act in place; S opens the menu", async () => {
    vi.useFakeTimers();
    const m = memHost(doc(), true);
    const s = new ReviewStore(m.host);
    await s.load();
    const key = (k: string) => s.onKeyDown(new KeyboardEvent("keydown", { key: k, cancelable: true }));
    expect(s.counts()).toEqual({ k: 2, d: 0, p: 1, n: 3 });
    key("Enter");
    expect(s.stateOf(s.data.items[0])).toBe("todo");
    await vi.advanceTimersByTimeAsync(500);
    expect(m.sent[0].ops).toEqual([{ op: "state", id: "I-001", action: "keep" }]);
    s.go(1);
    key("w"); // to verify → won't do
    key("r"); // won't do → reopen
    key("d"); // to do → done
    expect(s.stateOf(s.data.items[1])).toBe("done");
    key("s");
    expect(s.menuOpen).toBe(true);
    s.go(2);
    expect(s.menuOpen).toBe(false);
    key("a"); // already past new: nothing to keep, just moves on
    expect(s.stateOf(s.data.items[2])).toBe("wontfix");
    await vi.advanceTimersByTimeAsync(500);
    expect(m.sent.flatMap((x) => x.ops).map((o) => (o.op === "state" && "action" in o ? o.action : o.op))).toEqual(["keep", "wontfix", "reopen", "done"]);
    expect(m.file().items.map((i) => i.state)).toEqual(["todo", "done", undefined]);
    s.dispose();
    vi.useRealTimers();
  });
  it("undo sends the exact state back; a discard stays on the page even when the doc drops it", async () => {
    vi.useFakeTimers();
    const m = memHost(doc(), true);
    const s = new ReviewStore(m.host);
    await s.load();
    s.go(1);
    s.decide("discard");
    expect(s.stateOf(s.data.items[1])).toBe("discarded");
    await vi.advanceTimersByTimeAsync(500);
    // a server that leaves discarded items out of the doc: the page keeps showing it, struck through
    m.agentWrite((d) => (d.items = d.items.filter((i) => i.state !== "discarded")));
    await vi.advanceTimersByTimeAsync(2100);
    expect(s.data.items.map((i) => [i.id, s.st(i)])).toEqual([["I-001", "pending"], ["I-002", "drop"], ["I-003", "keep"]]);
    expect(s.pendingOps()).toEqual([]); // not an item to add
    s.undo();
    expect(s.stateOf(s.data.items[1])).toBe("to_verify");
    await vi.advanceTimersByTimeAsync(500);
    expect(m.sent.at(-1)!.ops).toEqual([{ op: "state", id: "I-002", state: "to_verify", undo: true }]);
    s.dispose();
    vi.useRealTimers();
  });
  it("hand off opens the host's dispatch for new / to do items, and never sends a state op", async () => {
    vi.useFakeTimers();
    const m = memHost(doc(), true);
    const dispatch = vi.fn();
    m.host.dispatch = dispatch;
    const s = new ReviewStore(m.host, { mode: "item", itemId: "I-001" });
    await s.load();
    expect(s.canHandOff).toBe(true);
    s.onKeyDown(new KeyboardEvent("keydown", { key: "Enter", metaKey: true, cancelable: true }));
    expect(dispatch).toHaveBeenCalledWith(["I-001"]);
    s.act([s.data.items[1]], "hand_off"); // to verify: not from there
    expect(dispatch).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(500);
    expect(m.sent).toEqual([]);
    s.dispose();
    vi.useRealTimers();
  });
});
