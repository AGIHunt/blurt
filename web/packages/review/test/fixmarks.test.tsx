import { act } from "react";
import { createRoot } from "react-dom/client";
import { describe, expect, it } from "vitest";
import type { BlurtHost, SessionDoc } from "../src/host";
import { ReviewStore } from "../src/store";
import { StoreCtx } from "../src/ui/ctx";
import { Queue } from "../src/ui/Queue";
import { ListView, Overview } from "../src/ui/Views";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
Element.prototype.scrollIntoView ??= () => {}; // jsdom has none; the queue keeps the current row in view

const doc: SessionDoc = {
  items: [
    { id: "I-001", kind: "issue", title: "fixed one", fix: { state: "fixed", agent: "codex", at: 1 } },
    { id: "I-002", kind: "issue", title: "being fixed", fix: { state: "fixing", agent: "claude", at: 1 } },
    { id: "I-003", kind: "issue", title: "untouched" },
    { id: "I-004", kind: "issue", title: "wontfix", fix: { state: "wontfix", at: 1 } },
  ],
};

async function render(node: React.ReactNode) {
  const host: BlurtHost = {
    host: "browser",
    load: async () => ({ doc: structuredClone(doc), etag: '"1"' }),
    poll: async (e) => ({ etag: e }),
    sendOps: async () => ({ ok: true, etag: '"2"' }),
    fileUrl: (r) => r,
  };
  const s = new ReviewStore(host, { lang: "zh" });
  await s.load();
  const el = document.createElement("div");
  const root = createRoot(el);
  await act(async () => root.render(<StoreCtx.Provider value={s}>{node}</StoreCtx.Provider>));
  return { el, done: () => (act(() => root.unmount()), s.dispose()) };
}

describe("the item list shows the fix state (as in the main window)", () => {
  it("queue rows: fixed = struck + check, fixing = agent-run mark, others plain", async () => {
    const { el, done } = await render(<Queue />);
    const rows = [...el.querySelectorAll(".qi")];
    expect(rows.map((r) => r.classList.contains("fx-fixed"))).toEqual([true, false, false, false]);
    expect(rows.map((r) => r.classList.contains("fx-fixing"))).toEqual([false, true, false, false]);
    expect(rows[0].querySelector(".fxi-fixed title")?.textContent).toBe("已修");
    expect(rows[1].querySelector(".fxi-fixing title")?.textContent).toBe("修复中…");
    expect(rows[2].querySelector(".fxi")).toBeNull();
    expect(rows[3].querySelector(".fxi")).toBeNull();
    done();
  });
  it("list cards too", async () => {
    const { el, done } = await render(<ListView />);
    const cards = [...el.querySelectorAll(".card")];
    expect(cards[0].classList.contains("fx-fixed")).toBe(true);
    expect(cards[0].querySelector(".tt .fxi-fixed")).not.toBeNull();
    expect(cards[1].querySelector(".tt .fxi-fixing")).not.toBeNull();
    done();
  });
  it("and the overview's lists", async () => {
    const { el, done } = await render(<Overview />);
    const rows = [...el.querySelectorAll(".ov-list button")];
    expect(rows[0].classList.contains("fx-fixed")).toBe(true);
    expect(rows[0].querySelector(".tt .fxi-fixed")).not.toBeNull();
    expect(rows[1].querySelector(".tt .fxi-fixing")).not.toBeNull();
    expect(rows[2].querySelector(".fxi")).toBeNull();
    done();
  });
});
