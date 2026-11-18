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
// Storage → Data location: the default, or (?location=custom) a folder on another drive whose old copy is being deleted
const mockLocation = param('location') === 'custom'
  ? { home: '/media/maya/Data/Blurt/.blurt', workspace: '/media/maya/Data/Blurt', custom: true, folder: '/media/maya/Data/Blurt', profile: H, fixed_by: null, cleanup: true, moving: false }
  : { home: `${H}/.blurt`, workspace: `${H}/Blurt`, custom: false, folder: null as string | null, profile: H, fixed_by: param('location') === 'env' ? 'BLURT_HOME' : null, cleanup: false, moving: false };

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
// recordings (recordings_list): S1 organised; an Unassigned one whose organising failed (no agent), one saved as video
// only, one never organised; a mobile-app one being organised. ?rec=none: none at all
const R2 = `${H}/Blurt/inbox/sessions/20261022-110200`;
const R3 = `${H}/Blurt/inbox/sessions/20261021-164000`;
const R4 = `${H}/code/mobile-app/.blurt/sessions/20261022-114500`;
const R5 = `${H}/Blurt/inbox/sessions/20261020-091500`;
const recJobs: Record<string, any>[] = [
  { id: 'j-20261022-110800-f4a1', type: 'process', state: 'failed', project: null, session: R2, title: null, items: [], steps: [{ id: 'prepare', state: 'failed' }], progress: null, created: '2026-10-22T11:08:00+02:00', started: '2026-10-22T11:08:00+02:00', ended: '2026-10-22T11:08:01+02:00', error: { code: 'no_agent', message: 'no coding agent is installed and logged in' } },
  { id: 'j-20261022-115000-r7k2', type: 'process', state: 'running', project: 'p2', session: R4, title: null, items: [], steps: [{ id: 'prepare', state: 'done' }, { id: 'transcribe', state: 'running' }, { id: 'write', state: 'pending' }], progress: null, created: '2026-10-22T11:50:00+02:00', started: '2026-10-22T11:50:00+02:00', ended: null, error: null },
];
function mockRecordings() {
  if (param('rec') === 'none') return [];
  const rec = (dir: string, project_id: string, ago: number, duration: number, first: string | null, more: Record<string, unknown> = {}) => ({
    id: `${project_id}:${dir.split('/').pop()}`, dir, project_id, project_name: project_id === 'inbox' ? inbox().name : pname(project_id).name, title: null, created: now - ago, duration,
    item_count: 0, processed: 0, processing: 0, video: `${dir}/recording.mp4`, first_line: first, video_only: false, ...more,
  });
  return [
    rec(R4, 'p2', 900, 74, L('On the settings screen the toggle flips back after a second', '设置页的开关点了一秒又弹回去')),
    rec(R2, 'inbox', 1500, 192, L('The login page hangs after I tap Continue', '登录页点继续以后一直转圈')),
    rec(S1, 'p1', 1800, 312, L('Let’s walk through checkout on Safari first', '先在 Safari 上走一遍结算流程'), { item_count: 3, processed: 1 }),
    rec(R3, 'inbox', 86400 + 3600, 48, null, { video_only: true }),
    rec(R5, 'inbox', 2 * 86400, 133, L('Notes for the onboarding copy review', '新手引导文案的修改意见'), { item_count: 2, processed: 1, video: null }),
  ];
}

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
    // ?taken=snap: another app holds that key (Home's fix line)
    const disabled = mockOff().includes(OWNER[a] ?? '');
    const result = spec === 'off' ? 'off' : disabled ? 'disabled' : param('taken') === a ? 'taken' : resident ? 'ok' : 'idle';
    return { action: a, spec, label, default: `opt+shift+${k}`, active: resident && !disabled, result };
  });
const OWNER: Record<string, string> = { reformat: 'dictation', snap: 'cards', voice: 'cards', cards: 'cards', text: 'screen_text', translate: 'screen_text', record: 'recording', pause: 'recording', pen: 'recording', stop: 'recording', project: 'recording' };

// the capability switches (capabilities.rs): ?off=cards,phone starts with those off
const CAP_IDS = ['dictation', 'cards', 'screen_text', 'recording', 'phone'];
function mockOff(): string[] {
  return CAP_IDS.filter((c) => (c === 'dictation' ? mockCfg.record?.dictation?.enabled === false : mockCfg.app?.capabilities?.[c] === false));
}
function mockSetCapability(id: string, on: boolean) {
  if (id === 'dictation') {
    mockCfg.record = mockCfg.record ?? {};
    const d = { ...(mockCfg.record.dictation ?? {}) };
    if (on) delete d.enabled;
    else d.enabled = false;
    mockCfg.record.dictation = d;
  } else {
    mockCfg.app = mockCfg.app ?? {};
    const caps = { ...(mockCfg.app.capabilities ?? {}) };
    if (on) delete caps[id];
    else caps[id] = false;
    mockCfg.app.capabilities = caps;
  }
  emit('capabilities://changed', { off: mockOff() });
  emit('hotkeys://changed', hotkeyRows());
}

// the Text & Translation page (screen_text_history): what Alt+Shift+C copied and Alt+Shift+T translated; ?screen_text=0 for none
let mockScreenText = param('screen_text') === '0' ? [] : [
  { id: 's-1', time: now - 600, translated: true, text: L('The export to CSV fails when the file name has spaces.', '文件名带空格时导出 CSV 会失败。'), source: L('文件名带空格时导出 CSV 会失败。', 'The export to CSV fails when the file name has spaces.'), target: L('en', 'zh'), app: 'Microsoft Edge', outcome: 'pasted' },
  { id: 's-2', time: now - 3600, translated: false, text: 'npm ERR! code ERESOLVE\nnpm ERR! Could not resolve dependency: peer react@"^18" from @blurt/ui', app: 'Windows Terminal', outcome: 'copied' },
  { id: 's-3', time: now - 90000, translated: true, text: L('Thanks, I’ll take a look tomorrow morning.', '谢谢，我明天上午看一下。'), source: L('ありがとう、明日の朝見てみます。', 'ありがとう、明日の朝見てみます。'), target: L('en', 'zh'), app: 'Slack', outcome: 'copied' },
];

// the Cards page (cards_list): pictures drawn here as small app screens, a voice note, one used yesterday; ?cards=0 for none
const shotSvg = (title: string, accent: string, lines: string[]) =>
  `data:image/svg+xml;charset=utf-8,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="480" height="300" font-family="Segoe UI, sans-serif">
<rect width="480" height="300" fill="#f6f7f9"/><rect width="480" height="34" fill="#ffffff"/><circle cx="18" cy="17" r="5" fill="#d0d4da"/><circle cx="34" cy="17" r="5" fill="#d0d4da"/>
<text x="56" y="22" font-size="13" fill="#3a3f47">${title}</text><rect x="20" y="52" width="140" height="228" rx="8" fill="#ffffff"/>
${[0, 1, 2, 3, 4].map((i) => `<rect x="34" y="${70 + i * 30}" width="${90 - i * 8}" height="10" rx="5" fill="#e3e6ea"/>`).join('')}
<rect x="176" y="52" width="284" height="228" rx="8" fill="#ffffff"/>${lines.map((l, i) => `<text x="194" y="${84 + i * 26}" font-size="13" fill="#4a505a">${l}</text>`).join('')}
<rect x="194" y="226" width="110" height="32" rx="7" fill="${accent}"/><text x="214" y="247" font-size="13" fill="#fff">Checkout</text></svg>`)}`;
const mockCards = {
  current: param('cards') === '0' ? [] : [
    { n: 3, src: shotSvg('Cart — storefront', '#2f6fde', ['Subtotal  $128.00', 'Shipping  Free', 'Total  $128.00']), kind: 'shot', text: L('The total doesn’t include tax', '合计没有算税'), session: S2, wall: now - 1500 },
    { n: 4, src: '', kind: 'voice', text: L('Move the promo code field above the total', '把优惠码输入框挪到合计上面'), session: S2, wall: now - 900 },
    { n: 5, src: shotSvg('Orders — admin', '#109478', ['#10482  Shipped', '#10481  Packing', '#10480  Refunded']), kind: 'shot', text: '', session: S2, wall: now - 300 },
  ],
  history: param('cards') === '0' ? [] : [
    { n: 1, src: shotSvg('Settings — mobile-app', '#7a5af5', ['Notifications  On', 'Language  English', 'Theme  System']), kind: 'shot', text: L('Theme picker is cut off on small phones', '小屏手机上主题选择被截断'), session: S2, wall: now - 90000, taken: now - 86000 },
  ],
};

// card_drop.rs drop_rows: the agents whose app gets a card's path and note (agents.json `drop`, Windows stems)
const MOCK_DROPS: [string, string, string[], 'composer' | 'terminal'][] = [
  ['codex', 'Codex', ['codex'], 'composer'], ['kimi', 'Kimi Code', ['kimi code'], 'composer'], ['workbuddy', 'WorkBuddy', ['workbuddy'], 'composer'],
  ['workbuddy-ai', 'WorkBuddy AI', ['workbuddy ai', 'workbuddyai'], 'composer'], ['cursor', 'Cursor', ['cursor'], 'terminal'], ['qoder', 'Qoder', ['qoder'], 'terminal'],
  ['qoderwork', 'QoderWork', ['qoderwork'], 'composer'], ['trae', 'Trae', ['trae'], 'terminal'], ['trae-cn', 'Trae CN', ['trae cn'], 'terminal'],
  ['windsurf', 'Windsurf', ['windsurf'], 'terminal'], ['kiro', 'Kiro', ['kiro'], 'terminal'], ['antigravity', 'Antigravity', ['antigravity'], 'terminal'],
  ['doubaowork', 'DoubaoWork', ['doubaowork'], 'composer'],
];
function mockAgentApps() {
  const off: Record<string, boolean> = mockCfg.record?.agent_drop ?? {};
  const mine: Record<string, any> = mockCfg.record?.agent_defs ?? {};
  return [
    ...MOCK_DROPS.map(([id, name, ids, drop]) => ({ id, name, ids, drop, on: off[id] !== false, custom: false })),
    ...Object.entries(mine).filter(([, d]) => d?.drop).map(([id, d]) => ({ id, name: d.name ?? id, ids: d.app?.windows ?? [id], drop: d.drop, on: off[id] !== false, custom: true })),
  ];
}
const mockStart = Date.now();
// Settings' writes, kept in memory (the Rust merge: two levels deep)
const mockHotkeys: Record<string, string> = {};
const mockCfg: Record<string, any> = { record: { agents: ['claude', 'codex', 'kimi'] }, notify: {} };
for (const c of (param('off') ?? '').split(',').filter((x) => CAP_IDS.includes(x))) {
  if (c === 'dictation') mockCfg.record.dictation = { enabled: false };
  else mockCfg.app = { ...(mockCfg.app ?? {}), capabilities: { ...(mockCfg.app?.capabilities ?? {}), [c]: false } };
}
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
/** dictation's choice in the browser mock: dictation_use / dictation_dashscope_model */
const mockDict: { use: string | null; ds: string | null } = { use: null, ds: null };
/** Linux: GNOME's screenshot permission (?shots=1: given before) */
const mockShots = { allowed: param('shots') === '1' };
let mdl: { id: string; done: number } | null = null;
// ?cloud=1: DeepSeek connected, polish and translate on it (the API id "deepseek-flash": Settings names it)
/** services connected in this mock session (cloud_connect) */
const mockServices: { id: string; preset: string; has_key: boolean; region?: string; base_url?: string; name?: string }[] = [
  ...(param('dashscope') === '1' ? [{ id: 'dashscope', preset: 'dashscope', has_key: true }] : []),
  ...(param('volc') === '1' ? [{ id: 'volcengine-speech', preset: 'volcengine-speech', has_key: true }] : []),
];
/** jobs put on a model in this mock session (cloud_job_set, cloud_custom_connect); null: Automatic */
const mockJobs: Record<string, { service: string; model: string } | null> = {};
/** record.cloud.jobs as Settings reads it back (the pop-up's value) */
const syncJobs = () => (mockCfg.record.cloud = { v: 2, jobs: Object.fromEntries(Object.entries(mockJobs).filter(([, x]) => x)) });
/** curated.json as the mock serves it */
const MOCK_CURATED: Record<string, { service: string; model: string; name: string }[]> = {
  polish: [{ service: 'dashscope', model: 'deepseek-v4.1-flash', name: 'DeepSeek V4.1 Flash' }, { service: 'deepseek', model: 'deepseek-flash', name: 'DeepSeek V4.1 Flash' }],
  translate: [{ service: 'dashscope', model: 'deepseek-v4.1-flash', name: 'DeepSeek V4.1 Flash' }, { service: 'deepseek', model: 'deepseek-flash', name: 'DeepSeek V4.1 Flash' }],
  vision: [{ service: 'dashscope', model: 'qwen3.6-flash', name: 'Qwen3.6 Flash' }, { service: 'deepseek', model: 'deepseek-flash', name: 'DeepSeek V4.1 Flash' }],
  speech: [{ service: 'dashscope', model: 'qwen3-asr-flash', name: 'Qwen3-ASR Flash' }, { service: 'dashscope', model: 'qwen-audio-3.1-asr-flash', name: 'Qwen Audio 3.1 ASR' }, { service: 'volcengine-speech', model: 'volcengine-seedasr', name: 'Doubao Seed-ASR 2.0' }],
};
const cloudSum = () => {
  const base = param('cloud') === '1'
    ? { services: [{ id: 'deepseek', preset: 'deepseek', has_key: true }, ...mockServices], routes: { polish: { service: 'deepseek', model: 'deepseek-flash' }, translate: null, vision: null } as Record<string, { service: string; model: string } | null> }
    : { services: [...mockServices], routes: { polish: null, translate: null, vision: null } as Record<string, { service: string; model: string } | null> };
  for (const [j, r] of Object.entries(mockJobs)) if (r) base.routes[j] = r;
  // a job left on Automatic runs on the first connected service Blurt measured for it (cloud.rs `route`)
  for (const j of ['polish', 'translate', 'vision']) {
    if (base.routes[j] || mockJobs[j] || (j === 'translate' && base.routes.polish)) continue; // translate follows polish
    const o = MOCK_CURATED[j].map((x) => ({ x, s: base.services.find((s) => s.preset === x.service && s.has_key) })).find((y) => y.s);
    if (o) base.routes[j] = { service: o.s!.id, model: o.x.model };
  }
  return base;
};
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
// recognised, one cancelled, one turned into an item; ?dictations=0 for the empty page
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
  dEntry('d-5', 3.1, 'WINWORD', '', '', { reason: 'asr_failed:asr_slow', insert: 'none', polished: null, model: null, duration: 12 }),
  // cancelled (Esc), its recording kept: the Dictation page offers Retry; Home and the tray never do
  dEntry('d-8', 3.3, 'Code', '', '', { reason: 'asr_failed:cancelled', insert: 'none', polished: null, model: null, duration: 4 }),
  dEntry('d-6', 26, 'Teams', L('lets move standup to ten thirty tomorrow', '明天站会改到十点半吧'), L('Let’s move stand-up to 10:30 tomorrow.', '明天站会改到 10:30 吧。'), { corrected: L('Let’s move stand-up to 10:30 tomorrow, not 10.', '明天站会改到 10:30 吧，不是 10 点。') }),
  dEntry('d-7', 30, 'Notion', L('three things for the launch one the press kit two the demo video three the faq', '发布要准备三件事 一是新闻稿 二是演示视频 三是常见问题'), L('Three things for the launch:\n1. The press kit\n2. The demo video\n3. The FAQ', '发布要准备三件事：\n1. 新闻稿\n2. 演示视频\n3. 常见问题'), { style: 'structured' }),
];

// Settings → Phone (remote.rs): Add Phone… shows a code good for two minutes (?phone_code=<seconds> to watch it run
// out sooner); a few seconds later a phone uses it over the relay and asks with six digits (?phone_scan=0: nobody
// scans); Allow pairs it and it connects over the relay, then finds a direct path. ?phone= paired | asking | nocontrol |
// problem | fromphone | relayfail | firewall starts there instead of with no phone (firewall: Windows Firewall keeps phones
// out; Allow… says yes for the administrator a moment later).
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
  firewall: 'ok' | 'blocked' | 'unknown';
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
  firewall: phoneStart === 'firewall' ? 'blocked' : 'ok',
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
    case 'remote_allow_firewall':
      // Windows' administrator prompt, answered yes
      return new Promise((ok) =>
        setTimeout(() => {
          remote.firewall = 'ok';
          remoteChanged();
          ok(remoteNow());
        }, 1200),
      );
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

Either way, give it a secret path as README.md says: a random RELAY_SECRET (openssl rand -hex 16), so strangers who find the host can't use it. Don't put the secret in a DNS name.

If I'm in mainland China, prefer a server there: the round trip is far shorter. A domain served from a mainland server needs an ICP filing.

Don't change anything else on the server or the domain, and ask before opening a port or spending money. Keep credentials out of anything you print.

When it's up, run \`node test.mjs <address>\` from that folder and check it passes. Then tell me the one address with its secret, like wss://relay.example.com/<secret>, and that it goes in Blurt → Settings → Phone → Relay Address. Reply in the language I'm writing in.`;

export async function mockInvoke<T>(cmd: string, args: Record<string, any> = {}): Promise<T> {
  if (cmd.startsWith('remote_')) return (await mockRemote(cmd, args)) as T;
  const r = (v: unknown) => v as T;
  switch (cmd) {
    case 'app_status':
      return r({ version: '0.7.0', os: param('platform') === 'win' ? 'windows' : 'linux', platform: param('platform') === 'win' ? 'win' : 'gnome', wayland: false, lang: param('lang') ?? navigator.language, blurt_home: `${H}/.blurt`, inbox_store: `${H}/Blurt/inbox`,
        handoff_dir: `${H}/.blurt/handoff`, index_ready: true, scripts: `${H}/.claude/skills/blurt/scripts`, uv: '/usr/bin/uv', capture: { recording: false, paused: false, session: null, voice: null }, hotkey_mode: param('platform') === 'win' ? 'plugin' : 'portal',
        // Linux: dictation and Copy Text built; ?keys=evdev for the input-group mode, else the portal's Menu key
        features: { dictation: true, screen_text: true },
        dictation_keys: param('platform') === 'win' ? 'hook' : param('keys') === 'evdev' ? 'evdev' : 'portal', dictation_key: param('platform') === 'win' ? null : 'Menu',
        start_view: param('view') });
    case 'cards_waiting':
      return r(mockOff().includes('cards') ? 0 : Number(param('cards') ?? mockCards.current.length));
    case 'capabilities_get':
      return r({ off: mockOff() });
    case 'capability_set':
      mockSetCapability(args.id, !!args.on);
      return r({ off: mockOff() });
    case 'cards_list':
      return r(mockOff().includes('cards') ? { current: [], history: [] } : JSON.parse(JSON.stringify(mockCards)));
    case 'card_action': {
      const all = [...mockCards.current, ...mockCards.history];
      const c = all.find((x) => x.n === args.n);
      if (c && args.action === 'remove') {
        mockCards.current = mockCards.current.filter((x) => x !== c);
        mockCards.history = mockCards.history.filter((x) => x !== c);
        emit('cards://changed', { count: mockCards.current.length });
      }
      return r(undefined);
    }
    case 'cards_reveal':
      return r(undefined);
    case 'translate_auto_pair': {
      // ?pair=ja (a Japanese user), ?pair=en (English only: no pair); else the page's language
      const home = param('pair') ?? (zh() ? 'zh' : 'en');
      return r({ home, other: home === 'en' ? null : 'en' });
    }
    case 'screen_text_history': {
      const days = Number(mockCfg.record?.screen_text?.history_days ?? 30);
      const entries = days === 0 ? [] : mockScreenText.filter((e) => days < 0 || e.time > now - days * 86400);
      return r({ entries: JSON.parse(JSON.stringify(entries)), days, count: entries.length });
    }
    case 'screen_text_history_delete':
      mockScreenText = mockScreenText.filter((e) => !(args.ids as string[]).includes(e.id));
      emit('screen-text://changed', {});
      return r(undefined);
    case 'screen_text_history_clear':
      mockScreenText = [];
      emit('screen-text://changed', {});
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
        ...recJobs.filter((j) => !(args.active && j.state === 'failed')),
      ]);
    case 'recordings_list':
      return r(mockRecordings());
    case 'session_process': {
      const was = recJobs.findIndex((j) => j.session === args.dir);
      const job = { id: `j-mock-${recJobs.length}`, type: 'process', state: 'running', project: null, session: args.dir, title: null, items: [], steps: [{ id: 'prepare', state: 'running' }, { id: 'write', state: 'pending' }], progress: null, created: '2026-10-22T12:00:00+02:00', started: '2026-10-22T12:00:00+02:00', ended: null, error: null };
      if (was >= 0) recJobs.splice(was, 1);
      recJobs.push(job);
      emit('jobs://changed', []);
      return r(undefined);
    }
    case 'job_dismiss': {
      const j = recJobs.find((x) => x.id === args.id);
      if (j) j.dismissed = true;
      emit('jobs://changed', []);
      return r(undefined);
    }
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
    // drops on the main window (drag-drop.md §4): nothing to attach to in the browser preview
    case 'items_attach':
      return r({
        ok: true,
        before: { frames: null, attachments: null, details: null },
        added: args.restore ? {} : { frames: args.frames ?? [], attachments: args.files ?? [], ...(args.text ? { details: args.text } : {}) },
      });
    case 'cards_attach':
      return r({ ok: true, before: { frames: null, attachments: null, details: null }, added: { frames: (args.cards ?? []).map(() => '/tmp/card.png') } });
    // Ctrl+V: the browser preview reads no system clipboard — the page's own paste data is used
    case 'clipboard_things':
      return Promise.reject(new Error('no native clipboard in the browser preview'));
    case 'drag_log':
      (window as unknown as { __dragLog?: unknown[] }).__dragLog = [...((window as unknown as { __dragLog?: unknown[] }).__dragLog ?? []), args.event];
      return r(null);
    case 'review_file':
      return r(args.open ? 'opened' : 'revealed');
    case 'items_add_files':
      return r({ ok: true, before: { frames: null, attachments: null, details: null }, added: { frames: ['/tmp/picked.png'], attachments: ['/Users/me/Documents/spec.pdf'] } });
    case 'cards_dragging':
      return r(null);
    case 'drop_paths':
      return r((args.paths ?? []).map((p: string) => ({ path: p, dir: false })));
    case 'cards_file':
    case 'cards_put_back':
      return r(null);
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
    case 'agents_detect': {
      // as agents.py detect: order = record.agents (else every headless agent); without ids only that order is listed.
      // ?agents=none: no command-line agent (the Windows user who reported "录屏之后啥也没有")
      const noCli = param('agents') === 'none';
      const t = Math.floor(Date.now() / 1000);
      const cli = (id: string, name: string, version: string, conn: string, extra: Record<string, unknown> = {}) => noCli
        ? { id, name, path: null, state: 'not_installed', why: '', fix: '', installed: false, version: null, login: 'n/a', headless: true, interactive: 'terminal', conn: 'missing', connect: true, found: false, linked: false, last_seen: null }
        : { id, name, path: `/usr/bin/${id}`, state: 'ready', why: '', fix: '', installed: true, version, login: 'ok', headless: true, interactive: 'terminal', conn, connect: true, found: true, linked: conn !== 'found', last_seen: conn === 'connected' ? t - 3600 : null, ...extra };
      const app = (id: string, name: string, conn: string, extra: Record<string, unknown> = {}) => ({ id, name, path: conn === 'missing' ? null : `/opt/${name}/${id}`, state: conn === 'missing' ? 'not_installed' : 'unknown', why: '', fix: '', installed: conn !== 'missing', version: null, login: 'n/a', headless: false, interactive: null, conn, connect: true, found: conn !== 'missing', linked: conn === 'linked' || conn === 'connected', last_seen: conn === 'connected' ? t - 86400 * 2 : null, ...extra });
      const custom = Object.entries(mockCfg.record?.agent_defs ?? {}).filter(([, d]: [string, any]) => d?.custom && d.connect !== false).map(([id, d]: [string, any]) => app(id, d.name ?? id, 'missing', { custom: true }));
      const all = [
        cli('claude', 'Claude Code', '2.3.1', 'connected'),
        cli('codex', 'Codex', '0.61.0', 'linked'),
        { id: 'kimi', name: 'Kimi Code', path: null, state: 'not_installed', why: '', fix: 'npm i -g kimi-code', installed: false, version: null, login: 'n/a', headless: true, interactive: 'terminal', conn: 'missing', connect: true, found: false, linked: false, last_seen: null },
        app('workbuddy', 'WorkBuddy', 'found', { edition: zh() ? '国内版' : 'China' }),
        app('workbuddy-ai', 'WorkBuddy AI', 'missing', { edition: zh() ? '国际版' : 'International' }),
        app('cursor', 'Cursor', 'connected'),
        app('trae', 'Trae', 'linked'),
        app('kiro', 'Kiro', 'missing'),
        ...custom,
      ];
      if (args.login !== false) await new Promise((ok) => setTimeout(ok, 2500)); // the full check takes a while
      const want = mockCfg.record?.agents as string[] | null | undefined;
      const order = want?.length ? want : all.filter((a) => a.headless).map((a) => a.id);
      const ids: string[] = args.ids ?? order;
      const agents = all.filter((a) => ids.includes(a.id) || !a.headless);
      // ?agents=none: none can organise in the background (a Windows computer with no agent CLI)
      if (param('agents') === 'none') return r({ order, pick: null, agents: agents.map((a) => (a.headless ? { ...a, state: 'not_installed', installed: false, path: null } : a)) });
      return r({ order, pick: order.find((id) => agents.some((a) => a.id === id && a.state === 'ready')) ?? null, agents });
    }
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
    case 'settings_set': {
      const before = mockOff().join();
      mockMerge(args.patch ?? {});
      if (mockOff().join() !== before) emit('capabilities://changed', { off: mockOff() });
      return r(mockCfg);
    }
    case 'asr_models':
      return r({ models: [{ id: 'sensevoice-small', name: 'SenseVoice Small', backend: 'sherpa-onnx', installed: true, size_mb: 228, languages: ['zh', 'en', 'ja', 'ko', 'yue'] }, { id: 'whisper-large-v3-turbo-ct2', name: 'Whisper large-v3 turbo', backend: 'faster-whisper', installed: false, size_mb: 1620, languages: 'multi' }] });
    case 'dictation_models':
      if (param('uv') === 'failed' && !onb.uvRetried) throw new Error('uv not found');
    {
      // ?dashscope=1 (or connected here): Model Studio's recogniser is a dictation choice (dictation_dashscope_model);
      // ?weak=1: a PC the CPU rules give SenseVoice (dictation_models `weak`); ?localasr=1: cloud recognition not allowed
      const weak = param('weak') === '1';
      // ?volc=1 (or connected here): Volcengine Speech's Seed-ASR likewise (dictation_use)
      const ds = mockServices.some((s) => s.preset === 'dashscope');
      const volc = mockServices.some((s) => s.preset === 'volcengine-speech');
      const rec = weak ? 'sensevoice-small' : 'fun-asr-nano-onnx';
      const clouds = [...(ds ? ['qwen3-asr-flash'] : []), ...(volc ? ['volcengine-seedasr'] : [])];
      // a cloud recogniser whose service was removed: back on the local model
      if (mockDict.use && ['qwen3-asr-flash', 'volcengine-seedasr'].includes(mockDict.use) && !clouds.includes(mockDict.use)) mockDict.use = null;
      const sel = mockDict.use ?? [rec, 'fun-asr-nano-onnx', 'sensevoice-small'].find((m) => modelsIn.has(m)) ?? rec;
      const onCloud = clouds.includes(sel);
      return r({ recommended: rec, selected: sel, selected_cloud: onCloud, weak, cloud_allowed: param('localasr') !== '1',
        ready: modelsIn.has(rec) || onCloud, downloading: mdl?.id ?? null, dashscope_model: mockDict.ds,
        models: [{ id: 'fun-asr-nano-onnx', name: 'Fun-ASR-Nano (CPU)', size_mb: 950, installed: modelsIn.has('fun-asr-nano-onnx'), recommended: rec === 'fun-asr-nano-onnx' }, { id: 'sensevoice-small', name: 'SenseVoice Small', size_mb: 228, installed: modelsIn.has('sensevoice-small'), recommended: rec === 'sensevoice-small' },
          ...(ds ? [{ id: 'qwen3-asr-flash', name: 'Qwen3-ASR Flash', size_mb: 0, installed: true, recommended: false }] : []),
          ...(volc ? [{ id: 'volcengine-seedasr', name: 'Doubao Seed-ASR 2.0', size_mb: 0, installed: true, recommended: false }] : [])] });
    }
    case 'dictation_use':
      mockDict.use = args.id ?? null;
      return r(undefined);
    case 'screen_text_allowed':
      return r(mockShots.allowed);
    case 'screen_text_allow':
      // ?shots=deny: the user says no in GNOME's dialog
      await new Promise((ok) => setTimeout(ok, 800));
      mockShots.allowed = param('shots') !== 'deny';
      return r(mockShots.allowed ? { ok: true } : { ok: false, code: 'denied' });
    case 'dictation_dashscope_model':
      mockDict.use = 'qwen3-asr-flash';
      mockDict.ds = args.model ?? null;
      return r(undefined);
    case 'model_download':
      if (mdl) throw new Error('a download is already running');
      mockDownload(args.id);
      return r(undefined);
    // the Welcome (onboarding.rs): ?view=welcome or ?welcome=1 shows it; ?dictation=0 is Linux (no dictation steps);
    // ?mic=denied|none, ?uv=failed for the other states
    case 'onboarding_get':
      return r({ ...onb, uv: param('uv') !== 'failed' || onb.uvRetried, uv_state: param('uv') === 'failed' && !onb.uvRetried ? 'failed' : 'done', first_download_pending: false,
        dictation: { available: param('dictation') !== '0', key: 'right_option', mode: 'auto', enabled: !mockOff().includes('dictation') }, off: mockOff() });
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
    case 'cloud_disconnect': {
      const i = mockServices.findIndex((x) => x.id === args.id);
      if (i >= 0) mockServices.splice(i, 1);
      for (const [j, x] of Object.entries(mockJobs)) if (x?.service === args.id) mockJobs[j] = null;
      syncJobs();
      return r(cloudSum());
    }
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
    // Storage → Data location (location.rs); ?location=custom starts on a chosen folder, ?location_error=<code> refuses
    // Settings → General → Cards → Agents… (island.rs agent_apps_*: card_drop.rs `listing` / `changing`)
    case 'agent_apps_get':
      return r(mockAgentApps());
    case 'agent_apps_set': {
      const id = String(args.id).trim().toLowerCase();
      const off: Record<string, boolean> = { ...(mockCfg.record?.agent_drop ?? {}) };
      const mine: Record<string, any> = { ...(mockCfg.record?.agent_defs ?? {}) };
      if (args.op === 'off') off[id] = false;
      else if (args.op === 'on') delete off[id];
      else if (args.op === 'add') mine[id] = { name: id, bins: [], headless: false, custom: true, connect: false, app: { windows: [id] }, drop: 'terminal' };
      else if (args.op === 'remove') delete mine[id];
      mockMerge({ record: { agent_drop: Object.keys(off).length ? off : null, agent_defs: Object.keys(mine).length ? mine : null } });
      return r(mockAgentApps());
    }
    case 'agent_apps_pick':
      return r({ ids: ['zed'] });
    case 'storage_location':
      return r({ ...mockLocation });
    case 'storage_location_pick':
    case 'storage_location_check': {
      const to = cmd === 'storage_location_pick' ? '/media/maya/Data/Blurt' : (args.folder as string | null);
      const err = param('location_error');
      return r(err ? { ok: false, error: err, folder: to, bytes: 3_820_000_000, free: 1_200_000_000 } : { ok: true, folder: to, home: to ? `${to}/.blurt` : `${H}/.blurt`, workspace: to ?? `${H}/Blurt`, bytes: 3_820_000_000, free: 214_000_000_000, redownload: !!to });
    }
    case 'storage_location_move': {
      const to = args.folder as string | null;
      const total = 3_820_000_000;
      mockLocation.moving = true;
      let done = 0;
      const t = setInterval(() => {
        done = Math.min(total, done + total / 12);
        emit('storage://move', { phase: 'copy', done, total });
        if (done >= total) {
          clearInterval(t);
          emit('storage://move', { phase: 'restart' }); // the real app restarts here (?location=custom shows after)
        }
      }, 250);
      return r({ ok: true, folder: to, bytes: total });
    }
    case 'cloud_curated':
      return r({ jobs: MOCK_CURATED });
    case 'cloud_job_set':
      mockJobs[args.job] = args.service ? { service: args.service, model: args.model ?? '' } : null;
      syncJobs();
      return r(cloudSum());
    case 'asr_auto_apply':
      return r({ ok: true });
    case 'agents_registry':
      return r({ agents: [
        { id: 'claude', name: 'Claude Code', fix: { en: 'run `claude` in a terminal and /login', zh: '在终端运行 claude，然后输入 /login' }, install: { en: 'npm i -g @anthropic-ai/claude-code', zh: 'npm i -g @anthropic-ai/claude-code' }, processing: { recording: { model: 'default', effort: 'low' }, cards: { model: 'cheapest', effort: 'low' } } },
        { id: 'codex', name: 'Codex', fix: { en: 'run `codex login`', zh: '运行 codex login' }, install: { en: 'npm i -g @openai/codex', zh: 'npm i -g @openai/codex' } },
        { id: 'kimi', name: 'Kimi Code', install: { en: 'npm i -g kimi-code', zh: 'npm i -g kimi-code' } },
        { id: 'workbuddy', name: 'WorkBuddy', headless: false, site: 'https://www.codebuddy.cn/work/', install: { en: 'see codebuddy.cn/work', zh: '见 codebuddy.cn/work' }, edition: { zh: '国内版', en: 'China' },
          after: { zh: '在 WorkBuddy 里打开 连接器 → blurt，点「信任」，然后新开一个对话。', en: 'In WorkBuddy, open Connectors → blurt, click Trust, then start a new chat.' } },
        { id: 'workbuddy-ai', name: 'WorkBuddy AI', headless: false, site: 'https://www.workbuddy.ai/', install: { en: 'see workbuddy.ai', zh: '见 workbuddy.ai' }, edition: { zh: '国际版', en: 'International' },
          after: { zh: '在 WorkBuddy AI 里打开 连接器 → blurt，点「信任」，然后新开一个对话。', en: 'In WorkBuddy AI, open Connectors → blurt, click Trust, then start a new chat.' } },
        { id: 'cursor', name: 'Cursor', headless: false, site: 'https://cursor.com', install: { en: 'see cursor.com', zh: '见 cursor.com' } },
        { id: 'trae', name: 'Trae', headless: false, site: 'https://www.trae.ai', install: { en: 'see trae.ai', zh: '见 trae.ai' } },
        { id: 'kiro', name: 'Kiro', headless: false, site: 'https://kiro.dev', install: { en: 'see kiro.dev', zh: '见 kiro.dev' } },
      ], failures: [{ id: 'auth', reason: { en: '{name} isn’t signed in: {fix}', zh: '{name} 没有登录：{fix}' } }] });
    case 'agents_install':
      return r(args.dryRun
        ? { ok: true, changes: args.id === 'claude' ? [{ action: 'exists', path: `${H}/.claude/skills/blurt` }, { action: 'exists', argv: ['claude', 'mcp', 'get', 'blurt'] }] : [{ action: 'symlink', path: `${H}/.codex/skills/blurt`, target: `${H}/.claude/skills/blurt` }, { action: 'run', argv: ['codex', 'mcp', 'add', 'blurt', '--', 'uv', 'run', 'mcp_server.py'] }] }
        : { ok: true, applied: true, changes: [{ action: 'symlink', ok: true, path: `${H}/.codex/skills/blurt`, target: `${H}/.claude/skills/blurt` }, { action: 'run', ok: true, argv: ['codex', 'mcp', 'add', 'blurt'] }] });
    case 'agents_manual': {
      const uv = `${H}/.blurt/bin/uv`, server = `${H}/.blurt/skill/scripts/mcp_server.py`, skill = `${H}/.blurt/skill`;
      const args = ['run', '--script', server];
      return r({ ok: true, skill, skill_ok: true, server, command: uv, args, mcp_json: JSON.stringify({ mcpServers: { blurt: { command: uv, args } } }, null, 2),
        prompt: zh() ? `请为你自己装上口喷鸡（Blurt）。口喷鸡的 skill 是文件夹 ${skill}（里面有 SKILL.md）：把它链接或复制到你自己的 skills 文件夹，名字叫 blurt。再添加一个名为 blurt 的 MCP 服务器，命令是 ${uv}，参数是 run --script ${server}。两样都装好后，调用 blurt 的 MCP 工具 hello 检查连接，并告诉我你改了哪些设置。`
          : `Set up Blurt for yourself. The Blurt skill is the folder ${skill} (SKILL.md is in it): link or copy it into your own skills folder under the name blurt. Then add an MCP server named blurt that runs ${uv} with the arguments run --script ${server}. When both are in place, call the blurt MCP tool hello to check the connection, and tell me what you changed.` });
    }
    case 'agents_custom': {
      const mine: Record<string, any> = { ...(mockCfg.record?.agent_defs ?? {}) };
      if (args.remove) delete mine[args.remove];
      const id = args.remove ? undefined : String(args.name).trim().toLowerCase().replace(/[^\p{L}\p{N}_]+/gu, '-');
      if (id) mine[id] = { name: String(args.name).trim(), bins: [], headless: false, custom: true };
      mockMerge({ record: { agent_defs: Object.keys(mine).length ? mine : null } });
      return r({ ok: true, id });
    }
    case 'mcp_clients':
      // ?hello=1: a new client said hello a few seconds after the sheet opened (Test turns to "Connected")
      return r(param('hello') === '1' && Date.now() - mockStart > 4000 ? { 'my-agent': { at: Date.now() / 1000 } } : {});
    case 'skill_zip':
      return r({ path: `${H}/Downloads/blurt-skill.zip` });
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
    case 'cloud_connect':
      await new Promise((ok) => setTimeout(ok, 600));
      if (String(args.key).length < 8) return r({ ok: false, code: 'auth' });
      if (!mockServices.some((s) => s.preset === args.preset)) mockServices.push({ id: args.preset, preset: args.preset, has_key: true });
      return r({ ok: true, summary: cloudSum() });
    // Advanced → Custom Model… and Add Cloud Model's other services (`jobs`, checked in turn): a key under 8 characters
    // is refused, a model id with "nope" in it isn't found, one with "text" in it reads no pictures (Copy Text fails)
    case 'cloud_custom_connect': {
      await new Promise((ok) => setTimeout(ok, 900));
      const own = mockServices.find((x) => x.id === args.service);
      if (!own && !args.service && String(args.preset).startsWith('custom') && !/^https:\/\//.test(String(args.baseUrl ?? ''))) return r({ ok: false, code: 'address' });
      if (!String(args.model).trim()) return r({ ok: false, code: 'model_id' });
      if (!args.service && String(args.key).trim().length < 8) return r({ ok: false, code: String(args.key).trim() ? 'auth' : 'no_key' });
      const jobs: string[] = args.jobs ?? [args.job];
      if (/nope/.test(String(args.model))) return r({ ok: false, code: 'model', ...(args.jobs ? { job: jobs[0] } : {}) });
      if (/text/.test(String(args.model)) && jobs.includes('vision')) return r({ ok: false, code: 'vision', ...(args.jobs ? { job: 'vision' } : {}) });
      let id = args.service as string | null;
      if (!id) {
        const custom = String(args.preset).startsWith('custom');
        const taken = new Set(mockServices.map((x) => x.id));
        id = custom ? 'custom-1' : args.preset;
        for (let n = 2; taken.has(id!); n++) id = custom ? `custom-${n}` : `${args.preset}-${n}`;
        mockServices.push({ id: id!, preset: args.preset, has_key: true, ...(args.region ? { region: args.region } : {}), ...(args.baseUrl ? { base_url: args.baseUrl } : {}), ...(args.name ? { name: args.name } : {}) });
      }
      for (const j of jobs) mockJobs[j] = { service: id!, model: String(args.model).trim() };
      syncJobs();
      return r({ ok: true, ms: 820, service: id, summary: cloudSum() });
    }
    case 'cloud_connect_speech':
      await new Promise((ok) => setTimeout(ok, 600));
      if (String(args.token).length < 8) return r({ ok: false, code: 'auth' });
      if (!mockServices.some((s) => s.preset === 'volcengine-speech')) mockServices.push({ id: 'volcengine-speech', preset: 'volcengine-speech', has_key: true });
      return r({ ok: true, ms: 480, summary: cloudSum() });
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
