import { act } from "react";
import { createRoot } from "react-dom/client";
import { describe, expect, it } from "vitest";
import type { BlurtHost, SessionDoc } from "../src/host";
import { fieldLabel, humanizeKey, normKey } from "../src/fields";
import { makeI18n } from "../src/i18n";
import { ReviewStore } from "../src/store";
import { StoreCtx } from "../src/ui/ctx";
import { Inspector } from "../src/ui/Inspector";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

describe("labels for fields the agent adds", () => {
  it("humanises snake / camel / kebab keys", () => {
    expect(humanizeKey("suspected_cause")).toBe("Suspected cause");
    expect(humanizeKey("suspectedCause")).toBe("Suspected cause");
    expect(humanizeKey("app-version")).toBe("App version");
    expect(humanizeKey("apiURL")).toBe("API URL");
    expect(humanizeKey("ios_build_id")).toBe("iOS build ID");
    expect(normKey("Root-Cause")).toBe("root_cause");
  });
  it("has zh / en labels for the common ones, whatever the key's case", () => {
    const zh = makeI18n("zh-Hans");
    const en = makeI18n("en");
    expect(fieldLabel("author", zh)).toBe("作者");
    expect(fieldLabel("suspected_cause", zh)).toBe("疑似原因");
    expect(fieldLabel("suspectedCause", en)).toBe("Suspected cause");
    expect(fieldLabel("rootCause", zh)).toBe("根本原因");
    for (const k of ["repro", "environment", "browser", "url", "version"]) expect(fieldLabel(k, zh)).toMatch(/[一-鿿]/);
    expect(fieldLabel("customer_tier", zh)).toBe("Customer tier"); // unknown: humanised, never the raw key
  });
  it("the inspector shows them instead of raw keys", async () => {
    const doc: SessionDoc = {
      items: [{ id: "I-001", kind: "issue", title: "a", author: "max", suspected_cause: "race", customerTier: "gold" }],
    };
    const host: BlurtHost = {
      host: "browser",
      load: async () => ({ doc, etag: '"1"' }),
      poll: async (e) => ({ etag: e }),
      sendOps: async () => ({ ok: true, etag: '"2"' }),
      fileUrl: (r) => r,
    };
    const s = new ReviewStore(host, { lang: "zh" });
    await s.load();
    const el = document.createElement("div");
    const root = createRoot(el);
    await act(async () => root.render(<StoreCtx.Provider value={s}><Inspector /></StoreCtx.Provider>));
    const labels = [...el.querySelectorAll(".f > label")].map((l) => l.textContent);
    expect(labels).toEqual(expect.arrayContaining(["作者", "疑似原因", "Customer tier"]));
    expect(labels.join("|")).not.toMatch(/suspected_cause|customerTier|author/);
    act(() => root.unmount());
    s.dispose();
  });
});
