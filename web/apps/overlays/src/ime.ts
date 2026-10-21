// Enter while an input method is composing must not submit (docs/design/desktop-app.md §5 C6): check
// isComposing / keyCode 229, and ignore Enter for 50 ms after compositionend (WebKit fires keydown after it).

export class EnterGuard {
  private composedAt = -Infinity;

  constructor(private now: () => number = () => performance.now()) {}

  compositionEnd() {
    this.composedAt = this.now();
  }

  /** True when this keydown is a real Enter (submit). */
  isSubmit(e: { key: string; isComposing?: boolean; keyCode?: number; shiftKey?: boolean }): boolean {
    if (e.key !== 'Enter' || e.shiftKey) return false;
    if (e.isComposing || e.keyCode === 229) return false;
    return this.now() - this.composedAt > 50;
  }

  attach(el: HTMLElement) {
    el.addEventListener('compositionend', () => this.compositionEnd());
    return this;
  }
}
