/* The v3 contract from the component's side (next-round.md K1 doc / user-ops, K2 moves, K3 work, K6 handoff, K8
   rings, protocol v3), in Chromium and WebKit, against e2e/v3server.ts. Skipped in the parity run (REVIEW_HTML). */
import { expect, test as base, type Page } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import type { Scope } from "../src/host";
import { V3_ITEMS } from "../test/v3store";
import { LEGACY } from "./harness";
import { renderScenes } from "./scenes";
import { BRIDGE, startV3, type V3Server } from "./v3server";

const U = (n: number) => V3_ITEMS[n].uid!;
const SHOTS = join(process.cwd(), "screens", "v3");

const test = base.extend<{ scope: Scope; query: string; bridge: string[] | null; server: V3Server }>({
  scope: [{ session: "/Users/me/workspace/bug-agent/.blurt/sessions/20261022-101500" }, { option: true }],
  query: ["?lang=en", { option: true }],
  bridge: [null, { option: true }],
  server: [async ({ scope, query, bridge, page, browser }, use) => {
    const sc = await renderScenes(browser);
    const s = await startV3(scope, {
      [U(0)]: [sc.login, sc.devtools], [U(1)]: [sc.pricing], [U(2)]: [sc.notes], [U(3)]: [sc.hero], [U(5)]: [sc.toasts],
    });
    await page.addInitScript(() => {
      if (!sessionStorage.getItem("seeded")) {
        localStorage.clear();
        localStorage.setItem("blurt.view", "focus");
        sessionStorage.setItem("seeded", "1");
      }
    });
    if (bridge) await page.addInitScript(BRIDGE(scope, bridge));
    await page.goto(s.url + query);
    await use(s);
    s.stop();
  }, { auto: true }],
});
test.skip(LEGACY, "v3 is new");

const curId = (page: Page) => page.locator(".insp .iid");
const item = (s: V3Server, n: number) => s.store.items.find((i) => i.uid === U(n))!;
async function until<T>(fn: () => T, ms = 5000): Promise<T> {
  const end = Date.now() + ms;
  for (;;) {
    const v = fn();
    if (v) return v;
    if (Date.now() > end) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 50));
  }
}
async function shot(page: Page, name: string, info: { project: { name: string } }) {
  mkdirSync(SHOTS, { recursive: true });
  await page.waitForTimeout(450);
  await page.screenshot({ path: join(SHOTS, `${info.project.name}-${name}.png`) });
}

test("ops go out by uid; a project move changes the id and keeps what you were typing", async ({ page, server }) => {
  await expect(curId(page)).toHaveText("BA-12");
  const actual = page.locator('textarea[data-k="actual"]');
  await actual.click();
  await actual.fill("Nothing happens on Safari");
  await page.locator("#projectPick").selectOption("p-site"); // the move goes out at once, the typing 450 ms later
  await expect(curId(page)).toHaveText("WS-8");
  await expect(actual).toHaveValue("Nothing happens on Safari");
  await until(() => item(server, 0).actual === "Nothing happens on Safari" && item(server, 0).project === "p-site");
  expect(item(server, 0).aliases).toEqual(["BA-12"]);
  expect(server.ops.every((o) => (o.op === "add" ? o.item.uid : o.id)?.startsWith("01JB"))).toBe(true);
  await expect(page.locator("#toast")).toContainText("Moved to website");
  // more edits after the move still land on the same item
  await actual.fill("Nothing happens on Safari 18");
  await until(() => item(server, 0).actual === "Nothing happens on Safari 18");
  await expect(page.locator("#provenance")).toContainText("BA-12"); // earlier IDs
});

test("work: the agent says fixed, you mark it done; reopen brings it back", async ({ page, server }) => {
  await expect(page.locator("#workRow .sring")).toHaveClass(/s-to_verify/);
  await expect(page.locator("#workRow")).toContainText("The agent says it’s fixed");
  await page.locator("#workDone").click();
  await expect(page.locator("#workRow .sring")).toHaveClass(/s-done/);
  await until(() => item(server, 0).work?.state === "done");
  expect(server.ops.at(-1)).toEqual({ op: "work", id: U(0), state: "done" });
  await page.locator("#workReopen").click();
  await until(() => item(server, 0).work?.state === "todo");
  await expect(page.locator(".qi").first().locator(".sring")).toHaveClass(/s-todo/);
});

test("an agent's write shows up by itself (poll), the user's edits stay", async ({ page, server }) => {
  await page.locator(".qi").nth(5).click();
  await expect(curId(page)).toHaveText("BA-15");
  const t = page.locator(".insp .title");
  await t.click();
  await t.fill("Toast stacks three times after save");
  server.store.agentWork(U(5), "to_verify", "fixed");
  await expect(page.locator("#workRow .sring")).toHaveClass(/s-to_verify/, { timeout: 4000 });
  await expect(t).toHaveValue("Toast stacks three times after save");
  await until(() => item(server, 5).title === "Toast stacks three times after save");
});

test("handoff: copy the instruction for your own agent", async ({ page, server, browserName }) => {
  if (browserName === "chromium") await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.locator(".qi").nth(3).click();
  await expect(curId(page)).toHaveText("WS-7");
  await page.locator("#copyInstruction").click();
  await expect(page.locator("#toast")).toContainText("Instruction copied · H-0013");
  expect(server.handoffs).toEqual([{ uids: [U(3)], what: "instruction" }]);
  await expect(page.locator("#workRow .sring")).toHaveClass(/s-handed_off/, { timeout: 4000 });
  await expect(page.locator("#workRow")).toContainText("Copied to your agent");
  if (browserName === "chromium") expect(await page.evaluate(() => navigator.clipboard.readText())).toContain("H-0013.md");
});

test("list: select, batch move, drag cards onto a project", async ({ page, server }, info) => {
  await expect(curId(page)).toHaveText("BA-12");
  await page.keyboard.press("g");
  await expect(page.locator(".card")).toHaveCount(7);
  await page.locator(".card").nth(1).hover();
  await page.locator(".card").nth(1).locator(".pickbox").click();
  await page.locator(".card").nth(3).locator(".pickbox").click({ modifiers: ["Shift"] });
  await expect(page.locator(".selcount")).toHaveText("3 selected");
  await shot(page, "list-selection-en-light", info);
  await page.locator("#selMove").selectOption("p-blurt");
  await until(() => item(server, 1).project === "p-blurt" && item(server, 3).project === "p-blurt");
  await expect(page.locator("#toast")).toContainText("Moved 2 items to bug-agent"); // BA-13 was already there
  await page.locator("#selClear").click();
  // drag one card onto Unassigned (HTML5 drag events with a real DataTransfer: deterministic in both engines)
  const dt = await page.evaluateHandle(() => new DataTransfer());
  await page.locator(".card").nth(4).dispatchEvent("dragstart", { dataTransfer: dt });
  await expect(page.locator(".dropzone")).toBeVisible();
  await page.locator('.dz[data-project="inbox"]').dispatchEvent("dragover", { dataTransfer: dt });
  await expect(page.locator('.dz[data-project="inbox"]')).toHaveClass(/over/);
  await shot(page, "list-dragging-en-light", info);
  await page.locator('.dz[data-project="inbox"]').dispatchEvent("drop", { dataTransfer: dt });
  await until(() => item(server, 4).project === "inbox");
  await expect(page.locator(".dropzone")).toHaveCount(0);
});

for (const theme of ["light", "dark"] as const)
  for (const lang of ["en", "zh-Hans"] as const)
    test.describe(`screens ${lang} ${theme}`, () => {
      test.use({ query: `?lang=${lang}&theme=${theme}&platform=mac` });
      test(`six work rings, focus and list (${lang}, ${theme})`, async ({ page }, info) => {
        await expect(page.locator(".shot.ready img")).toBeVisible();
        await shot(page, `focus-${lang}-${theme}`, info);
        await page.keyboard.press("g");
        const rings = page.locator(".card .sring");
        await expect(rings).toHaveCount(7);
        const states = await rings.evaluateAll((els) => [...new Set(els.map((e) => e.getAttribute("class")))].sort());
        expect(states).toEqual(["sring s-done", "sring s-handed_off", "sring s-in_progress", "sring s-to_verify", "sring s-todo", "sring s-wontfix"]);
        await shot(page, `list-${lang}-${theme}`, info);
        // the rings up close, at the detail size
        await page.keyboard.press("g");
        for (const n of [0, 1, 2, 4, 5, 6]) {
          await page.locator(".qi").nth(n).click();
          await page.locator("#workRow").screenshot({ path: join(SHOTS, `${info.project.name}-ring-${n}-${lang}-${theme}.png`) });
        }
      });
    });

test.describe("in the macOS main window (macos host over the bridge, a project, embedded)", () => {
  test.use({ scope: { project: "p-blurt" }, query: "?host=macos&project=p-blurt&lang=zh-Hans", bridge: ["reveal", "dispatch", "handoff", "openSession"] });
  test("project scope, no chrome of its own, dispatch / handoff / open session go to the host", async ({ page, server }, info) => {
    await expect(page.locator(".qi")).toHaveCount(5);
    await expect(page.locator(".brand")).toHaveCount(0);
    await expect(page.locator("#langBtn")).toHaveCount(0);
    await expect(page.locator("#finishBtn")).toHaveCount(0); // a project, not a session's batch
    expect(server.calls[0]).toEqual({ method: "load", params: { scope: { project: "p-blurt" } } });
    await expect(page.locator("#workSession")).toBeVisible();
    await page.locator("#workSession").click();
    await page.locator("#dispatchBtn").click();
    await until(() => server.calls.some((c) => c.method === "dispatch"));
    expect(server.calls.find((c) => c.method === "dispatch")!.params).toEqual({ uids: [U(0)] });
    expect(server.calls.find((c) => c.method === "openSession")!.params).toEqual({ job: "j-20261022-101500-ab12" });
    await shot(page, "embedded-project-zh", info);
    // moving an item away takes it out of this project's list
    await page.locator("#projectPick").selectOption("inbox");
    await expect(page.locator(".qi")).toHaveCount(4);
    await until(() => item(server, 0).project === "inbox");
  });
});
