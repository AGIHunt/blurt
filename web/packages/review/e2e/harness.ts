/* Start review.py on a scratch copy of a fixture session and talk to its items.json. */
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { copyFileSync, cpSync, existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
export const REPO = resolve(here, "../../../..");
export const FIXTURES = join(REPO, "tests/fixtures/sessions");
const SCRIPTS = join(REPO, "skills/blurt/scripts");
export const PY = process.env.PYTHON || (process.platform === "win32" ? "python" : "python3");

/** the page under test: the built review.html, or REVIEW_HTML (parity runs against the old page) */
export const LEGACY = !!process.env.REVIEW_HTML;

export interface Session {
  url: string;
  dir: string;
  scripts: string;
  proc: ChildProcess;
  /** review.py's stdout after it exited (the summary line) */
  exited: Promise<string>;
  items(): { items: Record<string, any>[]; [k: string]: any };
  item(id: string): Record<string, any> | undefined;
  run(script: string, ...args: string[]): { code: number | null; out: string; err: string };
  stop(): void;
}

export async function startReview(fixture = "20261021-101500"): Promise<Session> {
  const root = mkdtempSync(join(tmpdir(), "blurt-review-"));
  const dir = join(root, fixture);
  cpSync(join(FIXTURES, fixture), dir, { recursive: true });
  let scripts = SCRIPTS;
  if (process.env.REVIEW_HTML) {
    scripts = join(root, "scripts");
    cpSync(SCRIPTS, scripts, { recursive: true, filter: (p) => !p.includes("__pycache__") });
    copyFileSync(resolve(process.env.REVIEW_HTML), join(scripts, "review.html"));
  }
  // every Blurt folder in the scratch root: a session outside any project is filed into the inbox store, which
  // would otherwise be the user's own ~/Blurt/inbox
  const env = { ...process.env, BLURT_HOME: join(root, "home"), BLURT_WORKSPACE: join(root, "Blurt"), BLURT_NO_INDEX: "1",
    PYTHONDONTWRITEBYTECODE: "1" };
  const proc = spawn(PY, [join(scripts, "review.py"), dir, "--open", "none"], { env, stdio: ["ignore", "pipe", "pipe"] });
  let out = "";
  const exited = new Promise<string>((res) => proc.on("exit", () => res(out)));
  const url = await new Promise<string>((res, rej) => {
    const t = setTimeout(() => rej(new Error("review.py did not start: " + out)), 15000);
    proc.stdout!.on("data", (b: Buffer) => {
      out += b.toString();
      const m = out.match(/REVIEW (\S+)/);
      if (m) {
        clearTimeout(t);
        res(m[1]);
      }
    });
    proc.stderr!.on("data", (b: Buffer) => (out += b.toString()));
  });
  // review.py ingests the fixture's items.json into Markdown items (K1): read them back the way hosts do, by the
  // agent's draft id (I-001 → source.local_id) or the item id
  const items = () => {
    const r = spawnSync(PY, [join(scripts, "items.py"), "doc", dir, "--state", "new", "--state", "todo", "--state",
      "handed_off", "--state", "in_progress", "--state", "to_verify", "--state", "done", "--state", "wontfix",
      "--state", "discarded"], { env, encoding: "utf8" });
    const doc = JSON.parse(r.stdout).doc;
    const batch = JSON.parse(readFileSync(join(dir, "batch.json"), "utf8"));
    return { ...doc, reviewed: batch.reviewed };
  };
  return {
    url,
    dir,
    scripts,
    proc,
    exited,
    items,
    item: (id) =>
      items().items.find((i: { id: string; source?: { local_id?: string } }) => i.source?.local_id === id || i.id === id),
    run: (script, ...args) => {
      const r = spawnSync(PY, [join(scripts, script), ...args], { env, encoding: "utf8" });
      return { code: r.status, out: r.stdout, err: r.stderr };
    },
    stop: () => {
      if (proc.exitCode == null) proc.kill();
      try {
        if (existsSync(root)) rmSync(root, { recursive: true, force: true });
      } catch {
        /* windows: still open */
      }
    },
  };
}

/** poll until fn() is truthy (file-side assertions) */
export async function until<T>(fn: () => T, ms = 5000, step = 100): Promise<T> {
  const end = Date.now() + ms;
  let last: unknown;
  for (;;) {
    try {
      const v = fn();
      if (v) return v;
    } catch (e) {
      last = e;
    }
    if (Date.now() > end) throw new Error("timed out" + (last ? `: ${last}` : ""));
    await new Promise((r) => setTimeout(r, step));
  }
}
