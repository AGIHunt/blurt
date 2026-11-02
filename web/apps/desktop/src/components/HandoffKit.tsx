// The parts the hand-off panels share (Hand Off to Agent / New Session, Review Changes) — the Mac's HandoffKit.swift:
// one family with Settings — the same rounded box, rows over hairlines with one trailing control, the 16 px status disc
// in a notice — so a panel reads like a page of Settings brought forward. A panel is a dialog with no window buttons
// (Esc and Cancel close it), 480 px wide, 24 px insets, a 15 px title; its one default is the filled button in the sheet
// accent (#0B735E in both themes), the plain grey one while disabled; its switches take the same green. Why Start can't
// go is one PanelNotice under the items, with the way out as the default.
import { useEffect, useRef, type ReactNode } from 'react';
import { KindIcon } from '@blurt/ui/react';
import { Icon } from '@blurt/icons';
import { t } from '../i18n';
import { Popup } from '../settings/kit';
import '../settings/settings.css';

/** The dialog: a scrim, the panel on it. Esc closes (unless `busy`); Enter is the default button's (the native default:
    whatever has the focus, unless it's a control that takes Enter itself) — `enter` false where a bare Enter must not
    act (Review Changes: Merge is Ctrl+Enter). The panel takes the focus, or the control marked data-autofocus. */
export function Panel({ label, onClose, children, width = 480, busy, testId, onKey, enter = true }: {
  label: string;
  onClose: () => void;
  children: ReactNode;
  width?: number;
  busy?: boolean;
  testId?: string;
  /** keys the panel takes first (Ctrl+Enter: Merge) */
  onKey?: (e: React.KeyboardEvent) => boolean | void;
  enter?: boolean;
}) {
  const el = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const back = document.activeElement as HTMLElement | null;
    if (!el.current?.contains(document.activeElement)) (el.current?.querySelector<HTMLElement>('[data-autofocus]') ?? el.current)?.focus({ preventScroll: true });
    return () => back?.focus?.({ preventScroll: true });
  }, []);
  return (
    <div className="overlay hk-scrim" onMouseDown={(e) => e.target === e.currentTarget && !busy && onClose()}>
      <div ref={el} className="hk-panel" role="dialog" aria-modal="true" aria-label={label} tabIndex={-1} style={{ width }} data-testid={testId}
        onKeyDown={(e) => {
          if (onKey?.(e)) return;
          if (e.key === 'Escape' && !busy) {
            e.stopPropagation();
            onClose();
          } else if (e.key === 'Enter' && enter && !e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey) {
            const tgt = e.target as HTMLElement;
            if (tgt.closest('button, select, input, textarea, a, [role="checkbox"], [role="menu"]')) return;
            const all = el.current?.querySelectorAll<HTMLButtonElement>('.hk-foot .hk-default, .hk-foot [data-default]');
            const def = all?.[all.length - 1];
            if (def && !def.disabled) {
              e.preventDefault();
              e.stopPropagation();
              def.click();
            }
          }
        }}>
        {children}
      </div>
    </div>
  );
}

/** Settings' rounded box: rows over hairlines; an optional heading above it with an accessory at its right. */
export function PanelBox({ heading, accessory, children, className }: { heading?: ReactNode; accessory?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <div className={`hk-boxwrap ${className ?? ''}`}>
      {heading != null && (
        <div className="hk-box-head">
          <span>{heading}</span>
          <span className="grow" />
          {accessory}
        </div>
      )}
      <div className="hk-box">{children}</div>
    </div>
  );
}

/** A settings row: the title, a one-line description under it, one trailing control. */
export function SettingRow({ title, detail, help, children }: { title: string; detail?: ReactNode; help?: string; children?: ReactNode }) {
  return (
    <div className="hk-row hk-setting" title={help}>
      <span className="hk-setting-txt">
        <span className="hk-setting-title">{title}</span>
        {detail != null && detail !== '' && <span className="hk-setting-detail">{detail}</span>}
      </span>
      <span className="hk-setting-ctl">{children}</span>
    </div>
  );
}

/** The 16 px status disc (its shape twin of the ring): attention "!", error "×", or the quiet "i". */
export function StatusDot({ tone, size = 16 }: { tone: 'warn' | 'bad' | 'off'; size?: number }) {
  return (
    <span className={`hk-dot t-${tone}`} style={{ width: size, height: size, fontSize: size * 0.68 }} aria-hidden="true">
      {tone === 'bad' ? '×' : tone === 'off' ? 'i' : '!'}
    </span>
  );
}

/** Why Start can't go, or what must be read before it: the disc, one regular sentence, at most one small action. */
export function PanelNotice({ text, tone = 'warn', children }: { text: string; tone?: 'warn' | 'bad' | 'off'; children?: ReactNode }) {
  return (
    <div className={`hk-notice t-${tone}`} role="status">
      <StatusDot tone={tone} />
      <span className="hk-notice-txt">{text}</span>
      {children}
    </div>
  );
}

/** The brand spinner (BrandSpinnerView). */
export const Spinner = ({ size = 10, label }: { size?: number; label?: string }) => (
  <span className="hk-spin" style={{ width: size, height: size }} role={label ? 'img' : undefined} aria-label={label} aria-hidden={label ? undefined : true} />
);

/** The footer's left slot: one quiet line, or the spinner and what is going on — the one place a panel says it's busy. */
export function PanelFootnote({ text, busy }: { text?: string | null; busy?: string | null }) {
  return (
    <span className="hk-footnote" aria-live="polite">
      {busy ? (
        <>
          <Spinner label={busy} />
          <span>{busy}</span>
        </>
      ) : (
        text ?? ''
      )}
    </span>
  );
}

/** "› Options": quieter than the title, a toggle for rare settings; what it holds said small after it. */
export function PanelDisclosure({ title, open, onToggle, inset = true, size = 13, children }: {
  title: string;
  open: boolean;
  onToggle: () => void;
  inset?: boolean;
  size?: number;
  children?: ReactNode;
}) {
  return (
    <button type="button" className={`hk-disclosure ${inset ? 'inset' : ''}`} aria-expanded={open} onClick={onToggle} style={{ fontSize: size }}>
      <Icon name="chevron-right" size={10} className={open ? 'open' : ''} />
      <span>{title}</span>
      {children && <span className="hk-disclosure-more">{children}</span>}
    </button>
  );
}

export interface PanelItem {
  uid: string;
  ref: string;
  title: string;
  kind: string;
}

/** The id column: wide enough for "IOS-123", the same in every panel (wider only for an id that doesn't fit). */
export const refWidth = (items: PanelItem[]) => Math.max(40, ...items.map((i) => Math.ceil(i.ref.length * 7.4) + 2));

/** One item as the item list draws it: the kind icon in its colour, the id in a fixed tabular column, the title. */
export function ItemLine({ item, width = 40 }: { item: PanelItem; width?: number }) {
  return (
    <span className="hk-item">
      <KindIcon kind={item.kind} size={16} title={t(`kind.${item.kind}`)} />
      <span className="hk-item-ref" style={{ width }}>{item.ref}</span>
      <span className={`hk-item-title ${item.title ? '' : 'dim'}`} title={item.title}>{item.title || t('ses.dispatch.untitled')}</span>
    </span>
  );
}

const BUILT_IN = ['issue', 'idea', 'note', 'task'];

/** What a list of items holds: each kind's 14 px icon and its count. */
export function KindSummary({ items }: { items: PanelItem[] }) {
  const kinds = [...BUILT_IN.filter((k) => items.some((i) => i.kind === k)), ...[...new Set(items.map((i) => i.kind))].filter((k) => !BUILT_IN.includes(k)).sort()];
  return (
    <span className="hk-kinds">
      {kinds.map((k) => {
        const n = items.filter((i) => i.kind === k).length;
        return (
          <span key={k} className="hk-kind" aria-label={`${n} ${t(`kind.${k}`)}`}>
            <KindIcon kind={k} size={14} />
            {n}
          </span>
        );
      })}
    </span>
  );
}

/** The kit's pop-up at Settings' width: Settings' own themed pop-up (kit Popup → Menu.tsx), not the WebView's
    <select> — that drew a heavy black chevron, square corners and, in dark mode, a white list (main-window.md 14.x). */
export function ChoicePopup<T extends string>({ label, value, choices, onChange, testId, dividers = [] }: {
  label: string;
  value: T;
  choices: [T, string][];
  onChange: (v: T) => void;
  testId?: string;
  /** a separator before these indexes */
  dividers?: number[];
}) {
  return (
    <span className="hk-popup-k" data-testid={testId}>
      <Popup label={label} value={value} choices={choices} onChange={onChange} dividers={dividers} />
    </span>
  );
}

/** A panel's switch, in the sheet accent. */
export function PanelSwitch({ label, on, disabled, onChange }: { label: string; on: boolean; disabled?: boolean; onChange: (on: boolean) => void }) {
  return (
    <label className={`hk-switch ${disabled ? 'off' : ''}`}>
      <input type="checkbox" role="switch" aria-label={label} checked={on} disabled={disabled} onChange={(e) => onChange(e.target.checked)} />
      <span />
    </label>
  );
}

/** A command to copy (the update or sign-in command), in mono. */
export function CommandText({ text }: { text: string }) {
  return (
    <code className="hk-command" title={text} onClick={(e) => {
      const r = document.createRange();
      r.selectNodeContents(e.currentTarget);
      const s = getSelection();
      s?.removeAllRanges();
      s?.addRange(r);
    }}>{text}</code>
  );
}
