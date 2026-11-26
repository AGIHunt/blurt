// The bar on a computer being controlled (docs/design/remote-1.1.md §3): which device, Send Files… to it, and Disconnect. Its own
// small window, always on top at the top of the main display (src-tauri remote.rs `banner`), so whoever sits here always knows and
// can end it. When the device takes this computer's clipboard (docs/design/remote-files.md), the bar says so for 4 s in place of
// the name.
import { useEffect, useRef, useState } from 'react';
import { applyPlatform, applyTheme } from '@blurt/ui';
import { api, onClipboardSent, onRemoteStatus, type RemoteStatus } from '../api';
import { setLang, t } from '../i18n';
import './viewer.css';

export function RemoteBanner() {
  const [s, setS] = useState<RemoteStatus | null>(null);
  const [, setTick] = useState(0);
  const [sentTo, setSentTo] = useState<string | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(
    () =>
      onClipboardSent((to) => {
        setSentTo(to);
        if (timer.current) clearTimeout(timer.current);
        timer.current = setTimeout(() => setSentTo(null), 4000);
      }),
    [],
  );
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
      <span className="remote-banner-text" role="status" data-testid="remote-banner-text">
        {sentTo ? t('remote.banner.clipboard_sent', { 1: sentTo }) : t('remote.banner.controlling', { 1: who })}
      </span>
      <button className="secondary" data-testid="remote-banner-send" onClick={() => void api.remoteSendFiles().catch(() => {})}>{t('remote.banner.send_files')}</button>
      <button onClick={() => void api.remoteEndSession().catch(() => {})}>{t('remote.banner.disconnect')}</button>
    </div>
  );
}
