// C6: every Enter handler first checks e.isComposing || keyCode === 229, and ignores Enter within 50 ms after
// compositionend (WebKit sends the candidate-confirming Enter with isComposing === false, bugs.webkit.org/165004).

let lastCompositionEnd = -Infinity;

if (typeof document !== 'undefined') {
  document.addEventListener('compositionend', () => (lastCompositionEnd = performance.now()), true);
}

type KeyLike = { isComposing?: boolean; keyCode?: number; nativeEvent?: { isComposing?: boolean; keyCode?: number } };

export function isImeKey(e: KeyLike, now: number = performance.now()): boolean {
  const n = e.nativeEvent ?? e;
  return !!n.isComposing || n.keyCode === 229 || now - lastCompositionEnd < 50;
}

/** for tests */
export function _setCompositionEnd(t: number) {
  lastCompositionEnd = t;
}
