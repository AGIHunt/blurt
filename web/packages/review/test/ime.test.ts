import { afterEach, describe, expect, it, vi } from "vitest";
import { _resetImeGuard, IME_GRACE_MS, imeBusy, installImeGuard, isEnter } from "../src/ime";

const key = (init: KeyboardEventInit, keyCode?: number) => {
  const e = new KeyboardEvent("keydown", { key: "Enter", ...init });
  if (keyCode != null) Object.defineProperty(e, "keyCode", { get: () => keyCode });
  return e;
};

describe("IME Enter guard (C6)", () => {
  afterEach(() => {
    _resetImeGuard();
    vi.useRealTimers();
  });
  it("a plain Enter is an Enter", () => {
    expect(isEnter(key({}, 13))).toBe(true);
  });
  it("isComposing → not an Enter", () => {
    expect(isEnter(key({ isComposing: true }))).toBe(false);
  });
  it("keyCode 229 (WebKit's committing Enter) → not an Enter", () => {
    expect(isEnter(key({}, 229))).toBe(false);
    expect(imeBusy(key({ key: "Process" }, 229))).toBe(true);
  });
  it(`ignores Enter within ${IME_GRACE_MS} ms after compositionend`, () => {
    installImeGuard(document);
    const now = vi.spyOn(performance, "now");
    now.mockReturnValue(1000);
    document.dispatchEvent(new CompositionEvent("compositionend", { data: "好" }));
    now.mockReturnValue(1000 + IME_GRACE_MS - 1);
    expect(isEnter(key({}, 13))).toBe(false);
    now.mockReturnValue(1000 + IME_GRACE_MS + 1);
    expect(isEnter(key({}, 13))).toBe(true);
    now.mockRestore();
  });
  it("works on React synthetic events (nativeEvent)", () => {
    expect(isEnter({ key: "Enter", nativeEvent: key({}, 229) })).toBe(false);
  });
});
