import { useEffect, useState } from 'react';
import { Icon } from '@blurt/icons';
import { api, type AppStatus, type AsrModel, type Detect, type HotkeyResult, type HotkeyRow, type Settings } from '../api';
import { i18n, t } from '../i18n';
import { comboFromEvent, comboLabel } from '../util';

const ORDER = ['record', 'snap', 'voice', 'project', 'menu', 'pause', 'marker', 'stop', 'pen'];

function conflictText(r: { result: string; of?: string; action?: string; name?: string; hint_url?: string }, platform: AppStatus['platform']): string {
  switch (r.result) {
    case 'duplicate':
      return t('settings.hotkey.duplicate', { other: t(`settings.hotkey.${r.of ?? r.action}`) });
    case 'system':
      return t('settings.hotkey.system', { name: r.name ?? '' });
    case 'taken':
    case 'idle':
    case 'unsupported':
    case 'portal':
    case 'pending':
      return t(`settings.hotkey.${r.result}`);
    case 'invalid':
      return t('settings.hotkey.invalid', { super: platform === 'win' ? 'Win' : 'Super' });
    case 'manual':
      return t('settings.hotkey.manual', { url: r.hint_url ?? 'blurt://record' });
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
      <td>{t(`settings.hotkey.${row.action}`)}</td>
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
          {recording ? t('settings.hotkey.press') : row.label || comboLabel(row.spec, platform) || t('settings.hotkey.off')}
        </button>
      </td>
      <td className="dim small">{msg && msg.result !== 'ok' ? <span className="warn">{conflictText(msg, platform)}</span> : conflictText(row, platform)}</td>
      <td>
        <button className="link" onClick={async () => setMsg(await onSet(row.default))}>{t('settings.hotkey.default')}</button>
      </td>
    </tr>
  );
}

type Tab = 'general' | 'shortcuts' | 'agents' | 'speech' | 'export';

export function SettingsView({ status, onToast, onLang }: { status: AppStatus; onToast: (m: string) => void; onLang: (lang: string) => void }) {
  const [tab, setTab] = useState<Tab>('general');
  const [s, setS] = useState<Settings | null>(null);
  const [models, setModels] = useState<AsrModel[] | null>(null);
  const [modelsErr, setModelsErr] = useState<string | null>(null);
  const [detect, setDetect] = useState<Detect | null>(null);
  const [update, setUpdate] = useState('');

  const reload = () => api.settings().then(setS, (e) => onToast(String(e)));
  useEffect(() => {
    reload();
  }, []);
  useEffect(() => {
    if (tab === 'speech' && !models) api.asrModels().then((r) => setModels(r.models ?? []), (e) => setModelsErr(String(e)));
    if (tab === 'agents' && !detect) api.detect().then(setDetect, (e) => onToast(String(e)));
  }, [tab]);

  if (!s) return <div className="blank">{t('settings.loading')}</div>;
  const cfg = s.config ?? {};
  const order: string[] = detect?.order ?? cfg.record?.agents ?? [];
  const moveAgent = async (id: string, d: number) => {
    const ids = [...order];
    const i = ids.indexOf(id);
    if (i < 0 || i + d < 0 || i + d >= ids.length) return;
    [ids[i], ids[i + d]] = [ids[i + d], ids[i]];
    await api.setSettings({ record: { agents: ids } });
    setDetect(detect && { ...detect, order: ids, agents: ids.map((x) => detect.agents.find((a) => a.id === x)!).filter(Boolean) });
  };
  const notify = (k: 'done' | 'agent') => cfg.notify?.[k] !== false;
  const hotkeys = [...s.hotkeys].sort((a, b) => ORDER.indexOf(a.action) - ORDER.indexOf(b.action));

  return (
    <div className="settings" data-testid="settings">
      <nav className="tabs" role="tablist">
        {(['general', 'shortcuts', 'agents', 'speech', 'export'] as const).map((id) => (
          <button key={id} role="tab" aria-selected={tab === id} className={tab === id ? 'sel' : ''} onClick={() => setTab(id)}>{t(`settings.tab.${id}`)}</button>
        ))}
      </nav>
      {tab === 'general' && (
        <section className="kv">
          <div>
            <span>{t('settings.language')}</span>
            <select
              value={cfg.lang === 'zh' ? 'zh-Hans' : cfg.lang ?? 'auto'}
              onChange={async (e) => {
                await api.setSettings({ lang: e.target.value });
                onLang(e.target.value);
                reload();
              }}
            >
              <option value="auto">{t('settings.language.auto')}</option>
              <option value="en">English</option>
              <option value="zh-Hans">简体中文</option>
            </select>
          </div>
          {(['done', 'agent'] as const).map((k) => (
            <label key={k} className="check">
              <input type="checkbox" checked={notify(k)} onChange={async (e) => {
                await api.setSettings({ notify: { ...(cfg.notify ?? {}), [k]: e.target.checked } });
                reload();
              }} />
              {t(`settings.notify.${k}`)}
            </label>
          ))}
          <p className="dim small">{t('settings.notify.hint')}</p>
          <div><span>{t('settings.paths.home')}</span><code>{status.blurt_home}</code></div>
          <div><span>{t('settings.paths.inbox')}</span><code>{status.inbox_store}</code></div>
          <div><span>{t('settings.paths.scripts')}</span><code>{status.scripts ?? t('settings.paths.missing')}</code></div>
          <div><span>{t('settings.paths.uv')}</span><code>{status.uv ?? t('settings.paths.missing')}</code></div>
          {status.os !== 'windows' && (
            <div><span>{t('settings.paths.tmux')}</span><span className={status.tmux ? 'ok' : 'warn'}>{t(status.tmux ? 'settings.tmux.ok' : 'settings.tmux.missing')}</span></div>
          )}
          {status.os === 'linux' && (
            <label className="check">
              <input type="checkbox" checked={!!cfg.app?.disable_dmabuf} onChange={async (e) => {
                await api.setSettings({ app: { ...(cfg.app ?? {}), disable_dmabuf: e.target.checked } });
                reload();
                onToast(t('settings.restart'));
              }} />
              {t('settings.dmabuf')}
            </label>
          )}
          <div>
            <span>{t('settings.updates')}</span>
            <button onClick={async () => {
              const r = await api.updateCheck().catch(() => ({ configured: false }) as { configured: boolean; available?: boolean; version?: string });
              setUpdate(!r.configured ? t('settings.updates.none') : r.available ? t('settings.updates.available', { version: r.version ?? '' }) : t('settings.updates.latest'));
            }}>{t('settings.updates.check')}</button>
            <span className="dim">{update}</span>
          </div>
          <div><span>{t('settings.version')}</span><code>{status.version}</code></div>
        </section>
      )}
      {tab === 'shortcuts' && (
        <section>
          {s.wayland && s.hotkey_mode === 'portal' && <p className="note">{t('settings.hotkey.portal_note')}</p>}
          <table className="grid">
            <tbody>
              {hotkeys.map((r) => (
                <ShortcutRow key={r.action} row={r} platform={status.platform} onSet={async (c) => {
                  const res = await api.setShortcut(r.action, c);
                  if (res.result === 'ok') reload();
                  return res;
                }} />
              ))}
            </tbody>
          </table>
          <p className="dim small">{t('settings.hotkey.help')}</p>
        </section>
      )}
      {tab === 'agents' && (
        <section>
          <p className="dim">{t('settings.agents.lead')}</p>
          {!detect && <p className="dim">{t('settings.agents.loading')}</p>}
          {detect && (
            <table className="grid" data-testid="agents-order">
              <tbody>
                {detect.agents.map((a, i) => (
                  <tr key={a.id}>
                    <td>{i18n().formatNumber(i + 1)}. <b>{a.name}</b> {detect.pick === a.id && <span className="badge">{t('settings.agents.in_use')}</span>}</td>
                    <td className={a.login === 'ok' ? 'ok' : a.installed ? 'warn' : 'dim'}>
                      {t(a.login === 'ok' ? 'settings.agents.ready' : a.installed ? 'settings.agents.logged_out' : 'settings.agents.not_installed')}
                      {a.version ? ` · ${a.version}` : ''}
                    </td>
                    <td className="dim small">{(a.session ?? a.headless) && a.installed ? t('settings.agents.sessions') : ''}</td>
                    <td className="dim small">{a.login === 'ok' ? '' : a.fix}</td>
                    <td>
                      <button className="link" aria-label={t('settings.agents.up')} onClick={() => moveAgent(a.id, -1)} disabled={i === 0}><Icon name="chevron-up" size={14} /></button>
                      <button className="link" aria-label={t('settings.agents.down')} onClick={() => moveAgent(a.id, 1)} disabled={i === detect.agents.length - 1}><Icon name="chevron-down" size={14} /></button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </section>
      )}
      {tab === 'speech' && (
        <section>
          {modelsErr && <p className="warn">{modelsErr}</p>}
          {!models && !modelsErr && <p className="dim">{t('settings.speech.loading')}</p>}
          {models && (
            <table className="grid" data-testid="asr-models">
              <thead><tr><th>{t('settings.speech.model')}</th><th>{t('settings.speech.languages')}</th><th>{t('settings.speech.size')}</th><th /></tr></thead>
              <tbody>
                {models.map((m, i) => (
                  <tr key={String(m.id ?? m.name ?? i)}>
                    <td>{String(m.name ?? m.id)} <span className="dim">{String(m.backend ?? '')}</span></td>
                    <td>{Array.isArray(m.languages) ? i18n().formatList(m.languages) : m.languages === 'multi' ? t('settings.speech.multi') : String(m.languages ?? '')}</td>
                    <td>{m.size_mb ? i18n().formatNumber(Number(m.size_mb), { style: 'unit', unit: 'megabyte', maximumFractionDigits: 0 }) : ''}</td>
                    <td>{m.installed ? <span className="ok">{t('settings.speech.installed')}</span> : <span className="dim">{t('settings.speech.available')}</span>}</td>
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
                  <td className={x.configured ? 'ok' : 'dim'}>{t(x.configured ? 'settings.export.ready' : 'settings.export.setup')}</td>
                  <td className="dim small">{x.needs ?? ''}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="dim small">{t('settings.export.lead')}</p>
        </section>
      )}
    </div>
  );
}
