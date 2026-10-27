// macOS only: compile e2e/wkwebview/Harness.swift and run the review canvas in a real WKWebView with the C6 macos host
// (blurt-app:// scheme + message bridge + items.py user-ops) against a copy of the v2 fixture. Needs `vite build` first.
import { execFileSync, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdtempSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

if (process.platform !== "darwin") {
  console.log("wkwebview: macOS only, skipped");
  process.exit(0);
}
const here = dirname(fileURLToPath(import.meta.url));
const pkg = resolve(here, "..");
const repo = resolve(pkg, "../../..");
const html = join(pkg, "dist/index.html");
if (!existsSync(html)) {
  console.error("run `vite build` first");
  process.exit(1);
}
const work = mkdtempSync(join(tmpdir(), "blurt-wk-"));
const bin = join(work, "harness");
const src = join(pkg, "e2e/wkwebview/Harness.swift");
console.log("compiling", src);
execFileSync("swiftc", ["-O", "-o", bin, src], { stdio: "inherit" });
const session = join(work, "20261021-101500");
cpSync(join(repo, "tests/fixtures/sessions/20261021-101500"), session, { recursive: true });
const out = process.env.WK_OUT || join(pkg, "screens");
// every Blurt folder in the scratch dir: items.py files the fixture's items into the inbox store, which would
// otherwise be the user's own ~/Blurt/inbox (the harness refuses to run without these)
const env = { ...process.env, BLURT_HOME: join(work, "home"), BLURT_WORKSPACE: join(work, "Blurt"), BLURT_NO_INDEX: "1",
  PYTHONDONTWRITEBYTECODE: "1" };
const r = spawnSync(bin, ["--html", html, "--session", session, "--scripts", join(repo, "skills/blurt/scripts"), "--out", out,
  "--icon", join(repo, "skills/blurt/assets/icon.png"), "--python", process.env.PYTHON || "python3"],
  { stdio: "inherit", timeout: 120_000, env });
console.log(`wkwebview harness exit ${r.status} (html ${(statSync(html).size / 1024).toFixed(1)} KB)`);
process.exit(r.status ?? 1);
