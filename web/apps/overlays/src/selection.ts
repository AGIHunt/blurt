// The hanging cards' multi-select (docs/design/drag-drop.md §2; the Mac's HangingCards selection), as pure rules the
// island page drives with its clock:
//  • Ctrl-click toggles a card; Shift-click adds the run from the last card clicked (the anchor) to this one, oldest
//    first — the order a run of steps happened in, not the row's newest-first order.
//  • The order is the order picked: each picked card shows its place (1, 2, 3), and it is the order the cards leave in
//    (a drag, a copy, the numbered notes pasted after a chat drop). A reviewer caught the row's order sending an
//    agent the steps backwards.
//  • The clipboard isn't rewritten on every click: the selection is copied once, COPY_AFTER_MS after the last change
//    (a clipboard manager used to collect one entry per click).
//  • Picking 1, 3, 5, 7 along a long row runs into the cards going up: the selection outlives that by KEEP_MS.
// No DOM, no timers: the page asks `copyDue(now)` / `expired(now)` from its own timers and frame loop.

export const COPY_AFTER_MS = 600;
export const KEEP_MS = 60_000;

export class CardSelection {
  private picked: string[] = [];
  private anchor: string | null = null;
  /** when the selection last changed and hasn't been copied since (0: nothing to copy) */
  private changedAt = 0;
  /** when the cards went up with a selection (0: they are down, or nothing is picked) */
  private upSince = 0;

  get size(): number {
    return this.picked.length;
  }

  has(key: string): boolean {
    return this.picked.includes(key);
  }

  /** The picked cards' keys, in the order picked. */
  order(): string[] {
    return [...this.picked];
  }

  /** A card's place in the selection (1-based); 0 when it isn't picked. */
  badge(key: string): number {
    return this.picked.indexOf(key) + 1;
  }

  /** Ctrl-click: into the selection (at the end) or out of it. The card becomes the anchor of a later Shift-click. */
  toggle(key: string, now: number): void {
    const i = this.picked.indexOf(key);
    if (i >= 0) this.picked.splice(i, 1);
    else this.picked.push(key);
    this.anchor = key;
    this.touch(now);
  }

  /** Shift-click: every card from the anchor to `key` (both in) joins, oldest first, after the ones already picked.
   *  `row`: the hanging cards' keys, oldest first. No anchor (or it left the row): `key` alone joins. */
  extend(key: string, row: string[], now: number): void {
    const to = row.indexOf(key);
    if (to < 0) return;
    const from = this.anchor ? row.indexOf(this.anchor) : -1;
    const run = from < 0 ? [key] : row.slice(Math.min(from, to), Math.max(from, to) + 1);
    for (const k of run) if (!this.picked.includes(k)) this.picked.push(k);
    this.anchor = key;
    this.touch(now);
  }

  /** Ctrl+A: every card on the row joins, oldest first, after the ones already picked (their order stays). */
  pickAll(row: string[], now: number): void {
    for (const k of row) if (!this.picked.includes(k)) this.picked.push(k);
    if (row.length) this.anchor = row[row.length - 1];
    this.touch(now);
  }

  /** The keyboard's Space on a card: in or out, as a Ctrl-click. Shift+←/→: the card joins (never leaves). */
  add(key: string, now: number): void {
    if (this.picked.includes(key)) return;
    this.picked.push(key);
    this.anchor = key;
    this.touch(now);
  }

  /** Cards that left the row (filed, deleted, dragged out) leave the selection; the order of the rest stays. */
  retain(hanging: Iterable<string>): boolean {
    const keep = new Set(hanging);
    const before = this.picked.length;
    this.picked = this.picked.filter((k) => keep.has(k));
    if (this.anchor && !keep.has(this.anchor)) this.anchor = null;
    if (!this.picked.length) this.changedAt = this.upSince = 0;
    return this.picked.length !== before;
  }

  clear(): void {
    this.picked = [];
    this.anchor = null;
    this.changedAt = this.upSince = 0;
  }

  /** The cards a gesture on `key` acts on: the whole selection (in its order) when `key` is in it, else `key` alone. */
  group(key: string): string[] {
    return this.has(key) ? this.order() : [key];
  }

  /** The selection should be copied now: something changed COPY_AFTER_MS ago or more and hasn't been copied. */
  copyDue(now: number): boolean {
    return this.picked.length > 0 && this.changedAt > 0 && now - this.changedAt >= COPY_AFTER_MS;
  }

  copied(): void {
    this.changedAt = 0;
  }

  /** The cards went up (true) or came down (false). Returns true when this starts the KEEP_MS countdown. */
  cardsUp(up: boolean, now: number): boolean {
    if (!up) {
      this.upSince = 0;
      return false;
    }
    if (this.upSince || !this.picked.length) return false;
    this.upSince = now;
    return true;
  }

  /** The cards have been up KEEP_MS with the selection: it ends. */
  expired(now: number): boolean {
    return this.upSince > 0 && now - this.upSince >= KEEP_MS;
  }

  private touch(now: number) {
    this.changedAt = this.picked.length ? Math.max(1, now) : 0;
    if (!this.picked.length) this.upSince = 0;
  }
}
