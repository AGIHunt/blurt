/* IME Enter guard (C6). Chinese / Japanese input methods use Enter to commit a candidate; that Enter must never
   submit anything. WebKit reports the committing keydown with isComposing === false (bug 165004), but with
   keyCode 229, and some IMEs send it right after compositionend — so: ignore Enter while composing, with keyCode 229,
   or within 50 ms after a composition ended. */

let lastCompositionEnd = -Infinity;
let installed = false;

export const IME_GRACE_MS = 50;

export function installImeGuard(doc: Document = document) {
  if (installed) return;
  installed = true;
  doc.addEventListener("compositionend", () => (lastCompositionEnd = performance.now()), true);
}

type KeyLike = { key?: string; keyCode?: number; isComposing?: boolean; nativeEvent?: KeyboardEvent };

/** true when this keydown belongs to an input method and must not trigger anything */
export function imeBusy(e: KeyLike): boolean {
  const n = (e.nativeEvent ?? e) as KeyLike;
  if (n.isComposing || n.keyCode === 229) return true;
  return performance.now() - lastCompositionEnd < IME_GRACE_MS;
}

/** a real Enter press: use this for every Enter shortcut */
export function isEnter(e: KeyLike): boolean {
  const n = (e.nativeEvent ?? e) as KeyLike;
  return n.key === "Enter" && !imeBusy(e);
}

/** for tests */
export function _resetImeGuard() {
  lastCompositionEnd = -Infinity;
}
