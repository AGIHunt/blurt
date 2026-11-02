// Every setting the Settings page shows, as data — the Mac's BlurtCore/SettingsCatalog.swift for the rows that exist
// on Windows (docs/design/windows-parity/settings.md says which don't and why): the panes in the sidebar's groups,
// each pane's sections, one entry per row (its id, title and one-line description as string keys, a longer
// explanation, search keywords st.settings.kw.<id>). The panes render their rows from these entries, and the search
// runs over the same entries, so what search finds is what the page shows.
//
// Search (the Mac's rule, unchanged): every word of the query has to appear in an entry's title, description,
// keywords or section — in the UI language or the other one — scored title first; plain substring matching. Results
// come in groups, one per pane, best group first (ties: the sidebar's order), each by section. A query that is (the
// start of) a pane's name finds the pane as a whole; when no row matches by its own words, a pane whose keywords hold
// every word ("hotkey") does. Actions (Restore Defaults) are found by their own words only.
import { CATALOGS } from '../i18n';
import type { IconName } from '@blurt/icons';

export type Lang = 'en' | 'zh-Hans';
/** a string key in the settings catalogs (without the "st." prefix) */
export type Key = string;

export interface PaneInfo {
  id: PaneId;
  title: Key;
  icon: IconName;
  group: 'preferences' | 'work' | 'mac';
}
export type PaneId = 'general' | 'dictation' | 'screentext' | 'speech' | 'shortcuts' | 'projects' | 'agents' | 'privacy' | 'storage';

export interface Entry {
  id: string;
  kind: 'row' | 'section';
  section: string | null;
  title: Key;
  detail?: Key;
  more?: Key;
}

export const GROUPS: { id: PaneInfo['group']; title: Key }[] = [
  { id: 'preferences', title: 'settings.group.preferences' },
  { id: 'work', title: 'settings.group.work' },
  { id: 'mac', title: 'settings.group.mac' },
];

export const PANES: PaneInfo[] = [
  { id: 'general', title: 'settings.kit.general', icon: 'settings', group: 'preferences' },
  { id: 'dictation', title: 'dictation.settings.tab', icon: 'character-cursor', group: 'preferences' },
  { id: 'screentext', title: 'settings.kit.screen_text', icon: 'text-viewfinder', group: 'preferences' },
  { id: 'speech', title: 'settings.kit.speech', icon: 'cpu', group: 'preferences' },
  { id: 'shortcuts', title: 'settings.kit.shortcuts', icon: 'keyboard', group: 'preferences' },
  { id: 'projects', title: 'main.sidebar.projects', icon: 'folder', group: 'work' },
  { id: 'agents', title: 'settings.kit.agents', icon: 'terminal', group: 'work' },
  { id: 'privacy', title: 'settings.kit.privacy', icon: 'hand', group: 'mac' },
  { id: 'storage', title: 'settings.kit.storage', icon: 'drive', group: 'mac' },
];
export const pane = (id: string) => PANES.find((p) => p.id === id);

/** Old links (blurt://settings/<pane>, a remembered last pane) and where they land now. */
export const MOVED: Record<string, string> = { export: 'agents', cloud: 'speech', 'speech.cloud': 'speech' };
/** a link to Export's old place lands at Ask your agent (SettingsCatalog.moved: export → agents/agents.ask) */
export const MOVED_ROW: Record<string, string> = { export: 'agents.ask' };

export const SECTIONS: Record<string, Key> = {
  'general.app': 'settings.general.app',
  'general.recording': 'settings.general.recording',
  'general.voice': 'settings.general.section.voice',
  'general.cards': 'settings.general.section.cards',
  'general.about': 'settings.general.about',
  'projects.list': 'main.sidebar.projects',
  'projects.capture': 'settings.projects.capture_heading',
  'dictation.main': 'dictation.settings.section',
  'dictation.text': 'dictation.text.section',
  'dictation.translation': 'dictation.translate.section',
  'dictation.data': 'dictation.data.section',
  'screentext.copy': 'settings.screen_text.section.copy',
  'screentext.translation': 'settings.screen_text.section.translate',
  'speech.services': 'models.section.services',
  'speech.jobs': 'speech.section.jobs',
  'speech.models': 'speech.section.models',
  'shortcuts.capture': 'capture.keys.section.capture',
  'shortcuts.recording': 'capture.keys.while_recording',
  'shortcuts.dictation': 'dictation.settings.tab',
  'shortcuts.open': 'capture.keys.section.open',
  'agents.list': 'agents.header',
  'agents.organize': 'agents.organize.header',
  'agents.sessions': 'agents.sessions.header',
  'agents.manual': 'agents.manual.header',
  'agents.ask': 'agents.ask.header',
  'privacy.permissions': 'settings.privacy.permissions_live',
  'storage.recordings': 'settings.storage.recordings',
  'storage.models': 'settings.storage.models',
  'storage.files': 'settings.storage.app_data',
};

/** The Shortcuts page's sections and their actions (hotkeys.rs ACTIONS), in the page's order. The dictation key (set
 * in Settings → Dictation) leads its section. The pen only latches on / off (no hold-to-draw key: recording.md §4.6),
 * and the tray menu can't be opened from a key: "menu" opens the window (the Mac's "main"). */
export const SHORTCUT_SECTIONS: { section: string; actions: string[] }[] = [
  { section: 'shortcuts.capture', actions: ['record', 'snap', 'text', 'translate', 'voice'] },
  { section: 'shortcuts.recording', actions: ['pause', 'pen', 'stop'] },
  { section: 'shortcuts.dictation', actions: ['reformat'] },
  { section: 'shortcuts.open', actions: ['project', 'cards', 'menu'] },
];
/** The action's name on the page (the Mac's capture.action.<name>): Windows' "menu" is the Mac's "main". */
export const shortcutTitle = (a: string): Key => `capture.action.${a === 'menu' ? 'main' : a}`;
export const DESCRIBED_SHORTCUTS = new Set(['cards', 'reformat', 'text', 'translate']);

const row = (id: string, section: string | null, title: Key, o: { detail?: Key; more?: Key } = {}): Entry => ({ id, kind: 'row', section, title, ...o });
const whole = (id: string, detail?: Key): Entry => ({ id, kind: 'section', section: id, title: SECTIONS[id] ?? id, detail });

export const ENTRIES: Entry[] = (() => {
  const e: Entry[] = [
    // General
    row('general.login', 'general.app', 'settings.general.login', { detail: 'settings.general.login.detail' }),
    row('general.language', 'general.app', 'settings.general.language'),
    // Windows' own notifications (Blurt posts them while it isn't in front; the Mac says it in the island instead)
    row('general.notify_done', 'general.app', 'settings.notify.done', { more: 'win.general.notify.hint' }),
    row('general.notify_agent', 'general.app', 'settings.notify.agent', { more: 'win.general.notify.hint' }),
    row('general.after_recording', 'general.recording', 'settings.general.after_recording'),
    row('general.countdown', 'general.recording', 'app.menu.countdown'),
    row('general.system_audio', 'general.recording', 'settings.general.system_audio'),
    row('general.voice_end_on_pause', 'general.voice', 'settings.general.voice_end_on_pause', { more: 'settings.general.voice_end_on_pause.hint' }),
    row('general.live_text', 'general.voice', 'settings.general.live_text', { more: 'settings.general.live_text.hint' }),
    row('general.collect', 'general.cards', 'settings.general.collect', { more: 'settings.general.collect.hint' }),
    row('general.snap_sound', 'general.cards', 'settings.general.snap_sound'),
    row('general.card_drag', 'general.cards', 'settings.general.card_drag', { more: 'settings.general.card_drag.hint' }),
    row('general.drag_note_file', 'general.cards', 'settings.general.drag_note_file', { more: 'settings.general.drag_note_file.hint' }),
    whole('general.about'),
    // Projects
    row('projects.capture_into', 'projects.capture', 'settings.projects.capture_row'),
    whole('projects.list', 'settings.general.projects.hint'),
    // Dictation
    row('dictation.enable', 'dictation.main', 'dictation.settings.enable', { detail: 'dictation.settings.enable.detail' }),
    row('dictation.key', 'dictation.main', 'dictation.settings.key'),
    row('dictation.mode', 'dictation.main', 'dictation.settings.mode'),
    row('dictation.cancel_key', 'dictation.main', 'dictation.settings.cancel_key', { detail: 'dictation.settings.cancel_key.detail' }),
    row('dictation.double_tap', 'dictation.main', 'dictation.settings.double_tap', { detail: 'dictation.settings.double_tap.detail' }),
    row('dictation.modifier_tap', 'dictation.main', 'dictation.settings.modifier_tap', { detail: 'dictation.settings.modifier_tap.detail' }),
    row('dictation.mic', 'dictation.main', 'dictation.mic.section'),
    row('dictation.only_my_voice', 'dictation.main', 'dictation.only_my_voice', { detail: 'dictation.only_my_voice.detail' }),
    row('dictation.sounds', 'dictation.main', 'dictation.sounds'),
    row('dictation.stop_sound', 'dictation.main', 'dictation.stop_sound'),
    row('dictation.default_style', 'dictation.text', 'dictation.style.default'),
    row('dictation.by_app', 'dictation.text', 'dictation.style.by_app', { detail: 'dictation.style.by_app.detail' }),
    ...['chat', 'code', 'mail', 'notes', 'other'].map((c) => row(`dictation.cat.${c}`, 'dictation.text', `dictation.style.cat.${c}`, { detail: `dictation.style.cat.${c}.detail` })),
    row('dictation.suggest_lists', 'dictation.text', 'dictation.style.suggest'),
    row('dictation.learn_styles', 'dictation.text', 'dictation.style.learn_toggle', { detail: 'dictation.style.learn_toggle.detail' }),
    row('dictation.polish_timeout', 'dictation.text', 'dictation.polish.timeout'),
    row('dictation.word_list', 'dictation.text', 'dictation.vocab.summary.title', { detail: 'dictation.vocab.summary.detail' }),
    row('dictation.context', 'dictation.text', 'dictation.vocab.context', { detail: 'dictation.vocab.context.detail' }),
    row('dictation.learn', 'dictation.text', 'dictation.vocab.learn', { detail: 'dictation.vocab.learn.detail' }),
    row('dictation.translate', 'dictation.translation', 'dictation.translate.settings.title', { detail: 'dictation.translate.settings.detail' }),
    row('dictation.translate_model', 'dictation.translation', 'models.uses.translate'),
    row('dictation.history_saved', 'dictation.data', 'dictation.history.saved', { detail: 'dictation.history.saved.detail' }),
    row('dictation.keep_audio', 'dictation.data', 'dictation.history.keep_audio', { detail: 'dictation.history.keep_audio.detail' }),
    row('dictation.models', 'dictation.data', 'dictation.models.section', { detail: 'dictation.models.detail' }),
    // Copy Text from Screen
    row('screentext.precise', 'screentext.copy', 'screentext.precise', { detail: 'screentext.precise.detail' }),
    row('screentext.translate', 'screentext.translation', 'settings.screen_text.translate', { more: 'settings.screen_text.translate.hint' }),
    row('screentext.translate_model', 'screentext.translation', 'models.uses.translate'),
    // Models
    whole('speech.services', 'models.services.detail'),
    row('speech.batch', 'speech.jobs', 'speech.purpose.batch', { detail: 'speech.purpose.batch.detail' }),
    row('speech.note', 'speech.jobs', 'speech.purpose.note', { detail: 'speech.purpose.note.detail' }),
    row('speech.dictation', 'speech.jobs', 'speech.purpose.dictation', { detail: 'speech.purpose.dictation.detail' }),
    row('speech.polish', 'speech.jobs', 'speech.purpose.polish', { detail: 'speech.purpose.polish.detail' }),
    row('speech.translate', 'speech.jobs', 'models.job.translate', { detail: 'models.job.translate.detail' }),
    row('speech.vision', 'speech.jobs', 'models.job.vision', { detail: 'models.job.vision.detail' }),
    whole('speech.models', 'speech.models.footer'),
  ];
  for (const s of SHORTCUT_SECTIONS) {
    if (s.section === 'shortcuts.dictation') e.push(row('shortcuts.dictation_key', s.section, 'capture.keys.dictation_key'));
    for (const a of s.actions) {
      e.push(row(`shortcuts.${a}`, s.section, shortcutTitle(a), {
        detail: DESCRIBED_SHORTCUTS.has(a) ? `capture.action.${a}.detail` : undefined,
        // Windows' pen is latched only: how it draws, where the Mac's row names its hold key
        more: a === 'pen' ? 'win.capture.action.pen.help' : undefined,
      }));
    }
  }
  e.push(
    row('shortcuts.restore', null, 'capture.keys.restore'),
    // Agents
    whole('agents.list', 'agents.lead'),
    whole('agents.organize', 'agents.organize.footer'),
    whole('agents.sessions', 'agents.sessions.about'),
    row('agents.keep_sessions', 'agents.sessions', 'agents.keep_sessions', { more: 'agents.keep_sessions.ok' }),
    row('agents.project_agent', 'agents.sessions', 'agents.project_agent', { detail: 'agents.project_agent.hint' }),
    row('agents.handoff', 'agents.sessions', 'agents.handoff_target', { more: 'agents.handoff_target.hint' }),
    whole('agents.manual', 'agents.manual.footer'),
    whole('agents.ask', 'agents.ask.footer'),
    // Privacy
    whole('privacy.permissions'),
    row('privacy.mic', 'privacy.permissions', 'settings.perm.microphone', { detail: 'win.privacy.mic.detail' }),
    // Storage
    whole('storage.recordings'),
    row('storage.auto_delete', 'storage.recordings', 'settings.storage.videos.auto', { detail: 'settings.storage.videos.footer' }),
    whole('storage.models', 'settings.storage.model.footer'),
    whole('storage.files'),
  );
  return e;
})();

/** Rows that are a button rather than a setting: found by their own words only, never listed with their pane. */
export const ACTIONS = new Set(['shortcuts.restore']);
export const entry = (id: string) => ENTRIES.find((e) => e.id === id);
export const paneOf = (id: string) => id.split('.')[0] as PaneId;

// ------------------------------------------------------------------ text

type Catalog = Record<string, string>;
const cat = (lang: Lang) => CATALOGS[lang] as Catalog;

/** Arguments for a title with placeholders (the hotkey in "Alt+Shift+T translates into"), by key — set by the page;
 * without them a placeholder reads "…". */
let args: (key: Key) => Record<string, string> | undefined = () => undefined;
export const setArguments = (f: typeof args) => (args = f);

/** A key's text in a language (the settings catalog's "st." key, else the main window's own); undefined when missing. */
export function textIn(key: Key | undefined, lang: Lang): string | undefined {
  if (!key) return undefined;
  const s = cat(lang)[`st.${key}`] ?? (cat(lang) as Catalog)[key];
  const a = args(key);
  return s?.replace(/\{(\w+)\}/g, (_, n: string) => a?.[n] ?? '…');
}
const kwKey = (e: Entry) => `settings.kw.${e.id}`;
const paneKw = (p: PaneInfo) => `settings.kw.pane.${p.id}`;

/** Case, accents and full / half width don't matter. */
export const fold = (s: string) => s.normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase();
export const words = (q: string) => q.split(/\s+/).map(fold).filter(Boolean);

interface Field { text: string; title: boolean; pane: boolean; weight: number }

function fields(e: Entry, here: Lang, other: Lang): Field[] {
  const out: Field[] = [];
  const action = ACTIONS.has(e.id);
  const add = (k: Key | undefined, lang: Lang, w: number, o: { title?: boolean; pane?: boolean } = {}) => {
    if (!k || (action && (k === e.detail || k === e.more))) return;
    const s = textIn(k, lang);
    if (s) out.push({ text: fold(s), title: !!o.title, pane: !!o.pane, weight: w });
  };
  const p = pane(paneOf(e.id))!;
  const sec = e.section ? SECTIONS[e.section] : undefined;
  add(e.title, here, 100, { title: true });
  add(kwKey(e), here, 45);
  add(e.title, other, 40);
  add(kwKey(e), other, 35);
  add(sec, here, 30);
  add(p.title, here, 20, { pane: true });
  add(paneKw(p), here, 20, { pane: true });
  add(e.detail, here, 20);
  add(e.more, here, 15);
  add(sec, other, 12);
  add(p.title, other, 10, { pane: true });
  add(paneKw(p), other, 10, { pane: true });
  add(e.detail, other, 8);
  return out;
}

const isLatin = (s: string) => /^[\x00-\x7f]*$/.test(s);
const isLetter = (c: string) => /\p{L}/u.test(c);

/** A field's best match for one word: a title scores by where the word sits (its start, a word's start, anywhere);
 * elsewhere a Latin word has to start a word ("voice" isn't found in "SenseVoice"); Chinese matches anywhere. */
function score(term: string, fs: Field[]): number {
  let best = 0;
  const latin = isLatin(term);
  for (const f of fs) {
    let from = 0;
    for (;;) {
      const i = f.text.indexOf(term, from);
      if (i < 0) break;
      const atStart = i === 0;
      const atWord = atStart || !isLetter(f.text[i - 1]);
      let s = 0;
      if (f.title) s = atStart ? 100 : atWord ? 80 : 60;
      else if (atWord || !latin) s = f.weight;
      best = Math.max(best, s);
      if (s > 0 && (atWord || !f.title)) break;
      from = i + term.length;
    }
  }
  return best;
}

export interface Hit { entry: Entry; score: number }
export interface ResultGroup { pane: PaneId; paneHit: boolean; hits: Hit[]; score: number }

function bySection(hits: Hit[]): Hit[] {
  const keys: string[] = [];
  const runs = new Map<string, Hit[]>();
  for (const h of hits) {
    const k = h.entry.section ?? '';
    if (!runs.has(k)) {
      keys.push(k);
      runs.set(k, []);
    }
    runs.get(k)!.push(h);
  }
  const ordered = [...keys.filter((k) => k), ...keys.filter((k) => !k)];
  return ordered.flatMap((k) => {
    const r = runs.get(k) ?? [];
    return [...r.filter((h) => h.entry.kind === 'section'), ...r.filter((h) => h.entry.kind !== 'section')];
  });
}

/** The results by pane, best group first; ties keep the sidebar's order. */
export function results(query: string, here: Lang, shown: (e: Entry) => boolean = () => true): ResultGroup[] {
  const terms = words(query);
  if (!terms.length) return [];
  const other: Lang = here === 'en' ? 'zh-Hans' : 'en';
  const entries = ENTRIES.filter(shown);
  const all = entries.map((e) => fields(e, here, other));
  const pass = (paneLevel: boolean): Hit[] => {
    const hits: [Hit, number][] = [];
    entries.forEach((e, n) => {
      const f = paneLevel ? all[n] : all[n].filter((x) => !x.pane);
      let total = 0;
      for (const t of terms) {
        const s = score(t, f);
        if (!s) return;
        total += s;
      }
      hits.push([{ entry: e, score: total }, n]);
    });
    return hits.sort((a, b) => (a[0].score !== b[0].score ? b[0].score - a[0].score : a[1] - b[1])).map((h) => h[0]);
  };
  const q = fold(query.trim());
  const longEnough = q.length >= (isLatin(q) ? 2 : 1);
  const whole = new Set<PaneId>(
    longEnough ? PANES.filter((p) => [here, other].some((l) => fold(textIn(p.title, l) ?? '').startsWith(q))).map((p) => p.id) : [],
  );
  let own = pass(false);
  if (!own.length && !whole.size) {
    for (const p of PANES) {
      const pf: Field[] = [textIn(p.title, here), textIn(paneKw(p), here), textIn(p.title, other), textIn(paneKw(p), other)]
        .filter((s): s is string => !!s)
        .map((s) => ({ text: fold(s), title: false, pane: true, weight: 10 }));
      if (terms.every((t) => score(t, pf) > 0)) whole.add(p.id);
    }
    if (!whole.size) own = pass(true);
  }
  const groups: ResultGroup[] = [];
  const lead = 100_000;
  const found = new Set(own.map((h) => h.entry.id));
  for (const p of PANES) {
    if (!whole.has(p.id)) continue;
    const rows = entries.filter((e) => paneOf(e.id) === p.id && (!ACTIONS.has(e.id) || found.has(e.id))).map((e) => ({ entry: e, score: lead }));
    groups.push({ pane: p.id, paneHit: true, hits: bySection(rows), score: lead });
  }
  for (const p of PANES) {
    if (whole.has(p.id)) continue;
    const rows = own.filter((h) => paneOf(h.entry.id) === p.id);
    if (!rows.length) continue;
    groups.push({ pane: p.id, paneHit: false, hits: bySection(rows), score: rows[0].score });
  }
  const order = new Map(PANES.map((p, i) => [p.id, i]));
  return groups.sort((a, b) => (a.score !== b.score ? b.score - a.score : order.get(a.pane)! - order.get(b.pane)!));
}

/** The sentence of a text that holds the most of `terms`, without its parentheses. */
function excerpt(texts: string[], terms: string[]): string | undefined {
  const hits = (t: string) => terms.filter((x) => fold(t).includes(x)).length;
  let best: { t: string; n: number } | undefined;
  for (const t of texts) {
    const n = hits(t);
    if (n > (best?.n ?? 0)) best = { t, n };
    if (n === terms.length) break;
  }
  if (!best) return undefined;
  const sentences = best.t.match(/[^。！？.!?]+(?:[。！？]|[.!?](?=\s|$))?/g)?.map((s) => s.trim()).filter(Boolean) ?? [best.t];
  const most = Math.max(...sentences.map(hits));
  const pick = sentences.find((s) => hits(s) === most) ?? best.t;
  const bare = pick.replace(/\s*[（(][^）)]*[）)]/g, '');
  return bare || pick;
}

const keywordList = (k: Key, lang: Lang) => (textIn(k, lang) ?? '').split(/[,，、]/).map((s) => s.trim()).filter(Boolean);

/** Why an entry was found when its title doesn't say so (always in the UI's language); undefined when the title holds
 * every word. */
export function reason(e: Entry, query: string, here: Lang): string | undefined {
  const missing = words(query).filter((w) => !fold(textIn(e.title, here) ?? '').includes(w));
  if (!missing.length) return undefined;
  const texts = [textIn(e.detail, here), ...keywordList(kwKey(e), here), textIn(e.more, here)].filter((s): s is string => !!s);
  return excerpt(texts, missing) ?? textIn(e.detail, here);
}

/** Why a pane was found as a whole when its name doesn't say so: the keyword that holds the query. */
export function paneReason(id: PaneId, query: string, here: Lang): string | undefined {
  const p = pane(id)!;
  const missing = words(query).filter((w) => !fold(textIn(p.title, here) ?? '').includes(w));
  if (!missing.length) return undefined;
  return excerpt(keywordList(paneKw(p), here), missing);
}

/** The searches the no-match page offers. */
export const SUGGESTIONS: Key[] = ['shortcut', 'model', 'microphone', 'language'].map((s) => `settings.search.try.${s}`);
