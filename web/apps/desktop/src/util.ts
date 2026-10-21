/** A keydown → the config grammar ("ctrl+opt+shift+cmd+KEY"), or null while only modifiers are down. */
export function comboFromEvent(e: { ctrlKey: boolean; altKey: boolean; shiftKey: boolean; metaKey: boolean; code: string; key: string }): string | null {
  const c = e.code;
  let key: string | null = null;
  if (/^Key[A-Z]$/.test(c)) key = c.slice(3);
  else if (/^Digit\d$/.test(c)) key = c.slice(5);
  else if (/^F\d{1,2}$/.test(c)) key = c;
  else
    key = ({
      Space: 'Space', Tab: 'Tab', Enter: 'Return', ArrowLeft: 'Left', ArrowRight: 'Right', ArrowUp: 'Up', ArrowDown: 'Down',
      Minus: '-', Equal: '=', BracketLeft: '[', BracketRight: ']', Semicolon: ';', Quote: "'", Comma: ',', Period: '.',
      Slash: '/', Backslash: '\\', Backquote: '`',
    } as Record<string, string>)[c] ?? null;
  if (!key) return null;
  const mods = [e.ctrlKey && 'ctrl', e.altKey && 'opt', e.shiftKey && 'shift', e.metaKey && 'cmd'].filter(Boolean) as string[];
  return [...mods, key].join('+');
}

/** "opt+shift+R" → "Alt+Shift+R" (Windows/Linux names). */
export function comboLabel(spec: string, platform: 'win' | 'gnome' | 'mac' = 'win'): string {
  if (!spec || spec === 'off') return '';
  const names: Record<string, string> = { ctrl: 'Ctrl', opt: 'Alt', shift: 'Shift', cmd: platform === 'win' ? 'Win' : 'Super' };
  if (platform === 'mac') {
    const g: Record<string, string> = { ctrl: '⌃', opt: '⌥', shift: '⇧', cmd: '⌘' };
    return spec.split('+').map((p) => g[p] ?? p).join('');
  }
  return spec.split('+').map((p) => names[p] ?? p).join('+');
}

export function debounce<A extends unknown[]>(fn: (...a: A) => void, ms: number) {
  let h: ReturnType<typeof setTimeout> | undefined;
  return (...a: A) => {
    clearTimeout(h);
    h = setTimeout(() => fn(...a), ms);
  };
}

export function inField(t: EventTarget | null): boolean {
  const el = t as HTMLElement | null;
  return !!el?.closest?.('input, textarea, select, [contenteditable="true"], .xterm');
}

/** Selection with Shift-ranges over the list order. */
export function nextSelection(order: string[], cur: Set<string>, anchor: string | null, uid: string, how: 'one' | 'toggle' | 'range'): Set<string> {
  if (how === 'one') return new Set([uid]);
  if (how === 'toggle') {
    const s = new Set(cur);
    if (s.has(uid)) s.delete(uid);
    else s.add(uid);
    return s;
  }
  const a = anchor ? order.indexOf(anchor) : -1;
  const b = order.indexOf(uid);
  if (a < 0 || b < 0) return new Set([uid]);
  const [lo, hi] = a < b ? [a, b] : [b, a];
  return new Set(order.slice(lo, hi + 1));
}
