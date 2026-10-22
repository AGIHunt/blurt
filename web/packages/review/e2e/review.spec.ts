/* WP3 acceptance (design doc §6) against `review.py tests/fixtures/sessions/<fixture>` — and, with REVIEW_HTML, the
   same checks against the old vanilla page (the parity run). Checks marked NEW cover behaviour the old page lacked. */
import { expect, test as base, type Page } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { LEGACY, startReview, until, type Session } from "./harness";

const V2 = "20261021-101500";
const SHOTS = "20261020-141500-shots";
const V1 = "20261019-093000";

const test = base.extend<{ fixture: string; session: Session; query: string }>({
  fixture: [V2, { option: true }],
  query: ["", { option: true }],
  session: [async ({ fixture, page, query }, use) => {
    const s = await startReview(fixture);
    await page.addInitScript(() => {
      if (!sessionStorage.getItem("seeded")) {
        localStorage.clear();
        localStorage.setItem("blurt.view", "focus");
        sessionStorage.setItem("seeded", "1");
      }
    });
    await page.goto(s.url + query);
    await use(s);
    s.stop();
  }, { auto: true }],
});
const newOnly = () => test.skip(LEGACY, "behaviour the old page did not have");

const curId = (page: Page) => page.locator(".idrow > span").first();
async function ready(page: Page) {
  await expect(page.locator(".qi").first()).toBeVisible();
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur?.()); // keys go to the page, not a field
}

test("J/K move, A keeps, X discards, Z undoes, G and V switch views", async ({ page, session }) => {
  await ready(page);
  // K3: I-001 to verify, I-002 in progress, I-003 new, I-004 won't do (draft + your wontfix), I-005 new (reopened)
  await expect(curId(page)).toHaveText("I-003"); // the first new one
  await page.keyboard.press("j");
  await expect(curId(page)).toHaveText("I-004");
  await page.keyboard.press("k");
  await expect(curId(page)).toHaveText("I-003");

  await page.keyboard.press("a");
  await expect(page.locator("#toast")).toHaveClass(/show/);
  await expect(curId(page)).toHaveText("I-005"); // the next new one
  await until(() => session.item("I-003")?.state === "todo");

  await page.keyboard.press("x");
  await until(() => session.item("I-005")?.state === "discarded");
  await expect(page.locator(".qi.drop")).toHaveCount(1);

  await page.keyboard.press("z");
  await until(() => session.item("I-005")?.state === "new");
  await expect(page.locator(".qi.drop")).toHaveCount(0);
  await expect(curId(page)).toHaveText("I-005");

  await page.keyboard.press("g");
  await expect(page.locator("#listView")).toBeVisible();
  await page.keyboard.press("g");
  await expect(page.locator("#focusView")).toBeVisible();
  await page.keyboard.press("v");
  await expect(page.locator("#overviewView")).toBeVisible();
  await expect(page.locator("#overviewView h1")).toHaveText("个人中心和登录页走查");
});

test("editing a field autosaves it, recorded in _user", async ({ page, session }) => {
  await ready(page);
  const module = page.locator('.f input[data-k="module"]');
  await module.click();
  await module.fill("billing");
  await expect(page.locator("#saved")).toHaveText(/已保存|Saved/, { timeout: 5000 });
  const it = await until(() => {
    const i = session.item("I-001");
    return i?.module === "billing" && i._user?.module ? i : null;
  });
  expect(it!.uid).toBe("01KAQ6N2W8C3D4E5F6G7H8J9KM"); // v2 fields survive the round trip
  expect(it!.fix.state).toBe("fixed");
  // list fields are parsed back into arrays
  const steps = page.locator('textarea[data-k="steps"]');
  await steps.click();
  await steps.fill("1. open profile\n2. upload a PNG\n- see 500");
  await until(() => JSON.stringify(session.item("I-001")?.steps) === JSON.stringify(["open profile", "upload a PNG", "see 500"]));
});

test("M merges into the previous item, Z brings it back", async ({ page, session }) => {
  await ready(page);
  await page.keyboard.press("j");
  await expect(curId(page)).toHaveText("I-002");
  await page.keyboard.press("m");
  await expect(page.locator(".qi")).toHaveCount(4);
  await expect(curId(page)).toHaveText("I-001");
  await until(() => !session.item("I-002") && session.item("I-001")?.merged_from?.[0] === "I-002");
  const merged = session.items();
  expect(merged._removed).toEqual({ "I-002": "I-001" });
  if (!LEGACY) {
    // NEW: the merge never folds uid / fix into the target (the old page wrote "uid1\nuid2")
    expect(session.item("I-001")!.uid).toBe("01KAQ6N2W8C3D4E5F6G7H8J9KM");
    expect(session.item("I-001")!.fix.state).toBe("fixed");
  }

  await page.keyboard.press("z");
  await expect(page.locator(".qi")).toHaveCount(5);
  await until(() => {
    const d = session.items();
    return d.items.map((i) => i.id).join() === "I-001,I-002,I-003,I-004,I-005" && !d.items[0].merged_from && !d._removed;
  });
  expect(session.item("I-001")!.quote).toBe("上传头像直接报 500。");
});

test("frames the agent adds with items.py set-frames show up within 3 s", async ({ page, session }) => {
  await ready(page);
  await page.keyboard.press("j");
  await page.keyboard.press("j");
  await expect(curId(page)).toHaveText("I-003");
  await expect(page.locator(".strip .th img")).toHaveCount(1);
  const r = session.run("items.py", "set-frames", session.dir, "I-003", "frames/I-003-1.jpg@3.3", "frames/I-002-1.jpg@3.6#second look");
  expect(r.code, r.err).toBe(0);
  // the old page polled every 5 s when idle
  await expect(page.locator(".strip .th img")).toHaveCount(2, { timeout: LEGACY ? 7000 : 3000 });
  await expect(curId(page)).toHaveText("I-003"); // the user stays where they were
});

test("agent writes never overwrite a field the user is typing in", async ({ page, session }) => {
  await ready(page);
  const actual = page.locator('textarea[data-k="actual"]');
  await actual.click();
  await actual.fill("typed by the user");
  const r = session.run("items.py", "patch", session.dir, "I-001", "--set", "expected=from the agent");
  expect(r.code, r.err).toBe(0);
  await expect(page.locator('textarea[data-k="expected"]')).toHaveValue("from the agent", { timeout: 7000 });
  await expect(actual).toHaveValue("typed by the user");
  await expect(actual).toBeFocused();
  await until(() => session.item("I-001")?.actual === "typed by the user" && session.item("I-001")?.expected === "from the agent");
});

test("NEW: an IME's Enter (keyCode 229 / isComposing / just after compositionend) never submits", async ({ page, session }) => {
  newOnly();
  await ready(page);
  const title = page.locator(".insp .title");
  await title.click();
  const imeEnter = (init: Record<string, unknown>, keyCode?: number) =>
    title.evaluate(
      (el, [init, keyCode]) => {
        const e = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true, ...(init as object) });
        if (keyCode) Object.defineProperty(e, "keyCode", { get: () => keyCode });
        el.dispatchEvent(e);
        return { prevented: e.defaultPrevented, focused: document.activeElement === el };
      },
      [init, keyCode] as const,
    );
  expect(await imeEnter({}, 229)).toEqual({ prevented: false, focused: true });
  expect(await imeEnter({ isComposing: true })).toEqual({ prevented: false, focused: true });
  // a real Enter commits the title
  await page.keyboard.press("Enter");
  await expect(title).not.toBeFocused();

  // on the page, Enter = keep — but not an IME's Enter
  const docEnter = (keyCode: number, composition = false) =>
    page.evaluate(
      ([keyCode, composition]) => {
        if (composition) document.dispatchEvent(new CompositionEvent("compositionend", { data: "好" }));
        const e = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
        Object.defineProperty(e, "keyCode", { get: () => keyCode });
        document.body.dispatchEvent(e);
      },
      [keyCode, composition] as const,
    );
  await docEnter(229);
  await docEnter(13, true); // within 50 ms of compositionend
  await page.waitForTimeout(600);
  await expect(page.locator(".qi.keep")).toHaveCount(0);
  await expect(curId(page)).toHaveText("I-001");
  await docEnter(13);
  await expect(page.locator(".qi.keep")).toHaveCount(1);

  // the answer field: Enter commits, an IME Enter does not
  await page.locator(".qi").nth(4).click();
  const answer = page.locator('.ask input[data-k="answer"]');
  await answer.click();
  await answer.fill("切换后也不重置");
  const r = await answer.evaluate((el) => {
    const e = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
    Object.defineProperty(e, "keyCode", { get: () => 229 });
    el.dispatchEvent(e);
    return document.activeElement === el;
  });
  expect(r).toBe(true);
  await page.keyboard.press("Enter");
  await expect(answer).not.toBeFocused();
  await until(() => session.item("I-005")?.answer === "切换后也不重置" && session.item("I-005")?._user?.answer);
});

test("⌘⏎ → confirm: unsaved typing is saved first, review.py exits with the summary", async ({ page, session }) => {
  await ready(page);
  await page.keyboard.press("x"); // discard I-003
  const title = page.locator(".title").first();
  await expect(curId(page)).toHaveText("I-005");
  await title.click();
  await title.evaluate((el: HTMLTextAreaElement) => el.setSelectionRange(el.value.length, el.value.length));
  await page.keyboard.type(" (typed)");
  await page.keyboard.press("ControlOrMeta+Enter"); // before the 450 ms autosave fires
  await expect(page.locator("#modalBg")).toHaveClass(/show/);
  await page.locator("#mOk").click();
  await expect(page.locator("#done")).toHaveClass(/show/);
  const out = await session.exited;
  const summary = JSON.parse(out.trim().split("\n").pop()!);
  expect(summary).toMatchObject({ reviewed: true });
  const d = session.items();
  expect(d.reviewed).toBe(true);
  expect(session.item("I-005")!.title).toBe("登录页验证码倒计时不重置 (typed)");
  // finishing keeps what is still new; nothing else changes
  expect(d.items.map((i) => i.state)).toEqual(["to_verify", "in_progress", "discarded", "wontfix", "todo"]);
  for (const i of d.items) expect(i._touched).toBeUndefined();
});

test("finish dialog: review the rest, cancel with Esc", async ({ page }) => {
  await ready(page);
  await page.locator("#finishBtn").click();
  await expect(page.locator("#modal")).toContainText(/还有 2 条没看|2 not reviewed/);
  await page.locator("#mRest").click();
  await expect(page.locator("#modalBg")).not.toHaveClass(/show/);
  await page.keyboard.press("?");
  await expect(page.locator("#modal kbd").first()).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.locator("#modalBg")).not.toHaveClass(/show/);
});

test("list view: search, state and kind filters, open a card", async ({ page }) => {
  await ready(page);
  await page.keyboard.press("g");
  await expect(page.locator(".card")).toHaveCount(5);
  await page.locator("#search").fill("toast");
  await expect(page.locator(".card")).toHaveCount(1);
  await page.locator("#search").fill("");
  await page.locator('#kindFilter [data-kf="idea"]').click();
  await expect(page.locator(".card")).toHaveCount(1);
  await page.locator('#kindFilter [data-kf=""]').click();
  await page.locator("#stateFilter").selectOption("inbox"); // needs you: new + to verify
  await expect(page.locator(".card")).toHaveCount(3);
  await page.locator("#stateFilter").selectOption("wontfix");
  await expect(page.locator(".card")).toHaveCount(1);
  await page.locator("#stateFilter").selectOption("live");
  await page.locator(".card").nth(2).click();
  await expect(page.locator("#focusView")).toBeVisible();
  await expect(curId(page)).toHaveText("I-003");
});

test("media: ← → step through frames, clip and recording; lightbox; O jumps to the recording", async ({ page }) => {
  await ready(page);
  await expect(page.locator("#mediaCap .tm")).toHaveText(LEGACY ? "00:00" : "0:00");
  await page.keyboard.press("ArrowRight");
  await expect(page.locator("#mediaCap .tm")).toHaveText(LEGACY ? "00:01" : "0:01");
  await expect(page.locator("#mediaCap .ct")).toHaveText("Network 面板：POST /avatar 500");
  await page.keyboard.press("ArrowRight");
  await expect(page.locator("#mediaBox video")).toHaveCount(1);
  await page.keyboard.press("ArrowLeft");
  await page.locator(".shot img").click();
  await expect(page.locator("#lightbox")).toHaveClass(/show/);
  await page.keyboard.press("Escape");
  await expect(page.locator("#lightbox")).not.toHaveClass(/show/);
  await page.keyboard.press("o");
  await expect(page.locator(".th.vid.on")).toContainText(/原录屏|Recording/);
  await expect(page.locator("#mediaCap a.dl")).toHaveAttribute("href", /download=1/);
});

test("severity keys and chips, language switch", async ({ page, session }) => {
  await ready(page);
  await page.locator(".qi").first().click();
  await page.keyboard.press("3");
  await expect(page.locator("#sevChip")).toHaveClass(/sev-low/);
  await until(() => session.item("I-001")?.severity === "low");
  await page.locator("#sevChip").click();
  await expect(page.locator("#sevChip")).toHaveClass(/sev-high/);
  await page.locator("#langBtn").click();
  await expect(page.locator("#keepBtn")).toContainText("Keep");
  await page.locator("#langBtn").click();
  await expect(page.locator("#keepBtn")).toContainText("要做");
});

test.describe("screenshots session (no recording)", () => {
  test.use({ fixture: SHOTS });
  test("frames show, no play-from-recording", async ({ page }) => {
    await ready(page);
    await expect(page.locator(".qi")).toHaveCount(2);
    await expect(page.locator(".shot.ready img")).toBeVisible();
    await expect(page.locator("#origBtn")).toHaveCount(0);
    await expect(page.locator(".th.vid")).toHaveCount(0);
  });
});

test.describe("v1 session (no uid, one item dropped in this review)", () => {
  test.use({ fixture: V1 });
  test("loads, shows the drop, saves without adding uids", async ({ page, session }) => {
    await ready(page);
    await expect(page.locator(".qi")).toHaveCount(4);
    await expect(page.locator(".qi.drop")).toHaveCount(1);
    const module = page.locator('.f input[data-k="module"]');
    await module.fill("checkout");
    await until(() => session.item("I-001")?.module === "checkout");
    const d = session.items();
    expect(d.schema).toBeUndefined();
    expect(d.items.some((i: { uid?: string }) => i.uid)).toBe(false);
  });
});

test("NEW: v2 fields — fix records shown as work state and history, uid never shown as a field", async ({ page }) => {
  newOnly();
  await ready(page);
  // v2 fix records read as K3 states: fixed → to verify, a draft reopened → new
  await page.locator(".qi").first().click();
  await expect(page.locator("#statePill .sring")).toHaveClass(/s-to_verify/);
  await expect(page.locator("#workRow")).toContainText("a1c3e5f");
  await expect(page.locator(".worklog li")).toHaveCount(2);
  await expect(page.locator('[data-k="uid"]')).toHaveCount(0);
  await expect(page.locator(".qi .sring")).toHaveCount(5);
  await page.locator(".qi").nth(4).click();
  await expect(page.locator("#statePill .sring")).toHaveClass(/s-new/);
  await expect(page.locator(".worklog a")).toHaveAttribute("href", "https://github.com/example/app/pull/7");
});

test.describe("item mode (the main window's detail pane)", () => {
  test.use({ query: "?mode=item&item=01KAQ6N2W8C3D4E5F6G7H8J9KP" });
  test("NEW: one item by uid, edits autosave, the host can switch items", async ({ page, session }) => {
    newOnly();
    await expect(page.locator(".insp .idrow > span").first()).toHaveText("I-003");
    await expect(page.locator("#queue")).toHaveCount(0);
    await expect(page.locator(".actions")).toHaveCount(0);
    const why = page.locator('textarea[data-k="why"]');
    await why.fill("名字太长记不住");
    await until(() => session.item("I-003")?.why === "名字太长记不住" && session.item("I-003")?._user?.why);
    await page.evaluate(() => (window as unknown as { blurtReview: { setItem(i: string): void } }).blurtReview.setItem("I-005"));
    await expect(page.locator(".insp .idrow > span").first()).toHaveText("I-005");
    // the review's own keys do nothing here; the state keys act on this item
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur?.());
    await page.keyboard.press("m");
    await page.keyboard.press("j");
    await expect(page.locator(".insp .idrow > span").first()).toHaveText("I-005");
    await page.keyboard.press("x");
    await until(() => session.item("I-005")?.state === "discarded");
  });
});

// ---------------------------------------------------------------- screenshots: 3 platforms × light / dark
const SHOT_DIR = join(process.cwd(), "screens");
for (const platform of ["mac", "win", "gnome"] as const)
  for (const theme of ["light", "dark"] as const)
    test.describe(`screenshot ${platform} ${theme}`, () => {
      test.use({ query: `?platform=${platform}&theme=${theme}` });
      test(`NEW: ${platform} ${theme}`, async ({ page }, info) => {
        newOnly();
        await expect(page.locator(".shot.ready img")).toBeVisible();
        await expect(page.locator("html")).toHaveAttribute("data-platform", platform);
        await expect(page.locator("html")).toHaveAttribute("data-theme", theme);
        await page.waitForTimeout(450); // slide-in
        mkdirSync(SHOT_DIR, { recursive: true });
        await page.screenshot({ path: join(SHOT_DIR, `${info.project.name}-${platform}-${theme}.png`) });
      });
    });
