// After `vite build`: copy dist/index.html to skills/blurt/scripts/review.html (what review.py serves, unchanged)
// and fail if it outgrows the budget (design doc §6 WP3: ≤ 410 KB).
import { copyFileSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const src = resolve(here, "../dist/index.html");
const dest = resolve(here, "../../../../skills/blurt/scripts/review.html");
const LIMIT = 410 * 1024;

const size = statSync(src).size;
copyFileSync(src, dest);
const kb = (size / 1024).toFixed(1);
if (size > LIMIT) {
  console.error(`review.html is ${kb} KB, over the ${LIMIT / 1024} KB budget`);
  process.exit(1);
}
console.log(`review.html ${kb} KB → ${dest}`);
