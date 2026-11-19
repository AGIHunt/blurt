// Settings → Phones and Computers → Computers (docs/design/remote-desktop-viewer.md §The list of computers): the computers
// this one shows and drives. Each row: the name, its system, its state (Connected · <path>, Available · <path>, Offline ·
// <when last seen>) and one button (Open Window, Connect, Remove). Add Computer… lists the Blurt computers found on this
// network (choosing one starts pairing) and takes a pasted pairing link for one that's away. While pairing, the six digits
// the other computer asks with show here. The app's side: src-tauri/src/viewer.rs.
import { useEffect, useState } from 'react';
import { Icon } from '@blurt/icons';
import { i18n } from '../i18n';
import { Group, Line, Row, S } from '../settings/kit';
import { Confirm } from '../settings/PhonePane';
import { groupDigits } from '../settings/phone';
import { applyComputers, computers, pairingLink, rowPlan, useComputers, type ComputerRow, type ComputersStatus } from './computers';
import './computers.css';

const SYSTEM: Record<string, string> = { mac: 'macOS', windows: 'Windows', linux: 'Linux' };

export function ComputersGroup() {
  const s = useComputers();
  const [adding, setAdding] = useState(false);
  const [removing, setRemoving] = useState<ComputerRow | null>(null);

  // nearby computers are looked for while this list shows: their rows say Available, and new ones are offered
  useEffect(() => {
    void applyComputers(computers.browse(true)).catch(() => {});
    return () => void computers.browse(false).catch(() => {});
  }, []);
  // a computer just paired: the panel's job is done
  const [count, setCount] = useState(0);
  useEffect(() => {
    if (!adding) setCount(s?.computers.length ?? 0);
  }, [adding, s?.computers.length]);
  useEffect(() => {
    if (adding && s && !s.pairing && s.computers.length > count) setAdding(false);
  }, [s?.computers.length, s?.pairing]);

  if (!s) return null;
  const close = () => {
    setAdding(false);
    void applyComputers(computers.cancelPairing()).catch(() => {});
  };
  return (
    <Group id="phone.computers">
      {s.computers.map((c) => <ComputerLine key={c.id} c={c} onRemove={() => setRemoving(c)} />)}
      {adding || s.pairing ? (
        <AddPanel s={s} onClose={close} />
      ) : (
        <Row id="phone.computers.add">
          <button onClick={() => setAdding(true)} data-testid="computers-add">{S('computers.add')}</button>
        </Row>
      )}
      {removing && (
        <Confirm title={S('phone.remove.title', removing.name)} detail={S('computers.remove.detail')} cancel={S('phone.cancel')} ok={S('phone.remove')}
          onClose={() => setRemoving(null)}
          onOk={() => {
            const id = removing.id;
            setRemoving(null);
            void applyComputers(computers.remove(id)).catch(() => {});
          }} />
      )}
    </Group>
  );
}

function ComputerLine({ c, onRemove }: { c: ComputerRow; onRemove: () => void }) {
  const p = rowPlan(c);
  const route = p.route ? S(`phone.route.${p.route}`) : '';
  const when = p.when ? i18n().formatRelative(p.when) : '';
  const stateText = S(p.state, p.route ? route : when);
  const detail = (
    <span className={c.state === 'connected' ? 'st-phone-live' : undefined} data-testid={`computer-state-${c.id}`} data-state={c.state}>
      {c.state === 'connected' && <span className="st-phone-dot" aria-hidden />}
      {[c.platform ? SYSTEM[c.platform] : '', stateText].filter(Boolean).join(' · ')}
    </span>
  );
  const run = () => (p.action === 'remove' ? onRemove() : void applyComputers(computers.open(c.id)).catch(() => {}));
  const label = S(p.action === 'open' ? 'computers.open' : p.action === 'connect' ? 'computers.connect' : 'phone.remove');
  return (
    <Line title={c.name} detail={detail} flash={`computers.computer.${c.id}`}>
      <button onClick={run} aria-label={`${label} ${c.name}`} data-testid={`computer-action-${c.id}`}>{label}</button>
    </Line>
  );
}

/** Add Computer…: the ones on this network, a link for one that's away, and while pairing, the digits to compare. */
function AddPanel({ s, onClose }: { s: ComputersStatus; onClose: () => void }) {
  const [text, setText] = useState('');
  const [invalid, setInvalid] = useState(false);
  const p = s.pairing;
  const pairLink = () => {
    const l = pairingLink(text);
    if (!l) return setInvalid(true);
    setInvalid(false);
    void applyComputers(computers.pairLink(l)).catch(() => {});
  };
  if (p && p.state !== 'failed') {
    return (
      <div className="st-row st-computers-pair" data-setting="phone.computers.add" data-testid="computers-pairing" data-state={p.state}>
        <span className="st-phone-ask-icon"><Icon name="screen" size={20} /></span>
        <div className="st-phone-ask-body">
          <div className="st-phone-ask-title">{p.state === 'asking' ? S('computers.pairing.asking', p.name) : S('computers.pairing.connecting', p.name)}</div>
          {p.state === 'asking' && p.digits ? (
            <>
              <div className="st-detail">{S('computers.pairing.asking.detail')}</div>
              <div className="st-phone-ask-foot">
                <span className="st-phone-digits" data-testid="computers-digits" aria-label={p.digits.split('').join(' ')}>{groupDigits(p.digits)}</span>
                <span className="grow" />
                <button onClick={onClose}>{S('phone.cancel')}</button>
              </div>
            </>
          ) : (
            <div className="st-phone-ask-foot">
              <span className="st-spin" aria-hidden />
              <span className="grow" />
              <button onClick={onClose}>{S('phone.cancel')}</button>
            </div>
          )}
        </div>
      </div>
    );
  }
  const error = p?.state === 'failed' ? p.error : invalid ? 'invalid' : null;
  return (
    <div className="st-row st-computers-add" data-setting="phone.computers.add" data-testid="computers-add-panel">
      <div className="st-computers-section">{S('computers.nearby')}</div>
      {s.nearby.length ? (
        <ul className="st-computers-nearby" data-testid="computers-nearby">
          {s.nearby.map((n) => (
            <li key={n.id}>
              <Icon name="screen" size={16} />
              <span className="grow">{n.name}</span>
              <button onClick={() => void applyComputers(computers.pairNearby(n.id)).catch(() => {})} data-testid={`computers-pair-${n.id}`}>{S('computers.pair')}</button>
            </li>
          ))}
        </ul>
      ) : (
        <div className="st-detail st-computers-none">
          {s.browsing && <span className="st-spin" aria-hidden />}
          {S('computers.nearby.none')}
        </div>
      )}
      <div className="st-computers-section">{S('computers.link')}</div>
      <div className="st-computers-link">
        <input className="st-field" type="text" spellCheck={false} autoComplete="off" placeholder="blurtremote://pair?…" aria-label={S('computers.link')}
          value={text} data-testid="computers-link"
          onChange={(e) => (setText(e.target.value), setInvalid(false))}
          onKeyDown={(e) => e.key === 'Enter' && pairLink()} />
        <button onClick={pairLink} disabled={!text.trim()} data-testid="computers-link-pair">{S('computers.pair')}</button>
      </div>
      <div className={`st-detail ${error ? 'warn' : ''}`} data-testid="computers-link-detail">
        {error ? (
          <>
            <Icon name="warning" size={12} />
            {S(`computers.error.${error}`)}
          </>
        ) : (
          S('computers.link.detail')
        )}
      </div>
      <div className="st-phone-pair-actions">
        <span className="grow" />
        <button onClick={onClose} data-testid="computers-cancel">{S('phone.cancel')}</button>
      </div>
    </div>
  );
}
