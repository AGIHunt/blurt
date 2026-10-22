import { useEffect } from "react";
import type { ReviewStore } from "../store";
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
    document.documentElement.lang = s.lang === "zh-Hans" ? "zh-Hans" : "en";
    if (s.embedded || !s.loaded) return;
    const title = s.t("page.title", { name: String(s.data.title || s.data.session || s.t("page.brand")) });
    if (document.title !== title) document.title = title;
  });
  if (s.loadError)
    return (
      <div className="fail">
        <p>{s.t("load.failed", { error: s.loadError })}</p>
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
            <p>{s.t("item.gone")}</p>
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
