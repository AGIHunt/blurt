// Settings (the Mac's Settings window: Settings/SettingsWindow.swift, SettingsSearch.swift and the panes): a sidebar
// with the search field on top and the panes in three groups — Preferences: General, Dictation, Copy Text from Screen,
// Models, Shortcuts · Work: Projects, Agents · This PC: Privacy, Storage —, and the page: the pane, or the search
// results while there is a query. Ctrl+F focuses the search (the Mac's ⌘F), Esc clears it, ↓ / ↑ walk the results,
// Enter opens one. The last pane is remembered (app.settings_pane). On Windows the page lives in the main window (as
// Windows 11 apps keep their settings) instead of a window of its own; the tray's Settings… opens it.
// What each pane has and what it leaves out on Windows: docs/design/windows-parity/settings.md.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Icon } from '@blurt/icons';
import { api, listen, type AppStatus, type HotkeyResult, type HotkeyRow, type LoginItem, type MicState, type ProjectList, type Settings } from '../api';
import { i18n, t } from '../i18n';
import { comboFromEvent, comboLabel } from '../util';
import {
  ACTIONS, ENTRIES, GROUPS, MOVED, PANES, pane, paneOf, paneReason, reason, results, SECTIONS, setArguments, SHORTCUT_SECTIONS, shortcutTitle,
  SUGGESTIONS, textIn, type Entry, type Key, type PaneId, type ResultGroup,
} from '../settings/catalog';
import { Group, Line, Page, Popup, requestFlash, Row, S, TextLink, Toggle, lang } from '../settings/kit';
import { Menu, type MenuAt, type MenuEntry } from './Menu';
import { ProjectGlyph } from './glyphs';
import { OkMark } from './Welcome';
import '../settings/settings.css';
import { AgentsPane } from './AgentsSettings';
import { DictationPane, ModelsPane, ScreenTextPane } from './DictationSettings';
import { StoragePane } from './StorageSettings';

const REPO = 'https://github.com/AGIHunt/blurt';
const guideURL = () => `${REPO}/blob/main/docs/guide.md#${lang() === 'zh-Hans' ? encodeURIComponent('中文') : 'english'}`;

// a tray / deep-link "nav" to a pane can arrive before this page is mounted: kept until it is
let pendingNav: { pane?: string; check_updates?: boolean } | null = null;
let navListener: ((p: { pane?: string; check_updates?: boolean }) => void) | null = null;
listen<{ view?: string; pane?: string; check_updates?: boolean }>('nav', (p) => {
  if (p.view !== 'settings') return;
  pendingNav = p;
  navListener?.(p);
});

/** Open Settings at a pane from this page (the Welcome's "Change Shortcuts in Settings…"). */
export function goSettingsPane(pane: string) {
  pendingNav = { pane };
  navListener?.(pendingNav);
}

/** "speech" or "speech/speech.dictation" (a pane, then a row) → [pane, row]; a pane that moved goes where it went;
 *  a name that isn't a pane: General. */
function resolveLink(link: string | undefined | null, last: string | undefined): [PaneId, string | null] {
  const [p0, row] = (link ?? '').split('/');
  const p = MOVED[p0] ?? p0;
  if (p && pane(p)) return [p as PaneId, row ? (row.includes('.') ? row : `${p}.${row}`) : null];
  if (p) return ['general', null];
  const l = MOVED[last ?? ''] ?? last;
  return [l && pane(l) ? (l as PaneId) : 'general', null];
}

export function SettingsView({ status, onToast, onLang, onWelcome, onBack }: { status: AppStatus; onToast: (m: string) => void; onLang: (lang: string) => void; onWelcome?: () => void; onBack?: () => void }) {
  const [s, setS] = useState<Settings | null>(null);
  const [cur, setCur] = useState<PaneId>('general');
  const [query, setQuery] = useState('');
  const [checkUpdates, setCheckUpdates] = useState(0);
  const search = useRef<HTMLInputElement>(null);

  const reload = useCallback(() => api.settings().then(setS, (e) => onToast(String(e))), [onToast]);
  useEffect(() => {
    reload();
    return listen<HotkeyRow[]>('hotkeys://changed', (rows) => setS((x) => (x ? { ...x, hotkeys: rows } : x)));
  }, [reload]);

  // the pane to open: a nav (tray, link), else the last one
  const go = useCallback((p: PaneId, row?: string | null) => {
    setQuery('');
    setCur(p);
    api.setSettings({ app: { ...(s?.config?.app ?? {}), settings_pane: p } }).catch(() => {});
    if (row) requestFlash(row);
  }, [s]);
  const opened = useRef(false);
  useEffect(() => {
    if (!s || opened.current) return;
    opened.current = true;
    const [p, row] = resolveLink(pendingNav?.pane, s.config?.app?.settings_pane);
    if (pendingNav?.check_updates) setCheckUpdates((n) => n + 1);
    pendingNav = null;
    setCur(p);
    if (row) requestFlash(row);
    // ⌘, on the Mac: the cursor in the search field, ready to type
    if (!row) setTimeout(() => search.current?.focus(), 0);
  }, [s]);
  useEffect(() => {
    navListener = (n) => {
      const [p, row] = resolveLink(n.pane, cur);
      pendingNav = null;
      setQuery('');
      setCur(p);
      if (row) requestFlash(row);
      if (n.check_updates) setCheckUpdates((x) => x + 1);
    };
    return () => {
      navListener = null;
    };
  }, [cur]);

  // Ctrl+F: the search field (the Mac's ⌘F)
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && !e.altKey && e.key.toLowerCase() === 'f') {
        e.preventDefault();
        search.current?.focus();
        search.current?.select();
      }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, []);

  // titles that name a hotkey ("Alt+Shift+T translates into"): the user's key, else the action's name
  const hk = useCallback((a: string) => s?.hotkeys.find((r) => r.action === a && r.spec !== 'off')?.label ?? '', [s]);
  useEffect(() => {
    setArguments((k) => {
      if (k === 'settings.screen_text.translate' || k === 'settings.screen_text.section.translate') return { '1': hk('translate') || S('capture.action.translate') };
      // Copy Text from Screen's Copy section names its own key, as Translate does (the Mac's "Copy (⌥C)")
      if (k === 'settings.screen_text.section.copy') return { '1': hk('text') || S('capture.action.text') };
      return undefined;
    });
  }, [hk]);

  /** what this build shows: Linux has no dictation, no Copy Text from Screen and no login item here */
  const win = status.platform === 'win';
  const shown = useCallback(
    (e: Entry) => {
      const p = paneOf(e.id);
      if (!win && (p === 'dictation' || p === 'screentext' || e.section === 'general.cards' || e.id === 'shortcuts.dictation_key' || e.id === 'shortcuts.text' || e.id === 'shortcuts.translate')) return false;
      if (!win && (e.id === 'speech.dictation' || e.id === 'speech.polish' || e.id === 'speech.translate')) return false;
      return true;
    },
    [win],
  );
  const panes = PANES.filter((p) => win || (p.id !== 'dictation' && p.id !== 'screentext'));
  const groups = useMemo(() => (query.trim() ? results(query, lang(), shown) : []), [query, shown]);
  const counts = useMemo(() => new Map(groups.map((g) => [g.pane, g.paneHit ? ENTRIES.filter((e) => paneOf(e.id) === g.pane && shown(e) && !ACTIONS.has(e.id)).length : g.hits.length])), [groups, shown]);
  const searching = !!query.trim();

  // the results' stops for ↑ / ↓ / Enter
  const stops = useMemo(() => groups.flatMap((g) => [...(g.paneHit ? [{ pane: g.pane, row: null as string | null }] : []), ...g.hits.slice(0, g.paneHit ? 6 : 99).map((h) => ({ pane: g.pane, row: h.entry.id as string | null }))]), [groups]);
  const [sel, setSel] = useState(0);
  useEffect(() => setSel(0), [query]);
  const open = (i: number) => {
    const st = stops[i];
    if (st) go(st.pane, st.row);
  };

  if (!s) return <div className="blank">{t('settings.loading')}</div>;
  const cfg = s.config ?? {};
  const save = async (patch: Record<string, unknown>) => {
    await api.setSettings(patch);
    await reload();
  };

  return (
    <div className="st" data-testid="settings">
      <nav className="st-side" aria-label={S('settings.kit.general')}>
        {onBack && (
          <button type="button" className="st-back" onClick={onBack} data-testid="settings-back">
            <Icon name="chevron-left" size={14} />
            <span>{t('settings.back')}</span>
          </button>
        )}
        <div className="st-search">
          <Icon name="search" size={14} />
          <input
            ref={search}
            type="search"
            data-testid="settings-search"
            placeholder={S('settings.search.placeholder')}
            aria-label={S('settings.search.placeholder')}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Escape' && query) {
                e.preventDefault();
                setQuery('');
              } else if (e.key === 'ArrowDown' && searching) {
                e.preventDefault();
                setSel((x) => Math.min(stops.length - 1, x + 1));
              } else if (e.key === 'ArrowUp' && searching) {
                e.preventDefault();
                setSel((x) => Math.max(0, x - 1));
              } else if (e.key === 'Enter' && searching) {
                e.preventDefault();
                open(sel);
              }
            }}
          />
        </div>
        {GROUPS.map((g) => (
          <div key={g.id} role="group" aria-label={S(g.title)}>
            <div className="st-gtitle">{S(g.title)}</div>
            {panes.filter((p) => p.group === g.id).map((p) => {
              const n = searching ? counts.get(p.id) ?? 0 : null;
              return (
                <button key={p.id} className={`st-pane ${!searching && cur === p.id ? 'sel' : ''} ${n === 0 && groups.length ? 'dim' : ''}`} aria-current={!searching && cur === p.id ? 'page' : undefined}
                  data-testid={`settings-tab-${p.id}`} onClick={() => go(p.id)}>
                  <Icon name={p.icon} size={16} />
                  <span>{S(p.title)}</span>
                  {n ? <span className="st-count">{i18n().formatNumber(n)}</span> : null}
                </button>
              );
            })}
          </div>
        ))}
      </nav>
      {searching ? (
        <SearchResults query={query} groups={groups} stops={stops} sel={sel} setSel={setSel} open={open} clear={() => setQuery('')} setQuery={setQuery} hotkeys={s.hotkeys}
          counts={counts} dictKey={S(`dictation.key.${s.config.record?.dictation?.key === 'either_option' ? 'either_option' : 'right_option'}`)} />
      ) : cur === 'general' ? (
        <GeneralPane status={status} cfg={cfg} save={save} onToast={onToast} onLang={onLang} onWelcome={onWelcome} checkUpdates={checkUpdates} />
      ) : cur === 'dictation' ? (
        <DictationPane cfg={cfg} save={save} goModels={() => go('speech', 'speech.dictation')} goTranslate={() => go('speech', 'speech.translate')} keyOf={hk} />
      ) : cur === 'screentext' ? (
        <ScreenTextPane cfg={cfg} save={save} goTranslate={() => go('speech', 'speech.translate')} />
      ) : cur === 'speech' ? (
        <ModelsPane status={status} onToast={onToast} />
      ) : cur === 'shortcuts' ? (
        <ShortcutsPane s={s} status={status} reload={reload} goDictation={() => go('dictation', 'dictation.key')} />
      ) : cur === 'projects' ? (
        <ProjectsPane onToast={onToast} />
      ) : cur === 'agents' ? (
        <AgentsPane cfg={cfg} save={save} onToast={onToast} />
      ) : cur === 'privacy' ? (
        <PrivacyPane go={go} />
      ) : (
        <StoragePane status={status} s={s} save={save} onToast={onToast} />
      )}
    </div>
  );
}

// ------------------------------------------------------------------ search results

/** The matched words in bold (the Mac's results), the rest as it is. */
function Marked({ text, q }: { text: string; q: string }) {
  const words = q.toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return <>{text}</>;
  const lo = text.toLowerCase();
  const at = words.map((w) => [lo.indexOf(w), w.length] as const).filter(([i]) => i >= 0).sort((a, b) => a[0] - b[0])[0];
  if (!at) return <>{text}</>;
  return <>{text.slice(0, at[0])}<b>{text.slice(at[0], at[0] + at[1])}</b>{text.slice(at[0] + at[1])}</>;
}

function SearchResults({ query, groups, stops, sel, setSel, open, clear, setQuery, hotkeys, counts, dictKey }: {
  query: string;
  groups: ResultGroup[];
  stops: { pane: PaneId; row: string | null }[];
  sel: number;
  setSel: (i: number) => void;
  open: (i: number) => void;
  clear: () => void;
  setQuery: (q: string) => void;
  hotkeys: HotkeyRow[];
  /** each pane's hits, as the sidebar shows them: the lead's total is their sum, so the three never disagree */
  counts: Map<PaneId, number>;
  /** the dictation key's name ("Right Alt"): the Dictation › Shortcut hit shows it, as the Mac shows Fn */
  dictKey: string;
}) {
  const [more, setMore] = useState<Set<string>>(new Set());
  const total = [...counts.values()].reduce((a, n) => a + n, 0);
  const q = query.trim();
  const L = lang();
  const idx = (p: PaneId, row: string | null) => stops.findIndex((s) => s.pane === p && s.row === row);
  return (
    <div className="st-page" data-testid="settings-results">
      <div className="st-col">
        <h1 className="st-title">{S('settings.search.title_query', q)}</h1>
        {!groups.length ? (
          // the Mac's empty state: the query stays the title; a magnifier hangs left of "No results", the hint,
          // the common searches as links, and Clear Search as a real button
          <div className="st-none">
            <Icon name="search" size={20} />
            <div className="st-none-body">
              <div className="title">{S('settings.search.none.title_short')}</div>
              <div>{S('settings.search.none.hint')}</div>
              <div className="try">
                <span>{S('settings.search.none.common')}</span>
                {SUGGESTIONS.map((k, i) => (
                  <span key={k}>
                    {i > 0 && <span aria-hidden> · </span>}
                    <TextLink ink onClick={() => setQuery(S(k))}>{S(k)}</TextLink>
                  </span>
                ))}
              </div>
              <button className="st-none-clear" onClick={clear}>{S('settings.search.clear')}</button>
            </div>
          </div>
        ) : (
          <>
            <div className="st-results-lead">
              <span>{total === 1 ? S('settings.search.count_only.one') : S('settings.search.count_only', total)}</span>
              {total > 1 && (
                <span className="st-keyhint"><kbd>↑</kbd><kbd>↓</kbd> {S('settings.search.hint.choose')} <kbd>Enter</kbd> {S('settings.search.hint.open')}</span>
              )}
            </div>
            {groups.map((g) => {
              const p = pane(g.pane)!;
              const all = more.has(g.pane);
              const hits = g.paneHit && !all ? g.hits.slice(0, 6) : g.hits;
              return (
                <section key={g.pane} className="st-rgroup">
                  <h2 className="st-rhead"><Icon name={p.icon} size={16} />{S(p.title)}<span className="st-rcount">{i18n().formatNumber(counts.get(g.pane) ?? g.hits.length)}</span></h2>
                  {g.paneHit && (() => {
                    const k = idx(g.pane, null);
                    const why = paneReason(g.pane, q, L);
                    return (
                      <button className={`st-hit ${sel === k ? 'sel' : ''}`} onMouseMove={() => setSel(k)} onClick={() => open(k)}>
                        <span className="st-hit-text"><span className="st-hit-title"><Marked text={S('settings.search.open_pane', S(p.title))} q={q} /></span>{why && <span className="why">{why}</span>}</span>
                        <Icon name="chevron-right" size={14} />
                      </button>
                    );
                  })()}
                  {hits.map((h) => {
                    const e = h.entry;
                    const k = idx(g.pane, e.id);
                    const why = reason(e, q, L);
                    const sec = e.section && e.kind !== 'section' ? textIn(SECTIONS[e.section], L) : undefined;
                    const key = e.id === 'shortcuts.dictation_key' || e.id === 'dictation.key' ? dictKey : e.id.startsWith('shortcuts.') ? hotkeys.find((r) => `shortcuts.${r.action}` === e.id)?.label : undefined;
                    // a section's name only where it tells two hits apart, never the pane's own name again
                    const where = !key && sec && sec !== S(p.title) && g.hits.filter((x) => x.entry.section === e.section).length === 1 ? sec : null;
                    return (
                      <div key={e.id} className="st-hitwrap">
                        <button className={`st-hit ${sel === k ? 'sel' : ''} ${ACTIONS.has(e.id) ? 'action' : ''}`} onMouseMove={() => k >= 0 && setSel(k)} onClick={() => (k >= 0 ? open(k) : undefined)}
                          aria-label={S('settings.search.result.ax', textIn(e.title, L) ?? e.id, S(p.title))}>
                          <span className="st-hit-text">
                            <span className="st-hit-title"><Marked text={textIn(e.title, L) ?? ''} q={q} /></span>
                            {why && !key && <span className="why">{why}</span>}
                          </span>
                          {key ? <KeyCaps label={key} /> : where ? <span className="where">{where}</span> : null}
                        </button>
                      </div>
                    );
                  })}
                  {g.paneHit && g.hits.length > 6 && (
                    <TextLink ink onClick={() => setMore((m) => {
                      const n = new Set(m);
                      if (all) n.delete(g.pane);
                      else n.add(g.pane);
                      return n;
                    })}>{all ? S('settings.search.fewer') : S('settings.search.more', g.hits.length - 6)}<Icon name={all ? 'chevron-up' : 'chevron-down'} size={12} /></TextLink>
                  )}
                </section>
              );
            })}
          </>
        )}
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ General

function GeneralPane({ status, cfg, save, onToast, onLang, onWelcome, checkUpdates }: {
  status: AppStatus;
  cfg: Record<string, any>;
  save: (patch: Record<string, unknown>) => Promise<void>;
  onToast: (m: string) => void;
  onLang: (lang: string) => void;
  onWelcome?: () => void;
  checkUpdates: number;
}) {
  const [login, setLogin] = useState<LoginItem | null>(null);
  const [loginErr, setLoginErr] = useState(false);
  const [update, setUpdate] = useState<{ configured: boolean; text?: string; found?: string | null; busy?: boolean }>({ configured: false });
  const [contract, setContract] = useState<'skill_older' | 'app_older' | null>(null);
  useEffect(() => {
    api.loginItem().then(setLogin, () => {});
    // Check for Updates… only where this build can update itself (the Mac: Sparkle with a key); a version the
    // background check found is named at once
    api.updateState().then((r) => setUpdate({ configured: r.configured, found: r.pending, text: r.pending ? S('win.about.updates.available', r.pending) : undefined }), () => {});
    api.appContract().then((c) => setContract(c.mismatch), () => {});
    return listen<{ done?: number; total?: number | null; error?: string }>('update://progress', (p) =>
      setUpdate((u) => ({ ...u, busy: !p.error, text: p.error ? S('win.about.updates.failed') : S('win.update.downloading') })));
  }, []);
  const check = useCallback(async () => {
    setUpdate((u) => ({ ...u, busy: true, text: S('win.about.updates.checking') }));
    try {
      const r = await api.updateCheck();
      setUpdate({ configured: r.configured, found: r.version ?? null, text: r.available ? S('win.about.updates.available', r.version ?? '') : S('win.about.updates.latest') });
    } catch {
      setUpdate((u) => ({ ...u, busy: false, text: S('win.about.updates.failed') }));
    }
  }, []);
  useEffect(() => {
    if (checkUpdates) check();
  }, [checkUpdates, check]);

  const language = cfg.lang === 'zh' ? 'zh-Hans' : ['en', 'zh-Hans'].includes(cfg.lang) ? cfg.lang : 'auto';
  const rec = cfg.record ?? {};
  const voice = rec.voice ?? {};
  const liveText = rec.live_text !== false;
  // what a card dragged into an app carries: one choice over three settings (GeneralPane.swift's CardDragMode)
  const cardDrag = rec.drag_caption === true ? 'caption' : rec.smart_paste === false ? 'picture' : 'paste';
  const setCardDrag = (m: string) =>
    save({ record: { smart_paste: m === 'paste' ? null : false, drag_caption: m === 'caption' ? true : null, drag_copy_note: m === 'picture' ? false : null } });
  return (
    <Page id="general">
      <Group id="general.app">
        {login?.supported && (
          <Toggle id="general.login" on={login.enabled} detail={loginErr ? S('settings.general.login_failed') : undefined} warn={loginErr}
            set={(v) => api.setLoginItem(v).then((l) => (setLogin(l), setLoginErr(l.enabled !== v)), () => setLoginErr(true))} />
        )}
        <Row id="general.language">
          <Popup label={S('settings.general.language')} value={language} dividers={[1]}
            choices={[['auto', S('settings.general.language.system')], ['en', 'English'], ['zh-Hans', '简体中文']]}
            onChange={async (v) => {
              await save({ lang: v === 'auto' ? null : v });
              onLang(v);
            }} />
        </Row>
        <Toggle id="general.notify_done" on={cfg.notify?.done !== false} set={(v) => save({ notify: { ...(cfg.notify ?? {}), done: v } })} />
      </Group>

      {/* record.process / countdown / system_audio, as the Mac writes them (capture reads them at the next recording) */}
      <Group id="general.recording">
        <Row id="general.after_recording">
          <Popup label={S('settings.general.after_recording')} value={rec.process === 'off' ? 'off' : 'auto'}
            choices={[['auto', S('app.menu.after.organize')], ['off', S('app.menu.after.keep')]]} onChange={(v) => save({ record: { process: v } })} />
        </Row>
        <Row id="general.countdown">
          <Popup label={S('app.menu.countdown')} value={[0, 3, 5].includes(rec.countdown) ? rec.countdown : 3}
            choices={[[0, S('app.menu.countdown.none')], [3, S('app.menu.countdown.seconds', 3)], [5, S('app.menu.countdown.seconds', 5)]]}
            onChange={(v) => save({ record: { countdown: v } })} />
        </Row>
        <Toggle id="general.system_audio" on={rec.system_audio === true} set={(v) => save({ record: { system_audio: v } })} />
      </Group>

      <Group id="general.voice">
        <Row id="general.voice_end_on_pause">
          <Popup label={S('settings.general.voice_end_on_pause')} value={voice.end_on_pause === true}
            choices={[[false, S('settings.general.voice_end.key')], [true, S('settings.general.voice_end.pause')]]}
            onChange={(v) => save({ record: { voice: { ...voice, end_on_pause: v ? true : undefined } } })} />
        </Row>
        <Toggle id="general.live_text" on={liveText} set={(v) => save({ record: { live_text: v ? null : false } })} />
      </Group>

      {status.platform === 'win' && (
        <Group id="general.cards">
          <Toggle id="general.collect" on={rec.collect_system_shots === true} set={(v) => save({ record: { collect_system_shots: v ? true : null } })} />
          <Toggle id="general.snap_sound" on={rec.snap_sound === true} set={(v) => save({ record: { snap_sound: v ? true : null } })} />
          <Row id="general.card_drag">
            <Popup label={S('settings.general.card_drag')} value={cardDrag} choices={(['paste', 'caption', 'picture'] as const).map((m) => [m, S(`settings.general.card_drag.${m}`)] as [string, string])}
              onChange={setCardDrag} />
          </Row>
          <Toggle id="general.drag_note_file" on={rec.drag_note_file === true} set={(v) => save({ record: { drag_note_file: v ? true : null } })} />
        </Group>
      )}

      {/* About, as one quiet line: the version, then the rarely needed ways on; a skill / app mismatch above it */}
      <div className="st-about st-about-line" data-setting="general.about" data-kind="section">
        {contract && (
          <div className="st-about-warn">
            <span className="st-warn">{S(`app.contract.${contract}`)}</span>
            <TextLink ink onClick={() => api.appContractHelp()}>{S('app.contract.how')}</TextLink>
          </div>
        )}
        <span>{S('settings.general.about.version', status.version)}</span>
        {update.configured && !contract && (
          <>
            <span aria-hidden>·</span>
            {update.found ? (
              <TextLink ink onClick={() => api.updateInstall()}>{S('win.update.install')}</TextLink>
            ) : (
              <TextLink ink onClick={check}>{S('app.menu.updates')}</TextLink>
            )}
          </>
        )}
        {update.text && <span>{update.text}</span>}
        <span aria-hidden>·</span>
        <TextLink onClick={() => api.openUrl(guideURL()).catch((e) => onToast(String(e)))}>{S('settings.general.help')}</TextLink>
        {onWelcome && (
          <>
            <span aria-hidden>·</span>
            <TextLink onClick={onWelcome}>{S('settings.general.assistant.link')}</TextLink>
          </>
        )}
      </div>
    </Page>
  );
}

// ------------------------------------------------------------------ Shortcuts

function stateText(r: { result: string; of?: string; action?: string; name?: string; hint_url?: string; label?: string }, platform: AppStatus['platform']): string {
  switch (r.result) {
    case 'duplicate':
      return S('capture.keys.duplicate', S(shortcutTitle(r.of ?? r.action ?? '')));
    case 'system': {
      // the key the user pressed, and what Windows does with it, in their language (hotkeys.rs names it in English)
      const app = r.name ? S((`win.keys.app.${r.name.toLowerCase().replace(/[^a-z]+/g, '_').replace(/^_|_$/g, '')}`) as Key) : '';
      const name = app && !app.startsWith('win.keys.app.') ? app : r.name ?? '';
      return r.label ? S('win.keys.system_named', r.label, name) : S('win.keys.system', name);
    }
    case 'taken':
      return S('capture.keys.failed');
    case 'invalid':
      return S('win.keys.invalid', platform === 'win' ? 'Win' : 'Super');
    case 'portal':
      return S('win.keys.portal');
    case 'pending':
      return S('win.keys.pending');
    case 'manual':
      return S('win.keys.manual', r.hint_url ?? 'blurt://record');
    default:
      return '';
  }
}

/** A shortcut as keycaps, one quiet chip per key (the Mac's KeyCaps; Windows names: Alt, Shift, Win). */
export function KeyCaps({ label, tone }: { label: string; tone?: 'pending' | 'refused' }) {
  const keys = label.split('+').map((k) => k.trim()).filter(Boolean);
  return (
    <span className={`st-caps ${tone ?? ''}`}>
      {keys.map((k, i) => <kbd key={i}>{k}</kbd>)}
    </span>
  );
}

function KeyField({ row, pending, refused, onSet, onAsk, onRecording }: {
  row: HotkeyRow;
  /** the keys just pressed, waiting on Swap / Cancel: shown in the field, tinted */
  pending?: string | null;
  onSet: (combo: string) => Promise<HotkeyResult>;
  onAsk: (r: HotkeyResult, combo: string) => void;
  /** keys Windows keeps that were just refused: shown for a moment, then the field is back to its keys */
  refused?: string | null;
  onRecording?: (on: boolean) => void;
}) {
  const [rec, setRec] = useState(false);
  const [held, setHeld] = useState('');
  const off = row.spec === 'off';
  // while it records, Blurt's own global hotkeys stand down, or pressing a key another action holds would fire that
  // action instead of reaching this field (the Mac's HotkeySettings: `Hotkeys.shared.suspended`)
  useEffect(() => {
    onRecording?.(rec);
    if (!rec) return setHeld('');
    void api.suspendShortcuts(true).catch(() => {});
    return () => void api.suspendShortcuts(false).catch(() => {});
  }, [rec]);
  const mods = (e: React.KeyboardEvent) => [e.ctrlKey && 'Ctrl', e.altKey && 'Alt', e.shiftKey && 'Shift', e.metaKey && 'Win'].filter(Boolean).join('+');
  return (
    <button className={`st-key ${rec ? 'rec' : ''} ${off && !rec ? 'off' : ''} ${pending ? 'pending' : ''} ${refused ? 'refused' : ''}`}
      aria-label={`${S(shortcutTitle(row.action))}: ${row.label || S('capture.keys.none')}`}
      data-testid={`hotkey-${row.action}`}
      onClick={() => setRec(true)} onBlur={() => setRec(false)}
      onKeyUp={(e) => rec && setHeld(mods(e))}
      onKeyDown={async (e) => {
        if (!rec) return;
        e.preventDefault();
        if (e.key === 'Escape') return setRec(false);
        if (e.key === 'Backspace' || e.key === 'Delete') {
          setRec(false);
          await onSet('off');
          return;
        }
        const c = comboFromEvent(e);
        // modifiers only so far: show them as they're held
        if (!c) return setHeld(mods(e));
        setRec(false);
        const r = await onSet(c);
        if (r.result !== 'ok') onAsk(r, c);
      }}>
      {rec ? (
        <>
          {held ? <KeyCaps label={held} /> : <span className="st-key-type">{S('capture.keys.type')}</span>}
          <kbd className="st-key-esc">Esc</kbd>
        </>
      ) : refused ? (
        <KeyCaps label={refused} tone="refused" />
      ) : pending ? (
        <KeyCaps label={pending} tone="pending" />
      ) : row.label ? (
        <KeyCaps label={row.label} />
      ) : (
        <span className="st-key-none">{S('capture.keys.none')}</span>
      )}
    </button>
  );
}

function ShortcutsPane({ s, status, reload, goDictation }: { s: Settings; status: AppStatus; reload: () => Promise<unknown>; goDictation: () => void }) {
  const [ask, setAsk] = useState<{ action: string; r: HotkeyResult; combo: string } | null>(null);
  // a refused key stays in its field for a moment (the Mac's), then the field is back to its own keys
  const [refused, setRefused] = useState<{ action: string; label: string } | null>(null);
  useEffect(() => {
    if (!refused) return;
    const h = setTimeout(() => setRefused(null), 2500);
    return () => clearTimeout(h);
  }, [refused]);
  // Swap / Cancel from the keyboard while the question is up: Enter swaps, Esc cancels
  useEffect(() => {
    if (!ask || ask.r.result !== 'duplicate' || !ask.r.action) return;
    const k = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        setAsk(null);
      } else if (e.key === 'Enter') {
        e.preventDefault();
        void swap();
      }
    };
    addEventListener('keydown', k);
    return () => removeEventListener('keydown', k);
  }, [ask]);
  const rows = new Map(s.hotkeys.map((r) => [r.action, r]));
  const set = async (a: string, c: string) => {
    const r = await api.setShortcut(a, c);
    await reload();
    if (r.result === 'ok') setAsk(null);
    return r;
  };
  // the keys another action holds: swap them (the Mac's "Swap with …?"), or take them when this one had none
  const swap = async () => {
    if (!ask?.r.action) return;
    const mine = rows.get(ask.action)?.spec ?? 'off';
    await api.setShortcut(ask.action, 'off');
    await api.setShortcut(ask.r.action, mine);
    await api.setShortcut(ask.action, ask.combo);
    setAsk(null);
    await reload();
  };
  const d = s.config.record?.dictation ?? {};
  const dkey = d.key === 'either_option' ? 'either_option' : 'right_option';
  const win = status.platform === 'win';
  return (
    <Page id="shortcuts" lead={<span>{S('capture.keys.field_help')}</span>}>
      {s.wayland && s.hotkey_mode === 'portal' && <p className="st-lead">{S('win.keys.portal_note')}</p>}
      {SHORTCUT_SECTIONS.map((sec) => {
        const actions = sec.actions.filter((a) => rows.has(a) && (win || (a !== 'text' && a !== 'translate')));
        if (sec.section === 'shortcuts.dictation' && !win) return null;
        if (!actions.length && sec.section !== 'shortcuts.dictation') return null;
        return (
          <Group key={sec.section} id={sec.section}>
            {sec.section === 'shortcuts.dictation' && (
              <Row id="shortcuts.dictation_key" detail={<TextLink ink onClick={goDictation}>{S('win.keys.dictation')}</TextLink>}>
                <span className="st-key static"><KeyCaps label={S(`dictation.key.${dkey}`)} /></span>
              </Row>
            )}
            {actions.map((a) => {
              const r = rows.get(a)!;
              const asking = ask?.action === a ? ask : null;
              const bad = ['duplicate', 'system', 'taken', 'invalid', 'manual'].includes(r.result);
              const other = asking?.r.action;
              const swapping = asking?.r.result === 'duplicate' && !!other;
              const pressed = asking ? comboLabel(asking.combo, win ? 'win' : 'gnome') : '';
              // the swap question is a choice, not a warning: secondary ink, two inline text actions (the Mac's
              // s24_shortcut_swap_ask); a refusal keeps the attention colour and its mark
              const line = asking
                ? swapping
                  ? rows.get(a)?.spec === 'off'
                    ? S('capture.keys.move.ask_outcome', S(shortcutTitle(other!)) ?? other, asking.r.label ?? asking.combo)
                    : S('capture.keys.swap.ask_outcome', S(shortcutTitle(other!)), rows.get(a)?.label ?? '')
                  : stateText({ ...asking.r, label: pressed }, status.platform)
                : bad
                  ? stateText(r, status.platform)
                  : undefined;
              const detail = swapping ? (
                <span className="st-ask">
                  <span>{line}</span>
                  <button type="button" className="st-ask-ok" onClick={swap}>{S(rows.get(a)?.spec === 'off' ? 'capture.keys.move.ok' : 'capture.keys.swap.ok')}</button>
                  <button type="button" className="st-ask-no" onClick={() => setAsk(null)}>{S('capture.keys.swap.cancel')}</button>
                </span>
              ) : line;
              return (
                <Row key={a} id={`shortcuts.${a}`} detail={detail} warn={!!line && !swapping}>
                  <KeyField row={r} pending={swapping ? pressed : null} refused={refused?.action === a ? refused.label : null}
                    onSet={(c) => set(a, c)}
                    onAsk={(res, combo) => {
                      setAsk({ action: a, r: res, combo });
                      if (res.result !== 'duplicate') setRefused({ action: a, label: comboLabel(combo, win ? 'win' : 'gnome') });
                    }} />
                </Row>
              );
            })}
          </Group>
        );
      })}
      <div className="st-about st-restore" data-setting="shortcuts.restore">
        <button onClick={async () => {
          // one write: set one at a time, a swapped pair would refuse each other's default as taken
          await api.resetShortcuts().catch(() => {});
          setAsk(null);
          await reload();
        }}>{S('capture.keys.restore')}</button>
      </div>
    </Page>
  );
}

// ------------------------------------------------------------------ Projects

/** "C:\Users\ann\code\acme-web" → "…\code\acme-web" (the full path is the tooltip; the Mac's "/…/proj/x") */
function shortPath(p: string): string {
  const parts = p.split(/[\\/]/).filter(Boolean);
  return parts.length > 2 ? `…\\${parts.slice(-2).join('\\')}` : p;
}

/** Settings → Projects (the Mac's ProjectsPane): the folders, each a quiet row — its folder in its own colour, the
 *  name, the path shortened — with nothing at rest; a ⋯ at the row's end on hover (and the same menu on a right-click)
 *  holds Show in File Explorer and Send New Snaps Here. The header keeps Add Project Folder… and a ⋯ for Show
 *  Unassigned in File Explorer. "New ones go to" below is the one control for where snaps go. */
function ProjectsPane({ onToast }: { onToast: (m: string) => void }) {
  const [list, setList] = useState<ProjectList | null>(null);
  const [menuAt, setMenuAt] = useState<{ entries: MenuEntry[]; at: MenuAt } | null>(null);
  const load = useCallback(() => api.projects().then(setList, (e) => onToast(String(e))), [onToast]);
  useEffect(() => {
    load();
    return listen('projects://changed', () => load());
  }, [load]);
  if (!list) return <Page id="projects"><p className="st-lead">{t('settings.loading')}</p></Page>;
  const current = list.current === 'auto' || !list.current ? 'inbox' : list.current;
  const use = (id: string) => api.useProject(id === 'inbox' ? 'auto' : id).then(load, (e) => onToast(String(e)));
  const projects = [...list.projects].sort((a, b) => (b.last_used ?? '').localeCompare(a.last_used ?? ''));
  const rowMenu = (p: ProjectList['projects'][number]): MenuEntry[] => [
    { label: S('win.projects.reveal'), run: () => api.reveal(p.path).catch((e) => onToast(String(e))) },
    { label: S('settings.projects.make_current'), checked: current === p.id, disabled: !p.exists || current === p.id, run: () => use(p.id) },
  ];
  const headMenu: MenuEntry[] = [{ label: S('settings.general.open_unassigned'), run: () => api.reveal(list.inbox.path).catch((e) => onToast(String(e))) }];
  return (
    <Page id="projects">
      <Group id="projects.list" title={S('settings.projects.list_heading')} footer={S('settings.general.projects.hint')}
        accessory={<span className="st-ctl">
          <button className="link st-more st-more-on" aria-label={S('settings.general.open_unassigned')} title={S('settings.general.open_unassigned')}
            onClick={(e) => setMenuAt({ entries: headMenu, at: { x: 0, y: 0, anchor: e.currentTarget } })}><Icon name="more" size={14} /></button>
          <button onClick={() => api.openFolder().catch((e) => onToast(String(e)))}>{S('settings.projects.add')}</button>
        </span>}>
        {projects.map((p) => (
          <div key={p.id} className="st-proj" title={p.path} onContextMenu={(e) => {
            e.preventDefault();
            setMenuAt({ entries: rowMenu(p), at: { x: e.clientX, y: e.clientY } });
          }}>
            <Line icon="folder" glyph={p.exists ? <ProjectGlyph id={p.id} size={16} /> : undefined} title={p.name} detail={p.exists ? shortPath(p.path) : S('win.projects.missing')} warn={!p.exists}>
              <button className="link st-more" aria-label={S('agents.more.named', p.name)} onClick={(e) => setMenuAt({ entries: rowMenu(p), at: { x: 0, y: 0, anchor: e.currentTarget } })}>
                <Icon name="more" size={14} />
              </button>
            </Line>
          </div>
        ))}
      </Group>
      <Group id="projects.capture">
        <Row id="projects.capture_into">
          <Popup label={S('settings.general.capture_into')} value={current} wide dividers={projects.length ? [1] : []}
            choices={[['inbox', S('settings.general.none')], ...projects.filter((p) => p.exists).map((p) => [p.id, p.name] as [string, string])]}
            onChange={use} />
        </Row>
      </Group>
      {menuAt && <Menu entries={menuAt.entries} at={menuAt.at} onClose={() => setMenuAt(null)} />}
    </Page>
  );
}

// ------------------------------------------------------------------ Privacy

/** Settings → Privacy (the Mac's PrivacyPane): the lead with its two ways on (Models, where the files are), then the
 *  microphone as the Mac's permission row — what it's for (or the device), and at its end the state: a check and
 *  "Allowed", or the attention mark and "Off" with Windows Settings… only then. */
function PrivacyPane({ go }: { go: (p: PaneId, row?: string | null) => void }) {
  const [mic, setMic] = useState<MicState | null>(null);
  const load = () => api.mic().then(setMic, () => setMic(null));
  useEffect(() => {
    load();
    // back from Windows Settings: look again
    const f = () => load();
    window.addEventListener('focus', f);
    return () => window.removeEventListener('focus', f);
  }, []);
  const off = mic?.access === 'denied';
  const none = !!mic && !mic.device;
  return (
    <Page id="privacy" lead={<span className="st-privacy-lead">
      <span>{S('win.privacy.lead_short')}</span>{' '}
      <TextLink ink onClick={() => go('speech')}>{S('win.privacy.models_link')}</TextLink>
      <span aria-hidden> · </span>
      <TextLink ink onClick={() => go('storage')}>{S('win.privacy.files_link')}</TextLink>
    </span>}>
      {mic?.supported !== false && (
        <Group id="privacy.permissions">
          <Row id="privacy.mic" icon="mic" detail={off ? S('win.privacy.mic.off') : none ? S('win.privacy.mic.none') : mic?.device ? `${mic.device} · ${S('win.privacy.mic.why')}` : S('win.privacy.mic.why')} warn={off || none}>
            {mic && !off && mic.device ? (
              <span className="st-state good"><OkMark />{S('settings.kit.allowed')}</span>
            ) : (
              <button onClick={() => api.micSettings()}>{S('win.privacy.open')}</button>
            )}
          </Row>
        </Group>
      )}
    </Page>
  );
}
