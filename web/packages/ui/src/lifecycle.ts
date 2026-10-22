/* K3 — an item's one lifecycle: eight states, the user's actions between them, the groups every count uses, and the
   migration from the old two axes (review `status` + `work.state`, v2 `fix`). The same table is in Python
   (_common.LIFECYCLE) and Swift (BlurtCore/Lifecycle.swift); all three are tested against tests/fixtures/lifecycle.json. */

export const STATES = ["new", "todo", "handed_off", "in_progress", "to_verify", "done", "wontfix", "discarded"] as const;
export type State = (typeof STATES)[number];

/** "Needs you": what the inbox, the badges and the island count */
export const INBOX_STATES: readonly State[] = ["new", "to_verify"];
/** not finished (MCP open_items, the backlog) */
export const OPEN_STATES: readonly State[] = ["new", "todo", "handed_off", "in_progress"];
/** with an agent, or back from one */
export const ACTIVE_STATES: readonly State[] = ["handed_off", "in_progress", "to_verify"];
export const CLOSED_STATES: readonly State[] = ["done", "wontfix"];

export const ACTIONS = ["keep", "hand_off", "done", "send_back", "take_back", "reopen", "restore", "wontfix", "discard"] as const;
export type Action = (typeof ACTIONS)[number];

export interface Transition {
  from: readonly State[];
  /** null: restore goes back to the item's `restore_to` (new when it has none) */
  to: State | null;
  /** "a", "d", "r", "w", "x", "cmd+enter" (⌘↩ / Ctrl+↩) */
  key: string;
}

const LIVE: readonly State[] = STATES.filter((s) => s !== "discarded");
export const TRANSITIONS: Record<Action, Transition> = {
  keep: { from: ["new"], to: "todo", key: "a" },
  hand_off: { from: ["new", "todo"], to: "handed_off", key: "cmd+enter" },
  done: { from: ["todo", "handed_off", "in_progress", "to_verify"], to: "done", key: "d" },
  send_back: { from: ["to_verify"], to: "todo", key: "r" },
  take_back: { from: ["handed_off", "in_progress"], to: "todo", key: "r" },
  reopen: { from: ["done", "wontfix"], to: "todo", key: "r" },
  restore: { from: ["discarded"], to: null, key: "r" },
  wontfix: { from: ["new", "todo", "handed_off", "in_progress", "to_verify"], to: "wontfix", key: "w" },
  discard: { from: LIVE, to: "discarded", key: "x" },
};

/** what clicking a state offers, in order */
export const MENUS: Record<State, readonly Action[]> = {
  new: ["keep", "hand_off", "wontfix", "discard"],
  todo: ["hand_off", "done", "wontfix", "discard"],
  handed_off: ["done", "take_back", "wontfix", "discard"],
  in_progress: ["done", "take_back", "wontfix", "discard"],
  to_verify: ["done", "send_back", "wontfix", "discard"],
  done: ["reopen", "discard"],
  wontfix: ["reopen", "discard"],
  discarded: ["restore"],
};

export const isState = (v: unknown): v is State => typeof v === "string" && (STATES as readonly string[]).includes(v);
export const isAction = (v: unknown): v is Action => typeof v === "string" && (ACTIONS as readonly string[]).includes(v);
export const isInbox = (s: State) => INBOX_STATES.includes(s);

/** The menu for a state. `hand_off` only where the host can dispatch or hand off (it opens that, not a state op). */
export function menuFor(state: State, opts: { canHandOff?: boolean } = {}): Action[] {
  return MENUS[state].filter((a) => a !== "hand_off" || !!opts.canHandOff);
}

export const canDo = (action: Action, state: State) => TRANSITIONS[action].from.includes(state);

/** Where an action takes an item; null when the action isn't valid from the item's state. */
export function targetOf(action: Action, item: StateLike): State | null {
  const { state, restore_to } = migrate(item);
  if (!canDo(action, state)) return null;
  const to = TRANSITIONS[action].to;
  return to ?? (restore_to && restore_to !== "discarded" ? restore_to : "new");
}

/** The one "back" action of a state (send back / take back / reopen / restore): what R does. */
export function backAction(state: State): Action | null {
  return (["send_back", "take_back", "reopen", "restore"] as const).find((a) => canDo(a, state)) ?? null;
}

/** A key press → the action it means for this state, or null. Keys: A keep, D done, R back, W won't do,
    X / Delete / Backspace discard, ⌘↩ / Ctrl+↩ hand off. (Enter = keep is the review mode's, not here.) */
export function actionForKey(state: State, e: string | { key: string; metaKey?: boolean; ctrlKey?: boolean; altKey?: boolean }): Action | null {
  const ev = typeof e === "string" ? { key: e } : e;
  const mod = !!(ev.metaKey || ev.ctrlKey);
  let a: Action | null = null;
  if (ev.key === "Enter") a = mod ? "hand_off" : null;
  else if (mod || ev.altKey) return null;
  else {
    const k = ev.key.length === 1 ? ev.key.toLowerCase() : ev.key;
    if (k === "r") return backAction(state);
    a = ({ a: "keep", d: "done", w: "wontfix", x: "discard", Delete: "discard", Backspace: "discard" } as Record<string, Action>)[k] ?? null;
  }
  return a && canDo(a, state) ? a : null;
}

// ---------------------------------------------------------------- reading items, old and new
export interface StateLike {
  state?: unknown;
  restore_to?: unknown;
  status?: unknown;
  work?: { state?: unknown } | null;
  fix?: { state?: unknown; agent?: unknown } | null;
}

/** v2 `fix` → the K3 work state */
function fixState(fix: StateLike["fix"]): State | null {
  switch (fix?.state) {
    case "fixing":
      return "in_progress";
    case "fixed":
      return "to_verify";
    case "wontfix":
      return !fix.agent || fix.agent === "human" ? "wontfix" : "to_verify"; // the user's own "won't do" vs an agent's suggestion
    case "reopened":
      return "todo";
    default:
      return null;
  }
}

/** The state of an item, and where a discarded one goes back to. A known `state` wins; otherwise (K3 migration):
    status deleted → discarded (restore_to from the rest); a work state other than to do → it; draft → new,
    confirmed → to do. */
export function migrate(i: StateLike): { state: State; restore_to?: State } {
  if (isState(i.state)) {
    if (i.state !== "discarded") return { state: i.state };
    return { state: "discarded", restore_to: isState(i.restore_to) && i.restore_to !== "discarded" ? i.restore_to : "new" };
  }
  const ws = i.work?.state;
  const work: State | null =
    typeof ws === "string" && ws !== "new" && ws !== "discarded" && isState(ws) ? ws : fixState(i.fix);
  const live: State = work && work !== "todo" ? work : i.status === "confirmed" ? "todo" : "new";
  return i.status === "deleted" ? { state: "discarded", restore_to: live } : { state: live };
}

export const stateOf = (i: StateLike): State => migrate(i).state;
