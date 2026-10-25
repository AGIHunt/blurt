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
    // said while typing, not after the fact: the field is marked and a line under it explains
    expect(ta.getAttribute("aria-invalid")).toBe("true");
    expect(el.querySelector("#titleErr")?.textContent).toBe("标题不能为空。按 Esc 恢复原标题。");
    // Return doesn't commit an empty title: the focus stays
    act(() => void ta.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })));
    expect(document.activeElement).toBe(ta);
    act(() => ta.blur());
    expect(ta.value).toBe("Login button does nothing");
    expect(s.item!.title).toBe("Login button does nothing");
    expect(el.querySelector("#titleErr")).toBeNull();
    await act(async () => vi.advanceTimersByTimeAsync(1500));
    const titles = sent.flat().flatMap((op) => (op.op === "set" && op.set && "title" in op.set ? [op.set.title] : []));
    expect(titles.every((t) => typeof t === "string" && t.trim() !== "")).toBe(true);
    act(() => root.unmount());
    el.remove();
    s.dispose();
    vi.useRealTimers();
  });
});

/** the inspector mounted on a store whose host keeps the window's undo stack (the Mac app) */
async function mounted(lang = "en") {
  const { host, sent } = setup();
  const labels: string[] = [];
  const asked: boolean[] = [];
  host.registerUndo = (l) => labels.push(l);
  host.windowUndo = (redo) => asked.push(redo);
  const s = new ReviewStore(host, { lang, mode: "item", itemId: "I-001" });
  await s.load();
  const el = document.createElement("div");
  document.body.appendChild(el);
  const root = createRoot(el);
  await act(async () => root.render(<StoreCtx.Provider value={s}><Inspector /></StoreCtx.Provider>));
  const done = () => {
    act(() => root.unmount());
    el.remove();
    s.dispose();
  };
  return { s, el, labels, asked, sent, done };
}
const key = (el: Element, k: string, o: KeyboardEventInit = {}) =>
  act(() => void el.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...o })));

describe("one undo stack per window (micro 3, 4, 12, 13)", () => {
  it("a field's editing session is one step on the host's stack; the host's undo/redo come back to the page", async () => {
    const { s, el, labels, done } = await mounted();
    const ta = el.querySelector("textarea.title") as HTMLTextAreaElement;
    act(() => ta.focus());
    act(() => type(ta, "Login"));
    act(() => type(ta, "Login fails on Safari"));
    expect(labels).toEqual([]); // nothing while typing
    act(() => ta.blur());
    expect(labels).toEqual(["Edit"]); // one step for the whole edit
    act(() => s.undo()); // the host's ⌘Z
    expect(s.item!.title).toBe("Login button does nothing");
    act(() => s.redo()); // ⇧⌘Z
    expect(s.item!.title).toBe("Login fails on Safari");
    // focus and blur without a change: no step
    act(() => ta.focus());
    act(() => ta.blur());
    expect(labels).toEqual(["Edit"]);
    done();
  });

  it("Esc cancels an edit: the value from when editing began comes back, and no step is left", async () => {
    const { s, el, labels, done } = await mounted();
    const ta = el.querySelector("textarea.title") as HTMLTextAreaElement;
    act(() => ta.focus());
    act(() => type(ta, "oops"));
    expect(s.item!.title).toBe("oops"); // autosaving as before
    key(ta, "Escape");
    expect(s.item!.title).toBe("Login button does nothing");
    expect(ta.value).toBe("Login button does nothing");
    expect(document.activeElement).not.toBe(ta);
    expect(labels).toEqual([]);
    done();
  });

  it("⌘Z outside a field asks the host (the window's stack); chips and 1–4 are undoable steps", async () => {
    const { s, el, labels, asked, done } = await mounted();
    const page = (k: string, o: KeyboardEventInit = {}) => act(() => s.onKeyDown(new KeyboardEvent("keydown", { key: k, cancelable: true, ...o })));
    page("z", { metaKey: true });
    page("z", { metaKey: true, shiftKey: true });
    expect(asked).toEqual([false, true]);
    page("2"); // 1–4 = kind, as in the list
    expect(s.item!.kind).toBe("idea");
    page("1");
    const sev = el.querySelector("#sevChip") as HTMLSelectElement;
    expect([...sev.options].map((o) => o.value)).toEqual(["high", "medium", "low"]);
    act(() => {
      Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(sev, "high");
      sev.dispatchEvent(new Event("change", { bubbles: true }));
    });
    expect(s.item!.severity).toBe("high");
    expect(labels).toEqual(["Edit", "Edit", "Edit"]);
    act(() => s.undo());
    expect(s.item!.severity).toBeUndefined();
    done();
  });
});
