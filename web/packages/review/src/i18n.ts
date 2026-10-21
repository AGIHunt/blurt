/* The canvas's strings (K10): src/locales/{en,zh-Hans}.json over @blurt/i18n's common words. */
import { createI18n, type I18n } from "@blurt/i18n";
import en from "./locales/en.json";
import zh from "./locales/zh-Hans.json";

export const CATALOGS = { en, "zh-Hans": zh };
export const makeI18n = (lang: string): I18n => createI18n(CATALOGS, lang);
export const SEVERITIES = ["high", "medium", "low"] as const;
export const TYPES = ["bug", "ui", "ux", "copy", "perf"] as const;
export type { I18n, Lang } from "@blurt/i18n";
