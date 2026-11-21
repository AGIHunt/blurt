// Remote Control → Computers You Can Control (docs/design/remote-desktop-viewer.md §The list of computers; the page,
// PhonePage.tsx): the computers this one shows and drives. Each row: the name, its system, its state (Connected · <path>,
// Available · <path>, Needs its own relay, Offline · <when last seen>, Removed this computer), its button (Open Window, Connect
// or Add Again…) and ⋯ with Remove. Add Computer… lists the Blurt computers found on this network (choosing one starts pairing)
// and takes a pasted pairing link for one that's away. While pairing, the six digits the other computer asks with show here; a
// pairing that fails says why and what to do next (Try Again, or Back with the link kept). The app's side: src-tauri/src/viewer.rs.
import { useEffect, useState } from 'react';
import { Icon } from '@blurt/icons';
import { i18n } from '../i18n';
import { AddLine, DeviceRow, EmptyLine, renameEntry, RowMore, StateLine, type Rename } from '../components/DeviceRows';
import { S } from '../settings/kit';
import { Confirm } from '../settings/PhonePane';
import { groupDigits } from '../settings/phone';
import { applyComputers, computers, pairingLink, pairingPlan, rowPlan, useComputers, type ComputerRow, type ComputersStatus, type Pairing } from './computers';
import './computers.css';

const SYSTEM: Record<string, string> = { mac: 'macOS', windows: 'Windows', linux: 'Linux' };
/** Add Again… asked for from a computer's window, as far as this page has opened Add Computer for it */
let addSeen = 0;

export function ComputersGroup() {
  const s = useComputers();
  const [adding, setAdding] = useState(false);
  const [removing, setRemoving] = useState<ComputerRow | null>(null);

  // nearby computers are looked for while this list shows: their rows say Available, and new ones are offered
  useEffect(() => {
    void applyComputers(computers.browse(true)).catch(() => {});
    return () => void computers.browse(false).catch(() => {});
  }, []);
  // a computer just paired (or paired again: the list doesn't grow then): the panel's job is done
  const [paired, setPaired] = useState<number | null>(null);
  useEffect(() => {
    if (!s) return;
    if (paired != null && s.paired > paired) setAdding(false);
    setPaired(s.paired);
  }, [s?.paired]);
  // a pairing begun from elsewhere holds the panel open as one begun here does, so Back keeps it
  useEffect(() => {
    if (s?.pairing) setAdding(true);
  }, [!!s?.pairing]);
  // Add Again… from a computer's window: this page, with Add Computer open
  useEffect(() => {
    if (s && s.addRequests > addSeen) {
      addSeen = s.addRequests;
      setAdding(true);
    }
  }, [s?.addRequests]);

  if (!s) return null;
  const close = () => {
    setAdding(false);
    void applyComputers(computers.cancelPairing()).catch(() => {});
  };
  const none = !s.computers.length;
  return (
    <>
      <h2 className="pg-h2">{S('computers.section')}</h2>
      <section className="pg-box" data-testid="computers">
        {none && !adding && !s.pairing && (
          <EmptyLine icon="screen" title={S('computers.none')} detail={S('computers.add.detail')}>
            <button className="ph-act" onClick={() => setAdding(true)} data-testid="computers-add">{S('computers.add')}</button>
          </EmptyLine>
        )}
        {s.computers.map((c) => <ComputerLine key={c.id} c={c} onRemove={() => setRemoving(c)} onAdd={() => setAdding(true)} />)}
        {adding || s.pairing ? (
          <AddPanel s={s} onClose={close} />
        ) : (
          !none && <AddLine label={S('computers.add')} onClick={() => setAdding(true)} title={S('computers.add.detail')} testid="computers-add" />
        )}
      </section>
      {removing && (
        <Confirm title={S('phone.remove.title', removing.name)} detail={S('computers.remove.detail')} cancel={S('phone.cancel')} ok={S('phone.remove')}
          onClose={() => setRemoving(null)}
          onOk={() => {
            const id = removing.id;
            setRemoving(null);
            void applyComputers(computers.remove(id)).catch(() => {});
          }} />
      )}
    </>
  );
}

function ComputerLine({ c, onRemove, onAdd }: { c: ComputerRow; onRemove: () => void; onAdd: () => void }) {
  const p = rowPlan(c);
  const route = p.route ? S(`phone.route.${p.route}`) : '';
  // asleep since a clock time ("10:42"); offline since a while ago ("3 hours ago")
  const when = !p.when ? '' : c.state === 'asleep' ? i18n().formatDate(p.when, Date.now() - p.when < 20 * 3600_000 ? 'time' : 'datetime') : i18n().formatRelative(p.when);
  const stateText = S(p.state, p.route ? route : when);
  const label = S(p.action === 'open' ? 'computers.open' : p.action === 'add' ? 'computers.add_again' : 'computers.connect');
  const tone = c.state === 'connected' ? 'good' : p.warn ? 'warn' : c.state === 'available' ? 'ready' : 'off';
  const open = () => void applyComputers(computers.open(c.id)).catch(() => {});
  // offline: nothing to press at rest (a try is in ⋯); otherwise its one button. Removed: Add Again…, and while its key is still here
  // (a refusal alone, this run) Connect in ⋯
  const offline = c.state === 'offline' || c.state === 'asleep';
  const removed = c.state === 'removed';
  const remove = { label: S('phone.remove'), danger: true, run: onRemove };
  // a name this computer alone uses: nothing is sent to the host
  const [editing, setEditing] = useState(false);
  const rename: Rename = { editing, setEditing, own: c.ownName || c.name, save: (n) => void applyComputers(computers.rename(c.id, n)).catch(() => {}) };
  const sep = { kind: 'separator' as const };
  const more = offline
    ? [{ label, run: open }, renameEntry(rename), sep, remove]
    : removed && c.key
      ? [{ label: S('computers.connect'), run: open }, renameEntry(rename), sep, remove]
      : [renameEntry(rename), sep, remove];
  return (
    <DeviceRow icon="screen" name={c.name} testid={`computer-${c.id}`} rename={rename}
      state={<StateLine tone={tone} state={stateText} rest={c.platform ? SYSTEM[c.platform] : undefined} tip={p.warn ? S('computers.no_direct.detail') : undefined}
        testid={`computer-state-${c.id}`} data={c.state} />}>
      {!offline && <button className="ph-act" onClick={removed ? onAdd : open} aria-label={`${label} ${c.name}`} data-testid={`computer-action-${c.id}`}>{label}</button>}
      <RowMore name={c.name} testid={`computer-more-${c.id}`} entries={more} />
    </DeviceRow>
  );
}



/** Add Computer…: the ones on this network, a link for one that's away, and while pairing, the digits to compare. */
function AddPanel({ s, onClose }: { s: ComputersStatus; onClose: () => void }) {
  // kept while the panel is open: Back after a failure finds the link still in its field
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
      <div className="st-computers-pair-wrap">
        <div className="st-computers-pair" data-setting="phone.computers.add" data-testid="computers-pairing" data-state={p.state}>
          <span className="st-phone-ask-icon"><Icon name="screen" size={20} /></span>
          <div className="st-phone-ask-body">
            <div className="st-phone-ask-title">{p.state === 'asking' ? S('computers.pairing.asking', p.name) : S('computers.pairing.connecting', p.name)}</div>
            {p.state === 'asking' && p.digits ? (
              <>
                <div className="st-detail">{S('computers.pairing.asking.detail')}</div>
                <div className="st-phone-ask-foot">
                  <span className="st-phone-digits" data-testid="computers-digits" aria-label={p.digits.split('').join(' ')}>{groupDigits(p.digits)}</span>
                  <span className="grow" />
                  <button className="ph-act" onClick={onClose}>{S('phone.cancel')}</button>
                </div>
              </>
            ) : (
              <div className="st-phone-ask-foot">
                <span className="st-spin" aria-hidden />
                <span className="grow" />
                <button className="ph-act" onClick={onClose}>{S('phone.cancel')}</button>
              </div>
            )}
          </div>
        </div>
      </div>
    );
  }
  if (p && p.state === 'failed' && p.error !== 'invalid') return <PairFailed p={p} onClose={onClose} />;
  const error = p?.state === 'failed' ? p.error : invalid ? 'invalid' : null;
  // the nearby ones are rows like the list's (可连接 · 同一网络, Pair in the button's place); then one field for a link, its Pair
  // only once something is typed (Return pairs too), Cancel beside it
  return (
    <div className="st-computers-panel" data-setting="phone.computers.add" data-testid="computers-add-panel">
      <div className="st-computers-section">{S('computers.nearby')}{s.browsing && <span className="st-spin" aria-hidden />}</div>
      {s.nearby.length ? (
        <div className="st-computers-nearby" data-testid="computers-nearby">
          {s.nearby.map((n) => (
            <DeviceRow key={n.id} icon="screen" name={n.name} state={<StateLine tone="ready" state={S('computers.state.available', S('phone.route.local'))} />}>
              <button className="ph-act" onClick={() => void applyComputers(computers.pairNearby(n.id)).catch(() => {})} data-testid={`computers-pair-${n.id}`}>{S('computers.pair')}</button>
              <span className="ph-more-slot" aria-hidden />
            </DeviceRow>
          ))}
        </div>
      ) : (
        <div className="st-detail st-computers-none">{S('computers.nearby.none')}</div>
      )}
      <div className="st-computers-add">
        <div className="st-computers-section">{S('computers.link')}</div>
        <div className="st-computers-link">
          <input className="st-field" type="text" spellCheck={false} autoComplete="off" placeholder="blurtremote://pair?…" aria-label={S('computers.link')}
            value={text} data-testid="computers-link"
            onChange={(e) => (setText(e.target.value), setInvalid(false))}
            onKeyDown={(e) => e.key === 'Enter' && pairLink()} />
          {text.trim() && <button className="ph-act" onClick={pairLink} data-testid="computers-link-pair">{S('computers.pair')}</button>}
          <button className="ph-act" onClick={onClose} data-testid="computers-cancel">{S('phone.cancel')}</button>
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
      </div>
    </div>
  );
}

/** A pairing that didn't pair: what went wrong, then what to do. Try Again where the same link or nearby computer can still work,
 *  else Back to the panel's first page (the link still in its field); Cancel closes. Can't reach goes on trying meanwhile: if the
 *  other computer turns up and asks, its digits take this one's place. */
function PairFailed({ p, onClose }: { p: Pairing; onClose: () => void }) {
  const plan = pairingPlan(p);
  const back = () => void applyComputers(computers.cancelPairing()).catch(() => {});
  const retry = () => void applyComputers(computers.retryPairing()).catch(() => {});
  return (
    <div className="st-computers-pair-wrap">
      <div className="st-computers-pair" data-setting="phone.computers.add" data-testid="computers-pairing" data-state="failed" data-error={p.error} role="status">
        <span className="st-phone-ask-icon"><Icon name="warning" size={20} /></span>
        <div className="st-phone-ask-body">
          <div className="st-phone-ask-title" data-testid="computers-failed">{S(plan.title, p.name)}</div>
          {plan.help && <div className="st-detail">{S(plan.help, p.name)}</div>}
          <div className="st-phone-ask-foot">
            {plan.retry && <button className="ph-act" onClick={back} data-testid="computers-back">{S('computers.back')}</button>}
            <span className="grow" />
            <button className="ph-act" onClick={onClose} data-testid="computers-cancel">{S('phone.cancel')}</button>
            {plan.retry ? (
              <button className="ph-act primary" onClick={retry} data-testid="computers-retry">{S('viewer.retry')}</button>
            ) : (
              <button className="ph-act primary" onClick={back} data-testid="computers-back">{S('computers.back')}</button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
