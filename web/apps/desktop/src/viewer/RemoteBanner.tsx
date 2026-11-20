// The bar on a computer being controlled (docs/design/remote-1.1.md §3): which device, and Disconnect. Its own small window,
// always on top at the top of the main display (src-tauri remote.rs `banner`), so whoever sits here always knows and can end it.
import { useEffect, useState } from 'react';
import { applyPlatform, applyTheme } from '@blurt/ui';
import { api, onRemoteStatus, type RemoteStatus } from '../api';
import { setLang, t } from '../i18n';
import './viewer.css';

export function RemoteBanner() {
  const [s, setS] = useState<RemoteStatus | null>(null);
  const [, setTick] = useState(0);
  useEffect(() => {
    api.status().then((x) => {
      setLang(x.lang);
      applyPlatform(x.platform);
      applyTheme('dark');
      setTick((n) => n + 1);
    }, () => {});
    api.remoteStatus().then(setS, () => {});
    return onRemoteStatus(setS);
  }, []);
  const who = s?.connected?.name || t('phonepage.unnamed');
  return (
    <div className="remote-banner" data-testid="remote-banner">
      <span className="remote-banner-dot" aria-hidden />
      <span className="remote-banner-text">{t('remote.banner.controlling', { 1: who })}</span>
      <button onClick={() => void api.remoteEndSession().catch(() => {})}>{t('remote.banner.disconnect')}</button>
    </div>
  );
}
