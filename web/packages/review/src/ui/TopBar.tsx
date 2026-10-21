import { Egg, ICheck, IKeys, ILang, IMoon } from "./icons";
import { cx, useStore } from "./ctx";

export function Logo({ className }: { className?: string }) {
  return (
    <img
      className={className}
      src="icon.png"
      alt=""
      onError={(e) => ((e.currentTarget as HTMLImageElement).style.visibility = "hidden")}
    />
  );
}

function Proc() {
  const s = useStore();
  if (s.proc === "hidden") return null;
  if (s.proc === "fin" || s.proc === "out")
    return (
      <span className={cx("proc fin", s.proc === "out" && "out")} id="proc">
        <ICheck />
        <span>{s.t("finished")}</span>
      </span>
    );
  const n = s.data.items.length;
  const f = s.data.items.filter((i) => (i.frames || []).length).length;
  const stalled = s.stalled;
  const title = s.t(stalled ? "stalled" : "working").replace("{n}", String(n));
  return (
    <span className={cx("proc", stalled && "stalled")} id="proc" title={title}>
      <Egg kind="note" />
      <span>
        <span className="long">{title}</span>
        {!stalled && (
          <>
            {" "}
            <b>
              {f}/{n}
            </b>
          </>
        )}
      </span>
    </span>
  );
}

export function TopBar({ onTheme }: { onTheme: () => void }) {
  const s = useStore();
  const c = s.counts();
  const inApp = !!s.host.inApp;
  const saved = s.saveState === "saving" ? s.t("saving") : s.saveState === "saved" ? s.t("saved") : s.saveState === "error" ? s.t("saveError") : "";
  return (
    <header className="top">
      <div className="brand">
        <Logo className="logo" />
        blurt
        {!inApp && s.data.session ? <small id="sessionName">· {String(s.data.session)}</small> : null}
      </div>
      <div className="progress">
        <div className="bar" aria-hidden="true">
          <i className="k" style={{ width: (c.n ? (c.k / c.n) * 100 : 0) + "%" }} />
          <i className="d" style={{ width: (c.n ? (c.d / c.n) * 100 : 0) + "%" }} />
        </div>
        <div className="counts" id="counts">
          <span>
            <span className="dot" style={{ background: "var(--line-2)" }} />
            <b>{c.p}</b> {s.t("pending")}
          </span>
          <span>
            <span className="dot" style={{ background: "var(--keep)" }} />
            <b>{c.k}</b> {s.t("kept")}
          </span>
          <span>
            <span className="dot" style={{ background: "var(--drop)" }} />
            <b>{c.d}</b> {s.t("dropped")}
          </span>
        </div>
      </div>
      <div className="sp" />
      <Proc />
      <span className={cx("saved", s.saveState === "error" && "err")} id="saved" aria-live="polite">
        {saved}
      </span>
      <div className="seg" role="tablist">
        {s.hasOverview && (
          <button role="tab" aria-selected={s.view === "overview"} className={cx(s.view === "overview" && "on")} id="vOverview" onClick={() => s.setView("overview")}>
            {s.t("overview")}
          </button>
        )}
        <button role="tab" aria-selected={s.view === "focus"} className={cx(s.view === "focus" && "on")} id="vFocus" onClick={() => s.setView("focus")}>
          {s.t("focus")}
        </button>
        <button role="tab" aria-selected={s.view === "list"} className={cx(s.view === "list" && "on")} id="vList" onClick={() => s.setView("list")}>
          {s.t("list")}
        </button>
      </div>
      {!inApp && (
        <button className="icon-btn" id="themeBtn" title={s.t("theme")} aria-label={s.t("theme")} onClick={onTheme}>
          <IMoon size={17} />
        </button>
      )}
      <button className="lang-btn" id="langBtn" title="中文 / English" onClick={s.toggleLang}>
        <ILang size={16} />
        <span id="langLbl">{s.t("langName")}</span>
      </button>
      <button className="icon-btn" id="helpBtn" title={s.t("shortcuts")} aria-label={s.t("shortcuts")} onClick={s.openHelp}>
        <IKeys size={17} />
      </button>
      <button className="btn primary" id="finishBtn" onClick={s.openFinish}>
        {s.t("finish")} <kbd>{isMacLike() ? "⌘⏎" : "Ctrl ⏎"}</kbd>
      </button>
    </header>
  );
}

export const isMacLike = () => document.documentElement.dataset.platform === "mac";
