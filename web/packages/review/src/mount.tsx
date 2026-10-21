import { createRoot } from "react-dom/client";
import { applyPlatform, applyTheme, detectPlatform, setSystemAccent, type ThemePref } from "@blurt/ui";
import type { BlurtHost, MountOptions, ReviewHandle } from "./host";
import { installImeGuard } from "./ime";
import { ReviewStore } from "./store";
import { App } from "./ui/App";

const THEME_KEY = "blurt.theme";
const readPick = (): ThemePref | null => {
  try {
    const v = localStorage.getItem(THEME_KEY);
    return v === "light" || v === "dark" ? v : null;
  } catch {
    return null;
  }
};

/** mountReview(el, host, {mode, itemId, platform, theme}) — C6. Theme and platform go on <html> (the canvas is a
    whole page in every host). Browser page: the user's pick from the theme button wins, else `theme`, else the
    system; inside an app window the theme always follows the system unless the host passes one. */
export function mountReview(el: HTMLElement, host: BlurtHost, opts: MountOptions = {}): ReviewHandle & { store: ReviewStore } {
  const html = document.documentElement;
  applyPlatform(opts.platform ?? detectPlatform(), html);
  const pick = host.inApp ? null : readPick();
  const theme = applyTheme(opts.theme && opts.theme !== "auto" ? opts.theme : pick ?? opts.theme ?? "auto", html);
  const accent = (window as { blurtHostInfo?: { accent?: string } }).blurtHostInfo?.accent;
  if (accent) setSystemAccent(accent, html);
  if (host.inApp) html.classList.add("in-app");
  if (opts.mode === "item") html.classList.add("mode-item");
  installImeGuard(document);

  const store = new ReviewStore(host, opts);
  const toggleTheme = () => {
    const next = theme.theme === "light" ? "dark" : "light";
    try {
      localStorage.setItem(THEME_KEY, next);
    } catch {
      /* private mode */
    }
    theme.set(next);
  };
  const root = createRoot(el);
  root.render(<App store={store} onTheme={toggleTheme} />);
  void store.load();
  // hosts can push a system accent / theme later (e.g. macOS: NSApp.effectiveAppearance / accent changes)
  const api = window as unknown as { __blurtSetAccent?: (c: string | null) => void; __blurtSetTheme?: (t: ThemePref) => void };
  api.__blurtSetAccent = (c) => setSystemAccent(c, html);
  api.__blurtSetTheme = (t) => theme.set(t);
  return {
    store,
    setItem: (id) => store.setItem(id),
    setTheme: (t) => theme.set(t),
    setPlatform: (p) => applyPlatform(p, html),
    unmount: () => {
      store.dispose();
      theme.dispose();
      root.unmount();
    },
  };
}
