/* Test double for the v3 stores (K1 `items.py doc / user-ops`): items live in projects, ids are <KEY>-<n> per project
   and change when an item moves (the old id goes to `aliases`, the uid never changes), ops address items by uid,
   `set {project}` is the user's move, `{op: "state"}` the user's K3 action. Used by the vitest store tests and by
   the Playwright v3 server (e2e/v3server.ts). */
import type { State } from "@blurt/ui";
import type { Item, ProjectRef, ReviewDoc, Scope, UserOp, WorkRecord } from "../src/host";
import { applyState } from "./apply";

const clone = <T,>(v: T): T => JSON.parse(JSON.stringify(v));
const PROTECTED = new Set(["id", "uid", "_user", "state", "restore_to", "status", "work", "work_history", "fix", "fix_history", "schema", "path", "aliases", "updated", "created"]);

export class MemStore {
  items: Item[];
  projects: ProjectRef[];
  next: Record<string, number> = {};
  removed: Record<string, string> = {};
  rev = 1;
  meta: Partial<ReviewDoc>;
  root: string;

  constructor(items: Item[], projects: ProjectRef[], meta: Partial<ReviewDoc> = {}, root = "/tmp/blurt-e2e") {
    this.items = clone(items);
    this.projects = projects;
    this.meta = meta;
    this.root = root;
    for (const i of this.items) {
      const [k, n] = i.id.split("-");
      this.next[k] = Math.max(this.next[k] || 1, Number(n) + 1);
    }
  }
  private key(project: string) {
    return project === "inbox" ? "IN" : this.projects.find((p) => p.id === project)!.key;
  }
  get etag() {
    return `"r${this.rev}"`;
  }
  /** the K1 doc for a scope: a session's batch (all its items, any project, discarded too) or one project's items
      (K3: without the discarded ones unless the scope's state filter asks for them) */
  doc(scope: Scope): ReviewDoc {
    const inScope =
      "session" in scope
        ? this.items
        : this.items.filter((i) => (i.project || "inbox") === scope.project && (i.state !== "discarded" || !!scope.state?.includes("discarded")));
    return {
      schema: 3,
      scope,
      ...clone(this.meta),
      items: clone(inScope).map((i) => ({ ...i, path: `${this.root}/${i.project}/.blurt/items/${i.id}.md` })),
      _removed: { ...this.removed },
      projects: [...this.projects, { id: "inbox", name: "Unassigned", key: "IN" }],
    };
  }
  apply(ops: UserOp[], confirm = false) {
    const now = Date.now() / 1000;
    for (const op of ops) {
      if (op.op === "add") {
        if (this.items.some((i) => i.uid === op.item.uid)) continue;
        const k = this.items.findIndex((i) => i.uid === op.after);
        this.items.splice(op.after == null ? 0 : k + 1, 0, { ...clone(op.item), _user: {} });
        delete this.removed[op.item.uid!];
        continue;
      }
      const item = this.items.find((i) => i.uid === op.id);
      if (!item) continue;
      if (op.op === "remove") {
        this.items.splice(this.items.indexOf(item), 1);
        this.removed[op.id] = op.into;
      } else if (op.op === "state") {
        const prev = item.state;
        applyState(item, op);
        if (prev !== item.state && item.work) item.work_history = [...(item.work_history || []), { ...item.work, state: prev }];
      } else {
        const user = (item._user ||= {});
        for (const [k, v] of Object.entries(op.set)) {
          if (k === "project") {
            if (v !== item.project) {
              const key = this.key(String(v));
              item.aliases = [...(item.aliases || []), item.id];
              const n = this.next[key] || 1;
              this.next[key] = n + 1;
              item.id = `${key}-${n}`;
              item.project = String(v);
              item.project_by = "user";
            }
            user.project = now;
            continue;
          }
          if (PROTECTED.has(k)) continue;
          item[k] = v;
          if (!k.startsWith("_")) user[k] = now;
        }
        for (const k of op.unset) {
          if (PROTECTED.has(k)) continue;
          delete item[k];
          if (!k.startsWith("_")) user[k] = now;
        }
      }
    }
    if (confirm) this.meta.reviewed = true;
    this.rev++;
  }
  /** an agent's write (K3: mark_fixed fixed → to_verify, claim fixed) */
  agentWork(uid: string, state: State, claim: WorkRecord["claim"] = null) {
    const item = this.items.find((i) => i.uid === uid)!;
    if (item.work) item.work_history = [...(item.work_history || []), { ...item.work, state: item.state }];
    item.state = state;
    item.work = { ...(item.work || {}), claim, by: "agent", agent: "claude", at: new Date().toISOString() } as WorkRecord;
    this.rev++;
  }
  patch(uid: string, set: Record<string, unknown>) {
    Object.assign(this.items.find((i) => i.uid === uid)!, set);
    this.rev++;
  }
}

export const PROJECTS: ProjectRef[] = [
  { id: "p-blurt", name: "bug-agent", key: "BA", path: "/Users/me/workspace/bug-agent" },
  { id: "p-site", name: "website", key: "WS", path: "/Users/me/workspace/website" },
];

/** a session batch spread over two projects and the inbox */
export const V3_ITEMS: Item[] = [
  { id: "BA-12", uid: "01JB7ZK3Q4M8W2E5R6T9Y0AAA1", kind: "issue", title: "Login button does nothing", state: "to_verify", project: "p-blurt",
    project_by: "capture", severity: "high", module: "auth", actual: "Nothing happens", source: { type: "recording", by: "max", app: "Chrome", url: "https://blurt.dev/login", session: "/Users/me/workspace/bug-agent/.blurt/sessions/20261022-101500" },
    created: "2026-10-22T10:15:00+08:00", time: { start: 12.4, end: 30.1 }, work: { to: "session", agent: "claude", job: "j-20261022-101500-ab12", claim: "fixed", commit: "a1c3e5f9", by: "agent", at: "2026-10-22T11:00:00+08:00" },
    work_history: [{ state: "in_progress", to: "session", agent: "claude", by: "app", at: "2026-10-22T10:30:00+08:00" }] },
  { id: "IN-3", uid: "01JB7ZK3Q4M8W2E5R6T9Y0AAA2", kind: "idea", title: "Pricing page could show a calculator", state: "new", project: "inbox",
    summary: "", suggested_project: { id: "p-site", confidence: 0.58, reason: "mentions the pricing page" }, source: { type: "voice", by: "max" }, created: "2026-10-22T10:16:00+08:00" },
  { id: "BA-13", uid: "01JB7ZK3Q4M8W2E5R6T9Y0AAA3", kind: "task", title: "Write the release notes", state: "handed_off", project: "p-blurt",
    project_by: "ai", project_confidence: 0.82, details: "", work: { to: "external", handoff: "H-0012", by: "user", at: "2026-10-22T10:40:00+08:00" }, source: { type: "snap" } },
  { id: "WS-7", uid: "01JB7ZK3Q4M8W2E5R6T9Y0AAA4", kind: "note", title: "Competitor uses a dark hero", state: "new", project: "p-site",
    project_by: "user", summary: "", source: { type: "url", url: "https://example.com" } },
  { id: "BA-14", uid: "01JB7ZK3Q4M8W2E5R6T9Y0AAA5", kind: "competitor", title: "Linear's triage view", status: "draft", project: "p-blurt",
    competitor_notes: "keyboard first", work: { state: "wontfix", by: "user" } },
  { id: "BA-15", uid: "01JB7ZK3Q4M8W2E5R6T9Y0AAA6", kind: "issue", title: "Toast stacks three times", state: "in_progress", project: "p-blurt",
    work: { to: "session", agent: "codex", job: "j-2", by: "app" } },
  { id: "BA-16", uid: "01JB7ZK3Q4M8W2E5R6T9Y0AAA7", kind: "issue", title: "Avatar upload returns 500", state: "done", project: "p-blurt",
    work: { by: "user", commit: "9f8e7d6c", at: "2026-10-21T18:00:00+08:00" } },
];
