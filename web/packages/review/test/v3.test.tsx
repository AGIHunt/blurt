import { checkCatalogs } from "@blurt/i18n";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { BlurtHost, Scope, UserOp } from "../src/host";
import { CATALOGS } from "../src/i18n";
import { ReviewStore } from "../src/store";
import { StoreCtx } from "../src/ui/ctx";
import { Inspector } from "../src/ui/Inspector";
import { ListView } from "../src/ui/Views";
import { MemStore, PROJECTS, V3_ITEMS } from "./v3store";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
Element.prototype.scrollIntoView ??= () => {};

function v3Host(scope: Scope, extra: Partial<BlurtHost> = {}) {
  const m = new MemStore(V3_ITEMS, PROJECTS, { title: "Batch", language: "en" });
  const sent: UserOp[][] = [];
  const host: BlurtHost = {
    host: "macos",
    scope,
    load: async () => ({ doc: m.doc(scope), etag: m.etag }),
    poll: async (e) => (e === m.etag ? { etag: e } : { doc: m.doc(scope), etag: m.etag }),
    sendOps: async (ops, confirm) => {
      sent.push(ops);
      m.apply(ops, confirm);
      return { ok: true, etag: m.etag }; // acknowledge only, like the macOS bridge
    },
    fileUrl: (p) => "blurt-app://file/" + encodeURIComponent(p),
    ...extra,
  };
  return { m, host, sent };
}
const flush = async () => {
  await vi.advanceTimersByTimeAsync(500);
};
const U = (n: number) => V3_ITEMS[n].uid!;

afterEach(() => vi.useRealTimers());

describe("v3 doc: ops by uid", () => {
  it("edits go out addressed by uid; server-owned fields never do", async () => {
    vi.useFakeTimers();
    const { host, sent } = v3Host({ session: "/s" });
    const s = new ReviewStore(host, { lang: "en" });
    await s.load();
    expect(s.v3).toBe(true);
    s.setField(s.data.items[0], "module", "billing");
    await flush();
    expect(sent[0]).toEqual([{ op: "set", id: U(0), set: { module: "billing" }, unset: [] }]);
    s.dispose();
  });

  it("a project move changes the id; an unsaved edit typed meanwhile survives, keyed by uid", async () => {
    vi.useFakeTimers();
    const { m, host, sent } = v3Host({ session: "/s" });
    const s = new ReviewStore(host, { lang: "en" });
    await s.load();
    // the bridge answers slowly: the user keeps typing while the move is in flight
    let release!: () => void;
    const send = host.sendOps;
    host.sendOps = async (ops, c) => {
      await new Promise<void>((r) => (release = r));
      return send(ops, c);
    };
    s.moveTo([s.data.items[0]], "p-site");
    await vi.advanceTimersByTimeAsync(1);
    s.setField(s.data.items[0], "actual", "typed while the move was in flight");
    release();
    await vi.advanceTimersByTimeAsync(1);
    host.sendOps = send;
    expect(sent[0]).toEqual([{ op: "set", id: U(0), set: { project: "p-site" }, unset: [] }]);
    expect(s.data.items[0].id).toBe("WS-8"); // the server's new id is in, the typing is still local
    expect(s.data.items[0].actual).toBe("typed while the move was in flight");
    await flush();
    expect(sent[1]).toEqual([{ op: "set", id: U(0), set: { actual: "typed while the move was in flight" }, unset: [] }]);
    const now = s.data.items.find((i) => i.uid === U(0))!;
    expect(now.id).toBe("WS-8");
    expect(now.aliases).toEqual(["BA-12"]);
    expect(now.actual).toBe("typed while the move was in flight");
    expect(m.items.find((i) => i.uid === U(0))!.actual).toBe("typed while the move was in flight");
    expect(s.pendingOps()).toEqual([]);
    expect(s.toast?.msg).toBe("Moved to website");
    s.dispose();
  });

  it("in a project's list, items moved away leave the list (no phantom re-add)", async () => {
    vi.useFakeTimers();
    const { host, sent } = v3Host({ project: "p-blurt" });
    const s = new ReviewStore(host, { lang: "en" });
    await s.load();
    expect(s.data.items.map((i) => i.id)).toEqual(["BA-12", "BA-13", "BA-14", "BA-15", "BA-16"]);
    s.moveTo([s.data.items[1], s.data.items[3]], "inbox");
    await flush();
    expect(s.data.items.map((i) => i.id)).toEqual(["BA-12", "BA-14", "BA-16"]);
    expect(sent.flat().every((o) => o.op === "set")).toBe(true);
    expect(s.pendingOps()).toEqual([]);
    expect(s.toast?.msg).toBe("Moved 2 items to Unassigned");
    s.dispose();
  });

  it("work: the user confirms done; optimistic, sent as a work op, history kept", async () => {
    vi.useFakeTimers();
    const { m, host, sent } = v3Host({ session: "/s" });
    const s = new ReviewStore(host, { lang: "en" });
    await s.load();
    s.setWork([s.data.items[0]], "done");
    expect(s.workOf(s.data.items[0])).toBe("done"); // before the server answers
    await flush();
    expect(sent[0]).toEqual([{ op: "work", id: U(0), state: "done" }]);
    const f = m.items[0];
    expect(f.work!.state).toBe("done");
    expect(f.work_history!.map((w) => w.state)).toEqual(["handed_off", "to_verify"]);
    expect(s.data.items[0].work!.state).toBe("done");
    s.dispose();
  });

  it("an agent's to_verify arrives by poll while nothing is pending", async () => {
    vi.useFakeTimers();
    const { m, host } = v3Host({ session: "/s" });
    const s = new ReviewStore(host, { lang: "en" });
    await s.load();
    m.agentWork(U(5), "to_verify", "fixed");
    await vi.advanceTimersByTimeAsync(2100);
    expect(s.workOf(s.data.items[5])).toBe("to_verify");
    s.dispose();
  });

  it("merge in v3 records uids and removes by uid", async () => {
    vi.useFakeTimers();
    const { host, sent } = v3Host({ session: "/s" });
    const s = new ReviewStore(host, { lang: "en" });
    await s.load();
    s.go(1);
    s.mergePrev();
    await flush();
    expect(sent[0]).toEqual(expect.arrayContaining([{ op: "remove", id: U(1), into: U(0) }]));
    expect(s.data.items[0].merged_from).toEqual([U(1)]);
    s.dispose();
  });
});

describe("v3 UI", () => {
  async function mount(node: React.ReactNode, extra: Partial<BlurtHost> = {}, lang = "en") {
    const h = v3Host({ session: "/s" }, extra);
    const s = new ReviewStore(h.host, { lang });
    await s.load();
    const el = document.createElement("div");
    const root = createRoot(el);
    await act(async () => root.render(<StoreCtx.Provider value={s}>{node}</StoreCtx.Provider>));
    return { s, el, ...h, done: () => (act(() => root.unmount()), s.dispose()) };
  }

  it("inspector: project picker, work panel with Mark as done, provenance, handoff buttons", async () => {
    const handoff = vi.fn(async () => ({ id: "H-0013", path: "/h/H-0013.md", text: "Please handle BA-12 …" }));
    const dispatch = vi.fn();
    const { el, s, done } = await mount(<Inspector />, { handoff, dispatch, openSession: vi.fn() });
    expect((el.querySelector("#projectPick") as HTMLSelectElement).value).toBe("p-blurt");
    expect(el.querySelector("#workRow .sring.s-to_verify")?.getAttribute("aria-label")).toBe("To verify");
    expect(el.querySelector(".work-claim")?.textContent).toMatch(/says it's fixed/);
    expect(el.querySelector("#workDone")?.textContent).toContain("Mark as done");
    expect(el.querySelector("#workSession")).not.toBeNull();
    expect(el.querySelector("#provenance")?.textContent).toMatch(/Screen recording.*at 0:12/);
    expect(el.querySelector("#provenance")?.textContent).toContain("Captured in this project");
    expect(el.querySelector("#provenance")?.textContent).toContain("blurt.dev/login");
    await act(async () => (el.querySelector("#copyInstruction") as HTMLButtonElement).click());
    expect(handoff).toHaveBeenCalledWith([U(0)], "instruction");
    expect(s.toast?.msg).toBe("Instruction copied · H-0013");
    await act(async () => (el.querySelector("#dispatchBtn") as HTMLButtonElement).click());
    expect(dispatch).toHaveBeenCalledWith([U(0)]);
    done();
  });

  it("an inbox item shows the AI's suggestion; accepting moves it", async () => {
    vi.useFakeTimers();
    const { el, s, sent, done } = await mount(<Inspector />);
    await act(async () => s.go(1));
    expect(el.querySelector(".prov-sug")?.textContent).toContain("Looks like website");
    await act(async () => (el.querySelector("#acceptSuggestion") as HTMLButtonElement).click());
    await act(flush);
    expect(sent[0][0]).toEqual({ op: "set", id: U(1), set: { project: "p-site" }, unset: [] });
    expect(s.data.items[1].id).toBe("WS-8");
    done();
  });

  it("list: kind icons, six work rings, multi-select and batch move", async () => {
    vi.useFakeTimers();
    const { el, s, sent, done } = await mount(<ListView />, {}, "zh-Hans");
    const cards = [...el.querySelectorAll(".card")];
    expect(cards.map((c) => c.querySelector(".kind-ic")!.className)).toEqual([
      "kind-ic k-issue", "kind-ic k-idea", "kind-ic k-task", "kind-ic k-note", "kind-ic k-competitor", "kind-ic k-issue", "kind-ic k-issue"]);
    expect(new Set(cards.map((c) => c.querySelector(".sring")!.getAttribute("class")))).toEqual(
      new Set(["sring s-to_verify", "sring s-todo", "sring s-handed_off", "sring s-wontfix", "sring s-in_progress", "sring s-done"]));
    expect(cards[2].querySelector(".wk")?.textContent).toBe("已复制给外部 agent");
    expect(cards[5].querySelector(".wk")?.textContent).toBe("进行中");
    await act(async () => (cards[0].querySelector(".pickbox") as HTMLButtonElement).click());
    await act(async () => (cards[2].querySelector(".pickbox") as HTMLButtonElement).click());
    expect(el.querySelector(".selcount")?.textContent).toBe("已选 2 条");
    const pick = el.querySelector("#selMove") as HTMLSelectElement;
    await act(async () => {
      pick.value = "p-site";
      pick.dispatchEvent(new Event("change", { bubbles: true }));
    });
    await act(flush);
    expect(sent[0].map((o) => o.op === "set" && o.set.project)).toEqual(["p-site", "p-site"]);
    expect(s.data.items.filter((i) => i.project === "p-site").map((i) => i.id).sort()).toEqual(["WS-7", "WS-8", "WS-9"]);
    expect(s.toast?.msg).toBe("已把 2 条移到 website");
    done();
  });
});

describe("catalogs (K10)", () => {
  it("en and zh-Hans have the same keys and placeholders", () => {
    expect(checkCatalogs(CATALOGS.en, CATALOGS["zh-Hans"])).toEqual([]);
  });
  it("every key the source uses exists", () => {
    const SRC = join(__dirname, "../src");
    const files = (d: string): string[] =>
      readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? files(join(d, e.name)) : [join(d, e.name)]));
    const common = JSON.parse(readFileSync(join(__dirname, "../../i18n/src/common/en.json"), "utf8"));
    const known = (k: string) => k in CATALOGS.en || k in common || `${k}_other` in CATALOGS.en;
    const missing: string[] = [];
    for (const f of files(SRC).filter((f) => /\.tsx?$/.test(f))) {
      const src = readFileSync(f, "utf8");
      for (const m of src.matchAll(/\b(?:t|plural)\(\s*"([a-z_]+(?:\.[a-z_]+)+)"/g)) if (!known(m[1])) missing.push(`${f.slice(SRC.length + 1)}: ${m[1]}`);
      for (const m of src.matchAll(/"((?:keys|work|project|source|severity|type|handoff|select)\.[a-z_.]+)"/g)) if (!known(m[1]) && !/\.$/.test(m[1])) missing.push(`${f.slice(SRC.length + 1)}: ${m[1]}`);
    }
    expect(missing).toEqual([]);
  });
});
