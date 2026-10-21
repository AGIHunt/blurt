import { describe, expect, it } from "vitest";
import type { Item } from "../src/host";
import { canon, clone, diffOps, finalize, mergeInto, norm, rebase, statusOf } from "../src/sync";

const it2 = (id: string, extra: Partial<Item> = {}): Item => ({ id, kind: "issue", title: id, status: "draft", ...extra });
const B = (items: Item[]) => new Map(items.map((i) => [i.id, clone(i)]));

describe("canon", () => {
  it("ignores key order", () => {
    expect(canon({ a: 1, b: { c: 2, d: 3 } })).toBe(canon({ b: { d: 3, c: 2 }, a: 1 }));
  });
});

describe("norm / statusOf", () => {
  it("hides items dropped before this review, defaults kind", () => {
    const n = norm([it2("I-1", { status: "deleted" }), it2("I-2", { status: "deleted", _dropped: true }), { id: "I-3" }]);
    expect(n.map((i) => i.id)).toEqual(["I-2", "I-3"]);
    expect(n[1].kind).toBe("issue");
    expect(statusOf(n[0])).toBe("drop");
    expect(statusOf({ id: "x", _touched: true })).toBe("keep");
    expect(statusOf({ id: "x", status: "confirmed" })).toBe("pending"); // v2: what this review decided
    expect(statusOf({ id: "x", status: "confirmed" }, true)).toBe("keep"); // v3: persistent
    expect(statusOf({ id: "x", status: "draft" })).toBe("pending");
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

it("finalize keeps everything not dropped and strips bookkeeping", () => {
  const f = finalize([it2("I-1", { _touched: true }), it2("I-2", { status: "deleted", _dropped: true, _touched: true }), it2("I-3")]);
  expect(f.map((i) => i.status)).toEqual(["confirmed", "deleted", "confirmed"]);
  expect(f.every((i) => !("_touched" in i) && !("_dropped" in i))).toBe(true);
});
