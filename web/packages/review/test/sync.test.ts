import { describe, expect, it } from "vitest";
import type { Item } from "../src/host";
import { canon, clone, diffOps, mergeInto, norm, rebase, statusOf } from "../src/sync";

const it2 = (id: string, extra: Partial<Item> = {}): Item => ({ id, kind: "issue", title: id, status: "draft", ...extra });
const B = (items: Item[]) => new Map(items.map((i) => [i.id, clone(i)]));

describe("canon", () => {
  it("ignores key order", () => {
    expect(canon({ a: 1, b: { c: 2, d: 3 } })).toBe(canon({ b: { d: 3, c: 2 }, a: 1 }));
  });
});

describe("the quote", () => {
  it("is never sent unless the user merged into the item, and the server's always wins otherwise", () => {
    const base = [it2("AW-1", { quote: "Safari 上点登录没反应" }), it2("AW-3", { quote: "价格页在手机上横着溢出了。" })];
    const local = clone(base);
    local[1].quote = local[0].quote; // a mixed-up page: AW-3 carrying AW-1's words
    expect(diffOps(local, B(base))).toEqual([]);
    const r = rebase(local, B(base), clone(base), false);
    expect(r.items[1].quote).toBe("价格页在手机上横着溢出了。");
    // a merge (AW-3 folded into AW-1) sends the joined quote with it
    const merged = clone(base);
    merged[0].quote = "Safari 上点登录没反应 … 价格页在手机上横着溢出了。";
    merged[0].merged_from = ["AW-3"];
    const ops = diffOps([merged[0]], B(base));
    expect(ops[0]).toMatchObject({ op: "set", id: "AW-1", set: { quote: merged[0].quote, merged_from: ["AW-3"] } });
  });
});

describe("norm / statusOf", () => {
  it("defaults kind; the review's view of the K3 state: new = to review, discarded = dropped, the rest kept", () => {
    const n = norm([it2("I-1", { status: "deleted" }), { id: "I-3" }]);
    expect(n.map((i) => i.id)).toEqual(["I-1", "I-3"]);
    expect(n[1].kind).toBe("issue");
    expect(statusOf(n[0])).toBe("drop"); // an old file's deleted = discarded
    expect(statusOf({ id: "x", state: "new" })).toBe("pending");
    expect(statusOf({ id: "x", state: "discarded", restore_to: "todo" })).toBe("drop");
    for (const st of ["todo", "handed_off", "in_progress", "to_verify", "done", "wontfix"] as const) expect(statusOf({ id: "x", state: st })).toBe("keep");
    expect(statusOf({ id: "x", status: "confirmed" })).toBe("keep");
    expect(statusOf({ id: "x", status: "draft" })).toBe("pending");
    expect(statusOf({ id: "x", status: "draft", work: { state: "wontfix" } })).toBe("keep"); // won't do leaves the inbox
  });
  it("never sends the state or the old status as field edits (state goes as its own op)", () => {
    const base = [it2("I-1")];
    const local = clone(base);
    Object.assign(local[0], { state: "todo", status: "confirmed", _touched: true, title: "t2" });
    expect(diffOps(local, B(base))).toEqual([{ op: "set", id: "I-1", set: { title: "t2" }, unset: [] }]);
  });
  it("keeps an item the server no longer lists when asked (discarded on this page)", () => {
    const base = [it2("I-1"), it2("I-2", { state: "discarded" })];
    const r = rebase(clone(base), B(base), [it2("I-1")], false, undefined, (k) => k === "I-2");
    expect(r.items.map((i) => i.id)).toEqual(["I-1", "I-2"]);
    expect(rebase(clone(base), B(base), [it2("I-1")], false).items.map((i) => i.id)).toEqual(["I-1"]);
  });
});

describe("rebase", () => {
  it("takes the server's new fields, keeps the user's unsaved edits", () => {
    const base = [it2("I-1", { actual: "a" })];
    const local = clone(base);
    local[0].actual = "typed";
    const server = [it2("I-1", { actual: "agent", frames: [{ path: "f.jpg" }] })];
    const r = rebase(local, B(base), server, false);
    expect(r.items[0].actual).toBe("typed");
    expect(r.items[0].frames).toEqual([{ path: "f.jpg" }]);
    expect([...r.changed.get("I-1")!]).toEqual(["frames"]);
  });
  it("inserts new agent items after their predecessor", () => {
    const base = [it2("I-1"), it2("I-3")];
    const r = rebase(clone(base), B(base), [it2("I-1"), it2("I-2"), it2("I-3")], false);
    expect(r.items.map((i) => i.id)).toEqual(["I-1", "I-2", "I-3"]);
    expect(r.structural).toBe(true);
    expect(r.changed.get("I-2")).toEqual(new Set(["*"]));
  });
  it("an item removed here stays removed; one removed on the server goes if untouched here", () => {
    const base = [it2("I-1"), it2("I-2"), it2("I-3")];
    const local = clone(base).filter((i) => i.id !== "I-2");
    const r = rebase(local, B(base), [it2("I-1"), it2("I-2")], false);
    expect(r.items.map((i) => i.id)).toEqual(["I-1"]);
  });
  it("undo restores the user's own saved change, not the agent's", () => {
    const before = [it2("I-1", { status: "draft" })];
    const server = [it2("I-1", { status: "deleted", frames: [{ path: "new.jpg" }], _user: { status: 1 } })];
    const r = rebase(clone(before), B(before), server, true);
    expect(r.items[0].status).toBe("draft");
    expect(r.items[0].frames).toEqual([{ path: "new.jpg" }]);
  });
});

describe("diffOps", () => {
  it("sends set / unset / remove / add", () => {
    const base = [it2("I-1", { module: "a", tmp: 1 }), it2("I-2"), it2("I-3")];
    const items = clone(base);
    items[0].module = "b";
    delete items[0].tmp;
    items.splice(1, 1); // I-2 merged into I-1
    items[0].merged_from = ["I-2"];
    items.push(it2("I-9"));
    const ops = diffOps(items, B(base));
    expect(ops).toEqual([
      { op: "set", id: "I-1", set: { module: "b", merged_from: ["I-2"] }, unset: ["tmp"] },
      { op: "add", item: it2("I-9"), after: "I-3" },
      { op: "remove", id: "I-2", into: "I-1" },
    ]);
  });
  it("never sends _user", () => {
    const base = [it2("I-1")];
    const items = clone(base);
    items[0]._user = { title: 5 };
    expect(diffOps(items, B(base))).toEqual([]);
  });
});

describe("mergeInto", () => {
  it("joins text, unions lists, widens time, records merged_from", () => {
    const p = it2("I-1", { quote: "a", actual: "x", steps: ["1", "2"], tags: ["2024"], time: { start: 1, end: 2 }, severity: "high" });
    const i = it2("I-2", { quote: "b", actual: "y", steps: ["2", "3"], tags: ["ui"], time: { start: 0.5, end: 4 }, severity: "low", module: "m" });
    mergeInto(p, i);
    expect(p.quote).toBe("a … b");
    expect(p.actual).toBe("x\ny");
    expect(p.steps).toEqual(["1", "2", "3"]);
    expect(p.tags).toEqual(["2024", "ui"]); // "2024" stays a string
    expect(p.time).toEqual({ start: 0.5, end: 4 });
    expect(p.severity).toBe("high");
    expect(p.module).toBe("m");
    expect(p.merged_from).toEqual(["I-2"]);
  });
  it("v2: never folds uid / fix / fix_history into the target", () => {
    const p = it2("I-1", { uid: "U1", fix: { state: "fixed" } });
    const i = it2("I-2", { uid: "U2", fix: { state: "fixing" }, fix_history: [{ state: "fixing" }] });
    mergeInto(p, i);
    expect(p.uid).toBe("U1");
    expect(p.fix).toEqual({ state: "fixed" });
    expect(p.fix_history).toBeUndefined();
  });
});
