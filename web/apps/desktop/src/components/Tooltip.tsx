// The window's own tooltip, in place of the WebView's `title` box (square, light, Win95-looking even in dark mode, and
// it hung across the panes in the shots). Any element with `data-tip` gets it: after half a second over it, a small
// rounded panel in the theme's raised surface, 12 px, under the element and kept inside the window. `data-tip-trunc`
// shows it only while the element's text is cut (a row title that fits says nothing more). Any key, click, scroll or
// leaving the element hides it.
import { useEffect, useRef, useState } from 'react';

type Shown = { text: string; x: number; y: number; above: boolean };

export function Tooltip() {
  const [tip, setTip] = useState<Shown | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const over = useRef<HTMLElement | null>(null);
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const hide = () => {
      clearTimeout(timer.current);
      over.current = null;
      setTip(null);
    };
    const onOver = (e: MouseEvent) => {
      const el = (e.target as HTMLElement | null)?.closest?.('[data-tip]') as HTMLElement | null;
      if (el === over.current) return;
      hide();
      if (!el) return;
      over.current = el;
      timer.current = setTimeout(() => {
        if (over.current !== el || !el.isConnected) return;
        const text = el.dataset.tip;
        if (!text) return;
        if (el.hasAttribute('data-tip-trunc') && el.scrollWidth <= el.clientWidth + 1) return;
        const r = el.getBoundingClientRect();
        const above = r.bottom + 40 > window.innerHeight;
        setTip({ text, x: Math.max(8, Math.min(e.clientX - 12, window.innerWidth - 8)), y: above ? r.top - 6 : r.bottom + 6, above });
      }, 500);
    };
    document.addEventListener('mouseover', onOver, true);
    document.addEventListener('mousedown', hide, true);
    document.addEventListener('keydown', hide, true);
    document.addEventListener('scroll', hide, true);
    window.addEventListener('blur', hide);
    return () => {
      document.removeEventListener('mouseover', onOver, true);
      document.removeEventListener('mousedown', hide, true);
      document.removeEventListener('keydown', hide, true);
      document.removeEventListener('scroll', hide, true);
      window.removeEventListener('blur', hide);
      clearTimeout(timer.current);
    };
  }, []);
  // keep it inside the window once its width is known
  useEffect(() => {
    const el = box.current;
    if (!el || !tip) return;
    const w = el.offsetWidth;
    if (tip.x + w > window.innerWidth - 8) el.style.left = `${Math.max(8, window.innerWidth - 8 - w)}px`;
  }, [tip]);
  if (!tip) return null;
  return (
    <div
      ref={box}
      className="mw-tip"
      role="tooltip"
      style={{ left: tip.x, top: tip.above ? undefined : tip.y, bottom: tip.above ? window.innerHeight - tip.y : undefined }}
    >
      {tip.text}
    </div>
  );
}
