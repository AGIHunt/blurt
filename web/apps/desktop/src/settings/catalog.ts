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
import { CAPS } from '../capabilities';

export type Lang = 'en' | 'zh-Hans';
/** a string key in the settings catalogs (without the "st." prefix) */
export type Key = string;

export interface PaneInfo {
  id: PaneId;
  title: Key;
  icon: IconName;
  group: 'features' | 'app' | 'mac';
}
export type PaneId = 'general' | 'dictation' | 'cards' | 'screentext' | 'recording' | 'speech' | 'shortcuts' | 'phone' | 'projects' | 'agents' | 'privacy' | 'storage';

export interface Entry {
  id: string;
  kind: 'row' | 'section';
  section: string | null;
  title: Key;
  detail?: Key;
  more?: Key;
}

/** The sidebar's groups (v1.0.23, the Mac's SettingsCatalog.groups): Features — one pane per capability, named as the
 *  capability is everywhere, each there only while it is on (capabilities.ts `paneShown`) · App — what every feature
 *  shares · This PC. Before: Preferences / Work / This PC, with the recording, voice-note and card settings in General. */
export const GROUPS: { id: PaneInfo['group']; title: Key }[] = [
  { id: 'features', title: 'settings.group.features' },
  { id: 'app', title: 'settings.group.app' },
  { id: 'mac', title: 'settings.group.mac' },
];

export const PANES: PaneInfo[] = [
  { id: 'dictation', title: 'feature.dictation', icon: 'character-cursor', group: 'features' },
  // snaps, voice notes and what a dragged card carries (v1.0.23: before, two boxes in General)
  { id: 'cards', title: 'feature.cards', icon: 'cards', group: 'features' },
  { id: 'screentext', title: 'feature.screen_text', icon: 'text-viewfinder', group: 'features' },
  // a recording and what becomes of it (v1.0.23: before, a box in General); its projects follow
  { id: 'recording', title: 'feature.recording', icon: 'record', group: 'features' },
  { id: 'projects', title: 'main.sidebar.projects', icon: 'folder', group: 'features' },
  // the Mac's iPhone pane ("remote"): the feature's options (PhonePane.tsx); its name is the feature's, feature.phone, as the
  // page's, Home's row and the sidebar's: renaming the feature is that one string
  { id: 'phone', title: 'feature.phone', icon: 'devices', group: 'features' },
  { id: 'general', title: 'settings.kit.general', icon: 'settings', group: 'app' },
  { id: 'speech', title: 'settings.kit.speech', icon: 'cube', group: 'app' },
  { id: 'shortcuts', title: 'settings.kit.shortcuts', icon: 'keyboard', group: 'app' },
  { id: 'agents', title: 'settings.kit.agents', icon: 'terminal', group: 'app' },
  { id: 'privacy', title: 'settings.kit.privacy', icon: 'hand', group: 'mac' },
  { id: 'storage', title: 'settings.kit.storage', icon: 'drive', group: 'mac' },
];
export const pane = (id: string) => PANES.find((p) => p.id === id);

/** Old links (blurt://settings/<pane>, a remembered last pane) and where they land now. */
export const MOVED: Record<string, string> = { export: 'agents', cloud: 'speech', 'speech.cloud': 'speech', remote: 'phone' };
/** Rows that moved (old row → new row): Export's old place lands at Ask your agent; v1.0.23 moved General's Voice notes
 *  and Cards boxes to the Cards pane and its Recording box to Recording & Items (the Mac's SettingsCatalog.movedRows). */
export const MOVED_ROW: Record<string, string> = {
  export: 'agents.ask',
  'general.collect': 'cards.collect', 'general.snap_sound': 'cards.snap_sound', 'general.voice_end_on_pause': 'cards.voice_end_on_pause',
  'general.card_drag': 'cards.card_drag', 'general.agent_drag': 'cards.agent_drag', 'general.drag_note_file': 'cards.drag_note_file',
  'general.cards': 'cards.snaps', 'general.voice': 'cards.voice',
  'general.after_recording': 'recording.after_recording', 'general.countdown': 'recording.countdown',
  'general.system_audio': 'recording.system_audio', 'general.recording': 'recording.capture',
  // the device lists moved to the Remote Control page; their old rows land on the row that goes there
  'phone.add': 'phone.devices', 'phone.computers.add': 'phone.devices',
};
/** "general/general.collect" (or "general/collect") → "cards/cards.collect"; a moved pane → its new place; else as it is. */
export function redirect(link: string): string {
  const [p, rest] = link.split('/');
  if (MOVED[p] && !rest) return MOVED[p];
  if (!rest) return link;
  const row = rest.includes('.') ? rest : `${p}.${rest}`;
  const to = MOVED_ROW[row];
  return to ? `${to.split('.')[0]}/${to}` : link;
}

export const SECTIONS: Record<string, Key> = {
  // General: the five capabilities' switches, then the app's own choices
  'general.features': 'settings.general.features',
  'general.app': 'settings.general.app',
  'general.about': 'settings.general.about',
  // Cards, in the order a card is made and used: taking a snap, the voice note, dragging the card out
  'cards.snaps': 'settings.cards.section.snaps',
  'cards.voice': 'settings.general.section.voice',
  'cards.drag': 'settings.cards.section.drag',
  // Recording & Items: the recording itself, then what becomes of it
  'recording.capture': 'settings.general.recording',
  'recording.items': 'settings.recording.section.items',
  'projects.list': 'main.sidebar.projects',
  'projects.capture': 'settings.projects.capture_heading',
  'dictation.main': 'dictation.settings.section',
  'dictation.text': 'dictation.text.section',
  'dictation.translation': 'dictation.translate.section',
  'dictation.data': 'dictation.data.section',
  'screentext.copy': 'settings.screen_text.section.copy',
  'screentext.translation': 'settings.screen_text.section.translate',
  'screentext.history_section': 'settings.screen_text.section.history',
  'speech.services': 'models.section.services',
  'speech.jobs': 'speech.section.jobs',
  'speech.models': 'speech.section.models',
  'shortcuts.capture': 'capture.keys.section.capture',
  'shortcuts.recording': 'capture.keys.while_recording',
  'shortcuts.dictation': 'dictation.settings.tab',
  'shortcuts.open': 'capture.keys.section.open',
  'phone.options': 'phone.section.options',
  'phone.relay': 'phone.section.relay',
  'agents.use': 'agents.use.header',
  'agents.list': 'agents.organize.header',
  'agents.organize': 'agents.organize.header',
  'agents.drop': 'agents.drop.header',
  'agents.ask': 'agents.ask.header',
  'privacy.permissions': 'settings.privacy.permissions_live',
  'storage.location': 'win.storage.location.section',
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
    // General: the capabilities' switches (found by "features", "功能"; each by its capability's name and "turn off"),
    // then the app's own rows
    whole('general.features', 'settings.general.features.footer'),
    ...CAPS.map((c) => row(`general.feature.${c}`, 'general.features', `feature.${c}`, { detail: `feature.${c}.what` })),
    row('general.login', 'general.app', 'settings.general.login', { detail: 'settings.general.login.detail' }),
    // the Mac's "Show the notch when idle" (app.island_idle); off by default here (island.rs shows_at_rest)
    row('general.island_idle', 'general.app', 'settings.general.island_idle', { detail: 'settings.general.island_idle.detail' }),
    // dictation's and the voice note's alike (record.live_text): the app's, not one capability's
    row('general.live_text', 'general.app', 'settings.general.live_text', { detail: 'settings.general.live_text.detail', more: 'settings.general.live_text.hint' }),
    // Windows' own notifications (Blurt posts them while it isn't in front; the Mac says it in the island instead)
    row('general.notify_done', 'general.app', 'settings.notify.done', { more: 'win.general.notify.hint' }),
    row('general.language', 'general.app', 'settings.general.language'),
    whole('general.about'),
    // Cards (the strings keep their settings.general.* keys from when these rows were in General)
    row('cards.collect', 'cards.snaps', 'settings.general.collect', { more: 'settings.general.collect.hint' }),
    row('cards.snap_sound', 'cards.snaps', 'settings.general.snap_sound'),
    row('cards.voice_end_on_pause', 'cards.voice', 'settings.general.voice_end_on_pause', { more: 'settings.general.voice_end_on_pause.hint' }),
    row('cards.card_drag', 'cards.drag', 'settings.general.card_drag', { more: 'settings.general.card_drag.hint' }),
    // what an agent app gets (card_drop.rs AGENTS + the user's list): the picture's path and the note, as a terminal
    row('cards.agent_drag', 'cards.drag', 'settings.general.agent_drag', { more: 'settings.general.agent_drag.hint' }),
    row('cards.drag_note_file', 'cards.drag', 'settings.general.drag_note_file', { more: 'settings.general.drag_note_file.hint' }),
    // Recording & Items
    row('recording.countdown', 'recording.capture', 'app.menu.countdown'),
    row('recording.system_audio', 'recording.capture', 'settings.general.system_audio'),
    row('recording.after_recording', 'recording.items', 'settings.general.after_recording'),
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
    // Text & Translation
    row('screentext.allow', 'screentext.copy', 'screentext.allow', { detail: 'screentext.allow.detail' }),
    row('screentext.precise', 'screentext.copy', 'screentext.precise', { detail: 'screentext.precise.detail' }),
    row('screentext.translate', 'screentext.translation', 'settings.screen_text.translate', { more: 'settings.screen_text.translate.hint' }),
    row('screentext.translate_model', 'screentext.translation', 'models.uses.translate'),
    // how long the history keeps what was read (record.screen_text.history_days) in a popup in sight; then what is
    // kept, Open History…, Clear History…
    row('screentext.history_keep', 'screentext.history_section', 'settings.screen_text.history.keep'),
    row('screentext.history', 'screentext.history_section', 'settings.screen_text.history', { detail: 'settings.screen_text.history.detail' }),
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
    // Phone
    // the devices are on the Remote Control page: this row goes there
    row('phone.devices', null, 'phone.devices.show'),
    row('phone.service', 'phone.options', 'phone.service', { detail: 'phone.service.detail' }),
    row('phone.stay_awake', 'phone.options', 'phone.stay_awake', { detail: 'phone.stay_awake.desktop' }),
    row('phone.screen', 'phone.options', 'phone.screen', { detail: 'phone.screen.detail' }),
    row('phone.relay.address', 'phone.relay', 'phone.relay', { detail: 'phone.relay.detail' }),
    row('phone.go_between', 'phone.relay', 'phone.go_between', { detail: 'phone.go_between.detail' }),
    row('phone.relay.help', 'phone.relay', 'phone.relay.help', { detail: 'phone.relay.help.detail' }),
    // Agents
    whole('agents.use', 'agents.use.footer'),
    whole('agents.list', 'agents.lead'),
    whole('agents.organize', 'agents.organize.footer'),
    whole('agents.drop', 'settings.general.agent_apps.note'),
    whole('agents.ask', 'agents.ask.footer'),
    // Privacy
    whole('privacy.permissions'),
    row('privacy.mic', 'privacy.permissions', 'settings.perm.microphone', { detail: 'win.privacy.mic.detail' }),
    // Storage
    row('storage.location', 'storage.location', 'win.storage.location', { detail: 'win.storage.location.detail' }),
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
/** The desktop the app runs on: on Linux a string's `.linux` variant wins (the system keyring, not Windows' Credential
 *  Manager; GNOME's settings, not Windows'). Set once from app_status (SettingsView). */
let desk = 'win';
export function setDesk(p: string) {
  desk = p;
}
export const onLinux = () => desk === 'gnome';

export function textIn(key: Key | undefined, lang: Lang): string | undefined {
  if (!key) return undefined;
  const c = cat(lang) as Catalog;
  const s = (onLinux() ? c[`st.${key}.linux`] : undefined) ?? c[`st.${key}`] ?? c[key];
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
