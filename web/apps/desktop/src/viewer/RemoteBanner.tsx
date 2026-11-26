// The bar on a computer being controlled (docs/design/remote-1.1.md §3): which device, Send Files… to it, and Disconnect. Its own
// small window, always on top at the top of the main display (src-tauri remote.rs `banner`), so whoever sits here always knows and
// can end it. As the Mac's (RemoteBanner.swift), in place of the name (docs/design/remote-files.md): "Clipboard sent to …" for 4 s
// when the device takes this computer's clipboard; while a file goes to it, where and how far, or paused; "Not sent." for 4 s when one
// fails. The window is as wide as what the bar says: the page measures itself and remote.rs re-centres it (`remote_banner_fit`).
import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { applyPlatform, applyTheme } from '@blurt/ui';
import { api, onClipboardSent, onRemoteStatus, onRemoteTransfer, type RemoteStatus } from '../api';
import { setLang, t } from '../i18n';
import { barLine, type Transfer } from './files';
import './viewer.css';

export function RemoteBanner() {
  const [s, setS] = useState<RemoteStatus | null>(null);
  const [, setTick] = useState(0);
  const [flash, setFlash] = useState<string | null>(null);
  // the files going to the device now, by id: the bar shows the one going (else one waiting, else one paused)
  const [going, setGoing] = useState<Record<string, Transfer>>({});
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const bar = useRef<HTMLDivElement>(null);
  const say = (text: string) => {
    setFlash(text);
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => setFlash(null), 4000);
  };
  const took = (x: Transfer) => {
    if (x.incoming || x.clip) return;
    setGoing((m) => {
      const n = { ...m };
      if (x.state === 'going' || x.state === 'waiting' || x.state === 'paused') n[x.id] = x;
      else delete n[x.id];
      return n;
    });
    if (x.state === 'failed' && x.why !== 'stopped') say(t('viewer.file.failed.other'));
  };
  useEffect(() => onClipboardSent((to) => say(t('remote.banner.clipboard_sent', { 1: to }))), []);
  useEffect(() => onRemoteTransfer(took), []);
  useEffect(() => {
    api.status().then((x) => {
      setLang(x.lang);
      applyPlatform(x.platform);
      applyTheme('dark');
      setTick((n) => n + 1);
    }, () => {});
    api.remoteStatus().then(setS, () => {});
    api.remoteTransfers().then((l) => l.forEach(took), () => {});
    void document.fonts?.ready.then(() => setTick((n) => n + 1)); // measured again in the real font
    return onRemoteStatus(setS);
  }, []);
  // the window as wide as the bar: measured on every change of what it says (and once the fonts are in)
  useLayoutEffect(() => {
    const el = bar.current;
    document.documentElement.classList.add('remote-banner-page');
    if (typeof screen !== 'undefined' && screen.availWidth > 0) document.documentElement.style.setProperty('--banner-most', `${screen.availWidth - 40}px`);
    if (!el || typeof ResizeObserver === 'undefined') return;
    let last = 0;
    const fit = () => {
      const w = Math.ceil(el.getBoundingClientRect().width);
      if (w > 0 && w !== last) {
        last = w;
        void api.remoteBannerFit(w).catch(() => {});
      }
    };
    const ro = new ResizeObserver(fit);
    ro.observe(el);
    void document.fonts?.ready.then(fit);
    return () => ro.disconnect();
  }, []);
  const who = s?.connected?.name || t('phonepage.unnamed');
  const list = Object.values(going);
  const now = list.find((x) => x.state === 'going') ?? list.find((x) => x.state === 'waiting') ?? list.find((x) => x.state === 'paused');
  const controlling = t('remote.banner.controlling', { 1: who });
  const clipboard = t('remote.banner.clipboard_sent', { 1: who });
  const line = flash ?? (now ? barLine(now, who) : null) ?? controlling;
  // One width for the whole session, so Send Files… and Disconnect never move: the widest line the bar can say for this device (who,
  // the clipboard line, a file at its longest — "10 of 10", 999.9 MB of 999.9 MB —, paused, Not sent.), measured in the page.
  const longest = 999.9 * 1024 * 1024;
  const widest = [controlling, clipboard, barLine({ id: '', name: '', size: longest, done: longest, incoming: false, clip: false, state: 'going', index: 10, count: 10 }, who) ?? '',
    t('viewer.file.paused'), t('viewer.file.failed.other')];
  const measure = useRef<HTMLSpanElement>(null);
  const [textW, setTextW] = useState(0);
  useLayoutEffect(() => {
    const m = measure.current;
    if (!m) return;
    const w = Math.max(...Array.from(m.children).map((c) => Math.ceil(c.getBoundingClientRect().width)));
    if (w !== textW) setTextW(w);
  });
  return (
    <div className="remote-banner" ref={bar} data-testid="remote-banner">
      <span className="remote-banner-measure" ref={measure} aria-hidden>
        {widest.map((l, k) => <span key={k}>{l}</span>)}
      </span>
      <span className="remote-banner-dot" aria-hidden />
      <span className="remote-banner-text" role="status" data-testid="remote-banner-text" style={textW ? { width: textW } : undefined}>{line}</span>
      {s?.connected?.files && (
        <button data-testid="remote-banner-send" onClick={() => void api.remoteSendFiles().catch(() => {})}>{t('remote.banner.send_files')}</button>
      )}
      <button onClick={() => void api.remoteEndSession().catch(() => {})}>{t('remote.banner.disconnect')}</button>
    </div>
  );
}
