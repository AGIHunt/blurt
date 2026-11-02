// The Dictation page's rules, kept apart from the view so they can be tested (the Mac's DictationPage.swift:
// DictationHistoryModel, DictationStats, DictationChanges; BlurtCore's DictationEntry.preview / rowMark).
import type { DictationEntry } from './api';
import { i18n } from './i18n';

/** The text as it stands: the user's correction when there is one, else what was typed. */
export const finalText = (e: DictationEntry) => e.corrected ?? e.text;

/** Polish changed it (so there are two texts to tell apart). */
export const differs = (e: DictationEntry) => e.polished != null && e.text !== e.raw;

/** A take the speech model couldn't recognise. */
export const isFailed = (e: DictationEntry) => !e.text && (e.reason ?? '').startsWith('asr_failed');

/** One paragraph: line breaks and runs of spaces become one space, so every row clamps the same way. */
export const preview = (s: string) => s.split(/\s+/).filter(Boolean).join(' ');

/** How it went in, when it didn't simply go in polished at the cursor: the row's chip, the detail's line. */
export function exception(e: DictationEntry): 'copied_raw' | 'copied' | 'fell_back' | null {
  const copied = e.insert === 'copied';
  if (copied && e.fell_back) return 'copied_raw';
  if (copied) return 'copied';
  if (e.fell_back) return 'fell_back';
  return null;
}

/** Search over the text (as it stands, typed, heard, polished), the app's name and the words used. */
export function matches(e: DictationEntry, q: string, appName: (e: DictationEntry) => string | null): boolean {
  const s = q.trim().toLowerCase();
  if (!s) return true;
  const hay = [finalText(e), e.text, e.raw, e.polished ?? '', appName(e) ?? '', ...(e.terms_applied ?? [])];
  return hay.some((h) => h.toLowerCase().includes(s));
}

/** The search's words, for marking them in the rows. */
export const queryTerms = (q: string) => q.toLowerCase().split(/\s+/).filter(Boolean);

/** `s` cut around the terms: [text, marked][] (case-insensitive). */
export function marked(s: string, terms: string[]): [string, boolean][] {
  if (!terms.length) return [[s, false]];
  const low = s.toLowerCase();
  const on = new Array<boolean>(s.length).fill(false);
  for (const t of terms) {
    for (let i = low.indexOf(t); i >= 0 && t; i = low.indexOf(t, i + t.length)) on.fill(true, i, i + t.length);
  }
  const out: [string, boolean][] = [];
  for (let i = 0; i < s.length; i++) {
    const last = out[out.length - 1];
    if (last && last[1] === on[i]) last[0] += s[i];
    else out.push([s[i], on[i]]);
  }
  return out;
}

const CJK = /[぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]/u;

/** (CJK characters, other words) — a CJK character counts as one word. */
export function units(s: string): [number, number] {
  let cjk = 0;
  let words = 0;
  let inWord = false;
  for (const ch of s) {
    if (CJK.test(ch)) {
      cjk++;
      inWord = false;
      continue;
    }
    const letter = /[\p{L}\p{N}'’]/u.test(ch);
    if (letter && !inWord) words++;
    inWord = letter;
  }
  return [cjk, words];
}

/** Today's numbers: dictations, words, roughly the minutes saved over typing (~40 English words or ~50 Chinese
 *  characters a minute, minus the time spent talking). */
export function stats(entries: DictationEntry[]) {
  let cjk = 0;
  let latin = 0;
  let spoken = 0;
  for (const e of entries) {
    const [c, w] = units(e.text);
    cjk += c;
    latin += w;
    spoken += e.duration || 0;
  }
  return { count: entries.length, words: cjk + latin, savedMinutes: Math.floor(Math.max(0, latin / 40 + cjk / 50 - spoken / 60)) };
}

/** Local calendar day, "2026-11-02". */
export function dayKey(iso: string): string {
  const d = new Date(iso);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/** Newest day first, the rows in the order given. */
export function byDay(entries: DictationEntry[]): { day: string; rows: DictationEntry[] }[] {
  const out: { day: string; rows: DictationEntry[] }[] = [];
  for (const e of entries) {
    const k = dayKey(e.t);
    const last = out[out.length - 1];
    if (last?.day === k) last.rows.push(e);
    else out.push({ day: k, rows: [e] });
  }
  return out;
}

/** The names Windows apps go by (the history keeps the exe's name). */
const APP_NAMES: Record<string, string> = {
  chrome: 'Chrome', msedge: 'Microsoft Edge', firefox: 'Firefox', brave: 'Brave', opera: 'Opera', arc: 'Arc',
  winword: 'Word', excel: 'Excel', powerpnt: 'PowerPoint', outlook: 'Outlook', onenote: 'OneNote', olk: 'Outlook',
  'ms-teams': 'Teams', teams: 'Teams', explorer: 'File Explorer', notepad: 'Notepad', code: 'VS Code', cursor: 'Cursor',
  windowsterminal: 'Windows Terminal', cmd: 'Command Prompt', powershell: 'PowerShell', pwsh: 'PowerShell',
  slack: 'Slack', discord: 'Discord', notion: 'Notion', obsidian: 'Obsidian', wechat: 'WeChat', weixin: 'WeChat',
  feishu: 'Feishu', lark: 'Lark', dingtalk: 'DingTalk', qq: 'QQ', telegram: 'Telegram', whatsapp: 'WhatsApp',
  'blurt-desktop': 'Blurt', blurt: 'Blurt',
};
/** …as a Chinese Windows names them (older takes kept no name of their own) */
const APP_NAMES_ZH: Record<string, string> = {
  explorer: '文件资源管理器', notepad: '记事本', cmd: '命令提示符', windowsterminal: '终端', wechat: '微信', weixin: '微信',
  feishu: '飞书', dingtalk: '钉钉', wxwork: '企业微信', qq: 'QQ',
};

export function appName(e: DictationEntry): string | null {
  // the apps this page knows by name, in the page's language (Notepad in English, 记事本 in Chinese — the name kept at
  // the take is in the language Windows had then); else Windows' own name kept at the take (the exe's FileDescription)
  const raw = (e.app ?? e.bundle ?? '').replace(/\.exe$/i, '').trim();
  const k = raw.toLowerCase();
  const zh = i18n().locale.startsWith('zh');
  const known = k ? ((zh ? APP_NAMES_ZH[k] : undefined) ?? APP_NAMES[k]) : undefined;
  if (known) return known;
  if (typeof e.app_name === 'string' && e.app_name.trim()) return e.app_name.trim();
  if (!raw) return null;
  return raw.charAt(0).toUpperCase() + raw.slice(1);
}

// ---- what polish changed (DictationChanges): the words it left out struck through, the ones it added or respelled
// underlined; punctuation alone is not a change worth marking

export type Run = { op: 'same' | 'removed' | 'added'; text: string };

const TOKEN = /[぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]|[\p{L}\p{N}'’_-]+|\s+|[^\s\p{L}\p{N}]/gu;
const isSpace = (t: string) => /^\s+$/.test(t);
const isPunct = (t: string) => /^[^\p{L}\p{N}]+$/u.test(t);

export function changes(heard: string, typed: string): Run[] {
  const a = (heard.match(TOKEN) ?? []).filter((t) => !isSpace(t));
  const all = typed.match(TOKEN) ?? [];
  const bi = all.map((t, i) => [t, i] as const).filter(([t]) => !isSpace(t));
  const b = bi.map(([t]) => t);
  const n = a.length;
  const m = b.length;
  if (n * m > 400_000) return [{ op: 'same', text: typed }];
  const eq = (x: string, y: string) => x === y || x.toLowerCase() === y.toLowerCase();
  // LCS over the tokens (a word only recased is the same word)
  const L = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--) L[i][j] = eq(a[i], b[j]) ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
  const out: Run[] = [];
  const push = (op: Run['op'], text: string) => {
    const last = out[out.length - 1];
    if (last?.op === op) last.text += text;
    else out.push({ op, text });
  };
  let lastB = -1;
  const emitB = (j: number, op: Run['op']) => {
    const at = bi[j][1];
    for (let k = lastB + 1; k < at; k++) push('same', all[k]);
    push(op === 'added' && isPunct(b[j]) ? 'same' : op, b[j]);
    lastB = at;
  };
  let i = 0;
  let j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && eq(a[i], b[j])) {
      emitB(j, a[i] === b[j] ? 'same' : 'added'); // recased: changed, nothing left out
      i++;
      j++;
    } else if (i < n && (j >= m || L[i + 1][j] >= L[i][j + 1])) {
      // what was left out reads before what took its place, after the space that leads to it
      if (!isPunct(a[i])) {
        const until = j < m ? bi[j][1] : all.length;
        for (let k = lastB + 1; k < until; k++) push('same', all[k]);
        lastB = until - 1;
        push('removed', CJK.test(a[i]) ? a[i] : `${a[i]} `);
      }
      i++;
    } else {
      emitB(j, 'added');
      j++;
    }
  }
  for (let k = lastB + 1; k < all.length; k++) push('same', all[k]);
  return out;
}
