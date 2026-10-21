/* Test double: _common.apply_user_ops in TypeScript (the real one runs in review.py / items.py user-ops). */
import type { Item, SessionDoc, UserOp } from "../src/host";
import { clone } from "../src/sync";

const SERVER_KEYS = new Set(["id", "_user"]);

export function applyUserOps(doc: SessionDoc, ops: UserOp[]): SessionDoc {
  const d = clone(doc);
  const now = Date.now() / 1000;
  const removed: Record<string, string> = (d._removed as Record<string, string>) || {};
  for (const op of ops) {
    const iid = op.op === "add" ? op.item.id : op.id;
    const item = d.items.find((i) => i.id === iid);
    if (op.op === "set" && item) {
      const user = (item._user ||= {});
      for (const [k, v] of Object.entries(op.set)) {
        if (SERVER_KEYS.has(k)) continue;
        item[k] = v;
        if (!k.startsWith("_")) user[k] = now;
      }
      for (const k of op.unset) {
        if (SERVER_KEYS.has(k)) continue;
        delete item[k];
        if (!k.startsWith("_")) user[k] = now;
      }
    } else if (op.op === "remove" && item) {
      d.items.splice(d.items.indexOf(item), 1);
      removed[iid] = op.into || "";
    } else if (op.op === "add" && !item) {
      const n: Item = { ...op.item, _user: op.item._user || {} };
      delete removed[iid];
      const k = d.items.findIndex((i) => i.id === op.after);
      d.items.splice(op.after == null ? 0 : k >= 0 ? k + 1 : d.items.length, 0, n);
    }
  }
  if (Object.keys(removed).length) d._removed = removed;
  else delete d._removed;
  return d;
}
