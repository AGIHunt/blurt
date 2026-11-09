// Settings → Phone (the Mac's Settings/RemotePane.swift, for any phone): pair a phone with the QR code, see which
// phones are paired and which one is connected and how, remove one, let the phone show this screen, and the relay
// for away from home. The code shows only while Add Phone… is open: with no paired phone Blurt doesn't listen at
// all. A new phone always needs a yes here, with the same six digits the phone shows; Allow is never the default
// (Return and Esc say no, and a click in the first moment after the question appears answers nothing). The same
// question shows over the whole window when this pane isn't open (PhoneAsk). The host: src-tauri/src/remote.rs,
// docs/design/remote-protocol.md §The desktop app.
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { Icon } from '@blurt/icons';
import { api, type AppStatus, type RemoteStatus } from '../api';
import { i18n } from '../i18n';
import { Menu, type MenuAt } from '../components/Menu';
import { Group, Line, Page, Row, S, TextLink, Toggle } from './kit';
import { APP_PAGES, apply, groupDigits, relayAddress, timeLeft, useNow, usePhonePaneMounted, usePhonePaneOpen, useRemoteStatus } from './phone';
import './settings.css';

type RelayState = 'idle' | 'checking' | 'ok' | 'failed' | 'invalid';

export function PhonePane({ status }: { status: AppStatus }) {
  const r = useRemoteStatus();
  usePhonePaneMounted();
  const [adding, setAddingState] = useState(false);
  const [removing, setRemoving] = useState<RemoteStatus['devices'][number] | null>(null);
  const addingRef = useRef(false);

  const setAdding = (on: boolean) => {
    addingRef.current = on;
    setAddingState(on);
    void apply(api.remoteShowPairing(on)).catch(() => {});
  };
  // leaving the pane takes the code down (the Mac's stop())
  useEffect(() => () => {
    if (addingRef.current) void apply(api.remoteShowPairing(false)).catch(() => {});
  }, []);
  // a phone just paired from the code on screen: the code's job is done
  const count = useRef<number | null>(null);
  useEffect(() => {
    if (!r) return;
    if (count.current != null && r.devices.length > count.current && addingRef.current) setAdding(false);
    count.current = r.devices.length;
  }, [r?.devices.length]);

  if (!r) return <Page id="phone"><p className="st-lead">{S('settings.loading')}</p></Page>;
  const win = status.platform === 'win';
  return (
    <Page id="phone">
      {!r.canControl && r.devices.length > 0 && (
        <Notice title={S(win ? 'phone.control.win' : 'phone.control.linux')} detail={S(win ? 'phone.control.win.detail' : 'phone.control.linux.detail')} />
      )}
      {r.problem && !adding && <Notice title={r.problem} />}

      <Group id="phone.phones">
        {r.devices.map((d) => <DeviceRow key={d.id} d={d} r={r} onRemove={() => setRemoving(d)} />)}
        {r.asking ? (
          <AskBlock ask={r.asking} />
        ) : adding ? (
          <PairPanel r={r} onCancel={() => setAdding(false)} onRenew={() => void apply(api.remoteShowPairing(true)).catch(() => {})} />
        ) : (
          <Row id="phone.add">
            <GetApp />
            <button onClick={() => setAdding(true)} data-testid="phone-add">{S('phone.add')}</button>
          </Row>
        )}
      </Group>

      <Group id="phone.options">
        <Toggle id="phone.screen" on={r.screenAllowed} set={(v) => void apply(api.remoteSetScreenAllowed(v)).catch(() => {})} />
      </Group>

      <RelayGroup r={r} />

      {removing && (
        <Confirm title={S('phone.remove.title', removing.name)} detail={S('phone.remove.detail')} cancel={S('phone.cancel')} ok={S('phone.remove')}
          onClose={() => setRemoving(null)}
          onOk={() => {
            const id = removing.id;
            setRemoving(null);
            void apply(api.remoteRemoveDevice(id)).catch(() => {});
          }} />
      )}
    </Page>
  );
}

/** The one thing that stops the phone working, on the pane's first screen (Dictation's no-model notice). */
function Notice({ title, detail }: { title: string; detail?: string }) {
  return (
    <div className="st-notice warn st-phone-notice" role="status" data-testid="phone-notice">
      <Icon name="warning" size={16} />
      <span className="grow">
        <span className="st-phone-notice-title">{title}</span>
        {detail && <span className="st-phone-notice-detail">{detail}</span>}
      </span>
    </div>
  );
}

function DeviceRow({ d, r, onRemove }: { d: RemoteStatus['devices'][number]; r: RemoteStatus; onRemove: () => void }) {
  const on = r.connected?.id === d.id ? r.connected : null;
  let detail: ReactNode;
  if (on) {
    const how = [S(`phone.route.${on.route}`), on.screen ? S('phone.showing_screen') : ''].filter(Boolean).join(' · ');
    detail = <span className="st-phone-live"><span className="st-phone-dot" aria-hidden />{S('phone.connected', how)}</span>;
  } else {
    detail = d.lastSeen ? S('phone.last_used', i18n().formatRelative(d.lastSeen)) : S('phone.not_connected');
  }
  // no icon: the names line up with Blurt for Phones under them, as on the Mac
  return (
    <Line title={d.name} detail={detail} flash={`phone.device.${d.id}`}>
      <button onClick={onRemove} aria-label={`${S('phone.remove')} ${d.name}`}>{S('phone.remove')}</button>
    </Line>
  );
}

/** Get the App: the build steps for each phone, until the app is in the stores. */
function GetApp() {
  const [at, setAt] = useState<MenuAt | null>(null);
  const open = (url: string) => void api.openUrl(url).catch(() => {});
  return (
    <>
      <button type="button" className="st-link ink" aria-haspopup="menu" aria-expanded={!!at} data-testid="phone-get-app"
        onClick={(e) => setAt(at ? null : { x: 0, y: 0, anchor: e.currentTarget, align: 'end' })}>{S('phone.get_app')}</button>
      {at && (
        <Menu at={at} label={S('phone.get_app')} onClose={() => setAt(null)}
          entries={[{ label: S('phone.get_app.ios'), run: () => open(APP_PAGES.ios) }, { label: S('phone.get_app.android'), run: () => open(APP_PAGES.android) }]} />
      )}
    </>
  );
}

/** The code to scan, its time left, and the way out. A code past its time is dimmed with New Code beside it. */
function PairPanel({ r, onCancel, onRenew }: { r: RemoteStatus; onCancel: () => void; onRenew: () => void }) {
  const p = r.pairing;
  const now = useNow(!!p);
  const expired = !!p && p.expiresAt <= now;
  const src = p ? `data:image/svg+xml;charset=utf-8,${encodeURIComponent(p.qrSvg)}` : null;
  return (
    <div className="st-row st-phone-pair" data-setting="phone.add" data-testid="phone-pairing">
      <div className={`st-phone-qr ${expired ? 'expired' : ''}`}>
        {src ? <img src={src} alt={S('phone.scan')} draggable={false} /> : <span className="st-spin" aria-hidden />}
      </div>
      <div className="st-phone-pair-text">
        <div className="st-phone-pair-title">{S('phone.scan')}</div>
        <div className="st-detail">{S('phone.scan.detail')}</div>
        {p && (expired
          ? <div className="st-detail warn" data-testid="phone-expired"><Icon name="warning" size={12} />{S('phone.scan.expired')}</div>
          : <div className="st-detail st-phone-left" aria-live="off">{S('phone.scan.left', timeLeft(p.expiresAt, now))}</div>)}
        {r.problem && <div className="st-detail warn"><Icon name="warning" size={12} />{r.problem}</div>}
        <div className="st-phone-pair-actions">
          {expired && <button className="primary" onClick={onRenew} data-testid="phone-renew">{S('phone.scan.new')}</button>}
          <button onClick={onCancel}>{S('phone.cancel')}</button>
          <span className="grow" />
          <span className="st-phone-noapp">
            <span>{S('phone.no_app')}</span>
            <TextLink ink onClick={() => void api.openUrl(APP_PAGES.ios).catch(() => {})}>{S('phone.get_app.ios')}</TextLink>
            <span aria-hidden>·</span>
            <TextLink ink onClick={() => void api.openUrl(APP_PAGES.android).catch(() => {})}>{S('phone.get_app.android')}</TextLink>
          </span>
        </div>
      </div>
    </div>
  );
}

/** A click on Allow counts only once the question has been on screen a moment, and only from the mouse (a key press
 *  meant for something else must never let a phone in). */
export function useAllow(key: string) {
  const since = useRef(Date.now());
  useEffect(() => {
    since.current = Date.now();
  }, [key]);
  return (e: React.MouseEvent) => e.detail > 0 && Date.now() - since.current > 600;
}

/** `digits` ties the answer to the phone that asked: a late click can't answer another one that started asking since. */
const answer = (yes: boolean, digits: string) => void apply(api.remoteAnswerPairing(yes, digits)).catch(() => {});

/** A phone asking, in the pane: its name, the digits large, where it came from; Don't Allow and Allow, neither default. */
function AskBlock({ ask }: { ask: NonNullable<RemoteStatus['asking']> }) {
  const ok = useAllow(ask.digits);
  return (
    <div className="st-phone-ask" role="group" aria-labelledby="phone-ask-title" data-setting="phone.ask" data-testid="phone-ask"
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === 'Escape') {
          e.preventDefault();
          answer(false, ask.digits);
        }
      }}>
      <span className="st-phone-ask-icon"><Icon name="phone" size={20} /></span>
      <div className="st-phone-ask-body">
        <div className="st-phone-ask-title" id="phone-ask-title">{S('phone.ask.title', ask.device)}</div>
        <div className="st-detail">{S('phone.ask.detail')} {S(ask.viaRelay ? 'phone.ask.relay' : 'phone.ask.local')}</div>
        <div className="st-phone-ask-foot">
          <span className="st-phone-digits" data-testid="phone-digits" aria-label={ask.digits.split('').join(' ')}>{groupDigits(ask.digits)}</span>
          <span className="grow" />
          <button onClick={() => answer(false, ask.digits)}>{S('phone.ask.no')}</button>
          <button onClick={(e) => ok(e) && answer(true, ask.digits)} data-testid="phone-allow">{S('phone.ask.yes')}</button>
        </div>
      </div>
    </div>
  );
}

/** Away from Home: the relay address (Return or leaving the field uses it and tries it), and Copy Instructions. */
function RelayGroup({ r }: { r: RemoteStatus }) {
  const [text, setText] = useState(r.relay.address ?? '');
  const [state, setState] = useState<RelayState>('idle');
  const [copied, setCopied] = useState(false);
  const committed = useRef(r.relay.address ?? '');
  const field = useRef<HTMLInputElement>(null);
  const cur = useRef(text);
  cur.current = text;

  // a phone filled it in (or another window changed it): show it, unless it's being typed in
  useEffect(() => {
    const a = r.relay.address ?? '';
    if (a === committed.current || document.activeElement === field.current) return;
    committed.current = a;
    setText(a);
    setState('idle');
  }, [r.relay.address]);

  const commit = () => {
    const typed = text.trim();
    if (typed === committed.current) return; // Return, and then leaving the field
    if (!typed) {
      committed.current = '';
      setText('');
      setState('idle');
      void apply(api.remoteSetRelay('')).catch(() => {});
      return;
    }
    const a = relayAddress(typed);
    if (!a) return setState('invalid');
    committed.current = a;
    setText(a);
    setState('checking');
    apply(api.remoteSetRelay(a)).then(
      () => api.remoteCheckRelay(a).then((ok) => cur.current === a && setState(ok ? 'ok' : 'failed'), () => cur.current === a && setState('failed')),
      () => {
        committed.current = r.relay.address ?? '';
        if (cur.current === a) setState('invalid');
      },
    );
  };

  const copy = async () => {
    try {
      await api.copyText(await api.remoteRelayInstructions());
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      /* nothing to say: the button stays as it was */
    }
  };

  // what's said under the field: what this field is, or what became of the address
  const saved = !!r.relay.address && text === r.relay.address;
  let line: string | undefined;
  let warn = false;
  if (state === 'checking') line = S('phone.relay.checking');
  else if (state === 'ok') line = S('phone.relay.ok');
  else if (state === 'failed') (line = S('phone.relay.failed')), (warn = true);
  else if (state === 'invalid') (line = S('phone.relay.invalid')), (warn = true);
  else if (saved && r.relay.fromPhone) (line = S(r.relay.reachable === false ? 'phone.relay.from_phone_failed' : 'phone.relay.from_phone')), (warn = r.relay.reachable === false);
  else if (saved && r.relay.reachable === false) (line = S('phone.relay.failed')), (warn = true);

  return (
    <Group id="phone.relay">
      <Row id="phone.relay.address" detail={line} warn={warn}>
        <input ref={field} className="st-field st-phone-relay" type="text" spellCheck={false} autoComplete="off" autoCapitalize="off"
          placeholder="wss://relay.example.com" aria-label={S('phone.relay')} value={text} data-testid="phone-relay"
          onChange={(e) => {
            setText(e.target.value);
            // whatever was said about the last address doesn't hold for this one
            if (e.target.value !== committed.current) setState('idle');
          }}
          onKeyDown={(e) => {
            if (e.key === 'Enter') commit();
            else if (e.key === 'Escape' && text !== committed.current) {
              e.preventDefault();
              setText(committed.current);
              setState('idle');
            }
          }}
          onBlur={commit} />
      </Row>
      <Row id="phone.relay.help">
        <button onClick={copy} data-testid="phone-copy">{copied ? S('phone.relay.copied') : S('phone.relay.copy')}</button>
      </Row>
    </Group>
  );
}

/** A confirm on the app's ContentDialog (the Clear History sheet): Cancel is the default, the destructive one tinted. */
function Confirm({ title, detail, cancel, ok, onOk, onClose }: { title: string; detail: string; cancel: string; ok: string; onOk: () => void; onClose: () => void }) {
  return (
    <div className="overlay" onClick={onClose}>
      <div className="sheet dict-confirm" role="alertdialog" aria-modal="true" aria-labelledby="phone-confirm-title" onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => e.key === 'Escape' && (e.preventDefault(), onClose())}>
        <h3 id="phone-confirm-title">{title}</h3>
        <p>{detail}</p>
        <div className="dict-confirm-foot">
          <button autoFocus className="dict-confirm-cancel" onClick={onClose}>{cancel}</button>
          <button className="dict-danger-tint" onClick={onOk}>{ok}</button>
        </div>
      </div>
    </div>
  );
}

/** The phone's question over the whole window, wherever it is (App.tsx shows it once), while Settings → Phone isn't
 *  open: that pane asks in place. Don't Allow has the focus; Return, Esc and a click outside say no; only a click on
 *  Allow says yes. Gone when the host stops asking (answered, timed out, the phone went away). */
export function PhoneAsk() {
  const r = useRemoteStatus();
  const paneOpen = usePhonePaneOpen();
  const ask = r?.asking ?? null;
  const ok = useAllow(ask?.digits ?? '');
  if (!ask || paneOpen) return null;
  return (
    <div className="overlay" onClick={() => answer(false, ask.digits)}>
      <div className="sheet dict-confirm phone-ask-sheet" role="alertdialog" aria-modal="true" aria-labelledby="phone-ask-sheet-title" data-testid="phone-ask-dialog"
        onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === 'Escape') {
            e.preventDefault();
            answer(false, ask.digits);
          }
        }}>
        <div className="agent-ask-head">
          <span className="phone-ask-icon"><Icon name="phone" size={22} /></span>
          <h3 id="phone-ask-sheet-title">{S('phone.ask.title', ask.device)}</h3>
        </div>
        <div className="phone-ask-digits" aria-label={ask.digits.split('').join(' ')}>{groupDigits(ask.digits)}</div>
        <p>{S('phone.ask.detail')} {S(ask.viaRelay ? 'phone.ask.relay' : 'phone.ask.local')}</p>
        <div className="dict-confirm-foot">
          <button autoFocus className="dict-confirm-cancel" onClick={() => answer(false, ask.digits)}>{S('phone.ask.no')}</button>
          <button onClick={(e) => ok(e) && answer(true, ask.digits)} data-testid="phone-ask-allow">{S('phone.ask.yes')}</button>
        </div>
      </div>
    </div>
  );
}
