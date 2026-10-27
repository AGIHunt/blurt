/* review.html: the page review.py serves, the macOS main window loads from blurt-app://ui/index.html and the Tauri app
   embeds. URL parameters: mode=review|item, item=<uid|id>, platform=mac|win|gnome, theme=auto|light|dark,
   host=browser|macos|tauri, project=<id> | session=<abs dir> (app hosts), lang=en|zh|zh-Hans, embedded=1|0
   (default: 1 in the macOS app, 0 elsewhere). */
import "@blurt/ui/tokens.css";
import "@blurt/ui/base.css";
import "./styles/review.css";
import { isPlatform, type ThemePref } from "@blurt/ui";
import { detectHost } from "./hosts";
import { mountReview } from "./mount";

const q = new URLSearchParams(location.search);
const theme = q.get("theme");
const platform = q.get("platform");
const host = detectHost(window);
const embedded = q.get("embedded");
const handle = mountReview(document.getElementById("root")!, host, {
  mode: q.get("mode") === "item" ? "item" : "review",
  itemId: q.get("item") ?? undefined,
  platform: isPlatform(platform) ? platform : undefined,
  theme: theme === "light" || theme === "dark" || theme === "auto" ? (theme as ThemePref) : undefined,
  lang: q.get("lang") ?? undefined,
  embedded: embedded ? embedded === "1" : host.host === "macos",
});
// for hosts and tests: window.blurtReview.setItem("BA-12"), .setLang("zh-Hans") …
(window as unknown as { blurtReview: typeof handle }).blurtReview = handle;
