// The page's toasts (micro 20): in the Mac app they go up on the island — one place for the main window's toasts —
// and its Undo comes back to the page (or "gone" when the island lets it go); in the browser they stay 5 s and wait
// while pointed at. ⌘Z undoes the page's step after the toast is gone.
import { describe, expect, it, vi } from "vitest";
import type { BlurtHost, SessionDoc } from "../src/host";
import { createMacosHost } from "../src/hosts";
import { ReviewStore } from "../src/store";

const DOC: SessionDoc = { title: "t", items: [{ id: "I-001", kind: "issue", title: "a", status: "draft" }] };

function host(extra: Partial<BlurtHost> = {}): BlurtHost {
  return {
    host: "macos",
    load: async () => ({ doc: structuredClone(DOC), etag: '"1"' }),
    poll: async (e) => ({ etag: e }),
    sendOps: async () => ({ ok: true, etag: '"2"' }),
    fileUrl: (r) => r,
    ...extra,
  };
}

describe("toasts", () => {
  it("go to the host when it shows them (the island), not into the page", async () => {
    const shown: { msg: string; undo: boolean; icon?: string }[] = [];
    const s = new ReviewStore(host({ toast: async (t) => { shown.push(t); return "shown"; } }));
    await s.load();
    s.showToast("Moved to website", false, "check");
    expect(shown).toEqual([{ msg: "Moved to website", undo: false, icon: "check" }]);
    expect(s.toast).toBeNull();
    s.dispose();
  });

  it("the island's Undo undoes the page's step", async () => {
    let answer: (r: string) => void = () => {};
    const s = new ReviewStore(host({ toast: () => new Promise((r) => { answer = r; }) }));
    await s.load();
    const undo = vi.spyOn(s, "undo");
    s.showToast("Done · I-001", true);
    answer("undo");
    await Promise.resolve();
    await Promise.resolve();
    expect(undo).toHaveBeenCalledTimes(1);
    s.dispose();
  });

  it("a toast that went without its Undo undoes nothing", async () => {
    const s = new ReviewStore(host({ toast: async () => "gone" }));
    await s.load();
    const undo = vi.spyOn(s, "undo");
    s.showToast("Done · I-001", true);
    await Promise.resolve();
    await Promise.resolve();
    expect(undo).not.toHaveBeenCalled();
    s.dispose();
  });

  it("in the page: at least 5 s, and held while the pointer is on it", async () => {
    vi.useFakeTimers();
    const s = new ReviewStore(host());
    await s.load();
    s.showToast("Discarded · I-001", true);
    await vi.advanceTimersByTimeAsync(4900);
    expect(s.toast?.show).toBe(true);
    s.holdToast(true);
    await vi.advanceTimersByTimeAsync(20000);
    expect(s.toast?.show).toBe(true);
    s.holdToast(false);
    await vi.advanceTimersByTimeAsync(4900);
    expect(s.toast?.show).toBe(true);
    await vi.advanceTimersByTimeAsync(200);
    expect(s.toast?.show).toBe(false);
    s.dispose();
    vi.useRealTimers();
  });

  it("the macOS bridge offers toast only when the app lists it, and an unanswered one resolves as gone", async () => {
    const sent: { id: number; method: string; params: unknown }[] = [];
    const win = {
      location: { search: "", href: "blurt-app://ui/" },
      webkit: { messageHandlers: { blurt: { postMessage: (m: never) => void sent.push(m) } } },
      blurtHostInfo: { host: "macos", methods: ["toast"] },
    };
    const h = createMacosHost(win as never, 20, 20);
    expect(h.toast).toBeTypeOf("function");
    const p = h.toast!({ msg: "Copied", undo: false, icon: "copy" });
    expect(sent[0].method).toBe("toast");
    expect(sent[0].params).toEqual({ msg: "Copied", undo: false, icon: "copy" });
    await expect(p).resolves.toBe("gone");
    const none = createMacosHost({ ...win, blurtHostInfo: { host: "macos", methods: [] } } as never);
    expect(none.toast).toBeUndefined();
  });

  it("a toast waits as long as the island holds it, past the bridge's usual timeout, for the app's answer", async () => {
    const sent: { id: number; method: string }[] = [];
    const win: Record<string, unknown> = {
      location: { search: "", href: "blurt-app://ui/" },
      webkit: { messageHandlers: { blurt: { postMessage: (m: never) => void sent.push(m) } } },
      blurtHostInfo: { host: "macos", methods: ["toast"] },
    };
    const h = createMacosHost(win as never, 20);
    let answer: string | undefined;
    void h.toast!({ msg: "Done · I-001", undo: true }).then((r) => (answer = r));
    await new Promise((r) => setTimeout(r, 60));
    expect(answer).toBeUndefined();
    (win.__blurtReply as (id: number, r: unknown, e: unknown) => void)(sent[0].id, "gone", null);
    await Promise.resolve();
    await Promise.resolve();
    expect(answer).toBe("gone");
  });

  it("⌘Z undoes the page's last step after its toast is gone, and leaves a text field's own undo alone", async () => {
    const s = new ReviewStore(host({ toast: async () => "gone" }));
    await s.load();
    const undo = vi.spyOn(s, "undo");
    const z = () => {
      const e = new KeyboardEvent("keydown", { key: "z", metaKey: true, cancelable: true });
      s.onKeyDown(e);
      return e.defaultPrevented;
    };
    expect(z()).toBe(false);
    expect(undo).not.toHaveBeenCalled();
    s.act([s.item ?? s.data.items[0]], "discard");
    expect(z()).toBe(true);
    expect(undo).toHaveBeenCalledTimes(1);
    s.act([s.item ?? s.data.items[0]], "discard");
    const ta = document.createElement("textarea");
    document.body.appendChild(ta);
    ta.focus();
    expect(z()).toBe(false);
    ta.remove();
    s.dispose();
  });
});
