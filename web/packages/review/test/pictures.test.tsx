// An item's pictures in the detail (v1.0.23): the one on show can be removed (one undoable field edit, its file is
// left alone), and "Add image or file…" next to Add Field asks the host for its file picker.
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { BlurtHost, Item, SessionDoc, UserOp } from "../src/host";
import { ReviewStore } from "../src/store";
import { StoreCtx } from "../src/ui/ctx";
import { Inspector } from "../src/ui/Inspector";
import { Attachment } from "../src/ui/Stage";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let root: Root | null = null;
let el: HTMLElement | null = null;
let store: ReviewStore | null = null;
afterEach(() => {
  act(() => root?.unmount());
  el?.remove();
  store?.dispose();
  root = el = store = null;
  vi.useRealTimers();
});

const A = { path: "/store/assets/U1/a.png" }, B = { path: "/store/assets/U1/b.png" };

async function show(item: Partial<Item>, extra: Partial<BlurtHost> = {}) {
  const doc: SessionDoc = { items: [{ id: "I-001", uid: "U1", kind: "note", title: "Homepage teardown", ...item }] };
  const sent: UserOp[][] = [];
  const host: BlurtHost = {
    host: "browser",
    load: async () => ({ doc, etag: '"1"' }),
    poll: async (e) => ({ etag: e }),
    sendOps: async (ops) => (sent.push(ops), { ok: true, etag: '"2"' }),
    fileUrl: (r) => r,
    ...extra,
  };
  const s = (store = new ReviewStore(host, { lang: "en" }));
  await s.load();
  el = document.body.appendChild(document.createElement("div"));
  root = createRoot(el);
  await act(async () => root!.render(<StoreCtx.Provider value={s}><Inspector media={<Attachment />} /></StoreCtx.Provider>));
  return { s, sent };
}
const click = (b: Element | null | undefined) => act(() => (b as HTMLElement).click());

describe("the item's pictures", () => {
  it("Remove takes the picture on show off the item: a field edit, one undo step", async () => {
    vi.useFakeTimers();
    const { s, sent } = await show({ frames: [A, B] });
    const rm = () => el!.querySelector<HTMLButtonElement>("#mediaRemove");
    expect(rm()!.getAttribute("aria-label")).toBe("Remove picture");
    await click(rm());
    expect(s.item!.frames).toEqual([B]);
    expect(s.toast).toMatchObject({ msg: "Picture removed", undo: true });
    expect(s.undoName).toBe("Edit Pictures");
    act(() => s.undo());
    expect(s.item!.frames).toEqual([A, B]);
    await click(rm());
    await act(() => vi.advanceTimersByTimeAsync(500));
    expect(sent).toEqual([[{ op: "set", id: "I-001", set: { frames: [B] }, unset: [] }]]);
    // the last one: the section goes with it
    await click(rm());
    expect(s.item!.frames).toEqual([]);
    expect(el!.querySelector("#attachment")).toBeNull();
  });

  it("a read-only item keeps its pictures: no Remove, no Add", async () => {
    await show({ frames: [A], _readonly: true }, { addFiles: vi.fn() });
    expect(el!.querySelector("#mediaRemove")).toBeNull();
    expect(el!.querySelector("#addFiles")).toBeNull();
  });

  it("Add image or file… asks the host's picker for this item; a host without one shows no button", async () => {
    const addFiles = vi.fn();
    await show({}, { addFiles });
    const b = el!.querySelector<HTMLButtonElement>("#addFiles")!;
    expect(b.textContent).toContain("Add image or file…");
    await click(b);
    expect(addFiles).toHaveBeenCalledWith("U1");
    act(() => root?.unmount());
    el?.remove();
    store?.dispose();
    await show({});
    expect(el!.querySelector("#addFiles")).toBeNull();
  });
});
