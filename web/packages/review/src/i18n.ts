/* The canvas's strings (K10): src/locales/{en,zh-Hans}.json over @blurt/i18n's common words. */
import { createI18n, type I18n } from "@blurt/i18n";
import en from "./locales/en.json";
import zh from "./locales/zh-Hans.json";

export const CATALOGS = { en, "zh-Hans": zh };
/** The host's clock ("h23" on a Mac set to 24-hour time: window.blurtHostInfo.clock), so the page's times match the
    app's own lists. */
const hostClock = (): "h12" | "h23" | undefined => {
  const c = (globalThis as { blurtHostInfo?: { clock?: string } }).blurtHostInfo?.clock;
  return c === "h12" || c === "h23" ? c : undefined;
};
export const makeI18n = (lang: string): I18n => createI18n(CATALOGS, lang, { hourCycle: hostClock() });
export const SEVERITIES = ["high", "medium", "low"] as const;
export const TYPES = ["bug", "ui", "ux", "copy", "perf"] as const;
export type { I18n, Lang } from "@blurt/i18n";
