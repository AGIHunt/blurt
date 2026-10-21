import { describe, expect, it } from "vitest";
import { checkCatalogs, COMMON, createI18n, localeFor, resolveLang, toLang } from "../src";

const cat = {
  en: { hi: "Hello, {name}", "items.count_one": "{n} item", "items.count_other": "{n} items", "only.en": "only" },
  "zh-Hans": { hi: "你好，{name}", "items.count_other": "{n} 条" },
};

describe("languages", () => {
  it("normalises picks and system languages (K10)", () => {
    expect(toLang("zh")).toBe("zh-Hans");
    expect(toLang("zh-Hans")).toBe("zh-Hans");
    expect(toLang("zh_TW")).toBe("zh-Hans");
    expect(toLang("en-GB")).toBe("en");
    expect(toLang("ja")).toBeNull();
    expect(resolveLang("auto", ["ja-JP", "zh-CN"])).toBe("zh-Hans");
    expect(resolveLang(null, ["de-DE"])).toBe("en");
    expect(resolveLang("en", ["zh-CN"])).toBe("en");
  });
  it("formats with the interface language and the system region", () => {
    expect(localeFor("en", "GB")).toBe("en-GB");
    expect(localeFor("zh-Hans", "SG")).toBe("zh-Hans-SG");
    expect(localeFor("en")).toBe("en");
  });
});

describe("messages", () => {
  const en = createI18n(cat, "en", { region: "US" });
  const zh = createI18n(cat, "zh", { region: "CN" });
  it("fills placeholders, falls back to English, then the key", () => {
    expect(en.t("hi", { name: "Ann" })).toBe("Hello, Ann");
    expect(zh.t("hi", { name: "安" })).toBe("你好，安");
    expect(zh.t("only.en")).toBe("only");
    expect(zh.t("nope.key")).toBe("nope.key");
    expect(en.t("hi")).toBe("Hello, {name}");
  });
  it("plurals use CLDR categories; zh needs only _other", () => {
    expect(en.plural("items.count", 1)).toBe("1 item");
    expect(en.plural("items.count", 1200)).toBe("1,200 items");
    expect(zh.plural("items.count", 1)).toBe("1 条");
  });
  it("merges the common words under every catalog", () => {
    expect(en.t("work.to_verify")).toBe("To verify");
    expect(zh.t("work.handed_off.session", { agent: "Claude Code" })).toBe("已交给 Claude Code");
    expect(zh.t("job.step.frames")).toBe("补截图");
  });
});

describe("formatting", () => {
  const en = createI18n(cat, "en", { region: "US" });
  const gb = createI18n(cat, "en", { region: "GB" });
  const zh = createI18n(cat, "zh-Hans", { region: "CN" });
  const at = "2026-10-22T10:15:00+08:00";
  it("dates follow the locale; epoch seconds and ISO strings both work", () => {
    expect(en.formatDate(at, { timeZone: "Asia/Shanghai", month: "numeric", day: "numeric", year: "numeric" })).toBe("10/22/2026");
    expect(gb.formatDate(at, { timeZone: "Asia/Shanghai", month: "numeric", day: "numeric", year: "numeric" })).toBe("22/10/2026");
    expect(zh.formatDate(Date.parse(at) / 1000, { timeZone: "Asia/Shanghai", month: "long", day: "numeric" })).toBe("10月22日");
    expect(en.formatDate("not a date")).toBe("");
  });
  it("durations: clock and words", () => {
    expect(en.formatDuration(65)).toBe("1:05");
    expect(en.formatDuration(3725)).toBe("1:02:05");
    expect(en.formatDuration(65, "short")).toMatch(/^1 min,? 5 sec$/);
    expect(zh.formatDuration(65, "short")).toMatch(/1\s*分钟\s*5\s*秒/);
  });
  it("relative times", () => {
    const now = Date.parse(at);
    expect(en.formatRelative(now - 3 * 60_000, now)).toBe("3 minutes ago");
    expect(en.formatRelative(now - 86400_000, now)).toBe("yesterday");
    expect(zh.formatRelative(now - 86400_000, now)).toBe("昨天");
    expect(en.formatRelative(now - 5_000, now)).toBe("now");
  });
  it("numbers and lists", () => {
    expect(en.formatNumber(12345.5)).toBe("12,345.5");
    expect(en.formatList(["BA-12", "BA-13", "BA-14"])).toBe("BA-12, BA-13, and BA-14");
    expect(zh.formatList(["BA-12", "BA-13"])).toBe("BA-12和BA-13");
  });
});

describe("catalog checks", () => {
  it("the common catalogs have the same keys and placeholders", () => {
    expect(checkCatalogs(COMMON.en, COMMON["zh-Hans"])).toEqual([]);
  });
  it("has every K4 job type and step", () => {
    for (const t of ["record", "snap", "voice", "process", "route", "agent"]) expect(COMMON.en).toHaveProperty(`job.type.${t}`);
    for (const s of ["capture", "finalize", "listen", "transcribe", "file", "prepare", "write", "frames", "route", "launch", "work", "finish"])
      expect(COMMON.en).toHaveProperty(`job.step.${s}`);
  });
  it("reports missing keys, plural forms without _other and placeholder drift", () => {
    expect(checkCatalogs(cat.en, cat["zh-Hans"])).toEqual(["only.en: missing in zh-Hans"]);
    expect(checkCatalogs({ a: "{x}" }, { a: "{y}" })).toEqual(["a: placeholders {x} vs {y}"]);
    expect(checkCatalogs({ "b_one": "one" }, { "b_one": "一" })).toEqual(["b_one: no _other form in en", "b_one: no _other form in zh-Hans"]);
  });
});
