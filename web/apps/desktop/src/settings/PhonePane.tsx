// Settings → Remote Control (the Mac's Settings/RemotePane.swift): the options only. On This Computer (whether a phone
// may show this screen) and Away from home (an own relay, the public connection service, Set Up a Relay). The devices
// themselves, paired and to pair, are on the Remote Control page (PhonePage.tsx); its first row here goes there.
// A new device always needs a yes, with the same six digits it shows; the question shows over the whole window wherever it
// is (PhoneAsk), and Allow is never the default (Return and Esc say no, and a click in the first moment after the question
// appears answers nothing). The host: src-tauri/src/remote.rs, docs/design/remote-protocol.md §The desktop app.
import { useEffect, useRef, useState } from 'react';
import { Icon } from '@blurt/icons';
import { api, type AppStatus, type RemoteStatus } from '../api';
import type { Place } from '../places';
import { StatusDot } from '../components/StatusDot';
import { Group, Page, Row, S, Switch, TextLink, Toggle } from './kit';
import { APP_PAGES, apply, awayLine, groupDigits, relayAddress, timeLeft, useNow, useRemoteStatus } from './phone';
import './settings.css';

type RelayState = 'idle' | 'checking' | 'ok' | 'failed' | 'invalid';

export function PhonePane({ onGo }: { status: AppStatus; onGo?: (p: Place) => void }) {
  const r = useRemoteStatus();
  // the service couldn't be installed or removed (a declined UAC prompt is the user's answer, not a failure)
  const [svcFailed, setSvcFailed] = useState(false);
  if (!r) return <Page id="phone"><p className="st-lead">{S('settings.loading')}</p></Page>;
  return (
    <Page id="phone" lead={
      // the devices are on their page: the lead says so and goes there (search's QR, pair, add, computer land here)
      <span data-setting="phone.devices">
        {S('phone.devices.lead', S('feature.phone'))}{' '}
        {onGo && <TextLink ink onClick={() => onGo('phone')}>{S('phone.devices.show')}</TextLink>}
      </span>
    }>
      <Group id="phone.options">
        {r.service !== null && (
          <Toggle id="phone.service" on={!!r.service} detail={S(svcFailed ? 'phone.service.failed' : 'phone.service.detail')} warn={svcFailed}
            set={(v) => {
              setSvcFailed(false);
              void apply(api.remoteSetService(v)).catch((e) => setSvcFailed(String(e) !== 'declined'));
            }} />
        )}
        <Toggle id="phone.stay_awake" on={r.stayAwake} detail={S(r.battery ? 'phone.stay_awake.laptop' : 'phone.stay_awake.desktop')}
          set={(v) => void apply(api.remoteSetStayAwake(v)).catch(() => {})} />
        <Toggle id="phone.screen" on={r.screenAllowed} set={(v) => void apply(api.remoteSetScreenAllowed(v)).catch(() => {})} />
      </Group>

      <RelayGroup r={r} />
    </Page>
  );
}

/** The code to scan, its time left, and the way out. A code past its time is dimmed with New Code beside it. */
export function PairPanel({ r, onCancel, onRenew }: { r: RemoteStatus; onCancel: () => void; onRenew: () => void }) {
  const p = r.pairing;
  const now = useNow(!!p);
  const expired = !!p && p.expiresAt <= now;
  const src = p ? `data:image/svg+xml;charset=utf-8,${encodeURIComponent(p.qrSvg)}` : null;
  return (
    <div className="st-row st-phone-pair" data-setting="phone.add" data-testid="phone-pairing">
      <div className={`st-phone-qr ${expired ? 'expired' : ''}`}>
        {src ? <img src={src} alt={S('phone.scan')} draggable={false} data-testid="phone-qr" /> : <span className="st-spin" aria-hidden />}
      </div>
      <div className="st-phone-pair-text">
        {/* the title, its time left beside it; one line of what to do; where the app comes from; the buttons right under */}
        <div className="st-phone-pair-title">
          <span>{S('phone.scan')}</span>
          {p && !expired && <span className="st-phone-left" aria-live="off">{S('phone.scan.left', timeLeft(p.expiresAt, now))}</span>}
        </div>
        <div className="st-detail">{S('phone.scan.detail')}</div>
        <span className="st-phone-noapp">
          <span>{S('phone.no_app')}</span>
          <TextLink ink onClick={() => void api.openUrl(APP_PAGES.ios).catch(() => {})}>{S('phone.get_app.ios')}</TextLink>
          <span aria-hidden>·</span>
          <TextLink ink onClick={() => void api.openUrl(APP_PAGES.android).catch(() => {})}>{S('phone.get_app.android')}</TextLink>
        </span>
        {p && expired && <div className="st-detail warn" data-testid="phone-expired"><Icon name="warning" size={12} />{S('phone.scan.expired')}</div>}
        {r.problem && <div className="st-detail warn"><Icon name="warning" size={12} />{r.problem}</div>}
        <div className="st-phone-pair-actions">
          {expired && <button className="primary ph-act" onClick={onRenew} data-testid="phone-renew">{S('phone.scan.new')}</button>}
          {p && !expired && <CopyLink url={p.url} />}
          <button className="ph-act" onClick={onCancel} data-testid="phone-cancel">{S('phone.cancel')}</button>
        </div>
      </div>
    </div>
  );
}

/** The code as a link, for a computer to paste into its Add Computer… (docs/design/remote-desktop-viewer.md). */
function CopyLink({ url }: { url: string }) {
  const [copied, setCopied] = useState(false);
  const copy = () =>
    void api.copyText(url).then(
      () => {
        // the link copied outlives the code on screen (10 minutes), and says so
        void api.remotePairingLinkCopied().catch(() => {});
        setCopied(true);
        setTimeout(() => setCopied(false), 4000);
      },
      () => {},
    );
  return <button className="ph-act" onClick={copy} data-testid="phone-copy-link">{copied ? S('phone.link_copied') : S('phone.copy_link')}</button>;
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

/** `digits` ties the answer to the device that asked: a late click can't answer another one that started asking since. */
const answer = (yes: boolean, digits: string) => void apply(api.remoteAnswerPairing(yes, digits)).catch(() => {});

/** Away from home's status line: the path a connected phone uses, or what a phone on another network would use and
 *  why that won't work (phone.ts `awayLine`). */
function AwayStatus({ r }: { r: RemoteStatus }) {
  const a = awayLine(r);
  return (
    <div className={`st-row st-phone-away ${a.warn ? 'warn' : ''}`} role="status" data-testid="phone-away" data-away={a.key}>
      <span className="st-phone-away-label">{S('phone.away')}</span>
      <span className="st-phone-away-value">
        {a.live ? <StatusDot tone="good" small /> : a.warn ? <Icon name="warning" size={14} /> : null}
        <span>{a.route ? S(a.key, S(a.route)) : S(a.key)}</span>
      </span>
    </div>
  );
}

/** Away from home: what's in use (AwayStatus), the owner's relay address, recommended (Return or leaving the field uses it
 *  and tries it), Blurt's go-between switch (used only while no relay is set), and Copy Instructions. */
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
  else if (saved && r.relay.reachable === false) (line = S(r.relay.fallback ? 'phone.relay.failed_fallback' : 'phone.relay.failed')), (warn = true);

  const own = !!r.relay.address;
  return (
    <Group id="phone.relay">
      <AwayStatus r={r} />
      <Row id="phone.relay.address" detail={line} warn={warn}
        title={<span data-testid="phone-relay-recommended">{S('phone.relay.own')}</span>}>
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
      {/* with a relay of the owner's the go-between is never used: the switch stays as set, dimmed, and says so */}
      <Row id="phone.go_between" detail={own ? S('phone.go_between.unused') : undefined}>
        <Switch on={r.relay.goBetween} label={S('phone.go_between')} disabled={own}
          set={(v) => void apply(api.remoteSetGoBetween(v)).catch(() => {})} />
      </Row>
      <Row id="phone.relay.help">
        <button onClick={copy} data-testid="phone-copy">{copied ? S('phone.relay.copied') : S('phone.relay.copy')}</button>
      </Row>
    </Group>
  );
}

/** A confirm on the app's ContentDialog (the Clear History sheet): Cancel is the default, the destructive one tinted
 *  (`danger`; otherwise the accent button: a choice that loses nothing, as Models' Use for Dictation). */
export function Confirm({ title, detail, cancel, ok, onOk, onClose, danger = true }: { title: string; detail: string; cancel: string; ok: string; onOk: () => void; onClose: () => void; danger?: boolean }) {
  return (
    <div className="overlay" onClick={onClose}>
      <div className="sheet dict-confirm" role="alertdialog" aria-modal="true" aria-labelledby="phone-confirm-title" onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => e.key === 'Escape' && (e.preventDefault(), onClose())}>
        <h3 id="phone-confirm-title">{title}</h3>
        <p>{detail}</p>
        <div className="dict-confirm-foot">
          <button autoFocus className="dict-confirm-cancel" onClick={onClose}>{cancel}</button>
          <button className={danger ? 'dict-danger-tint' : 'primary'} onClick={onOk}>{ok}</button>
        </div>
      </div>
    </div>
  );
}

/** A new device's question over the whole window, wherever it is (App.tsx shows it once). Its icon is the device's kind
 *  when the host knows it, else a neutral one. Don't Allow has the focus; Return, Esc and a click outside say no; only a
 *  click on Allow says yes. Gone when the host stops asking (answered, timed out, the device went away). */
export function PhoneAsk() {
  const r = useRemoteStatus();
  const ask = r?.asking ?? null;
  const ok = useAllow(ask?.digits ?? '');
  if (!ask) return null;
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
          <span className="phone-ask-icon" data-kind={ask.kind ?? 'unknown'}><Icon name={ask.kind === 'computer' ? 'screen' : ask.kind === 'phone' ? 'phone' : 'devices'} size={28} /></span>
          <h3 id="phone-ask-sheet-title">{S('phone.ask.title', ask.device)}</h3>
        </div>
        <div className="phone-ask-digits" aria-label={ask.digits.split('').join(' ')}>{groupDigits(ask.digits)}</div>
        {/* two sentences, one to a line: what to check, then where it is */}
        <p><span className="phone-ask-line">{S('phone.ask.detail', ask.device)}</span> <span className="phone-ask-line">{S(ask.viaRelay ? 'phone.ask.relay' : 'phone.ask.local')}</span></p>
        {/* anti-scam: said on every pairing, where the owner is looking (remote-1.1.md §3) */}
        <p className="phone-ask-caution" data-testid="phone-ask-caution"><Icon name="warning" size={16} />{S('phone.ask.caution')}</p>
        <div className="dict-confirm-foot">
          <button autoFocus className="dict-confirm-cancel" onClick={() => answer(false, ask.digits)}>{S('phone.ask.no')}</button>
          <button onClick={(e) => ok(e) && answer(true, ask.digits)} data-testid="phone-ask-allow">{S('phone.ask.yes')}</button>
        </div>
      </div>
    </div>
  );
}
