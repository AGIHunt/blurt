import { Egg } from "./icons";
import { cx, useStore } from "./ctx";
import { Logo, isMacLike } from "./TopBar";

export function Toast() {
  const s = useStore();
  const t = s.toast;
  return (
    <div className={cx("toast", t?.show && "show")} id="toast" role="status">
      <span id="toastMsg">{t?.msg}</span>
      {t?.undo && (
        <button id="toastUndo" onClick={s.undo}>
          {s.t("undo")}  Z
        </button>
      )}
    </div>
  );
}

function Keys() {
  const s = useStore();
  const mod = isMacLike() ? "⌘⏎" : "Ctrl+⏎";
  const rows: [string, string][] =
    s.mode === "item"
      ? [["← →", s.t("k_media")], ["Space / O", s.t("k_play")], ["E", s.t("k_edit")], ["1 2 3", s.t("k_sev")], [mod, s.t("k_fix")], ["?", s.t("k_help")]]
      : [["↓ ↑ / J K", s.t("k_next")], ["A / ⏎", s.t("k_keep")], ["X / ⌫", s.t("k_drop")], ["Z", s.t("k_undo")], ["M", s.t("k_merge")],
         ["1 2 3", s.t("k_sev")], ["← →", s.t("k_media")], ["Space / O", s.t("k_play")], ["E", s.t("k_edit")], ["G", s.t("k_view")],
         ["V", s.t("k_ov")], [mod, s.t("k_finish")], ["?", s.t("k_help")]];
  return (
    <>
      <h3>{s.t("keysTitle")}</h3>
      <div className="keys">
        {rows.map(([k, l]) => (
          <div key={l}>
            <span>{l}</span>
            <span>
              {k.split(" ").map((x, n) =>
                x === "/" ? (
                  <span key={n} style={{ color: "var(--faint)" }}>
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
          {s.t("ok")}
        </button>
      </div>
    </>
  );
}

function Finish() {
  const s = useStore();
  const c = s.counts();
  return (
    <>
      <h3>{s.t("confirmTitle")}</h3>
      <p>{s.finishError ? s.t("saveError") : s.t("confirmBody").replace("{k}", String(c.k)).replace("{d}", String(c.d)).replace("{p}", String(c.p))}</p>
      {s.finishWarn && (
        <div className="warn">
          <Egg kind="note" />
          <span>{s.t("stillProc")}</span>
        </div>
      )}
      <div className="sum">
        <div>
          <b style={{ color: "var(--keep-ink)" }}>{c.k}</b>
          {s.t("kept")}
        </div>
        <div>
          <b style={{ color: "var(--drop-ink)" }}>{c.d}</b>
          {s.t("dropped")}
        </div>
        <div>
          <b>{c.p}</b>
          {s.t("pending")}
        </div>
      </div>
      <div className="row">
        {c.p ? (
          <button className="btn" id="mRest" onClick={s.reviewRest}>
            {s.t("reviewRest")}
          </button>
        ) : (
          <button className="btn" id="mCancel" onClick={s.closeModal}>
            {s.t("cancel")}
          </button>
        )}
        <button className="btn primary" id="mOk" onClick={s.finish} disabled={s.confirming}>
          {c.p ? s.t("pendingAs") : s.t("confirm")}
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
        <Logo className="big" />
        <h2>{s.t("doneTitle")}</h2>
        <p>{s.host.inApp ? s.t("doneBodyApp") : s.t("doneBody")}</p>
      </div>
    </div>
  );
}
