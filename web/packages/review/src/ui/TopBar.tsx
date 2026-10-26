import { Icon } from "./Icon";
import { cx, useStore } from "./ctx";
import peep from "../assets/peep-vector.svg";

/** Peep, the brand character: the shaded vector drawing (assets/brand/import_peep.py), no tile. */
export function Logo({ className }: { className?: string }) {
  return <img className={className} src={peep} alt="" />;
}

/** Peep thinking (its eye looks round): the menu-bar glyph's frames as a mask, in the colour around it. Organising,
 *  and media still on their way. Reduce Motion: one frame, the eye up. */
export function Thinking({ className }: { className?: string }) {
  return <span className={cx("peep-think", className)} aria-hidden="true" />;
}

/** organizing: Peep thinking (brand and motion only, K8) */
function Proc() {
  const s = useStore();
  if (s.proc === "hidden") return null;
  if (s.proc === "fin" || s.proc === "out")
    return (
      <span className={cx("proc fin", s.proc === "out" && "out")} id="proc">
        <Icon name="check" />
        <span>{s.t("proc.finished")}</span>
      </span>
    );
  const n = s.data.items.length;
  const f = s.data.items.filter((i) => (i.frames || []).length).length;
  const stalled = s.stalled;
  const title = s.plural(stalled ? "proc.stalled" : "proc.working", n);
  return (
    <span className={cx("proc", stalled ? "stalled" : "ai-working")} id="proc" title={title}>
      <Thinking />
      <span>
        <span className="long">{title}</span>
        {!stalled && (
          <>
            {" "}
            <b>
              {s.i18n.formatNumber(f)}/{s.i18n.formatNumber(n)}
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
  const chrome = !s.embedded;
  const showTheme = chrome && !s.host.inApp;
  const saved = s.saveState === "saving" ? s.t("save.saving") : s.saveState === "saved" ? s.t("save.saved") : s.saveState === "error" ? s.t("save.error") : "";
  const scopeName = s.data.scope && "project" in s.data.scope ? s.projectName(s.project(s.data.scope.project)) : "";
  return (
    <header className="top">
      {chrome && (
        <div className="brand">
          <Logo className="logo" />
          {s.t("page.brand")}
          {!s.host.inApp && (s.data.session || scopeName) ? <small id="sessionName">· {String(scopeName || s.data.session)}</small> : null}
        </div>
      )}
      <div className="progress">
        <div className="bar" aria-hidden="true">
          <i className="k" style={{ width: (c.n ? (c.k / c.n) * 100 : 0) + "%" }} />
          <i className="d" style={{ width: (c.n ? (c.d / c.n) * 100 : 0) + "%" }} />
        </div>
        <div className="counts" id="counts">
          <span>
            <span className="dot pend" />
            <b>{s.i18n.formatNumber(c.p)}</b> {s.t("counts.pending")}
          </span>
          <span>
            <span className="dot keep" />
            <b>{s.i18n.formatNumber(c.k)}</b> {s.t("counts.kept")}
          </span>
          <span>
            <span className="dot drop" />
            <b>{s.i18n.formatNumber(c.d)}</b> {s.t("counts.dropped")}
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
            {s.t("view.overview")}
          </button>
        )}
        <button role="tab" aria-selected={s.view === "focus"} className={cx(s.view === "focus" && "on")} id="vFocus" onClick={() => s.setView("focus")}>
          {s.t("view.focus")}
        </button>
        <button role="tab" aria-selected={s.view === "list"} className={cx(s.view === "list" && "on")} id="vList" onClick={() => s.setView("list")}>
          {s.t("view.list")}
        </button>
      </div>
      {showTheme && (
        <button className="icon-btn" id="themeBtn" title={s.t("theme.switch")} aria-label={s.t("theme.switch")} onClick={onTheme}>
          <Icon name="moon" size={17} />
        </button>
      )}
      {chrome && (
        <button className="lang-btn" id="langBtn" title={s.t("lang.switch")} aria-label={s.t("lang.switch")} onClick={s.toggleLang}>
          <Icon name="languages" size={16} />
          <span id="langLbl">{s.t("lang.name")}</span>
        </button>
      )}
      <button className="icon-btn" id="helpBtn" title={s.t("keys.open") + " ?"} aria-label={s.t("keys.open")} onClick={s.openHelp}>
        <Icon name="keyboard" size={17} />
      </button>
      {s.isSession && (
        <button className="btn primary" id="finishBtn" onClick={s.openFinish}>
          {s.t("review.finish")} <kbd>{isMacLike() ? "⌘⏎" : "Ctrl ⏎"}</kbd>
        </button>
      )}
    </header>
  );
}

export const isMacLike = () => document.documentElement.dataset.platform === "mac";
