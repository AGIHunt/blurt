/* Sync with items.json — pure functions, ported 1:1 from the vanilla review page.

   The agent keeps writing (frames, clips, new items) while the user reviews. The page never posts the whole list:
   it diffs its copy against the last server state it saw (base) and sends only what the user changed; the server
   merges that into the file under a lock (apply_user_ops). Server updates are merged the other way round, field by
   field: a field the user changed here and hasn't saved yet keeps the user's value. */
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

/** dropped before this review: hidden */
export const shown = (i: Item) => !(i.status === "deleted" && !i._dropped);
export const norm = (items: Item[] | undefined): Item[] =>
  (items || []).filter(shown).map((i) => (i.kind ? i : { ...i, kind: "issue" }));

export type Status = "keep" | "drop" | "pending";
export const statusOf = (i: Item): Status => (i.status === "deleted" ? "drop" : i._touched ? "keep" : "pending");

export interface RebaseResult {
  items: Item[];
  /** item id → changed keys ("*" = new item) */
  changed: Map<string, Set<string>>;
  structural: boolean;
}

/** three-way merge: local items L, the base they were edited from B (id → item), server S */
export function rebase(L: Item[], B: Map<string, Item>, S: Item[], undoing: boolean): RebaseResult {
  const Smap = new Map(S.map((i) => [i.id, i]));
  const Lids = new Set(L.map((i) => i.id));
  const changed = new Map<string, Set<string>>();
  const out: Item[] = [];
  let structural = false;
  for (const l of L) {
    const s = Smap.get(l.id);
    const b = B.get(l.id);
    if (!s) {
      if (!undoing && b && canon(l) === canon(b)) {
        structural = true; // removed on the server (merged by another page / the app), untouched here: let it go
        continue;
      }
      out.push(l);
      continue;
    }
    const ch = new Set<string>();
    for (const k of new Set([...Object.keys(s), ...Object.keys(b || {}), ...Object.keys(l)])) {
      if (k === "id") continue;
      const bv = canon(b?.[k]);
      if (canon(s[k]) === bv) continue; // the server didn't change it
      if (k !== "_user") {
        if (canon(l[k]) !== bv) continue; // changed here too: the user's version wins
        if (undoing && (k.startsWith("_") || s._user?.[k] != null)) continue; // the user's own saved change: undo restores it
      }
      if (s[k] === undefined) delete l[k];
      else l[k] = clone(s[k]);
      ch.add(k);
    }
    if (ch.size) changed.set(l.id, ch);
    out.push(l);
  }
  S.forEach((s, n) => {
    // new from the agent; an id in B but not in L was removed here, and stays removed
    if (Lids.has(s.id) || B.has(s.id)) return;
    let pos = 0;
    for (let m = n - 1; m >= 0; m--) {
      const k = out.findIndex((x) => x.id === S[m].id);
      if (k >= 0) {
        pos = k + 1;
        break;
      }
    }
    out.splice(pos, 0, clone(s));
    changed.set(s.id, new Set(["*"]));
    structural = true;
  });
  return { items: out, changed, structural };
}

/** what the user changed relative to base, as user-ops */
export function diffOps(items: Item[], base: Map<string, Item>): UserOp[] {
  const ops: UserOp[] = [];
  const ids = new Set(items.map((i) => i.id));
  items.forEach((i, k) => {
    const b = base.get(i.id);
    if (!b) {
      const it = clone(i);
      delete it._user;
      ops.push({ op: "add", item: it, after: k ? items[k - 1].id : null });
      return;
    }
    const set: Record<string, unknown> = {};
    const unset: string[] = [];
    for (const key of new Set([...Object.keys(i), ...Object.keys(b)])) {
      if (key === "id" || key === "_user") continue;
      if (canon(i[key]) !== canon(b[key])) {
        if (i[key] === undefined) unset.push(key);
        else set[key] = i[key];
      }
    }
    if (unset.length || Object.keys(set).length) ops.push({ op: "set", id: i.id, set, unset });
  });
  for (const id of base.keys())
    if (!ids.has(id))
      ops.push({ op: "remove", id, into: items.find((x) => (x.merged_from || []).includes(id))?.id || "" });
  return ops;
}

/** keys a merge never copies from the merged item: identity, review bookkeeping and the fix record (v2) */
const MERGE_SKIP = new Set(["id", "uid", "kind", "title", "quote", "time", "status", "merged_from", "exported",
  "fix", "fix_history", "schema"]);
const MERGE_KEEP_TARGET = new Set(["severity", "type", "owner", "module"]);

/** fold item `i` into `p` (the item above): quotes and text joined, lists unioned, time spans widened */
export function mergeInto(p: Item, i: Item): void {
  const join = (a: unknown, b: unknown, s: string) => [a, b].filter(Boolean).join(s);
  p.quote = join(p.quote, i.quote, " … ");
  for (const [k, v] of Object.entries(i)) {
    if (MERGE_SKIP.has(k) || k.startsWith("_")) continue;
    if (typeof v === "string" && v && !MERGE_KEEP_TARGET.has(k)) p[k] = join(p[k], v, "\n");
    else if (Array.isArray(v)) {
      const seen = new Map<string, unknown>(); // union, first occurrence wins; "2024" stays a string
      for (const x of [...(Array.isArray(p[k]) ? (p[k] as unknown[]) : []), ...v]) {
        const key = typeof x === "string" ? "s" + x : "j" + canon(x);
        if (!seen.has(key)) seen.set(key, x);
      }
      p[k] = [...seen.values()];
    } else if (p[k] == null) p[k] = v;
  }
  p.merged_from = [...(p.merged_from || []), i.id];
  if (i.time && p.time)
    p.time = { start: Math.min(p.time.start, i.time.start), end: Math.max(p.time.end, i.time.end) };
}

/** the items as confirmed: everything not dropped is kept; review bookkeeping removed */
export function finalize(items: Item[]): Item[] {
  const final = items.map(clone);
  final.forEach((i) => {
    if (i.status !== "deleted") i.status = "confirmed";
    delete i._touched;
    delete i._dropped;
  });
  return final;
}
