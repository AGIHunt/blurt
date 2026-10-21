/* review.html: the page review.py serves, the macOS app loads from blurt-app://ui/index.html and the Tauri app embeds.
   URL parameters: mode=review|item, item=<id|uid>, platform=mac|win|gnome, theme=auto|light|dark, host=browser|macos|tauri,
   session=<abs dir> (tauri), lang=en|zh. */
import "@blurt/ui/tokens.css";
import "@blurt/ui/base.css";
import "./styles/review.css";
import { isPlatform, type ThemePref } from "@blurt/ui";
import { detectHost } from "./hosts";
import { mountReview } from "./mount";

const q = new URLSearchParams(location.search);
const theme = q.get("theme");
const platform = q.get("platform");
const handle = mountReview(document.getElementById("root")!, detectHost(window), {
  mode: q.get("mode") === "item" ? "item" : "review",
  itemId: q.get("item") ?? undefined,
  platform: isPlatform(platform) ? platform : undefined,
  theme: theme === "light" || theme === "dark" || theme === "auto" ? (theme as ThemePref) : undefined,
  lang: q.get("lang") ?? undefined,
});
// for hosts and tests: window.blurtReview.setItem("I-003") etc.
(window as unknown as { blurtReview: typeof handle }).blurtReview = handle;
