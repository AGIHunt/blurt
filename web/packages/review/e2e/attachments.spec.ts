/* An item's attached files in the Mac main window's detail (macos host over the bridge, item mode): a row a file,
   Quick Look on click / Space, Show in Finder and Remove at the row's end without anything moving. Chromium and
   WebKit, light and dark; screenshots go to screens/v3/. Skipped in the parity run (REVIEW_HTML). */
import { expect, test as base, type Page } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import type { Item, Scope } from "../src/host";
import { PROJECTS } from "../test/v3store";
import { LEGACY } from "./harness";
import { renderScenes } from "./scenes";
import { BRIDGE, startV3, type V3Server } from "./v3server";

const SHOTS = join(process.cwd(), "screens", "v3");
const UID = "01JB7ZK3Q4M8W2E5R6T9Y0FFF1";
const PDF = "/Users/me/Documents/specs/spec-v2.pdf";
const MP4 = "/Users/me/Movies/Screen Recordings/onboarding-walkthrough.mp4";
const DOCX = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Work/Clients/Northwind/2026/Q4 planning/Homepage redesign — interview notes and open questions (reviewed, final).docx";
const ITEM: Item = {
  id: "BA-21", uid: UID, kind: "task", title: "Rework the homepage hero", state: "todo", project: PROJECTS[0].id, project_by: "capture",
  details: "The headline is fine. The second line says nothing, and the call to action is below the fold on a 13-inch screen.",
  expected: "The hero says what the product does in one line, and the button is in view without scrolling.",
  attachments: [PDF, MP4, DOCX], source: { type: "snap", by: "me", app: "Safari" }, created: "2026-11-14T10:15:00+08:00",
};
const scope: Scope = { project: PROJECTS[0].id };

// the app's scheme handler, played by the test server: an <img> at blurt-app://file/<path> loads /files/<path>
const FILES = `{
  const d = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, "src");
  const here = (v) => String(v).replace("blurt-app://file/", "/files/");
  Object.defineProperty(HTMLImageElement.prototype, "src", { ...d, set(v) { d.set.call(this, here(v)); } });
  const set = Element.prototype.setAttribute;
  Element.prototype.setAttribute = function (k, v) { return set.call(this, k, k === "src" ? here(v) : v); };
}`;

const test = base.extend<{ theme: "light" | "dark"; app: boolean; lang: string; server: V3Server }>({
  theme: ["light", { option: true }],
  /** the Mac main window's detail (macos host over the bridge, item mode); false: review.py's page in a browser */
  app: [true, { option: true }],
  lang: ["en", { option: true }],
  server: [async ({ theme, app, lang, page, browser }, use) => {
    const sc = await renderScenes(browser);
    const s = await startV3(app ? scope : { session: "/Users/me/Blurt/inbox/.blurt/sessions/20261114-101500" }, { [UID]: [sc.hero] }, [ITEM]);
    if (app) {
      await page.addInitScript(BRIDGE(scope, ["reveal", "quickLook", "registerUndo"]));
      await page.addInitScript(FILES);
      await page.setViewportSize({ width: 760, height: 860 });
    } else await page.addInitScript(() => localStorage.setItem("blurt.view", "focus"));
    await page.goto(`${s.url}?lang=${lang}&theme=${theme}&platform=mac` + (app ? `&host=macos&project=${PROJECTS[0].id}&mode=item&item=${UID}` : ""));
    await use(s);
    s.stop();
  }, { auto: true }],
});
test.skip(LEGACY, "v3 is new");

const calls = (s: V3Server, method: string) => s.calls.filter((c) => c.method === method).map((c) => c.params.path);
const box = async (page: Page, sel: string) => JSON.stringify(await page.locator(sel).evaluateAll((els) => els.map((e) => {
  const r = e.getBoundingClientRect();
  return [r.x, r.y, r.width, r.height];
})));

for (const theme of ["light", "dark"] as const)
  test.describe(`attached files (${theme})`, () => {
    test.use({ theme });
    test("rows, not a list of paths; open, reveal and remove; nothing moves on hover", async ({ page, server, browserName }, info) => {
      // Safari's Tab stops at text fields only (the system's Keyboard Navigation setting adds the rest): ⌥Tab reaches buttons
      const tab = browserName === "webkit" ? "Alt+Tab" : "Tab";
      const rows = page.locator(".files .file");
      await expect(rows).toHaveCount(3);
      await expect(page.locator(".files .sec-h")).toHaveText("Attachments");
      await expect(page.locator('[data-k="attachments"]')).toHaveCount(0);
      await expect(page.locator(".shot.ready img")).toBeVisible();
      mkdirSync(SHOTS, { recursive: true });
      await page.waitForTimeout(450);
      await page.screenshot({ path: join(SHOTS, `${info.project.name}-attachments-${theme}.png`) });

      // every row is inside the column, the long one cut: its name keeps the extension, its folder its last part
      const fit = await rows.evaluateAll((els) => els.map((e) => e.getBoundingClientRect().right <= e.closest(".side")!.getBoundingClientRect().right));
      expect(fit).toEqual([true, true, true]);
      const long = rows.nth(2);
      expect(await long.locator(".file-n > :first-child").evaluate((e) => e.scrollWidth > e.clientWidth)).toBe(true);
      expect(await long.locator(".file-d").evaluate((e) => e.scrollWidth > e.clientWidth)).toBe(true);
      expect(await rows.nth(0).locator(".file-d").evaluate((e) => e.scrollWidth > e.clientWidth)).toBe(false);

      // the row's buttons appear on hover; no box changes
      const before = await box(page, ".files .file, .files .file-open, .files .file-n, .files .file-d, #workRow, #provenance");
      await expect(rows.nth(0).locator(".file-a")).toHaveCSS("opacity", "0");
      await rows.nth(0).hover();
      await expect(rows.nth(0).locator(".file-a")).toHaveCSS("opacity", "1");
      expect(await box(page, ".files .file, .files .file-open, .files .file-n, .files .file-d, #workRow, #provenance")).toBe(before);
      await page.screenshot({ path: join(SHOTS, `${info.project.name}-attachments-hover-${theme}.png`) });

      // a click is Quick Look; Space and Enter on the focused row each once more — and never the page's key
      await rows.nth(0).locator(".file-open").click();
      await expect.poll(() => calls(server, "quickLook")).toEqual([PDF]);
      await rows.nth(1).locator(".file-open").focus();
      await page.keyboard.press("Space");
      await page.keyboard.press("Enter");
      await expect.poll(() => calls(server, "quickLook")).toEqual([PDF, MP4, MP4]);
      await page.waitForTimeout(200);
      expect(calls(server, "quickLook")).toEqual([PDF, MP4, MP4]);
      await page.keyboard.press(tab); // Show in Finder
      await expect(rows.nth(1).locator(".file-a")).toHaveCSS("opacity", "1");
      await page.keyboard.press("Enter");
      await expect.poll(() => calls(server, "reveal")).toEqual([MP4]);
      await page.screenshot({ path: join(SHOTS, `${info.project.name}-attachments-focus-${theme}.png`) });

      // Remove: the field without that path, as a field edit; the window's undo step is named
      await page.keyboard.press(tab);
      await expect(page.locator(".file-rm:focus")).toHaveAttribute("aria-label", "Remove: onboarding-walkthrough.mp4");
      await page.keyboard.press("Enter");
      await expect(rows).toHaveCount(2);
      await expect.poll(() => server.store.items[0].attachments).toEqual([PDF, DOCX]);
      expect(server.calls.filter((c) => c.method === "registerUndo").map((c) => c.params.label)).toEqual(["Edit Attachments"]);
      expect(server.store.items[0].state).toBe("todo"); // no key reached the page (Enter would not, D would)
      // the keyboard stays in the list: the row that moved up has the focus
      await expect(page.locator(".file-open:focus")).toHaveAttribute("title", DOCX);
      await page.keyboard.press("Backspace");
      await expect(rows).toHaveCount(1);
      await page.keyboard.press("Delete");
      await expect(page.locator(".files")).toHaveCount(0);
      await expect.poll(() => server.store.items[0].attachments).toEqual([]);
    });
  });

test.describe("attached files on review.py's page (no Quick Look, no Finder)", () => {
  test.use({ app: false, lang: "zh-Hans" });
  test("the narrow inspector: rows fit, a click copies the path, Remove is there", async ({ page, server, context, browserName }, info) => {
    if (browserName === "chromium") await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    const rows = page.locator(".files .file");
    await expect(rows).toHaveCount(3);
    await expect(page.locator(".files .sec-h")).toHaveText("附件");
    await expect(page.locator(".shot.ready img")).toBeVisible();
    const fit = await rows.evaluateAll((els) => els.map((e) => e.getBoundingClientRect().right <= e.closest(".side")!.getBoundingClientRect().right));
    expect(fit).toEqual([true, true, true]);
    await rows.nth(2).hover();
    await expect(rows.nth(2).locator(".file-a button")).toHaveCount(1); // nothing to reveal with: Remove only
    await page.waitForTimeout(450);
    await page.screenshot({ path: join(SHOTS, `${info.project.name}-attachments-review-zh.png`) });
    await expect(rows.nth(0).locator(".file-open")).toHaveAttribute("aria-label", "复制路径：spec-v2.pdf");
    await rows.nth(0).locator(".file-open").click();
    await expect(page.locator("#toast")).toContainText("已复制 " + PDF);
    if (browserName === "chromium") expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(PDF);
    await rows.nth(2).locator(".file-rm").click();
    await expect(rows).toHaveCount(2);
    await expect(page.locator("#toast")).toContainText("已移除 Homepage redesign");
    await expect.poll(() => server.store.items[0].attachments).toEqual([PDF, MP4]);
    await page.locator("#toast button").click(); // Undo
    await expect(rows).toHaveCount(3);
    await expect.poll(() => server.store.items[0].attachments).toEqual([PDF, MP4, DOCX]);
  });
});
