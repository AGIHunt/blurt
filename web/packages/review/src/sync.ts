/* Sync with the store — pure functions.

   The agent keeps writing (frames, clips, new items) while the user reviews. The page never posts the whole list:
   it diffs its copy against the last server state it saw (base) and sends only what the user changed; the server
   merges that in under a lock. Server updates are merged the other way round, field by field: a field the user
   changed here and hasn't saved yet keeps the user's value.

   Items are matched by a key: the uid on a v3 doc (the display id changes when an item moves project, the uid
   never does), the display id on v2. Fields the server owns (the display id, the state, work, paths) always come
   from the server and are never sent back; a state change is an explicit op (store.act). */
import { stateOf } from "@blurt/ui";
import type { Item, UserOp } from "./host";

export const clone = <T>(v: T): T => (v === undefined ? v : JSON.parse(JSON.stringify(v)));

/** JSON with sorted object keys: equality that ignores key order */
export const canon = (v: unknown): string =>
  JSON.stringify(v, (_k, x) =>
    x && typeof x === "object" && !Array.isArray(x)
      ? Object.keys(x)
          .sort()
          .reduce((o: Record<string, unknown>, kk) => ((o[kk] = (x as Record<string, unknown>)[kk]), o), {})
      : x,
  );

export type KeyFn = (i: Item) => string;
/** v2: the display id */
export const byId: KeyFn = (i) => i.id;
/** v3: the uid (falls back to the id for an item the page created before the server gave it one) */
export const byUid: KeyFn = (i) => i.uid || i.id;

/** written by the server only: never diffed into ops; on a v3 doc always taken from the server (with `id`) */
export const SERVER_OWNED = new Set(["uid", "_user", "fix", "fix_history", "schema", "work", "work_history", "path",
  "store", "aliases", "updated", "created", "_project", "suggested_project", "project_by", "project_confidence",
  "state", "restore_to", "status"]);
/** never sent as field edits, whatever the doc's shape: the state goes as `state` ops; `status` and the review
    bookkeeping are the pre-v0.7 two-axis model, read (stateOf) but not written */
const NOT_FIELDS = new Set(["state", "restore_to", "status", "_touched", "_dropped"]);

export const norm = (items: Item[] | undefined): Item[] => (items || []).map((i) => (i.kind ? i : { ...i, kind: "issue" }));

export type Status = "keep" | "drop" | "pending";
/** the review's three-way view of the state (K3): new = still to review, discarded = dropped, anything else = kept */
export const statusOf = (i: Item): Status => {
  const s = stateOf(i);
  return s === "new" ? "pending" : s === "discarded" ? "drop" : "keep";
};

export interface RebaseResult {
  items: Item[];
  /** item key → changed keys ("*" = new item) */
  changed: Map<string, Set<string>>;
  structural: boolean;
}

/** three-way merge: local items L, the base they were edited from B (key → item), server S. `keep(key)`: an item
    the server no longer lists that stays anyway (one the user discarded on this page). */
export function rebase(L: Item[], B: Map<string, Item>, S: Item[], undoing: boolean, key: KeyFn = byId,
  keep: (k: string) => boolean = () => false): RebaseResult {
  const v3 = key === byUid;
  const Smap = new Map(S.map((i) => [key(i), i]));
  const Lkeys = new Set(L.map(key));
  const changed = new Map<string, Set<string>>();
  const out: Item[] = [];
  let structural = false;
  for (const l of L) {
    const lk = key(l);
    const s = Smap.get(lk);
    const b = B.get(lk);
    if (!s) {
      if (!undoing && b && canon(l) === canon(b) && !keep(lk)) {
        structural = true; // removed on the server (merged by another page / the app), untouched here: let it go
        continue;
      }
      out.push(l);
      continue;
    }
    const ch = new Set<string>();
    for (const k of new Set([...Object.keys(s), ...Object.keys(b || {}), ...Object.keys(l)])) {
      if (v3 ? k === "uid" : k === "id") continue;
      const owned = v3 && (k === "id" || SERVER_OWNED.has(k));
      const bv = canon(b?.[k]);
      if (owned) {
        if (canon(l[k]) === canon(s[k])) continue;
      } else {
        if (canon(s[k]) === bv) continue; // the server didn't change it
        if (k !== "_user") {
          if (canon(l[k]) !== bv) continue; // changed here too: the user's version wins
          if (undoing && (k.startsWith("_") || s._user?.[k] != null)) continue; // the user's own saved change: undo restores it
        }
      }
      if (s[k] === undefined) delete l[k];
      else l[k] = clone(s[k]);
      ch.add(k);
    }
    if (ch.size) changed.set(lk, ch);
    out.push(l);
  }
  S.forEach((s, n) => {
    // new from the agent; a key in B but not in L was removed here, and stays removed
    const sk = key(s);
    if (Lkeys.has(sk) || B.has(sk)) return;
    let pos = 0;
    for (let m = n - 1; m >= 0; m--) {
      const k = out.findIndex((x) => key(x) === key(S[m]));
      if (k >= 0) {
        pos = k + 1;
        break;
      }
    }
    out.splice(pos, 0, clone(s));
    changed.set(sk, new Set(["*"]));
    structural = true;
  });
  return { items: out, changed, structural };
}

/** what the user changed relative to base, as user-ops (addressed by key) */
export function diffOps(items: Item[], base: Map<string, Item>, key: KeyFn = byId): UserOp[] {
  const v3 = key === byUid;
  const ops: UserOp[] = [];
  const keys = new Set(items.map(key));
  items.forEach((i, k) => {
    const b = base.get(key(i));
    if (!b) {
      const it = clone(i);
      delete it._user;
      ops.push({ op: "add", item: it, after: k ? key(items[k - 1]) : null });
      return;
    }
    const set: Record<string, unknown> = {};
    const unset: string[] = [];
    for (const f of new Set([...Object.keys(i), ...Object.keys(b)])) {
      if (f === "id" || f === "_user" || NOT_FIELDS.has(f) || (v3 && SERVER_OWNED.has(f))) continue;
      if (canon(i[f]) !== canon(b[f])) {
        if (i[f] === undefined) unset.push(f);
        else set[f] = i[f];
      }
    }
    if (unset.length || Object.keys(set).length) ops.push({ op: "set", id: key(i), set, unset });
  });
  for (const k of base.keys()) {
    if (keys.has(k)) continue;
    const into = items.find((x) => (x.merged_from || []).includes(k));
    ops.push({ op: "remove", id: k, into: into ? key(into) : "" });
  }
  return ops;
}

/** keys a merge never copies from the merged item: identity, the state, project and the work record */
const MERGE_SKIP = new Set(["id", "uid", "kind", "title", "quote", "time", "state", "restore_to", "status", "merged_from", "exported",
  "fix", "fix_history", "schema", "work", "work_history", "project", "project_by", "project_confidence",
  "suggested_project", "aliases", "created", "updated", "path", "source", "merged_into"]);
const MERGE_KEEP_TARGET = new Set(["severity", "type", "owner", "module", "language", "assignee"]);

/** fold item `i` into `p` (the item above): quotes and text joined, lists unioned, time spans widened */
export function mergeInto(p: Item, i: Item, key: KeyFn = byId): void {
  const join = (a: unknown, b: unknown, s: string) => [a, b].filter(Boolean).join(s);
  p.quote = join(p.quote, i.quote, " … ");
  for (const [k, v] of Object.entries(i)) {
    if (MERGE_SKIP.has(k) || k.startsWith("_")) continue;
    if (typeof v === "string" && v && !MERGE_KEEP_TARGET.has(k)) p[k] = join(p[k], v, "\n");
    else if (Array.isArray(v)) {
      const seen = new Map<string, unknown>(); // union, first occurrence wins; "2024" stays a string
      for (const x of [...(Array.isArray(p[k]) ? (p[k] as unknown[]) : []), ...v]) {
        const kk = typeof x === "string" ? "s" + x : "j" + canon(x);
        if (!seen.has(kk)) seen.set(kk, x);
      }
      p[k] = [...seen.values()];
    } else if (p[k] == null) p[k] = v;
  }
  p.merged_from = [...(p.merged_from || []), key(i)];
  if (i.time && p.time)
    p.time = { start: Math.min(p.time.start, i.time.start), end: Math.max(p.time.end, i.time.end) };
}
