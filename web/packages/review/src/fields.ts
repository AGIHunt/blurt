/* Labels for the fields an agent adds beyond the lens ("author", "suspected_cause", "rootCause"…): a localized label
   (`field.<snake_case>` in the catalogs) for the common ones, and a humanised key for the rest — never a raw
   snake_case / camelCase key in the UI. */
import type { I18n } from "@blurt/i18n";

/** "suspectedCause" / "Suspected-Cause" / "suspected cause" → "suspected_cause" */
export function normKey(k: string): string {
  return words(k).join("_");
}

function words(k: string): string[] {
  return String(k)
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2") // camelCase
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2") // HTTPServer → HTTP Server
    .split(/[\s_\-.:/]+/)
    .filter(Boolean)
    .map((w) => w.toLowerCase());
}

const ACRONYMS: Record<string, string> = {
  url: "URL", api: "API", id: "ID", os: "OS", ui: "UI", ux: "UX", sdk: "SDK", http: "HTTP", https: "HTTPS", ios: "iOS",
  css: "CSS", html: "HTML", js: "JS", pr: "PR", qa: "QA", ci: "CI", db: "DB", sql: "SQL", ip: "IP", cpu: "CPU", gpu: "GPU",
};

/** "suspected_cause" → "Suspected cause", "apiURL" → "API URL", "app-version" → "App version" */
export function humanizeKey(k: string): string {
  const ws = words(k).map((w) => ACRONYMS[w] ?? w);
  if (!ws.length) return String(k);
  const first = ws[0];
  ws[0] = first === first.toLowerCase() ? first[0].toUpperCase() + first.slice(1) : first;
  return ws.join(" ");
}

/** The label a field shows: the localized one when the catalogs have it, else the humanised key. */
export function fieldLabel(k: string, i18n: I18n): string {
  const key = "field." + normKey(k);
  return i18n.has(key) ? i18n.t(key) : humanizeKey(k);
}
