// Dictation (听写): every dictation, newest first, grouped by day — the Mac's MainWindow/DictationPage.swift on
// Windows / Linux (dictation/history.rs). The list column: search, what stands in dictation's way (off, no speech
// model) as one banner, the days as quiet headings, each row the app, one chip when it didn't simply go in polished,
// the item it became, its time and the text in two lines. The detail: one dictation — where and when, the text
// (polished, heard, or the changes polish made marked in one text) with Copy and Correct on hover, Retry for a take
// that wasn't recognised, Turn into Item, the rest in "⋯", and the facts under it; several selected: Copy All and
// Delete. Delete has Undo (the toast, Ctrl+Z); the list's foot holds how long dictations are kept and Clear History.
//
// Keys (outside a field): ↑↓ (Shift/Ctrl-click for more), Del / Backspace deletes, Ctrl+Z puts it back, Ctrl+C
// copies, E or Enter corrects, Ctrl+Enter turns into an item, / or Ctrl+F searches (Esc clears it).
//
// Send Feedback… is in the header (FeedbackSheet.tsx); 历史 · 词库 under the title (the Words tab: DictationWords.tsx).
// The rows show the app's icon (a tile with its initial where there is none). Not here (Mac-only): the Lab tab, the
// Accessibility banner. The recording has no player here, as on the Mac: Show Recording is in ⋯.
import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Icon } from '@blurt/icons';
import { api, inTauri, listen, type DictationEntry, type DictationHistory } from '../api';
import * as D from '../dictation';
import { i18n, plural, t } from '../i18n';
import { isImeKey } from '../ime';
import { inField, nextSelection } from '../util';
import { S } from '../settings/kit';
import { FeedbackSheet } from './FeedbackSheet';
import { EmptyState } from './EmptyState';
import { Menu, MenuItem } from './DictMenu';
import { DictationWords } from './DictationWords';

type Mode = 'polished' | 'raw' | 'compare';
type Undo = { msg: string; run: () => Promise<void> };
/** `detail`: the detail's "⋯" (its Turn into Item is the button beside it) */
type MenuAt = { x: number; y: number; ids: string[]; detail?: boolean };

const KEEP = [7, 30, 90, 365];

const reasonText = (r: string | null | undefined) => {
  const k = `dictation_page.reason.${r ?? 'error'}`;
  return i18n().has(k) ? t(k) : t('dictation_page.reason.error');
};
const failedText = (e: DictationEntry) => (e.reason === 'asr_failed:model_missing' ? t('dictation_page.failed.no_model') : t('dictation_page.failed'));
const appLabel = (e: DictationEntry) => D.appName(e) ?? t('dictation_page.unknown_app');

function dayTitle(day: string): string {
  const [y, m, d] = day.split('-').map(Number);
  const date = new Date(y, m - 1, d);
  const today = new Date();
  const yest = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1);
  if (D.dayKey(today.toISOString()) === day) return t('dictation_page.today');
  if (D.dayKey(yest.toISOString()) === day) return t('dictation_page.yesterday');
  return i18n().formatDate(date, date.getFullYear() === today.getFullYear() ? { month: 'long', day: 'numeric', weekday: 'long' } : { year: 'numeric', month: 'long', day: 'numeric' });
}
const time = (iso: string) => i18n().formatDate(iso, 'time');
const length = (s: number) => i18n().formatDuration(Math.round(s || 0), 'clock');
/** When, short (the list's own form): "4:03 PM" today, "Yesterday 4:03 PM", "Oct 31 4:03 PM" — never a weekday and a
 *  year that push the app's name out of the header. */
function whenShort(iso: string): string {
  const day = D.dayKey(iso);
  const today = new Date();
  const yest = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1);
  if (D.dayKey(today.toISOString()) === day) return `${t('dictation_page.today')} ${time(iso)}`;
  if (D.dayKey(yest.toISOString()) === day) return `${t('dictation_page.yesterday')} ${time(iso)}`;
  const d = new Date(iso);
  return `${i18n().formatDate(d, d.getFullYear() === today.getFullYear() ? { month: 'short', day: 'numeric' } : { year: 'numeric', month: 'short', day: 'numeric' })} ${time(iso)}`;
}
/** A model id no list knows any more, readable ("qwen3-asr-0.6b" → "Qwen3-ASR 0.6B"). */
function prettyModel(id: string): string {
  const parts = id.split(':').slice(-1)[0].split(/[-_]/);
  const size = parts.length > 1 && /^\d+(\.\d+)?[bm]$/i.test(parts[parts.length - 1]) ? parts.pop()!.toUpperCase() : '';
  const name = parts.map((p) => (/^(asr|tts|cpu|gpu)$/i.test(p) ? p.toUpperCase() : p.charAt(0).toUpperCase() + p.slice(1))).join('-');
  return size ? `${name} ${size}` : name;
}

function Marked({ text, terms }: { text: string; terms: string[] }) {
  return <>{D.marked(text, terms).map(([s, on], i) => (on ? <mark key={i}>{s}</mark> : <Fragment key={i}>{s}</Fragment>))}</>;
}

const BULLET = /^[-•*]\s+/;
const NUM = /^\d+[.、)]\s*/;
/** A Structured take as its lead line (a heading such as "发布要准备三件事：") and its list items ("- a", "1. b"), else null. */
function listItems(text: string): { head: string; ordered: boolean; items: string[] } | null {
  const lines = text.split('\n').map((l) => l.trim()).filter(Boolean);
  const first = lines.findIndex((l) => BULLET.test(l) || NUM.test(l));
  if (first < 0 || first > 1) return null;
  const items = lines.slice(first);
  if (items.length < 2 || !items.every((l) => BULLET.test(l) || NUM.test(l))) return null;
  return { head: lines.slice(0, first).join(' '), ordered: NUM.test(items[0]), items: items.map((l) => l.replace(BULLET, '').replace(NUM, '')) };
}
/** A row's two lines: a list's items joined with " · ", never its raw "- " markers. */
const rowPreview = (text: string) => {
  const l = listItems(text);
  return l ? `${l.head ? `${l.head} ` : ''}${l.items.join(' · ')}` : D.preview(text);
};
/** The text as it reads: a Structured take as a real list (a hanging indent, the markers in secondary ink). */
function Read({ text }: { text: string }) {
  const l = listItems(text);
  if (!l) return <div className="dict-read">{text}</div>;
  const Tag = l.ordered ? 'ol' : 'ul';
  return (
    <div className="dict-read">
      {l.head && <div>{l.head}</div>}
      <Tag className="dict-list-read">{l.items.map((x, i) => <li key={i}>{x}</li>)}</Tag>
    </div>
  );
}

/** The app's icon as Windows shows it (the Mac's rows show the app's icon), the app's initial on a tile where there is
 *  none. One request per executable (cached here and in Rust). */
const ICONS = new Map<string, Promise<string | null>>();
function AppTile({ name, exe, size = 16 }: { name: string; exe?: string | null; size?: number }) {
  const [src, setSrc] = useState<string | null>(null);
  useEffect(() => {
    if (!exe || !inTauri) return;
    let p = ICONS.get(exe);
    if (!p) ICONS.set(exe, (p = api.appIcon(exe).catch(() => null)));
    let live = true;
    p.then((u) => live && setSrc(u));
    return () => {
      live = false;
    };
  }, [exe]);
  if (src) return <img className="dict-icon" src={src} width={size} height={size} alt="" aria-hidden="true" />;
  return <span className="dict-tile" style={{ width: size, height: size, fontSize: size * 0.6 }} aria-hidden="true">{name.charAt(0).toUpperCase()}</span>;
}
/** What the icon is looked up by: the executable's path when the take kept it, else its file name. */
const exeOf = (e: DictationEntry) => (typeof e.exe_path === 'string' && e.exe_path) || e.bundle || null;

/** Settings → Dictation's Manage… (the Mac's: opens this page on its Words tab) — taken by the next mount, or by the
 *  page that is already showing through the `blurt:words` event. */
let wordsNext = false;
export function openWordsTab() {
  wordsNext = true;
  window.dispatchEvent(new Event('blurt:words'));
}

export function DictationView({ project, onShowItem, onSettings, onToast }: {
  /** the current project (items go there), "auto" or null: Unassigned */
  project: string | null;
  onShowItem: (uid: string) => void;
  onSettings: () => void;
  onToast: (msg: string) => void;
}) {
  const [data, setData] = useState<DictationHistory | null>(null);
  // 历史 / 词库 (the Mac's two tabs in the list header)
  const [tab, setTab] = useState<'history' | 'words'>(() => (wordsNext ? ((wordsNext = false), 'words') : 'history'));
  useEffect(() => {
    const go = () => ((wordsNext = false), setTab('words'));
    window.addEventListener('blurt:words', go);
    return () => window.removeEventListener('blurt:words', go);
  }, []);
  const [cfg, setCfg] = useState<Record<string, any>>({});
  const [wordsN, setWordsN] = useState<number | null>(null);
  const [query, setQuery] = useState('');
  const [sel, setSel] = useState<Set<string>>(new Set());
  // Send Feedback… (the Mac's History → Send Feedback: FeedbackSheet.tsx)
  const [feedback, setFeedback] = useState(false);
  const [anchor, setAnchor] = useState<string | null>(null);
  const [mode, setMode] = useState<Mode>('polished');
  const [working, setWorking] = useState<Set<string>>(new Set());
  // the models' names as Settings shows them ("Fun-ASR-Nano (CPU)", "DeepSeek V4.1 Flash"), never their ids
  const [modelNames, setModelNames] = useState<Record<string, string>>({});
  // the speech models on this PC: a take's model that is gone says so (the Mac's "· 这台 Mac 上已经没有了")
  const [installed, setInstalled] = useState<Set<string> | null>(null);
  useEffect(() => {
    api.dictationModels().then((m) => {
      setModelNames((n) => ({ ...n, ...Object.fromEntries(m.models.map((r) => [r.id, r.name])) }));
      setInstalled(new Set(m.models.filter((r) => (r as { installed?: boolean }).installed).map((r) => r.id)));
    }, () => {});
    api.cloudCurated().then(
      (c) => setModelNames((n) => ({ ...n, ...Object.fromEntries(Object.values(c.jobs ?? {}).flat().map((o) => [`${o.service}:${o.model}`, o.name])) })),
      () => {},
    );
  }, []);
  /** "deepseek:deepseek-flash" → its curated name, else the model's own id without the service */
  const modelName = (id: string) => modelNames[id] ?? prettyModel(id);
  const [keepMenu, setKeepMenu] = useState<{ x: number; y: number; right?: boolean } | null>(null);
  const [retrying, setRetrying] = useState<Set<string>>(new Set());
  const [editing, setEditing] = useState<string | null>(null);
  const [draft, setDraft] = useState('');
  const [copied, setCopied] = useState<string | null>(null);
  const [undo, setUndo] = useState<Undo | null>(null);
  const [menu, setMenu] = useState<MenuAt | null>(null);
  const [confirmClear, setConfirmClear] = useState(false);
  const [error, setError] = useState('');
  const searchRef = useRef<HTMLInputElement>(null);
  const undoTimer = useRef<ReturnType<typeof setTimeout>>(undefined);

  const reload = useCallback(() => api.dictationHistory().then(setData, (e) => setError(String(e))), []);
  useEffect(() => {
    reload();
    api.settings().then((s) => setCfg(s.config ?? {}), () => {});
    const off = listen('dictation://changed', () => reload());
    const focus = () => reload();
    window.addEventListener('focus', focus);
    return () => {
      off();
      window.removeEventListener('focus', focus);
    };
  }, []);

  const entries = data?.entries ?? [];
  const filtered = useMemo(() => entries.filter((e) => D.matches(e, query, appLabel)), [entries, query]);
  const days = useMemo(() => D.byDay(filtered), [filtered]);
  const terms = useMemo(() => D.queryTerms(query), [query]);
  const selected = filtered.filter((e) => sel.has(e.id));
  const current = sel.size === 1 ? entries.find((e) => sel.has(e.id)) ?? null : null;
  const todayKey = D.dayKey(new Date().toISOString());

  // the first row, when nothing is selected yet (and a selection the list no longer has goes)
  useEffect(() => {
    const ids = new Set(filtered.map((e) => e.id));
    const keep = [...sel].filter((i) => ids.has(i));
    // a search always shows its first hit (the chosen one gone from the results, or nothing chosen yet)
    if (!keep.length && filtered.length) setSel(new Set([filtered[0].id]));
    else if (keep.length !== sel.size) setSel(new Set(keep));
  }, [filtered]);
  useEffect(() => {
    if (editing && current?.id !== editing) setEditing(null);
  }, [current?.id]);

  const flash = (id: string) => {
    setCopied(id);
    setTimeout(() => setCopied((c) => (c === id ? null : c)), 1200);
  };
  const copy = (text: string, id?: string) =>
    api.copyText(text).then(() => (id ? flash(id) : onToast(t('dictation_page.copied'))), (e) => onToast(String(e)));
  const shown = (e: DictationEntry) => (mode === 'raw' && D.differs(e) ? e.raw : D.finalText(e));
  const copySelection = () => {
    if (!selected.length) return;
    copy(selected.length === 1 ? shown(selected[0]) : selected.map(D.finalText).join('\n\n'));
  };

  const offerUndo = (msg: string, run: () => Promise<void>) => {
    clearTimeout(undoTimer.current);
    setUndo({ msg, run });
    undoTimer.current = setTimeout(() => setUndo(null), 5000);
  };
  const runUndo = async () => {
    const u = undo;
    if (!u) return;
    clearTimeout(undoTimer.current);
    setUndo(null);
    try {
      await u.run();
    } catch (e) {
      onToast(String(e));
    }
  };

  /** ⌫: the row after the last deleted one is selected next, as in Mail; the recordings wait for Undo. */
  const remove = async (es: DictationEntry[]) => {
    if (!es.length) return;
    const gone = new Set(es.map((e) => e.id));
    const i = filtered.findIndex((e) => gone.has(e.id));
    const next = filtered.slice(i).find((e) => !gone.has(e.id)) ?? filtered.slice(0, i).reverse().find((e) => !gone.has(e.id));
    setData((d) => (d ? { ...d, entries: d.entries.filter((e) => !gone.has(e.id)) } : d));
    setSel(new Set(next ? [next.id] : []));
    // the keys stay on the list (Del, Ctrl+Z, ↑↓), not in a search field that happened to have the focus
    if (inField(document.activeElement)) (document.activeElement as HTMLElement).blur();
    try {
      const r = await api.dictationEdit({ op: 'delete', ids: [...gone] });
      const back = r.deleted?.length ? r.deleted : es;
      offerUndo(es.length === 1 ? t('dictation_page.deleted_one') : plural('dictation_page.deleted', es.length), async () => {
        await api.dictationEdit({ op: 'restore', entries: back });
        await reload();
        setSel(gone);
      });
    } catch (e) {
      onToast(String(e));
      reload();
    }
  };

  const makeItem = async (e: DictationEntry) => {
    if (working.has(e.id)) return;
    setWorking((w) => new Set(w).add(e.id));
    try {
      const r = await api.dictationItem(e.id, project && project !== 'auto' ? project : null, i18n().lang);
      setError('');
      await reload();
      onToast(t('dictation_page.item_made', { id: r.item.id }));
    } catch (err) {
      setError(String(err));
    } finally {
      setWorking((w) => {
        const n = new Set(w);
        n.delete(e.id);
        return n;
      });
    }
  };

  const retry = async (e: DictationEntry) => {
    setRetrying((w) => new Set(w).add(e.id));
    try {
      await api.dictationRetry(e.id);
      await reload();
      onToast(t('dictation_page.retry.done'));
    } catch (err) {
      onToast(String(err).includes('[retry_gone]') ? t('dictation_page.retry.gone') : t('dictation_page.retry.failed'));
    } finally {
      setRetrying((w) => {
        const n = new Set(w);
        n.delete(e.id);
        return n;
      });
    }
  };

  const beginEdit = (e: DictationEntry) => {
    if (D.isFailed(e)) return;
    setDraft(D.finalText(e));
    setEditing(e.id);
  };
  const saveCorrection = async (e: DictationEntry) => {
    const text = draft.trim();
    setEditing(null);
    if (!text || text === D.finalText(e)) return;
    const previous = e.corrected ?? null;
    try {
      await api.dictationEdit({ op: 'correct', id: e.id, text });
      await reload();
      offerUndo(t('dictation_page.correct.saved'), async () => {
        await api.dictationEdit({ op: 'correct', id: e.id, text: previous });
        await reload();
      });
    } catch (err) {
      onToast(String(err));
    }
  };

  const setKeep = async (days: number) => {
    const d = cfg.record?.dictation ?? {};
    const patch = { record: { dictation: { ...d, retention_days: days === 30 ? null : days } } };
    try {
      setCfg(await api.setSettings(patch));
      setData((x) => (x ? { ...x, retention_days: days } : x));
    } catch (e) {
      onToast(String(e));
    }
  };
  /** The off banner's Turn On: dictation back on, right here (Settings → Dictation's switch, the same setting). */
  const turnOn = async () => {
    const d = cfg.record?.dictation ?? {};
    try {
      setCfg(await api.setSettings({ record: { dictation: { ...d, enabled: null } } }));
      await reload();
    } catch (e) {
      onToast(String(e));
    }
  };
  const clearAll = async () => {
    setConfirmClear(false);
    try {
      await api.dictationEdit({ op: 'clear' });
      setSel(new Set());
      await reload();
    } catch (e) {
      onToast(String(e));
    }
  };

  const pick = (id: string, how: 'one' | 'toggle' | 'range') => {
    setSel((cur) => nextSelection(filtered.map((e) => e.id), cur, anchor, id, how));
    if (how !== 'range') setAnchor(id);
  };

  // Ctrl+Z after a delete: this page's undo, before the window's own (App's item undo listens on the window too and
  // used to take it — the deleted takes didn't come back, an earlier inbox change was undone instead)
  useEffect(() => {
    const onUndo = (ev: KeyboardEvent) => {
      if (tab !== 'history' || !undo || !(ev.ctrlKey || ev.metaKey) || ev.key.toLowerCase() !== 'z' || ev.shiftKey || inField(ev.target)) return;
      if (isImeKey(ev) || menu || confirmClear || document.querySelector('.overlay')) return;
      ev.preventDefault();
      ev.stopPropagation();
      runUndo();
    };
    window.addEventListener('keydown', onUndo, true);
    return () => window.removeEventListener('keydown', onUndo, true);
  });

  // keys
  useEffect(() => {
    const onKey = (ev: KeyboardEvent) => {
      // the Words tab has its own keys
      if (tab !== 'history' || ev.defaultPrevented || isImeKey(ev) || menu || confirmClear || document.querySelector('.overlay')) return;
      const mod = ev.ctrlKey || ev.metaKey;
      const k = ev.key;
      if (mod && k.toLowerCase() === 'f') {
        ev.preventDefault();
        searchRef.current?.focus();
        return;
      }
      if (mod && k.toLowerCase() === 'z' && undo && !inField(ev.target)) {
        ev.preventDefault();
        runUndo();
        return;
      }
      if (inField(ev.target)) return;
      if (k === '/') {
        ev.preventDefault();
        searchRef.current?.focus();
      } else if (k === 'ArrowDown' || k === 'ArrowUp' || k === 'j' || k === 'k') {
        const ids = filtered.map((e) => e.id);
        const at = ids.findIndex((i) => i === (anchor && sel.has(anchor) ? anchor : [...sel][0]));
        const n = ids[Math.max(0, Math.min(ids.length - 1, at + (k === 'ArrowDown' || k === 'j' ? 1 : -1)))];
        if (n) {
          ev.preventDefault();
          if (ev.shiftKey) setSel((cur) => new Set(cur).add(n));
          else setSel(new Set([n]));
          setAnchor(n);
          document.querySelector(`[data-did="${n}"]`)?.scrollIntoView({ block: 'nearest' });
        }
      } else if ((k === 'Delete' || k === 'Backspace') && selected.length) {
        ev.preventDefault();
        remove(selected);
      } else if (mod && k.toLowerCase() === 'c' && !window.getSelection()?.toString()) {
        ev.preventDefault();
        copySelection();
      } else if (mod && k === 'Enter' && current && !current.item && !D.isFailed(current)) {
        ev.preventDefault();
        makeItem(current);
      } else if ((k === 'Enter' || k === 'e') && !mod && current && !(ev.target as HTMLElement).closest?.('button, a, audio')) {
        ev.preventDefault();
        beginEdit(current);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  });

  const keyName = cfg.record?.dictation?.key === 'either_option' ? t('dictation.key.either_alt') : t('dictation.key.right_alt');
  const blocked = data ? (!data.enabled ? 'off' : data.ready === false ? 'no_model' : null) : null;

  // what stands in dictation's way, in one line: the fact, then the one way out (off: neutral, a ring; no model: the
  // attention tint and its "!" — a shape twin, never colour alone)
  const banner = blocked && (
    <div className={`dict-banner ${blocked === 'off' ? 'off' : 'warn'}`} role="status">
      <Icon name={blocked === 'off' ? 'power' : 'warning'} size={16} />
      <span className="nm grow">{t(blocked === 'off' ? 'dictation_page.off' : 'dictation_page.banner.no_model')}</span>
      <button onClick={blocked === 'off' ? turnOn : onSettings}>{t(blocked === 'off' ? 'dictation_page.banner.turn_on' : 'dictation_page.banner.choose')}</button>
    </div>
  );

  const entryMenu = (es: DictationEntry[], withItem: boolean) => {
    if (es.length > 1)
      return (
        <>
          <MenuItem label={t('dictation_page.copy_all')} keys="Ctrl+C" onClick={() => copy(es.map(D.finalText).join('\n\n'))} />
          <div className="dict-sep" />
          <MenuItem label={t('dictation_page.delete')} keys="Del" danger onClick={() => remove(es)} />
        </>
      );
    const e = es[0];
    if (!e) return null;
    const failed = D.isFailed(e);
    return (
      <>
        <MenuItem label={t('dictation_page.copy')} keys="Ctrl+C" disabled={failed} onClick={() => copy(D.finalText(e), 'detail-text')} />
        {D.differs(e) && <MenuItem label={t('dictation_page.copy_raw')} onClick={() => copy(e.raw, 'detail-raw')} />}
        <div className="dict-sep" />
        {!failed && <MenuItem label={t('dictation_page.correct')} keys="E" onClick={() => { setSel(new Set([e.id])); beginEdit(e); }} />}
        {data?.can_retry && e.audio_path && <MenuItem label={t('dictation_page.retry')} disabled={retrying.has(e.id)} onClick={() => retry(e)} />}
        {withItem &&
          (e.item && e.item_uid ? (
            <MenuItem label={t('dictation_page.show_item', { id: e.item })} onClick={() => onShowItem(e.item_uid!)} />
          ) : (
            <MenuItem label={t('dictation_page.make_item')} keys="Ctrl+Enter" disabled={failed || working.has(e.id)} onClick={() => makeItem(e)} />
          ))}
        {e.audio_path && <MenuItem label={t('dictation_page.reveal_audio')} onClick={() => api.reveal(e.audio_path!)} />}
        <MenuItem label={t('dictation_page.settings')} onClick={onSettings} />
        <div className="dict-sep" />
        <MenuItem label={t('dictation_page.delete')} keys="Del" danger onClick={() => remove([e])} />
      </>
    );
  };

  const todayTip = () => {
    const s = D.stats(entries.filter((e) => D.dayKey(e.t) === todayKey));
    const parts = [plural('dictation_page.stat.count', s.count), plural('dictation_page.stat.words', s.words)];
    if (s.savedMinutes >= 1) parts.push(t('dictation_page.stat.saved', { n: s.savedMinutes }));
    return parts.join(' · ') + (s.savedMinutes >= 1 ? `\n${t('dictation_page.stat.saved.tip')}` : '');
  };

  const count = entries.length
    ? query.trim()
      ? t('dictation_page.count_of', { n: filtered.length, all: plural('dictation_page.count', entries.length) })
      : plural('dictation_page.count', entries.length)
    : '';

  // ---- the list column: the title, then 历史 · 词库 with Send Feedback across from them (the Mac's list header)
  const header = (
    <>
      <header className="project-head">
        <div className="txt">
          <h1>{t('dictation_page.title')}</h1>
          {count && tab === 'history' && <div className="sub dim small" data-testid="dictation-count">{count}</div>}
          {tab === 'words' && wordsN !== null && <div className="sub dim small">{plural('dictation_words.count', wordsN)}</div>}
        </div>
      </header>
      <div className="dict-tabs">
        <div className="seg" role="tablist" aria-label={t('dictation_page.title')}>
          {(['history', 'words'] as const).map((k) => (
            <button key={k} role="tab" aria-selected={tab === k} aria-checked={tab === k} className={tab === k ? 'on' : ''} data-testid={`dictation-tab-${k}`}
              onClick={() => { setTab(k); setUndo(null); }}>
              {t(`dictation_page.tab.${k}`)}
            </button>
          ))}
        </div>
        <span className="grow" />
        {entries.length > 0 && tab === 'history' && (
          <>
            <button className="link dict-feedback" title={S('dictation.feedback.button.tip')} data-testid="dictation-feedback" onClick={() => setFeedback(true)}>
              <Icon name="send" size={13} />
              {S('dictation.feedback.button')}
            </button>
            {/* how long dictations are kept, and Clear History…: the history's own housekeeping, behind ⋯ (the Mac
                keeps them in Settings → Dictation; the list column holds only the takes) */}
            <button className="icon-btn dict-ghost" aria-label={t('dictation_page.history_menu')} title={t('dictation_page.history_menu')} data-testid="dictation-history-menu"
              onClick={(ev) => { const b = ev.currentTarget.getBoundingClientRect(); setKeepMenu({ x: b.right, y: b.bottom + 4, right: true }); }}>
              <Icon name="more" size={15} />
            </button>
          </>
        )}
      </div>
    </>
  );
  const list = (
    <section className={`dict-list ${undo ? 'has-undo' : ''}`} data-testid="dictation-list">
      {header}
      {feedback && <FeedbackSheet entries={entries} selected={sel} close={() => setFeedback(false)} />}
      {entries.length > 0 && (
        <div className="dict-search">
          <div className="searchbox">
            <Icon name="search" size={14} />
            <input ref={searchRef} value={query} placeholder={t('dictation_page.search')} aria-label={t('dictation_page.search')} data-testid="dictation-search"
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Escape') {
                  e.preventDefault();
                  if (query) setQuery('');
                  else (e.target as HTMLInputElement).blur();
                } else if ((e.key === 'ArrowDown' || (e.key === 'Enter' && !isImeKey(e))) && filtered.length) {
                  e.preventDefault();
                  (e.target as HTMLInputElement).blur();
                  setSel(new Set([filtered[0].id]));
                }
              }} />
            {query && (
              <button className="icon-btn dict-clear-q" aria-label={t('dictation_page.clear_search')} title={t('dictation_page.clear_search')}
                onClick={() => { setQuery(''); searchRef.current?.focus(); }}>
                <Icon name="x" size={13} />
              </button>
            )}
          </div>
        </div>
      )}
      {entries.length > 0 && banner}
      {error && <p className="warn small dict-error">{error}</p>}
      {!data ? (
        <div className="blank" />
      ) : !entries.length ? (
        <EmptyState testId="dictation-empty" title={t('dictation_page.empty.title')} body={t('dictation_page.empty.body', { key: keyName })}>
          {/* the state, one shape per meaning (a filled dot: on; a ring: off; "!": needs a model), then its one way on */}
          {blocked ? (
            <div className="dict-empty-acts">
              <span className={`dict-pill ${blocked === 'off' ? '' : 'warn'}`}>
                {blocked === 'off' ? <span className="dict-dot off" /> : <Icon name="warning" size={13} />}
                {t(blocked === 'off' ? 'dictation_page.off' : 'dictation_page.banner.no_model')}
              </span>
              <button className="primary" onClick={blocked === 'off' ? turnOn : onSettings}>{t(blocked === 'off' ? 'dictation_page.banner.turn_on' : 'dictation_page.banner.choose')}</button>
            </div>
          ) : (
            <span className="dict-pill"><span className="dict-dot ok" />{t('dictation_page.ready')}</span>
          )}
        </EmptyState>
      ) : !filtered.length ? (
        <EmptyState testId="dictation-no-match" title={t('dictation_page.no_match', { q: shortQuery(query) })} body={t('dictation_page.no_match.hint')}>
          <button onClick={() => { setQuery(''); searchRef.current?.focus(); }}>{t('dictation_page.clear_search')}</button>
        </EmptyState>
      ) : (
        <div className="dict-rows" role="listbox" aria-multiselectable="true" aria-label={t('dictation_page.title')}>
          {days.map((g, n) => (
            <Fragment key={g.day}>
              <div className={`dict-day ${n === 0 ? 'first' : ''}`} role="presentation" title={g.day === todayKey ? todayTip() : undefined}>{dayTitle(g.day)}</div>
              {g.rows.map((e) => {
                const x = outcome(e);
                const app = appLabel(e);
                const on = sel.has(e.id);
                return (
                  <div key={e.id} role="option" aria-selected={on} data-did={e.id} data-testid="dictation-row"
                    className={`dict-row ${on ? 'sel' : ''} ${working.has(e.id) || retrying.has(e.id) ? 'working' : ''}`}
                    onClick={(ev) => pick(e.id, ev.shiftKey ? 'range' : ev.ctrlKey || ev.metaKey ? 'toggle' : 'one')}
                    onDoubleClick={() => beginEdit(e)}
                    onContextMenu={(ev) => {
                      ev.preventDefault();
                      const ids = on ? [...sel] : [e.id];
                      if (!on) setSel(new Set([e.id]));
                      setMenu({ x: ev.clientX, y: ev.clientY, ids });
                    }}>
                    <div className="dict-row-head">
                      <AppTile name={app} exe={exeOf(e)} />
                      <span className="dict-app"><Marked text={app} terms={terms} /></span>
                      {x && <span className={`dict-chip ${x === 'failed' ? 'warn' : ''}`} title={outcomeLine(e)}>{t(`dictation_page.chip.${x}`)}</span>}
                      <span className="grow" />
                      {e.item && (
                        <button className="link dict-item" title={t('dictation_page.show_item', { id: e.item })}
                          onClick={(ev) => { ev.stopPropagation(); if (e.item_uid) onShowItem(e.item_uid); }}>
                          {e.item}<span aria-hidden="true">↗</span>
                        </button>
                      )}
                      <span className="dict-time">{time(e.t)}</span>
                    </div>
                    {D.isFailed(e) ? (
                      <div className="dict-text dim">—</div>
                    ) : (
                      <div className="dict-text"><Marked text={rowPreview(D.finalText(e))} terms={terms} /></div>
                    )}
                  </div>
                );
              })}
            </Fragment>
          ))}
        </div>
      )}
      {keepMenu && (
        <Menu at={keepMenu} onClose={() => setKeepMenu(null)}>
          <div className="dict-mhead">{t('dictation_page.keep')}</div>
          {[...new Set([...KEEP, data?.retention_days ?? 30])].sort((a, b) => a - b).map((d) => (
            <MenuItem key={d} label={plural('dictation_page.days', d)} checked={(data?.retention_days ?? 30) === d} onClick={() => setKeep(d)} />
          ))}
          <div className="dict-sep" />
          <MenuItem label={t('dictation_page.clear')} danger testId="dictation-clear" onClick={() => setConfirmClear(true)} />
        </Menu>
      )}
      {undo && (
        // docked in its own lane at the list's foot (the rows get that much room under them): it never covers a row
        <div className="dict-undo" role="status">
          <span>{undo.msg}</span>
          <button className="dict-undo-btn" onClick={runUndo}>{t('dictation_page.undo')}</button>
        </div>
      )}
    </section>
  );

  // ---- the detail column
  const detail = (() => {
    if (current) return one(current);
    if (selected.length > 1) {
      const few = selected.slice(0, 8);
      return (
        <div className="dict-detail-in">
          <h2 className="dict-multi">{plural('dictation_page.multi', selected.length)}</h2>
          <div className="dict-acts">
            <button className="primary" onClick={copySelection}>{t('dictation_page.copy_all')}</button>
            <button className="icon-btn dict-ghost" aria-label={t('dictation_page.more')} title={t('dictation_page.more')}
              onClick={(ev) => { const r = ev.currentTarget.getBoundingClientRect(); setMenu({ x: r.left, y: r.bottom + 4, ids: selected.map((e) => e.id) }); }}>
              <Icon name="more" size={15} />
            </button>
          </div>
          <div className="dict-card">
            {few.map((e) => (
              <div key={e.id} className="dict-mini"><span className="dict-time">{time(e.t)}</span><span className="dict-mini-t">{rowPreview(D.finalText(e))}</span></div>
            ))}
            {selected.length > few.length && <div className="dim small">{t('dictation_page.multi.more', { n: selected.length - few.length })}</div>}
          </div>
          <Keys text={t('dictation_page.multi.keys')} />
        </div>
      );
    }
    if (!entries.length || !filtered.length) return null;
    return (
      <div className="blank dict-none">
        <Icon name="align-left" size={28} />
        <b>{t('dictation_page.none')}</b>
        <span className="small">{t('dictation_page.none.detail')}</span>
        <Keys text={t('dictation_page.none.keys')} />
      </div>
    );
  })();

  /** What happened to a take when it didn't simply go in polished — one word for the row's chip. */
  function outcome(e: DictationEntry): 'failed' | 'copied_raw' | 'copied' | 'fell_back' | 'not_typed' | null {
    if (D.isFailed(e)) return 'failed';
    const x = D.exception(e);
    if (x) return x;
    return e.insert === 'none' ? 'not_typed' : null;
  }
  /** …and the one sentence under the text that says what happened and why (the metadata stays factual). */
  function outcomeLine(e: DictationEntry): string {
    const x = outcome(e);
    if (x === 'copied') return t('dictation_page.status.copied');
    if (x === 'copied_raw') return t('dictation_page.status.copied_raw', { why: reasonText(e.reason) });
    if (x === 'fell_back') return t('dictation_page.status.raw', { why: reasonText(e.reason) });
    if (x === 'not_typed') return t('dictation_page.status.not_typed');
    return '';
  }

  function one(e: DictationEntry) {
    const diff = D.differs(e);
    const failed = D.isFailed(e);
    const isEditing = editing === e.id;
    const app = appLabel(e);
    const x = outcome(e);
    const line = outcomeLine(e);
    const busy = working.has(e.id);
    const ran = !failed && !e.fell_back && e.polished != null; // polish ran and its text went in
    const styleName = ran && e.style && i18n().has(`dictation_page.style.${e.style}`) ? t(`dictation_page.style.${e.style}`) : null;
    // the Polish row says only which model polished it (or Off): why it didn't is the line under the text
    const polishInfo = failed ? null : e.polished == null && !e.fell_back ? t('dictation_page.info.polish.off') : e.model ? modelName(e.model) : t('dictation_page.info.polished');
    // a speech model the list knows and this PC no longer has
    const asrGone = !!(e.asr_model && installed && modelNames[e.asr_model] !== undefined && !installed.has(e.asr_model));
    let language: string | null = null;
    try {
      language = e.language ? new Intl.DisplayNames([i18n().locale], { type: 'language' }).of(e.language) ?? e.language : null;
    } catch {
      language = e.language ?? null;
    }
    const text = mode === 'raw' && diff ? e.raw : D.finalText(e);
    return (
      <div className="dict-detail-in" data-testid="dictation-detail">
        {/* the app at its full name on top, when it was and how long under it, the view switch across (the Mac v0.8
            detail: the name never gives way to the meta) */}
        <div className="dict-dhead">
          <AppTile name={app} exe={exeOf(e)} size={20} />
          <div className="dict-dtitle">
            <b className="dict-dapp" title={app}>{app}</b>
            <span className="dict-when">
              {whenShort(e.t)} · {length(e.duration)}
              {e.corrected != null && (
                <button className="dict-tag" title={diff ? t('dictation_page.corrected.tip') : undefined} disabled={!diff} onClick={() => setMode('compare')}>
                  {t('dictation_page.corrected')}
                </button>
              )}
            </span>
          </div>
          <span className="grow" />
          {diff && !failed && !isEditing && (
            <div className="seg" role="radiogroup" aria-label={t('dictation_page.mode.label')}>
              {(['polished', 'raw', 'compare'] as const).map((m) => (
                <button key={m} role="radio" aria-checked={mode === m} className={mode === m ? 'on' : ''} onClick={() => setMode(m)}>
                  {t(`dictation_page.mode.${m}`)}
                </button>
              ))}
            </div>
          )}
        </div>

        {failed ? (
          // a take that wasn't recognised: the failure where the text would be, then the one way out (the Mac's
          // failed take and the island's line: why, and that the recording is kept)
          <div className="dict-failed">
            <Icon name="warning" size={16} />
            <div>
              <div className="dict-failed-t">{failedText(e)}</div>
              {e.audio_path && <div className="dim small">{t('dictation_page.failed.kept', { len: length(e.duration) })}</div>}
            </div>
          </div>
        ) : isEditing ? (
          <div className="dict-edit">
            <textarea autoFocus value={draft} aria-label={t('dictation_page.correct.title')} rows={Math.min(14, Math.max(2, draft.split('\n').length, Math.ceil(draft.length / 34)))}
              onFocus={(ev) => {
                const n = ev.currentTarget.value.length;
                ev.currentTarget.setSelectionRange(n, n);
              }}
              onChange={(ev) => setDraft(ev.target.value)}
              onKeyDown={(ev) => {
                if (isImeKey(ev)) return;
                if (ev.key === 'Enter' && (ev.ctrlKey || ev.metaKey)) {
                  ev.preventDefault();
                  saveCorrection(e);
                } else if (ev.key === 'Escape') {
                  ev.preventDefault();
                  ev.stopPropagation();
                  setEditing(null);
                }
              }} />
            <p className="dim small dict-caption">{t('dictation_page.correct.caption')}</p>
            <div className="dict-acts">
              <button className="primary" disabled={!draft.trim()} onClick={() => saveCorrection(e)}>{t('dictation_page.correct.save')}</button>
              <button onClick={() => setEditing(null)}>{t('dictation_page.correct.cancel')}</button>
              <span className="dim small">{t('dictation_page.correct.hint')}</span>
            </div>
          </div>
        ) : diff && mode === 'compare' ? (
          <div className="dict-changes">
            <div className="dict-read">
              {D.changes(e.raw, D.finalText(e)).map((r, i, all) =>
                r.op === 'removed' ? (
                  <Fragment key={i}><del>{r.text}</del>{all[i + 1]?.op === 'added' ? ' ' : ''}</Fragment>
                ) : r.op === 'added' ? <ins key={i}>{r.text}</ins> : <Fragment key={i}>{r.text}</Fragment>,
              )}
            </div>
          </div>
        ) : (
          <Read text={text} />
        )}

        {/* one line for what happened (copied, not polished, not typed) — or, in Changes, what the marks mean: the
            same slot, so the actions under it never jump between the views */}
        {!isEditing && !failed && (line || (diff && mode === 'compare')) && (
          <p className={`dict-line ${x ? 'out' : ''}`}>
            {x && <Icon name={x === 'copied' ? 'copy' : 'info'} size={13} />}
            <span>{diff && mode === 'compare' && !line ? t('dictation_page.changes.key') : line}</span>
          </p>
        )}

        {!isEditing && (
          <div className="dict-acts dict-main-acts">
            {failed ? (
              e.reason === 'asr_failed:model_missing' ? (
                <button className="primary" onClick={onSettings}>{t('dictation_page.banner.choose')}</button>
              ) : data?.can_retry && e.audio_path ? (
                <button className="primary" disabled={retrying.has(e.id)} title={t('dictation_page.retry.tip')} onClick={() => retry(e)}>
                  {retrying.has(e.id) ? t('dictation_page.retrying') : t('dictation_page.retry')}
                </button>
              ) : null
            ) : e.item && e.item_uid ? (
              <button onClick={() => onShowItem(e.item_uid!)}>{t('dictation_page.show_item', { id: e.item })}</button>
            ) : (
              // the same width while it works: the spinner in the button, the label says what it does
              <button className={`primary ${busy ? 'busy' : ''}`} disabled={busy} title={t('dictation_page.make_item.tip')} onClick={() => makeItem(e)}>
                {busy && <span className="mw-spinner" aria-hidden="true" />}
                {busy ? t('dictation_page.making_item') : t('dictation_page.make_item')}
              </button>
            )}
            {!failed && (
              <>
                <button className="icon-btn dict-ghost" title={t('dictation_page.correct.tip')} aria-label={t('dictation_page.correct')} onClick={() => beginEdit(e)}>
                  <Icon name="pencil" size={15} />
                </button>
                <button className={`icon-btn dict-ghost ${copied === 'detail' ? 'ok' : ''}`} title={copied === 'detail' ? t('dictation_page.copied') : t('dictation_page.copy')} aria-label={t('dictation_page.copy')}
                  onClick={() => copy(text, 'detail')}>
                  <Icon name={copied === 'detail' ? 'check' : 'copy'} size={15} />
                </button>
              </>
            )}
            <button className="icon-btn dict-ghost" aria-label={t('dictation_page.more')} title={t('dictation_page.more')}
              onClick={(ev) => { const r = ev.currentTarget.getBoundingClientRect(); setMenu({ x: r.left, y: r.bottom + 4, ids: [e.id], detail: true }); }}>
              <Icon name="more" size={15} />
            </button>
          </div>
        )}

        {!isEditing && (
          <dl className="dict-info" aria-label={t('dictation_page.details')}>
            {e.asr_model && (
              <>
                <dt>{t('dictation_page.info.asr')}</dt>
                <dd>
                  {modelName(e.asr_model)}
                  {asrGone && <span className="dim"> · {t('dictation_page.info.gone')} </span>}
                  {asrGone && <button className="link" onClick={onSettings}>{t('dictation_page.info.choose')}</button>}
                </dd>
              </>
            )}
            {polishInfo && <><dt>{t('dictation_page.info.polish')}</dt><dd>{polishInfo}</dd></>}
            {styleName && <><dt>{t('dictation_page.info.style')}</dt><dd>{styleName}</dd></>}
            {language && <><dt>{t('dictation_page.info.language')}</dt><dd>{language}</dd></>}
            {!!e.terms_applied?.length && <><dt>{t('dictation_page.info.terms')}</dt><dd>{i18n().formatList(e.terms_applied)}</dd></>}
            {e.context_used === true && <><dt>{t('dictation_page.info.context')}</dt><dd>{t('dictation_page.info.context.value')}</dd></>}
          </dl>
        )}
      </div>
    );
  }

  if (tab === 'words') return <DictationWords header={header} onToast={onToast} onCount={setWordsN} />;
  const menuEntries = menu ? entries.filter((e) => menu.ids.includes(e.id)) : [];
  // nothing dictated yet: the list column stands alone; a search that found nothing keeps both columns (the field
  // doesn't stretch across the window, nothing jumps)
  const solo = !!data && !entries.length;
  return (
    <div className={`dict-split ${solo ? 'solo' : ''}`} data-testid="dictation">
      {list}
      {!solo && <aside className="detail dict-detail">{detail}</aside>}
      {menu && menuEntries.length > 0 && (
        <Menu at={menu} onClose={() => setMenu(null)}>{entryMenu(menuEntries, !menu.detail)}</Menu>
      )}
      {confirmClear && (
        <div className="overlay" onClick={() => setConfirmClear(false)}>
          <div className="sheet dict-confirm" role="alertdialog" aria-modal="true" onClick={(e) => e.stopPropagation()}
            onKeyDown={(e) => e.key === 'Escape' && setConfirmClear(false)}>
            <h3>{t('dictation_page.clear.title')}</h3>
            <p>{t('dictation_page.clear.body', { n: entries.length })}</p>
            <div className="dict-confirm-foot">
              <button autoFocus className="dict-confirm-cancel" onClick={() => setConfirmClear(false)}>{t('dictation_page.clear.cancel')}</button>
              <button className="dict-danger-tint" onClick={clearAll}>{t('dictation_page.clear.confirm')}</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

/** The query as typed, trimmed; past 16 characters its start and end around an ellipsis. */
function shortQuery(q: string): string {
  const s = q.trim();
  return s.length > 16 ? `${s.slice(0, 8)}…${s.slice(-7)}` : s;
}

/** A keys line ("↑↓ Move    Ctrl+C Copy    Del Delete"): each key as a small keycap, then its label, the pairs well apart. */
function Keys({ text }: { text: string }) {
  return (
    <span className="dict-keys">
      {text.split(/\s{2,}/).map((pair, i) => {
        const at = pair.indexOf(' ');
        return (
          <span key={i} className="dict-kp">
            <kbd>{at > 0 ? pair.slice(0, at) : pair}</kbd>
            {at > 0 ? pair.slice(at + 1) : ''}
          </span>
        );
      })}
    </span>
  );
}
