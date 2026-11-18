// Home (the Mac's MainWindow/HomePage.swift + HomeViews.swift; docs/design/capabilities.md): the main window's first
// page. The five capabilities, one row each — what it does, its keys, its switch, and when something stands in its way
// one line with the one way to fix it —; what waits for you (new items, cards at the top of the screen); and Recent,
// one timeline of what was made with the capabilities that are on (dictations, cards, text read or translated from the
// screen, recordings with their state, items), newest first by day.
// A row goes to its place; its right-click menu also opens its settings. Off: the name and keys step back, the line
// stays readable, the switch brings it back.
import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react';
import { Icon } from '@blurt/icons';
import { KindIcon } from '@blurt/ui/react';
import { api, listen, type AppStatus, type CardInfo, type HotkeyRow, type ItemRow, type Summary } from '../api';
import { CAPS, feedDays, feedId, mergeFeed, phoneHeadline, phoneNeedsAttention, SHOWN_KEYS, type Capability, type FeedEntry, type FeedKind } from '../capabilities';
import * as D from '../dictation';
import { keyInText } from '../util';
import { i18n, plural, t } from '../i18n';
import type { Place } from '../places';
import { useRemoteStatus } from '../settings/phone';
import { Switch } from '../settings/kit';
import { useMenu, type MenuEntry } from './Menu';
import { inlineAction, type Recording } from '../recordings';
import { actionLabel, recClick, recLength, recMenu, recStateText, recTip, recTitle, runRecAction, type RecHandlers } from './Recordings';
import { screenTextSource } from './ScreenTextPage';
import { mb, ModelProgress, useDictationModels } from './ModelDownload';
import { CAP_ICON, dictationKeyName } from './SettingsView';
import { setCapability, useOff } from './useCapabilities';
import './pages.css';

const BAD = new Set(['taken', 'duplicate', 'system', 'invalid']);
const caps = (label: string) => label.split('+').map((k) => k.trim()).filter(Boolean);

function Caps({ label }: { label: string }) {
  return (
    <span className="pg-caps">
      {caps(label).map((k, i) => <kbd key={i}>{k}</kbd>)}
    </span>
  );
}

/** "Today", "Yesterday", a weekday within the week, else the date. */
function dayLabel(day: number): string {
  const d = new Date(day * 1000);
  const now = new Date();
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() / 1000;
  const days = Math.round((start - day) / 86400);
  if (days <= 0) return t('dictation_page.today');
  if (days === 1) return t('dictation_page.yesterday');
  const loc = i18n().locale;
  if (days < 7) return new Intl.DateTimeFormat(loc, { weekday: 'long' }).format(d);
  return new Intl.DateTimeFormat(loc, { month: 'long', day: 'numeric', year: d.getFullYear() === now.getFullYear() ? undefined : 'numeric' }).format(d);
}
const clock = (time: number) => new Intl.DateTimeFormat(i18n().locale, { hour: 'numeric', minute: '2-digit' }).format(new Date(time * 1000));

/** Where a capability's row goes. */
const PLACE: Record<Capability, Place | null> = { dictation: 'dictation', cards: 'cards', screen_text: 'screen_text', recording: 'inbox', phone: 'phone' };
/** Its Settings pane. */
const PANE: Record<Capability, string> = { dictation: 'dictation', cards: 'cards', screen_text: 'screentext', recording: 'recording', phone: 'phone' };

export function HomePage({ status, hotkeys, summary, cardsWaiting, onGo, onReveal, onToast, onSettings, tick, recordings, recAgent, recHandlers }: {
  status: AppStatus;
  hotkeys: HotkeyRow[];
  summary: Summary | null;
  cardsWaiting: number;
  onGo: (p: Place) => void;
  onReveal: (uid: string) => void;
  onToast: (m: string) => void;
  onSettings: (pane: string) => void;
  /** the window's refresh tick (items changed) */
  tick: number;
  /** the recordings with their state (App: recordings_list + the jobs) */
  recordings: Recording[];
  /** an agent can organise in the background (null: not known yet) */
  recAgent: boolean | null;
  recHandlers: RecHandlers;
}) {
  const { off } = useOff();
  const remote = useRemoteStatus();
  const menu = useMenu();
  const built = { dictation: status.features?.dictation ?? status.platform === 'win', screen_text: status.features?.screen_text ?? status.platform === 'win' };
  const shownCaps = CAPS.filter((c) => (c !== 'dictation' || built.dictation) && (c !== 'screen_text' || built.screen_text));
  const [cfg, setCfg] = useState<Record<string, any> | null>(null);
  const dict = useDictationModels();
  const agentReady = recAgent;
  const [shotsAllowed, setShotsAllowed] = useState(true);
  const [lists, setLists] = useState<{ dictations: FeedEntry[]; cards: FeedEntry[]; screenTexts: FeedEntry[]; items: FeedEntry[] }>({ dictations: [], cards: [], screenTexts: [], items: [] });
  const [loaded, setLoaded] = useState(false);
  const [cardsTick, setCardsTick] = useState(0);
  /** failed dictations whose Retry is running: "Recognizing…" until the history has their text */
  const [retrying, setRetrying] = useState<Set<string>>(new Set());

  useEffect(() => {
    api.settings().then((s) => setCfg(s.config), () => {});
  }, [off]);
  useEffect(() => listen('cards://changed', () => setCardsTick((n) => n + 1)), []);
  useEffect(() => listen('screen-text://changed', () => setCardsTick((n) => n + 1)), []);
  // a take landed, failed or was retried (a failed one is a row with Retry; once retried, a dictation like any other)
  useEffect(() => listen('dictation://changed', () => setCardsTick((n) => n + 1)), []);
  useEffect(() => {
    if (status.platform === 'gnome' && !off.has('screen_text')) api.screenTextAllowed().then(setShotsAllowed, () => {});
  }, [status.platform, off.has('screen_text')]);

  // Recent: the lists, each only while its capability is on
  const load = useCallback(async () => {
    const [dh, cl, st, it] = await Promise.all([
      off.has('dictation') ? null : api.dictationHistory().catch(() => null),
      off.has('cards') ? null : api.cardsList().catch(() => null),
      off.has('screen_text') || !built.screen_text ? null : api.screenTextHistory().catch(() => null),
      off.has('recording') ? null : api.items({ sort: 'updated', ascending: false, limit: 40 }).catch(() => null),
    ]);
    // a take that wasn't recognised, its recording kept, is a row too: its action is Retry (DictationRetry.onHome)
    const dictations: FeedEntry[] = (dh?.entries ?? [])
      .filter((e) => D.onHome(e, !!dh?.can_retry && !!e.audio_path))
      .slice(0, 40)
      .map((e) => {
        const failed = D.failedNotCancelled(e);
        const len = i18n().formatDuration(Math.round(e.duration || 0), 'clock');
        return {
          kind: 'dictation',
          key: e.id,
          time: new Date(e.t).getTime() / 1000,
          source: D.appName(e) ?? '',
          text: failed ? t('home.entry.failed', { len }) : D.preview(D.finalText(e)),
          ...(failed ? { sub: 'failed' } : {}),
        };
      });
    const card = (c: CardInfo): FeedEntry => ({
      kind: 'card',
      key: `${c.session ?? ''}#${c.n}`,
      time: c.taken ?? c.wall ?? 0,
      source: t(c.ref ? 'home.entry.file' : c.textCard ? 'home.entry.text' : c.kind === 'voice' || !c.src ? 'home.entry.voice' : 'home.entry.snap'),
      text: (c.text ?? '').trim(),
      sub: c.ref ? 'file' : c.textCard ? 'text' : c.kind === 'voice' || !c.src ? 'voice' : 'shot',
    });
    const cards = [...(cl?.current ?? []), ...(cl?.history ?? [])].filter((c) => c.wall || c.taken).map(card);
    const items: FeedEntry[] = (it?.items ?? []).map((r: ItemRow) => ({
      kind: 'item',
      key: r.uid,
      time: r.updated || r.created,
      source: [r.item_id, r.project_id === 'inbox' ? t('project.inbox') : r.project_name].filter(Boolean).join(' · '),
      text: r.title,
      sub: r.kind,
    }));
    const screenTexts: FeedEntry[] = (st?.entries ?? []).slice(0, 40).map((e) => ({
      kind: 'screen_text',
      key: e.id,
      time: e.time,
      source: screenTextSource(e),
      text: D.preview(e.text),
      sub: e.translated ? 'translate' : 'copy',
    }));
    setLists({ dictations, cards, screenTexts, items });
    setLoaded(true);
  }, [off, built.screen_text]);
  useEffect(() => {
    void load();
  }, [load, tick, cardsTick]);
  // a recording: "Recording · 3:12 · 2 items" over the first thing said in it
  const recByKey = useMemo(() => new Map(recordings.map((r) => [r.info.dir, r])), [recordings]);
  const recEntries = useMemo((): FeedEntry[] => recordings.map((r) => ({
    kind: 'recording',
    key: r.info.dir,
    time: r.info.created ?? 0,
    source: [t('inbox.mode.video'), recLength(r), recStateText(r)].filter(Boolean).join(' · '),
    text: r.info.first_line ?? '',
    sub: r.state.kind,
  })), [recordings]);
  const feed = useMemo(() => mergeFeed({ ...lists, recordings: recEntries }, off), [lists, recEntries, off]);

  const hk = (a: string) => hotkeys.find((h) => h.action === a);
  const keyLabel = (a: string) => {
    const h = hk(a);
    return h && h.spec !== 'off' && h.label ? h.label : '';
  };
  const dictKey = dictationKeyName(status, cfg ?? undefined);
  const keysOf = (c: Capability): string[] => (c === 'dictation' ? [dictKey] : SHOWN_KEYS[c].map(keyLabel).filter(Boolean));

  const what = (c: Capability) => (c === 'dictation' ? t('feature.dictation.what', { a: keyInText(dictKey, i18n().lang) }) : t(`feature.${c}.what`));

  /** What stands in a capability's way now, and its one fix (only while it is on). */
  const fix = (c: Capability): ReactNode => {
    if (off.has(c)) return null;
    if (c === 'dictation') {
      const m = dict.models;
      if (dict.dl) return <ModelProgress dl={dict.dl} total={m?.models.find((x) => x.id === dict.dl!.id)?.size_mb} onStop={() => void api.modelDownloadCancel().catch(() => {})} />;
      if (m && !m.ready) {
        const rec = m.models.find((x) => x.id === m.recommended);
        return (
          <FixLine text={t('home.dictation.no_model')}>
            <button className="pg-small" onClick={() => void dict.download(m.recommended)} data-testid="home-download">
              {t('home.dictation.download')}{rec?.size_mb ? ` · ${mb(rec.size_mb)}` : ''}
            </button>
          </FixLine>
        );
      }
    }
    const taken = [...(c === 'dictation' ? HOTKEYS_DICT : SHOWN_KEYS[c])].filter((a) => {
      const h = hk(a);
      return h && BAD.has(h.result);
    });
    if (taken.length) {
      const labels = taken.map((a) => hk(a)!.label || a);
      const text = labels.length === 1 ? t('home.keys.taken', { a: labels[0] }) : t('home.keys.taken_several', { a: t('home.keys.and', { a: labels[0], b: labels[1] }) });
      return (
        <FixLine text={text}>
          <button className="pg-small" onClick={() => onSettings('shortcuts')}>{t('home.keys.change')}</button>
        </FixLine>
      );
    }
    if (c === 'screen_text' && status.platform === 'gnome' && !shotsAllowed)
      return (
        <FixLine text={t('home.screen_text.allow')}>
          <button className="pg-small" onClick={() => void api.screenTextAllow().then((r) => setShotsAllowed(r.ok), () => {})}>{t('st.screentext.allow.button')}</button>
        </FixLine>
      );
    if (c === 'recording' && agentReady === false)
      return (
        <FixLine text={t('home.recording.no_agent')} quiet>
          <button className="pg-small" onClick={() => onSettings('agents')}>{t('home.recording.set_up_agent')}</button>
        </FixLine>
      );
    if (c === 'phone' && remote && phoneNeedsAttention(remote))
      return (
        <FixLine text={t('home.phone.needs_access')}>
          <button className="pg-small" onClick={() => onGo('phone')}>{t('home.phone.look')}</button>
        </FixLine>
      );
    return null;
  };

  /** The phone's state, quiet after its line ("Maya's iPhone connected"). */
  const phoneState = (): string => {
    if (!remote || off.has('phone')) return '';
    const h = phoneHeadline(remote);
    if (h.kind === 'connected') return t('phonepage.head.connected', { a: h.name || t('phonepage.unnamed') });
    if (h.kind === 'not_connected') return t('phonepage.head.not_connected');
    return '';
  };

  const rowMenu = (c: Capability): MenuEntry[] => [
    ...(PLACE[c] && !off.has(c) ? [{ label: t('home.row.open', { a: t(`feature.${c}`) }), run: () => onGo(PLACE[c]!) }] : []),
    { label: t('home.row.settings', { a: t(`feature.${c}`) }), disabled: off.has(c), run: () => onSettings(PANE[c]) },
  ];

  // the lines under the box: what waits for you
  const fresh = summary?.new ?? 0;
  const verify = summary?.to_verify ?? 0;
  const waiting: ReactNode[] = [];
  if (!off.has('recording') && (fresh > 0 || verify > 0))
    waiting.push(
      <div key="inbox" className="pg-wait" data-testid="home-waiting-inbox">
        <Icon name="inbox" size={15} />
        {fresh > 0 && <span className="pg-pill">{i18n().formatNumber(fresh)}</span>}
        <span>{[fresh > 0 ? t('home.waiting.new') : '', verify > 0 ? t('main.inbox.verify', { n: verify }) : ''].filter(Boolean).join(' · ')}</span>
        <button className="pg-link" onClick={() => onGo('inbox')}>{t('home.waiting.open_inbox')}</button>
      </div>,
    );
  if (!off.has('cards') && cardsWaiting > 0)
    waiting.push(
      <div key="cards" className="pg-wait" data-testid="home-waiting-cards">
        <Icon name="cards" size={15} />
        <span>{plural('home.waiting.cards', cardsWaiting)}</span>
        <button className="pg-link" onClick={() => void api.revealCards().catch(() => {})}>{t('home.waiting.show')}</button>
      </div>,
    );

  const isFailed = (e: FeedEntry) => e.kind === 'dictation' && e.sub === 'failed';
  const recOf = (e: FeedEntry) => (e.kind === 'recording' ? recByKey.get(e.key) ?? null : null);
  /** a recording's one action on its row, under the pointer in the time's place: Retry or Organize (the click shows
   *  its detail; Set Up an Agent… is there) */
  const recAct = (r: Recording) => {
    const a = inlineAction(r, agentReady);
    return a === 'set_up_agent' ? null : a;
  };
  /** A failed dictation's Retry: the recording again, the text onto the clipboard (never pasted: the user is here). */
  const retry = async (e: FeedEntry) => {
    if (retrying.has(e.key)) return;
    setRetrying((w) => new Set(w).add(e.key));
    try {
      await api.dictationRetry(e.key);
      onToast(t('dictation_page.retry.done'));
      await load();
    } catch (err) {
      onToast(String(err).includes('[retry_gone]') ? t('dictation_page.retry.gone') : t('dictation_page.retry.failed'));
    } finally {
      setRetrying((w) => {
        const n = new Set(w);
        n.delete(e.key);
        return n;
      });
    }
  };
  const primary = (e: FeedEntry) => {
    const r = recOf(e);
    if (r) return runRecAction(recClick(r), r, recHandlers);
    return isFailed(e) ? void retry(e) : openEntry(e);
  };
  const openEntry = (e: FeedEntry) => (e.kind === 'dictation' ? onGo('dictation') : e.kind === 'card' ? onGo('cards') : e.kind === 'screen_text' ? onGo('screen_text') : onReveal(e.key));
  const entryMenu = (e: FeedEntry): MenuEntry[] => recOf(e) ? recMenu(recOf(e)!, agentReady, recHandlers) : isFailed(e) ? [
    { label: t('home.entry.retry'), disabled: retrying.has(e.key), run: () => void retry(e) },
    { label: t('home.entry.open'), run: () => openEntry(e) },
  ] : [
    { label: t('home.entry.open'), run: () => openEntry(e) },
    ...(e.text ? [{ label: e.kind === 'item' ? t('home.entry.copy_title') : t('home.entry.copy'), run: () => void api.copyText(e.text).then(() => onToast(t('dictation_page.copied')), () => {}) }] : []),
  ];
  // recordings have no page of their own: their link is the items'
  const ALL: Partial<Record<FeedKind, { key: string; place: Place }>> = {
    dictation: { key: 'home.all.dictation', place: 'dictation' },
    card: { key: 'home.all.cards', place: 'cards' },
    screen_text: { key: 'home.all.screen_text', place: 'screen_text' },
    item: { key: 'home.all.items', place: 'all' },
  };
  const allOff = shownCaps.every((c) => off.has(c));
  const tries = shownCaps.filter((c) => !off.has(c));
  const tryKey: Record<Capability, string> = { dictation: dictKey, cards: keyLabel('snap'), screen_text: keyLabel('text'), recording: keyLabel('record'), phone: '' };

  return (
    <div className="pg" data-testid="home">
      <div className="pg-col">
        <h1 className="pg-title">{t('home.title')}</h1>

        <section className="pg-box hm-caps" aria-label={t('home.features')}>
          {shownCaps.map((c) => {
            const on = !off.has(c);
            const keys = keysOf(c);
            const line = fix(c);
            const state = c === 'phone' ? phoneState() : '';
            const go = PLACE[c] ?? null;
            return (
              <div key={c} className={`hm-row ${on ? '' : 'off'} ${on && (go || c === 'screen_text') ? 'link' : ''}`} data-testid={`home-cap-${c}`}
                onClick={(e) => {
                  if (!on || (e.target as HTMLElement).closest('button')) return;
                  if (go) onGo(go);
                  else onSettings(PANE[c]);
                }}
                onContextMenu={(e) => {
                  e.preventDefault();
                  menu.open(rowMenu(c), { x: e.clientX, y: e.clientY }, t(`feature.${c}`));
                }}
                title={on && go ? t('home.row.open', { a: t(`feature.${c}`) }) : undefined}>
                <span className="hm-ic"><Icon name={CAP_ICON[c]} size={18} /></span>
                <span className="hm-text">
                  <span className="hm-name">{t(`feature.${c}`)}</span>
                  <span className="hm-what">{what(c)}{state && <span className="hm-state"> · {state}</span>}</span>
                  {line}
                </span>
                <span className="hm-keys" aria-hidden={!on}>
                  {keys.map((k, i) => <Caps key={i} label={k} />)}
                </span>
                <span className="hm-switch" title={t(on ? 'home.switch.tip.on' : 'home.switch.tip.off', { a: t(`feature.${c}`) })}>
                  <Switch on={on} label={t(`feature.${c}`)} set={(v) => void setCapability(c, v).catch((e) => onToast(String(e)))} />
                </span>
              </div>
            );
          })}
        </section>

        {waiting.length > 0 && <div className="pg-waits">{waiting}</div>}

        <h2 className="pg-h2">{t('home.recent')}</h2>
        {!loaded ? null : feed.entries.length === 0 ? (
          <div className="pg-empty" data-testid="home-empty">
            <div className="pg-empty-title">{t('home.empty.title')}</div>
            {allOff ? (
              <div className="pg-empty-line">{t('home.empty.all_off')}</div>
            ) : (
              tries.map((c) => (
                <div key={c} className="pg-empty-line">
                  <Icon name={CAP_ICON[c]} size={14} />
                  <span>{c === 'phone' ? t('home.try.phone') : tryLine(`home.try.${c}`, tryKey[c])}</span>
                </div>
              ))
            )}
          </div>
        ) : (
          <div className="hm-recent" data-testid="home-recent">
            {feedDays(feed.entries).map((d) => (
              <section key={d.day} className="hm-day">
                <h3 className="hm-day-title">{dayLabel(d.day)}</h3>
                <div className="pg-box">
                  {d.rows.map((e) => {
                    const rec = recOf(e);
                    if (rec) {
                      // a recording: its state in the quiet line (a failure in the attention ink), what was said in it,
                      // its one action under the pointer
                      const act = recAct(rec);
                      const recFailed = rec.state.kind === 'failed';
                      return (
                        <button key={feedId(e)} className={`hm-entry ${act ? 'failed' : ''}`} onClick={() => primary(e)} data-testid={`home-entry-recording-${rec.state.kind}`}
                          title={recTip(rec, agentReady) || undefined}
                          onContextMenu={(ev) => {
                            ev.preventDefault();
                            menu.open(entryMenu(e), { x: ev.clientX, y: ev.clientY });
                          }}>
                          <span className="hm-entry-ic">{entryIcon(e)}</span>
                          <span className="hm-entry-text">
                            <span className={`hm-entry-src ${recFailed ? 'attn' : ''}`}>{e.source}</span>
                            <span className={`hm-entry-body ${e.text ? '' : 'none'}`}>{recTitle(rec)}</span>
                          </span>
                          <span className="hm-entry-end">
                            <span className="hm-entry-time">{clock(e.time)}</span>
                            {act && (
                              <span className="hm-entry-act" role="button" tabIndex={-1} data-testid="home-entry-recording-act"
                                onClick={(ev) => {
                                  ev.stopPropagation();
                                  runRecAction(act, rec, recHandlers);
                                }}>
                                {actionLabel(act, rec)}
                              </span>
                            )}
                          </span>
                        </button>
                      );
                    }
                    const failed = isFailed(e);
                    const busy = failed && retrying.has(e.key);
                    return (
                      <button key={feedId(e)} className={`hm-entry ${failed ? 'failed' : ''}`} onClick={() => primary(e)} aria-busy={busy || undefined}
                        data-testid={failed ? 'home-entry-dictation-failed' : `home-entry-${e.kind}`} title={failed ? t('dictation_page.retry.tip') : undefined}
                        onContextMenu={(ev) => {
                          ev.preventDefault();
                          menu.open(entryMenu(e), { x: ev.clientX, y: ev.clientY });
                        }}>
                        <span className="hm-entry-ic">{entryIcon(e)}</span>
                        <span className="hm-entry-text">
                          <span className="hm-entry-src">{e.source}</span>
                          {/* not recognised, recording kept: said in the attention ink, Retry is the row's action */}
                          <span className={`hm-entry-body ${failed ? 'attn' : e.text ? '' : 'none'}`}>{busy ? t('home.entry.retrying') : e.text || t('cards.no_note')}</span>
                        </span>
                        {failed ? (
                          <span className="hm-entry-end">
                            <span className="hm-entry-time">{clock(e.time)}</span>
                            {!busy && <span className="hm-entry-act">{t('home.entry.retry')}</span>}
                          </span>
                        ) : (
                          <span className="hm-entry-time">{clock(e.time)}</span>
                        )}
                      </button>
                    );
                  })}
                </div>
              </section>
            ))}
            <div className="hm-all">
              {feed.kinds.filter((k) => ALL[k]).map((k) => (
                <button key={k} className="pg-link" onClick={() => onGo(ALL[k]!.place)}>{t(ALL[k]!.key)}</button>
              ))}
            </div>
          </div>
        )}
      </div>
      {menu.node}
    </div>
  );
}

/** The one thing in a capability's way, under its line: the attention mark and the problem, then its fix. `quiet`: a
 *  hint, not a problem (no mark). */
function FixLine({ text, quiet, children }: { text: string; quiet?: boolean; children?: ReactNode }) {
  return (
    <span className={`hm-fix ${quiet ? 'quiet' : ''}`}>
      {!quiet && <Icon name="warning" size={13} />}
      <span>{text}</span>
      {children}
    </span>
  );
}

/** Dictation's own shortcut besides its key (Reformat the last dictation): said when it's taken too. */
const HOTKEYS_DICT = ['reformat'];

/** "Press [Alt]+[Shift]+[A] to snap…": the key drawn as caps where {a} is (no key: the sentence without it). */
function tryLine(key: string, label: string): ReactNode {
  const s = t(key, { a: '\u0000' });
  const [before, after] = s.split('\u0000');
  if (!label) return (before + (after ?? '')).replace(/\s+/g, ' ').trim();
  return (
    <>
      {before}
      <Caps label={label} />
      {after}
    </>
  );
}

function entryIcon(e: FeedEntry): ReactNode {
  if (e.kind === 'dictation') return <Icon name="character-cursor" size={15} />;
  if (e.kind === 'recording') return <Icon name="video" size={15} />;
  if (e.kind === 'screen_text') return <Icon name={e.sub === 'translate' ? 'languages' : 'text-viewfinder'} size={15} />;
  if (e.kind === 'card') return <Icon name={e.sub === 'voice' ? 'mic' : e.sub === 'file' ? 'document' : e.sub === 'text' ? 'quote' : 'snap'} size={15} />;
  return <KindIcon kind={e.sub ?? 'note'} size={15} />;
}
