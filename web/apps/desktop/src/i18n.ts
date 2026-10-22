// The main window's strings (K10): this package's catalogs over @blurt/i18n's common words. The language comes
// from the app (`app_status.lang`, which follows config `lang` / the system); dates and numbers use its locale.
import { createI18n, resolveLang, type I18n, type Params } from '@blurt/i18n';
import EN from './locales/en.json';
import ZH from './locales/zh-Hans.json';

export const CATALOGS = { en: EN, 'zh-Hans': ZH };

let current: I18n = createI18n(CATALOGS, resolveLang(null));

export function setLang(lang: string | null | undefined) {
  current = createI18n(CATALOGS, resolveLang(lang));
  if (typeof document !== 'undefined') document.documentElement.lang = current.lang;
  return current;
}

export const i18n = () => current;
export const t = (key: string, p?: Params) => current.t(key, p);
export const plural = (key: string, n: number, p?: Params) => current.plural(key, n, p);
/** "3 minutes ago" from epoch seconds or ISO */
export const ago = (v: number | string | null | undefined) => (v == null || v === '' ? '' : current.formatRelative(v));

/** A command error in the UI language: the CLI's machine code at its end (`… [needs_project]`) → `error.<code>`. */
export function errText(e: unknown): string {
  const code = String(e).match(/\[([a-z_]+)\]\s*$/)?.[1] ?? 'unknown';
  return current.has(`error.${code}`) ? current.t(`error.${code}`) : current.t('error.unknown');
}
