let lang: 'zh' | 'en' = typeof navigator !== 'undefined' && navigator.language?.startsWith('zh') ? 'zh' : 'en';
export const setLang = (l: 'zh' | 'en') => (lang = l);
export const getLang = () => lang;
/** t('中文', 'English') */
export const t = (zh: string, en: string) => (lang === 'zh' ? zh : en);

export const KIND_ICON: Record<string, string> = { issue: '🐞', idea: '💡', note: '📝', task: '☑️' };
export const kindIcon = (k: string) => KIND_ICON[k] ?? '•';

export function ago(epoch: number | null | undefined, now = Date.now() / 1000): string {
  if (!epoch) return '';
  const d = Math.max(0, now - epoch);
  if (d < 60) return t('刚刚', 'now');
  if (d < 3600) return `${Math.floor(d / 60)}${t('分钟', 'm')}`;
  if (d < 86400) return `${Math.floor(d / 3600)}${t('小时', 'h')}`;
  if (d < 86400 * 30) return `${Math.floor(d / 86400)}${t('天', 'd')}`;
  return new Date(epoch * 1000).toLocaleDateString();
}

export function egg(s: { processed: number; processing: number; reviewed: number }): { icon: string; label: string; cls: string } {
  if (!s.processed) return { icon: '🥚', label: t('待整理', 'to process'), cls: 'egg' };
  if (s.processing) return { icon: '🥚', label: t('整理中', 'processing'), cls: 'egg wobble' };
  if (!s.reviewed) return { icon: '🐣', label: t('待审核', 'to review'), cls: 'egg' };
  return { icon: '🐔', label: t('已审核', 'reviewed'), cls: 'egg done' };
}

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
  return !!el?.closest?.('input, textarea, select, [contenteditable="true"]');
}
