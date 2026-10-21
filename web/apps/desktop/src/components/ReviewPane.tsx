import { useEffect, useRef } from 'react';
import { mountReview, type BlurtHost, type MountOptions, type ReviewHandle } from '../review';

/** Mounts the review component (C6) for one session. A new session or mode remounts; another item of the same
    session goes through handle.setItem (no reload). */
export function ReviewPane({ host, opts, hostKey }: { host: BlurtHost; opts: MountOptions; hostKey: string }) {
  const el = useRef<HTMLDivElement>(null);
  const handle = useRef<ReviewHandle | null>(null);
  useEffect(() => {
    if (!el.current) return;
    // a fresh element per mount: the component keeps its own React root, which can't be unmounted while we render
    const child = document.createElement('div');
    child.className = 'review-mount';
    el.current.appendChild(child);
    const h = mountReview(child, host, opts);
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
  }, [hostKey, opts.mode, opts.lang]);
  useEffect(() => {
    if (opts.itemId) handle.current?.setItem(opts.itemId);
  }, [opts.itemId]);
  return <div className="review-pane" ref={el} />;
}
