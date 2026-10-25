import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { DragRect } from "../host";
import type { Media, ReviewStore } from "../store";
import { Icon } from "./Icon";
import { cx, useStore } from "./ctx";

function guessAR(s: ReviewStore) {
  for (const r of s.ar.values()) if (r > 0) return r;
  return 1.6;
}

function Shot({ m }: { m: Media }) {
  const s = useStore();
  const known = s.ar.get(m.src);
  const fresh = s.fresh.has(m.src);
  const [ready, setReady] = useState(!!known && !fresh);
  const [ar, setAr] = useState(known || guessAR(s));
  const fit = (r: number) => {
    if (r > 0) {
      s.ar.set(m.src, r);
      setAr(r);
    }
    requestAnimationFrame(() => setReady(true));
  };
  if (m.kind === "img")
    return (
      <div className={cx("shot", ready && "ready", fresh && "fresh")} style={{ ["--ar" as string]: ar }} data-rel={m.rel}>
        <img
          src={m.src}
          alt=""
          ref={(el) => {
            if (el && el.complete && el.naturalWidth && !ready) fit(el.naturalWidth / el.naturalHeight);
          }}
          onLoad={(e) => fit(e.currentTarget.naturalWidth / e.currentTarget.naturalHeight)}
          onError={() => fit(0)}
          onClick={() => s.openLightbox(m.src)}
        />
      </div>
    );
  return (
    <div className={cx("shot", ready && "ready")} style={{ ["--ar" as string]: ar }} data-rel={m.rel}>
      <video
        src={m.src}
        controls
        playsInline
        preload="metadata"
        onLoadedMetadata={(e) => {
          const v = e.currentTarget;
          fit(v.videoWidth / v.videoHeight);
          if (m.kind === "orig" && m.start != null) v.currentTime = Math.max(0, m.start - 1.5);
        }}
        onError={() => fit(0)}
        onTimeUpdate={(e) => {
          const v = e.currentTarget;
          if (m.kind === "orig" && m.end != null && v.currentTime > m.end + 2 && !v.dataset.freed) {
            v.pause();
            v.dataset.freed = "1";
          }
        }}
      />
    </div>
  );
}

function MediaBox({ items, k }: { items: Media[]; k: number }) {
  const s = useStore();
  const m = items[k];
  if (!m)
    return (
      <div id="mediaBox">
        <div className="shot none ready">{s.t("media.none")}</div>
      </div>
    );
  if (m.kind === "wait")
    return (
      <div id="mediaBox">
        <div className={cx("shot wait ready", !s.stalled && "shim")} style={{ ["--ar" as string]: guessAR(s) }}>
          <div className="wait-in">
            <Icon name="hatch" className="hatching" />
            <span>{s.stalled ? s.t("media.none") : s.t("media.adding")}</span>
          </div>
        </div>
      </div>
    );
  return (
    <div id="mediaBox">
      <Shot key={m.src} m={m} />
    </div>
  );
}

function Caption({ m }: { m: Media | undefined }) {
  const s = useStore();
  const h = s.host;
  if (!m || m.kind === "wait") return <div className="cap" id="mediaCap" />;
  const rel = m.rel || "";
  return (
    <div className="cap" id="mediaCap">
      <span className="tm">
        {m.label}
        {m.kind === "orig" && m.start != null ? ` · ${s.clock(m.start)}` : ""}
      </span>
      {m.cap ? <span className="ct">{m.cap}</span> : null}
      {h.downloadUrl ? (
        <a className="dl" href={h.downloadUrl(rel)} download title={s.t("media.download")} aria-label={s.t("media.download")}>
          <Icon name="download" />
        </a>
      ) : h.download ? (
        <button className="dl" onClick={() => h.download!(rel)} title={s.t("media.download")} aria-label={s.t("media.download")}>
          <Icon name="download" />
        </button>
      ) : null}
      {h.quickLook && (
        <button className="dl" onClick={() => h.quickLook!(rel)} title={s.t("media.quick_look")} aria-label={s.t("media.quick_look")}>
          <Icon name="eye" />
        </button>
      )}
      {h.reveal && (
        <button className="dl" onClick={() => h.reveal!(rel)} title={s.t(h.host === "macos" ? "media.reveal_mac" : "media.reveal")} aria-label={s.t(h.host === "macos" ? "media.reveal_mac" : "media.reveal")}>
          <Icon name="folder" />
        </button>
      )}
    </div>
  );
}

/** report where the frames are, so a native layer can drag them out as files (C6 registerDragRects) */
export function useDragRects(root: React.RefObject<HTMLElement | null>, deps: unknown[]) {
  const s = useStore();
  const reg = s.host.registerDragRects;
  useEffect(() => {
    if (!reg || !root.current) return;
    let raf = 0;
    let last = "";
    const send = () => {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => {
        const rects: DragRect[] = [];
        root.current?.querySelectorAll<HTMLElement>("[data-rel]").forEach((el) => {
          const r = el.getBoundingClientRect();
          if (r.width > 0 && r.height > 0)
            rects.push({ rel: el.dataset.rel!, x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) });
        });
        const key = JSON.stringify(rects);
        if (key !== last) {
          last = key;
          reg(rects);
        }
      });
    };
    send();
    const ro = new ResizeObserver(send);
    ro.observe(root.current);
    window.addEventListener("resize", send);
    const t = setTimeout(send, 400); // after the slide-in animation
    return () => {
      ro.disconnect();
      window.removeEventListener("resize", send);
      clearTimeout(t);
      cancelAnimationFrame(raf);
      reg([]);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
}

/** The main window's detail (item mode): the item's pictures and clips inside its column, edge to edge with a 1 px
    inner stroke — no grey well around them. What you can do with one (Quick Look, Download, Show in Finder) sits in a
    small bar over its top corner while the pointer is on it (or a key is in it); a frame's time only where it says
    something (a clip, a frame of a recording among others). Several: a row of thumbnails under it. */
export function ItemMedia({ i }: { i: import("../host").Item }) {
  const s = useStore();
  const h = s.host;
  const ref = useRef<HTMLElement>(null);
  const items = s.mediaItems(i);
  const k = s.mediaIndex(items);
  const m = items[k];
  useDragRects(ref, [s.keyOf(i), k, items.length]);
  if (!m) return null;
  const rel = m.rel || "";
  const many = items.length >= 2;
  const reveal = s.t(h.host === "macos" ? "media.reveal_mac" : "media.reveal");
  return (
    <section className={cx("imedia", many && "many")} ref={ref} id="itemMedia" aria-label={s.t("media.title")}>
      {m.kind === "wait" ? (
        <div className={cx("iwait", !s.stalled && "shim")}>
          <Icon name="hatch" className="hatching" />
          <span>{s.stalled ? s.t("media.none") : s.t("media.adding")}</span>
        </div>
      ) : (
        <figure className="imain" data-rel={rel} tabIndex={-1}>
          {m.kind === "img" ? (
            <img key={m.src} src={m.src} alt={m.cap || ""} onClick={() => (h.quickLook ? h.quickLook(rel) : s.openLightbox(m.src))} />
          ) : (
            <video key={m.src + m.kind} src={m.src} controls playsInline preload="metadata"
              onLoadedMetadata={(e) => {
                if (m.kind === "orig" && m.start != null) e.currentTarget.currentTime = Math.max(0, m.start - 1.5);
              }} />
          )}
          <figcaption className="ibar">
            {(m.kind !== "img" || many) && <span className="tm">{m.label}{m.kind === "orig" && m.start != null ? ` · ${s.clock(m.start)}` : ""}</span>}
            {h.quickLook && (
              <button onClick={() => h.quickLook!(rel)} title={s.t("media.quick_look")} aria-label={s.t("media.quick_look")}>
                <Icon name="eye" size={15} />
              </button>
            )}
            {h.downloadUrl ? (
              <a href={h.downloadUrl(rel)} download title={s.t("media.download")} aria-label={s.t("media.download")}>
                <Icon name="download" size={15} />
              </a>
            ) : h.download ? (
              <button onClick={() => h.download!(rel)} title={s.t("media.download")} aria-label={s.t("media.download")}>
                <Icon name="download" size={15} />
              </button>
            ) : null}
            {h.reveal && (
              <button onClick={() => h.reveal!(rel)} title={reveal} aria-label={reveal}>
                <Icon name="reveal" size={15} />
              </button>
            )}
          </figcaption>
          {m.cap ? <p className="icap">{m.cap}</p> : null}
        </figure>
      )}
      {many && (
        <div className="ithumbs">
          {items.map((x, n) =>
            x.kind === "img" ? (
              <button key={x.src} className={cx("th", n === k && "on")} data-m={n} data-rel={x.rel} onClick={() => s.selectMedia(x.src)} aria-label={x.label}>
                <img src={x.src} alt="" />
              </button>
            ) : x.kind === "wait" ? null : (
              <button key={x.src + x.kind} className={cx("th vid", n === k && "on")} data-m={n} onClick={() => s.selectMedia(x.src)}>
                <Icon name={x.kind === "clip" ? "film" : "video"} className="ic" />
                {x.label}
              </button>
            ),
          )}
        </div>
      )}
    </section>
  );
}

export function Slide() {
  const s = useStore();
  const i = s.item;
  const ref = useRef<HTMLDivElement>(null);
  const items = s.mediaItems(i);
  const k = s.mediaIndex(items);
  const anim = s.slideKey > 0;
  useDragRects(ref, [s.cur, k, items.length, s.slideKey]);
  if (!i) return null;
  return (
    <div ref={ref} key={`${s.keyOf(i)}:${s.slideKey}`} className={cx("slide", anim && (s.dir === "up" ? "in-up" : "in-down"))}>
      <div className={cx("media", items.length >= 2 && "has-strip")}>
        <div className="frame">
          <MediaBox items={items} k={k} />
          <Caption m={items[k]} />
          {items.length >= 2 && (
            <div className="strip scroll">
              {items.map((m, n) =>
                m.kind === "img" ? (
                  <button key={m.src} className={cx("th", n === k && "on", s.fresh.has(m.src) && "fresh")} data-m={n} data-rel={m.rel} onClick={() => s.selectMedia(m.src)}>
                    <img src={m.src} alt="" />
                    <span className="lbl">{m.label}</span>
                  </button>
                ) : m.kind === "wait" ? (
                  <button key={m.src} className={cx("th shim", n === k && "on")} data-m={n} onClick={() => s.selectMedia(m.src)}>
                    <span className="lbl">…</span>
                  </button>
                ) : (
                  <button key={m.src + m.kind} className={cx("th vid", n === k && "on")} data-m={n} onClick={() => s.selectMedia(m.src)}>
                    <Icon name={m.kind === "clip" ? "film" : "video"} className="ic" />
                    {m.label}
                  </button>
                ),
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

export function Stage() {
  const s = useStore();
  const ref = useRef<HTMLElement>(null);
  const i = s.item;
  const st = i ? s.st(i) : "pending";
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const wheel = (e: WheelEvent) => s.onWheel(e);
    let y: number | null = null;
    const ts = (e: TouchEvent) => (y = e.touches[0].clientY);
    const te = (e: TouchEvent) => {
      if (y == null) return;
      const d = y - e.changedTouches[0].clientY;
      if (Math.abs(d) > 50) d > 0 ? s.go(s.cur + 1, "up") : s.go(s.cur - 1, "down");
      y = null;
    };
    el.addEventListener("wheel", wheel, { passive: true });
    el.addEventListener("touchstart", ts, { passive: true });
    el.addEventListener("touchend", te);
    return () => {
      el.removeEventListener("wheel", wheel);
      el.removeEventListener("touchstart", ts);
      el.removeEventListener("touchend", te);
    };
  }, [s]);
  return (
    <section className="stage" id="stage" ref={ref}>
      <Slide />
      {s.mode === "review" && (
        <div className="actions">
          {st === "drop" ? (
            <button className="act drop on" id="dropBtn" onClick={() => s.actOnCurrent("restore")}>
              <Icon name="restart" size={16} />
              <span>{s.t("action.restore")}</span>
              <kbd>R</kbd>
            </button>
          ) : (
            <button className="act drop" id="dropBtn" onClick={() => s.decide("discard")}>
              <Icon name="x" size={16} />
              <span>{s.t("action.discard")}</span>
              <kbd>X</kbd>
            </button>
          )}
          <button className="act ghost" id="mergeBtn" onClick={s.mergePrev}>
            <Icon name="merge" size={16} />
            <span>{s.t("action.merge")}</span>
            <kbd>M</kbd>
          </button>
          <button className="act ghost" id="undoBtn" onClick={s.undoLast}>
            <Icon name="undo" size={16} />
            <span>{s.t("action.undo")}</span>
            <kbd>Z</kbd>
          </button>
          <button className={cx("act keep", st === "keep" && "on")} id="keepBtn" onClick={() => s.decide("keep")}>
            <Icon name="check" size={17} />
            <span>{s.t("action.keep")}</span>
            <kbd>A</kbd>
          </button>
        </div>
      )}
    </section>
  );
}
