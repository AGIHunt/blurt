import type { BlurtHost } from "../host";
import { createBrowserHost } from "./browser";
import { createMacosHost } from "./macos";
import { createTauriHost, isTauri } from "./tauri";

export { createBrowserHost, createMacosHost, createTauriHost, isTauri };

/** Which host is showing the page:
    - blurt-app://… (or ?host=macos)                    → macos (WKURLSchemeHandler + message bridge)
    - Tauri IPC present (or ?host=tauri)                → tauri, session from ?session=
    - anything else (review.py, incl. the app's current review window over http) → browser */
export function detectHost(win: Window = window): BlurtHost {
  const q = new URLSearchParams(win.location.search);
  const want = q.get("host");
  const w = win as Window & { blurtHostInfo?: { host?: string; session?: string } };
  if (want === "macos" || win.location.protocol === "blurt-app:" || w.blurtHostInfo?.host === "macos") return createMacosHost(win as never);
  if (want === "tauri" || (want !== "browser" && isTauri(win))) {
    const session = q.get("session") || w.blurtHostInfo?.session || "";
    return createTauriHost(session, win as never);
  }
  return createBrowserHost({ win });
}
