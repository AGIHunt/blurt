// The Dictation page's small menu at a point (the "⋯" button's and a row's or a chip's right-click): the history's and
// the Words tab's.
import { useEffect, useRef, useState } from 'react';
import { Icon } from '@blurt/icons';

/** A small menu at a point: the "⋯" button's and the row's right-click. */
export function Menu({ at, onClose, children }: { at: { x: number; y: number; right?: boolean }; onClose: () => void; children: React.ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState(at);
  useEffect(() => {
    const el = ref.current;
    if (el) {
      const r = el.getBoundingClientRect();
      // `right`: x is the button's right edge — the menu ends there (a ⋯ at a column's edge), never past the window
      const x = at.right ? at.x - r.width : at.x;
      setPos({ x: Math.max(8, Math.min(x, window.innerWidth - r.width - 8)), y: Math.min(at.y, window.innerHeight - r.height - 8) });
      (el.querySelector('button:not(:disabled)') as HTMLElement | null)?.focus();
    }
    const down = (e: MouseEvent) => !ref.current?.contains(e.target as Node) && onClose();
    const key = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        onClose();
      } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        const bs = [...(ref.current?.querySelectorAll('button:not(:disabled)') ?? [])] as HTMLElement[];
        const i = bs.indexOf(document.activeElement as HTMLElement);
        bs[(i + (e.key === 'ArrowDown' ? 1 : bs.length - 1)) % bs.length]?.focus();
      }
    };
    window.addEventListener('mousedown', down);
    window.addEventListener('keydown', key, true);
    window.addEventListener('blur', onClose);
    return () => {
      window.removeEventListener('mousedown', down);
      window.removeEventListener('keydown', key, true);
      window.removeEventListener('blur', onClose);
    };
  }, []);
  return (
    <div ref={ref} className="smenu dict-menu" role="menu" style={{ left: pos.x, top: pos.y }} onClick={onClose}>
      {children}
    </div>
  );
}

/** One item: `keys` its accelerator, right-aligned and dim (Windows 11's context menus: Copy Ctrl+C, Delete Del);
 *  `checked` a choice that is the current one (a tick in the leading column). */
export function MenuItem({ label, onClick, disabled, danger, keys, checked, testId }: {
  label: string;
  onClick: () => void;
  disabled?: boolean;
  danger?: boolean;
  keys?: string;
  checked?: boolean;
  testId?: string;
}) {
  return (
    <button role={checked === undefined ? 'menuitem' : 'menuitemradio'} aria-checked={checked} className={`smenu-i ${danger ? 'dict-danger' : ''}`} disabled={disabled} onClick={onClick} data-testid={testId}>
      {checked !== undefined && <span className="dict-mk" aria-hidden="true">{checked ? <Icon name="check" size={12} /> : null}</span>}
      <span className="dict-ml">{label}</span>
      {keys && <span className="dict-mkeys">{keys}</span>}
    </button>
  );
}

