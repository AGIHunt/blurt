// In-browser stand-in for the Rust commands (vite dev / unit tests): a tiny fixed dataset, writes kept in memory.

type Listener = (p: unknown) => void;
const listeners = new Map<string, Set<Listener>>();

export function mockListen(event: string, cb: Listener): () => void {
  if (!listeners.has(event)) listeners.set(event, new Set());
  listeners.get(event)!.add(cb);
  return () => listeners.get(event)?.delete(cb);
}

const now = Date.now() / 1000;
const ws = [
  { id: 'w0', path: '/home/me/Blurt', name: 'Blurt', kind: 'default', sessions: 1, open_items: 2 },
  { id: 'w1', path: '/home/me/code/my-saas', name: 'my-saas', kind: 'repo', sessions: 2, open_items: 4 },
];
const S1 = '/home/me/code/my-saas/.blurt/sessions/20261021-101500';
const S2 = '/home/me/Blurt/recordings/20261020-141500-shots';

const docs: Record<string, any> = {
  [S1]: {
    schema: 2,
    title: '个人中心和登录页走查',
    reviewed: false,
    items: [
      { id: 'I-001', uid: 'u1', kind: 'issue', title: '头像上传返回 500', quote: '上传头像直接报 500。', status: 'confirmed', severity: 'high',
        actual: 'POST /api/avatar 返回 500', expected: '上传成功并刷新头像', steps: ['打开个人中心', '上传 PNG 头像'], code_refs: ['api/avatar.py:88'],
        frames: [{ path: 'frames/I-001-1.jpg', t: 0.9, caption: '上传后的报错' }],
        fix: { state: 'fixed', agent: 'claude', run_id: 'r-1', commit: 'a1c3e5f', pr: null, note: 'multipart 边界解析错误', at: now - 3 * 86400 } },
      { id: 'I-002', uid: 'u2', kind: 'issue', title: '登录按钮点击无响应', quote: '这个登录按钮点了没反应', status: 'draft', severity: 'high',
        actual: '点击后没有请求', expected: '跳转到首页', frames: [{ path: 'frames/I-002-1.jpg', t: 3.1 }] },
      { id: 'I-003', uid: 'u3', kind: 'idea', title: '学 Linear 的空状态', quote: '空列表可以像 Linear 那样给个引导', status: 'draft', why: '新用户第一次进来不知道干嘛' },
    ],
  },
  [S2]: {
    schema: 2,
    title: '价格页',
    items: [{ id: 'I-001', uid: 'u4', kind: 'issue', title: '价格页移动端溢出', status: 'draft', severity: 'medium', frames: [{ path: 'shots/001.png' }] }],
  },
};

function rows() {
  const out: any[] = [];
  for (const [dir, d] of Object.entries(docs)) {
    const w = dir.startsWith('/home/me/Blurt') ? ws[0] : ws[1];
    d.items.forEach((it: any, i: number) =>
      out.push({
        uid: it.uid, session_id: `${w.id}:${dir.split('/').pop()}`, session_dir: dir, item_id: it.id, kind: it.kind, title: it.title,
        status: it.status ?? 'draft', fix_state: it.fix?.state ?? null, severity: it.severity ?? null,
        primary_frame: it.frames?.[0] ? `${dir}/${it.frames[0].path}` : null, updated: now - (i + 1) * 3600 * (dir === S2 ? 20 : 2),
        snippet: null, workspace_id: w.id, created: now - 86400, session_title: d.title, quote: it.quote ?? '', tags: '', frame_count: it.frames?.length ?? 0,
        has_code_refs: it.code_refs?.length ? 1 : 0,
      }),
    );
  }
  return out.sort((a, b) => b.updated - a.updated);
}

function etag(dir: string) {
  return `"${JSON.stringify(docs[dir]).length.toString(16)}"`;
}

const hotkeys = ['record', 'menu', 'pause', 'snap', 'marker', 'pen', 'stop'].map((a) => ({
  action: a, spec: `opt+shift+${a === 'menu' ? 'B' : a === 'snap' ? 'A' : a === 'pen' ? 'D' : a[0].toUpperCase()}`,
  label: `Alt+Shift+${a === 'menu' ? 'B' : a === 'snap' ? 'A' : a === 'pen' ? 'D' : a[0].toUpperCase()}`, default: '', active: ['record', 'menu', 'snap'].includes(a),
  result: a === 'pen' ? 'unsupported' : ['record', 'menu', 'snap'].includes(a) ? 'ok' : 'idle',
}));

export async function mockInvoke<T>(cmd: string, args: Record<string, any> = {}): Promise<T> {
  const r = (v: unknown) => v as T;
  switch (cmd) {
    case 'app_status':
      return r({ version: '0.6.0-mock', os: 'linux', platform: 'gnome', wayland: false, lang: navigator.language.startsWith('zh') ? 'zh' : 'en',
        blurt_home: '/home/me/.blurt', index_db: '/home/me/.blurt/index.db', index_exists: true, default_workspace: '/home/me/Blurt',
        scripts: '/home/me/.claude/skills/blurt/scripts', uv: '/usr/bin/uv', capture: { recording: false, paused: false, session: null, engine: 'mock' }, hotkey_mode: 'plugin' });
    case 'index_query': {
      const q = args.q ?? {};
      let items = rows().filter((x) => (q.status?.length ? q.status.includes(x.status) : x.status !== 'deleted'));
      if (q.kind?.length) items = items.filter((x) => q.kind.includes(x.kind));
      if (q.fix_state?.length) items = items.filter((x) => q.fix_state.includes(x.fix_state ?? 'none'));
      if (q.workspace) items = items.filter((x) => x.workspace_id === q.workspace);
      if (q.session) items = items.filter((x) => x.session_dir === q.session || x.session_id === q.session);
      for (const t of (q.query ?? '').split(/\s+/).filter(Boolean)) items = items.filter((x) => (x.title + x.quote).includes(t));
      return r({ total: items.length, items: items.slice(q.offset ?? 0, (q.offset ?? 0) + (q.limit ?? 50)), missing: false });
    }
    case 'index_item':
      return r(rows().find((x) => x.uid === args.uid) ?? null);
    case 'index_workspaces':
      return r(ws);
    case 'index_summary':
      return r({ missing: false, items: rows().length, sessions: 2, inbox: 1, fixing: 0 });
    case 'index_sessions':
      return r(Object.entries(docs).filter(([dir]) => (args.q?.state === 'inbox' ? !docs[dir].reviewed : true)).map(([dir, d]) => ({
        id: dir.split('/').pop(), workspace_id: dir.includes('my-saas') ? 'w1' : 'w0', workspace_name: dir.includes('my-saas') ? 'my-saas' : 'Blurt',
        workspace_path: '', dir, mode: dir.endsWith('shots') ? 'shots' : 'video', title: d.title, created: now - 86400, duration: 42, shot_count: 3,
        item_count: d.items.length, processed: 1, processing: 0, reviewed: d.reviewed ? 1 : 0, fixed_count: 1,
      })));
    case 'index_rescan':
      return r(undefined);
    case 'review_load':
      return r({ doc: structuredClone(docs[args.session]), etag: etag(args.session) });
    case 'review_poll':
      return r(etag(args.session) === args.etag ? { etag: args.etag } : { doc: structuredClone(docs[args.session]), etag: etag(args.session) });
    case 'review_ops': {
      const d = docs[args.session];
      for (const op of args.ops ?? []) {
        const it = d.items.find((i: any) => i.id === op.id);
        if (op.op === 'set' && it) {
          Object.assign(it, op.set ?? {});
          it._user = { ...(it._user ?? {}), ...Object.fromEntries(Object.keys(op.set ?? {}).map((k) => [k, Date.now() / 1000])) };
        }
      }
      if (args.confirm) d.reviewed = true;
      return r({ ok: true, etag: etag(args.session) });
    }
    case 'agents_detect':
      return r({ order: ['claude', 'codex', 'kimi'], pick: 'codex', agents: [
        { id: 'claude', name: 'Claude Code', path: '/usr/bin/claude', state: 'logged_out', why: 'not logged in', fix: 'run `claude` and /login', installed: true, version: '2.1.0', login: 'logged_out', headless: true, interactive: 'url' },
        { id: 'codex', name: 'Codex', path: '/usr/bin/codex', state: 'ready', why: 'logged in', fix: '', installed: true, version: '0.50.0', login: 'ok', headless: true, interactive: 'terminal' },
        { id: 'kimi', name: 'Kimi Code', path: null, state: 'not_installed', why: 'not installed', fix: '', installed: false, version: null, login: 'n/a', headless: true, interactive: 'terminal' },
      ] });
    case 'agent_runs':
      return r([]);
    case 'fix_with_agent':
      return r({ run_id: 'r-mock', agent: 'codex', repo: '/home/me/code/my-saas' });
    case 'settings_get':
      return r({ config: { record: { agents: ['codex', 'claude'] } }, hotkeys, hotkey_mode: 'plugin', wayland: false, config_path: '/home/me/.blurt/config.json',
        export_targets: [{ id: 'markdown', name: 'Markdown', configured: true }, { id: 'csv', name: 'CSV', configured: true }, { id: 'github', name: 'GitHub Issues', configured: true, needs: 'gh auth login' }, { id: 'feishu', name: 'Feishu / Lark Bitable', configured: false }] });
    case 'settings_set':
      return r({});
    case 'shortcut_set':
      return r(args.combo.toLowerCase().includes('win+shift+s') ? { result: 'system', name: 'Snipping Tool' } : { result: 'ok', spec: args.combo, label: args.combo });
    case 'asr_models':
      return r({ models: [{ id: 'sensevoice', name: 'SenseVoice Small', installed: true, size_mb: 241, languages: ['zh', 'en', 'ja'] }, { id: 'whisper-large-v3-turbo', name: 'Whisper large-v3 turbo', installed: false, size_mb: 1600, languages: 'multi' }] });
    case 'update_check':
      return r({ configured: false });
    default:
      return r(undefined);
  }
}
