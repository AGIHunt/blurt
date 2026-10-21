import { useEffect } from "react";
import type { ReviewStore } from "../store";
import { EggSprite } from "./icons";
import { Inspector } from "./Inspector";
import { Done, Lightbox, Modal, Toast } from "./Overlays";
import { Queue } from "./Queue";
import { Stage } from "./Stage";
import { TopBar } from "./TopBar";
import { ListView, Overview } from "./Views";
import { cx, StoreCtx, useStore } from "./ctx";

function Shell({ onTheme }: { onTheme: () => void }) {
  const s = useStore();
  useEffect(() => {
    const title = `${s.data.title || s.data.session || "blurt"} · ${s.t("reviewTitle")}`;
    if (s.loaded && document.title !== title) document.title = title;
    document.documentElement.lang = s.lang === "zh" ? "zh-CN" : "en";
  });
  if (s.loadError)
    return (
      <div className="fail">
        <p>{s.loadError}</p>
      </div>
    );
  if (!s.loaded) return <div className="boot" aria-busy="true" />;
  if (s.mode === "item")
    return (
      <>
        {s.item ? (
          <main id="itemView" className="focus item-mode">
            <Stage />
            <Inspector />
          </main>
        ) : (
          <div className="fail">
            <p>{s.t("noItem")}</p>
          </div>
        )}
        <span className={cx("saved item-saved", s.saveState === "error" && "err")} id="saved" aria-live="polite">
          {s.saveState === "saving" ? s.t("saving") : s.saveState === "error" ? s.t("saveError") : ""}
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
      <EggSprite />
      <Shell onTheme={onTheme} />
    </StoreCtx.Provider>
  );
}
