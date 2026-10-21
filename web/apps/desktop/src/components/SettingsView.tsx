import { useEffect, useState } from 'react';
import { api, type AppStatus, type AsrModel, type Detect, type HotkeyResult, type HotkeyRow, type Settings } from '../api';
import { comboFromEvent, comboLabel, t } from '../util';
import { Icon } from '../icons';

const ACTION_NAME: Record<string, [string, string]> = {
  record: ['开始 / 结束录制', 'Start / finish recording'],
  menu: ['打开 Blurt', 'Open Blurt'],
  snap: ['截图', 'Snap'],
  pause: ['暂停 / 继续', 'Pause / resume'],
  marker: ['标记（同时截图）', 'Marker (also snaps)'],
  pen: ['画笔常开 / 关', 'Pen on / off'],
  stop: ['完成录制', 'Finish recording'],
};

function conflictText(r: { result: string; of?: string; action?: string; name?: string; hint?: string; error?: string }): string {
  switch (r.result) {
    case 'duplicate':
      return t(`和「${ACTION_NAME[r.of ?? r.action ?? '']?.[0] ?? r.of ?? r.action}」重复`, `Same keys as “${ACTION_NAME[r.of ?? r.action ?? '']?.[1] ?? r.of ?? r.action}”`);
    case 'system':
      return t(`系统已占用：${r.name}`, `Used by the system: ${r.name}`);
    case 'taken':
      return t('注册失败：可能被别的应用占用', "Couldn't register: another app probably holds it");
    case 'invalid':
      return r.error ?? t('无效的组合', 'Not a valid shortcut');
    case 'idle':
      return t('录制时生效', 'Active while recording');
    case 'unsupported':
      return t('Windows/Linux 暂不支持画笔', 'The pen is macOS-only for now');
    case 'portal':
      return t('由系统（门户）管理', 'Managed by the desktop (portal)');
    case 'pending':
      return t('等待系统确认…', 'Waiting for the desktop…');
    case 'manual':
      return r.hint ?? t('Wayland 下请在系统设置里绑定', 'On Wayland, bind it in the system settings');
    default:
      return '';
  }
}

function ShortcutRow({ row, platform, onSet }: { row: HotkeyRow; platform: AppStatus['platform']; onSet: (combo: string) => Promise<HotkeyResult> }) {
  const [recording, setRecording] = useState(false);
  const [msg, setMsg] = useState<HotkeyResult | null>(null);
  const bad = ['duplicate', 'system', 'taken', 'invalid', 'manual'].includes(row.result);
  return (
    <tr className={bad ? 'conflict' : ''} data-testid={`hotkey-${row.action}`}>
      <td>{t(...(ACTION_NAME[row.action] ?? [row.action, row.action]))}</td>
      <td>
        <button
          className={`key-recorder ${recording ? 'rec' : ''}`}
          onClick={() => setRecording(true)}
          onBlur={() => setRecording(false)}
          onKeyDown={async (e) => {
            if (!recording) return;
            e.preventDefault();
            if (e.key === 'Escape') return setRecording(false);
            if (e.key === 'Backspace' || e.key === 'Delete') {
              setRecording(false);
              return setMsg(await onSet('off'));
            }
            const c = comboFromEvent(e);
            if (!c) return;
            setRecording(false);
            setMsg(await onSet(c));
          }}
        >
          {recording ? t('按下新组合…', 'Press keys…') : row.label || comboLabel(row.spec, platform) || t('未设置', 'Off')}
        </button>
      </td>
      <td className="dim">
        {msg && msg.result !== 'ok' ? <span className="warn">{conflictText(msg)}</span> : conflictText(row)}
        {msg?.hint && <div className="hint">{msg.hint}</div>}
      </td>
      <td>
        <button className="link" onClick={async () => setMsg(await onSet(row.default))}>{t('恢复默认', 'Default')}</button>
      </td>
    </tr>
  );
}

export function SettingsView({ status, onToast }: { status: AppStatus; onToast: (m: string) => void }) {
  const [tab, setTab] = useState<'shortcuts' | 'speech' | 'agents' | 'export' | 'general'>('shortcuts');
  const [s, setS] = useState<Settings | null>(null);
  const [models, setModels] = useState<AsrModel[] | null>(null);
  const [modelsErr, setModelsErr] = useState<string | null>(null);
  const [detect, setDetect] = useState<Detect | null>(null);
  const [update, setUpdate] = useState<string>('');

  const reload = () => api.settings().then(setS, (e) => onToast(String(e)));
  useEffect(() => {
    reload();
  }, []);
  useEffect(() => {
    if (tab === 'speech' && !models) api.asrModels().then((r) => setModels(r.models ?? []), (e) => setModelsErr(String(e)));
    if (tab === 'agents' && !detect) api.detect().then(setDetect, (e) => onToast(String(e)));
  }, [tab]);

  if (!s) return <div className="empty">{t('读取设置…', 'Loading settings…')}</div>;
  const order: string[] = detect?.order ?? s.config?.record?.agents ?? [];
  const moveAgent = async (id: string, d: number) => {
    const ids = [...order];
    const i = ids.indexOf(id);
    if (i < 0 || i + d < 0 || i + d >= ids.length) return;
    [ids[i], ids[i + d]] = [ids[i + d], ids[i]];
    await api.setSettings({ record: { agents: ids } });
    setDetect(detect && { ...detect, order: ids, agents: ids.map((x) => detect.agents.find((a) => a.id === x)!).filter(Boolean) });
  };

  return (
    <div className="settings" data-testid="settings">
      <nav className="tabs">
        {(
          [
            ['shortcuts', '快捷键', 'Shortcuts'],
            ['speech', '语音', 'Speech'],
            ['agents', 'Agent', 'Agents'],
            ['export', '导出', 'Export'],
            ['general', '通用', 'General'],
          ] as const
        ).map(([id, zh, en]) => (
          <button key={id} className={tab === id ? 'sel' : ''} onClick={() => setTab(id)}>{t(zh, en)}</button>
        ))}
      </nav>
      {tab === 'shortcuts' && (
        <section>
          {s.wayland && (
            <p className="note">
              {s.hotkey_mode === 'portal'
                ? t('Wayland：快捷键通过系统的 GlobalShortcuts 门户注册，在系统设置 → 键盘里修改。', 'Wayland: shortcuts go through the desktop’s GlobalShortcuts portal; change them in Settings → Keyboard.')
                : t('Wayland 下应用不能自己抢快捷键。到系统设置 → 键盘 → 自定义快捷键，命令填 `blurt blurt://record`（截图用 blurt://snap，打开用 blurt://open）。',
                    'On Wayland apps can’t grab keys. In Settings → Keyboard → Custom Shortcuts, add the command `blurt blurt://record` (blurt://snap, blurt://open for the others).')}
            </p>
          )}
          <table className="grid">
            <tbody>
              {s.hotkeys.map((r) => (
                <ShortcutRow key={r.action} row={r} platform={status.platform} onSet={async (c) => {
                  const res = await api.setShortcut(r.action, c);
                  if (res.result === 'ok') reload();
                  return res;
                }} />
              ))}
            </tbody>
          </table>
          <p className="dim small">{t('点按钮后按下新组合；Backspace 关闭；Esc 取消。', 'Click, then press the new keys; Backspace turns it off; Esc cancels.')}</p>
        </section>
      )}
      {tab === 'speech' && (
        <section>
          {modelsErr && <p className="warn">{modelsErr}</p>}
          {!models && !modelsErr && <p className="dim">{t('读取模型…', 'Loading models…')}</p>}
          {models && (
            <table className="grid" data-testid="asr-models">
              <thead><tr><th>{t('模型', 'Model')}</th><th>{t('语言', 'Languages')}</th><th>{t('大小', 'Size')}</th><th /></tr></thead>
              <tbody>
                {models.map((m, i) => (
                  <tr key={String(m.id ?? m.name ?? i)}>
                    <td>{String(m.name ?? m.id)} <span className="dim">{String(m.backend ?? '')}</span></td>
                    <td>{Array.isArray(m.languages) ? m.languages.join(', ') : String(m.languages ?? '')}</td>
                    <td>{m.size_mb ? `${Math.round(Number(m.size_mb))} MB` : ''}</td>
                    <td>{m.installed ? <span className="ok">{t('已安装', 'Installed')}</span> : <span className="dim">{t('可下载', 'Available')}</span>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </section>
      )}
      {tab === 'agents' && (
        <section>
          <p className="dim">{t('按顺序尝试：第一个已登录、能后台运行的 agent 用来整理和修复。', 'Tried in this order: the first logged-in agent that can run headless processes and fixes.')}</p>
          {!detect && <p className="dim">{t('检测中…', 'Detecting…')}</p>}
          {detect && (
            <table className="grid" data-testid="agents-order">
              <tbody>
                {detect.agents.map((a, i) => (
                  <tr key={a.id}>
                    <td>{i + 1}. <b>{a.name}</b> {detect.pick === a.id && <span className="badge">{t('当前', 'in use')}</span>}</td>
                    <td className={a.login === 'ok' ? 'ok' : a.installed ? 'warn' : 'dim'}>{a.why}{a.version ? ` · ${a.version}` : ''}</td>
                    <td className="dim small">{a.fix}</td>
                    <td>
                      <button className="link" aria-label="up" onClick={() => moveAgent(a.id, -1)} disabled={i === 0}><Icon name="up" size={14} /></button>
                      <button className="link" aria-label="down" onClick={() => moveAgent(a.id, 1)} disabled={i === detect.agents.length - 1}><Icon name="down" size={14} /></button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </section>
      )}
      {tab === 'export' && (
        <section>
          <table className="grid">
            <tbody>
              {s.export_targets.map((x) => (
                <tr key={x.id}>
                  <td>{x.name}</td>
                  <td className={x.configured ? 'ok' : 'dim'}>{x.configured ? t('可用', 'Ready') : t('未配置', 'Not set up')}</td>
                  <td className="dim small">{x.needs ?? ''}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="dim small">{t('导出由 agent 通过 skill 完成（export_local.py / feishu.py）。', 'Exports run through the skill (export_local.py / feishu.py).')}</p>
        </section>
      )}
      {tab === 'general' && (
        <section className="kv">
          <div><span>{t('数据目录', 'Blurt home')}</span><code>{status.blurt_home}</code></div>
          <div><span>{t('索引', 'Index')}</span><code>{status.index_db}</code> {status.index_exists ? '' : <span className="warn">{t('还没有', 'not built yet')}</span>}</div>
          <div><span>{t('默认工作区', 'Default workspace')}</span><code>{status.default_workspace}</code></div>
          <div><span>Skill</span><code>{status.scripts ?? t('没找到', 'not found')}</code></div>
          <div><span>uv</span><code>{status.uv ?? t('没装（写入操作不可用）', 'not installed (edits disabled)')}</code></div>
          <div><span>{t('录制引擎', 'Capture engine')}</span><code>{status.capture.engine}</code></div>
          <div><span>{t('配置文件', 'Config')}</span><code>{s.config_path}</code></div>
          {status.os === 'linux' && (
            <label className="check">
              <input type="checkbox" checked={!!s.config?.app?.disable_dmabuf} onChange={async (e) => {
                await api.setSettings({ app: { ...(s.config?.app ?? {}), disable_dmabuf: e.target.checked } });
                reload();
                onToast(t('重启 Blurt 后生效', 'Takes effect after restarting Blurt'));
              }} />
              {t('关闭 WebKit DMA-BUF 渲染（NVIDIA 黑屏时打开）', 'Disable WebKit DMA-BUF rendering (fixes a black window on NVIDIA)')}
            </label>
          )}
          <div>
            <span>{t('更新', 'Updates')}</span>
            <button onClick={async () => {
              const r = await api.updateCheck().catch((e) => ({ configured: true, error: String(e) }) as any);
              setUpdate(!r.configured ? t('这个版本没有配置更新源', 'Updates are not configured in this build') : r.error ?? (r.available ? `${t('有新版本', 'New version')} ${r.version}` : t('已是最新', 'Up to date')));
            }}>{t('检查更新', 'Check for updates')}</button> <span className="dim">{update}</span>
          </div>
          <div><span>{t('版本', 'Version')}</span><code>{status.version}</code></div>
        </section>
      )}
    </div>
  );
}
