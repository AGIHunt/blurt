import { KindIcon, StatusRing } from "@blurt/ui/react";
import { useLayoutEffect, useRef } from "react";
import type { Item } from "../host";
import { kindOf, type ReviewStore } from "../store";
import { cx, useStore } from "./ctx";

/** The work ring with its localized name; "handed off" says to whom (K10 work.handed_off.session / .external). */
export function WorkRing({ i, size = 14 }: { i: Item; size?: number }) {
  const s = useStore();
  const w = s.workOf(i);
  return <StatusRing state={w} size={size} label={workText(s, i)} />;
}

export function workText(s: ReviewStore, i: Item): string {
  const w = s.workOf(i);
  if (w === "handed_off" && i.work?.to === "session") return s.t("work.handed_off.session", { agent: agentName(i.work.agent) });
  if (w === "handed_off" && i.work?.to === "external") return s.t("work.handed_off.external");
  return s.workLabel(w);
}

const AGENTS: Record<string, string> = { claude: "Claude Code", codex: "Codex", human: "" };
export const agentName = (a: string | null | undefined) => (a ? (AGENTS[a] ?? a) : "agent");

export function Queue() {
  const s = useStore();
  const ref = useRef<HTMLElement>(null);
  useLayoutEffect(() => {
    ref.current?.querySelector(".qi.cur")?.scrollIntoView({ block: "nearest" });
  }, [s.cur, s.slideKey]);
  return (
    <nav className="queue scroll" id="queue" ref={ref} aria-label={s.t("view.list")}>
      {s.data.items.map((i, k) => {
        const st = s.st(i);
        const ask = (i.questions || []).length > 0 && !i.answer;
        const kd = kindOf(i);
        return (
          <div key={s.keyOf(i)} className={cx("qi", st, k === s.cur && "cur", "w-" + s.workOf(i))} data-k={k} onClick={() => s.go(k)} aria-current={k === s.cur ? "true" : undefined}>
            <span className="rd" title={st === "pending" ? s.t("review.draft") : undefined} />
            <KindIcon kind={kd} size={15} title={s.kindLabel(kd)} />
            <div className="qb">
              <div className="t">
                <span className="tt">{i.title}</span>
              </div>
              <div className="qm">
                <span className="n">{i.id}</span>
                {ask && (
                  <span className="q">
                    <span className="qd" /> {s.t("ask.title")}
                  </span>
                )}
              </div>
            </div>
            <WorkRing i={i} />
          </div>
        );
      })}
    </nav>
  );
}
