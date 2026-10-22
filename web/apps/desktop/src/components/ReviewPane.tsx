import { useEffect, useRef } from 'react';
import { mountReview, type BlurtHost, type MountOptions, type ReviewHandle } from '../review';

/** Mounts the review component (protocol v3, embedded in the main window) for one scope. Another scope or mode
    remounts; another item of the same scope goes through handle.setItem (no reload). */
export function ReviewPane({ host, opts, hostKey }: { host: BlurtHost; opts: MountOptions; hostKey: string }) {
  const el = useRef<HTMLDivElement>(null);
  const handle = useRef<ReviewHandle | null>(null);
  useEffect(() => {
    if (!el.current) return;
    // a fresh element per mount: the component keeps its own React root, which can't be unmounted while we render
    const child = document.createElement('div');
    child.className = 'review-mount';
    el.current.appendChild(child);
    const h = mountReview(child, host, { ...opts, embedded: true });
    handle.current = h;
    return () => {
      handle.current = null;
      child.style.display = 'none';
      setTimeout(() => {
        h.unmount();
        child.remove();
      });
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hostKey, opts.mode]);
  useEffect(() => {
    if (opts.itemId) handle.current?.setItem(opts.itemId);
  }, [opts.itemId]);
  useEffect(() => {
    if (opts.lang) handle.current?.setLang(opts.lang);
  }, [opts.lang]);
  return <div className="review-pane" ref={el} />;
}
