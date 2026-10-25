// The page's toasts (micro 20): in the Mac app they go up on the island — one place for the main window's toasts —
// and its Undo comes back to the page; in the browser they stay 5 s and wait while pointed at.
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
    const h = createMacosHost(win as never, 20);
    expect(h.toast).toBeTypeOf("function");
    const p = h.toast!({ msg: "Copied", undo: false, icon: "copy" });
    expect(sent[0].method).toBe("toast");
    expect(sent[0].params).toEqual({ msg: "Copied", undo: false, icon: "copy" });
    await expect(p).resolves.toBe("gone");
    const none = createMacosHost({ ...win, blurtHostInfo: { host: "macos", methods: [] } } as never);
    expect(none.toast).toBeUndefined();
  });
});
