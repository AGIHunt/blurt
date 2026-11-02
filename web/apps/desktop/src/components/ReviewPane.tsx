import { useEffect, useRef } from 'react';
import { mountReview, type BlurtHost, type MountOptions, type ReviewHandle } from '../review';

/** Mounts the review component (protocol v3, embedded in the main window) for one scope. Another scope or mode
    remounts; another item of the same scope goes through handle.setItem (no reload).
    The Mac gives the page a web view of its own; here it shares the window's document (sharedDocument: its keys are
    only the ones typed inside it). `onHandle`: the page on show, for the window's undo and Return-to-title;
    `rev`: the window wrote something (a list key, a move) — the page fetches the doc again in place, as the Mac's
    pollNow, so its scroll, caret and undo steps stay. */
export function ReviewPane({ host, opts, hostKey, onHandle, rev, onMissing }: {
  host: BlurtHost;
  opts: MountOptions;
  hostKey: string;
  onHandle?: (h: ReviewHandle | null) => void;
  rev?: number;
  /** the loaded doc doesn't have this item (discarded, moved in since): load one that lists it (the Mac reloads) */
  onMissing?: (itemId: string) => void;
}) {
  const el = useRef<HTMLDivElement>(null);
  const missingRef = useRef(onMissing);
  missingRef.current = onMissing;
  const handle = useRef<ReviewHandle | null>(null);
  useEffect(() => {
    if (!el.current) return;
    // a fresh element per mount: the component keeps its own React root, which can't be unmounted while we render
    const child = document.createElement('div');
    child.className = 'review-mount';
    el.current.appendChild(child);
    const h = mountReview(child, host, { ...opts, embedded: true, sharedDocument: true });
    handle.current = h;
    onHandle?.(h);
    // once a doc has come and it leaves the item out (a discarded one picked under the Discarded filter, the first
    // doc of a page that was asked for it before it loaded): ask for a doc that lists it — once per item and mount
    // (a doc loaded for that item that still lacks it is a real "gone")
    const told = new Set<string>();
    const st = (h as ReviewHandle & { store?: { loaded?: boolean; missing?: boolean; itemId?: string; subscribe?: (f: () => void) => () => void } }).store;
    const off = st?.subscribe?.(() => {
      const want = st.itemId;
      if (opts.mode === 'item' && st.loaded && st.missing && want && !told.has(want) && !hostKey.endsWith(`:${want}`)) {
        told.add(want);
        missingRef.current?.(want);
      }
    });
    return () => {
      off?.();
      handle.current = null;
      onHandle?.(null);
      child.style.display = 'none';
      setTimeout(() => {
        h.unmount();
        child.remove();
      });
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hostKey, opts.mode]);
  useEffect(() => {
    const h = handle.current as (ReviewHandle & { store?: { loaded?: boolean } }) | null;
    // before its first doc the page shows the item when the doc comes; after, false means the doc leaves it out
    if (opts.itemId && h && h.setItem(opts.itemId) === false && h.store?.loaded) onMissing?.(opts.itemId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [opts.itemId]);
  useEffect(() => {
    if (opts.lang) handle.current?.setLang(opts.lang);
  }, [opts.lang]);
  const first = useRef(true);
  useEffect(() => {
    if (first.current) return void (first.current = false);
    handle.current?.pollNow();
  }, [rev]);
  return <div className="review-pane" ref={el} />;
}
