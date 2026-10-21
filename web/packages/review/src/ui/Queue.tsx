import { useLayoutEffect, useRef } from "react";
import { kindOf } from "../store";
import { statusOf } from "../sync";
import { Egg } from "./icons";
import { cx, useStore } from "./ctx";

export function Queue() {
  const s = useStore();
  const ref = useRef<HTMLElement>(null);
  useLayoutEffect(() => {
    ref.current?.querySelector(".qi.cur")?.scrollIntoView({ block: "nearest" });
  }, [s.cur, s.slideKey]);
  return (
    <nav className="queue scroll" id="queue" ref={ref} aria-label="Items">
      {s.data.items.map((i, k) => {
        const st = statusOf(i);
        const ask = (i.questions || []).length > 0 && !i.answer;
        return (
          <div key={i.id} className={cx("qi", st, k === s.cur && "cur")} data-k={k} onClick={() => s.go(k)} aria-current={k === s.cur ? "true" : undefined}>
            <span className="n">{String(k + 1).padStart(2, "0")}</span>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div className="t">
                <span className="ki">
                  <Egg kind={kindOf(i)} />
                </span>
                <span className="tt">{i.title}</span>
              </div>
              {ask && (
                <div className="q">
                  <i className="qd">●</i> {s.t("ask")}
                </div>
              )}
            </div>
            <span className="st" />
          </div>
        );
      })}
    </nav>
  );
}
