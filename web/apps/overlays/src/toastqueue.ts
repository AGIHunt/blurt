// Lines that arrive while the take's ✓ moment owns the ears (island.ts 'toast' op): one queue in arrival order, a newer
// line replacing a waiting one with the same key, so "Organizing…" never comes back after its own answer.
export interface Keyed {
  key?: string;
}

/** Add `line` to the lines waiting for the moment to end. */
export function queueLine<T extends Keyed>(waiting: T[], line: T): void {
  const i = line.key ? waiting.findIndex((w) => w.key === line.key) : -1;
  if (i >= 0) waiting[i] = line;
  else waiting.push(line);
}

/** A line shown after the moment supersedes one of its key still waiting for it. */
export function dropSuperseded<T extends Keyed>(waiting: T[], line: T): void {
  if (!line.key) return;
  const i = waiting.findIndex((w) => w.key === line.key);
  if (i >= 0) waiting.splice(i, 1);
}
