// The first-run Welcome on Windows / Linux (the Mac's Onboarding/Onboarding.swift; onboarding.rs): a view over the
// whole main window, shown once (config app.onboarded) and again from Settings → General. Four steps on Windows,
// every one skippable:
//   1. welcome — what Blurt does: each use with what it makes and its key as keycaps;
//   2. dictation — the key (right Alt; a "press it" check from the hook's own events) and the microphone (the
//      default input, Windows' privacy switches, Open Settings… while they are off);
//   3. speech model — the recommended model and its one download (setup.rs starts it at the first launch: that one is
//      shown, never a second, with Stop), the cloud model as an optional row (Add… opens Settings' Add Cloud Model);
//   4. try it — a box to dictate into, checked once a dictation lands (then double-tap to send), and "Open Blurt at
//      login" as the last row. Done applies it.
// Linux has no dictation yet: the welcome, then the last step without the practice card.
// The window is the assistant (mainwin.rs welcome_window: 880×600, as the Mac's is a window of its own), one scroll
// region (the step's rows) at any scale.
// Footer (as on the Mac): the step dots, Skip Setup (the one way out; not on the last step), Back, and one primary —
// the step's own action while it is still to do (a quiet Not Now beside it goes on without it), else Next / Done.
import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { Icon, Mascot, type IconName } from '@blurt/icons';
import { api, listen, type CloudSummary, type HotkeyRow, type LoginItem, type MicState, type Onboarding } from '../api';
import { i18n, t } from '../i18n';
import { Popup } from '../settings/kit';
import { AddCloudModel, AddSpeechCloud, dictateInCloud, speechOffers, useCurated } from './DictationSettings';
import { mb, ModelProgress, useDictationModels } from './ModelDownload';

export type StepId = 'welcome' | 'dictation' | 'models' | 'try';

/** The steps this PC gets: dictation's three only where dictation runs (Windows). */
export function stepsFor(dictation: boolean): StepId[] {
  return dictation ? ['welcome', 'dictation', 'models', 'try'] : ['welcome', 'try'];
}

/** The last step's one line (the Mac's BlurtCore WelcomeLine): where Blurt stays and the keys to try first — only
 *  keys that work now. */
export function welcomeLine(dictation: 'works' | 'no_model' | 'off', dictate: string, snap: string | null): { key: string; params: Record<string, string> } {
  if (dictation === 'works') return snap ? { key: 'welcome.line', params: { dictate, snap } } : { key: 'welcome.line_dictation_only', params: { dictate } };
  if (dictation === 'no_model') return { key: 'welcome.line_no_model', params: {} };
  return snap ? { key: 'welcome.line_snap_only', params: { snap } } : { key: 'welcome.line_plain', params: {} };
}

const caps = (label: string) => label.split('+').map((s) => s.trim()).filter(Boolean);

function KeyCaps({ keys }: { keys: string[] }) {
  return (
    <span className="wl-caps">
      {keys.map((k, i) => <kbd key={i} className="wl-cap">{k}</kbd>)}
    </span>
  );
}

function Row({ icon, title, detail, first, children, testid }: { icon: IconName; title: string; detail?: ReactNode; first?: boolean; children?: ReactNode; testid?: string }) {
  return (
    <div className={`wl-row${first ? ' first' : ''}`} data-testid={testid}>
      <span className="wl-glyph"><Icon name={icon} size={18} /></span>
      <span className="wl-txt">
        <span className="wl-title">{title}</span>
        {detail && <span className="wl-detail">{detail}</span>}
      </span>
      {children && <span className="wl-trail">{children}</span>}
    </div>
  );
}

/** The filled check-circle the Mac's rows end in ("Allowed", "Done", "Ready"), in the ok colour. */
export function OkMark({ size = 14 }: { size?: number }) {
  return (
    <svg className="wl-okmark" width={size} height={size} viewBox="0 0 16 16" aria-hidden>
      <circle cx="8" cy="8" r="7.5" fill="currentColor" />
      <path d="M4.6 8.3 7 10.6l4.4-4.9" fill="none" stroke="var(--raise, #fff)" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

/** A row's status at its trailing edge: a mark and a word (the Mac's StatusLabel). */
function State({ tone, text, title }: { tone: 'good' | 'warn' | 'busy' | 'wait'; text: string; title?: string }) {
  return (
    <span className={`wl-state ${tone}`} title={title}>
      {tone === 'busy' ? <span className="wl-spin" aria-hidden /> : tone === 'good' ? <OkMark /> : tone === 'warn' ? <Icon name="warning" size={14} /> : null}
      {text}
    </span>
  );
}

function Notice({ tone, title, detail, children }: { tone: 'good' | 'warn' | 'busy' | 'err'; title: string; detail?: string; children?: ReactNode }) {
  return (
    <div className={`wl-notice ${tone}`} role={tone === 'err' ? 'alert' : undefined}>
      {/* the colour is on the mark, never on the words (system.md: the signal carries the colour) */}
      {(tone === 'warn' || tone === 'err') && <span className="wl-nmark"><Icon name="warning" size={18} /></span>}
      <span className="wl-ntitle">{tone === 'busy' && <span className="wl-spin" aria-hidden />}{title}</span>
      {detail && <span className="wl-detail">{detail}</span>}
      {children}
    </div>
  );
}

interface Props {
  onb: Onboarding;
  /** the first run (shown by itself): the step is kept for a quit, "Open at login" starts on */
  firstRun: boolean;
  onDone: () => void;
  onToast: (m: string) => void;
  /** leave the assistant for a Settings pane (it comes back at its step next launch while setup isn't done) */
  onSettings?: (pane: string) => void;
}

export function Welcome({ onb: initial, firstRun, onDone, onToast, onSettings }: Props) {
  const [onb, setOnb] = useState(initial);
  const steps = stepsFor(onb.dictation.available);
  const [ix, setIx] = useState(() => Math.min(firstRun ? initial.step : 0, steps.length - 1));
  const step = steps[ix];
  const last = ix === steps.length - 1;
  const [hotkeys, setHotkeys] = useState<HotkeyRow[]>([]);
  const [heard, setHeard] = useState(false);
  const [keyDown, setKeyDown] = useState(false);
  const [mic, setMic] = useState<MicState | null>(null);
  const [cloud, setCloud] = useState<CloudSummary | null>(null);
  const [cloudOpen, setCloudOpen] = useState(false);
  // cloud recognition (windows-models.md §Cloud recognition on a weak PC): the sheet for a speech service, open
  const [speechOpen, setSpeechOpen] = useState(false);
  const curated = useCurated();
  const [login, setLogin] = useState<LoginItem | null>(null);
  const [openAtLogin, setOpenAtLogin] = useState(true);
  const [waited, setWaited] = useState(false);
  const [retrying, setRetrying] = useState(false);
  /** the speech tools (uv) coming down: MB so far / in all (setup.rs; total 0 = not known) */
  const [uvProg, setUvProg] = useState<{ done: number; total: number } | null>(null);
  const { models, err, dl, failed, load, download } = useDictationModels();
  const win = onb.dictation.available;
  /** the key went down while the try card showed: a paste after it is the first dictation */
  const pressedHere = useRef(false);
  const stepRef = useRef(step);
  stepRef.current = step;
  /** the try card heard the key go down and no text has landed yet */
  const [listening, setListening] = useState(false);

  const refresh = useCallback(() => api.onboarding().then(setOnb, () => {}), []);
  const readMic = useCallback(() => (win ? api.mic().then(setMic, () => {}) : Promise.resolve()), [win]);

  // the window is the assistant's size while it shows, the user's own frame after
  useEffect(() => {
    api.welcomeWindow(true).catch(() => {});
    return () => void api.welcomeWindow(false).catch(() => {});
  }, []);

  useEffect(() => {
    api.settings().then((s) => setHotkeys(s.hotkeys), () => {});
    api.loginItem().then((l) => {
      setLogin(l);
      // the first time: on (dictation needs Blurt running); opened again later: as it is now
      setOpenAtLogin(firstRun ? true : l.enabled);
    }, () => {});
    if (win) api.cloudSummary().then(setCloud, () => {});
    readMic();
    const t0 = setTimeout(() => setWaited(true), 60_000);
    const offs = [
      listen<{ down: boolean }>('dictation://key', (p) => {
        setKeyDown(p.down);
        if (p.down) setHeard(true);
        if (p.down && stepRef.current === 'try') {
          pressedHere.current = true;
          setListening(true);
        }
      }),
      // uv arrived (or failed): the step follows, and the models are read again
      listen<{ step: string; state: string; done_mb?: number; total_mb?: number }>('setup', (p) => {
        if (p.step !== 'uv') return;
        if (p.state === 'running' && p.done_mb != null) return setUvProg({ done: p.done_mb, total: p.total_mb ?? 0 });
        setUvProg(null);
        if (p.state !== 'running') setRetrying(false);
        refresh();
        if (p.state === 'done') load();
      }),
    ];
    // back from Windows Settings: read the switches again
    const onFocus = () => readMic();
    window.addEventListener('focus', onFocus);
    return () => {
      clearTimeout(t0);
      offs.forEach((o) => o());
      window.removeEventListener('focus', onFocus);
    };
  }, []);

  useEffect(() => {
    if (firstRun) api.onboardingStep(ix).catch(() => {});
  }, [ix]);

  // the key check on step 2: while this window has the focus the press is only a check — App.tsx sees
  // [data-key-probe] and doesn't pass it on, so no take starts and the island stays out of the way
  useEffect(() => {
    if (step !== 'dictation') return;
    const either = onb.dictation.key === 'either_option';
    const on = (e: KeyboardEvent) => {
      if (e.code !== 'AltRight' && !(either && e.code === 'AltLeft')) return;
      if ((e.target as HTMLElement | null)?.closest?.('.mw-menu')) return;
      const down = e.type === 'keydown';
      setKeyDown(down);
      if (down) setHeard(true);
    };
    window.addEventListener('keydown', on, true);
    window.addEventListener('keyup', on, true);
    return () => {
      window.removeEventListener('keydown', on, true);
      window.removeEventListener('keyup', on, true);
    };
  }, [step, onb.dictation.key]);

  // the microphone while its step (or the try card) shows: the switches change in another window
  useEffect(() => {
    if (!win || (step !== 'dictation' && step !== 'try')) return;
    const h = setInterval(readMic, 2000);
    return () => clearInterval(h);
  }, [step, win]);

  // ---- the speech model
  const rec = models?.models.find((m) => m.id === models.recommended) ?? null;
  type MS = 'tools' | 'tools_failed' | 'checking' | 'list_failed' | 'downloading' | 'installed' | 'failed' | 'waiting' | 'offer';
  const ms: MS = (() => {
    if (!onb.uv) return onb.uv_state === 'failed' && !retrying ? 'tools_failed' : 'tools';
    if (dl) return 'downloading';
    if (!models) return err ? 'list_failed' : 'checking';
    if (!rec || rec.installed) return 'installed';
    if (failed) return 'failed';
    if (onb.first_download_pending && !waited) return 'waiting';
    return 'offer';
  })();
  const ready = ms === 'installed' || !!models?.ready;

  // while the tools or setup's first download are still coming: look again now and then
  useEffect(() => {
    if (!win || !['tools', 'waiting', 'checking'].includes(ms)) return;
    const h = setInterval(() => {
      refresh();
      if (onb.uv) load();
    }, 3000);
    return () => clearInterval(h);
  }, [ms, win, onb.uv]);

  const setKey = async (key: string) => {
    try {
      const d = (await api.settings()).config.record?.dictation ?? {};
      await api.setSettings({ record: { dictation: { ...d, key } } });
    } catch (e) {
      onToast(String(e));
    }
    refresh();
  };

  const retrySetup = async () => {
    setRetrying(true);
    if (!(await api.onboardingRetrySetup().catch(() => false))) setRetrying(false);
    refresh();
  };

  // ---- try it
  const [text, setText] = useState('');
  const [tried, setTried] = useState(false);
  const [sent, setSent] = useState(false);
  const pastedAt = useRef(0);
  const box = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    if (step === 'try') pressedHere.current = false;
  }, [step]);

  const keyName = t(onb.dictation.key === 'either_option' ? 'dictation.key.either_alt' : 'dictation.key.right_alt');
  const keyCaps = [onb.dictation.key === 'either_option' ? 'Alt' : t('dictation.key.right_alt')];
  const mode = ['auto', 'tap', 'hold'].includes(onb.dictation.mode) ? onb.dictation.mode : 'auto';
  const micBlocked = !!mic?.supported && (!mic.device || mic.access === 'denied');

  type TryBlock = 'off' | 'mic' | 'downloading' | 'no_model' | 'tools' | null;
  const tryBlock: TryBlock = (() => {
    if (!win || tried) return null;
    if (!onb.dictation.enabled) return 'off';
    if (micBlocked) return 'mic';
    if (ready) return null;
    if (ms === 'downloading' || ms === 'waiting' || ms === 'checking') return 'downloading';
    if (ms === 'offer' || ms === 'failed') return 'no_model';
    return 'tools';
  })();

  // ---- the step's own action, while it is still to do (nil: Next / Done is the primary)
  const action: { title: string; run: () => void; disabled?: boolean } | null = (() => {
    const openMic = { title: t('welcome.mic.open'), run: () => api.micSettings().catch((e) => onToast(String(e))) };
    if (step === 'dictation' && mic?.supported && mic.device && mic.access === 'denied') return openMic;
    if (step === 'models') {
      if (ms === 'tools_failed') return { title: t('welcome.models.retry'), run: retrySetup };
      if (ms === 'list_failed') return { title: t('welcome.models.retry'), run: () => load() };
      // Download / Try Again sit in the model's own row (the Mac's step 3): the footer stays Skip · Back · Next
    }
    if (step === 'try') {
      if (tryBlock === 'mic' && mic?.device) return openMic;
      if (tryBlock === 'no_model' && rec) return { title: t('welcome.models.download', { size: mb(rec.size_mb) }), run: () => download(rec.id) };
      if (tryBlock === 'tools') return { title: t('welcome.models.retry'), run: () => setIx(steps.indexOf('models')) };
    }
    return null;
  })();

  const finish = async (done: boolean) => {
    try {
      await api.onboardingFinish(done && login?.supported ? openAtLogin : null);
    } catch (e) {
      onToast(String(e));
    }
    onDone();
  };
  const next = () => (last ? finish(true) : setIx(ix + 1));

  const heading = (() => {
    switch (step) {
      case 'welcome':
        return [t('welcome.welcome'), t('welcome.subtitle')];
      case 'dictation':
        // only what was checked: the key heard, the microphone allowed (not that speech was heard)
        return [t('welcome.dictation.title'), t(heard ? (mic?.device && mic.access !== 'denied' ? 'welcome.dictation.detail_done' : 'welcome.dictation.detail_key') : 'welcome.dictation.detail')];
      case 'models':
        return [t('welcome.models'), t(models?.selected_cloud ? 'welcome.models.detail_cloud' : 'welcome.models.detail')];
      default:
        return win ? [t('welcome.try'), t('welcome.try.subtitle')] : [t('welcome.finish'), t('welcome.finish.detail')];
    }
  })();

  const hk = (a: string) => hotkeys.find((h) => h.action === a);
  const hkCaps = (a: string) => {
    const h = hk(a);
    return h && h.result === 'ok' && h.label ? caps(h.label) : [];
  };

  // ---- steps
  const welcome = (
    <div className="wl-rows">
      {(
        [
          ...(win ? [['text-cursor', 'dictation', keyCaps] as const] : []),
          ['snap', 'snap', hkCaps('snap')] as const,
          ...(win ? [['copy', 'text', hkCaps('text')] as const, ['languages', 'translate', hkCaps('translate')] as const] : []),
          ['mic', 'voice', hkCaps('voice')] as const,
          ['record', 'record', hkCaps('record')] as const,
        ] as const
      ).map(([icon, use, keys], i) => (
        <Row key={use} icon={icon} first={i === 0} title={t(`welcome.use.${use}`)} detail={use === 'dictation' ? t(`welcome.gesture.${mode}`) : t(`welcome.use.${use}.detail`)} testid={`welcome-use-${use}`}>
          {keys.length ? <KeyCaps keys={[...keys]} /> : <span className="dim small">{t('welcome.not_set')}</span>}
        </Row>
      ))}
      {onSettings ? (
        <p className="wl-foot"><button type="button" className="wl-link" onClick={() => onSettings('shortcuts')}>{t('welcome.use.change')}</button></p>
      ) : null}
    </div>
  );

  const micRow = (first = false) => {
    // the row says what the microphone is for (the Mac's); the device is the status's tooltip
    const detail = !mic || (mic.device && mic.access !== 'denied') ? t('welcome.mic.why') : !mic.device ? t('welcome.mic.none_detail') : t('welcome.mic.denied_detail');
    return (
      <Row icon="mic" title={t('welcome.mic.title')} detail={detail} first={first} testid="welcome-mic">
        {!mic ? <State tone="busy" text={t('welcome.models.checking')} />
          : !mic.device ? <State tone="warn" text={t('welcome.mic.none')} />
          : mic.access === 'denied' ? <><State tone="warn" text={t('welcome.mic.denied')} /><button onClick={() => api.micSettings().catch((e) => onToast(String(e)))}>{t('welcome.mic.open')}</button></>
          : <State tone="good" text={t(mic.access === 'allowed' ? 'welcome.mic.allowed' : 'welcome.mic.found')} title={mic.device} />}
      </Row>
    );
  };

  const dictation = (
    <div className="wl-rows">
      <Row icon="text-cursor" first title={t('welcome.key.title')} detail={t(`welcome.gesture.${mode}`)} testid="welcome-key">
        {/* the key, chosen here (the Mac's ChoicePopup on this step) */}
        <Popup label={t('welcome.key.title')} value={onb.dictation.key === 'either_option' ? 'either_option' : 'right_option'}
          choices={[['right_option', t('dictation.key.right_alt')], ['either_option', t('dictation.key.either_alt')]]}
          hints={[undefined, t('welcome.key.either_hint')]} onChange={setKey} />
      </Row>
      {/* the check: a row of its own (the Mac's "Fn key in macOS" row), its status at the trailing edge */}
      <div className={`wl-rowwrap${keyDown ? ' down' : ''}`} data-testid="welcome-press">
        <Row icon="keyboard" title={t('welcome.key.try')} detail={t('welcome.key.press', { key: keyName })}>
          {heard ? <State tone="good" text={t('welcome.key.heard')} /> : <State tone="wait" text={t('welcome.key.waiting')} />}
        </Row>
      </div>
      <h3 className="wl-head">{t('welcome.permissions')}</h3>
      {micRow(true)}
      <p className="wl-note">{t('welcome.permissions.none_else')}</p>
    </div>
  );

  // one size for one download: what the Download button promised, never a second figure
  const modelSize = Math.max(rec?.size_mb ?? 0, dl?.total_mb ?? 0);
  const zh = i18n().lang === 'zh-Hans';
  // the row's trailing column says where it stands: Ready, the Download button, a spinner while it comes down
  const modelTrail = () => {
    if (!rec) return null;
    if (dl) return <State tone="busy" text={dl.total_mb > 0 ? `${Math.min(99, Math.floor((dl.done_mb / Math.max(dl.total_mb, modelSize)) * 100))}%` : t('dictation.model.starting')} />;
    if (ms === 'installed') return <State tone="good" text={t('welcome.models.ready_short')} />;
    if (ms === 'waiting') return <State tone="busy" text={t('welcome.models.starting')} />;
    if (ms === 'failed') return <button onClick={() => download(rec.id)}>{t('welcome.models.retry')}</button>;
    // dictation runs in the cloud now: the download stays offered, no longer the step's main button
    if (ms === 'offer') return <button className={models?.selected_cloud ? '' : 'primary'} onClick={() => download(rec.id)}>{t('welcome.models.download', { size: mb(rec.size_mb) })}</button>;
    // dictation works on another model already: the recommended one is the upgrade, its own button
    if (models?.ready) return <button onClick={() => download(rec.id)}>{t('welcome.models.download', { size: mb(rec.size_mb) })}</button>;
    return null;
  };
  const cloudOn = cloud?.services.find((s) => s.has_key);
  // cloud recognition: offered beside the download (no download, more accurate; the recording goes to the service),
  // first on a weak PC; chosen only here or in Settings — never switched on by itself
  const offers = models?.cloud_allowed === false ? [] : speechOffers(curated);
  const speechOn = offers.find((o) => cloud?.services.some((s) => s.has_key && s.preset === o.service));
  const cloudRecName = models?.selected_cloud ? models.models.find((m) => m.id === models.selected)?.name : null;
  const useCloudRec = async () => {
    if (speechOn) {
      await dictateInCloud(speechOn.service, speechOn.model).catch(() => {});
      load();
    } else setSpeechOpen(true);
  };

  const models_ = (
    <div className="wl-rows">
      {ms === 'tools' && (
        <Notice tone="busy" title={t('welcome.tools.title')} detail={t('welcome.tools.detail')}>
          {uvProg && (
            <span className="mprog" data-testid="uv-progress">
              <progress max={uvProg.total > 0 ? uvProg.total : undefined} value={uvProg.total > 0 ? Math.min(uvProg.done, uvProg.total) : undefined} />
              <span className="dim small">
                {uvProg.total > 0 ? t('dictation.model.progress', { done: mb(uvProg.done), total: mb(uvProg.total) }) : mb(uvProg.done)}
              </span>
            </span>
          )}
        </Notice>
      )}
      {(ms === 'tools_failed' || ms === 'list_failed') && <Notice tone="err" title={t('welcome.tools.failed')} detail={t('welcome.tools.failed_detail')} />}
      {ms === 'checking' && <Notice tone="busy" title={t('welcome.models.checking')} />}
      {/* one divided list, no section labels (the Mac's step 3): dictation's model, then the optional cloud model */}
      {rec && (
        <Row icon="text-cursor" first title={t('welcome.models.kind')} detail={`${t('welcome.models.what')}${zh ? '' : ' '}${rec.name}`} testid="welcome-model">
          {modelTrail()}
        </Row>
      )}
      {rec && !models?.selected_cloud && (dl || ms === 'failed' || ms === 'offer') && (
        <div className="wl-status" data-testid="welcome-model-status">
          {dl ? (
            <>
              <ModelProgress dl={dl} total={modelSize} wide onStop={() => api.modelDownloadCancel().catch(() => {})} />
              <span className="dim small">{t('welcome.models.background')}</span>
            </>
          ) : ms === 'failed' ? (
            <span className="warn small">{t('welcome.models.failed')}</span>
          ) : (
            <span className="dim small">{t('welcome.models.needed')}</span>
          )}
        </div>
      )}
      {win && models && offers.length > 0 && (
        <Row icon="waveform" title={t('welcome.cloudrec.title')} testid="welcome-cloudrec"
          detail={cloudRecName ? t('welcome.cloudrec.on', { name: cloudRecName })
            : models.weak ? t('welcome.cloudrec.detail_weak')
            : t('welcome.cloudrec.detail', { size: mb(rec?.size_mb ?? 0) })}>
          {cloudRecName
            ? <button onClick={() => api.dictationUse(null).then(load, () => {})}>{t('welcome.cloudrec.local')}</button>
            : <button onClick={useCloudRec}>{t('welcome.cloudrec.use')}</button>}
        </Row>
      )}
      {speechOpen && <AddSpeechCloud onClose={() => setSpeechOpen(false)}
        onDone={async (s, service) => {
          setCloud(s);
          setSpeechOpen(false);
          const o = offers.find((x) => x.service === service);
          if (o) await dictateInCloud(o.service, o.model).catch(() => {});
          load();
        }} />}
      <Row icon="cloud" first={!rec} title={t('welcome.cloud.title')}
        detail={cloudOn ? `${t('welcome.cloud.detail')} ${t('welcome.cloud.on', { name: t(`cloud.preset.${cloudOn.preset}`) })}` : t('welcome.cloud.detail')}
        testid="welcome-cloud">
        <button onClick={() => setCloudOpen(true)}>
          {t(cloudOn ? 'welcome.cloud.change' : 'welcome.cloud.add')}
        </button>
      </Row>
      {cloudOpen && <AddCloudModel connected={cloud} onClose={() => setCloudOpen(false)} onDone={(s) => (setCloud(s), setCloudOpen(false))} />}
      <p className="wl-foot pin">{t('welcome.models.later')}</p>
    </div>
  );

  const tryNotice = () => {
    switch (tryBlock) {
      case 'off':
        return <Notice tone="warn" title={t('welcome.try.off')} detail={t('welcome.try.off_detail')} />;
      case 'mic':
        return <Notice tone="warn" title={t('welcome.try.no_mic')} detail={t(mic?.device ? 'welcome.mic.denied_detail' : 'welcome.mic.none_detail')} />;
      case 'downloading':
        return (
          <Notice tone="busy" title={t('welcome.try.downloading')} detail={t('welcome.try.downloading_detail')}>
            {dl && <ModelProgress dl={dl} total={modelSize} wide />}
          </Notice>
        );
      case 'no_model':
        return <Notice tone="warn" title={t('welcome.try.no_model')} detail={t('welcome.try.no_model_detail')} />;
      default:
        return <Notice tone="err" title={t('welcome.tools.failed')} detail={t('welcome.tools.failed_detail')} />;
    }
  };

  const hint = listening && !tried
    ? t(mode === 'hold' ? 'welcome.try.listening.hold' : 'welcome.try.listening', { key: keyName })
    : t(mode === 'hold' ? 'welcome.try.how.hold' : 'welcome.try.how');
  const tryIt = (
    <div className="wl-rows">
      {win && (tryBlock ? (
        <div className="wl-trycard blocked">{tryNotice()}</div>
      ) : (
        <div className={`wl-trycard${tried ? ' done' : ''}${listening && !tried ? ' live' : ''}`} onClick={() => box.current?.focus()} data-testid="welcome-try">
          <div className="wl-how">
            <KeyCaps keys={keyCaps} />
            <span className="dim">{listening && !tried && <span className="wl-live" aria-hidden />}{hint}</span>
          </div>
          <textarea
            ref={box}
            autoFocus
            rows={4}
            value={text}
            placeholder={listening ? '' : t('welcome.try.placeholder')}
            onChange={(e) => setText(e.target.value)}
            onPaste={() => {
              // dictation types by pasting: a paste after the key was pressed here is the first dictation
              if (pressedHere.current) setTried(true);
              setListening(false);
              pastedAt.current = Date.now();
            }}
            onKeyDown={(e) => {
              // the double tap presses Return right after its paste: that is the send
              if (e.key === 'Enter' && tried && Date.now() - pastedAt.current < 2000) {
                e.preventDefault();
                setSent(true);
              }
            }}
          />
          {tried && (
            <div className="wl-checks">
              <span className="wl-works"><OkMark size={15} />{t('welcome.try.works')}</span>
              <span className="dim wl-sub">{sent ? t('welcome.try.sent') : t('welcome.try.send_next', { key: keyName })}</span>
            </div>
          )}
        </div>
      ))}
      {login?.supported && (
        <div className="wl-pinned">
          <Row icon="power" first title={t('welcome.login')} detail={t(win ? 'welcome.login.detail' : 'welcome.login.detail_plain')} testid="welcome-login">
            <label className="wl-switch">
              <input type="checkbox" role="switch" checked={openAtLogin} onChange={(e) => setOpenAtLogin(e.target.checked)} aria-label={t('welcome.login')} />
              <span aria-hidden />
            </label>
          </Row>
          {/* Windows' one fact the Mac has no need to say: closing the window leaves Blurt in the tray */}
          <p className="wl-note">{t('welcome.line_plain')}</p>
        </div>
      )}
    </div>
  );

  return (
    <div className="wl-root" data-testid="welcome" data-step={step} data-key-probe={step === 'dictation' ? '' : undefined}>
      <div className="wl-panel" role="dialog" aria-modal="true" aria-labelledby="wl-heading">
        <div className="wl-hero" aria-hidden>
          <span className="wl-glow" />
          {/* the Mac's onboarding hero: Peep says hello (the last step: a peep and a hop), then idles; 108 px */}
          <Mascot key={last ? 'done' : 'hello'} clip={last ? 'done' : 'hello'} then="idle" size={108} />
        </div>
        <div className="wl-main">
          <header className="wl-header">
            <h1 id="wl-heading" className="wl-h1 g-text">{heading[0]}</h1>
            <p className="dim">{heading[1]}</p>
          </header>
          <div className="wl-body">
            {step === 'welcome' && welcome}
            {step === 'dictation' && dictation}
            {step === 'models' && models_}
            {step === 'try' && tryIt}
          </div>
          <footer className="wl-footer">
            <span className="wl-dots" role="img" aria-label={t('welcome.step_of', { n: ix + 1, total: steps.length })}>
              {steps.map((s, i) => <span key={s} className={i === ix ? 'on' : ''} />)}
            </span>
            <span className="grow" />
            {!last && <button className="link" onClick={() => finish(false)} data-testid="welcome-skip">{t('welcome.skip')}</button>}
            {action && <button className="link" onClick={next}>{t('welcome.not_now')}</button>}
            {ix > 0 && <button onClick={() => setIx(ix - 1)}>{t('welcome.back')}</button>}
            {action ? (
              <button className="primary" onClick={action.run} disabled={action.disabled}>{action.title}</button>
            ) : (
              <button className="primary" onClick={next} data-testid="welcome-next">{t(last ? 'welcome.done' : 'welcome.next')}</button>
            )}
          </footer>
        </div>
      </div>
    </div>
  );
}
