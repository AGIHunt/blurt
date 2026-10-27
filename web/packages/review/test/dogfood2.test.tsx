// dogfood-2 (work): what the item detail must never hide or show raw — a task's acceptance criterion, internal
// fields ("enrich: pending"), agent ids, bundle ids, capture-folder names, uids of merged items, the host's raw load
// error — and a hand-broken item that says it can't be read, never that it's gone.
import { act } from "react";
import { createRoot } from "react-dom/client";
import { describe, expect, it } from "vitest";
import type { BlurtHost, ReviewDoc } from "../src/host";
import { ReviewStore } from "../src/store";
import { App } from "../src/ui/App";
import { StoreCtx } from "../src/ui/ctx";
import { appLabel, Inspector } from "../src/ui/Inspector";
import { agentName, stateText } from "../src/ui/Queue";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const host = (doc: ReviewDoc | (() => never)): BlurtHost => ({
  host: "browser",
  load: async () => (typeof doc === "function" ? doc() : { doc, etag: '"1"' }),
  poll: async (e) => ({ etag: e }),
  sendOps: async () => ({ ok: true, etag: '"2"' }),
  fileUrl: (r) => r,
});

async function render(s: ReviewStore, node: React.ReactNode) {
  const el = document.createElement("div");
  const root = createRoot(el);
  await act(async () => root.render(<StoreCtx.Provider value={s}>{node}</StoreCtx.Provider>));
  return { el, done: () => act(() => root.unmount()) };
}

describe("the item detail", () => {
  it("shows a task's Expected (what done means) and never the internal enrich flag", async () => {
    const doc: ReviewDoc = {
      schema: 3,
      items: [{ id: "HS-2", uid: "u2", kind: "task", title: "Hello", state: "todo", expected: "hi.txt says hello", enrich: "pending" }],
    };
    const s = new ReviewStore(host(doc), { lang: "zh" });
    await s.load();
    const { el, done } = await render(s, <Inspector />);
    const labels = [...el.querySelectorAll(".f > label")].map((l) => l.textContent);
    expect(labels).toContain("完成标准");
    expect(el.querySelector<HTMLTextAreaElement>('[data-k="expected"]')?.value).toBe("hi.txt says hello");
    expect(el.textContent).not.toMatch(/enrich|pending/i);
    done();
    s.dispose();
  });

  it("names agents from the doc, a desktop hand-off by its app, and never shows an id", async () => {
    const doc: ReviewDoc = {
      schema: 3,
      agents: { claude: { name: "Claude Code", desktop: "Claude" }, opencode: { name: "OpenCode", desktop: null } },
      items: [
        { id: "A-1", uid: "a1", kind: "issue", title: "x", state: "handed_off", work: { to: "session", agent: "opencode", job: "j-1" } },
        { id: "A-2", uid: "a2", kind: "issue", title: "y", state: "handed_off", work: { to: "session", agent: "claude", job: "j-2" }, _work_runner: "desktop" },
      ],
    };
    const s = new ReviewStore(host(doc), { lang: "zh" });
    await s.load();
    expect(stateText(s, s.data.items[0])).toBe("已交给 OpenCode");
    expect(stateText(s, s.data.items[1])).toBe("已交给 Claude 桌面端");
    expect(agentName(s, "zcode")).toBe("Agent");
    expect(agentName(s, null)).toBe("Agent");
    s.dispose();
  });

  it("says where it came from in words: app names, capture time, merged items by count", async () => {
    expect(appLabel("com.apple.TextEdit")).toBe("TextEdit");
    expect(appLabel("备忘录")).toBe("备忘录");
    const doc: ReviewDoc = {
      schema: 3,
      items: [{ id: "N-1", uid: "n1", kind: "note", title: "n", state: "todo", summary: "s",
        source: { type: "dictation", app: "com.apple.Notes", session: "/x/sessions/20261025-101010-shots" },
        merged_from: ["01JB3K4XABCDEFGHJKMNPQRSTV"] }],
    };
    const s = new ReviewStore(host(doc), { lang: "zh" });
    await s.load();
    const { el, done } = await render(s, <Inspector />);
    const prov = el.querySelector("#provenance")!.textContent!;
    expect(prov).toContain("听写");
    expect(prov).toContain("Notes");
    expect(prov).not.toMatch(/com\.apple|20261025-101010|01JB3K4X|dictation/);
    expect(prov).toContain("更早的 1 条");
    done();
    s.dispose();
  });

  it("an unreadable item says so (never gone), and a failed load never shows the host's raw words", async () => {
    const doc: ReviewDoc = { schema: 3, items: [], _unreadable: [{ uid: "u4", id: "AW-4", path: "/p/AW-4.md" }] };
    const s = new ReviewStore(host(doc), { lang: "zh", mode: "item", itemId: "u4" });
    await s.load();
    expect(s.unreadable).toBe(true);
    const a = await render(s, <App store={s} onTheme={() => {}} />);
    expect(a.el.textContent).toContain("读不出来");
    expect(a.el.textContent).not.toContain("不在这里");
    a.done();
    s.dispose();
    const bad = new ReviewStore(host(() => { throw new Error("items.py load failed: exit 1: Traceback"); }), { lang: "zh" });
    await bad.load();
    const b = await render(bad, <App store={bad} onTheme={() => {}} />);
    expect(b.el.textContent).toContain("条目没能加载");
    expect(b.el.textContent).not.toMatch(/items\.py|Traceback|exit 1/);
    b.done();
    bad.dispose();
  });
});
