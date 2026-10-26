import { useEffect, useLayoutEffect, useRef } from "react";
import type { ReviewStore } from "../store";
import { Inspector } from "./Inspector";
import { Done, Lightbox, Modal, Toast } from "./Overlays";
import { Queue } from "./Queue";
import { Attachment, Stage } from "./Stage";
import { TopBar } from "./TopBar";
import { ListView, Overview } from "./Views";
import { cx, StoreCtx, useStore } from "./ctx";

function Shell({ onTheme }: { onTheme: () => void }) {
  const s = useStore();
  // another item comes in at its top: the detail scrolls as one column when narrow, and a new item opened half-way
  // down showed the tail of the picture well as an empty band
  const itemView = useRef<HTMLElement>(null);
  const ik = s.item ? s.keyOf(s.item) : "";
  useLayoutEffect(() => {
    if (itemView.current) itemView.current.scrollTop = 0;
  }, [ik]);
  useEffect(() => {
    document.documentElement.lang = s.lang === "zh-Hans" ? "zh-Hans" : "en";
    if (s.embedded || !s.loaded) return;
    const title = s.t("page.title", { name: String(s.data.title || s.data.session || s.t("page.brand")) });
    if (document.title !== title) document.title = title;
  });
  if (s.loadError)
    return (
      <div className="fail">
        <p>{s.t("load.failed")}</p>
      </div>
    );
  if (!s.loaded) return <div className="boot" aria-busy="true" />;
  if (s.mode === "item")
    return (
      <>
        {s.item ? (
          // one document: the item's words first, its pictures inline after its fields (an attachment, not a hero)
          <main id="itemView" ref={itemView} className={cx("focus item-mode", s.mediaItems(s.item).length === 0 && "bare")}>
            {/* a fresh inspector per item: nothing of one item's editing state can show under another's title */}
            <Inspector key={s.keyOf(s.item)} media={<Attachment />} />
          </main>
        ) : (
          <div className="fail">
            <p>{s.t(s.unreadable ? "item.unreadable" : "item.gone")}</p>
          </div>
        )}
        <span className={cx("saved item-saved", s.saveState === "error" && "err")} id="saved" aria-live="polite">
          {s.saveState === "saving" ? s.t("save.saving") : s.saveState === "error" ? s.t("save.error") : ""}
        </span>
        <Toast />
        <Modal />
        <Lightbox />
      </>
    );
  return (
    <>
      <TopBar onTheme={onTheme} />
      {s.view === "focus" && (
        <main id="focusView" className="focus">
          <Queue />
          <Stage />
          <Inspector />
        </main>
      )}
      {s.view === "list" && <ListView />}
      {s.view === "overview" && <Overview />}
      <Toast />
      <Modal />
      <Lightbox />
      <Done />
    </>
  );
}

export function App({ store, onTheme }: { store: ReviewStore; onTheme: () => void }) {
  useEffect(() => {
    const key = (e: KeyboardEvent) => store.onKeyDown(e);
    const vis = () => {
      if (!document.hidden) store.pollNow();
    };
    document.addEventListener("keydown", key);
    document.addEventListener("visibilitychange", vis);
    return () => {
      document.removeEventListener("keydown", key);
      document.removeEventListener("visibilitychange", vis);
    };
  }, [store]);
  return (
    <StoreCtx.Provider value={store}>
      <Shell onTheme={onTheme} />
    </StoreCtx.Provider>
  );
}
