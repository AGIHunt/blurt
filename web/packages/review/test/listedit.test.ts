// micro 21: steps (and other list fields) edit as a list
import { describe, expect, it } from "vitest";
import { listKey } from "../src/listedit";

describe("list fields", () => {
  const steps = "1. Open /login\n2. Click Sign in";
  it("Return continues the numbering, also in the middle of the list", () => {
    const end = listKey(steps, steps.length, "enter", true)!;
    expect(end.value).toBe("1. Open /login\n2. Click Sign in\n3. ");
    expect(end.caret).toBe(end.value.length);
    const mid = listKey(steps, "1. Open /login".length, "enter", true)!;
    expect(mid.value).toBe("1. Open /login\n2. \n3. Click Sign in");
    expect(listKey("- a", 3, "enter", false)!.value).toBe("- a\n- ");
  });
  it("Return on an empty item ends the list (and commits)", () => {
    const r = listKey(steps + "\n3. ", (steps + "\n3. ").length, "enter", true)!;
    expect([r.value, r.done]).toEqual([steps, true]);
  });
  it("⌫ right after a marker removes it; an empty item goes", () => {
    const v = steps + "\n3. ";
    expect(listKey(v, v.length, "backspace", true)!.value).toBe(steps);
    expect(listKey(steps, 3, "backspace", true)!.value).toBe("Open /login\n1. Click Sign in");
    expect(listKey(steps, 5, "backspace", true)).toBeNull(); // inside the text: an ordinary ⌫
  });
  it("⌃⌘↑ / ⌃⌘↓ move an item, the numbers follow", () => {
    const r = listKey(steps, steps.length, "up", true)!;
    expect(r.value).toBe("1. Click Sign in\n2. Open /login");
    expect(r.caret).toBeLessThanOrEqual("1. Click Sign in".length);
    expect(listKey(steps, 0, "up", true)!.value).toBe(steps);
  });
  it("plain text or an empty field: Return as usual", () => {
    expect(listKey("", 0, "enter", true)).toBeNull();
    expect(listKey("just text", 9, "enter", true)).toBeNull();
  });
});
