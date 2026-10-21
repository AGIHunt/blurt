import { useLayoutEffect, useRef } from "react";
import type { Item } from "../host";
import { kindOf } from "../store";
import { statusOf } from "../sync";
import { Egg } from "./icons";
import { Icon } from "./Icon";
import { cx, useStore } from "./ctx";

/** The fix state next to a title, as in the main window: fixed = a check (and the title struck through, via .fx-fixed),
    fixing = the agent-run mark, pulsing gently. Other states show nothing here (the inspector's chip has them). */
export function FixMark({ i }: { i: Item }) {
  const s = useStore();
  const st = i.fix?.state;
  if (st !== "fixed" && st !== "fixing") return null;
  return <Icon name={st === "fixed" ? "check" : "agent-run"} size={13} className={"fxi fxi-" + st} title={s.t(("fix_" + st) as never)} />;
}

/** the row / card class for an item's fix state ("fx-fixed", "fx-fixing"), or nothing */
export const fixClass = (i: Item) => (i.fix?.state === "fixed" || i.fix?.state === "fixing" ? "fx-" + i.fix.state : null);

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
          <div key={i.id} className={cx("qi", st, k === s.cur && "cur", fixClass(i))} data-k={k} onClick={() => s.go(k)} aria-current={k === s.cur ? "true" : undefined}>
            <span className="n">{String(k + 1).padStart(2, "0")}</span>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div className="t">
                <span className="ki">
                  <Egg kind={kindOf(i)} />
                </span>
                <span className="tt">{i.title}</span>
                <FixMark i={i} />
              </div>
              {ask && (
                <div className="q">
                  <span className="qd" /> {s.t("ask")}
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
