// A project's one look (the Mac's ProjectLook): the island's switcher, the note bubble's chip and list.

/** The Mac's eight hues (their dark-appearance values). */
const PALETTE = ['#0a84ff', '#ff9f0a', '#30d158', '#bf5af2', '#ff375f', '#5e5ce6', '#ac8e68', '#ffd60a'];

/** A project's colour (ProjectLook.color): FNV-1a of its id into the palette. */
export function projectColor(id: string): string {
  let h = 0x811c9dc5;
  for (const b of new TextEncoder().encode(id)) h = Math.imul(h ^ b, 16777619) >>> 0;
  return PALETTE[h % PALETTE.length];
}
