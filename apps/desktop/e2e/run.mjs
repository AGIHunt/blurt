// End-to-end test of the desktop app through tauri-driver (Linux: WebKitWebDriver; Windows: msedgedriver).
// Not available on macOS (no WKWebView driver) — CI runs it on ubuntu-22.04 under xvfb.
//
//   BLURT_APP=apps/desktop/src-tauri/target/release/blurt node apps/desktop/e2e/run.mjs
//
// It opens a fixture project (scripts/fixture_index.py: projects.py add → items.py migrate → index.py scan), starts the
// app on it and checks: the project's items are listed from index.db v2 → search (trigram) narrows them → an item opens
// in the review component (protocol v3) → editing its title saves through items_ops (items.py user-ops) → the item's
// Markdown file has the new title → the index finds it → the inbox and the agent sessions views render.
// Selectors: the shell's data-testid attributes, and the review canvas's own markup (textarea.title).

import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { Builder, By, Capabilities, Key } from 'selenium-webdriver';

const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(process.env.BLURT_APP ?? join(here, '../src-tauri/target/release/blurt'));
const shots = resolve(process.env.E2E_SCREENSHOTS ?? join(here, 'screenshots'));
mkdirSync(shots, { recursive: true });

const fx = JSON.parse(
  execFileSync('python3', [join(here, '../scripts/fixture_index.py'), join(mkdtempSync(join(tmpdir(), 'blurt-e2e-')), 'fx')], { encoding: 'utf-8' })
    .trim()
    .split('\n')
    .pop(),
);
console.log('fixture:', fx.scan);

const env = {
  ...process.env,
  HOME: fx.home,
  BLURT_HOME: fx.blurt_home,
  BLURT_WORKSPACE: fx.workspace,
  BLURT_QUIT_ON_CLOSE: '1',
  BLURT_NO_ISLAND: '1',
  BLURT_LANG: 'en',
  BLURT_START_VIEW: `project:${fx.project}`,
};
const driverBin = process.env.TAURI_DRIVER ?? 'tauri-driver';
const driver = spawn(driverBin, [], { env, stdio: ['ignore', 'inherit', 'inherit'] });
await new Promise((r) => setTimeout(r, 1500));

const caps = new Capabilities();
caps.set('tauri:options', { application: app });
caps.setBrowserName('wry');
const wd = await new Builder().withCapabilities(caps).usingServer('http://127.0.0.1:4444/').build();

async function shot(name) {
  writeFileSync(join(shots, `${name}.png`), await wd.takeScreenshot(), 'base64');
}

async function rows() {
  return wd.findElements(By.css('[data-testid="item-row"]'));
}

async function waitFor(fn, what, ms = 20000) {
  const t0 = Date.now();
  let last;
  while (Date.now() - t0 < ms) {
    try {
      last = await fn();
      if (last) return last;
    } catch (e) {
      last = e;
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`timed out waiting for ${what} (last: ${last})`);
}

function mdWithTitle(title) {
  const dir = join(fx.repo, '.blurt', 'items');
  return readdirSync(dir).some((f) => f.endsWith('.md') && readFileSync(join(dir, f), 'utf-8').includes(title));
}

let failed = false;
try {
  // 1. the project's items, from index.db v2
  await waitFor(async () => (await rows()).length >= 4, 'the items table');
  console.log('items:', await wd.findElement(By.css('[data-testid="total"]')).getText());
  await shot('1-project');

  // 2. search: ≥ 3 chars → FTS5 trigram
  const search = await wd.findElement(By.css('[data-testid="search"]'));
  await search.sendKeys('头像上');
  await waitFor(async () => (await rows()).length === 1, 'one search hit');

  // 3. open it: the review component (mode=item, scope = the project) shows it; its title is a textarea.title
  await (await rows())[0].click();
  const TITLE = '.review-pane textarea.title';
  const title = await waitFor(async () => {
    const el = await wd.findElement(By.css(TITLE));
    return (await el.getAttribute('value')).includes('头像上传') && el;
  }, 'the item detail');
  await shot('2-item');

  // 4. edit the title (Enter commits) → items_ops → items.py user-ops → the item's Markdown file
  const NEW = '头像上传返回 500（e2e）';
  await title.click();
  await title.sendKeys(Key.chord(Key.CONTROL, 'a'), NEW, Key.ENTER);
  await waitFor(() => mdWithTitle(NEW), 'the Markdown file to have the new title');
  console.log('item file updated');

  // 5. the index follows (items.py re-indexes in-process; the watcher emits index://changed)
  await search.sendKeys(Key.chord(Key.CONTROL, 'a'), 'e2e');
  await waitFor(async () => {
    const r = await rows();
    return r.length === 1 && (await r[0].getText()).includes('e2e');
  }, 'the renamed item in search');
  await shot('3-edited');

  // 6. the inbox and the agent sessions render
  await (await wd.findElement(By.css('[data-testid="nav-inbox"]'))).click();
  await waitFor(async () => (await wd.findElements(By.css('[data-testid="inbox"], [data-testid="inbox-empty"]'))).length > 0, 'the inbox');
  await (await wd.findElement(By.css('[data-testid="nav-sessions"]'))).click();
  await waitFor(async () => (await wd.getPageSource()).includes('Agent'), 'the sessions view');
  await shot('4-sessions');
  console.log('e2e: ok');
} catch (e) {
  failed = true;
  console.error('e2e failed:', e);
  await shot('failure').catch(() => {});
} finally {
  await wd.quit().catch(() => {});
  driver.kill();
}
process.exit(failed ? 1 : 0);
