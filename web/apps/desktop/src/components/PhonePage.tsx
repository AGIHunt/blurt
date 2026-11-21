// Remote Control (the sidebar's page; docs/design/remote-desktop-viewer.md §One place for devices): every device in
// three groups. Devices That Can Control This Computer: each paired phone and computer, its icon by kind, its state, Remove,
// and Add Device… (the code to scan, its digits, Copy Link for a computer). Computers You Can Control: the computers this one
// drives (ComputersGroup.tsx) and Add Computer…. This Computer: only what stands in a device's way (all well is one line,
// never a wall of checks). Then what to try when a phone won't connect. Settings → Remote Control keeps the options and
// away from home.
import { useEffect, useRef, useState } from 'react';
import { api, type AppStatus, type RemoteConnection, type RemoteStatus } from '../api';
import { phoneProblems, phoneTips, type PhoneProblem } from '../capabilities';
import { i18n, t } from '../i18n';
import { apply, useRemoteStatus } from '../settings/phone';
import { Confirm, PairPanel } from '../settings/PhonePane';
import { ComputersGroup } from '../viewer/ComputersGroup';
import { AddLine, DeviceRow, EmptyLine, renameEntry, RowMore, StateLine, type Rename } from './DeviceRows';
import { StatusDot } from './StatusDot';
import './pages.css';

type Device = RemoteStatus['devices'][number];

export function PhonePage({ status, onSettings }: { status: AppStatus; onSettings: (pane: string) => void }) {
  const r = useRemoteStatus();
  const [adding, setAddingState] = useState(false);
  const [removing, setRemoving] = useState<Device | null>(null);
  const [checking, setChecking] = useState(false);
  const [allowing, setAllowing] = useState(false);
  const addingRef = useRef(false);
  const setAdding = (on: boolean) => {
    addingRef.current = on;
    setAddingState(on);
    void apply(api.remoteShowPairing(on)).catch(() => {});
  };
  // leaving the page takes the code down
  useEffect(() => () => {
    if (addingRef.current) void apply(api.remoteShowPairing(false)).catch(() => {});
  }, []);
  // a device just paired from the code on screen: the code's job is done
  const count = useRef<number | null>(null);
  useEffect(() => {
    if (!r) return;
    if (count.current != null && r.devices.length > count.current && addingRef.current) setAdding(false);
    count.current = r.devices.length;
  }, [r?.devices.length]);

  if (!r) return <div className="pg" data-testid="phone-page" />;
  const win = status.platform === 'win';
  const problems = phoneProblems(r);
  const tips = phoneTips(r);
  const none = !r.devices.length;

  const problem = (p: PhoneProblem) => {
    switch (p) {
      case 'control':
        return <Check key={p} bad title={t(win ? 'phone.control.win' : 'phone.control.linux')} detail={t(win ? 'phone.control.win.detail' : 'phone.control.linux.detail')} />;
      case 'firewall':
        return (
          <Check key={p} bad title={t('phone.firewall')} detail={t('phone.firewall.detail')}>
            <button className="primary ph-act" disabled={allowing} data-testid="phone-firewall-allow" onClick={() => {
              setAllowing(true);
              void apply(api.remoteAllowFirewall()).catch(() => {}).finally(() => setAllowing(false));
            }}>{t('phone.firewall.allow')}</button>
          </Check>
        );
      case 'listen':
        return <Check key={p} bad title={t('phonepage.listen')} detail={r.problem ?? ''} />;
      case 'relay':
        return (
          <Check key={p} bad title={t('phonepage.relay')} detail={t('phonepage.relay.detail')}>
            <button className="ph-act" disabled={checking} onClick={() => {
              setChecking(true);
              void api.remoteCheckRelay(r.relay.address ?? '').finally(() => setChecking(false));
            }}>{t('phonepage.relay.again')}</button>
            <button className="ph-act" onClick={() => onSettings('phone/phone.relay.address')}>{t('phonepage.relay_settings')}</button>
          </Check>
        );
    }
  };

  const thisComputer = (
    <>
      <h2 className="pg-h2">{t('phonepage.computer')}</h2>
      <section className={`pg-box ${problems.length ? 'ph-attn' : ''}`} data-testid="phone-checks">
        {problems.length ? (
          problems.map(problem)
        ) : (
          <Check title={t('phonepage.ok')}
            detail={[t('phonepage.ok.keys'), r.screenAllowed ? t('phonepage.ok.screen') : '', r.relay.address ? t(r.relay.reachable == null ? 'phonepage.ok.relay_checking' : 'phonepage.ok.relay') : ''].filter(Boolean).join(' · ')} />
        )}
      </section>
    </>
  );

  return (
    <div className="pg" data-testid="phone-page">
      <div className="pg-col">
        <header className="pg-head">
          <div className="pg-head-text">
            <h1 className="pg-title">{t('feature.phone')}</h1>
          </div>
          <div className="pg-head-acts">
            <button onClick={() => onSettings('phone')} title={t('phonepage.settings.tip')} data-testid="phone-settings">{t('phonepage.settings')}</button>
          </div>
        </header>

        {/* something in a device's way here: said first, with its fix (the sidebar's mark points at it) */}
        {problems.length > 0 && thisComputer}

        {/* what can control this computer: phones and computers, then the way to add one */}
        <h2 className="pg-h2">{t('phonepage.paired')}</h2>
        <section className="pg-box" data-testid="phone-paired">
          {none && !adding && (
            <EmptyLine icon="devices" title={t('phonepage.head.none')} detail={t('phonepage.head.none.detail')}>
              <button className="primary ph-act" disabled={!!r.asking} onClick={() => setAdding(true)} data-testid="phone-page-add">{t('phone.add')}</button>
            </EmptyLine>
          )}
          {r.devices.map((d) => <DeviceLine key={d.id} d={d} r={r} onRemove={() => setRemoving(d)} />)}
          {adding && !r.asking ? (
            <div className="ph-pair">
              <PairPanel r={r} onCancel={() => setAdding(false)} onRenew={() => void apply(api.remoteShowPairing(true)).catch(() => {})} />
            </div>
          ) : (
            !none && <AddLine label={t('phone.add')} disabled={!!r.asking} onClick={() => setAdding(true)} title={t('phone.add.detail')} testid="phone-page-add" />
          )}
        </section>

        {/* what this computer controls */}
        <ComputersGroup />

        {/* who was in this computer, and when (remote-1.1.md §3) */}
        <ConnectionLog r={r} />

        {/* this computer: all well is one quiet line at the end */}
        {problems.length === 0 && thisComputer}

        {tips.length > 0 && (
          <>
            <h2 className="pg-h2">{t('phonepage.tips')}</h2>
            <ol className="pg-box ph-tips" data-testid="phone-tips">
              {tips.map((k) => (
                <li key={k}>{t(k === 'vpn' && !win ? 'phonepage.tips.vpn.linux' : k === 'away_none' ? 'phonepage.tips.away.none' : k === 'away_ok' ? 'phonepage.tips.away.ok' : k === 'away_go_between' ? 'phonepage.tips.away.go_between' : `phonepage.tips.${k}`)}
                  {(k === 'away_none' || k === 'away_go_between') && <button className="pg-link" onClick={() => onSettings('phone/phone.relay.address')}>{t('phonepage.relay_settings')}</button>}
                </li>
              ))}
            </ol>
          </>
        )}
      </div>
      {removing && (
        <Confirm title={t('phone.remove.title', { 1: removing.name })} detail={t(removing.kind === 'computer' ? 'computers.remove.detail' : 'phone.remove.detail')} cancel={t('phone.cancel')} ok={t('phone.remove')}
          onClose={() => setRemoving(null)}
          onOk={() => {
            const id = removing.id;
            setRemoving(null);
            void apply(api.remoteRemoveDevice(id)).catch(() => {});
          }} />
      )}
    </div>
  );
}

/** A device that can control this computer: a phone or a computer (its icon), whether it's connected and how, Remove. */
function DeviceLine({ d, r, onRemove }: { d: Device; r: RemoteStatus; onRemove: () => void }) {
  const computer = d.kind === 'computer';
  const on = r.connected?.id === d.id ? r.connected : null;
  const name = d.name || t(computer ? 'phonepage.unnamed.computer' : 'phonepage.unnamed');
  // a computer always shows the screen: only a phone says so
  const how = on ? [t(`phone.route.${on.route}`), on.screen && !computer ? t('phone.showing_screen') : ''].filter(Boolean).join(' · ') : '';
  // state first, as the computers below: 已连接 · <path> · …, or 未连接 · 上次使用：<when>
  const state = on ? t('phone.connected', { 1: how }) : t('phone.not_connected');
  const rest = !on && d.lastSeen ? t('phone.last_used', { 1: i18n().formatRelative(d.lastSeen) }) : undefined;
  // a name this computer alone uses: nothing is sent to the device
  const [editing, setEditing] = useState(false);
  const rename: Rename = { editing, setEditing, own: d.ownName || name, save: (n) => void apply(api.remoteRenameDevice(d.id, n)).catch(() => {}) };
  return (
    <DeviceRow icon={computer ? 'screen' : 'phone'} name={name} testid={`device-${d.id}`} kind={computer ? 'computer' : 'phone'} rename={rename}
      state={<StateLine tone={on ? 'good' : 'off'} state={state} rest={rest} />}>
      <RowMore name={name} testid={`device-more-${d.id}`} entries={[renameEntry(rename), { kind: 'separator' }, { label: t('phone.remove'), danger: true, run: onRemove }]} />
    </DeviceRow>
  );
}

/** A line about this computer: a check or the attention mark, what it is, what it means, its fix. */
function Check({ title, detail, bad, children }: { title: string; detail?: string; bad?: boolean; children?: React.ReactNode }) {
  return (
    <div className={`pg-line ph-row ph-check ${bad ? 'bad' : 'good'}`} aria-label={`${title}, ${t(bad ? 'phonepage.ax.needs_you' : 'phonepage.ax.ok')}`}>
      {/* not a device: no device glyph, only the state's mark (a disc with a check, or with "!"), as the rows' marks */}
      <span className="pg-line-ic"><StatusDot tone={bad ? 'warn' : 'good'} small /></span>
      <span className="pg-line-text">
        <span className="pg-line-title">{title}</span>
        {detail && <span className="pg-line-detail">{detail}</span>}
      </span>
      {children}
    </div>
  );
}

/** 连接记录: the latest three sessions and pairings here, newest first; Show All opens the rest in a box that scrolls on its own, so
 * a long log never pushes the page down. Read again whenever a session starts or ends. */
function ConnectionLog({ r }: { r: RemoteStatus }) {
  const [list, setList] = useState<RemoteConnection[]>([]);
  const [open, setOpen] = useState(false);
  const key = `${r.connected?.id ?? ''}|${r.devices.length}`;
  useEffect(() => {
    api.remoteConnections(200).then(setList, () => {});
  }, [key]);
  if (!list.length) return null;
  const when = (ms: number) => i18n().formatDate(ms, 'datetime');
  const line = (c: RemoteConnection) => {
    if (c.paired) return t('phone.log.paired', { 1: when(c.start) });
    const span = c.end ? `${when(c.start)}–${i18n().formatDate(c.end, 'time')}` : t('phone.log.now', { 1: when(c.start) });
    return c.route ? `${span} · ${t(`phone.route.${c.route}`)}` : span;
  };
  const row = (c: RemoteConnection) => (
    <DeviceRow key={`${c.id}-${c.paired}`} icon={c.paired ? 'plus' : r.devices.find((d) => d.id === c.deviceId)?.kind === 'computer' ? 'screen' : 'phone'}
      name={r.devices.find((d) => d.id === c.deviceId)?.name || c.name || t('phonepage.unnamed')} state={<span className="pg-line-detail">{line(c)}</span>} />
  );
  return (
    <>
      <h2 className="pg-h2">{t('phone.log')}</h2>
      <section className="pg-box" data-testid="phone-log">
        {list.slice(0, 3).map(row)}
        {open && list.length > 3 && <div className="ph-log-more">{list.slice(3).map(row)}</div>}
        {list.length > 3 && (
          <button type="button" className="pg-line ph-add" onClick={() => setOpen(!open)} data-testid="phone-log-all">
            <span className="pg-line-ic" />
            <span>{open ? t('phone.log.less') : t('phone.log.all', { 1: list.length })}</span>
          </button>
        )}
      </section>
    </>
  );
}
