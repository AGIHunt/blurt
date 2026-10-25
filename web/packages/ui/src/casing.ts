/* Button and menu labels in English are macOS Title Case ("Mark as Done", "Copy Full Text"); the shared catalogs keep
   them in sentence case, because the same words also run inside sentences. Like the Mac app's Look.menuCase: every
   word capitalised but the short ones in the middle; text with Chinese in it is left as it is. */
const SMALL = new Set(["a", "an", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to"]);

export function menuCase(s: string): string {
  if (/[　-鿿＀-￯]/.test(s)) return s;
  return s
    .split(" ")
    .map((w, k) => (k > 0 && SMALL.has(w.toLowerCase()) ? w : w.charAt(0).toUpperCase() + w.slice(1)))
    .join(" ");
}
