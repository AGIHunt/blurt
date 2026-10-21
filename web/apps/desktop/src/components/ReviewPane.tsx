import { useEffect, useRef } from 'react';
import { mountReview, type BlurtHost, type MountOptions, type ReviewHandle } from '../review';

/** Mounts the review component (C6) for one session; remounts when the session, mode or item changes. */
export function ReviewPane({ host, opts, hostKey }: { host: BlurtHost; opts: MountOptions; hostKey: string }) {
  const el = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!el.current) return;
    // a fresh element per mount: the component may keep its own React root, which can't be unmounted while we render
    const child = document.createElement('div');
    child.className = 'review-mount';
    el.current.appendChild(child);
    const h = mountReview(child, host, opts) as ReviewHandle | (() => void) | undefined;
    return () => {
      child.style.display = 'none';
      setTimeout(() => {
        if (typeof h === 'function') h(); // WP3's mountReview may return a cleanup function or a handle
        else h?.unmount?.();
        child.remove();
      });
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hostKey, opts.mode, opts.itemId, opts.platform, opts.theme]);
  return <div className="review-pane" ref={el} />;
}
