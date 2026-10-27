import type { Action } from "@blurt/ui";
import { KindIcon, StatePill, StatusRing } from "@blurt/ui/react";
import { useLayoutEffect, useRef } from "react";
import type { Item } from "../host";
import { kindOf, type ReviewStore } from "../store";
import { cx, useStore } from "./ctx";
import { isMacLike } from "./TopBar";

/** The state's name; "handed off" says to whom (K10 state.handed_off.session / .external). */
export function stateText(s: ReviewStore, i: Item): string {
  const st = s.stateOf(i);
  if (st === "handed_off" && i.work?.to === "session") {
    const desktop = i._work_runner === "desktop" ? desktopName(s, i.work.agent) : null;
    return desktop ? s.t("state.handed_off.desktop", { app: desktop }) : s.t("state.handed_off.session", { agent: agentName(s, i.work.agent) });
  }
  if (st === "handed_off" && i.work?.to === "external") return s.t("state.handed_off.external");
  return s.stateLabel(st);
}

/** The state ring with its localized name (not clickable). */
export function StateRing({ i, size = 14 }: { i: Item; size?: number }) {
  const s = useStore();
  return <StatusRing state={s.stateOf(i)} size={size} label={stateText(s, i)} />;
}

/** The state you can change: a pill (detail) or the bare ring (cards) opening the K3 action menu. `shortcuts`: the
    menu shows the keys (only where they work — the focused item). */
export function StateControl({ i, variant = "pill", id, shortcuts = false, controlled = false }: {
  i: Item;
  variant?: "pill" | "ring";
  id?: string;
  shortcuts?: boolean;
  /** the S key opens this one (the current item's) */
  controlled?: boolean;
}) {
  const s = useStore();
  // ⌘⏎ finishes the review in review mode; it hands off only in item mode
  const keys = shortcuts && ((a: Action) => a !== "hand_off" || s.mode === "item");
  return (
    <StatePill
      id={id}
      state={s.stateOf(i)}
      label={stateText(s, i)}
      t={s.t}
      variant={variant}
      size={variant === "pill" ? 16 : 14}
      onPick={(a) => s.act([i], a)}
      canHandOff={s.canHandOff}
      restoreTo={s.restoreTo(i)}
      keys={keys}
      mac={isMacLike()}
      {...(controlled ? { open: s.menuOpen, onOpenChange: s.setMenuOpen } : {})}
    />
  );
}

/** An agent's name as the user knows it (the doc's `agents`, from agents.json and their own agent_defs); a localized
    "Agent" when the doc doesn't say — never its id. */
export const agentName = (s: ReviewStore, a: string | null | undefined) =>
  (a && s.data.agents?.[a]?.name) || s.t("agent.generic");
/** The agent's desktop app ("Claude"), when the hand-off went there. */
const desktopName = (s: ReviewStore, a: string | null | undefined) => (a && s.data.agents?.[a]?.desktop) || null;

export function Queue() {
  const s = useStore();
  const ref = useRef<HTMLElement>(null);
  useLayoutEffect(() => {
    ref.current?.querySelector(".qi.cur")?.scrollIntoView({ block: "nearest" });
  }, [s.cur, s.slideKey]);
  return (
    <nav className="queue scroll" id="queue" ref={ref} aria-label={s.t("view.list")}>
      {s.data.items.map((i, k) => {
        const ask = (i.questions || []).length > 0 && !i.answer;
        const kd = kindOf(i);
        return (
          <div key={s.keyOf(i)} className={cx("qi", s.st(i), k === s.cur && "cur", "s-" + s.stateOf(i))} data-k={k} onClick={() => s.go(k)} aria-current={k === s.cur ? "true" : undefined}>
            <KindIcon kind={kd} size={16} title={s.kindLabel(kd)} />
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
            <StateRing i={i} />
          </div>
        );
      })}
    </nav>
  );
}
