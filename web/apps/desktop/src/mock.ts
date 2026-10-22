// In-browser stand-in for the Rust commands (vite dev, UI screenshots, unit tests): a small fixed world — three
// projects, a dozen items in every K3 state, a batch to review, an agent session waiting for an answer, a
// terminal that prints what Claude Code would. Writes are kept in memory.
import { INBOX_STATES, migrate, OPEN_STATES, targetOf, type State } from '@blurt/ui';

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

const projects = () => [
  { id: 'p1', name: 'storefront', key: 'SF', slug: 'storefront', path: `${H}/code/storefront`, store: `${H}/code/storefront/.blurt`, kind: 'repo', exists: true, worktree: true, last_used: '2026-10-22T09:40:00+02:00', ...counts('p1') },
  { id: 'p2', name: 'mobile-app', key: 'MA', slug: 'mobile-app', path: `${H}/code/mobile-app`, store: `${H}/code/mobile-app/.blurt`, kind: 'repo', exists: true, worktree: true, last_used: '2026-10-21T17:10:00+02:00', ...counts('p2') },
  { id: 'p3', name: L('Launch notes', '发布笔记'), key: 'LN', slug: 'launch-notes', path: `${H}/Documents/Launch notes`, store: `${H}/Documents/Launch notes/.blurt`, kind: 'folder', exists: true, worktree: false, last_used: '2026-10-20T11:00:00+02:00', ...counts('p3') },
];
const inbox = () => ({ id: 'inbox', name: L('Unassigned', '待分配'), key: 'IN', slug: 'inbox', path: `${H}/Blurt/inbox`, store: `${H}/Blurt/inbox`, kind: 'inbox', exists: true, ...counts('inbox') });

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
  { uid: 'u04', id: 'SF-9', project: 'p1', kind: 'issue', title: L('Avatar upload returns 500', '头像上传返回 500'), state: 'in_progress', work_to: 'session', work_agent: 'claude', severity: 'high', age: 2 },
  { uid: 'u05', id: 'SF-10', project: 'p1', kind: 'task', title: L('Translate the checkout emails into German', '把结算邮件翻译成德语'), state: 'handed_off', work_to: 'external', age: 5 },
  { uid: 'u06', id: 'SF-7', project: 'p1', kind: 'issue', title: L('Search results flicker while typing', '输入时搜索结果闪烁'), state: 'to_verify', work_agent: 'codex', severity: 'medium', age: 20 },
  { uid: 'u07', id: 'SF-5', project: 'p1', kind: 'note', title: L('Competitors all show stock levels', '竞品都显示库存数量'), state: 'todo', age: 48 },
  { uid: 'u08', id: 'SF-3', project: 'p1', kind: 'issue', title: L('Footer links overlap on small phones', '小屏手机上页脚链接重叠'), state: 'done', severity: 'low', age: 90 },
  { uid: 'u09', id: 'SF-2', project: 'p1', kind: 'idea', title: L('Dark mode for the storefront', '商店的深色模式'), state: 'wontfix', age: 120 },
  { uid: 'u10', id: 'MA-4', project: 'p2', kind: 'issue', title: L('Onboarding skips the notifications step', '新手引导跳过了通知那一步'), state: 'new', severity: 'medium', age: 7 },
  { uid: 'u11', id: 'MA-3', project: 'p2', kind: 'task', title: L('Ship the iPad layout', '上线 iPad 布局'), state: 'in_progress', work_to: 'session', work_agent: 'codex', age: 26 },
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

const sessions = () => [
  { job: 'j-20261022-094100-k2m4', project: 'p1', agent: 'claude', items: ['u04'], window: 'SF-9', status: 'waiting_input', status_at: '2026-10-22T09:52:00+02:00', worktree: `${H}/code/.storefront-worktrees/SF-9`, branch: 'blurt/sf-9-avatar-upload', cwd: `${H}/code/.storefront-worktrees/SF-9`, started: new Date((now - 1500) * 1000).toISOString(), ended: null, exit: null },
  { job: 'j-20261021-161000-a7q2', project: 'p2', agent: 'codex', items: ['u11'], window: 'MA-3', status: 'running', status_at: null, worktree: null, branch: null, cwd: `${H}/code/mobile-app`, started: new Date((now - 7200) * 1000).toISOString(), ended: null, exit: null },
];

const TERM = [
  '\x1b[38;5;209m╭─────────────────────────────────────────────────────────╮\x1b[0m\r\n',
  '\x1b[38;5;209m│\x1b[0m \x1b[1m\u273b Claude Code\x1b[0m                                            \x1b[38;5;209m│\x1b[0m\r\n',
  '\x1b[38;5;209m│\x1b[0m   cwd: ~/code/.storefront-worktrees/SF-9                \x1b[38;5;209m│\x1b[0m\r\n',
  '\x1b[38;5;209m╰─────────────────────────────────────────────────────────╯\x1b[0m\r\n\r\n',
  '\x1b[2m> Read /home/maya/.blurt/handoff/H-0031.md and handle the item in it.\x1b[0m\r\n\r\n',
  '\x1b[1m\u25cf\x1b[0m Reading the hand-off sheet and the avatar upload handler.\r\n\r\n',
  '\x1b[32m\u25cf\x1b[0m \x1b[1mRead\x1b[0m(api/avatar.py)\r\n  \u23bf  Read 142 lines\r\n\r\n',
  '\x1b[1m\u25cf\x1b[0m The multipart boundary is parsed before the size check, so a 6 MB PNG\r\n  overflows the 5 MB buffer and raises. I\'ll stream it instead.\r\n\r\n',
  '\x1b[33m\u25cf\x1b[0m \x1b[1mEdit\x1b[0m(api/avatar.py)\r\n',
  '\x1b[48;5;236m Do you want to make this edit to avatar.py?                \x1b[0m\r\n',
  '\x1b[48;5;236m \u276f 1. Yes                                                  \x1b[0m\r\n',
  '\x1b[48;5;236m   2. Yes, and don\'t ask again this session                \x1b[0m\r\n',
  '\x1b[48;5;236m   3. No, and tell Claude what to do differently (esc)      \x1b[0m\r\n',
];

const hotkeyRows = () =>
  ['record', 'snap', 'voice', 'project', 'menu', 'pause', 'marker', 'stop', 'pen'].map((a) => {
    const k = ({ record: 'R', snap: 'A', voice: 'V', project: 'O', menu: 'B', pause: 'P', marker: 'M', stop: 'S', pen: 'D' } as Record<string, string>)[a];
    const resident = ['record', 'snap', 'voice', 'project', 'menu'].includes(a);
    return { action: a, spec: `opt+shift+${k}`, label: `Alt+Shift+${k}`, default: `opt+shift+${k}`, active: resident, result: a === 'pen' ? 'unsupported' : resident ? 'ok' : 'idle' };
  });

/** K3 in memory: discarded remembers where it was */
function setState(it: MItem, to: State | null | undefined) {
  if (!to) return;
  const from = migrate(it).state;
  it.restore_to = to === 'discarded' ? from : undefined;
  it.state = to;
}

let current = 'p1';
let ptySeq = 0;

export async function mockInvoke<T>(cmd: string, args: Record<string, any> = {}): Promise<T> {
  const r = (v: unknown) => v as T;
  switch (cmd) {
    case 'app_status':
      return r({ version: '0.7.0', os: 'linux', platform: 'gnome', wayland: false, lang: param('lang') ?? navigator.language, blurt_home: `${H}/.blurt`, inbox_store: `${H}/Blurt/inbox`,
        handoff_dir: `${H}/.blurt/handoff`, index_ready: true, scripts: `${H}/.claude/skills/blurt/scripts`, uv: '/usr/bin/uv', tmux: true, capture: { recording: false, paused: false, session: null, voice: null }, hotkey_mode: 'plugin',
        start_view: param('view') });
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
        open: n(OPEN_STATES), unassigned: live.filter((i) => i.project === 'inbox').length, batches: 2 });
    }
    case 'jobs_list':
      return r([
        { id: 'j-20261022-101800-p9x2', type: 'process', state: 'running', project: null, session: S2, title: L('Two screenshots and a voice note', '两张截图和一条语音'), items: [], steps: [{ id: 'prepare', state: 'done' }, { id: 'transcribe', state: 'done' }, { id: 'write', state: 'running', progress: 0.6 }, { id: 'frames', state: 'pending' }, { id: 'route', state: 'pending' }], progress: 0.6, created: '', started: '', ended: null, error: null },
        { id: sessions()[0].job, type: 'agent', state: 'running', project: 'p1', session: null, title: null, items: ['u04'], steps: [], progress: null, created: '', started: '', ended: null, error: null, agent: { id: 'claude', mode: 'together', runner: 'tmux', status: 'waiting_input', cwd: '' } },
      ]);
    case 'index_query': {
      const q = args.q ?? {};
      let list = items.filter((x) => (q.state?.length ? q.state.includes(x.state) : x.state !== 'discarded'));
      if (q.kind?.length) list = list.filter((x) => q.kind.includes(x.kind));
      if (q.project) list = list.filter((x) => x.project === q.project);
      for (const term of (q.query ?? '').toLowerCase().split(/\s+/).filter(Boolean)) list = list.filter((x) => (x.title + (x.quote ?? '')).toLowerCase().includes(term));
      list = [...list].sort((a, b) => a.age - b.age);
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
      return r({ ok: true });
    case 'handoff_create':
      return r({ id: 'H-0032', path: `${H}/.blurt/handoff/H-0032.md`, text: 'Please handle SF-12 — details and screenshots are in …' });
    case 'agents_detect':
      return r({ order: ['claude', 'codex', 'kimi'], pick: 'claude', agents: [
        { id: 'claude', name: 'Claude Code', path: '/usr/bin/claude', state: 'ready', why: '', fix: '', installed: true, version: '2.3.1', login: 'ok', headless: true, interactive: 'terminal', session: true },
        { id: 'codex', name: 'Codex', path: '/usr/bin/codex', state: 'ready', why: '', fix: '', installed: true, version: '0.61.0', login: 'ok', headless: true, interactive: 'terminal', session: true },
        { id: 'kimi', name: 'Kimi Code', path: null, state: 'not_installed', why: '', fix: 'npm i -g kimi-code', installed: false, version: null, login: 'n/a', headless: true, interactive: 'terminal', session: true },
      ] });
    case 'sessions_dispatch':
      if (args.opts?.dryRun)
        return r({ ok: true, jobs: [], warnings: args.opts.worktree === 'off' ? [{ code: 'concurrent_edit', jobs: ['j-20261021-161000-a7q2'] }] : [] });
      return r({ ok: true, jobs: [{ id: sessions()[0].job, project: 'p1', window: '@3', cwd: '', items: args.opts.items }], warnings: [] });
    case 'sessions_list':
      return r({ ok: true, sessions: sessions(), owned: [] });
    case 'sessions_finish':
      return r({ ok: true, base: 'main', branch: 'blurt/sf-9-avatar-upload', stat: [{ path: 'api/avatar.py', added: 24, deleted: 9 }, { path: 'api/tests/test_avatar.py', added: 31, deleted: 0 }], patch: '', uncommitted: 0 });
    case 'pty_open': {
      const id = ++ptySeq;
      setTimeout(() => TERM.forEach((l, i) => setTimeout(() => emit('pty://data', { ptyId: id, data: btoa(String.fromCharCode(...new TextEncoder().encode(l))) }), i * 40)), 50);
      return r({ ptyId: id, replay: null, owned: false });
    }
    case 'settings_get':
      return r({ config: { record: { agents: ['claude', 'codex', 'kimi'] }, notify: {} }, hotkeys: hotkeyRows(), hotkey_mode: 'plugin', wayland: false, config_path: `${H}/.blurt/config.json`,
        export_targets: [{ id: 'markdown', name: 'Markdown', configured: true }, { id: 'csv', name: 'CSV', configured: true }, { id: 'github', name: 'GitHub Issues', configured: true, needs: 'gh auth login' }, { id: 'feishu', name: 'Feishu / Lark Bitable', configured: false }] });
    case 'shortcut_set':
      return r(String(args.combo).toLowerCase().includes('cmd+shift+s') ? { result: 'system', name: 'Snipping Tool' } : { result: 'ok', spec: args.combo, label: args.combo });
    case 'asr_models':
      return r({ models: [{ id: 'sensevoice-small', name: 'SenseVoice Small', backend: 'sherpa-onnx', installed: true, size_mb: 228, languages: ['zh', 'en', 'ja', 'ko', 'yue'] }, { id: 'whisper-large-v3-turbo-ct2', name: 'Whisper large-v3 turbo', backend: 'faster-whisper', installed: false, size_mb: 1620, languages: 'multi' }] });
    case 'update_check':
      return r({ configured: false });
    default:
      return r(undefined);
  }
}
