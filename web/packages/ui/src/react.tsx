/* K8 components: <KindIcon kind/>, <StatusRing state/> and <StatePill state/> (the ring + its K3 action menu).
   Colours come from tokens.css + base.css. */
import { Icon, type IconName } from "@blurt/icons";
import { useCallback, useEffect, useId, useLayoutEffect, useRef, useState, type CSSProperties, type KeyboardEvent as ReactKeyboardEvent, type RefObject } from "react";
import { createPortal } from "react-dom";
import { menuCase } from "./casing";
import { kindIcon, kindStyle, ringAttrs, ringShapes } from "./kinds";
import { actionForKey, menuFor, TRANSITIONS, type Action, type State } from "./lifecycle";

export interface KindIconProps {
  kind: string;
  /** px (default 16) */
  size?: number;
  /** accessible name (the localized kind); without it the icon is decorative */
  title?: string;
  className?: string;
}

/** A kind's icon in its colour: issue = bug, idea = light bulb, note = document, task = checklist, custom lens = tag. */
export function KindIcon({ kind, size = 16, title, className }: KindIconProps) {
  return (
    <span className={"kind-ic k-" + kind.replace(/[^\w-]/g, "_") + (className ? " " + className : "")} style={kindStyle(kind) as CSSProperties}>
      <Icon name={kindIcon(kind) as IconName} size={size} title={title} />
    </span>
  );
}

export interface StatusRingProps {
  state: State;
  /** px: 14 in lists, 18 in the detail */
  size?: number;
  /** accessible name: the localized `state.<state>` */
  label?: string;
  className?: string;
}

const reactAttr = (k: string) => k.replace(/-(\w)/g, (_m, c: string) => c.toUpperCase());

/** The state ring (K8): new dashed · to do empty · handed off dot · in progress half · to verify ! · done check ·
    won't do slash · discarded cross. */
export function StatusRing({ state, size = 14, label, className }: StatusRingProps) {
  return (
    <svg
      className={"sring s-" + state + (className ? " " + className : "")}
      width={size}
      height={size}
      viewBox={`0 0 ${size} ${size}`}
      strokeWidth={1.5}
      strokeLinecap="round"
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
    >
      {ringShapes(state, size).map((s, i) => {
        const a = Object.fromEntries(Object.entries(ringAttrs(s)).map(([k, v]) => [reactAttr(k), v]));
        return s.el === "circle" ? <circle key={i} {...a} /> : <path key={i} {...a} />;
      })}
    </svg>
  );
}

// ---------------------------------------------------------------- the state pill and its menu
type T = (key: string, params?: Record<string, string | number | null | undefined>) => string;

export interface StatePillProps {
  state: State;
  /** strings: state.<s>, state.menu, action.<a>, action.<a>.hint, action.done.hint_verify */
  t: T;
  onPick: (action: Action) => void;
  /** the host can start or hand off work: the menu offers "Hand off to agent…" (it opens the host's panel) */
  canHandOff?: boolean;
  /** where Restore goes (a discarded item's restore_to); its ring is shown on the Restore row */
  restoreTo?: State;
  /** the pill's text; default the state's name (e.g. "Handed off to Claude Code") */
  label?: string;
  /** pill = ring + name + chevron (detail, inspector); ring = the ring alone (list rows) */
  variant?: "pill" | "ring";
  size?: number;
  /** controlled open state (the S key opens it from outside) */
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  /** show the shortcut of each action (default true; a function picks per action) */
  keys?: boolean | ((action: Action) => boolean);
  /** ⌘⏎ rather than Ctrl ⏎ */
  mac?: boolean;
  /** shows the state without a menu */
  disabled?: boolean;
  id?: string;
  className?: string;
}

const KEY_LABEL: Record<string, string> = { a: "A", d: "D", r: "R", w: "W", x: "X" };

/** An item's state, clickable: a menu of only the actions valid from it — verb, one-line hint, shortcut. Arrow keys
    move, Enter picks, Esc closes (focus goes back to the pill), and the shortcut letters work while it is open. */
export function StatePill({ state, t, onPick, canHandOff, restoreTo, label, variant = "pill", size, open: openProp, onOpenChange,
  keys = true, mac, disabled, id, className }: StatePillProps) {
  const [openSelf, setOpenSelf] = useState(false);
  const open = !disabled && (openProp ?? openSelf);
  const setOpen = useCallback((v: boolean) => {
    setOpenSelf(v);
    onOpenChange?.(v);
  }, [onOpenChange]);
  const anchor = useRef<HTMLButtonElement>(null);
  const menuId = useId();
  const name = label ?? t(`state.${state}`);
  const ringSize = size ?? (variant === "pill" ? 16 : 14);
  const cls = (variant === "pill" ? "spill" : "spill-ring") + " s-" + state + (className ? " " + className : "");
  if (disabled)
    return variant === "pill" ? (
      <span className={cls + " static"} id={id}>
        <StatusRing state={state} size={ringSize} />
        <span className="spill-l">{name}</span>
      </span>
    ) : (
      <StatusRing state={state} size={ringSize} label={name} className={className} />
    );
  return (
    <>
      <button
        ref={anchor}
        type="button"
        id={id}
        className={cls + (open ? " open" : "")}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        aria-label={variant === "ring" ? `${name} · ${t("state.menu")}` : undefined}
        title={variant === "ring" ? name : t("state.menu")}
        onClick={(e) => {
          e.stopPropagation(); // a ring in a list row: don't also select / open the row
          setOpen(!open);
        }}
        onKeyDown={(e) => {
          if (e.key === "ArrowDown" && !open) {
            e.preventDefault();
            setOpen(true);
          }
        }}
      >
        <StatusRing state={state} size={ringSize} />
        {variant === "pill" && (
          <>
            <span className="spill-l">{name}</span>
            <Icon name="chevron-down" size={12} className="spill-ch" />
          </>
        )}
      </button>
      {open && (
        <StateMenu
          id={menuId}
          anchor={anchor}
          state={state}
          t={t}
          canHandOff={canHandOff}
          restoreTo={restoreTo}
          alignEnd={variant === "ring"}
          keys={keys}
          mac={mac}
          onClose={(refocus) => {
            setOpen(false);
            if (refocus) anchor.current?.focus();
          }}
          onPick={(a) => {
            setOpen(false);
            anchor.current?.focus();
            onPick(a);
          }}
        />
      )}
    </>
  );
}

function StateMenu({ id, anchor, state, t, canHandOff, restoreTo, alignEnd, keys, mac, onClose, onPick }: {
  id: string;
  anchor: RefObject<HTMLButtonElement | null>;
  state: State;
  t: T;
  canHandOff?: boolean;
  restoreTo?: State;
  keys: boolean | ((action: Action) => boolean);
  mac?: boolean;
  /** a bare ring: the menu lines up with its right edge when the ring sits in the right half of the window */
  alignEnd?: boolean;
  onClose: (refocus: boolean) => void;
  onPick: (a: Action) => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);
  const actions = menuFor(state, { canHandOff });
  const items = () => [...(ref.current?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])];

  // under the anchor (left edges lined up, or right edges for a ring); above it when there is no room below; in the window
  useLayoutEffect(() => {
    const a = anchor.current?.getBoundingClientRect();
    const m = ref.current;
    if (!a || !m) return;
    const w = m.offsetWidth, h = m.offsetHeight, gap = 6, pad = 8;
    let top = a.bottom + gap;
    if (top + h > innerHeight - pad && a.top - gap - h >= pad) top = a.top - gap - h;
    const end = alignEnd && a.left + a.width / 2 > innerWidth / 2;
    const left = Math.max(pad, Math.min(end ? a.right - w : a.left, innerWidth - w - pad));
    setPos({ left, top: Math.max(pad, top) });
  }, [anchor]);
  // the first action takes focus once the menu is placed (a hidden element can't)
  const placed = pos !== null;
  useLayoutEffect(() => {
    if (placed) items()[0]?.focus({ preventScroll: true });
  }, [placed]);

  useEffect(() => {
    const down = (e: PointerEvent) => {
      const n = e.target as Node;
      if (!ref.current?.contains(n) && !anchor.current?.contains(n)) onClose(false);
    };
    const away = (e: Event) => {
      if (!ref.current?.contains(e.target as Node)) onClose(false);
    };
    document.addEventListener("pointerdown", down, true);
    window.addEventListener("scroll", away, true);
    window.addEventListener("resize", away);
    window.addEventListener("blur", away);
    return () => {
      document.removeEventListener("pointerdown", down, true);
      window.removeEventListener("scroll", away, true);
      window.removeEventListener("resize", away);
      window.removeEventListener("blur", away);
    };
  }, [anchor, onClose]);

  const onKey = (e: ReactKeyboardEvent) => {
    if (e.nativeEvent.isComposing) return;
    const list = items();
    const at = list.indexOf(document.activeElement as HTMLElement);
    const go = (k: number) => list[(k + list.length) % list.length]?.focus();
    if (e.key === "Tab") return onClose(false);
    e.preventDefault(); // nothing typed here reaches the page's shortcuts
    e.stopPropagation();
    if (e.key === "ArrowDown") go(at + 1);
    else if (e.key === "ArrowUp") go(at < 0 ? -1 : at - 1);
    else if (e.key === "Home") go(0);
    else if (e.key === "End") go(-1);
    else if (e.key === "Escape") onClose(true);
    else if (e.key === "Enter" && !(e.metaKey || e.ctrlKey)) list[at]?.click();
    else if (e.key === " ") list[at]?.click();
    else {
      const a = actionForKey(state, e.nativeEvent);
      if (a && actions.includes(a)) onPick(a);
    }
  };

  const target = (a: Action): State => TRANSITIONS[a].to ?? restoreTo ?? "new";
  const hint = (a: Action) => t(a === "done" && state === "to_verify" ? "action.done.hint_verify" : `action.${a}.hint`);
  const key = (a: Action) => {
    const k = TRANSITIONS[a].key;
    if (k === "cmd+enter") return mac ? ["⌘", "⏎"] : ["Ctrl", "⏎"];
    return [KEY_LABEL[k] ?? k.toUpperCase()];
  };

  return createPortal(
    <div
      ref={ref}
      id={id}
      className="smenu"
      role="menu"
      aria-label={t("state.menu")}
      style={pos ? { left: pos.left, top: pos.top } : { left: 0, top: 0, visibility: "hidden" }}
      onKeyDown={onKey}
    >
      {actions.map((a) => (
        <button
          key={a}
          type="button"
          role="menuitem"
          tabIndex={-1}
          className={"smenu-i a-" + a}
          data-action={a}
          onClick={() => onPick(a)}
          onPointerMove={(e) => document.activeElement !== e.currentTarget && e.currentTarget.focus({ preventScroll: true })}
        >
          <StatusRing state={target(a)} size={14} />
          <span className="smenu-t">
            <span className="smenu-v">{menuCase(t(`action.${a}`))}</span>
            <span className="smenu-h">{hint(a)}</span>
          </span>
          {(typeof keys === "function" ? keys(a) : keys) && (
            <span className="smenu-k" aria-hidden="true">
              {key(a).map((k) => (
                <kbd key={k}>{k}</kbd>
              ))}
            </span>
          )}
        </button>
      ))}
    </div>,
    document.body,
  );
}
