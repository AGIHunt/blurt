/* @blurt/i18n — localization for Blurt's web surfaces (contract K10). No runtime dependencies: everything is Intl.

   Catalogs are flat JSON: dotted lower-case keys → messages with {name} placeholders. Plurals use CLDR category
   suffixes: `items.count_one`, `items.count_other` (plus _zero / _two / _few / _many where a language needs them;
   `_other` is always required). zh-Hans only needs `_other`. Every package keeps its own `src/locales/{en,zh-Hans}.json`;
   the words every platform shares (kind / state / action / inbox / session / project / handoff / job) live in `src/common/` and
   are merged under each package's catalog. Missing keys fall back to English, then to the key itself. */
import COMMON_EN from "./common/en.json";
import COMMON_ZH from "./common/zh-Hans.json";

export type Lang = "en" | "zh-Hans";
export const LANGS: readonly Lang[] = ["en", "zh-Hans"];
export type Catalog = Record<string, string>;
export type Catalogs = { en: Catalog } & Partial<Record<Lang, Catalog>>;
export type Params = Record<string, string | number | null | undefined>;
export type DateLike = Date | number | string;
export type DateStyle = "date" | "time" | "datetime" | "short" | "day";
export type DurationStyle = "clock" | "short" | "narrow" | "long";

export const COMMON: Record<Lang, Catalog> = { en: COMMON_EN, "zh-Hans": COMMON_ZH };

/** "zh" | "zh-Hans" | "zh-CN" | "zh_TW" → zh-Hans; "en-GB" → en; anything else → null (not a UI language we ship). */
export function toLang(s: string | null | undefined): Lang | null {
  const v = String(s ?? "").trim().replace(/_/g, "-").toLowerCase();
  if (v === "zh" || v.startsWith("zh-")) return "zh-Hans";
  if (v === "en" || v.startsWith("en-")) return "en";
  return null;
}

/** The UI language: an explicit pick ("en" | "zh" | "zh-Hans"), else the first system language we ship, else English.
    "auto", "" and unknown values follow the system (K10 `lang: auto`). */
export function resolveLang(pick?: string | null, system: readonly string[] = systemLanguages()): Lang {
  return toLang(pick) ?? (system.map(toLang).find((l): l is Lang => !!l) ?? "en");
}

export function systemLanguages(): string[] {
  if (typeof navigator === "undefined") return [];
  const n = navigator as Navigator & { languages?: readonly string[] };
  return [...(n.languages?.length ? n.languages : [n.language].filter(Boolean))];
}

/** The region of the user's first system language that has one ("en-GB" → "GB", "zh-Hans-CN" → "CN"). */
export function systemRegion(system: readonly string[] = systemLanguages()): string | undefined {
  for (const s of system) {
    try {
      const r = new Intl.Locale(s).maximize().region;
      if (r) return r;
    } catch {
      /* not a BCP 47 tag */
    }
  }
  return undefined;
}

/** Interface language + system region (K10): en + GB → "en-GB" (dates read 22/10/2026), zh-Hans + SG → "zh-Hans-SG". */
export function localeFor(lang: Lang, region?: string): string {
  if (!region) return lang === "en" ? "en" : "zh-Hans-CN";
  try {
    return Intl.getCanonicalLocales(`${lang}-${region}`)[0];
  } catch {
    return lang;
  }
}

const PLURAL = /_(zero|one|two|few|many|other)$/;
const PH = /\{(\w+)\}/g;

export interface I18n {
  readonly lang: Lang;
  /** BCP 47 locale for Intl: the interface language with the system's region */
  readonly locale: string;
  t(key: string, params?: Params): string;
  /** `key_<category>` for n (Intl.PluralRules), falling back to `key_other`; {n} is n, formatted */
  plural(key: string, n: number, params?: Params): string;
  has(key: string): boolean;
  /** "date" 22 Oct 2026 · "time" 10:15 · "datetime" (default) 22 Oct, 10:15 · "short" 22 Oct · "day" Thursday */
  formatDate(v: DateLike, style?: DateStyle | Intl.DateTimeFormatOptions): string;
  formatNumber(n: number, opts?: Intl.NumberFormatOptions): string;
  /** seconds → "clock" 1:05 / 1:02:05, or words: "short" 1 min 5 sec, "narrow" 1m 5s, "long" 1 minute, 5 seconds */
  formatDuration(seconds: number, style?: DurationStyle): string;
  /** "3 minutes ago", "yesterday", "in 2 hours" */
  /** "2 minutes ago"; style "short": "2 min. ago" / "2分钟前", always numeric (the Mac app's RelativeDateTimeFormatter .short) */
  formatRelative(v: DateLike, now?: DateLike, style?: "long" | "short"): string;
  formatList(items: string[], type?: "conjunction" | "disjunction" | "unit"): string;
}

export interface I18nOptions {
  /** region for formatting (default: the system's); pass "" for none */
  region?: string;
}

/** Epoch numbers below 1e11 are seconds (v2 files and `_user`), larger ones milliseconds; strings are ISO 8601. */
export function toDate(v: DateLike): Date {
  if (v instanceof Date) return v;
  if (typeof v === "number") return new Date(v < 1e11 ? v * 1000 : v);
  return new Date(v);
}

export function createI18n(catalogs: Catalogs, lang: Lang | string, opts: I18nOptions = {}): I18n {
  const L: Lang = toLang(lang) ?? "en";
  const region = opts.region === undefined ? systemRegion() : opts.region || undefined;
  const locale = localeFor(L, region);
  const chain = [catalogs[L], COMMON[L], catalogs.en, COMMON.en].filter((c): c is Catalog => !!c);
  const nf = new Intl.NumberFormat(locale);
  const pr = new Intl.PluralRules(locale);
  const lookup = (key: string): string | undefined => {
    for (const c of chain) if (key in c) return c[key];
    return undefined;
  };
  const fill = (msg: string, params?: Params) =>
    params
      ? msg.replace(PH, (m, name: string) => {
          const v = params[name];
          return v == null ? m : typeof v === "number" ? nf.format(v) : String(v);
        })
      : msg;

  const cache = new Map<string, Intl.DateTimeFormat>();
  const dtf = (o: Intl.DateTimeFormatOptions) => {
    const k = JSON.stringify(o);
    let f = cache.get(k);
    if (!f) cache.set(k, (f = new Intl.DateTimeFormat(locale, o)));
    return f;
  };
  const DATE_STYLES: Record<DateStyle, Intl.DateTimeFormatOptions> = {
    date: { year: "numeric", month: "short", day: "numeric" },
    time: { hour: "numeric", minute: "2-digit" },
    datetime: { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" },
    short: { month: "short", day: "numeric" },
    day: { weekday: "long" },
  };
  const two = new Intl.NumberFormat(locale, { minimumIntegerDigits: 2, useGrouping: false });
  const one = new Intl.NumberFormat(locale, { useGrouping: false });

  const i18n: I18n = {
    lang: L,
    locale,
    t: (key, params) => fill(lookup(key) ?? key, params),
    plural(key, n, params) {
      const msg = lookup(`${key}_${pr.select(n)}`) ?? lookup(`${key}_other`) ?? key;
      return fill(msg, { n, ...params });
    },
    has: (key) => lookup(key) !== undefined,
    formatDate(v, style = "datetime") {
      const d = toDate(v);
      if (isNaN(d.getTime())) return "";
      return dtf(typeof style === "string" ? DATE_STYLES[style] : style).format(d);
    },
    formatNumber: (n, o) => (o ? new Intl.NumberFormat(locale, o) : nf).format(n),
    formatDuration(seconds, style = "clock") {
      // a clock floors like a media player's (0.9 s is still 0:00); words round
      const raw = Math.max(0, Number(seconds) || 0);
      const s = style === "clock" ? Math.floor(raw) : Math.round(raw);
      const h = Math.floor(s / 3600);
      const m = Math.floor((s % 3600) / 60);
      const r = s % 60;
      if (style === "clock") return h ? `${one.format(h)}:${two.format(m)}:${two.format(r)}` : `${one.format(m)}:${two.format(r)}`;
      const DF = (Intl as unknown as { DurationFormat?: new (l: string, o: object) => { format(d: object): string } }).DurationFormat;
      const parts = { hours: h, minutes: m, seconds: r };
      if (DF) {
        try {
          return new DF(locale, { style }).format(s ? parts : { seconds: 0 });
        } catch {
          /* fall through */
        }
      }
      const display = style === "long" ? "long" : style === "narrow" ? "narrow" : "short";
      const units: [number, string][] = [[h, "hour"], [m, "minute"], [r, "second"]];
      const shown = units.filter(([v]) => v > 0);
      const words = (shown.length ? shown : [[0, "second"] as [number, string]]).map(([v, unit]) =>
        new Intl.NumberFormat(locale, { style: "unit", unit, unitDisplay: display }).format(v),
      );
      return new Intl.ListFormat(locale, { type: "unit", style: display === "long" ? "long" : display }).format(words);
    },
    formatRelative(v, now = Date.now(), style = "long") {
      const d = toDate(v).getTime();
      if (isNaN(d)) return "";
      const diff = (d - toDate(now).getTime()) / 1000;
      const a = Math.abs(diff);
      const rtf = new Intl.RelativeTimeFormat(locale, style === "short" ? { numeric: "always", style: "short" } : { numeric: "auto" });
      if (a < 45) return rtf.format(0, "second");
      if (a < 45 * 60) return rtf.format(Math.round(diff / 60), "minute");
      if (a < 22 * 3600) return rtf.format(Math.round(diff / 3600), "hour");
      if (a < 26 * 86400) return rtf.format(Math.round(diff / 86400), "day");
      if (a < 320 * 86400) return rtf.format(Math.round(diff / (30.44 * 86400)), "month");
      return rtf.format(Math.round(diff / (365.25 * 86400)), "year");
    },
    formatList: (items, type = "conjunction") => new Intl.ListFormat(locale, { type }).format(items),
  };
  return i18n;
}

/** Problems between two catalogs of the same package: keys missing on either side (plural forms count as one key,
    and each plural key needs `_other`), and placeholders that differ. Every package's vitest runs this (K10). */
export function checkCatalogs(a: Catalog, b: Catalog, names: [string, string] = ["en", "zh-Hans"]): string[] {
  const base = (c: Catalog) => {
    const m = new Map<string, Set<string>>();
    for (const [k, v] of Object.entries(c)) {
      const bk = k.replace(PLURAL, "");
      const ph = m.get(bk) ?? new Set<string>();
      for (const [, p] of v.matchAll(PH)) ph.add(p);
      m.set(bk, ph);
    }
    return m;
  };
  const out: string[] = [];
  const A = base(a);
  const B = base(b);
  for (const [k] of A) if (!B.has(k)) out.push(`${k}: missing in ${names[1]}`);
  for (const [k] of B) if (!A.has(k)) out.push(`${k}: missing in ${names[0]}`);
  for (const [k, pa] of A) {
    const pb = B.get(k);
    if (!pb) continue;
    const x = [...pa].sort().join(",");
    const y = [...pb].sort().join(",");
    if (x !== y) out.push(`${k}: placeholders {${x}} vs {${y}}`);
  }
  for (const [name, c] of [[names[0], a], [names[1], b]] as const)
    for (const k of Object.keys(c))
      if (PLURAL.test(k) && !(k.replace(PLURAL, "_other") in c)) out.push(`${k}: no _other form in ${name}`);
  return [...new Set(out)];
}
