// The Phone page (the Mac's MainWindow/PhonePage.swift + PhonePageViews.swift, BlurtCore/PhoneChecks.swift;
// docs/design/capabilities.md): whether a phone is connected and how, what on this computer stands in a phone's way
// (only that — all well is one line, never a wall of checks), the paired phones, Add Phone… (the code to scan, right
// here), where the phone app comes from (built from source until it is in the stores) and what to try when it won't
// connect. Settings → Phone keeps the options and the relay.
import { useEffect, useRef, useState } from 'react';
import { Icon } from '@blurt/icons';
import { api, type AppStatus, type RemoteStatus } from '../api';
import { phoneHeadline, phoneProblems, phoneTips, type PhoneProblem } from '../capabilities';
import { i18n, t } from '../i18n';
import { APP_PAGES, apply, useRemoteStatus } from '../settings/phone';
import { Confirm, PairPanel } from '../settings/PhonePane';
import './pages.css';

export function PhonePage({ status, onSettings }: { status: AppStatus; onSettings: (pane: string) => void }) {
  const r = useRemoteStatus();
  const [adding, setAddingState] = useState(false);
  const [removing, setRemoving] = useState<RemoteStatus['devices'][number] | null>(null);
  const [checking, setChecking] = useState(false);
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
  // a phone just paired from the code on screen: the code's job is done
  const count = useRef<number | null>(null);
  useEffect(() => {
    if (!r) return;
    if (count.current != null && r.devices.length > count.current && addingRef.current) setAdding(false);
    count.current = r.devices.length;
  }, [r?.devices.length]);

  if (!r) return <div className="pg" data-testid="phone-page" />;
  const win = status.platform === 'win';
  const head = phoneHeadline(r);
  const problems = phoneProblems(r);
  const tips = phoneTips(r);
  const open = (url: string) => void api.openUrl(url).catch(() => {});

  const problem = (p: PhoneProblem) => {
    switch (p) {
      case 'control':
        return <Check key={p} bad title={t(win ? 'phone.control.win' : 'phone.control.linux')} detail={t(win ? 'phone.control.win.detail' : 'phone.control.linux.detail')} />;
      case 'firewall':
        return (
          <Check key={p} bad title={t('phone.firewall')} detail={t('phone.firewall.detail')}>
            <button className="primary" onClick={() => void apply(api.remoteAllowFirewall()).catch(() => {})}>{t('phone.firewall.allow')}</button>
          </Check>
        );
      case 'listen':
        return <Check key={p} bad title={t('phonepage.listen')} detail={r.problem ?? ''} />;
      case 'relay':
        return (
          <Check key={p} bad title={t('phonepage.relay')} detail={t('phonepage.relay.detail')}>
            <button disabled={checking} onClick={() => {
              setChecking(true);
              void api.remoteCheckRelay(r.relay.address ?? '').finally(() => setChecking(false));
            }}>{t('phonepage.relay.again')}</button>
            <button onClick={() => onSettings('phone/phone.relay.address')}>{t('phonepage.relay_settings')}</button>
          </Check>
        );
    }
  };

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

        {/* the one fact: connected, how; or not; or none paired yet, with the way to pair */}
        <section className={`pg-box ph-head ${head.kind}`} data-testid="phone-head">
          <span className="ph-glyph"><Icon name="phone" size={22} />{head.kind === 'connected' && <i className="ph-dot" aria-hidden />}</span>
          <span className="ph-head-text">
            <span className="ph-head-title">
              {head.kind === 'connected' ? t('phonepage.head.connected', { a: head.name || t('phonepage.unnamed') }) : t(head.kind === 'none' ? 'phonepage.head.none' : 'phonepage.head.not_connected')}
            </span>
            <span className="ph-head-detail">
              {head.kind === 'connected' ? t(head.viaRelay ? 'phonepage.head.relay' : 'phonepage.head.local') : t(head.kind === 'none' ? 'phonepage.head.none.detail' : 'phonepage.head.not_connected.detail')}
            </span>
          </span>
          {!adding && !r.asking && (
            <button className={head.kind === 'none' ? 'primary' : ''} onClick={() => setAdding(true)} title={t('phone.add.detail')} data-testid="phone-page-add">{t('phone.add')}</button>
          )}
        </section>
        {adding && !r.asking && (
          <div className="pg-box ph-pair">
            <PairPanel r={r} onCancel={() => setAdding(false)} onRenew={() => void apply(api.remoteShowPairing(true)).catch(() => {})} />
          </div>
        )}

        {/* this computer: only what stands in a phone's way; all well is one line */}
        <h2 className="pg-h2">{t('phonepage.computer')}</h2>
        <section className="pg-box" data-testid="phone-checks">
          {problems.length ? (
            problems.map(problem)
          ) : (
            <Check title={t('phonepage.ok')}
              detail={[t('phonepage.ok.keys'), r.screenAllowed ? t('phonepage.ok.screen') : '', r.relay.address ? t(r.relay.reachable == null ? 'phonepage.ok.relay_checking' : 'phonepage.ok.relay') : ''].filter(Boolean).join(' · ')} />
          )}
        </section>

        {r.devices.length > 0 && (
          <>
            <h2 className="pg-h2">{t('phonepage.paired')}</h2>
            <section className="pg-box" data-testid="phone-paired">
              {r.devices.map((d) => {
                const on = r.connected?.id === d.id ? r.connected : null;
                return (
                  <div key={d.id} className="pg-line">
                    <span className="pg-line-ic"><Icon name="phone" size={16} /></span>
                    <span className="pg-line-text">
                      <span className="pg-line-title">{d.name || t('phonepage.unnamed')}</span>
                      <span className="pg-line-detail">
                        {on ? (
                          <span className="ph-live"><i className="ph-dot" aria-hidden />{t('phone.connected', { 1: t(`phone.route.${on.route}`) })}</span>
                        ) : d.lastSeen ? t('phone.last_used', { 1: i18n().formatRelative(d.lastSeen) }) : t('phone.not_connected')}
                      </span>
                    </span>
                    <button onClick={() => setRemoving(d)} aria-label={`${t('phone.remove')} ${d.name}`}>{t('phone.remove')}</button>
                  </div>
                );
              })}
            </section>
          </>
        )}

        {tips.length > 0 && (
          <>
            <h2 className="pg-h2">{t('phonepage.tips')}</h2>
            <ol className="pg-box ph-tips" data-testid="phone-tips">
              {tips.map((k) => (
                <li key={k}>{t(k === 'vpn' && !win ? 'phonepage.tips.vpn.linux' : k === 'away_none' ? 'phonepage.tips.away.none' : k === 'away_ok' ? 'phonepage.tips.away.ok' : `phonepage.tips.${k}`)}
                  {k === 'away_none' && <button className="pg-link" onClick={() => onSettings('phone/phone.relay.address')}>{t('phonepage.relay_settings')}</button>}
                </li>
              ))}
            </ol>
          </>
        )}

        {/* where the phone app comes from: built from source until it is in the stores */}
        <h2 className="pg-h2">{t('phone.app')}</h2>
        <section className="pg-box">
          <div className="pg-line">
            <span className="pg-line-ic"><Icon name="code" size={16} /></span>
            <span className="pg-line-text">
              <span className="pg-line-title">{t('phonepage.app.where')}</span>
            </span>
            <button onClick={() => open(APP_PAGES.ios)}>{t('phone.get_app.ios')}</button>
            <button onClick={() => open(APP_PAGES.android)}>{t('phone.get_app.android')}</button>
          </div>
        </section>
      </div>
      {removing && (
        <Confirm title={t('phone.remove.title', { 1: removing.name })} detail={t('phone.remove.detail')} cancel={t('phone.cancel')} ok={t('phone.remove')}
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

/** A line about this computer: a check or the attention mark, what it is, what it means, its fix. */
function Check({ title, detail, bad, children }: { title: string; detail?: string; bad?: boolean; children?: React.ReactNode }) {
  return (
    <div className={`pg-line ph-check ${bad ? 'bad' : 'good'}`} aria-label={`${title}, ${t(bad ? 'phonepage.ax.needs_you' : 'phonepage.ax.ok')}`}>
      <span className="pg-line-ic">{bad ? <Icon name="warning" size={16} /> : <Icon name="check" size={16} />}</span>
      <span className="pg-line-text">
        <span className="pg-line-title">{title}</span>
        {detail && <span className="pg-line-detail">{detail}</span>}
      </span>
      {children}
    </div>
  );
}
