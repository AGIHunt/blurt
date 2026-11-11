// The parts every Settings pane is made of — the Mac's Settings/SettingsKit.swift on one grid (system.md §3.4): a
// page (its pane's name, an optional lead line), open sections with a heading in the primary ink and hairlines
// between rows, rows with a title and a one-line description on the left and one control on the right, every pop-up
// the same width so the controls share one column, a switch in the brand accent, a longer explanation behind ⓘ.
// Titles and descriptions come from the catalog (catalog.ts) so search and page can't drift apart.
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { Icon, type IconName } from '@blurt/icons';
import { i18n, t } from '../i18n';
import { entry, onLinux, pane, SECTIONS, setDesk, textIn, type Key, type Lang, type PaneId } from './catalog';
import { Menu, type MenuAt, type MenuEntry } from '../components/Menu';

/** A settings string (the Mac's key under "st."), its placeholders {1} {2} … filled in order. */
/** The desktop the app runs on (catalog `setDesk`): on Linux a string's `.linux` variant wins. */
export const setPlatform = setDesk;
export function S(key: Key, ...args: (string | number)[]): string {
  const p: Record<string, string> = {};
  args.forEach((a, i) => (p[String(i + 1)] = typeof a === 'number' ? i18n().formatNumber(a) : a));
  if (onLinux() && i18n().has(`st.${key}.linux`)) return t(`st.${key}.linux` as Key, p);
  return i18n().has(`st.${key}`) ? t(`st.${key}`, p) : t(key, p);
}
export const lang = () => i18n().lang as Lang;
const T = (k: Key | undefined) => (k ? textIn(k, lang()) : undefined);

/** The row a search hit, a link or the tray asked for: scrolled to and flashed in the brand tint. */
let flashListener: ((id: string) => void) | null = null;
let pendingFlash: string | null = null;
export function requestFlash(id: string) {
  pendingFlash = id;
  flashListener?.(id);
}
function useFlash(root: React.RefObject<HTMLDivElement | null>) {
  useEffect(() => {
    const go = (id: string) => {
      // a page lays itself out over a few frames (and loads into it): try until the row is there
      let n = 0;
      const tick = () => {
        const el = root.current?.querySelector<HTMLElement>(`[data-setting="${CSS.escape(id)}"]`);
        if (el) {
          el.scrollIntoView({ block: el.dataset.kind === 'section' ? 'start' : 'center' });
          el.classList.remove('st-flash');
          void el.offsetWidth;
          el.classList.add('st-flash');
          pendingFlash = null;
        } else if (n++ < 20) setTimeout(tick, 60);
      };
      tick();
    };
    flashListener = go;
    if (pendingFlash) go(pendingFlash);
    return () => {
      if (flashListener === go) flashListener = null;
    };
  }, [root]);
}

export function Page({ id, lead, children }: { id: PaneId; lead?: ReactNode; children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  useFlash(ref);
  return (
    <div className="st-page" ref={ref} data-testid={`settings-pane-${id}`}>
      <div className="st-col">
        <h1 className="st-title">{T(pane(id)!.title)}</h1>
        {lead && <div className="st-lead">{lead}</div>}
        {children}
      </div>
    </div>
  );
}

/** A section: its heading (from the catalog, or `title`; "" for none) over its rows, an optional footnote. */
export function Group({ id, title, footer, accessory, children }: { id: string; title?: string; footer?: ReactNode; accessory?: ReactNode; children: ReactNode }) {
  const head = title ?? T(SECTIONS[id]);
  return (
    <section className="st-group" data-setting={id} data-kind="section">
      {(head || accessory) && (
        <h2 className="st-head">
          <span>{head}</span>
          {accessory}
        </h2>
      )}
      <div className="st-rows">{children}</div>
      {footer && <p className="st-foot">{footer}</p>}
    </section>
  );
}

/** ⓘ after a row's title: the longer explanation, on hover or focus. */
export function InfoTip({ text }: { text: string }) {
  const [open, setOpen] = useState(false);
  return (
    <span className="st-info" onMouseEnter={() => setOpen(true)} onMouseLeave={() => setOpen(false)}>
      <button type="button" className="st-info-btn" aria-label={text} onFocus={() => setOpen(true)} onBlur={() => setOpen(false)} onClick={() => setOpen((o) => !o)}>
        <Icon name="info" size={13} />
      </button>
      {open && <span className="st-pop" role="tooltip">{text}</span>}
    </span>
  );
}

/** A setting: title and description on the left (the catalog's, or the overrides), the control on the right. */
export function Row({ id, title, detail, warn, help, icon, children }: {
  id: string;
  title?: ReactNode;
  detail?: ReactNode | null;
  warn?: boolean;
  help?: string | null;
  icon?: IconName;
  children?: ReactNode;
}) {
  const e = entry(id);
  const more = help === null ? undefined : help ?? T(e?.more);
  const d = detail === null ? undefined : detail ?? T(e?.detail);
  return (
    <div className="st-row" data-setting={id}>
      {icon && <span className="st-icon"><Icon name={icon} size={16} /></span>}
      <div className="st-text">
        <div className="st-row-title">
          <span>{title ?? T(e?.title)}</span>
          {more && <InfoTip text={more} />}
        </div>
        {d && <div className={`st-detail ${warn ? 'warn' : ''}`}>{warn && <Icon name="warning" size={12} />}{d}</div>}
      </div>
      {children && <div className="st-ctl">{children}</div>}
    </div>
  );
}

/** A plain line in a section (a project, a model, a service): no catalog entry of its own. */
export function Line({ icon, glyph, title, detail, warn, badge, children, flash }: {
  icon?: IconName;
  /** a picture of its own in the icon column (a project's folder in its colour) */
  glyph?: ReactNode;
  title: ReactNode;
  detail?: ReactNode;
  warn?: boolean;
  badge?: string;
  children?: ReactNode;
  flash?: string;
}) {
  return (
    <div className="st-row" data-setting={flash}>
      {glyph ? <span className="st-icon">{glyph}</span> : icon && <span className="st-icon"><Icon name={icon} size={16} /></span>}
      <div className="st-text">
        <div className="st-row-title">
          <span>{title}</span>
          {badge && <span className="st-badge">{badge}</span>}
        </div>
        {detail && <div className={`st-detail ${warn ? 'warn' : ''}`}>{warn && <Icon name="warning" size={12} />}{detail}</div>}
      </div>
      {children && <div className="st-ctl">{children}</div>}
    </div>
  );
}

/** A switch in the brand accent (the Mac's BrandSwitchStyle). */
export function Switch({ on, set, label, disabled }: { on: boolean; set: (v: boolean) => void; label: string; disabled?: boolean }) {
  return (
    <button type="button" role="switch" aria-checked={on} aria-label={label} disabled={disabled} className={`st-switch ${on ? 'on' : ''}`} onClick={() => set(!on)}>
      <span />
    </button>
  );
}

export function Toggle({ id, on, set, detail, warn }: { id: string; on: boolean; set: (v: boolean) => void; detail?: ReactNode | null; warn?: boolean }) {
  return (
    <Row id={id} detail={detail} warn={warn}>
      <Switch on={on} set={set} label={T(entry(id)?.title) ?? id} />
    </Row>
  );
}

/** A pop-up at the page's one control width (the Mac's ChoicePopup); `dividers`: a line before these indexes. */
export function Popup<V extends string | number | boolean>({ label, value, choices, onChange, wide, dividers = [], disabled, hints }: {
  label: string;
  disabled?: boolean;
  value: V;
  choices: [V, string][];
  onChange: (v: V) => void;
  wide?: boolean;
  dividers?: number[];
  /** a second line under a choice in the open menu (what it means) */
  hints?: (string | undefined)[];
}) {
  // the app's own themed menu (Menu.tsx), not the WebView's <select>: Chromium draws that list in the light theme
  // whatever the window's theme (a dark window got a white list with white text), with square corners and no check.
  // The menu hangs under the button, at least its width, the current choice checked (the Mac's NSPopUpButton menu);
  // its right edge on the button's, so a longer choice or hint grows it leftward and never past the column's edge
  // (round-2 gate: welcome.2-key-menu).
  const idx = Math.max(0, choices.findIndex(([v]) => v === value));
  const btn = useRef<HTMLButtonElement>(null);
  const [at, setAt] = useState<MenuAt | null>(null);
  const open = () => btn.current && setAt({ x: 0, y: 0, anchor: btn.current, align: 'end', minWidth: btn.current.offsetWidth });
  const entries: MenuEntry[] = choices.flatMap(([v, l], i): MenuEntry[] => [
    ...(dividers.includes(i) ? [{ kind: 'separator' } as MenuEntry] : []),
    { label: l, note: hints?.[i], checked: i === idx, run: () => v !== value && onChange(v) },
  ]);
  return (
    <span className={`st-popup ${wide ? 'wide' : ''}`}>
      <button
        ref={btn}
        type="button"
        className="st-popup-btn"
        aria-haspopup="menu"
        aria-expanded={!!at}
        aria-label={label}
        data-tip={choices[idx]?.[1]}
        data-tip-trunc
        disabled={disabled}
        onClick={() => (at ? setAt(null) : open())}
        onKeyDown={(e) => {
          if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
            e.preventDefault();
            open();
          }
        }}
      >
        <span className="st-popup-v">{choices[idx]?.[1]}</span>
      </button>
      <Icon name="chevron-down" size={12} />
      {at && <Menu entries={entries} at={at} label={label} onClose={() => setAt(null)} />}
    </span>
  );
}

/** A quiet text button (the About line's User Guide, a row's Change…). */
export function TextLink({ children, onClick, ink }: { children: ReactNode; onClick: () => void; ink?: boolean }) {
  return (
    <button type="button" className={`st-link ${ink ? 'ink' : ''}`} onClick={onClick}>
      {children}
    </button>
  );
}
