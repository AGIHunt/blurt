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
    expect(m.file().items.map((i) => [i.title, i.status])).toEqual([["typed", "confirmed"], ["b", "confirmed"]]);
    expect(confirmed).toHaveBeenCalled();
    expect(s.confirmed).toBe(true);
    s.dispose();
    vi.useRealTimers();
  });
  it("item mode follows the item by uid and ignores triage keys", async () => {
    const m = memHost({ items: [{ id: "I-001", uid: "U1" }, { id: "I-002", uid: "U2" }] });
    const s = new ReviewStore(m.host, { mode: "item", itemId: "U2" });
    await s.load();
    expect(s.item!.id).toBe("I-002");
    s.onKeyDown(new KeyboardEvent("keydown", { key: "x" }));
    expect(s.item!.status).toBeUndefined();
    s.setItem("I-001");
    expect(s.item!.id).toBe("I-001");
    s.dispose();
  });
});
