// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Action, State } from "./lifecycle";
import { StatePill } from "./react";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
const t = (k: string) => k;
let root: Root | null = null;
afterEach(() => {
  act(() => root?.unmount());
  root = null;
  document.body.innerHTML = "";
});

function mount(state: State, props: { canHandOff?: boolean; variant?: "pill" | "ring" } = {}) {
  const onPick = vi.fn<(a: Action) => void>();
  const el = document.body.appendChild(document.createElement("div"));
  root = createRoot(el);
  act(() => root!.render(<StatePill state={state} t={t} onPick={onPick} {...props} />));
  const btn = el.querySelector("button")!;
  return { onPick, btn };
}
const menu = () => document.querySelector<HTMLElement>('[role="menu"]');
const rows = () => [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].map((b) => b.dataset.action);
const key = (k: string, opts: KeyboardEventInit = {}) =>
  act(() => void document.activeElement!.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...opts })));

describe("<StatePill>", () => {
  it("is a menu button: the menu lists only the state's actions, first one focused", () => {
    const { btn } = mount("to_verify");
    expect(btn.getAttribute("aria-haspopup")).toBe("menu");
    expect(btn.getAttribute("aria-expanded")).toBe("false");
    expect(btn.textContent).toContain("state.to_verify");
    act(() => btn.click());
    expect(btn.getAttribute("aria-expanded")).toBe("true");
    expect(menu()?.getAttribute("aria-label")).toBe("state.menu");
    expect(rows()).toEqual(["done", "send_back", "wontfix", "discard"]);
    expect(document.activeElement).toBe(document.querySelector('[data-action="done"]'));
    // the to-verify "done" says what it means there; every row has its shortcut
    expect(menu()!.textContent).toContain("action.done.hint_verify");
    expect([...menu()!.querySelectorAll(".smenu-k")].map((k) => k.textContent)).toEqual(["D", "R", "W", "X"]);
  });
  it("hand off only when the host can", () => {
    const a = mount("todo");
    act(() => a.btn.click());
    expect(rows()).toEqual(["done", "wontfix", "discard"]);
    act(() => root!.unmount());
    const b = mount("todo", { canHandOff: true });
    act(() => b.btn.click());
    expect(rows()).toEqual(["hand_off", "done", "wontfix", "discard"]);
  });
  it("arrows move, Enter picks and closes, focus goes back to the pill", () => {
    const { btn, onPick } = mount("new");
    act(() => btn.click());
    key("ArrowDown");
    key("ArrowDown");
    key("ArrowDown"); // keep, done (BA-56), wontfix, discard
    expect(document.activeElement?.getAttribute("data-action")).toBe("discard");
    key("ArrowDown"); // wraps
    expect(document.activeElement?.getAttribute("data-action")).toBe("keep");
    key("ArrowUp");
    key("Enter");
    expect(onPick).toHaveBeenCalledWith("discard");
    expect(menu()).toBeNull();
    expect(document.activeElement).toBe(btn);
  });
  it("shortcut letters pick while open; Esc closes without picking", () => {
    const { btn, onPick } = mount("done");
    act(() => btn.click());
    key("d"); // not valid from done
    expect(onPick).not.toHaveBeenCalled();
    key("r");
    expect(onPick).toHaveBeenCalledWith("reopen");
    act(() => btn.click());
    key("Escape");
    expect(menu()).toBeNull();
    expect(onPick).toHaveBeenCalledTimes(1);
    expect(document.activeElement).toBe(btn);
  });
  it("a click outside closes it", () => {
    const { btn } = mount("discarded", { variant: "ring" });
    expect(btn.getAttribute("aria-label")).toBe("state.discarded · state.menu");
    act(() => btn.click());
    expect(rows()).toEqual(["restore"]);
    act(() => void document.body.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true })));
    expect(menu()).toBeNull();
  });
});
