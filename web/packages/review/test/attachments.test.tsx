// An item's attached files (`attachments`, absolute paths): one row a file — icon by kind, name, folder — that opens,
// reveals and removes it; never the raw list in a text field.
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { attachedFiles, fileFolder, fileKind, fileName, nameParts } from "../src/files";
import type { BlurtHost, Item, SessionDoc, UserOp } from "../src/host";
import { ReviewStore } from "../src/store";
import { StoreCtx } from "../src/ui/ctx";
import { Inspector } from "../src/ui/Inspector";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const PDF = "/Users/me/Documents/specs/spec-v2.pdf";
const MP4 = "/Users/me/Movies/walkthrough.mp4";
const DOCX = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Work/Clients/Northwind/2026/Q4/Quarterly planning notes — final v3 (reviewed).docx";

describe("files: names, folders, kinds", () => {
  it("picks the kind by extension, whatever its case", () => {
    const kinds = { "a.pdf": "pdf", "a.MP4": "video", "a.mov": "video", "a.m4a": "audio", "a.PNG": "image", "a.zip": "archive",
      "a.tar.gz": "archive", "a.ts": "code", "notes.md": "text", "a.xlsx": "sheet", "a.csv": "sheet", "a.docx": "doc",
      "a.key": "slides", "a.pptx": "slides", "Makefile": "file", "a.xyz": "file", ".gitignore": "file" };
    for (const [n, k] of Object.entries(kinds)) expect([n, fileKind("/x/" + n)]).toEqual([n, k]);
  });
  it("the name, and the folder with the home folder as ~", () => {
    expect(fileName(PDF)).toBe("spec-v2.pdf");
    expect(fileFolder(PDF)).toBe("~/Documents/specs");
    expect(fileFolder("/home/ana/notes/a.txt")).toBe("~/notes");
    expect(fileFolder("/Users/me/a.txt")).toBe("~");
    expect(fileFolder("/Volumes/Share/a.txt")).toBe("/Volumes/Share");
    expect(fileFolder("/a.txt")).toBe("/");
    expect(fileFolder("a.txt")).toBe("");
    expect([fileName("C:\\Users\\ana\\Desktop\\a.pdf"), fileFolder("C:\\Users\\ana\\Desktop\\a.pdf")]).toEqual(["a.pdf", "~\\Desktop"]);
  });
  it("a long name is two parts (the end keeps the extension); a short one is whole", () => {
    expect(nameParts("spec-v2.pdf")).toEqual(["spec-v2.pdf", ""]);
    const [head, tail] = nameParts(fileName(DOCX));
    expect(head + tail).toBe(fileName(DOCX));
    expect(tail).toBe("viewed).docx");
  });
  it("only the strings of the list are files", () => {
    expect(attachedFiles([PDF, 7, null, "", { path: "/x" }, MP4])).toEqual([[0, PDF], [5, MP4]]);
    expect(attachedFiles(PDF)).toEqual([[0, PDF]]);
    expect(attachedFiles(undefined)).toEqual([]);
    expect(attachedFiles({ 0: PDF })).toEqual([]);
  });
});

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

async function show(item: Partial<Item>, extra: Partial<BlurtHost> = {}, lang = "en") {
  const doc: SessionDoc = { items: [{ id: "I-001", kind: "note", title: "Homepage teardown", ...item }] };
  const sent: UserOp[][] = [];
  const host: BlurtHost = {
    host: "browser",
    load: async () => ({ doc, etag: '"1"' }),
    poll: async (e) => ({ etag: e }),
    sendOps: async (ops) => (sent.push(ops), { ok: true, etag: '"2"' }),
    fileUrl: (r) => r,
    ...extra,
  };
  const s = (store = new ReviewStore(host, { lang }));
  await s.load();
  el = document.body.appendChild(document.createElement("div"));
  root = createRoot(el);
  await act(async () => root!.render(<StoreCtx.Provider value={s}><Inspector /></StoreCtx.Provider>));
  const rows = () => [...el!.querySelectorAll<HTMLElement>(".files .file")];
  const open = (n: number) => rows()[n].querySelector<HTMLButtonElement>(".file-open")!;
  return { s, sent, rows, open, files: () => el!.querySelector(".files") };
}
const click = (b: Element | null | undefined) => act(() => (b as HTMLElement).click());

describe("the inspector's attached files", () => {
  it("one row a file from the list: icon, name, folder — not a text field of paths", async () => {
    const { rows, files } = await show({ attachments: [PDF, 42, MP4, null, DOCX] });
    expect(files()!.querySelector(".sec-h")!.textContent).toBe("Attachments");
    expect(rows().map((r) => r.querySelector(".file-n")!.textContent)).toEqual(["spec-v2.pdf", "walkthrough.mp4", fileName(DOCX)]);
    expect(rows().map((r) => r.querySelector(".file-d")!.textContent)).toEqual(
      ["~/Documents/specs", "~/Movies", "~/Library/Mobile Documents/com~apple~CloudDocs/Work/Clients/Northwind/2026/Q4"]);
    expect(rows().map((r) => r.querySelector(".file-open")!.getAttribute("title"))).toEqual([PDF, MP4, DOCX]);
    for (const r of rows()) expect(r.querySelector(".file-ic svg.ico path")).not.toBeNull();
    // three kinds, three different drawings
    expect(new Set(rows().map((r) => r.querySelector(".file-ic")!.innerHTML)).size).toBe(3);
    // never also the generic list field, in the page or in Add Field
    expect(el!.querySelector('[data-k="attachments"]')).toBeNull();
    expect([...el!.querySelectorAll("#addField option")].map((o) => o.getAttribute("value"))).not.toContain("attachments");
    expect(el!.textContent).not.toContain("- /Users");
  });

  it("the label is localized; no list, no section", async () => {
    const zh = await show({ attachments: [PDF] }, {}, "zh-Hans");
    expect(zh.files()!.querySelector(".sec-h")!.textContent).toBe("附件");
    expect(zh.open(0).getAttribute("aria-label")).toBe("复制路径：spec-v2.pdf");
    act(() => root!.unmount());
    const none = await show({ attachments: [] });
    expect(none.files()).toBeNull();
    act(() => root!.unmount());
    expect((await show({ attachments: [3, null] })).files()).toBeNull();
  });

  it("a click is Quick Look where the host has it; Show in Finder is the button beside it", async () => {
    const quickLook = vi.fn();
    const reveal = vi.fn();
    const { rows, open } = await show({ attachments: [PDF, MP4] }, { host: "macos", quickLook, reveal });
    expect(open(0).getAttribute("aria-label")).toBe("Quick Look: spec-v2.pdf");
    await click(open(1));
    expect(quickLook.mock.calls).toEqual([[MP4]]);
    expect(reveal).not.toHaveBeenCalled();
    const show1 = rows()[0].querySelector<HTMLElement>('.file-a button[aria-label="Show in Finder: spec-v2.pdf"]');
    await click(show1);
    expect(reveal.mock.calls).toEqual([[PDF]]);
    expect(quickLook).toHaveBeenCalledTimes(1);
  });

  it("without Quick Look a click shows it in its folder; with neither it copies the path", async () => {
    const reveal = vi.fn();
    const a = await show({ attachments: [PDF] }, { host: "tauri", reveal });
    expect(a.open(0).getAttribute("aria-label")).toBe("Show in Folder: spec-v2.pdf");
    await click(a.open(0));
    expect(reveal.mock.calls).toEqual([[PDF]]);
    // the row already reveals: no second button for the same thing
    expect(a.rows()[0].querySelectorAll(".file-a button").length).toBe(1);
    act(() => root!.unmount());
    const writeText = vi.fn();
    Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
    const b = await show({ attachments: [PDF] });
    await click(b.open(0));
    expect(writeText.mock.calls).toEqual([[PDF]]);
  });

  it("Remove takes the path out of the field — sent like any field edit, one undo step; the last one takes the section", async () => {
    vi.useFakeTimers();
    const { s, sent, rows, files } = await show({ attachments: [PDF, 42, MP4] });
    await click(rows()[0].querySelector('.file-rm[aria-label="Remove: spec-v2.pdf"]'));
    expect(s.item!.attachments).toEqual([42, MP4]); // what isn't a path is left as it was
    expect(rows().map((r) => r.querySelector(".file-n")!.textContent)).toEqual(["walkthrough.mp4"]);
    expect(s.toast).toMatchObject({ msg: "Removed spec-v2.pdf", undo: true });
    expect(s.undoName).toBe("Edit Attachments");
    act(() => s.undo());
    expect(s.item!.attachments).toEqual([PDF, 42, MP4]);
    expect(rows().length).toBe(2);
    await click(rows()[0].querySelector(".file-rm"));
    await act(() => vi.advanceTimersByTimeAsync(500));
    expect(sent).toEqual([[{ op: "set", id: "I-001", set: { attachments: [42, MP4] }, unset: [] }]]);
    await click(rows()[0].querySelector(".file-rm"));
    expect(s.item!.attachments).toEqual([42]);
    expect(files()).toBeNull();
  });

  it("a read-only item: the rows open, nothing removes", async () => {
    const quickLook = vi.fn();
    const { s, rows, open } = await show({ attachments: [PDF, MP4], _readonly: true }, { quickLook });
    expect(rows().length).toBe(2);
    expect(el!.querySelector(".file-rm")).toBeNull();
    act(() => void open(0).dispatchEvent(new KeyboardEvent("keydown", { key: "Backspace", bubbles: true, cancelable: true })));
    expect(s.item!.attachments).toEqual([PDF, MP4]);
    await click(open(0));
    expect(quickLook.mock.calls).toEqual([[PDF]]);
  });

  it("keys on a row are the row's: ⌫ removes it and the next row takes the focus; Enter, Space and ⌫ never reach the page", async () => {
    const { s, rows, open } = await show({ attachments: [PDF, MP4, DOCX] });
    const page = vi.fn();
    document.addEventListener("keydown", page);
    try {
      const press = (t: HTMLElement, key: string) => {
        const e = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
        act(() => void t.dispatchEvent(e));
        return e;
      };
      open(1).focus();
      expect(press(open(1), "Enter").defaultPrevented).toBe(false); // the button's own click follows
      press(open(1), " ");
      press(rows()[1].querySelector<HTMLElement>(".file-rm")!, "Enter");
      expect(s.item!.attachments).toEqual([PDF, MP4, DOCX]);
      expect(press(open(1), "Backspace").defaultPrevented).toBe(true);
      expect(s.item!.attachments).toEqual([PDF, DOCX]);
      expect(document.activeElement).toBe(open(1));
      expect(open(1).getAttribute("title")).toBe(DOCX);
      press(open(1), "Delete");
      expect(s.item!.attachments).toEqual([PDF]);
      expect(document.activeElement).toBe(open(0));
      expect(page).not.toHaveBeenCalled();
      press(open(0), "j"); // any other key is still the page's
      expect(page).toHaveBeenCalledTimes(1);
    } finally {
      document.removeEventListener("keydown", page);
    }
  });
});
