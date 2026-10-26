import { Icon } from "./Icon";
import { cx, useStore } from "./ctx";
import { Logo, Thinking, isMacLike } from "./TopBar";

export function Toast() {
  const s = useStore();
  const t = s.toast;
  return (
    <div className={cx("toast", t?.show && "show")} id="toast" role="status"
         onMouseEnter={() => s.holdToast(true)} onMouseLeave={() => s.holdToast(false)}>
      {t?.icon && <Icon name={t.icon} size={15} className={"ti ti-" + t.icon} />}
      <span id="toastMsg">{t?.msg}</span>
      {t?.undo && (
        <button id="toastUndo" onClick={s.undoLast}>
          {s.t("action.undo")} <kbd>{s.mode === "item" ? (isMacLike() ? "⌘Z" : "Ctrl+Z") : "Z"}</kbd>
        </button>
      )}
    </div>
  );
}

function Keys() {
  const s = useStore();
  const mod = isMacLike() ? "⌘⏎" : "Ctrl+⏎";
  // the K3 state keys work on the item in front of you, in both modes
  const states: [string, string][] = [["D", "keys.done"], ["R", "keys.back"], ["W", "keys.wontfix"], ["S", "keys.state"]];
  const rows: [string, string][] =
    s.mode === "item"
      ? [["A", "keys.keep_item"], ["X / ⌫", "keys.discard_item"], ...states,
         ...(s.canHandOff ? [[mod, "keys.hand_off"] as [string, string]] : []),
         ["← →", "keys.media"], ["Space / O", "keys.play"], ["E", "keys.edit"], ["1 2 3 4", "keys.kind"], [isMacLike() ? "⌘Z ⇧⌘Z" : "Ctrl+Z", "keys.undo"], ["?", "keys.help"]]
      : [["↓ ↑ / J K", "keys.next"], ["A / ⏎", "keys.keep"], ["X / ⌫", "keys.discard"], ...states, ["Z", "keys.undo"], ["M", "keys.merge"],
         ["1 2 3 4", "keys.kind"], ["← →", "keys.media"], ["Space / O", "keys.play"], ["E", "keys.edit"], ["G", "keys.view"], ["Space", "keys.select"],
         ["V", "keys.overview"], ...(s.isSession ? [[mod, "keys.finish"] as [string, string]] : []), ["?", "keys.help"]];
  return (
    <>
      <h3>{s.t("keys.title")}</h3>
      <div className="keys">
        {rows.map(([k, l]) => (
          <div key={l}>
            <span>{s.t(l)}</span>
            <span>
              {k.split(" ").map((x, n) =>
                x === "/" ? (
                  <span key={n} className="kor">
                    {" / "}
                  </span>
                ) : (
                  <kbd key={n}>{x}</kbd>
                ),
              )}
            </span>
          </div>
        ))}
      </div>
      <div className="row">
        <button className="btn" onClick={s.closeModal} autoFocus>
          {s.t("action.ok")}
        </button>
      </div>
    </>
  );
}

function Finish() {
  const s = useStore();
  const c = s.counts();
  const n = s.i18n.formatNumber;
  // only an agent that waits (review.py) gets the batch "handed back"; a review started in Blurt just finishes
  const back = s.handsBack;
  return (
    <>
      <h3>{s.t(back ? "finish.title" : "finish.title_app")}</h3>
      <p>{s.finishError ? s.t("finish.error") : s.t("finish.body", { k: c.k, d: c.d, p: c.p })}</p>
      {s.finishWarn && (
        <div className="warn">
          <Thinking />
          <span>{s.t(back ? "finish.still_processing" : "finish.still_processing_app")}</span>
        </div>
      )}
      <div className="sum">
        <div>
          <b className="k">{n(c.k)}</b>
          {s.t("counts.kept")}
        </div>
        <div>
          <b className="d">{n(c.d)}</b>
          {s.t("counts.dropped")}
        </div>
        <div>
          <b>{n(c.p)}</b>
          {s.t("counts.pending")}
        </div>
      </div>
      <div className="row">
        {c.p ? (
          <button className="btn" id="mRest" onClick={s.reviewRest}>
            {s.t("finish.review_rest")}
          </button>
        ) : (
          <button className="btn" id="mCancel" onClick={s.closeModal}>
            {s.t("action.cancel")}
          </button>
        )}
        <button className="btn primary" id="mOk" onClick={s.finish} disabled={s.confirming} autoFocus>
          {c.p ? s.t("finish.pending_as_kept") : s.t("finish.confirm")}
        </button>
      </div>
    </>
  );
}

export function Modal() {
  const s = useStore();
  return (
    <div className={cx("modal-bg", s.modal && "show")} id="modalBg" onClick={(e) => e.target === e.currentTarget && s.closeModal()}>
      <div className="modal" id="modal" role="dialog" aria-modal="true">
        {s.modal === "help" ? <Keys /> : s.modal === "finish" ? <Finish /> : null}
      </div>
    </div>
  );
}

export function Lightbox() {
  const s = useStore();
  return (
    <div className={cx("lightbox", s.lightbox && "show")} id="lightbox" onClick={() => s.openLightbox(null)}>
      {s.lightbox && <img alt="" src={s.lightbox} />}
    </div>
  );
}

export function Done() {
  const s = useStore();
  return (
    <div className={cx("done", s.confirmed && "show")} id="done">
      <div>
        {!s.embedded && (
          <span className="cel">
            <Logo className="big peep-done" />
          </span>
        )}
        <h2>{s.t(s.handsBack ? "done.title" : "done.title_app")}</h2>
        <p>{!s.handsBack ? s.i18n.plural("done.body_app_todo", s.doneTodo) : s.host.inApp ? s.t("done.body_app") : s.t("done.body")}</p>
      </div>
    </div>
  );
}
