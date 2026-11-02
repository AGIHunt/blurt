// Settings → Dictation and Settings → Cloud on Windows / Linux (the Mac's Settings/DictationPane.swift,
// DictationModels.swift and the Cloud Services pane): the key, how it starts, sounds and polish; dictation's speech
// model — the recommended one with one Download (its progress from `model-download` events), the others under it —
// and the cloud services whose key lives in the system's own store (Windows Credential Manager), never in a file.
import { useEffect, useState } from 'react';
import { api, listen, type CloudSummary, type DictationModels, type ModelDownload } from '../api';
import { i18n, t } from '../i18n';

const mb = (n: number) =>
  n >= 1000
    ? i18n().formatNumber(n / 1024, { style: 'unit', unit: 'gigabyte', maximumFractionDigits: 1 })
    : i18n().formatNumber(n, { style: 'unit', unit: 'megabyte', maximumFractionDigits: 0 });

export function DictationSettings({ cfg, save }: { cfg: Record<string, any>; save: (patch: Record<string, unknown>) => Promise<void> }) {
  const d = cfg.record?.dictation ?? {};
  const set = (patch: Record<string, unknown>) => save({ record: { dictation: { ...d, ...patch } } });
  const [models, setModels] = useState<DictationModels | null>(null);
  const [err, setErr] = useState('');
  const [dl, setDl] = useState<ModelDownload | null>(null);
  const load = () => api.dictationModels().then(setModels, (e) => setErr(String(e)));
  useEffect(() => {
    load();
    return listen<ModelDownload>('model-download', (p) => {
      setDl(p.state === 'running' ? p : null);
      if (p.state === 'done') load();
      if (p.state === 'failed') setErr(t('dictation.model.failed'));
    });
  }, []);

  const rec = models?.models.find((m) => m.id === models.recommended);
  const missing = rec && !rec.installed;
  return (
    <section className="kv" data-testid="settings-dictation">
      <label className="check">
        <input type="checkbox" checked={d.enabled !== false} onChange={(e) => set({ enabled: e.target.checked })} />
        {t('dictation.enabled')}
      </label>
      <div>
        <span>{t('dictation.key')}</span>
        <select value={d.key === 'either_option' ? 'either_option' : 'right_option'} onChange={(e) => set({ key: e.target.value })}>
          <option value="right_option">{t('dictation.key.right_alt')}</option>
          <option value="either_option">{t('dictation.key.either_alt')}</option>
        </select>
      </div>
      <div>
        <span>{t('dictation.mode')}</span>
        <select value={d.mode ?? 'auto'} onChange={(e) => set({ mode: e.target.value })}>
          {(['auto', 'tap', 'hold'] as const).map((m) => (
            <option key={m} value={m}>{t(`dictation.mode.${m}`)}</option>
          ))}
        </select>
        <span className="dim small">{t(`dictation.mode.${d.mode ?? 'auto'}.hint`)}</span>
      </div>
      <label className="check">
        <input type="checkbox" checked={d.sounds !== false} onChange={(e) => set({ sounds: e.target.checked })} />
        {t('dictation.sounds')}
      </label>
      <label className="check">
        <input type="checkbox" checked={d.polish !== 'off'} onChange={(e) => set({ polish: e.target.checked ? 'light' : 'off' })} />
        {t('dictation.polish')}
      </label>
      <p className="dim small">{t('dictation.polish.hint')}</p>
      <div>
        <span>{t('dictation.translate_target')}</span>
        <select value={d.translate_target ?? 'auto'} onChange={(e) => set({ translate_target: e.target.value })}>
          <option value="auto">{t('dictation.translate_target.auto')}</option>
          {['en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'es', 'fr', 'de'].map((l) => (
            <option key={l} value={l}>{new Intl.DisplayNames([i18n().locale], { type: 'language' }).of(l) ?? l}</option>
          ))}
        </select>
      </div>

      <h3 className="sub-head">{t('dictation.model')}</h3>
      {err && <p className="warn">{err}</p>}
      {!models && !err && <p className="dim">{t('settings.speech.loading')}</p>}
      {models && (
        <>
          {missing && rec && (
            <div className="callout" data-testid="model-get">
              <span>{t('dictation.model.needed', { name: rec.name, size: mb(rec.size_mb) })}</span>
              {dl?.id === rec.id ? (
                <span className="dim">{dl.total_mb ? t('dictation.model.progress', { done: mb(dl.done_mb), total: mb(dl.total_mb) }) : t('dictation.model.starting')}</span>
              ) : (
                <button className="primary" disabled={!!dl} onClick={() => api.modelDownload(rec.id).catch((e) => setErr(String(e)))}>{t('dictation.model.download')}</button>
              )}
            </div>
          )}
          <table className="grid" data-testid="dictation-models">
            <tbody>
              {models.models.map((m) => (
                <tr key={m.id}>
                  <td>
                    <label className="radio">
                      <input type="radio" name="dmodel" disabled={!m.installed} checked={models.selected === m.id && m.installed}
                        onChange={() => api.dictationUse(m.recommended ? null : m.id).then(load)} />
                      {m.name}
                    </label>
                    {m.recommended && <span className="badge">{t('dictation.model.recommended')}</span>}
                  </td>
                  <td className="dim">{mb(m.size_mb)}</td>
                  <td>
                    {m.installed ? (
                      <span className="ok">{t('settings.speech.installed')}</span>
                    ) : dl?.id === m.id ? (
                      <span className="dim">{dl.total_mb ? `${Math.round((dl.done_mb / dl.total_mb) * 100)}%` : '…'}</span>
                    ) : (
                      <button disabled={!!dl} onClick={() => api.modelDownload(m.id).catch((e) => setErr(String(e)))}>{t('dictation.model.download')}</button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </section>
  );
}

const PRESETS = [
  { id: 'deepseek', page: 'https://platform.deepseek.com/api_keys' },
  { id: 'dashscope', page: 'https://bailian.console.aliyun.com/?tab=model#/api-key' },
] as const;

export function CloudSettings({ onToast }: { onToast: (m: string) => void }) {
  const [sum, setSum] = useState<CloudSummary | null>(null);
  const [preset, setPreset] = useState<string>('deepseek');
  const [key, setKey] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  useEffect(() => {
    api.cloudSummary().then(setSum, (e) => onToast(String(e)));
  }, []);
  const connect = async () => {
    setBusy(true);
    setMsg(null);
    try {
      const r = await api.cloudConnect(preset, key.trim());
      if (r.ok) {
        setKey('');
        setSum(r.summary ?? (await api.cloudSummary()));
        setMsg({ ok: true, text: t('cloud.connected', { ms: String(r.ms ?? '') }) });
      } else {
        setMsg({ ok: false, text: t(`cloud.error.${r.code ?? 'other'}`, { error: r.error ?? '' }) });
      }
    } catch (e) {
      setMsg({ ok: false, text: String(e) });
    }
    setBusy(false);
  };
  const route = sum?.routes?.polish;
  return (
    <section className="kv" data-testid="settings-cloud">
      <p className="dim small">{t('cloud.lead')}</p>
      {sum?.services.map((s) => (
        <div key={s.id}>
          <span>{t(`cloud.preset.${s.preset}`)}</span>
          <span className={s.has_key ? 'ok' : 'warn'}>{t(s.has_key ? 'cloud.key.saved' : 'cloud.key.missing')}</span>
          <button className="link" onClick={async () => setSum(await api.cloudDisconnect(s.id))}>{t('cloud.remove')}</button>
        </div>
      ))}
      <div>
        <span>{t('cloud.add')}</span>
        <select value={preset} onChange={(e) => setPreset(e.target.value)}>
          {PRESETS.map((p) => (
            <option key={p.id} value={p.id}>{t(`cloud.preset.${p.id}`)}</option>
          ))}
        </select>
        <input type="password" autoComplete="off" spellCheck={false} placeholder={t('cloud.key.placeholder')} value={key} onChange={(e) => setKey(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && key.trim() && !busy && connect()} />
        <button className="primary" disabled={!key.trim() || busy} onClick={connect}>{busy ? t('cloud.testing') : t('cloud.connect')}</button>
        <button className="link" onClick={() => api.openUrl(PRESETS.find((p) => p.id === preset)!.page)}>{t('cloud.get_key')}</button>
      </div>
      {msg && <p className={msg.ok ? 'ok' : 'warn'}>{msg.text}</p>}
      <div>
        <span>{t('cloud.polish')}</span>
        <span>{route ? `${route.model} · ${t(`cloud.preset.${sum?.services.find((s) => s.id === route.service)?.preset ?? 'custom'}`)}` : t('cloud.polish.none')}</span>
      </div>
    </section>
  );
}
