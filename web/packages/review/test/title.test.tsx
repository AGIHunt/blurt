import { act } from "react";
import { createRoot } from "react-dom/client";
import { describe, expect, it, vi } from "vitest";
import type { BlurtHost, SessionDoc, UserOp } from "../src/host";
import { ReviewStore } from "../src/store";
import { StoreCtx } from "../src/ui/ctx";
import { Inspector } from "../src/ui/Inspector";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

function setup() {
  const doc: SessionDoc = { items: [{ id: "I-001", kind: "issue", title: "Login button does nothing" }] };
  const sent: UserOp[][] = [];
  const host: BlurtHost = {
    host: "macos",
    load: async () => ({ doc: structuredClone(doc), etag: '"1"' }),
    poll: async (e) => ({ etag: e }),
    sendOps: async (ops) => {
      sent.push(ops);
      return { ok: true, etag: `"${sent.length + 1}"` };
    },
    fileUrl: (r) => r,
  };
  return { host, sent };
}

/** what typing does to a controlled textarea: the native value setter, then an input event */
function type(el: HTMLTextAreaElement, v: string) {
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(el, v);
  el.dispatchEvent(new Event("input", { bubbles: true }));
}

describe("an empty title is never saved", () => {
  it("setField refuses empty / whitespace titles", async () => {
    const { host } = setup();
    const s = new ReviewStore(host);
    await s.load();
    for (const v of ["", "   ", "\n", "　", null]) expect(s.setField(s.item!, "title", v)).toBe(false);
    expect(s.item!.title).toBe("Login button does nothing");
    expect(s.pendingOps()).toEqual([]);
    expect(s.setField(s.item!, "title", "Login does nothing")).toBe(true);
    s.dispose();
  });

  it("clearing the title in the inspector reverts to the previous one on blur, and sends no empty title", async () => {
    vi.useFakeTimers();
    const { host, sent } = setup();
    const s = new ReviewStore(host, { lang: "zh" });
    await s.load();
    const el = document.createElement("div");
    document.body.appendChild(el);
    const root = createRoot(el);
    await act(async () => root.render(<StoreCtx.Provider value={s}><Inspector /></StoreCtx.Provider>));
    const ta = el.querySelector("textarea.title") as HTMLTextAreaElement;
    act(() => ta.focus());
    act(() => type(ta, "Login"));
    act(() => type(ta, "   "));
    expect(ta.value).toBe("   "); // what the user typed stays visible while editing
    act(() => ta.blur());
    expect(ta.value).toBe("Login button does nothing");
    expect(s.item!.title).toBe("Login button does nothing");
    expect(s.toast?.msg).toBe("标题不能为空，已恢复原标题");
    await act(async () => vi.advanceTimersByTimeAsync(1500));
    const titles = sent.flat().flatMap((op) => (op.op === "set" && op.set && "title" in op.set ? [op.set.title] : []));
    expect(titles.every((t) => typeof t === "string" && t.trim() !== "")).toBe(true);
    act(() => root.unmount());
    el.remove();
    s.dispose();
    vi.useRealTimers();
  });
});
