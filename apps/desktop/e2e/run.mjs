// End-to-end test of the desktop app through tauri-driver (Linux: WebKitWebDriver; Windows: msedgedriver).
// Not available on macOS (no WKWebView driver) — CI runs it on ubuntu-24.04 under xvfb.
//
//   BLURT_APP=apps/desktop/src-tauri/target/release/blurt node apps/desktop/e2e/run.mjs
//
// It opens a fixture project (scripts/fixture_index.py: projects.py add → items.py migrate → index.py scan), starts the
// app on it and checks: the project's items are listed from index.db v2 → search (trigram) narrows them → an item opens
// in the review component (protocol v3) → editing its title saves through items_ops (items.py user-ops) → the item's
// Markdown file has the new title → the index finds it → the inbox renders → Settings → Phone → Add Phone… shows a
// pairing QR code (the real blurt-remote host: it listens on a free port and draws the code; no phone needed).
// Selectors: the shell's data-testid attributes, and the review canvas's own markup (textarea.title). Text is read as
// textContent: WebKitWebDriver's getText() returns '' for these elements.

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

// A sidebar place or the gear. In a narrow window the sidebar is folded away: open it with its toolbar button first.
async function sidebar(id) {
  const css = By.css(`[data-testid="${id}"]`);
  const shown = async () => {
    const els = await wd.findElements(css);
    return els.length > 0 && (await els[0].isDisplayed()) && els[0];
  };
  if (!(await shown())) await (await wd.findElement(By.css('[data-testid="toggle-sidebar"]'))).click();
  return waitFor(shown, `the sidebar's ${id}`);
}

function mdWithTitle(title) {
  const dir = join(fx.repo, '.blurt', 'items');
  return readdirSync(dir).some((f) => f.endsWith('.md') && readFileSync(join(dir, f), 'utf-8').includes(title));
}

let failed = false;
try {
  // 1. the project's items, from index.db v2
  await waitFor(async () => (await rows()).length >= 4, 'the items table');
  // the heading is the fixture project (fixture_index.py names it my-saas), with its counts beside it
  const text = async (id) => (await wd.findElement(By.css(`[data-testid="${id}"]`)).getAttribute('textContent')).trim();
  await waitFor(async () => (await text('list-title')) === 'my-saas', 'the project heading (my-saas)');
  console.log('project:', await text('list-title'), '·', await text('counts'), '·', (await rows()).length, 'rows');
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
  // three calls: in one, WebKitWebDriver drops the text after the Ctrl chord and the field keeps its old title
  await title.sendKeys(Key.chord(Key.CONTROL, 'a'));
  await title.sendKeys(NEW);
  assert.equal(await title.getAttribute('value'), NEW, 'the title field has the new title');
  await title.sendKeys(Key.ENTER);
  await waitFor(() => mdWithTitle(NEW), 'the Markdown file to have the new title');
  console.log('item file updated');

  // 5. the index follows (items.py re-indexes in-process; the watcher emits index://changed)
  await search.sendKeys(Key.chord(Key.CONTROL, 'a'));
  await search.sendKeys('e2e');
  await waitFor(async () => {
    const r = await rows();
    return r.length === 1 && (await r[0].getAttribute('textContent')).includes('e2e');
  }, 'the renamed item in search');
  await shot('3-edited');

  // 6. the inbox renders (its items, or its empty state); the search is cleared first (it carries across places)
  await search.sendKeys(Key.ESCAPE);
  await waitFor(async () => (await search.getAttribute('value')) === '', 'the search cleared');
  await (await sidebar('nav-inbox')).click();
  await waitFor(async () => (await text('list-title')) === 'Inbox', 'the Inbox heading');
  await waitFor(async () => (await wd.findElements(By.css('[data-testid="items"], [data-testid="inbox-empty"]'))).length > 0, 'the inbox');
  console.log('inbox:', await text('counts').catch(() => '(empty)'), '·', (await rows()).length, 'rows');
  await shot('4-inbox');

  // 7. Settings → Phone → Add Phone…: the host starts listening and the pane shows the pairing QR code (an SVG data URI)
  await (await sidebar('nav-settings')).click();
  await (await waitFor(() => wd.findElement(By.css('[data-testid="settings-tab-phone"]')), 'Settings')).click();
  await (await waitFor(() => wd.findElement(By.css('[data-testid="settings-pane-phone"] [data-testid="phone-add"]')), 'the Phone pane')).click();
  const qr = await waitFor(async () => {
    const el = await wd.findElement(By.css('[data-testid="phone-pairing"] [data-testid="phone-qr"]'));
    return (await el.getAttribute('src')).startsWith('data:image/svg+xml') && (await el.isDisplayed()) && el;
  }, 'the pairing QR code');
  const size = await qr.getRect();
  assert.ok(size.width >= 100 && size.height >= 100, `the QR code is drawn at a scannable size (${size.width}×${size.height})`);
  console.log('phone: pairing code shown', `${Math.round(size.width)}×${Math.round(size.height)}`);
  await shot('5-phone');
  // Cancel takes the code down: Add Phone… comes back
  await (await wd.findElement(By.css('[data-testid="phone-cancel"]'))).click();
  await waitFor(async () => (await wd.findElements(By.css('[data-testid="phone-add"]'))).length === 1, 'Add Phone… after Cancel');
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
