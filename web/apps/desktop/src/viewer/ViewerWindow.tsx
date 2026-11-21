// A computer's window (docs/design/remote-desktop-viewer.md §A window per computer): the toolbar (the computer's name, the
// path and round trip, the display switcher when it has more than one display, Keys to Remote, picture quality, ⋯) over
// the picture. The picture is decoded here (decode.ts); the pointer, buttons and the wheel go to the computer while the
// pointer is over the picture and the keys are captured; a click into the picture captures them, Ctrl+Alt gives them back
// (the hint says so for 3 s). The session itself is src-tauri/src/viewer.rs's, reached through `viewer_*` commands and a
// Channel of events and frames.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Channel } from '@tauri-apps/api/core';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { Icon } from '@blurt/icons';
import { applyPlatform, applyTheme } from '@blurt/ui';
import { api, inTauri, invoke, listen, type RemoteRoute } from '../api';
import { setLang, t } from '../i18n';
import { Menu, tidy, type MenuAt, type MenuEntry } from '../components/Menu';
import { contained, decodable, parseFrame, Picture, toPicture, wheelPoints } from './decode';
import { pathLine } from './computers';
import './viewer.css';

type Quality = 'auto' | 'sharp' | 'balanced' | 'saver';
/** removed: the host said so in a session (the key is gone); forgotten: it refused the key with no session (kept, said this run) */
type Link = 'connecting' | 'connected' | 'offline' | 'busy' | 'noDirect' | 'relayDown' | 'removed' | 'forgotten' | 'replaced' | 'ended';
interface Display {
  id: string;
  name: string;
  x: number;
  y: number;
  width: number;
  height: number;
  main: boolean;
}
interface Init {
  id: string;
  name: string;
  platform: 'mac' | 'windows' | 'linux' | null;
  options: { mapped: boolean; clipboard: boolean };
  systemShortcuts: 'all' | 'local';
  os: 'windows' | 'linux' | 'mac';
}
type Message =
  | { type: 'link'; link: Link; route: RemoteRoute | null }
  | { type: 'rtt'; ms: number }
  | { type: 'session'; name: string; platform: Init['platform']; canControl: boolean; privacy?: boolean; files?: boolean }
  | { type: 'file'; state: 'sending' | 'saved' | 'failed'; name?: string; why?: string }
  | { type: 'displays'; displays: Display[] }
  | { type: 'view'; width: number; height: number; family: string; display: string | null }
  | { type: 'cursor'; x: number; y: number }
  | { type: 'cursorShape'; png: string; hotX: number; hotY: number; width: number; height: number }
  | { type: 'screenFailed'; why: string }
  | { type: 'canControl'; on: boolean }
  | { type: 'screenLocked'; locked: boolean }
  | { type: 'released' };

const HINT_MS = 3000;
const QUALITIES: Quality[] = ['auto', 'sharp', 'balanced', 'saver'];
/** screenFailed's codes that have their own line; any other reason gets the general one */
const SCREEN_FAILED: Record<string, string> = { off: 'viewer.screen_off', permission: 'viewer.screen_permission', one_display: 'viewer.one_display' };

/** The window's channel: Tauri's in the app; in a browser, a stand-in the mock talks into (mock.ts). */
function channel(on: (m: Message | ArrayBuffer) => void): unknown {
  if (inTauri) {
    const c = new Channel<Message | ArrayBuffer>();
    c.onmessage = on;
    return c;
  }
  return { onmessage: on };
}

/** The route's word in the toolbar: the agreed terms (copy.md), the same as Settings → Remote Control. */
const routeWord = (r: RemoteRoute) => t(`phone.route.${r}`);

export function ViewerWindow({ id }: { id: string }) {
  const [init, setInit] = useState<Init | null>(null);
  const [langTick, setLangTick] = useState(0);
  const [link, setLink] = useState<Link>('connecting');
  const [route, setRoute] = useState<RemoteRoute | null>(null);
  const [rtt, setRtt] = useState<number | null>(null);
  const [displays, setDisplays] = useState<Display[]>([]);
  const [shown, setShown] = useState<string | null>(null);
  const [follow, setFollow] = useState(true);
  const [captured, setCaptured] = useState(false);
  const [hint, setHint] = useState(false);
  const [quality, setQuality] = useState<Quality>(() => (localStorage.getItem('blurt.viewer.quality') as Quality) || 'auto');
  const [options, setOptions] = useState({ mapped: true, clipboard: true });
  const [failed, setFailed] = useState<string | null>(null);
  // asked for the screen again (Try Again after a failure, e.g. once the host's Remote Desktop dialog is answered)
  const [screenTry, setScreenTry] = useState(0);
  const [canControl, setCanControl] = useState(true);
  // 隐私屏: the host can (its session says), and it was asked this session (asked again after a drop)
  const [canPrivacy, setCanPrivacy] = useState(false);
  // files: the host takes them (its session says); what the last one did, said for a few seconds
  const [canFiles, setCanFiles] = useState(false);
  const [fileNote, setFileNote] = useState<string | null>(null);
  const fileTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const privacy = useRef(false);
  const [, setPrivacyTick] = useState(0);
  // the host's screen is locked where it can't show it: the last frame stays under a darker cover that says so
  const [locked, setLocked] = useState(false);
  // a frame has been seen: a drop keeps it, darker, instead of a blank window
  const [hadPicture, setHadPicture] = useState(false);
  const hadPictureRef = useRef(false);
  const [noDecoder, setNoDecoder] = useState(false);
  const [codecs, setCodecs] = useState<string[] | null>(null);
  const [cursor, setCursor] = useState<{ x: number; y: number } | null>(null);
  const [shape, setShape] = useState<{ src: string; hotX: number; hotY: number; width: number; height: number } | null>(null);
  const [picSize, setPicSize] = useState<{ w: number; h: number } | null>(null);
  const [menu, setMenu] = useState<{ at: MenuAt; kind: 'quality' | 'more' } | null>(null);
  const [switcher, setSwitcher] = useState<HTMLElement | null>(null);
  const [name, setName] = useState('');

  const stage = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const picture = useRef<Picture | null>(null);
  const capturedRef = useRef(false);
  capturedRef.current = captured;
  const localMove = useRef(0);
  const hintTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // the app's language, look and the window's title
  useEffect(() => {
    api.status().then(
      (s) => {
        setLang(s.lang);
        applyPlatform(s.platform);
        applyTheme('auto');
        setLangTick((n) => n + 1);
      },
      () => {},
    );
    decodable().then((c) => {
      setCodecs(c);
      setNoDecoder(c.length === 0);
    });
  }, []);

  const onMessage = useCallback((m: Message | ArrayBuffer) => {
    if (m instanceof ArrayBuffer) {
      const f = parseFrame(m);
      if (f) {
        picture.current?.frame(f);
        if (!hadPictureRef.current) {
          hadPictureRef.current = true;
          setHadPicture(true);
        }
      }
      return;
    }
    switch (m.type) {
      case 'link':
        setLink(m.link);
        setRoute(m.route);
        if (m.link !== 'connected') {
          setRtt(null);
          // no session, no capture: otherwise Keys to Remote stays on, the click that captures is taken for a click on the
          // other computer, and after a reconnect the keys go nowhere
          if (capturedRef.current) {
            setCaptured(false);
            setHint(false);
            void invoke('viewer_capture', { on: false }).catch(() => {});
          }
        }
        break;
      case 'rtt':
        setRtt(m.ms);
        break;
      case 'session':
        setName(m.name);
        setCanControl(m.canControl);
        setCanPrivacy(!!m.privacy);
        setCanFiles(!!m.files);
        if (m.privacy && privacy.current) void invoke('viewer_privacy', { on: true }).catch(() => {});
        setFailed(null);
        setLocked(false);
        break;
      case 'displays':
        setDisplays(m.displays);
        break;
      case 'view':
        setShown(m.display);
        break;
      case 'cursor':
        setCursor({ x: m.x, y: m.y });
        break;
      case 'cursorShape':
        setShape({ src: `data:image/png;base64,${m.png}`, hotX: m.hotX, hotY: m.hotY, width: m.width, height: m.height });
        break;
      case 'screenFailed':
        setFailed(m.why);
        break;
      case 'canControl':
        setCanControl(m.on);
        break;
      case 'screenLocked':
        setLocked(m.locked);
        break;
      case 'file': {
        const text = m.state === 'sending' ? t('viewer.file.sending', { 1: m.name ?? '' })
          : m.state === 'saved' ? t('viewer.file.saved', { 1: m.name ?? '' })
          : t(`viewer.file.failed.${m.why === 'space' || m.why === 'too_big' || m.why === 'locked' ? m.why : 'other'}`);
        setFileNote(text);
        if (fileTimer.current) clearTimeout(fileTimer.current);
        if (m.state !== 'sending') fileTimer.current = setTimeout(() => setFileNote(null), 5000);
        break;
      }
      case 'released':
        setCaptured(false);
        setHint(false);
        break;
    }
  }, []);

  // the session: once the webview is ready (and again after a reload)
  const attach = useCallback(() => {
    invoke<Init>('viewer_attach', { channel: channel(onMessage) }).then(
      (i) => {
        setInit(i);
        setName(i.name);
        setOptions(i.options);
        if (inTauri) void getCurrentWindow().setTitle(i.name);
      },
      () => setLink('removed'),
    );
  }, [onMessage]);
  useEffect(() => {
    if (!canvas.current) return;
    picture.current = new Picture(canvas.current, () => void invoke('viewer_decode_failed').catch(() => {}), (w, h) =>
      setPicSize((p) => (p && p.w === w && p.h === h ? p : { w, h })),
    );
    attach();
    const off = listen<Init['options']>('viewer://options', setOptions);
    return () => {
      off();
      picture.current?.close();
    };
  }, [attach]);

  // the picture: the stage's size in pixels is its ceiling; a resize asks again (once it settles). The display isn't named: the
  // host keeps what showDisplay pinned for the next request too
  useEffect(() => {
    const el = stage.current;
    if (!el || codecs == null || codecs.length === 0 || link !== 'connected') return;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const ask = () => {
      const dpr = window.devicePixelRatio || 1;
      const width = Math.round(el.clientWidth * dpr);
      const height = Math.round(el.clientHeight * dpr);
      void invoke('viewer_screen', { width, height, codecs, quality, display: null, on: true }).catch(() => {});
    };
    ask();
    const ro = new ResizeObserver(() => {
      if (timer) clearTimeout(timer);
      timer = setTimeout(ask, 300);
    });
    ro.observe(el);
    return () => {
      ro.disconnect();
      if (timer) clearTimeout(timer);
    };
  }, [codecs, quality, link, screenTry]);

  const capture = useCallback((on: boolean) => {
    setCaptured(on);
    void invoke('viewer_capture', { on }).catch(() => {});
    if (hintTimer.current) clearTimeout(hintTimer.current);
    setHint(on);
    if (on) hintTimer.current = setTimeout(() => setHint(false), HINT_MS);
  }, []);

  // keys: the webview's own events (Linux, and a Mac build). On Windows the hook takes them before the webview (viewer_keys.rs)
  // and swallows them, so this sees only what the hook didn't take: a fallback, never a second copy
  useEffect(() => {
    if (!init) return;
    const on = (down: boolean) => (e: KeyboardEvent) => {
      if (!capturedRef.current) return;
      e.preventDefault();
      e.stopPropagation();
      void invoke<boolean>('viewer_key', { code: e.code, down }).then((released) => {
        if (released) {
          setCaptured(false);
          setHint(false);
        }
      });
    };
    const d = on(true);
    const u = on(false);
    window.addEventListener('keydown', d, true);
    window.addEventListener('keyup', u, true);
    return () => {
      window.removeEventListener('keydown', d, true);
      window.removeEventListener('keyup', u, true);
    };
  }, [init]);

  // the pointer: where it is on the picture, at most once a frame
  const pending = useRef<{ x: number; y: number } | null>(null);
  const raf = useRef(0);
  const rect = () => {
    const el = canvas.current;
    if (!el) return null;
    const b = el.getBoundingClientRect();
    const r = contained(b.width, b.height, el.width, el.height);
    return { b, r };
  };
  const at = (e: { clientX: number; clientY: number }) => {
    const g = rect();
    return g ? toPicture(e.clientX - g.b.left, e.clientY - g.b.top, g.r) : null;
  };
  const sendMove = (p: { x: number; y: number }) => {
    pending.current = p;
    if (raf.current) return;
    raf.current = requestAnimationFrame(() => {
      raf.current = 0;
      const q = pending.current;
      if (q) void invoke('viewer_pointer', q).catch(() => {});
    });
  };
  const live = captured && link === 'connected';
  const onPointerMove = (e: React.PointerEvent) => {
    if (!live) return;
    const p = at(e);
    if (!p) return;
    localMove.current = performance.now();
    setCursor(p);
    sendMove(p);
  };
  // a button's down and up reach the host in the order they happened
  const clicks = useRef<Promise<unknown>>(Promise.resolve());
  const inOrder = (f: () => Promise<unknown>) => {
    clicks.current = clicks.current.then(f, f).catch(() => {});
  };
  const onPointerDown = (e: React.PointerEvent) => {
    const p = at(e);
    if (!p || link !== 'connected') return;
    if (!captured) {
      // the click that captures stays here
      capture(true);
      return;
    }
    (e.target as HTMLElement).setPointerCapture?.(e.pointerId);
    const button = e.button === 2 ? 1 : e.button === 1 ? 2 : 0;
    inOrder(() => invoke('viewer_pointer', p).then(() => invoke('viewer_button', { button, down: true })));
  };
  const onPointerUp = (e: React.PointerEvent) => {
    if (!live) return;
    const p = at(e);
    const button = e.button === 2 ? 1 : e.button === 1 ? 2 : 0;
    // after the down has gone, whatever it waited on: a quick click (a tap) otherwise lets the up arrive first, and the host holds
    // the button down
    inOrder(() => (p ? invoke('viewer_pointer', p) : Promise.resolve()).then(() => invoke('viewer_button', { button, down: false })));
  };
  const wheelEnd = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => {
    const el = stage.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      if (!capturedRef.current) return;
      e.preventDefault();
      const { dx, dy } = wheelPoints(e, el.clientHeight);
      void invoke('viewer_scroll', { dx, dy, phase: 2 }).catch(() => {});
      if (wheelEnd.current) clearTimeout(wheelEnd.current);
      wheelEnd.current = setTimeout(() => void invoke('viewer_scroll', { dx: 0, dy: 0, phase: 3 }).catch(() => {}), 150);
    };
    el.addEventListener('wheel', onWheel, { passive: false });
    return () => el.removeEventListener('wheel', onWheel);
  }, []);

  const setOpts = (o: Partial<Init['options']>) => {
    const next = { ...options, ...o };
    setOptions(next);
    void invoke('viewer_options', next).catch(() => {});
  };
  const pickQuality = (q: Quality) => {
    setQuality(q);
    try {
      localStorage.setItem('blurt.viewer.quality', q);
    } catch {
      /* private storage: the choice lasts this window */
    }
  };
  const showDisplay = (d: string | null) => {
    setFollow(d == null);
    void invoke('viewer_show_display', { id: d }).catch(() => {});
  };
  const fullScreen = async () => {
    if (!inTauri) return void document.documentElement.requestFullscreen?.().catch(() => {});
    const w = getCurrentWindow();
    await w.setFullscreen(!(await w.isFullscreen()));
  };

  const host = init?.platform ?? 'mac';
  const moreEntries: MenuEntry[] = tidy([
    host === 'mac' && init?.os !== 'mac' && { label: t('viewer.mapping'), checked: options.mapped, run: () => setOpts({ mapped: !options.mapped }), testId: 'viewer-mapping' },
    { label: t('viewer.clipboard'), checked: options.clipboard, run: () => setOpts({ clipboard: !options.clipboard }), testId: 'viewer-clipboard' },
    host === 'windows' && { label: t('viewer.ctrl_alt_del'), testId: 'viewer-cad', run: () => void invoke('viewer_system', { name: 'secureAttention' }).catch(() => {}) },
    canFiles && { label: t('viewer.send_files'), testId: 'viewer-send-files', run: () => void invoke('viewer_send_files', { paths: null }).catch(() => {}) },
    canPrivacy && { label: t('viewer.privacy'), checked: privacy.current, testId: 'viewer-privacy',
      run: () => {
        privacy.current = !privacy.current;
        setPrivacyTick((n) => n + 1);
        void invoke('viewer_privacy', { on: privacy.current }).catch(() => {});
      } },
    init?.systemShortcuts === 'local' && { label: t('viewer.shortcuts_local'), disabled: true },
    { kind: 'separator' },
    { label: t('viewer.full_screen'), keys: init?.os === 'mac' ? undefined : 'F11', run: () => void fullScreen() },
  ]);
  const qualityEntries: MenuEntry[] = QUALITIES.map((q) => ({ label: t(`viewer.quality.${q}`), checked: q === quality, run: () => pickQuality(q) }));

  // F11: the system's own full screen, as the ⋯ menu's (not while keys are the other computer's)
  useEffect(() => {
    const f = (e: KeyboardEvent) => {
      if (e.key === 'F11' && !capturedRef.current) {
        e.preventDefault();
        void fullScreen();
      }
    };
    window.addEventListener('keydown', f);
    return () => window.removeEventListener('keydown', f);
  }, []);

  const index = displays.findIndex((d) => d.id === shown);
  const box = picSize && stage.current ? contained(stage.current.clientWidth, stage.current.clientHeight, picSize.w, picSize.h) : null;
  const showCursor = live && cursor && box && cursor.x >= 0 && cursor.y >= 0 && cursor.x <= 1 && cursor.y <= 1;
  const cover = coverFor(link, name, failed, noDecoder, canControl, locked, hadPicture, host);
  void langTick;

  return (
    <div className={`app vw ${captured ? 'captured' : ''}`} data-testid="viewer-window" data-computer={id} data-link={link}>
      <header className="vw-bar">
        <span className="vw-name" data-testid="viewer-name">{name}</span>
        <span className="vw-path" data-testid="viewer-path">
          {link === 'connected' && route ? (
            <>
              <span className="vw-dot" aria-hidden />
              {pathLine(routeWord(route), rtt)}
            </>
          ) : link === 'connecting' ? (
            t('viewer.connecting')
          ) : null}
        </span>
        <span className="grow" />
        {displays.length > 1 && (
          <button className="vw-btn" aria-haspopup="dialog" aria-expanded={!!switcher} data-testid="viewer-displays"
            onClick={(e) => setSwitcher(switcher ? null : e.currentTarget)}>
            <Icon name="screen" size={14} />
            {t('viewer.display', { 1: String(Math.max(1, index + 1)), 2: String(displays.length) })}
            <Icon name="chevron-down" size={12} />
          </button>
        )}
        <label className={`vw-keys ${captured ? 'on' : ''}`} data-testid="viewer-keys">
          <Icon name="keyboard" size={14} />
          <span>{t('viewer.keys')}</span>
          <input type="checkbox" role="switch" checked={captured} disabled={link !== 'connected'} onChange={(e) => capture(e.target.checked)} />
          <span className="vw-switch" aria-hidden />
        </label>
        <button className="vw-btn" aria-haspopup="menu" data-testid="viewer-quality"
          onClick={(e) => setMenu({ at: { x: 0, y: 0, anchor: e.currentTarget, align: 'end' }, kind: 'quality' })}>
          {t('viewer.quality')}: {t(`viewer.quality.${quality}`)}
          <Icon name="chevron-down" size={12} />
        </button>
        <button className="vw-btn icon" aria-label={t('viewer.more')} aria-haspopup="menu" data-testid="viewer-more"
          onClick={(e) => setMenu({ at: { x: 0, y: 0, anchor: e.currentTarget, align: 'end' }, kind: 'more' })}>
          <Icon name="more" size={16} />
        </button>
      </header>
      <div ref={stage} className={`vw-stage ${live ? 'live' : ''}`} data-testid="viewer-stage"
        onPointerMove={onPointerMove} onPointerDown={onPointerDown} onPointerUp={onPointerUp} onContextMenu={(e) => e.preventDefault()}>
        <canvas ref={canvas} className="vw-picture" width={16} height={10} data-testid="viewer-canvas" />
        {showCursor && shape && (
          <img className="vw-cursor" src={shape.src} alt="" draggable={false}
            style={{ left: box.x + cursor.x * box.w - shape.hotX, top: box.y + cursor.y * box.h - shape.hotY, width: shape.width, height: shape.height }} />
        )}
        {showCursor && !shape && <span className="vw-cursor arrow" style={{ left: box.x + cursor.x * box.w, top: box.y + cursor.y * box.h }} />}
        {hint && live && <div className="vw-hint" role="status" data-testid="viewer-hint">{t('viewer.hint')}</div>}
        {fileNote && live && <div className="vw-hint" role="status" data-testid="viewer-file">{fileNote}</div>}
        {cover && (
          <div className={`vw-cover ${cover.warn ? 'warn' : ''} ${cover.over ? 'over' : ''}`} role="status" data-testid="viewer-cover" data-cover={cover.kind}>
            {cover.kind === 'connecting' || cover.kind === 'reconnecting' ? <span className="st-spin" aria-hidden /> : cover.warn ? <Icon name="warning" size={20} /> : null}
            <div className="vw-cover-title">{cover.title}</div>
            {cover.detail && <div className="vw-cover-detail">{cover.detail}</div>}
            {cover.kind === 'replaced' && <button className="primary" onClick={attach}>{t('computers.connect')}</button>}
            {cover.kind === 'ended' && <button className="primary" onClick={attach}>{t('viewer.reconnect')}</button>}
            {/* its key is no good there now: the way back is to add it again, in the main window (this one closes) */}
            {cover.kind === 'removed' && (
              <button className="primary" onClick={() => void invoke('computers_add_again').catch(() => {})} data-testid="viewer-add-again">{t('computers.add_again')}</button>
            )}
            {cover.kind === 'screenFailed' && failed !== 'off' && (
              <button onClick={() => { setFailed(null); setScreenTry((n) => n + 1); }}>{t('viewer.retry')}</button>
            )}
          </div>
        )}
      </div>
      {menu && (
        <Menu at={menu.at} label={menu.kind === 'quality' ? t('viewer.quality') : t('viewer.more')} onClose={() => setMenu(null)}
          entries={menu.kind === 'quality' ? qualityEntries : moreEntries} />
      )}
      {switcher && (
        <DisplaySwitcher anchor={switcher} displays={displays} shown={shown} follow={follow} onClose={() => setSwitcher(null)}
          onPick={(d) => showDisplay(d)} />
      )}
    </div>
  );
}

/** What covers the picture when there's none to show: connecting, or why not, in the window's words. */
export function coverFor(link: Link, name: string, failed: string | null, noDecoder: boolean, canControl: boolean, locked = false,
  hadPicture = false, host: string = 'mac'): null | { kind: string; title: string; detail?: string; warn: boolean; over?: boolean } {
  const n = name || t('computers.this');
  switch (link) {
    case 'connecting':
      // a drop: it comes back by itself, over the last picture (never a new pairing)
      if (hadPicture) return { kind: 'reconnecting', title: t('viewer.reconnecting'), warn: false, over: true };
      return { kind: 'connecting', title: t('viewer.connecting'), warn: false };
    case 'offline':
      // a Mac that restarted with FileVault on waits for its disk password at the computer
      return { kind: 'offline', title: t('viewer.offline', { 1: n }), detail: t(host === 'mac' ? 'viewer.offline.detail.mac' : 'viewer.offline.detail'), warn: true };
    case 'busy':
      return { kind: 'busy', title: t('phone.away.busy'), warn: true };
    case 'noDirect':
      return { kind: 'noDirect', title: t('phone.away.no_direct'), warn: true };
    case 'relayDown':
      // still trying, through the public connection service as well
      return { kind: 'relayDown', title: t('viewer.relay_down', { 1: n }), warn: true, over: hadPicture };
    case 'removed':
    case 'forgotten':
      return { kind: 'removed', title: t('viewer.removed', { 1: n }), warn: true };
    case 'replaced':
      return { kind: 'replaced', title: t('viewer.replaced', { 1: n }), warn: false };
    case 'ended':
      return { kind: 'ended', title: t('viewer.ended', { 1: n }), warn: false };
  }
  if (noDecoder) return { kind: 'noDecoder', title: t('viewer.no_decoder'), warn: true };
  // GNOME ends screen sharing at its lock; its own Remote Login reaches the login screen
  if (locked) return { kind: 'locked', title: t(host === 'linux' ? 'viewer.locked.linux' : 'viewer.locked', { 1: n }), warn: false, over: hadPicture };
  // the host's own sentence is for phones (English only): the viewer says it in its own words
  if (failed) return { kind: 'screenFailed', title: t(SCREEN_FAILED[failed] ?? 'viewer.screen_failed', { 1: n }), warn: true };
  if (!canControl) return { kind: 'noControl', title: t('viewer.no_control', { 1: n }), warn: true };
  return null;
}

/** The host's displays as they're arranged; a click shows that one, and Follow the Pointer goes back to following. */
function DisplaySwitcher({ anchor, displays, shown, follow, onPick, onClose }: { anchor: HTMLElement; displays: Display[]; shown: string | null; follow: boolean; onPick: (id: string | null) => void; onClose: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const away = (e: PointerEvent) => !ref.current?.contains(e.target as Node) && !anchor.contains(e.target as Node) && onClose();
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('pointerdown', away, true);
    window.addEventListener('keydown', esc);
    return () => {
      window.removeEventListener('pointerdown', away, true);
      window.removeEventListener('keydown', esc);
    };
  }, [anchor, onClose]);
  const layout = useMemo(() => {
    const minX = Math.min(...displays.map((d) => d.x));
    const minY = Math.min(...displays.map((d) => d.y));
    const maxX = Math.max(...displays.map((d) => d.x + d.width));
    const maxY = Math.max(...displays.map((d) => d.y + d.height));
    const k = Math.min(240 / (maxX - minX), 120 / (maxY - minY));
    return { k, minX, minY, w: (maxX - minX) * k, h: (maxY - minY) * k };
  }, [displays]);
  const b = anchor.getBoundingClientRect();
  return (
    <div ref={ref} className="vw-switcher" role="dialog" aria-label={t('viewer.display_label')} data-testid="viewer-switcher"
      style={{ top: b.bottom + 6, right: Math.max(8, window.innerWidth - b.right) }}>
      <div className="vw-arrangement" style={{ width: layout.w, height: layout.h }}>
        {displays.map((d, i) => (
          <button key={d.id} className={`vw-screen ${d.id === shown ? 'shown' : ''}`} title={d.name} aria-pressed={d.id === shown && !follow}
            style={{ left: (d.x - layout.minX) * layout.k, top: (d.y - layout.minY) * layout.k, width: d.width * layout.k - 4, height: d.height * layout.k - 4 }}
            onClick={() => onPick(d.id)}>
            {i + 1}
          </button>
        ))}
      </div>
      <label className="vw-follow">
        <input type="checkbox" checked={follow} onChange={(e) => onPick(e.target.checked ? null : shown)} data-testid="viewer-follow" />
        {t('viewer.follow')}
      </label>
    </div>
  );
}
