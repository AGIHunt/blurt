// In-browser stand-in for the Rust commands (vite dev, UI screenshots, unit tests): a small fixed world — three
// projects, a dozen items in every K3 state, a batch to review, an agent session waiting for an answer, a
// terminal that prints what Claude Code would. Writes are kept in memory.
import { INBOX_STATES, migrate, OPEN_STATES, targetOf, type State } from '@blurt/ui';

/** The Words tab's list in the browser preview (vocabulary.json's shape). */
const mockWords: { term: string; state: string; source?: string; hits?: number; seen?: number; sounds_like?: string[]; added?: string }[] = [
  { term: 'Blurt', state: 'active', source: 'manual', hits: 12, sounds_like: ['blurred'], added: '2026-10-20T10:00:00+08:00' },
  { term: 'DeepSeek', state: 'active', source: 'learned', hits: 4, added: '2026-10-28T10:00:00+08:00' },
  { term: 'Kubernetes', state: 'active', source: 'manual', hits: 2 },
  { term: 'billing-api', state: 'active', source: 'project' },
  { term: 'BA', state: 'active', source: 'project' },
  { term: 'Claude Code', state: 'active', source: 'default' },
  { term: 'GitHub', state: 'active', source: 'default' },
  { term: 'Qwen', state: 'suggested', source: 'learned', seen: 2, sounds_like: ['群'], added: '2026-11-01T09:00:00+08:00' },
];

type Listener = (p: unknown) => void;
const listeners = new Map<string, Set<Listener>>();

export function mockListen(event: string, cb: Listener): () => void {
  if (!listeners.has(event)) listeners.set(event, new Set());
  listeners.get(event)!.add(cb);
  return () => listeners.get(event)?.delete(cb);
}
const emit = (event: string, p: unknown) => listeners.get(event)?.forEach((cb) => cb(p));

const param = (k: string) => (typeof location === 'undefined' ? null : new URLSearchParams(location.search).get(k));
const zh = () => (param('lang') ?? (typeof navigator === 'undefined' ? '' : navigator.language)).startsWith('zh');
const L = (en: string, cn: string) => (zh() ? cn : en);
const now = Date.now() / 1000;
const H = '/home/maya';

// the main window's project menu edits these in memory (rename, pin, description, remove / restore)
const projectEdits: Record<string, Record<string, unknown>> = {};
const removedProjects = new Set<string>();
const projects = () => projectList().filter((p) => !removedProjects.has(p.id)).map((p) => ({ ...p, ...projectEdits[p.id] }));
const projectList = () => [
  { id: 'p1', name: 'storefront', key: 'SF', slug: 'storefront', path: `${H}/code/storefront`, store: `${H}/code/storefront/.blurt`, kind: 'repo', exists: true, last_used: '2026-10-22T09:40:00+02:00', ...counts('p1') },
  { id: 'p2', name: 'mobile-app', key: 'MA', slug: 'mobile-app', path: `${H}/code/mobile-app`, store: `${H}/code/mobile-app/.blurt`, kind: 'repo', exists: true, last_used: '2026-10-21T17:10:00+02:00', ...counts('p2') },
  { id: 'p3', name: L('Launch notes', '发布笔记'), key: 'LN', slug: 'launch-notes', path: `${H}/Documents/Launch notes`, store: `${H}/Documents/Launch notes/.blurt`, kind: 'folder', exists: true, last_used: '2026-10-20T11:00:00+02:00', ...counts('p3') },
];
const inbox = () => ({ id: 'inbox', name: L('Unassigned', '未归类'), key: 'IN', slug: 'inbox', path: `${H}/Blurt/inbox`, store: `${H}/Blurt/inbox`, kind: 'inbox', exists: true, ...counts('inbox') });

const S1 = `${H}/code/storefront/.blurt/sessions/20261022-093000`;
const S2 = `${H}/Blurt/inbox/sessions/20261022-101500-shots`;

interface MItem {
  uid: string; id: string; project: string; kind: string; title: string; quote?: string; state: State; restore_to?: State; work_to?: string | null; work_agent?: string | null;
  severity?: string | null; session?: string; age: number; actual?: string; expected?: string; steps?: string[]; why?: string; code_refs?: string[]; suggested?: string;
}
const items: MItem[] = [
  { uid: 'u01', id: 'SF-12', project: 'p1', kind: 'issue', title: L('Checkout button does nothing on Safari', 'Safari 上结算按钮点了没反应'), quote: L('I click checkout and nothing happens — no spinner, nothing.', '我点结算，什么都没发生，也没有加载。'), state: 'new', severity: 'high', session: S1, age: 0.4, actual: L('No request is sent; the console shows a TypeError in cart.ts', '没有发请求，控制台在 cart.ts 报 TypeError'), expected: L('Goes to the payment step', '进入付款步骤'), steps: [L('Add any product to the cart', '把任意商品加入购物车'), L('Open the cart in Safari 18', '在 Safari 18 打开购物车'), L('Click Checkout', '点结算')], code_refs: ['web/src/cart/cart.ts:118'] },
  { uid: 'u02', id: 'SF-13', project: 'p1', kind: 'issue', title: L('Price filter resets after going back', '返回后价格筛选被重置'), state: 'new', severity: 'medium', session: S1, age: 0.5 },
  { uid: 'u03', id: 'SF-14', project: 'p1', kind: 'idea', title: L('Show delivery date on the product card', '商品卡片上显示预计送达日期'), state: 'new', session: S1, age: 0.6, why: L('People ask support “when will it arrive?” more than anything else', '客服被问最多的就是「什么时候到」') },
  { uid: 'u04', id: 'SF-9', project: 'p1', kind: 'issue', title: L('Avatar upload returns 500', '头像上传返回 500'), state: 'in_progress', work_to: 'external', severity: 'high', age: 2 },
  { uid: 'u05', id: 'SF-10', project: 'p1', kind: 'task', title: L('Translate the checkout emails into German', '把结算邮件翻译成德语'), state: 'handed_off', work_to: 'external', age: 5 },
  { uid: 'u06', id: 'SF-7', project: 'p1', kind: 'issue', title: L('Search results flicker while typing', '输入时搜索结果闪烁'), state: 'to_verify', work_agent: 'codex', severity: 'medium', age: 20 },
  { uid: 'u07', id: 'SF-5', project: 'p1', kind: 'note', title: L('Competitors all show stock levels', '竞品都显示库存数量'), state: 'todo', age: 48 },
  { uid: 'u08', id: 'SF-3', project: 'p1', kind: 'issue', title: L('Footer links overlap on small phones', '小屏手机上页脚链接重叠'), state: 'done', severity: 'low', age: 90 },
  { uid: 'u09', id: 'SF-2', project: 'p1', kind: 'idea', title: L('Dark mode for the storefront', '商店的深色模式'), state: 'wontfix', age: 120 },
  { uid: 'u10', id: 'MA-4', project: 'p2', kind: 'issue', title: L('Onboarding skips the notifications step', '新手引导跳过了通知那一步'), state: 'new', severity: 'medium', age: 7 },
  { uid: 'u11', id: 'MA-3', project: 'p2', kind: 'task', title: L('Ship the iPad layout', '上线 iPad 布局'), state: 'in_progress', work_to: 'external', age: 26 },
  { uid: 'u12', id: 'LN-2', project: 'p3', kind: 'note', title: L('Keynote: open with the 5-minute demo', '发布会：用 5 分钟演示开场'), state: 'todo', age: 70 },
  { uid: 'u13', id: 'IN-1', project: 'inbox', kind: 'idea', title: L('A weekly digest of what got fixed', '每周发一份修好了什么的周报'), state: 'new', session: S2, age: 0.2, suggested: 'p3' },
  { uid: 'u15', id: 'SF-6', project: 'p1', kind: 'idea', title: L('Confetti when an order goes through', '下单成功时撒彩带'), state: 'discarded', restore_to: 'new', age: 30 },
  { uid: 'u14', id: 'IN-2', project: 'inbox', kind: 'issue', title: L('Login page logo is blurry on 4K', '登录页 logo 在 4K 屏上发虚'), state: 'new', session: S2, severity: 'low', age: 0.25, suggested: 'p1' },
];
// ?empty=1: a fresh install (the empty inbox)
if (param('empty') === '1') items.length = 0;

function counts(project: string) {
  const live = items.filter((i) => i.project === project && i.state !== 'discarded');
  const n = (sts: readonly State[]) => live.filter((i) => sts.includes(i.state)).length;
  return { items: live.length, open_items: n(OPEN_STATES), inbox: n(INBOX_STATES), new: n(['new']), to_verify: n(['to_verify']) };
}

const pname = (id: string) => (id === 'inbox' ? inbox() : projects().find((p) => p.id === id))!;

function row(i: MItem) {
  const p = pname(i.project);
  return {
    uid: i.uid, project_id: i.project, project_name: p.name, project_key: p.key, session_id: i.session ? `${i.project}:${i.session.split('/').pop()}` : null, session_dir: i.session ?? null,
    path: `${p.store}/items/${i.id}.md`, item_id: i.id, kind: i.kind, title: i.title, state: i.state, work_to: i.work_to ?? null, work_agent: i.work_agent ?? null,
    severity: i.severity ?? null, primary_frame: null, created: now - i.age * 3600, updated: now - i.age * 3600, snippet: null, suggested_project: i.suggested ?? null,
    suggested_confidence: i.suggested ? 0.58 : null, project_by: 'capture', quote: i.quote ?? '', frame_count: 0,
  };
}

function docItem(i: MItem) {
  const r = row(i);
  return {
    id: i.id, uid: i.uid, kind: i.kind, title: i.title, quote: i.quote, state: i.state, restore_to: i.restore_to, severity: i.severity ?? undefined, actual: i.actual, expected: i.expected, steps: i.steps, why: i.why,
    code_refs: i.code_refs, project: i.project, path: r.path, work: { to: i.work_to ?? null, agent: i.work_agent ?? null, job: null, handoff: null, claim: i.state === 'to_verify' ? 'fixed' : null, note: '', at: new Date((now - i.age * 3600) * 1000).toISOString(), by: 'agent' },
    created: new Date((now - i.age * 3600) * 1000).toISOString(), source: { type: i.session === S2 ? 'snap' : 'recording', by: 'maya' },
  };
}

let rev = 1;
function doc(scope: { session?: string; project?: string }) {
  // a session: its whole batch; a project: everything but discarded (K3)
  const list = scope.session ? items.filter((i) => i.session === scope.session) : items.filter((i) => i.project === scope.project && i.state !== 'discarded');
  return {
    schema: 3, scope, title: scope.session === S1 ? L('Checkout walkthrough', '结算流程走查') : undefined, language: zh() ? 'zh' : 'en', items: list.map(docItem), _removed: {},
    projects: [...projects().map((p) => ({ id: p.id, name: p.name, key: p.key, path: p.path })), { id: 'inbox', name: inbox().name, key: 'IN' }],
  };
}

const hotkeyRows = () =>
  ['record', 'snap', 'text', 'translate', 'voice', 'pause', 'pen', 'stop', 'reformat', 'project', 'cards', 'menu'].map((a) => {
    const k = ({ record: 'R', snap: 'A', text: 'C', translate: 'T', voice: 'V', project: 'O', cards: 'H', menu: 'B', pause: 'P', pen: 'D', stop: 'S', reformat: 'L' } as Record<string, string>)[a];
    const resident = !['pause', 'pen', 'stop'].includes(a);
    const spec = mockHotkeys[a] ?? `opt+shift+${k}`;
    const label = spec === 'off' ? '' : spec.replace('opt', 'Alt').replace('shift', 'Shift').replace('ctrl', 'Ctrl').replace(/\+(\w)$/, (_, c) => `+${c.toUpperCase()}`);
    return { action: a, spec, label, default: `opt+shift+${k}`, active: resident, result: spec === 'off' ? 'off' : resident ? 'ok' : 'idle' };
  });
// Settings' writes, kept in memory (the Rust merge: two levels deep)
const mockHotkeys: Record<string, string> = {};
const mockCfg: Record<string, any> = { record: { agents: ['claude', 'codex', 'kimi'] }, notify: {} };
function mockMerge(patch: Record<string, any>) {
  for (const [k, v] of Object.entries(patch)) {
    if (v === null) delete mockCfg[k];
    else if (typeof v === 'object' && !Array.isArray(v) && typeof mockCfg[k] === 'object' && mockCfg[k]) {
      for (const [k2, v2] of Object.entries(v)) {
        if (v2 === null) delete mockCfg[k][k2];
        else mockCfg[k][k2] = v2;
      }
    } else mockCfg[k] = v;
  }
}

/** K3 in memory: discarded remembers where it was */
function setState(it: MItem, to: State | null | undefined) {
  if (!to) return;
  const from = migrate(it).state;
  it.restore_to = to === 'discarded' ? from : undefined;
  it.state = to;
}

let current = 'p1';

// dictation's model download and the Welcome, in memory
// ?models=0: no speech model on this PC yet (Settings' no-model notices)
const modelsIn = new Set(param('models') === '0' ? [] : ['sensevoice-small']);
let mdl: { id: string; done: number } | null = null;
// ?cloud=1: DeepSeek connected, polish and translate on it (the API id "deepseek-flash": Settings names it)
const cloudSum = () => (param('cloud') === '1'
  ? { services: [{ id: 'deepseek', preset: 'deepseek', has_key: true }], routes: { polish: { service: 'deepseek', model: 'deepseek-flash' }, translate: null, vision: null } }
  : { services: [], routes: { polish: null, translate: null, vision: null } });
function mockDownload(id: string) {
  const total = id === 'sensevoice-small' ? 228 : 950;
  mdl = { id, done: 0 };
  emit('model-download', { id, state: 'running', done_mb: 0, total_mb: 0 });
  const step = () => {
    if (!mdl) return;
    mdl.done = Math.min(total, mdl.done + total / 40);
    if (mdl.done >= total) {
      mdl = null;
      modelsIn.add(id);
      emit('model-download', { id, state: 'done', done_mb: 0, total_mb: 0 });
    } else {
      emit('model-download', { id, state: 'running', done_mb: mdl.done, total_mb: total });
      setTimeout(step, 250);
    }
  };
  setTimeout(step, 1200);
}
const onb = { needed: param('view') === 'welcome' || param('welcome') === '1', step: 0, uvRetried: false };
let mic = param('mic') ?? 'allowed';
let login = false;
// a first launch: setup.rs starts the recommended model by itself
if (onb.needed && param('uv') !== 'failed') mockDownload('fun-asr-nano-onnx');
// the dictation key, as the hook would report it: right Alt on this page
if (typeof window !== 'undefined') {
  for (const type of ['keydown', 'keyup'] as const)
    window.addEventListener(type, (e) => e.code === 'AltRight' && !e.repeat && emit('dictation://key', { down: type === 'keydown' }));
}

// the Dictation page (dictation/history.rs): a few takes today and yesterday, one copied, one not polished, one not
// recognised, one turned into an item; ?dictations=0 for the empty page
const dIso = (hoursAgo: number) => new Date(Date.now() - hoursAgo * 3600_000).toISOString();
const dEntry = (id: string, hoursAgo: number, app: string, raw: string, text: string, more: Record<string, unknown> = {}) => ({
  id, t: dIso(hoursAgo), app, bundle: `${app}.exe`, duration: Math.max(2, raw.length / 9), raw, polished: text === raw ? null : text, text,
  model: text === raw ? null : 'deepseek-v4-flash', fell_back: false, reason: null, insert: 'pasted', audio: `audio/${id}.wav`,
  audio_path: `${H}/.blurt/dictation/audio/${id}.wav`, asr_model: 'fun-asr-nano-onnx', style: 'light', ...more,
});
let dictations: any[] = param('dictations') === '0' ? [] : [
  dEntry('d-1', 0.2, 'Slack', 'um can you push the release to thursday the the QA pass isnt done', 'Can you push the release to Thursday? The QA pass isn’t done.'),
  dEntry('d-2', 0.9, 'Code', L('the checkout button does nothing on safari clicking it shows no spinner', '那个结算按钮在 safari 上点了没反应 也没有加载'), L('The checkout button does nothing on Safari. Clicking it shows no spinner.', '结算按钮在 Safari 上点了没反应，也没有加载。'), { item: 'SF-12', item_uid: 'u01' }),
  dEntry('d-3', 1.5, 'chrome', L('reply to anna saying the deck is ready for review', '回复安娜说幻灯片可以看了'), L('reply to anna saying the deck is ready for review', '回复安娜说幻灯片可以看了'), { fell_back: true, reason: 'timeout' }),
  dEntry('d-4', 2.4, 'explorer', L('rename the folder to launch notes', '把文件夹改名叫发布笔记'), L('Rename the folder to Launch notes.', '把文件夹改名为「发布笔记」。'), { insert: 'copied' }),
  dEntry('d-5', 3.1, 'WINWORD', '', '', { reason: 'asr_failed:asr_slow', insert: 'none', polished: null, model: null }),
  dEntry('d-6', 26, 'Teams', L('lets move standup to ten thirty tomorrow', '明天站会改到十点半吧'), L('Let’s move stand-up to 10:30 tomorrow.', '明天站会改到 10:30 吧。'), { corrected: L('Let’s move stand-up to 10:30 tomorrow, not 10.', '明天站会改到 10:30 吧，不是 10 点。') }),
  dEntry('d-7', 30, 'Notion', L('three things for the launch one the press kit two the demo video three the faq', '发布要准备三件事 一是新闻稿 二是演示视频 三是常见问题'), L('Three things for the launch:\n1. The press kit\n2. The demo video\n3. The FAQ', '发布要准备三件事：\n1. 新闻稿\n2. 演示视频\n3. 常见问题'), { style: 'structured' }),
];

// Settings → Phone (remote.rs): Add Phone… shows a code good for two minutes (?phone_code=<seconds> to watch it run
// out sooner); a few seconds later a phone uses it over the relay and asks with six digits (?phone_scan=0: nobody
// scans); Allow pairs it and it connects over the relay, then finds a direct path. ?phone= paired | asking | nocontrol |
// problem | fromphone | relayfail starts there instead of with no phone.
type MockRemote = {
  listening: boolean;
  pairing: null | { url: string; qrSvg: string; expiresAt: number };
  asking: null | { device: string; digits: string; viaRelay: boolean };
  devices: { id: string; name: string; lastSeen: number | null }[];
  connected: null | { id: string; name: string; route: 'local' | 'direct' | 'relay'; screen: boolean };
  relay: { address: string | null; fromPhone: boolean; reachable: boolean | null };
  screenAllowed: boolean;
  canControl: boolean;
  problem: string | null;
};
const phoneStart = param('phone') ?? '';
const paired = phoneStart !== '';
const remote: MockRemote = {
  listening: paired,
  pairing: null,
  asking: phoneStart === 'asking' ? { device: L('Maya’s Pixel 9', 'Maya 的 Pixel 9'), digits: '482913', viaRelay: true } : null,
  devices: paired
    ? [
        { id: 'ph-1', name: L('Maya’s iPhone', 'Maya 的 iPhone'), lastSeen: Date.now() - 4 * 60_000 },
        { id: 'ph-2', name: 'iPad mini', lastSeen: Date.now() - 2 * 86400_000 },
      ]
    : [],
  connected: paired ? { id: 'ph-1', name: L('Maya’s iPhone', 'Maya 的 iPhone'), route: 'relay', screen: true } : null,
  relay: paired
    ? { address: 'wss://relay.example.com', fromPhone: phoneStart === 'fromphone', reachable: phoneStart === 'relayfail' ? false : true }
    : { address: null, fromPhone: false, reachable: null },
  screenAllowed: true,
  canControl: phoneStart !== 'nocontrol',
  problem: phoneStart === 'problem' ? L('Blurt can’t listen on this network: port 41833 is taken by another app.', '口喷鸡无法在这个网络上监听：端口 41833 已被其他应用占用。') : null,
};
const remoteNow = () => JSON.parse(JSON.stringify(remote)) as MockRemote;
const remoteChanged = () => emit('remote://status', remoteNow());
let remoteTimers: ReturnType<typeof setTimeout>[] = [];
const remoteLater = (ms: number, f: () => void) => remoteTimers.push(setTimeout(() => (f(), remoteChanged()), ms));

/** A stand-in QR code (finder squares, timing lines, the rest from the link's hash): looks like the host's, scans as nothing. */
function mockQr(seed: string): string {
  const n = 29;
  let h = 2166136261;
  for (const c of seed) h = Math.imul(h ^ c.charCodeAt(0), 16777619);
  const rnd = () => ((h = Math.imul(h ^ (h >>> 15), 2246822507) ^ Math.imul(h ^ (h >>> 13), 3266489909)) >>> 0) / 2 ** 32;
  const on: boolean[][] = Array.from({ length: n }, () => Array(n).fill(false));
  const reserved = (x: number, y: number) => (x < 8 && y < 8) || (x >= n - 8 && y < 8) || (x < 8 && y >= n - 8) || x === 6 || y === 6;
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (!reserved(x, y)) on[y][x] = rnd() < 0.5;
  for (let i = 8; i < n - 8; i++) on[6][i] = on[i][6] = i % 2 === 0;
  const finder = (ox: number, oy: number) => {
    for (let y = 0; y < 7; y++) for (let x = 0; x < 7; x++) on[oy + y][ox + x] = x === 0 || y === 0 || x === 6 || y === 6 || (x >= 2 && x <= 4 && y >= 2 && y <= 4);
  };
  finder(0, 0);
  finder(n - 7, 0);
  finder(0, n - 7);
  for (let y = n - 9; y < n - 4; y++) for (let x = n - 9; x < n - 4; x++) on[y][x] = x === n - 9 || y === n - 9 || x === n - 5 || y === n - 5 || (x === n - 7 && y === n - 7);
  let d = '';
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (on[y][x]) d += `M${x} ${y}h1v1h-1z`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${n} ${n}" shape-rendering="crispEdges"><path fill="#000" d="${d}"/></svg>`;
}

function mockPairingCode() {
  const url = `blurtremote://pair?v=1&host=${encodeURIComponent('maya-thinkpad')}&k=${Math.random().toString(36).slice(2, 12)}`;
  remote.pairing = { url, qrSvg: mockQr(url), expiresAt: Date.now() + Number(param('phone_code') ?? 120) * 1000 };
  remote.listening = true;
  remoteTimers.forEach(clearTimeout);
  remoteTimers = [];
  if (param('phone_scan') === '0') return;
  // a phone scans it: the code is spent, the phone waits for a yes
  remoteLater(5000, () => {
    if (!remote.pairing || remote.pairing.expiresAt < Date.now()) return;
    remote.pairing = null;
    remote.asking = { device: L('Maya’s Pixel 9', 'Maya 的 Pixel 9'), digits: String(100000 + Math.floor(Math.random() * 900000)), viaRelay: !!remote.relay.address };
    // nobody answers in two minutes: that's a no
    remoteLater(120_000, () => (remote.asking = null));
  });
}

function mockRemote(cmd: string, a: Record<string, any>): unknown {
  switch (cmd) {
    case 'remote_status':
      return remoteNow();
    case 'remote_show_pairing':
      if (a.on) mockPairingCode();
      else {
        remote.pairing = null;
        remote.listening = remote.devices.length > 0;
        if (!remote.asking) (remoteTimers.forEach(clearTimeout), (remoteTimers = []));
      }
      break;
    case 'remote_answer_pairing': {
      const ask = remote.asking;
      if (!ask || (a.digits !== undefined && a.digits !== ask.digits)) break; // another phone's question by now
      remoteTimers.forEach(clearTimeout);
      remoteTimers = [];
      remote.asking = null;
      if (!a.yes) {
        // turned away: a fresh code while Add Phone… is open
        mockPairingCode();
        break;
      }
      const id = `ph-${Date.now()}`;
      remote.devices = [...remote.devices, { id, name: ask.device, lastSeen: Date.now() }];
      remote.listening = true;
      remote.connected = { id, name: ask.device, route: ask.viaRelay ? 'relay' : 'local', screen: false };
      if (ask.viaRelay) remoteLater(4000, () => remote.connected?.id === id && (remote.connected.route = 'direct'));
      break;
    }
    case 'remote_remove_device':
      remote.devices = remote.devices.filter((d) => d.id !== a.id);
      if (remote.connected?.id === a.id) remote.connected = null;
      remote.listening = remote.devices.length > 0 || !!remote.pairing;
      break;
    case 'remote_set_relay': {
      const t = String(a.address ?? '').trim();
      if (!t) remote.relay = { address: null, fromPhone: false, reachable: null };
      else if (!/^wss?:\/\/[^\s/?#]+(\/[^\s?#]*)?$/.test(t)) throw new Error('not a relay address');
      else {
        remote.relay = { address: t, fromPhone: false, reachable: null };
        remoteLater(900, () => remote.relay.address === t && (remote.relay.reachable = !/nothing|bad|invalid/.test(t)));
      }
      break;
    }
    case 'remote_check_relay':
      return new Promise((ok) => setTimeout(() => ok(!/nothing|bad|invalid/.test(String(a.address))), 900));
    case 'remote_set_screen_allowed':
      remote.screenAllowed = !!a.on;
      if (!a.on && remote.connected) remote.connected.screen = false;
      break;
    case 'remote_relay_instructions':
      return MOCK_RELAY_PROMPT;
  }
  remoteChanged();
  return remoteNow();
}

const MOCK_RELAY_PROMPT = `Set up a relay I own for Blurt on my phone, then give me its address to paste into Blurt.

Blurt for phones turns an iPhone or Android phone into a trackpad and keyboard for a computer. When the two aren't on the same network they connect through a small WebSocket relay. It passes sealed bytes it can't read and stores nothing.

The code and the full steps are here; read README.md first:
https://github.com/AGIHunt/blurt/tree/main/tools/remote-relay

Ask me which of these I have, then do that one:
A. A domain on Cloudflare: deploy the Worker on a subdomain such as relay.example.com. The free plan is enough for one person.
B. A server with a public IP: run server.js as a service (Node 12 or later, one dependency). With a domain, serve it over HTTPS on port 443 with a publicly trusted certificate. Without one, open a port and use ws://.

If I'm in mainland China, prefer a server there: the round trip is far shorter. A domain served from a mainland server needs an ICP filing.

Don't change anything else on the server or the domain, and ask before opening a port or spending money. Keep credentials out of anything you print.

When it's up, run \`node test.mjs <address>\` from that folder and check it passes. Then tell me the one address, like wss://relay.example.com, and that it goes in Blurt → Settings → Phone → Relay Address. Reply in the language I'm writing in.`;

export async function mockInvoke<T>(cmd: string, args: Record<string, any> = {}): Promise<T> {
  if (cmd.startsWith('remote_')) return (await mockRemote(cmd, args)) as T;
  const r = (v: unknown) => v as T;
  switch (cmd) {
    case 'app_status':
      return r({ version: '0.7.0', os: param('platform') === 'win' ? 'windows' : 'linux', platform: param('platform') === 'win' ? 'win' : 'gnome', wayland: false, lang: param('lang') ?? navigator.language, blurt_home: `${H}/.blurt`, inbox_store: `${H}/Blurt/inbox`,
        handoff_dir: `${H}/.blurt/handoff`, index_ready: true, scripts: `${H}/.claude/skills/blurt/scripts`, uv: '/usr/bin/uv', capture: { recording: false, paused: false, session: null, voice: null }, hotkey_mode: 'plugin',
        start_view: param('view') });
    case 'cards_waiting':
      return r(Number(param('cards') ?? 0));
    case 'cards_reveal':
      return r(undefined);
    case 'projects_list':
      return r({ current, projects: projects(), inbox: inbox() });
    case 'projects_use':
      current = args.id;
      return r({ ok: true, current });
    case 'index_summary':
    {
      const live = items.filter((i) => i.state !== 'discarded');
      const n = (sts: readonly State[]) => live.filter((i) => sts.includes(i.state)).length;
      return r({ missing: false, items: live.length, inbox: n(INBOX_STATES), new: n(['new']), to_verify: n(['to_verify']), active: n(['handed_off', 'in_progress']),
        open: n(OPEN_STATES), unassigned: live.filter((i) => i.project === 'inbox').length, batches: 2,
        progress: n(['handed_off', 'in_progress', 'to_verify']), discarded: items.filter((i) => i.state === 'discarded').length });
    }
    case 'jobs_list':
      return r([
        { id: 'j-20261022-101800-p9x2', type: 'process', state: 'running', project: null, session: S2, title: L('Two screenshots and a voice note', '两张截图和一条语音'), items: [], steps: [{ id: 'prepare', state: 'done' }, { id: 'transcribe', state: 'done' }, { id: 'write', state: 'running', progress: 0.6 }, { id: 'frames', state: 'pending' }, { id: 'route', state: 'pending' }], progress: 0.6, created: '', started: '', ended: null, error: null },
      ]);
    case 'index_query': {
      const q = args.q ?? {};
      let list = items.filter((x) => (q.state?.length ? q.state.includes(x.state) : x.state !== 'discarded'));
      if (q.kind?.length) list = list.filter((x) => q.kind.includes(x.kind));
      if (q.project) list = list.filter((x) => x.project === q.project);
      for (const term of (q.query ?? '').toLowerCase().split(/\s+/).filter(Boolean)) list = list.filter((x) => (x.title + (x.quote ?? '')).toLowerCase().includes(term));
      list = [...list].sort((a, b) => a.age - b.age);
      // the Mac list's sort keys (index.rs order_by): dates newest first, the rest A to Z, unless asked
      const key = q.sort ?? 'updated';
      const asc = q.ascending ?? key !== 'updated';
      const LC = ['new', 'todo', 'handed_off', 'in_progress', 'to_verify', 'done', 'wontfix', 'discarded'];
      const val = (x: MItem): string | number =>
        key === 'title' ? x.title.toLowerCase() : key === 'id' ? x.id.replace(/\d+$/, (n) => n.padStart(6, '0')) : key === 'kind' ? x.kind
          : key === 'state' ? LC.indexOf(x.state) : key === 'project' ? pname(x.project).name.toLowerCase() : -x.age;
      const cmp = (a: MItem, b: MItem) => (val(a) < val(b) ? -1 : val(a) > val(b) ? 1 : a.age - b.age);
      list.sort((a, b) => (asc ? cmp(a, b) : -cmp(a, b)));
      return r({ total: list.length, items: list.slice(q.offset ?? 0, (q.offset ?? 0) + (q.limit ?? 50)).map(row), missing: false });
    }
    case 'index_item':
      return r(items.find((x) => x.uid === args.uid) ? row(items.find((x) => x.uid === args.uid)!) : null);
    case 'index_sessions':
      return r([
        { id: 'p1:20261022-093000', project_id: 'p1', project_name: 'storefront', project_key: 'SF', project_path: `${H}/code/storefront`, dir: S1, mode: 'video', title: L('Checkout walkthrough', '结算流程走查'), created: now - 1800, duration: 312, shot_count: 2, item_count: 3, new_count: items.filter((i) => i.session === S1 && i.state === 'new').length, processed: 1, processing: 0, reviewed: 0 },
        { id: 'inbox:20261022-101500-shots', project_id: 'inbox', project_name: inbox().name, project_key: 'IN', project_path: `${H}/Blurt/inbox`, dir: S2, mode: 'shots', title: null, created: now - 700, duration: null, shot_count: 2, item_count: 2, new_count: items.filter((i) => i.session === S2 && i.state === 'new').length, processed: 1, processing: 0, reviewed: 0 },
      ]);
    case 'items_doc':
      return r({ doc: doc(args.scope), etag: `"m${rev}"` });
    case 'items_poll':
      return r(args.etag === `"m${rev}"` ? { etag: args.etag } : { doc: doc(args.scope), etag: `"m${rev}"` });
    case 'items_ops': {
      for (const op of args.ops ?? []) {
        const it = items.find((i) => i.uid === op.id || i.id === op.id);
        if (!it) continue;
        if (op.op === 'set') Object.assign(it, op.set ?? {});
        if (op.op === 'state') setState(it, op.action ? targetOf(op.action, it) : op.state);
      }
      rev++;
      return r({ ok: true, etag: `"m${rev}"`, doc: doc(args.scope) });
    }
    case 'items_state':
      for (const uid of args.uids ?? []) {
        const it = items.find((i) => i.uid === uid);
        if (it) setState(it, targetOf(args.action, it));
      }
      rev++;
      emit('index://changed', {});
      return r({ ok: true });
    case 'items_move':
      for (const uid of args.uids ?? []) {
        const it = items.find((i) => i.uid === uid);
        if (it) it.project = args.project;
      }
      rev++;
      emit('index://changed', {});
      return r({ ok: true, moved: args.uids ?? [] });
    // the main window's writes (docs/design/windows-parity/main-window.md)
    case 'items_undo_state':
      for (const uid of args.uids ?? []) {
        const it = items.find((i) => i.uid === uid);
        if (it) setState(it, args.to);
      }
      rev++;
      emit('index://changed', {});
      return r({ ok: true });
    case 'items_add': {
      const p = args.project as string;
      const key = pname(p)?.key ?? 'IN';
      const n = Math.max(0, ...items.filter((i) => i.project === p).map((i) => Number(i.id.split('-')[1]) || 0)) + 1;
      const uid = `u${100 + items.length}`;
      items.push({ uid, id: `${key}-${n}`, project: p, kind: args.item.kind, title: args.item.title, state: 'new', age: 0 });
      rev++;
      emit('index://changed', {});
      return r({ ok: true, uid });
    }
    case 'items_export_bundle':
      return r({ ok: true, path: `${H}/Downloads/${args.name}`, items: (args.uids ?? []).length });
    case 'pick_images':
      return r([]);
    case 'items_enrich':
      return r('j-mock-enrich');
    case 'items_drag_out':
    case 'items_drag_out_available':
      return r(false);
    case 'projects_set':
      projectEdits[args.id] = { ...projectEdits[args.id], ...args.patch };
      emit('projects://changed', {});
      return r({ ok: true });
    case 'projects_remove':
      removedProjects.add(args.id);
      emit('projects://changed', {});
      return r({ ok: true, removed: { entry: { id: args.id } } });
    case 'projects_restore':
      removedProjects.delete(args.removed?.removed?.entry?.id ?? args.removed?.entry?.id);
      emit('projects://changed', {});
      return r({ ok: true });
    case 'handoff_create':
      return r({ id: 'H-0032', path: `${H}/.blurt/handoff/H-0032.md`, text: 'Please handle SF-12 — details and screenshots are in …' });
    case 'agents_detect':
      return r({ order: ['claude', 'codex', 'kimi'], pick: 'claude', agents: [
        { id: 'claude', name: 'Claude Code', path: '/usr/bin/claude', state: 'ready', why: '', fix: '', installed: true, version: '2.3.1', login: 'ok', headless: true, interactive: 'terminal' },
        { id: 'codex', name: 'Codex', path: '/usr/bin/codex', state: 'ready', why: '', fix: '', installed: true, version: '0.61.0', login: 'ok', headless: true, interactive: 'terminal' },
        { id: 'kimi', name: 'Kimi Code', path: null, state: 'not_installed', why: '', fix: 'npm i -g kimi-code', installed: false, version: null, login: 'n/a', headless: true, interactive: 'terminal' },
      ] });
    case 'agents_models':
      return r(args.agent === 'codex'
        ? { ok: true, id: 'codex', models: [{ id: 'gpt-6-astra', name: 'GPT-6-Astra', description: '', cheap: false }, { id: 'gpt-6-luna', name: 'GPT-6-Luna', description: 'Fast and affordable', cheap: true }], cheapest: 'gpt-6-luna', cli_default: 'gpt-6-astra', efforts: ['low', 'medium', 'high'] }
        : { ok: true, id: args.agent, models: [{ id: 'haiku', name: 'Haiku', description: '', cheap: true }, { id: 'sonnet', name: 'Sonnet', description: '', cheap: false }], cheapest: 'haiku', cli_default: null, efforts: [] });
    case 'settings_get':
      return r({ config: JSON.parse(JSON.stringify(mockCfg)), hotkeys: hotkeyRows(), hotkey_mode: 'plugin', wayland: false, config_path: `${H}/.blurt/config.json`,
        export_targets: [{ id: 'markdown', name: 'Markdown', configured: true }, { id: 'csv', name: 'CSV', configured: true }, { id: 'github', name: 'GitHub Issues', configured: true, needs: 'gh auth login' }, { id: 'feishu', name: 'Feishu / Lark Bitable', configured: false }] });
    case 'shortcut_set': {
      if (String(args.combo).toLowerCase().includes('cmd+shift+s')) return r({ result: 'system', name: 'Snipping Tool' });
      const dup = hotkeyRows().find((x) => x.action !== args.action && x.spec !== 'off' && x.spec.toLowerCase() === String(args.combo).toLowerCase());
      if (dup) return r({ result: 'duplicate', action: dup.action, spec: dup.spec, label: dup.label });
      mockHotkeys[args.action] = args.combo;
      return r({ result: 'ok', spec: args.combo, label: args.combo });
    }
    case 'settings_set':
      mockMerge(args.patch ?? {});
      return r(mockCfg);
    case 'asr_models':
      return r({ models: [{ id: 'sensevoice-small', name: 'SenseVoice Small', backend: 'sherpa-onnx', installed: true, size_mb: 228, languages: ['zh', 'en', 'ja', 'ko', 'yue'] }, { id: 'whisper-large-v3-turbo-ct2', name: 'Whisper large-v3 turbo', backend: 'faster-whisper', installed: false, size_mb: 1620, languages: 'multi' }] });
    case 'dictation_models':
      if (param('uv') === 'failed' && !onb.uvRetried) throw new Error('uv not found');
      return r({ recommended: 'fun-asr-nano-onnx', selected: ['fun-asr-nano-onnx', 'sensevoice-small'].find((m) => modelsIn.has(m)) ?? 'fun-asr-nano-onnx', ready: modelsIn.has('fun-asr-nano-onnx'), downloading: mdl?.id ?? null, models: [{ id: 'fun-asr-nano-onnx', name: 'Fun-ASR-Nano (CPU)', size_mb: 950, installed: modelsIn.has('fun-asr-nano-onnx'), recommended: true }, { id: 'sensevoice-small', name: 'SenseVoice Small', size_mb: 228, installed: modelsIn.has('sensevoice-small'), recommended: false }] });
    case 'model_download':
      if (mdl) throw new Error('a download is already running');
      mockDownload(args.id);
      return r(undefined);
    // the Welcome (onboarding.rs): ?view=welcome or ?welcome=1 shows it; ?dictation=0 is Linux (no dictation steps);
    // ?mic=denied|none, ?uv=failed for the other states
    case 'onboarding_get':
      return r({ ...onb, uv: param('uv') !== 'failed' || onb.uvRetried, uv_state: param('uv') === 'failed' && !onb.uvRetried ? 'failed' : 'done', first_download_pending: false,
        dictation: { available: param('dictation') !== '0', key: 'right_option', mode: 'auto', enabled: true } });
    case 'onboarding_step':
      onb.step = args.step;
      return r(undefined);
    case 'onboarding_finish':
      onb.needed = false;
      if (typeof args.login === 'boolean') login = args.login;
      return r({ supported: true, enabled: login });
    case 'onboarding_retry_setup':
      setTimeout(() => {
        onb.uvRetried = true;
        emit('setup', { step: 'uv', state: 'done' });
        mockDownload('fun-asr-nano-onnx');
      }, 1500);
      return r(true);
    case 'onboarding_mic':
      return r({ supported: true, device: mic === 'none' ? null : 'Microphone (Realtek(R) Audio)', access: mic === 'denied' ? 'denied' : 'allowed' });
    case 'onboarding_mic_settings':
      setTimeout(() => (mic = 'allowed'), 2500); // as if the user turned it on in Windows Settings
      return r(undefined);
    case 'login_item_get':
      return r({ supported: true, enabled: login });
    case 'login_item_set':
      login = args.on;
      return r({ supported: true, enabled: login });
    case 'dictation_history':
      return r({ entries: [...dictations].sort((a, b) => b.t.localeCompare(a.t)), retention_days: 30, enabled: true, ready: true, can_retry: true });
    case 'dictation_history_edit': {
      const e = args.edit ?? {};
      if (e.op === 'delete') {
        const gone = dictations.filter((d) => e.ids.includes(d.id));
        dictations = dictations.filter((d) => !e.ids.includes(d.id));
        return r({ ok: true, deleted: gone });
      }
      if (e.op === 'restore') dictations = [...dictations.filter((d) => !e.entries.some((x: any) => x.id === d.id)), ...e.entries];
      if (e.op === 'correct') dictations = dictations.map((d) => (d.id !== e.id ? d : e.text ? { ...d, corrected: e.text } : (({ corrected: _, ...rest }) => rest)(d)));
      if (e.op === 'clear') dictations = [];
      return r({ ok: true });
    }
    case 'dictation_history_item': {
      await new Promise((ok) => setTimeout(ok, 1200));
      const key = `SF-${20 + Math.floor(Math.random() * 50)}`;
      dictations = dictations.map((d) => (d.id === args.id ? { ...d, item: key, item_uid: 'u02' } : d));
      return r({ ok: true, item: { id: key, uid: 'u02' } });
    }
    case 'dictation_retry': {
      await new Promise((ok) => setTimeout(ok, 1500));
      const text = L('Add the invoice number to the email subject.', '在邮件标题里加上发票号。');
      dictations = dictations.map((d) => (d.id === args.id ? { ...d, raw: text.toLowerCase(), text, polished: text, reason: null, insert: 'copied', model: 'deepseek-v4-flash' } : d));
      return r({ ok: true, entry: dictations.find((d) => d.id === args.id) });
    }
    case 'clipboard_write':
      await navigator.clipboard?.writeText(args.text).catch(() => {});
      return r(undefined);
    case 'cloud_summary':
      return r(cloudSum());
    case 'update_check':
      return r({ configured: false });
    // Settings' backends (housekeeping.rs)
    case 'update_state':
      return r({ configured: param('update') === '1', pending: param('update') === '1' ? '1.2.0' : null });
    case 'app_contract':
      return r({ skill: 1, app: 1, mismatch: param('contract') ?? null });
    case 'storage_scan':
      return r({ folders: [{ path: `${H}/code/storefront/.blurt/sessions`, bytes: 2_310_000_000, sessions: 14 }, { path: `${H}/Blurt/inbox/sessions`, bytes: 410_000_000, sessions: 22 }],
        videos: [{ session: S1, bytes: 980_000_000, age_days: 41 }, { session: `${S1}-b`, bytes: 620_000_000, age_days: 120 }],
        models: [{ path: `${H}/.blurt/models/asr/fun-asr-nano-onnx`, folder: 'fun-asr-nano-onnx', bytes: 996_000_000 }, { path: `${H}/.blurt/models/asr/sensevoice-small`, folder: 'sensevoice-small', bytes: 239_000_000 }],
        files: [{ key: 'dictation_history', path: `${H}/.blurt/dictation/history.jsonl`, bytes: 412_000, removable: false }, { key: 'dictation_audio', path: `${H}/.blurt/dictation/audio`, bytes: 88_000_000, removable: false },
          { key: 'index', path: `${H}/.blurt/index.db`, bytes: 6_200_000, removable: false }, { key: 'jobs', path: `${H}/.blurt/jobs`, bytes: 1_900_000, removable: false }, { key: 'logs', path: `${H}/.blurt/logs`, bytes: 3_100_000, removable: false }],
        auto_days: (mockCfg.record?.delete_videos_after_days as number) ?? null, available: 214_000_000_000 });
    case 'videos_auto_set':
      mockMerge({ record: { delete_videos_after_days: args.days } });
      return r({ auto_days: args.days });
    case 'videos_trash':
      return r({ count: 1, bytes: 620_000_000 });
    case 'storage_trash':
      return r(args.files ?? []);
    case 'cloud_curated':
      return r({ jobs: { polish: [{ service: 'dashscope', model: 'deepseek-v4.1-flash', name: 'DeepSeek V4.1 Flash' }, { service: 'deepseek', model: 'deepseek-flash', name: 'DeepSeek V4.1 Flash' }],
        translate: [{ service: 'dashscope', model: 'deepseek-v4.1-flash', name: 'DeepSeek V4.1 Flash' }, { service: 'deepseek', model: 'deepseek-flash', name: 'DeepSeek V4.1 Flash' }],
        vision: [{ service: 'dashscope', model: 'qwen3.6-flash', name: 'Qwen3.6 Flash' }, { service: 'deepseek', model: 'deepseek-flash', name: 'DeepSeek V4.1 Flash' }] } });
    case 'cloud_job_set':
      return r(cloudSum());
    case 'asr_auto_apply':
      return r({ ok: true });
    case 'agents_registry':
      return r({ agents: [
        { id: 'claude', name: 'Claude Code', fix: { en: 'run `claude` in a terminal and /login', zh: '在终端运行 claude，然后输入 /login' }, install: { en: 'npm i -g @anthropic-ai/claude-code', zh: 'npm i -g @anthropic-ai/claude-code' }, processing: { recording: { model: 'default', effort: 'low' }, cards: { model: 'cheapest', effort: 'low' } } },
        { id: 'codex', name: 'Codex', fix: { en: 'run `codex login`', zh: '运行 codex login' }, install: { en: 'npm i -g @openai/codex', zh: 'npm i -g @openai/codex' } },
        { id: 'kimi', name: 'Kimi Code', install: { en: 'npm i -g kimi-code', zh: 'npm i -g kimi-code' } },
        { id: 'cursor', name: 'Cursor', headless: false, install: { en: 'see cursor.com', zh: '见 cursor.com' } },
      ], failures: [{ id: 'auth', reason: { en: '{name} isn’t signed in: {fix}', zh: '{name} 没有登录：{fix}' } }] });
    case 'agents_install':
      return r(args.dryRun
        ? { ok: true, changes: args.id === 'claude' ? [{ action: 'exists', path: `${H}/.claude/skills/blurt` }, { action: 'exists', argv: ['claude', 'mcp', 'get', 'blurt'] }] : [{ action: 'symlink', path: `${H}/.codex/skills/blurt`, target: `${H}/.claude/skills/blurt` }, { action: 'run', argv: ['codex', 'mcp', 'add', 'blurt', '--', 'uv', 'run', 'mcp_server.py'] }] }
        : { ok: true, applied: true, changes: [{ action: 'symlink', ok: true, path: `${H}/.codex/skills/blurt`, target: `${H}/.claude/skills/blurt` }, { action: 'run', ok: true, argv: ['codex', 'mcp', 'add', 'blurt'] }] });
    case 'agents_test':
      await new Promise((ok) => setTimeout(ok, 800));
      return r({ ok: true, secs: 3.2 });
    case 'dictation_mics':
      return r({ default: 'Microphone (Realtek(R) Audio)', devices: ['Microphone (Realtek(R) Audio)', 'Headset (Jabra Evolve2 65)'] });
    case 'dictation_words':
      return r({ terms: mockWords.filter((w) => w.state === 'active' || w.state === 'suggested') });
    case 'dictation_words_edit': {
      const a = args as { op: string; term: string; to?: string | null };
      const w = mockWords.find((x) => x.term.toLowerCase() === a.term.toLowerCase());
      if (a.op === 'add') {
        for (const t of a.term.split(/[,，、\n]/).map((x) => x.trim()).filter(Boolean)) {
          const have = mockWords.find((x) => x.term.toLowerCase() === t.toLowerCase());
          if (have) have.state = 'active';
          else mockWords.push({ term: t, state: 'active', source: 'manual', hits: 0, added: new Date().toISOString() });
        }
      } else if (w && a.op === 'rename' && a.to) w.term = a.to;
      else if (w) w.state = { remove: 'removed', accept: 'active', restore: 'active', reject: 'rejected', suggest: 'suggested' }[a.op] ?? w.state;
      return r({ changed: true, terms: mockWords });
    }
    case 'app_icon':
      return r(null);
    case 'voiceprint_status':
      return r({ enrolled: param('vp') === '1', stale: param('vp') === 'stale', model_ready: true, recording: false });
    case 'voiceprint_prepare':
      return r({ ok: true, enrolled: false, stale: false, model_ready: true });
    case 'voiceprint_clear':
      return r({ enrolled: false, stale: false, model_ready: true });
    case 'voiceprint_start': {
      // a take read in about 3 s, then learned
      let p = 0;
      emit('voiceprint://changed', { phase: 'recording', progress: 0 });
      const t = setInterval(() => {
        p += 0.1;
        if (p < 1) return emit('voiceprint://changed', { phase: 'recording', progress: p, can_finish: p >= 0.5 });
        clearInterval(t);
        emit('voiceprint://changed', { phase: 'saving', progress: 1 });
        setTimeout(() => emit('voiceprint://changed', { phase: 'idle', learned: true, enrolled: true }), 700);
      }, 300);
      return r(undefined);
    }
    case 'voiceprint_stop':
      return r(undefined);
    case 'cloud_connect_speech':
      await new Promise((ok) => setTimeout(ok, 600));
      return r(String(args.token).length < 8 ? { ok: false, code: 'auth' } : { ok: true, ms: 480, summary: { services: [{ id: 'volcengine-speech', preset: 'volcengine-speech', has_key: true }], routes: {} } });
    case 'cloud_speech_app_id':
      return r(null);
    case 'model_download_cancel':
      return r(true);
    case 'agent_setup_instruction':
      return r({ guide: 'C:\\Users\\you\\.claude\\skills\\blurt\\reference\\setup-models.md', setup: 'C:\\Users\\you\\.claude\\skills\\blurt\\scripts\\setup.py' });
    case 'agent_setup_state':
      return r(param('setup') === '1'
        ? { active: true, agent: 'Claude Code', steps: [{ kind: 'connect', subject: 'deepseek', state: 'done', name: 'DeepSeek' }, { kind: 'use', subject: 'polish', state: 'done', name: 'DeepSeek V4.1 Flash' }, { kind: 'download', subject: 'fun-asr-nano-onnx', state: 'running', name: 'Fun-ASR Nano' }] }
        : { active: false, agent: null, steps: [] });
    case 'agent_setup_stop':
    case 'agent_setup_dismiss':
      return r({ active: false, agent: null, steps: [] });
    case 'save_to_downloads':
      return r(String(args.path ?? '').split(/[\\/]/).pop() ?? '');
    case 'feedback_send':
      await new Promise((ok) => setTimeout(ok, 800));
      return r({ ok: true, id: 'FB-7Q2K', bytes: 412000, takes: (args.ids ?? []).length });
    default:
      return r(undefined);
  }
}
