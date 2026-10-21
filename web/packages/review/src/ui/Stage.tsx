import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { DragRect } from "../host";
import { fmt, kindOf, type Media, type ReviewStore } from "../store";
import { statusOf } from "../sync";
import { Egg } from "./icons";
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
  const i = s.item!;
  if (!m)
    return (
      <div id="mediaBox">
        <div className="shot none ready">{s.t("noMedia")}</div>
      </div>
    );
  if (m.kind === "wait")
    return (
      <div id="mediaBox">
        <div className={cx("shot wait ready", !s.stalled && "shim")} style={{ ["--ar" as string]: guessAR(s) }}>
          <div className="wait-in">
            <Egg kind={kindOf(i)} />
            <span>{s.stalled ? s.t("noMedia") : s.t("waitShot")}</span>
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
        {m.kind === "orig" && m.start != null ? ` · ${fmt(m.start)}` : ""}
      </span>
      {m.cap ? <span className="ct">{m.cap}</span> : null}
      {h.downloadUrl ? (
        <a className="dl" href={h.downloadUrl(rel)} download title={s.t("download")} aria-label={s.t("download")}>
          <Icon name="download" />
        </a>
      ) : h.download ? (
        <button className="dl" onClick={() => h.download!(rel)} title={s.t("download")} aria-label={s.t("download")}>
          <Icon name="download" />
        </button>
      ) : null}
      {h.quickLook && (
        <button className="dl" onClick={() => h.quickLook!(rel)} title={s.t("quickLook")} aria-label={s.t("quickLook")}>
          <Icon name="eye" />
        </button>
      )}
      {h.reveal && (
        <button className="dl" onClick={() => h.reveal!(rel)} title={s.t(h.host === "macos" ? "reveal" : "revealWin")} aria-label={s.t("reveal")}>
          <Icon name="folder" />
        </button>
      )}
    </div>
  );
}

/** report where the frames are, so a native layer can drag them out as files (C6 registerDragRects) */
function useDragRects(root: React.RefObject<HTMLElement | null>, deps: unknown[]) {
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
    <div ref={ref} key={`${i.id}:${s.slideKey}`} className={cx("slide", anim && (s.dir === "up" ? "in-up" : "in-down"))}>
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
  const st = i ? statusOf(i) : "pending";
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
          <button className={cx("act drop", st === "drop" && "on")} id="dropBtn" onClick={() => s.decide("drop")}>
            <Icon name="x" size={16} />
            <span>{s.t("drop")}</span>
            <kbd>X</kbd>
          </button>
          <button className="act ghost" id="mergeBtn" onClick={s.mergePrev}>
            <Icon name="merge" size={16} />
            <span>{s.t("merge")}</span>
            <kbd>M</kbd>
          </button>
          <button className="act ghost" id="undoBtn" onClick={s.undo}>
            <Icon name="undo" size={16} />
            <span>{s.t("undo")}</span>
            <kbd>Z</kbd>
          </button>
          <button className={cx("act keep", st === "keep" && "on")} id="keepBtn" onClick={() => s.decide("keep")}>
            <Icon name="check" size={17} />
            <span>{s.t("keep")}</span>
            <kbd>A</kbd>
          </button>
        </div>
      )}
    </section>
  );
}
