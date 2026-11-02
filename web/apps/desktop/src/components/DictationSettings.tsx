// Settings → Dictation, Copy Text from Screen and Models on Windows (the Mac's Settings/DictationPane.swift,
// ScreenTextPane.swift, SpeechPane.swift + CloudServicesPane.swift), on the panes' one grid (../settings/kit.tsx):
//   Dictation       the switch, the key, how it starts and stops, the sounds · the style (Verbatim / Light) · what
//                   double-tap Ctrl translates into and the model that translates · the history (how long, clear)
//                   and the models dictation runs on (chosen in Models)
//   Copy Text …     what Alt+Shift+T translates into (its own target, not dictation's) and the model that translates
//   Models          the recommended download while it is missing · the cloud models you connected (the key in
//                   Windows Credential Manager, never in a file; Add Cloud Model… is a sheet with Test) · the model
//                   each job uses · every speech model on this PC
// What the Mac has here that Windows doesn't (yet): docs/design/windows-parity/settings.md.
import { useEffect, useRef, useState } from 'react';
import { api, listen, type AgentSetupState, type AgentSetupStep, type AppStatus, type AsrModel, type CloudSummary, type CuratedOption, type DictationHistory, type VoiceprintEvent, type VoiceprintStatus } from '../api';
import { t } from '../i18n';
import { Icon } from '@blurt/icons';
import { Group, Line, Page, Popup, Row, S, Switch, TextLink, Toggle } from '../settings/kit';
import { mb, ModelProgress, useDictationModels } from './ModelDownload';
import { openWordsTab } from './DictationView';
import { Menu, type MenuAt, type MenuEntry } from './Menu';

type Save = (patch: Record<string, unknown>) => Promise<void>;

/** The translate targets (the Mac's DictationTranslateTarget), each by its own name. Auto is the pair Windows' polish
 * server uses for "auto": Chinese ↔ English. */
const TARGETS: [string, string][] = [
  ['en', 'English'], ['zh', '简体中文'], ['zh-Hant', '繁體中文'], ['ja', '日本語'], ['ko', '한국어'], ['fr', 'Français'],
  ['de', 'Deutsch'], ['es', 'Español'], ['pt', 'Português'], ['it', 'Italiano'], ['ru', 'Русский'],
];
const targetChoices = (): [string, string][] => [['auto', S('dictation.translate.target.auto', '简体中文', 'English')], ...TARGETS];
/** what an older Windows build wrote ("zh-Hans") in the Mac's words */
const normTarget = (v: unknown) => (v === 'zh-Hans' ? 'zh' : typeof v === 'string' && [...TARGETS.map(([k]) => k), 'auto'].includes(v) ? v : 'auto');

type Route = { service: string; model: string };
/** A cloud model by the name Settings shows ("DeepSeek V4.1 Flash"), never its API id ("deepseek-flash") — the Mac's
 *  CuratedModels.option(job, on: service, model:).name: the job's own entry on that service first, then the same
 *  model listed for another job or service; only a model Blurt never measured keeps its id (the Mac's Custom Model). */
export function modelName(sum: CloudSummary | null, curated: Record<string, CuratedOption[]> | undefined, job: string, r: Route): string {
  const preset = sum?.services.find((s) => s.id === r.service)?.preset;
  const all = Object.entries(curated ?? {}).flatMap(([j, os]) => os.map((o) => ({ j, o })));
  const hit = all.find((x) => x.j === job && x.o.model === r.model && (!preset || x.o.service === preset))
    ?? all.find((x) => x.o.model === r.model && (!preset || x.o.service === preset))
    ?? all.find((x) => x.o.model === r.model);
  return hit?.o.name ?? r.model;
}
/** what a text job runs on (translate follows polish until it has its own route) */
const routeOf = (sum: CloudSummary | null, job: string): Route | null => sum?.routes?.[job] ?? (job === 'translate' ? sum?.routes?.polish ?? null : null);

/** "DeepSeek V4.1 Flash · cloud" / "Not set" for a text job (the Mac's CloudText.uses). */
function uses(sum: CloudSummary | null, job: 'polish' | 'translate', curated?: Record<string, CuratedOption[]>): string {
  const r = routeOf(sum, job);
  return r ? S('models.uses.cloud', modelName(sum, curated, job, r)) : S('models.uses.none');
}
function useCurated() {
  const [c, setC] = useState<Record<string, CuratedOption[]>>({});
  useEffect(() => {
    api.cloudCurated().then((x) => setC(x.jobs ?? {}), () => {});
  }, []);
  return c;
}
function useCloud() {
  const [sum, setSum] = useState<CloudSummary | null>(null);
  useEffect(() => {
    api.cloudSummary().then(setSum, () => setSum({ services: [], routes: {} }));
  }, []);
  return [sum, setSum] as const;
}

// ------------------------------------------------------------------ Dictation

export function DictationPane({ cfg, save, goModels, goTranslate, keyOf }: {
  cfg: Record<string, any>;
  save: Save;
  goModels: () => void;
  goTranslate: () => void;
  /** a capture action's key as the Shortcuts page shows it ("Alt+Shift+V"); "" when it is off */
  keyOf?: (action: string) => string;
}) {
  const d = cfg.record?.dictation ?? {};
  const set = (patch: Record<string, unknown>) => save({ record: { dictation: { ...d, ...patch } } });
  // record.dictation.* as dictation/prefs.rs reads it (the Mac's keys; the engine reloads them when the file changes)
  const key = d.key === 'either_option' ? 'either_option' : 'right_option';
  const mode: string = ['auto', 'tap', 'hold'].includes(d.mode) ? d.mode : 'auto';
  const styles: Record<string, any> = d.styles ?? {};
  const style: string = d.polish === 'off' ? 'verbatim' : ['verbatim', 'light', 'structured', 'auto'].includes(styles.default) ? styles.default : 'light';
  const tap: string = d.modifier_tap === 'single' ? 'single' : 'double';
  const [sum] = useCloud();
  const curated = useCurated();
  const { models, dl } = useDictationModels();
  const [hist, setHist] = useState<DictationHistory | null>(null);
  const [mics, setMics] = useState<{ default: string | null; devices: string[] } | null>(null);
  const [words, setWords] = useState<{ term: string; state: string; source?: string }[] | null>(null);
  const [byApp, setByApp] = useState(false);
  const [confirmClear, setConfirmClear] = useState(false);
  const loadHist = () => api.dictationHistory().then(setHist, () => {});
  const loadWords = () => api.dictationWords().then((w) => setWords(w.terms), () => {});
  useEffect(() => {
    loadHist();
    loadWords();
    api.dictationMics().then(setMics, () => {});
  }, []);
  const days: number = d.retention_days ?? hist?.retention_days ?? 30;
  const sel = models?.models.find((m) => m.id === models.selected);
  // the polish model beside the recogniser while a style polishes ("Fun-ASR-Nano (CPU) · DeepSeek V4.1 Flash (cloud)",
  // the Mac's modelNames); Windows polishes in the cloud only
  const polishRoute = style !== 'verbatim' ? routeOf(sum, 'polish') : null;
  const modelLine = !models
    ? undefined
    : dl
      ? S('speech.rec.downloading', models.models.find((m) => m.id === dl.id)?.name ?? '')
      : sel?.installed
        ? [sel.name, polishRoute && S('dictation.models.cloud', modelName(sum, curated, 'polish', polishRoute))].filter(Boolean).join(' · ')
        : S('dictation.models.missing', models.models.find((m) => m.id === models.recommended)?.name ?? '');
  const styleName = (s: string) => S(`dictation.style.${s}`);
  const STYLES = ['verbatim', 'light', 'structured', 'auto'];
  /** The one Style choice: Verbatim turns polish off; the others turn it on with that style as the default. */
  const setStyle = (s: string) => set({ polish: s === 'verbatim' ? 'off' : undefined, styles: { ...styles, default: s === 'light' ? undefined : s } });
  const CATS = ['chat', 'code', 'mail', 'notes', 'other'];
  const apps = Object.entries((styles.apps ?? {}) as Record<string, string>);
  const byAppSummary = [
    ...CATS.filter((c) => styles[c]).map((c) => S('dictation.style.by_app.pair', S(`dictation.style.cat.${c}`), styleName(styles[c]))),
    ...(apps.length ? [S('dictation.style.by_app.apps', apps.length)] : []),
  ].join(' · ') || S('dictation.style.by_app.detail');
  const mine = (words ?? []).filter((w) => w.state === 'active');
  const suggested = (words ?? []).filter((w) => w.state !== 'active');
  // Polish time limit (record.dictation.polish_timeout_ms): Windows' base is 4 s (engine.rs), the Mac's 3 s
  const timeout: number = typeof d.polish_timeout_ms === 'number' ? Math.min(10, Math.max(1, Math.round(d.polish_timeout_ms / 500) / 2)) : 4;
  // the reformat key (record.hotkeys.reformat, Alt+Shift+L by default) as the row says it
  const hk = cfg.record?.hotkeys?.reformat;
  const reformatKey = hk === 'off' ? '' : typeof hk === 'string' && hk ? hk.split('+').map((p: string) => ({ opt: 'Alt', alt: 'Alt', shift: 'Shift', ctrl: 'Ctrl', cmd: 'Ctrl' })[p.toLowerCase()] ?? p.toUpperCase()).join('+') : 'Alt+Shift+L';
  const setTimeoutS = (x: number) => set({ polish_timeout_ms: x === 4 ? undefined : Math.round(x * 1000) });
  const on = d.enabled !== false;
  const cancelKey: string = ['ctrl_esc', 'shift_esc'].includes(d.cancel_key) ? d.cancel_key : 'esc';
  const cancelName = ({ esc: 'Esc', ctrl_esc: 'Ctrl+Esc', shift_esc: 'Shift+Esc' } as Record<string, string>)[cancelKey];
  // Start and stop's ⓘ (the Mac's dictation.mode.help): the key that cancels, and the voice note's key for keeping speech
  const modeHelp = S('dictation.mode.help', cancelName, keyOf?.('voice') || S('dictation.settings.voice_note_off'));
  const doubleTap = d.double_tap_send !== false;
  return (
    <Page id="dictation">
      {/* the one thing that stops dictation working: said on the pane's first screen, not only in its last row */}
      {on && models && !sel?.installed && !dl && (
        <div className="st-notice warn" role="status" data-testid="dictation-no-model">
          <Icon name="warning" size={16} />
          <span className="grow">{S('dictation.nomodel.notice', models.models.find((m) => m.id === models.recommended)?.name ?? '')}</span>
          <button className="primary" onClick={goModels}>{S('dictation.models.get_in_speech')}</button>
        </div>
      )}
      <Group id="dictation.main" title="">
        <Toggle id="dictation.enable" on={on} set={(v) => set({ enabled: v ? undefined : false })}
          detail={on ? undefined : S('dictation.enable.off_detail', S(`dictation.key.${key}.inline`))} />
        {/* off: the rows stay where they are, dimmed (the Mac's .disabled(!enabled)) — the page doesn't reshuffle */}
        {(
          <div className={`st-set ${on ? '' : 'off'}`} inert={!on}>
            <Row id="dictation.key" detail={key === 'either_option' ? S('dictation.settings.either_hint') : undefined}>
              <Popup label={S('dictation.settings.key')} value={key} choices={[['right_option', S('dictation.key.right_option')], ['either_option', S('dictation.key.either_option')]]}
                onChange={(v) => set({ key: v })} />
            </Row>
            <Row id="dictation.mode" detail={S(`dictation.mode.${mode}.detail`, S(`dictation.key.${key}.inline`))} help={modeHelp}>
              <Popup label={S('dictation.settings.mode')} value={mode} choices={(['auto', 'tap', 'hold'] as const).map((m) => [m, S(`dictation.mode.${m}`)] as [string, string])}
                onChange={(v) => set({ mode: v })} />
            </Row>
            <Row id="dictation.cancel_key">
              <Popup label={S('dictation.settings.cancel_key')} value={cancelKey}
                choices={[['esc', S('dictation.settings.cancel_key.default', 'Esc')], ['ctrl_esc', 'Ctrl+Esc'], ['shift_esc', 'Shift+Esc']]}
                onChange={(v) => set({ cancel_key: v === 'esc' ? undefined : v })} />
            </Row>
            {/* a Toggle with the Mac's ⓘ (tap to check, double-tap to send) */}
            <Row id="dictation.double_tap" detail={S('dictation.settings.double_tap.key', S(`dictation.key.${key}.inline`))} help={S('dictation.settings.double_tap.help')}>
              <Switch on={doubleTap} label={S('dictation.settings.double_tap')} set={(v) => set({ double_tap_send: v ? undefined : false })} />
            </Row>
            <Row id="dictation.modifier_tap">
              <Popup label={S('dictation.settings.modifier_tap')} value={tap} choices={[['double', S('dictation.mode.modifier.double')], ['single', S('dictation.mode.modifier.single')]]}
                onChange={(v) => set({ modifier_tap: v === 'double' ? undefined : v, modifier_tap_shift: undefined, modifier_tap_command: undefined })} />
            </Row>
            <Row id="dictation.mic" help={null}>
              <Popup label={S('dictation.mic.section')} value={typeof d.mic === 'string' && d.mic ? d.mic : ''} dividers={mics?.devices.length ? [1] : []}
                choices={[['', mics?.default ? `${S('dictation.mic.default')} (${mics.default})` : S('dictation.mic.default')], ...(mics?.devices ?? []).map((m) => [m, m] as [string, string]),
                  ...(typeof d.mic === 'string' && d.mic && !(mics?.devices ?? []).includes(d.mic) ? [[d.mic, d.mic] as [string, string]] : [])]}
                onChange={(v) => set({ mic: v || undefined })} />
            </Row>
            <OnlyMyVoiceRow on={d.only_my_voice === true} set={(v) => set({ only_my_voice: v ? true : undefined })} />
            <Toggle id="dictation.sounds" on={d.sounds !== false} set={(v) => set({ sounds: v ? undefined : false })} />
            <Toggle id="dictation.stop_sound" on={d.stop_sound === true} set={(v) => set({ stop_sound: v ? true : undefined })} />
          </div>
        )}
      </Group>

      <Group id="dictation.text">
        <div className={`st-set ${on ? '' : 'off'}`} inert={!on}>
          <Row id="dictation.default_style" detail={S(`dictation.style.${style}.detail`)}>
            <Popup label={S('dictation.style.default')} value={style} choices={STYLES.map((s) => [s, styleName(s)] as [string, string])} onChange={setStyle} />
          </Row>
          {/* a disclosure, not a dialog: the whole row is its button and its chevron turns (DictationPane.showByApp);
              none for Verbatim, which tidies nothing anywhere */}
          {style !== 'verbatim' && (
            <div className="st-row st-disclose" data-setting="dictation.by_app" role="button" tabIndex={0} aria-expanded={byApp}
              onClick={() => setByApp((x) => !x)} onKeyDown={(e) => (e.key === 'Enter' || e.key === ' ') && (e.preventDefault(), setByApp((x) => !x))}>
              <div className="st-text">
                <div className="st-row-title"><span>{S('dictation.style.by_app')}</span></div>
                <div className="st-detail">{byAppSummary}</div>
              </div>
              <div className="st-ctl"><Icon name="chevron-right" size={14} className={`st-chev ${byApp ? 'open' : ''}`} /></div>
            </div>
          )}
          {byApp && style !== 'verbatim' && (
            // what it opens sits in one inset block under it (an intro, the kinds, the two switches, the wait, the keys)
            <div className="st-inset">
              <p className="st-inset-lead">{S('dictation.style.by_app.intro')}</p>
              {CATS.map((c) => (
                <Row key={c} id={`dictation.cat.${c}`}>
                  <Popup label={S(`dictation.style.cat.${c}`)} value={styles[c] ?? ''} dividers={[1]}
                    choices={[['', S('dictation.style.cat.same', styleName(style))], ...STYLES.map((s) => [s, styleName(s)] as [string, string])]}
                    onChange={(v) => set({ styles: { ...styles, [c]: v || undefined } })} />
                </Row>
              ))}
              {apps.map(([app, s]) => (
                <Line key={app} icon="screen" title={app} detail={`${S('dictation.style.apps')} · ${styleName(s)}`}>
                  <button className="st-small" title={S('dictation.style.reset.help')}
                    onClick={() => {
                      const rest = { ...(styles.apps ?? {}) };
                      delete rest[app];
                      set({ styles: { ...styles, apps: Object.keys(rest).length ? rest : undefined } });
                    }}>{S('dictation.style.reset')}</button>
                </Line>
              ))}
              <Toggle id="dictation.suggest_lists" on={d.suggest_lists !== false} set={(v) => set({ suggest_lists: v ? undefined : false })} />
              <Toggle id="dictation.learn_styles" on={d.learn_styles !== false} set={(v) => set({ learn_styles: v ? undefined : false })} />
              <Row id="dictation.polish_timeout" detail={S('dictation.polish.timeout.detail')}>
                <Popup label={S('dictation.polish.timeout')} value={timeout}
                  choices={[...new Set([1, 1.5, 2, 2.5, 3, 3.5, 4, 5, 6, 8, 10, timeout])].sort((a, b) => a - b).map((x) => [x, S('dictation.polish.seconds', String(x))] as [number, string])}
                  onChange={(v) => setTimeoutS(v)} />
              </Row>
              <p className="st-inset-foot">{reformatKey ? S('dictation.style.keys', reformatKey) : S('dictation.style.keys.no_hotkey')}</p>
            </div>
          )}
        </div>
        <Row id="dictation.word_list" detail={words ? (
          <>
            {S('dictation.vocab.summary.mine', mine.length)}
            {suggested.length > 0 && <> · <span className="st-warn">{S('dictation.vocab.summary.suggested', suggested.length)}</span></>}
            {` · ${S('dictation.vocab.summary.detail')}`}
          </>
        ) : undefined}>
          {/* the Mac's Manage…: a bordered button — it opens the Dictation page's Words tab */}
          <button onClick={() => { openWordsTab(); window.dispatchEvent(new Event('blurt:open-dictation')); }}>{S('dictation.vocab.manage')}</button>
        </Row>
        <div className={`st-set ${on ? '' : 'off'}`} inert={!on}>
          <Toggle id="dictation.context" on={d.context !== false} set={(v) => set({ context: v ? undefined : false })} />
          <Toggle id="dictation.learn" on={d.learn !== false} set={(v) => set({ learn: v ? undefined : false })} />
        </div>
      </Group>

      <Group id="dictation.translation">
        <div className={`st-set ${on ? '' : 'off'}`} inert={!on}>
          <Row id="dictation.translate">
            <Popup label={S('dictation.translate.settings.title')} value={normTarget(d.translate_target)} wide dividers={[1]} choices={targetChoices()}
              onChange={(v) => set({ translate_target: v === 'auto' ? undefined : v })} />
          </Row>
        </div>
        <Row id="dictation.translate_model" detail={uses(sum, 'translate', curated)}>
          <button onClick={goTranslate}>{S('models.uses.change')}</button>
        </Row>
      </Group>

      <Group id="dictation.data">
        <Row id="dictation.history_saved" detail={hist ? S('dictation.history.summary', hist.entries.length, S('dictation.history.days', days)) : undefined}>
          {/* one control: how long, and — under a line, last — Clear History… (the Mac's historyRow menu: never a
              destructive button at rest); it opens the Dictation page's own confirm (window.confirm shows nothing in
              WebView2 and answers yes) */}
          <Popup label={S('dictation.history.keep')} value={days} dividers={hist?.entries.length ? [4] : []}
            choices={[...[7, 30, 90, 365].map((n) => [n, S('dictation.history.days', n)] as [number, string]), ...(hist?.entries.length ? [[-1, S('dictation.history.clear')] as [number, string]] : [])]}
            onChange={(v) => (v === -1 ? setConfirmClear(true) : set({ retention_days: v === 30 ? undefined : v }))} />
        </Row>
        {confirmClear && (
          <div className="overlay" onClick={() => setConfirmClear(false)}>
            <div className="sheet dict-confirm" role="alertdialog" aria-modal="true" onClick={(e) => e.stopPropagation()}
              onKeyDown={(e) => e.key === 'Escape' && setConfirmClear(false)}>
              <h3>{t('dictation_page.clear.title')}</h3>
              <p>{t('dictation_page.clear.body', { n: hist?.entries.length ?? 0 })}</p>
              {/* the same dialog as the Dictation page's Clear History (Windows' ContentDialog: two equal buttons on a band) */}
              <div className="dict-confirm-foot">
                <button autoFocus className="dict-confirm-cancel" onClick={() => setConfirmClear(false)}>{t('dictation_page.clear.cancel')}</button>
                <button className="dict-danger-tint" onClick={async () => {
                  setConfirmClear(false);
                  await api.dictationEdit({ op: 'clear' });
                  loadHist();
                }}>{t('dictation_page.clear.confirm')}</button>
              </div>
            </div>
          </div>
        )}
        <Toggle id="dictation.keep_audio" on={d.keep_audio !== false} detail={S('dictation.history.keep_audio.detail.days', S('dictation.history.days', days))}
          set={(v) => set({ keep_audio: v ? undefined : false })} />
        <Row id="dictation.models" detail={modelLine} warn={!!models && !sel?.installed && !dl}>
          <button onClick={goModels}>{S(sel?.installed ? 'dictation.models.change' : 'dictation.models.get_in_speech')}</button>
        </Row>
      </Group>
    </Page>
  );
}

// ------------------------------------------------------------------ Only my voice

/** The switch, and beside it (once a voice is set up) Record Again / Delete (the Mac's onlyMyVoiceRow). Turning it on
 *  without a voice profile opens the passage to read; it turns on once the voice is learned (housekeeping.rs). */
function OnlyMyVoiceRow({ on, set }: { on: boolean; set: (v: boolean) => void }) {
  const [vp, setVp] = useState<VoiceprintStatus | null>(null);
  const [sheet, setSheet] = useState(false);
  const [menu, setMenu] = useState<MenuAt | null>(null);
  useEffect(() => {
    api.voiceprintStatus().then(setVp, () => {});
  }, []);
  const enrolled = !!vp?.enrolled;
  // Voice Profile ▾ (the Mac's RowMenu): the app's themed menu under the button, Delete last in the danger ink
  const entries: MenuEntry[] = [
    { label: S('dictation.voiceprint.again'), run: () => setSheet(true) },
    { label: S('dictation.voiceprint.delete'), danger: true, run: async () => {
      set(false);
      setVp(await api.voiceprintClear());
    } },
  ];
  return (
    <Row id="dictation.only_my_voice" detail={S(vp?.stale ? 'dictation.only_my_voice.stale' : 'dictation.only_my_voice.detail')} warn={!!vp?.stale}>
      {(enrolled || vp?.stale) && (
        <>
          <button className="st-small" aria-haspopup="menu" aria-expanded={!!menu}
            onClick={(e) => setMenu(menu ? null : { x: 0, y: 0, anchor: e.currentTarget, align: 'start' })}>
            {S('dictation.voiceprint.more')} <Icon name="chevron-down" size={11} />
          </button>
          {menu && <Menu entries={entries} at={menu} label={S('dictation.voiceprint.more')} onClose={() => setMenu(null)} />}
        </>
      )}
      {/* the sheet takes the focus: the switch's ring doesn't stay lit under its scrim */}
      <Switch on={on && enrolled} label={S('dictation.only_my_voice')} set={(v) => (v && !enrolled ? ((document.activeElement as HTMLElement | null)?.blur(), setSheet(true)) : set(v))} />
      {sheet && (
        <VoiceprintSheet ready={!!vp?.model_ready} onClose={() => setSheet(false)}
          onLearned={(st) => (setVp(st), setSheet(false), set(true))} />
      )}
    </Row>
  );
}

/** Reading the passage (the Mac's VoiceprintSheet): the text, the microphone's level, how much has been heard; the
 *  model downloads meanwhile. Done is there once enough was heard; the take also ends by itself. */
function VoiceprintSheet({ ready, onClose, onLearned }: { ready: boolean; onClose: () => void; onLearned: (s: VoiceprintStatus) => void }) {
  const [phase, setPhase] = useState<VoiceprintEvent['phase']>('idle');
  const [progress, setProgress] = useState(0);
  const [canFinish, setCanFinish] = useState(false);
  const [failed, setFailed] = useState<string | null>(null);
  const [downloading, setDownloading] = useState(!ready);
  const live = useRef(true);
  useEffect(() => {
    live.current = true;
    if (!ready) {
      api.voiceprintPrepare().then((r) => {
        if (!live.current) return;
        setDownloading(false);
        if (!r.ok) setFailed('network');
      }, () => live.current && (setDownloading(false), setFailed('network')));
    }
    const off = listen<VoiceprintEvent>('voiceprint://changed', (e) => {
      setPhase(e.phase);
      setProgress(e.progress ?? 0);
      setCanFinish(!!e.can_finish);
      if (e.failed) setFailed(e.failed);
      if (e.learned) onLearned({ enrolled: true, stale: false, model_ready: true });
    });
    const k = (e: KeyboardEvent) => e.key === 'Escape' && cancel();
    window.addEventListener('keydown', k);
    return () => {
      live.current = false;
      off();
      window.removeEventListener('keydown', k);
    };
  }, []);
  const cancel = () => {
    api.voiceprintStop(false).catch(() => {});
    onClose();
  };
  const failure = (c: string) =>
    c === 'too_short' ? S('dictation.voiceprint.too_short') : c === 'mic_failed' ? S('dictation.voiceprint.mic_failed') : c === 'network' ? S('dictation.voiceprint.network') : S('dictation.voiceprint.failed', c);
  const status = failed
    ? failure(failed)
    : phase === 'starting' ? S('dictation.voiceprint.starting')
      : phase === 'recording' ? S('dictation.voiceprint.recording')
        : phase === 'saving' ? S(downloading ? 'dictation.voiceprint.downloading' : 'dictation.voiceprint.saving', 28)
          : downloading ? S('dictation.voiceprint.downloading', 28) : '\u00a0';
  const recording = phase === 'recording';
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && cancel()}>
      <div className="sheet st-sheet vp-sheet" role="dialog" aria-label={S('dictation.voiceprint.title')} data-testid="voiceprint-sheet">
        <div className="st-col" style={{ padding: '18px 20px' }}>
          <h1 className="st-title">{S('dictation.voiceprint.title')}</h1>
          <p className="st-foot">{S('dictation.voiceprint.read')}</p>
          <div className={`st-well st-passage ${recording ? 'on' : ''}`}>{S('dictation.voiceprint.passage')}</div>
          <div className="st-passage-bar">
            <Icon name="mic" size={14} />
            <span className="st-bar"><span style={{ width: `${Math.round(progress * 100)}%` }} /></span>
          </div>
          <p className={`st-foot ${failed ? 'st-warn' : ''}`} aria-live="polite">{status}</p>
          <div className="st-ctl" style={{ marginTop: 12 }}>
            <span className="st-foot st-dim" style={{ marginRight: 'auto' }}>{S('dictation.voiceprint.private')}</span>
            <button onClick={cancel}>{S('dictation.voiceprint.cancel')}</button>
            {recording || phase === 'saving' ? (
              <button className="primary" disabled={!canFinish || phase === 'saving'} onClick={() => api.voiceprintStop(true)}>{S('dictation.voiceprint.done')}</button>
            ) : (
              <button className="primary" disabled={phase === 'starting'} onClick={() => (setFailed(null), setProgress(0), api.voiceprintStart().catch(() => setFailed('mic_failed')))}>{S('dictation.voiceprint.start')}</button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ Copy Text from Screen

export function ScreenTextPane({ cfg, save, goTranslate }: { cfg: Record<string, any>; save: Save; goTranslate: () => void }) {
  const st = cfg.record?.screen_text ?? {};
  const tr = st.translate ?? {};
  const [sum, setSum] = useCloud();
  const curated = useCurated();
  // Copy (Alt+Shift+C): the second, cloud pass that reads the screenshot (the Mac's 精确识别) — the same setting as
  // Models → Copy Text from Screen (record.cloud.jobs.vision), so the two never disagree
  const [jobs, setJobs] = useState<Record<string, unknown>>({});
  useEffect(() => {
    api.settings().then((x) => setJobs(x.config?.record?.cloud?.jobs ?? {}), () => {});
  }, []);
  const conn = new Map((sum?.services ?? []).map((x) => [x.preset, x.id]));
  const route = sum?.routes?.vision;
  const opts = (curated.vision ?? []).filter((o) => conn.has(o.service)).map((o) => [`${conn.get(o.service)}:${o.model}`, o.name] as [string, string]);
  const named = route ? modelName(sum, curated, 'vision', route) : null;
  const value = jobs.vision && route ? `${route.service}:${route.model}` : 'auto';
  // a model picked elsewhere that the measured list doesn't have (an agent's setup): still the pop-up's value, by name
  if (value !== 'auto' && !opts.some(([v]) => v === value)) opts.push([value, named ?? value]);
  const setVision = async (v: string) => {
    const [service, model] = v === 'auto' ? [null, null] : v.split(':');
    setSum(await api.cloudJobSet('vision', service, model));
    api.settings().then((x) => setJobs(x.config?.record?.cloud?.jobs ?? {}), () => {});
  };
  return (
    <Page id="screentext">
      <Group id="screentext.copy">
        <Row id="screentext.precise" detail={named ? S('speech.auto.using', S('screentext.precise.detail'), named) : undefined}>
          <Popup label={S('screentext.precise')} value={value} dividers={opts.length ? [1] : []} choices={[['auto', S('win.models.auto')], ...opts]} onChange={setVision} />
        </Row>
      </Group>
      <Group id="screentext.translation">
        <Row id="screentext.translate">
          {/* the same 240 px as dictation's target (the Mac's TranslateTargets.popupWidth): "Auto: 简体中文 ⇄ English" whole */}
          <Popup label={S('settings.screen_text.translate', '')} value={normTarget(tr.target)} wide dividers={[1]} choices={targetChoices()}
            onChange={(v) => save({ record: { screen_text: { ...st, translate: { cloud: tr.cloud ?? true, ...(v === 'auto' ? {} : { target: v }) } } } })} />
        </Row>
        <Row id="screentext.translate_model" detail={uses(sum, 'translate', curated)}>
          <button onClick={goTranslate}>{S('models.uses.change')}</button>
        </Row>
      </Group>
    </Page>
  );
}

// ------------------------------------------------------------------ Models

type TextJob = 'polish' | 'translate' | 'vision';
/** the curated services (CloudServiceSheetModel.curated); Volcengine Speech is speech-only, with an App ID and an Access
 *  Token kept together as one Credential Manager item (housekeeping.rs `cloud_connect_speech`) */
const PRESETS = [
  { id: 'deepseek', page: 'https://platform.deepseek.com/api_keys', recommended: true, pair: false },
  { id: 'dashscope', page: 'https://bailian.console.aliyun.com/?tab=model#/api-key', recommended: false, pair: false },
  { id: 'volcengine-speech', page: 'https://console.volcengine.com/speech/app', recommended: false, pair: true },
] as const;
/** Volcengine Speech only where it can serve: someone in mainland China or who speaks Chinese (its accounts need
 *  mainland verification; VolcengineSpeech.offered) */
const volcOffered = () => {
  const langs = typeof navigator === 'undefined' ? [] : [...(navigator.languages ?? []), navigator.language];
  return langs.some((l) => /^(zh|yue)\b/i.test(l) || /-CN$/i.test(l));
};
/** a preset's string key: "volcengine-speech" → models.preset.volcengine_speech */
const presetKey = (p: string) => p.replace(/-/g, '_');

/** The Add Cloud Model sheet as the setup assistant opens it (the Mac's welcome row opens the same sheet as
 *  Settings → Models): the curated services not connected yet, or all of them. */
export function AddCloudModel({ connected, onClose, onDone }: { connected: CloudSummary | null; onClose: () => void; onDone: (s: CloudSummary) => void }) {
  const taken = new Set(connected?.services.map((s) => s.preset) ?? []);
  const left = PRESETS.filter((p) => !taken.has(p.id) && (p.id !== 'volcengine-speech' || volcOffered()));
  return <AddCloudSheet onClose={onClose} onDone={onDone} presets={left.length ? left : PRESETS.filter((p) => !p.pair || volcOffered())} />;
}

/** Stop, beside a download's progress (dictation/commands.rs model_download_cancel: the child ends, partial files go). */
export function StopDownload() {
  // the same size as the Download it replaced
  return <button onClick={() => api.modelDownloadCancel().catch(() => {})}>{S('speech.download.stop')}</button>;
}

export function ModelsPane({ status, onToast }: { status: AppStatus; onToast: (m: string) => void }) {
  const win = status.platform === 'win';
  const [sum, setSum] = useCloud();
  const [adding, setAdding] = useState(false);
  const [agentSheet, setAgentSheet] = useState(false);
  // the agents that can run a setup session here: installed, with an interactive session (AgentSetupAgents)
  const [setupAgents, setSetupAgents] = useState<{ id: string; name: string }[]>([]);
  useEffect(() => {
    api.detect({ login: false }).then((d) => setSetupAgents(d.agents.filter((a) => a.installed && (a.session ?? a.interactive === 'terminal')).map((a) => ({ id: a.id, name: a.name }))), () => {});
  }, []);
  const { models, err, dl, failed, failedId, load, download } = useDictationModels();
  const rec = models?.models.find((m) => m.id === models.recommended);
  const taken = new Set(sum?.services.map((s) => s.preset) ?? []);
  const left = PRESETS.filter((p) => !taken.has(p.id) && (p.id !== 'volcengine-speech' || volcOffered()));
  const installed = models?.models.filter((m) => m.installed) ?? [];
  // the speech jobs (transcribe.py: asr.models per purpose, asr.auto) and the text jobs (record.cloud.jobs)
  const [asr, setAsr] = useState<{ auto: boolean; selected: Record<string, string>; models: AsrModel[] } | null>(null);
  const loadAsr = () => api.asrModels().then((r: any) => setAsr({ auto: r.auto !== false, selected: r.selected ?? {}, models: (r.models ?? []).filter((m: AsrModel) => m.role === 'asr') }), () => {});
  const [curated, setCurated] = useState<Record<string, CuratedOption[]>>({});
  // which text jobs were picked by hand (record.cloud.jobs); the summary's routes say what runs
  const [jobsCfg, setJobsCfg] = useState<Record<string, unknown>>({});
  const loadJobs = () => api.settings().then((x) => setJobsCfg(x.config?.record?.cloud?.jobs ?? {}), () => {});
  useEffect(() => {
    loadAsr();
    loadJobs();
    api.cloudCurated().then((c) => setCurated(c.jobs ?? {}), () => {});
  }, []);
  const asrName = (id?: string) => (asr?.models.find((m) => m.id === id)?.name as string | undefined) ?? id ?? S('speech.purpose.none_yet');
  const choosePurpose = async (p: string, id: string) => {
    if (id === 'auto') await api.asrAutoApply();
    else {
      // a hand-picked model for one purpose: automatic choice ends, the other purposes keep what they use now
      const cur: Record<string, string> = { ...(asr?.selected ?? {}) };
      cur[p] = id;
      await api.setSettings({ asr: { models: cur, auto: false } });
    }
    loadAsr();
  };
  const purposeRow = (p: 'batch' | 'note', icon: 'film' | 'mic') => {
    const now = asr?.selected?.[p];
    const here = (asr?.models ?? []).filter((m) => m.installed && m.runs_here !== false && m.local !== false);
    // a hand-picked model that isn't here (any more) stays the pop-up's value, said as None (the Mac's ModelPopUp)
    const gone = !asr?.auto && now && !here.some((m) => m.id === now) ? [[now, S('speech.purpose.none_yet')] as [string, string]] : [];
    return (
      <Row key={p} id={`speech.${p}`} icon={icon} detail={asr?.auto ? S('speech.auto.using', S(`speech.purpose.${p}.detail`), asrName(now)) : undefined}>
        {asr ? (
          <Popup label={S(`speech.purpose.${p}`)} value={asr.auto ? 'auto' : now ?? 'auto'} dividers={[1]}
            choices={[['auto', S('win.models.auto')], ...gone, ...here.map((m) => [String(m.id), String(m.name ?? m.id)] as [string, string])]} onChange={(v) => choosePurpose(p, v)} />
        ) : <span className="st-detail">{S('speech.loading')}</span>}
      </Row>
    );
  };
  /** A text job's pop-up: Automatic, then the measured models of each connected service; a curated service with no
   *  key yet says so (picking it opens Add Cloud Model). */
  const jobValue = (job: TextJob) => {
    const r = sum?.routes?.[job];
    return jobsCfg[job] && r ? `${r.service}:${r.model}` : 'auto';
  };
  const jobChoices = (job: TextJob): [string, string][] => {
    const conn = new Map((sum?.services ?? []).map((x) => [x.preset, x.id]));
    const opts = (curated[job] ?? []).map((o) => conn.has(o.service)
      ? ([`${conn.get(o.service)}:${o.model}`, o.name] as [string, string])
      : ([`add:${o.service}`, S('win.models.add_key', `${o.name} · ${S(`models.preset.${presetKey(o.service)}`)}`)] as [string, string]));
    // a model picked elsewhere that the measured list doesn't have (an agent's setup, an older Blurt): kept, by name
    const v = jobValue(job), r = sum?.routes?.[job];
    if (v !== 'auto' && r && !opts.some(([x]) => x === v)) opts.push([v, modelName(sum, curated, job, r)]);
    // the closed pop-up says only Automatic or the model's name: what runs now is the row's detail (nothing cut off)
    return [['auto', S('win.models.auto')], ...opts];
  };
  const setJob = async (job: TextJob, v: string) => {
    if (v.startsWith('add:')) return setAdding(true);
    const [service, model] = v === 'auto' ? [null, null] : v.split(':');
    setSum(await api.cloudJobSet(job, service, model));
    loadJobs();
  };
  const textJob = (job: TextJob, icon: 'wand' | 'character-bubble' | 'text-viewfinder') => {
    const r = routeOf(sum, job);
    // Copy Text from Screen reads the picture here (Windows OCR) when no model is set; a model makes it better
    const none = job === 'vision' ? S('models.job.vision.detail') : S('models.job.none');
    // every row reads the same: what the feature does, then what it uses now (the Mac's "Models in use")
    const does = S(job === 'polish' ? 'models.job.polish.does' : job === 'translate' ? 'models.job.translate.detail' : 'models.job.vision.detail');
    return (
      <Row key={job} id={`speech.${job}`} icon={icon} detail={r ? S('speech.auto.using', does, modelName(sum, curated, job, r)) : none}>
        <Popup label={S(job === 'polish' ? 'speech.purpose.polish' : `models.job.${job}`)} value={jobValue(job)} dividers={[1]} choices={jobChoices(job)} onChange={(v) => setJob(job, v)} />
      </Row>
    );
  };
  return (
    <Page id="speech" lead={!models && !err ? S('speech.loading') : undefined}>
      {/* the one recommendation, only while it is missing (or coming down) */}
      {win && rec && !rec.installed && (
        <Group id="speech.use" title={S('speech.section.mac')}>
          {/* with no speech model on this PC at all, dictation can't run: the line says so in the attention mark (the
              Dictation pane's notice), the Download beside it the one way out */}
          <Line title={S('speech.rec.title_size', mb(rec.size_mb))}
            detail={failed && failedId === rec.id ? S('win.models.failed_row') : !installed.length && !dl ? S('dictation.nomodel.notice', rec.name) : S('speech.rec.line', S('speech.purpose.dictation'), rec.name)}
            warn={(failed && failedId === rec.id) || (!installed.length && !dl)}>
            {dl?.id === rec.id ? <><ModelProgress dl={dl} /><StopDownload /></> : <button className="primary" disabled={!!dl} onClick={() => download(rec.id)}>{S(failed && failedId === rec.id ? 'speech.rec.retry' : 'speech.download.button')}</button>}
          </Line>
        </Group>
      )}

      <Group id="speech.services" footer={S('models.sheet.note')}>
        {sum?.services.map((s) => (
          <Line key={s.id} icon="cloud" title={S(`models.preset.${presetKey(s.preset)}`)} badge={PRESETS.find((p) => p.id === s.preset)?.recommended ? S('models.recommended') : undefined}
            detail={s.has_key ? S('models.service.connected') : S('models.service.no_key')} warn={!s.has_key} flash={`speech_service_${s.id}`}>
            <button onClick={async () => setSum(await api.cloudDisconnect(s.id))}>{S('win.cloud.remove')}</button>
          </Line>
        ))}
        {(left.length > 0 || !sum?.services.length) ? (
          <Line icon="plus" title={S('models.services.add.title')} detail={!sum?.services.length ? S('models.services.empty') : undefined}>
            {win && setupAgents.length > 0 && <button onClick={() => setAgentSheet(true)}>{S('models.agent.button')}</button>}
            <button className={sum?.services.length ? '' : 'primary'} onClick={() => setAdding(true)}>{S('models.services.add')}</button>
          </Line>
        ) : win && setupAgents.length > 0 && (
          // every curated service is in, so the Add row is gone: Set Up with Agent… keeps a row of its own
          <Line icon="terminal" title={S('models.agent.sheet.title')} flash="speech_agent_setup_start">
            <button onClick={() => setAgentSheet(true)}>{S('models.agent.button')}</button>
          </Line>
        )}
        {win && <AgentSetupProgress onChange={() => (api.cloudSummary().then(setSum, () => {}), load(), loadJobs(), loadAsr())} />}
      </Group>

      <Group id="speech.jobs">
        {purposeRow('batch', 'film')}
        {purposeRow('note', 'mic')}
        {win && (
          <Row id="speech.dictation" icon="character-cursor" warn={!!models && !installed.length}
            detail={!models ? S('speech.purpose.dictation.detail') : installed.length
              ? S('speech.auto.using', S('speech.purpose.dictation.detail'), models.models.find((m) => m.id === models.selected && m.installed)?.name ?? (rec?.installed ? rec.name : installed[0].name))
              : S('win.models.dict_none')}>
            {/* never a dead end: with nothing installed the pop-up stays, saying Not set */}
            <Popup label={S('speech.purpose.dictation')} disabled={!installed.length}
              value={!installed.length ? 'none' : models?.models.find((m) => m.id === models.selected && m.installed && !m.recommended) ? models!.selected : 'auto'}
              choices={!installed.length ? [['none', S('models.uses.none')]] : [['auto', S('win.models.auto')], ...installed.filter((m) => !m.recommended || !rec?.installed).map((m) => [m.id, m.name] as [string, string])]}
              dividers={installed.length ? [1] : []} onChange={(v) => api.dictationUse(v === 'auto' ? null : v).then(load, (e) => onToast(String(e)))} />
          </Row>
        )}
        {win && textJob('polish', 'wand')}
        {win && textJob('translate', 'character-bubble')}
        {win && textJob('vision', 'text-viewfinder')}
      </Group>

      {win && models && (
        <Group id="speech.models" footer={err || (failed && !failedId ? S('win.models.failed') : undefined)}>
          {/* a failed download says so on its own row (Try Again); one coming down shows its progress where its button
              was, the row keeping its two lines and its height */}
          {models.models.map((m) => {
            const broke = failed && failedId === m.id;
            return (
              <Line key={m.id} icon="waveform" title={m.name} badge={m.recommended && !m.installed ? S('models.recommended') : undefined} warn={broke}
                detail={broke ? `${mb(m.size_mb)} · ${S('win.models.failed_row')}` : dl?.id === m.id ? S('speech.rec.downloading', '').trim() : mb(m.size_mb)}>
                {m.installed ? (
                  <span className="st-have"><Icon name="check" size={13} />{S('win.models.installed')}</span>
                ) : dl?.id === m.id ? (
                  <><ModelProgress dl={dl} /><StopDownload /></>
                ) : (
                  <button disabled={!!dl} title={dl ? S('win.models.one_at_a_time') : undefined} onClick={() => download(m.id)}>{S(broke ? 'speech.rec.retry' : 'speech.download.button')}</button>
                )}
              </Line>
            );
          })}
        </Group>
      )}
      {adding && <AddCloudSheet onClose={() => setAdding(false)} onDone={(s) => (setSum(s), setAdding(false))} presets={left.length ? left : PRESETS.filter((p) => !p.pair || volcOffered())} />}
      {agentSheet && <AgentSetupSheet agents={setupAgents} onClose={() => setAgentSheet(false)} onToast={onToast} />}
    </Page>
  );
}

/** Add Cloud Model (the Mac's CloudServiceSheet): the service, the API key — or for Volcengine Speech its App ID and
 *  Access Token — and Test before it is saved. */
function AddCloudSheet({ presets, onClose, onDone }: { presets: readonly (typeof PRESETS)[number][]; onClose: () => void; onDone: (s: CloudSummary) => void }) {
  const [preset, setPreset] = useState<string>(presets[0].id);
  const [key, setKey] = useState('');
  const [appId, setAppId] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const info = PRESETS.find((p) => p.id === preset)!;
  useEffect(() => {
    const k = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [onClose]);
  useEffect(() => {
    // the App ID is no secret: shown again, so a new token can go with it
    if (info.pair) api.cloudSpeechAppId().then((a) => a && setAppId((x) => x || a), () => {});
  }, [info.pair]);
  const failure = (code?: string) =>
    S(code === 'auth' ? 'models.check.auth' : code === 'network' ? 'models.check.network' : code === 'quota' ? 'models.check.rate'
      : code === 'app_id' ? 'models.check.app_id' : code === 'no_token' ? 'models.check.no_token' : code === 'token' ? 'models.token.invalid' : 'models.check.other');
  const connect = async () => {
    const k = key.trim();
    if (/\s/.test(k)) return setMsg({ ok: false, text: S(info.pair ? 'models.token.invalid' : 'models.key.spaces') });
    setBusy(true);
    setMsg(null);
    try {
      const r = info.pair ? await api.cloudConnectSpeech(appId.trim(), k) : await api.cloudConnect(preset, k);
      if (r.ok) onDone(r.summary ?? (await api.cloudSummary()));
      else setMsg({ ok: false, text: failure(r.code) });
    } catch (e) {
      setMsg({ ok: false, text: String(e) });
    }
    setBusy(false);
  };
  const ready = info.pair ? !!appId.trim() && !!key.trim() : !!key.trim();
  const svcName = S(`models.preset.${presetKey(preset)}`);
  const getKey = <TextLink ink onClick={() => api.openUrl(info.page)}>{S('models.sheet.key.get', svcName)}</TextLink>;
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="sheet st-sheet cloud-sheet" role="dialog" aria-label={S('models.sheet.add_title')} data-testid="cloud-sheet">
        <div className="st-col" style={{ padding: '20px 24px' }}>
          <h1 className="st-title">{S('models.sheet.add_title')}</h1>
          {/* what it is for, what goes there and where the key stays — before the key is asked for */}
          <p className="st-foot cs-lead">{info.pair ? S('models.sheet.note.pair') : S('models.sheet.lead')}</p>
          {/* one form grid: the labels right-aligned in one column, every control the same width beside them, the
              link to get a key under the field it fills (the Mac's sheet) */}
          <div className="cs-form">
            <label className="cs-l">{S('models.sheet.service')}</label>
            <Popup label={S('models.sheet.service')} value={preset}
              choices={presets.map((p) => [p.id, p.recommended ? S('models.preset.recommended', S(`models.preset.${presetKey(p.id)}`)) : S(`models.preset.${presetKey(p.id)}`)] as [string, string])}
              onChange={(v) => (setPreset(v), setMsg(null))} />
            {info.pair && (
              <>
                <label className="cs-l" htmlFor="cs-app">{S('models.sheet.app_id')}</label>
                <input id="cs-app" className="st-field" autoComplete="off" spellCheck={false} placeholder={S('models.sheet.app_id.placeholder')} value={appId} autoFocus
                  onChange={(e) => (setAppId(e.target.value), setMsg(null))} />
              </>
            )}
            <label className="cs-l" htmlFor="cs-key">{S(info.pair ? 'models.sheet.token' : 'models.sheet.key')}</label>
            <div className="cs-f">
              <input id="cs-key" className="st-field" type="password" autoComplete="off" spellCheck={false} autoFocus={!info.pair}
                placeholder={S(info.pair ? 'models.sheet.token.placeholder' : 'models.sheet.key.placeholder')} value={key}
                onChange={(e) => (setKey(e.target.value), setMsg(null))} onKeyDown={(e) => e.key === 'Enter' && ready && !busy && connect()} />
              <span className="cs-get">{getKey}</span>
            </div>
          </div>
          {msg && <p className={`st-foot ${msg.ok ? '' : 'st-warn'}`}>{msg.text}</p>}
          <div className="st-ctl" style={{ marginTop: 16 }}>
            <button onClick={onClose}>{S('capture.keys.swap.cancel')}</button>
            <button className="primary" disabled={!ready || busy} onClick={connect}>{busy ? S('win.cloud.testing') : S('models.sheet.connect')}</button>
          </div>
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ Set Up with Agent…

/** One step of what the agent did, in the Mac's words (AgentSetupProgress.text). */
function stepText(s: AgentSetupStep): string {
  const job = (j: string) => S(j === 'polish' ? 'speech.purpose.polish' : j === 'translate' ? 'models.job.translate' : j === 'vision' ? 'models.job.vision' : 'speech.purpose.dictation');
  const name = s.name || s.subject;
  switch (s.kind) {
    case 'connect': return S(s.state === 'running' ? 'models.agent.step.connecting' : s.state === 'done' ? 'models.agent.step.connected' : 'models.agent.step.connect_failed', name);
    case 'use': return s.state === 'failed' ? S('models.agent.step.use_failed', job(s.subject)) : S('models.agent.step.use', job(s.subject), name);
    case 'download': return S(s.state === 'running' ? 'models.agent.step.downloading' : s.state === 'done' ? 'models.agent.step.downloaded' : 'models.agent.step.download_failed', name);
    default: return S(s.state === 'running' ? 'models.agent.step.verifying' : s.state === 'done' ? 'models.agent.step.verified' : 'models.agent.step.verify_failed');
  }
}

/** The instruction to paste into the user's own agent (the Mac's AgentSetupInstruction): the setup guide and setup.py. */
function useInstruction() {
  const [text, setText] = useState('');
  useEffect(() => {
    api.agentSetupInstruction().then((p) => setText(S('models.agent.prompt', p.guide, p.setup)), () => {});
  }, []);
  return text;
}

/** "Set Up Models with an Agent": the instruction to copy (the main way), or Open in Terminal — an agent Blurt starts
 *  in its own terminal on that instruction (control.rs `agent_setup_start`). */
function AgentSetupSheet({ agents, onClose, onToast }: { agents: { id: string; name: string }[]; onClose: () => void; onToast: (m: string) => void }) {
  const instruction = useInstruction();
  const [copied, setCopied] = useState(false);
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [openIn, setOpenIn] = useState<MenuAt | null>(null);
  useEffect(() => {
    // Esc closes the open menu first (it handles its own), then the sheet
    const k = (e: KeyboardEvent) => e.key === 'Escape' && !e.defaultPrevented && onClose();
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [onClose]);
  const start = async (id: string) => {
    setStarting(true);
    setError(null);
    try {
      const st = await api.agentSetupStart(id);
      onClose();
      if (st.job) showJob(st.job);
    } catch (e) {
      setError(String(e));
      setStarting(false);
    }
  };
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="sheet st-sheet" role="dialog" aria-label={S('models.agent.sheet.title')} data-testid="agent-setup-sheet">
        <div className="st-col" style={{ padding: '18px 20px' }}>
          <h1 className="st-title">{S('models.agent.sheet.title')}</h1>
          <p className="st-foot">{S('models.agent.sheet.detail')}</p>
          <div className="st-well st-instruction" tabIndex={0}>{instruction}</div>
          <p className="st-foot">{S('models.agent.note')}</p>
          {error && <p className="st-foot st-warn">{error}</p>}
          <div className="st-ctl" style={{ marginTop: 12 }}>
            {agents.length > 0 && (
              // Open in Terminal ▾: the app's themed menu of the agents that can run it (never the WebView's <select>,
              // drawn light in a dark window)
              <>
                <button style={{ marginRight: 'auto' }} disabled={starting} aria-haspopup="menu" aria-expanded={!!openIn}
                  onClick={(e) => setOpenIn(openIn ? null : { x: 0, y: 0, anchor: e.currentTarget, align: 'start', minWidth: e.currentTarget.offsetWidth })}>
                  {S('models.agent.sheet.open')} <Icon name="chevron-down" size={11} />
                </button>
                {openIn && <Menu at={openIn} label={S('models.agent.sheet.open')} onClose={() => setOpenIn(null)}
                  entries={agents.map((a) => ({ label: a.name, run: () => start(a.id) }))} />}
              </>
            )}
            <button onClick={onClose}>{S(copied ? 'models.sheet.done' : 'models.cancel')}</button>
            <button className="primary" disabled={!instruction} onClick={() => api.copyText(instruction).then(() => setCopied(true), (e) => onToast(String(e)))}>
              <Icon name={copied ? 'check' : 'copy'} size={13} /> {S(copied ? 'models.agent.sheet.copied' : 'models.agent.sheet.copy')}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

/** The session's terminal (the main window's sessions view, as the tray's nav does). */
function showJob(job: string) {
  import('@tauri-apps/api/event').then(({ emit }) => emit('nav', { job })).catch(() => {});
}

/** The live list (the Mac's AgentSetupProgressView): who is setting up, Show Terminal / Stop (Done once it is over),
 *  then one line per thing done. `onChange`: a step finished — the pane reads its rows again. */
function AgentSetupProgress({ onChange }: { onChange: () => void }) {
  const [st, setSt] = useState<AgentSetupState | null>(null);
  const done = useRef(0);
  useEffect(() => {
    api.agentSetupState().then(setSt, () => {});
    return listen<AgentSetupState>('agent-setup://changed', (p) => {
      setSt(p);
      const n = (p.steps ?? []).filter((s) => s.state !== 'running').length;
      if (n !== done.current) {
        done.current = n;
        onChange();
      }
    });
  }, []);
  if (!st || (!st.active && !(st.steps ?? []).length)) return null;
  const title = st.active ? (st.agent ? S('models.agent.active', st.agent) : S('models.agent.active.unknown')) : S('models.agent.ended');
  return (
    <>
      <Line icon="terminal" title={title} flash="speech_agent_setup">
        {st.active && st.job && <button onClick={() => showJob(st.job!)}>{S('models.agent.show')}</button>}
        {st.active ? <button onClick={() => api.agentSetupStop().then(setSt)}>{S('models.agent.stop')}</button>
          : <button onClick={() => api.agentSetupDismiss().then(setSt)}>{S('models.sheet.done')}</button>}
      </Line>
      {(st.steps ?? []).map((s, i) => (
        <div key={i} className="st-row st-step" data-state={s.state}>
          <span className="st-icon">{s.state === 'running' ? <span className="st-spin" /> : <Icon name={s.state === 'done' ? 'check' : 'x'} size={12} />}</span>
          <span className="st-detail">{stepText(s)}</span>
        </div>
      ))}
    </>
  );
}

// ------------------------------------------------------------------ the Welcome's cloud row (onboarding owns it)

const OLD_PRESETS = [
  { id: 'deepseek', page: 'https://platform.deepseek.com/api_keys' },
  { id: 'dashscope', page: 'https://bailian.console.aliyun.com/?tab=model#/api-key' },
] as const;

export function CloudSettings({ onToast, onChange }: { onToast: (m: string) => void; onChange?: (s: CloudSummary) => void }) {
  const [sum, setSumState] = useState<CloudSummary | null>(null);
  const setSum = (s: CloudSummary) => {
    setSumState(s);
    onChange?.(s);
  };
  const [preset, setPreset] = useState<string>('deepseek');
  const [key, setKey] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  useEffect(() => {
    api.cloudSummary().then(setSum, (e) => onToast(String(e)));
  }, []);
  const connect = async () => {
    setBusy(true);
    setMsg(null);
    try {
      const r = await api.cloudConnect(preset, key.trim());
      if (r.ok) {
        setKey('');
        setSum(r.summary ?? (await api.cloudSummary()));
        setMsg({ ok: true, text: t('cloud.connected', { ms: String(r.ms ?? '') }) });
      } else {
        setMsg({ ok: false, text: t(`cloud.error.${r.code ?? 'other'}`, { error: r.error ?? '' }) });
      }
    } catch (e) {
      setMsg({ ok: false, text: String(e) });
    }
    setBusy(false);
  };
  const route = sum?.routes?.polish;
  return (
    <section className="kv" data-testid="settings-cloud">
      <p className="dim small">{t('cloud.lead')}</p>
      {sum?.services.map((s) => (
        <div key={s.id}>
          <span>{t(`cloud.preset.${s.preset}`)}</span>
          <span className={s.has_key ? 'ok' : 'warn'}>{t(s.has_key ? 'cloud.key.saved' : 'cloud.key.missing')}</span>
          <button className="link" onClick={async () => setSum(await api.cloudDisconnect(s.id))}>{t('cloud.remove')}</button>
        </div>
      ))}
      <div>
        <span>{t('cloud.add')}</span>
        <select value={preset} onChange={(e) => setPreset(e.target.value)}>
          {OLD_PRESETS.map((p) => (
            <option key={p.id} value={p.id}>{t(`cloud.preset.${p.id}`)}</option>
          ))}
        </select>
        <input type="password" autoComplete="off" spellCheck={false} placeholder={t('cloud.key.placeholder')} value={key} onChange={(e) => setKey(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && key.trim() && !busy && connect()} />
        <button className="primary" disabled={!key.trim() || busy} onClick={connect}>{busy ? t('cloud.testing') : t('cloud.connect')}</button>
        <button className="link" onClick={() => api.openUrl(OLD_PRESETS.find((p) => p.id === preset)!.page)}>{t('cloud.get_key')}</button>
      </div>
      {msg && <p className={msg.ok ? 'ok' : 'warn'}>{msg.text}</p>}
      <div>
        <span>{t('cloud.polish')}</span>
        <span>{route ? `${route.model} · ${t(`cloud.preset.${sum?.services.find((s) => s.id === route.service)?.preset ?? 'custom'}`)}` : t('cloud.polish.none')}</span>
      </div>
    </section>
  );
}

