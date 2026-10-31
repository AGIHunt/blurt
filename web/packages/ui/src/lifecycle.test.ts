import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  ACTIONS, ACTIVE_STATES, actionForKey, backAction, CLOSED_STATES, INBOX_STATES, isInbox, MENUS, menuFor, migrate, OPEN_STATES,
  STATES, stateOf, targetOf, TRANSITIONS, type Action, type State,
} from "./lifecycle";

/** the one table Python, Swift and this file are all tested against */
const F = JSON.parse(readFileSync(new URL("../../../../tests/fixtures/lifecycle.json", import.meta.url), "utf8")) as {
  states: string[];
  groups: Record<string, string[]>;
  actions: { action: string; from: string[]; to: string | null; key: string }[];
  menus: Record<string, string[]>;
  migrate: { in: Record<string, unknown>; state: string; restore_to?: string }[];
};

describe("lifecycle (K3) matches tests/fixtures/lifecycle.json", () => {
  it("states and groups", () => {
    expect([...STATES]).toEqual(F.states);
    expect({ inbox: INBOX_STATES, open: OPEN_STATES, active: ACTIVE_STATES, closed: CLOSED_STATES }).toEqual(F.groups);
  });
  it("actions: from, to, key", () => {
    expect([...ACTIONS].sort()).toEqual(F.actions.map((a) => a.action).sort());
    for (const a of F.actions) {
      const t = TRANSITIONS[a.action as Action];
      expect([...t.from].sort(), a.action).toEqual([...a.from].sort());
      expect(t.to, a.action).toBe(a.to);
      expect(t.key, a.action).toBe(a.key);
    }
  });
  it("menus, in order; hand off only when the host can", () => {
    expect(MENUS).toEqual(F.menus);
    for (const s of STATES) {
      expect(menuFor(s, { canHandOff: true })).toEqual(F.menus[s]);
      expect(menuFor(s)).toEqual(F.menus[s].filter((a) => a !== "hand_off"));
    }
  });
  it.each(F.migrate.map((m) => [JSON.stringify(m.in), m] as const))("migrates %s", (_k, m) => {
    const r = migrate(m.in);
    expect(r.state).toBe(m.state);
    if (m.restore_to) expect(r.restore_to).toBe(m.restore_to);
    expect(stateOf(m.in)).toBe(m.state);
  });
});

describe("lifecycle helpers", () => {
  it("targetOf follows the table, restore goes to restore_to (new without one)", () => {
    expect(targetOf("keep", { state: "new" })).toBe("todo");
    expect(targetOf("keep", { state: "todo" })).toBeNull();
    expect(targetOf("done", { state: "to_verify" })).toBe("done");
    expect(targetOf("discard", { state: "done" })).toBe("discarded");
    expect(targetOf("discard", { state: "discarded" })).toBeNull();
    expect(targetOf("restore", { state: "discarded", restore_to: "in_progress" })).toBe("in_progress");
    expect(targetOf("restore", { state: "discarded" })).toBe("new");
    expect(targetOf("restore", { status: "deleted", work: { state: "done" } })).toBe("done"); // an old file
  });
  it("one back action per state at most: R is never ambiguous", () => {
    const back: Record<State, Action | null> = { new: null, todo: null, handed_off: "take_back", in_progress: "take_back",
      to_verify: "send_back", done: "reopen", wontfix: "reopen", discarded: "restore" };
    for (const s of STATES) expect(backAction(s), s).toBe(back[s]);
  });
  it("keys map to the action valid for the state, or nothing", () => {
    expect(actionForKey("new", "a")).toBe("keep");
    expect(actionForKey("new", "A")).toBe("keep");
    expect(actionForKey("todo", "a")).toBeNull();
    expect(actionForKey("to_verify", "d")).toBe("done");
    expect(actionForKey("new", "d")).toBe("done"); // BA-56: no Accept first
    expect(actionForKey("to_verify", "r")).toBe("send_back");
    expect(actionForKey("in_progress", "r")).toBe("take_back");
    expect(actionForKey("wontfix", "r")).toBe("reopen");
    expect(actionForKey("discarded", "r")).toBe("restore");
    expect(actionForKey("todo", "r")).toBeNull();
    expect(actionForKey("todo", "w")).toBe("wontfix");
    expect(actionForKey("done", "w")).toBeNull();
    for (const k of ["x", "Delete", "Backspace"]) expect(actionForKey("done", k)).toBe("discard");
    expect(actionForKey("discarded", "x")).toBeNull();
    expect(actionForKey("todo", { key: "Enter", metaKey: true })).toBe("hand_off");
    expect(actionForKey("todo", { key: "Enter", ctrlKey: true })).toBe("hand_off");
    expect(actionForKey("done", { key: "Enter", metaKey: true })).toBeNull();
    expect(actionForKey("new", "Enter")).toBeNull();
    expect(actionForKey("new", { key: "a", metaKey: true })).toBeNull(); // ⌘A is select all
  });
  it("the inbox is new + to verify", () => {
    expect(STATES.filter(isInbox)).toEqual(["new", "to_verify"]);
  });
});
