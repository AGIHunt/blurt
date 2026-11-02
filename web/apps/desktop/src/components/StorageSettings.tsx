// Settings → Storage (the Mac's PrivacyStoragePanes.swift StoragePane): everything big that Blurt keeps. The lead is
// the total ("Blurt uses 3.9 GB"); then Recordings (all recordings and snaps; inside them the videos of organized
// recordings, which can go — by age, or all — and "Delete videos automatically"), Models (one row per model folder,
// what it is used for) and App data (dictation's history and audio, the index and build files as one Caches row, job
// logs, hand-off notes, prompts, benchmark samples, temporary files, logs). Every row: an icon, a name, one plain line,
// the size in one size column; what can be done with it (Show in File Explorer, Delete) is in its ⋯ menu and its
// right-click menu. Deleting goes to the Recycle Bin (Windows' own undo, where the Mac's island offers Undo); turning
// automatic deletion on asks first when it would delete something right away. Sizes come from housekeeping.rs
// (`storage_scan`); which model is which from `transcribe.py models` / `dictation-models`.
import { useCallback, useEffect, useState } from 'react';
import { Icon, type IconName } from '@blurt/icons';
import { api, type AppStatus, type AsrModel, type DictationModels, type Settings, type StorageScan } from '../api';
import { i18n } from '../i18n';
import { Group, Line, Page, Popup, Row, S, Switch } from '../settings/kit';

/** "412 MB", "1.6 GB" — one formatter for every row (the Mac's ByteCountFormatter, file style). */
export function size(bytes: number): string {
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = Math.max(0, bytes) / 1000;
  let u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  return `${i18n().formatNumber(v, { maximumFractionDigits: v >= 100 || u === 0 ? 0 : 1 })} ${units[u]}`;
}
const P = (key: string, n: number) => i18n().plural(`st.win.n.${key}`, n);
const CHOICES = [30, 90, 180];

type Action = { label: string; run: () => void; disabled?: boolean; sep?: boolean };

function Menu({ actions, label }: { actions: Action[]; label: string }) {
  const [open, setOpen] = useState<{ x: number; y: number } | null>(null);
  useEffect(() => {
    if (!open) return;
    const c = () => setOpen(null);
    setTimeout(() => window.addEventListener('mousedown', c), 0);
    const k = (e: KeyboardEvent) => e.key === 'Escape' && c();
    window.addEventListener('keydown', k);
    return () => {
      window.removeEventListener('mousedown', c);
      window.removeEventListener('keydown', k);
    };
  }, [open]);
  if (!actions.length) return <span className="st-more-slot" />;
  return (
    <span className="st-more-slot">
      <button className="link st-more" aria-label={`${S('settings.storage.more')}: ${label}`} onClick={(e) => setOpen({ x: e.clientX, y: e.clientY })}><Icon name="more" size={14} /></button>
      {open && (
        <div className="st-menu" role="menu" style={{ left: Math.min(open.x, window.innerWidth - 260), top: open.y }} onMouseDown={(e) => e.stopPropagation()}>
          {actions.map((a, i) => [
            a.sep ? <div key={`s${i}`} className="st-menu-sep" /> : null,
            <button key={i} role="menuitem" disabled={a.disabled} onClick={() => (setOpen(null), a.run())}>{a.label}</button>,
          ])}
        </div>
      )}
    </span>
  );
}

function StorageRow({ icon, title, detail, bytes, tip, actions = [] }: { icon: IconName; title: string; detail?: string; bytes: number; tip?: string; actions?: Action[] }) {
  return (
    <div className="st-row st-storage" title={tip}>
      <span className="st-icon"><Icon name={icon} size={16} /></span>
      <div className="st-text">
        <div className="st-row-title"><span>{title}</span></div>
        {detail && <div className="st-detail">{detail}</div>}
      </div>
      <div className="st-ctl">
        <Menu actions={actions} label={title} />
        <span className="st-size">{size(bytes)}</span>
      </div>
    </div>
  );
}

const FILES: Record<string, { title: string; detail: string; icon: IconName }> = {
  dictation_history: { title: 'settings.storage.dictation_history', detail: 'settings.storage.managed_in_dictation', icon: 'character-cursor' },
  dictation_audio: { title: 'settings.storage.dictation_audio', detail: 'settings.storage.managed_in_dictation', icon: 'waveform' },
  runs: { title: 'settings.privacy.agent_runs', detail: 'settings.storage.detail.runs', icon: 'send' },
  jobs: { title: 'settings.storage.jobs', detail: 'settings.storage.detail.jobs', icon: 'list-box' },
  handoff: { title: 'settings.storage.handoff', detail: 'settings.storage.detail.handoff', icon: 'document' },
  prompts: { title: 'settings.privacy.prompts', detail: 'settings.storage.detail.prompts', icon: 'quote' },
  bench: { title: 'settings.privacy.benchmark_samples', detail: 'settings.storage.detail.bench', icon: 'waveform' },
  tmp: { title: 'settings.storage.tmp', detail: 'settings.storage.detail.tmp', icon: 'inbox' },
  logs: { title: 'win.storage.logs', detail: 'win.storage.logs.detail', icon: 'document' },
};

export function StoragePane({ status, s, save, onToast }: { status: AppStatus; s: Settings; save: (patch: Record<string, unknown>) => Promise<void>; onToast: (m: string) => void }) {
  const [scan, setScan] = useState<StorageScan | null>(null);
  const [asr, setAsr] = useState<AsrModel[] | null>(null);
  const [dict, setDict] = useState<DictationModels | null>(null);
  const [ask, setAsk] = useState<number | null>(null);
  const load = useCallback(() => api.storageScan().then(setScan, (e) => onToast(String(e))), [onToast]);
  useEffect(() => {
    load();
    api.asrModels().then((r) => setAsr(r.models ?? []), () => setAsr([]));
    api.dictationModels().then(setDict, () => {});
  }, [load]);
  const cfg = s.config ?? {};
  const reveal = (p: string) => api.reveal(p).catch((e) => onToast(String(e)));
  const trash = async (paths: string[], name: string) => {
    try {
      await api.storageTrash(paths);
      onToast(S('settings.storage.trashed', name));
    } catch (e) {
      onToast(String(e));
    }
    load();
  };
  const older = (d: number | null) => (scan?.videos ?? []).filter((v) => d == null || v.age_days >= d);
  const bytesOf = (l: { bytes: number }[]) => l.reduce((a, b) => a + b.bytes, 0);
  const trashVideos = async (d: number | null) => {
    const r = await api.videosTrash(d);
    onToast(S('settings.storage.videos.trashed', P('videos', r.count), size(r.bytes)));
    load();
  };
  const setAuto = async (d: number) => {
    if (d && older(d).length && ask !== d) return setAsk(d);
    setAsk(null);
    await api.videosAutoSet(d || null);
    load();
  };

  const recBytes = bytesOf(scan?.folders ?? []);
  const sessions = (scan?.folders ?? []).reduce((a, f) => a + f.sessions, 0);
  // models: the scripts say which folder is which model and what uses it
  const named = (p: string, folder: string) => {
    const norm = (x: string) => x.replace(/\\/g, '/').toLowerCase();
    const a = asr?.find((m) => typeof m.path === 'string' && norm(String(m.path)) === norm(p));
    const d = dict?.models.find((m) => m.id === folder || norm(p).endsWith(`/${m.id}`));
    return { name: (a?.name as string | undefined) ?? d?.name ?? (folder === 'silero_vad.onnx' ? null : S('settings.storage.model.unknown')), purposes: (a?.purposes as string[] | undefined) ?? [], dictation: !!d && dict?.selected === d.id };
  };
  const models = (scan?.models ?? []).filter((m) => m.folder !== 'silero_vad.onnx').sort((a, b) => b.bytes - a.bytes);
  const files = scan?.files ?? [];
  const caches = files.filter((f) => f.key === 'index' || f.key === 'build');
  const others = files.filter((f) => f.key !== 'index' && f.key !== 'build');
  const total = recBytes + bytesOf(scan?.models ?? []) + bytesOf(files);

  return (
    <Page id="storage" lead={scan ? (
      <span className="st-lead-split">
        <span>{S('settings.storage.uses', size(total))}</span>
        {typeof scan.available === 'number' && <span className="st-dim st-num">{S('settings.storage.available', size(scan.available))}</span>}
      </span>
    ) : S('settings.storage.counting')}>
      <Group id="storage.recordings" accessory={scan ? <span className="st-size">{size(recBytes)}</span> : undefined}>
        {scan && (
          <StorageRow icon="record" title={S('settings.privacy.recordings_screenshots')} bytes={recBytes}
            detail={sessions ? P('recordings', sessions) + (scan.folders.length > 1 ? ` · ${P('folders', scan.folders.length)}` : '') : S('settings.storage.none_yet')}
            tip={scan.folders.map((f) => f.path).join('\n')}
            actions={scan.folders.map((f) => ({ label: scan.folders.length > 1 ? `${S('win.storage.show')} · ${f.path.split(/[\\/]/).slice(-3, -1).join('/')}` : S('win.storage.show'), run: () => reveal(f.path) }))} />
        )}
        {scan && scan.videos.length > 0 && (
          <StorageRow icon="film" title={S('settings.storage.videos')} bytes={bytesOf(scan.videos)} tip={S('settings.storage.videos.footer')}
            detail={S('settings.storage.videos.detail', P('videos', scan.videos.length))}
            actions={[
              ...CHOICES.map((d, i) => ({ label: `${S('settings.privacy.move_trash')} · ${S('settings.storage.videos.older', d)}${older(d).length ? ` (${size(bytesOf(older(d)))})` : ''}`, disabled: !older(d).length, run: () => trashVideos(d), sep: i === 0 && false })),
              { label: `${S('settings.privacy.move_trash')} · ${S('settings.storage.videos.all')} (${size(bytesOf(scan.videos))})`, run: () => trashVideos(null), sep: true },
            ]} />
        )}
        <Row id="storage.auto_delete" icon="history" detail={ask ? `${S('settings.storage.videos.auto_confirm')} ${P('videos', older(ask).length)} (${size(bytesOf(older(ask)))}). ${S('settings.storage.videos.confirm')}` : undefined} warn={!!ask}>
          {ask ? (
            <>
              <button onClick={() => setAsk(null)}>{S('action.cancel')}</button>
              <button className="danger" onClick={() => setAuto(ask)}>{S('settings.storage.videos.auto_on')}</button>
            </>
          ) : (
            <Popup label={S('settings.storage.videos.auto')} value={scan?.auto_days ?? 0} dividers={[1]}
              choices={[[0, S('settings.storage.videos.never')], ...CHOICES.map((d) => [d, S('settings.storage.videos.after', d)] as [number, string])]} onChange={setAuto} />
          )}
        </Row>
      </Group>

      <Group id="storage.models" footer={S('settings.storage.model.footer')} accessory={scan ? <span className="st-size">{size(bytesOf(scan.models))}</span> : undefined}>
        {scan && !models.length && <StorageRow icon="cpu" title={S('settings.storage.model.none')} bytes={0} />}
        {models.map((m) => {
          const n = named(m.path, m.folder);
          const jobs = [...n.purposes.filter((p) => p !== 'live').map((p) => S(`speech.purpose.${p}`)), ...(n.dictation ? [S('speech.purpose.dictation')] : [])];
          const line = jobs.length ? S('settings.storage.model.used_for', i18n().formatList(jobs.map((j) => j.toLocaleLowerCase(i18n().locale)))) : asr ? S('settings.storage.model.not_used') : undefined;
          return (
            <StorageRow key={m.path} icon="waveform" title={n.name ?? m.folder} bytes={m.bytes} detail={line} tip={m.path}
              actions={[{ label: S('win.storage.show'), run: () => reveal(m.path) }, ...(!jobs.length && asr && n.name === S('settings.storage.model.unknown') ? [{ label: S('settings.privacy.move_trash'), run: () => trash([m.path], n.name ?? m.folder), sep: true }] : [])]} />
          );
        })}
      </Group>

      <Group id="storage.files" accessory={scan ? <span className="st-size">{size(bytesOf(files))}</span> : undefined}>
        {others.slice(0, 1).map((f) => fileRow(f))}
        {caches.length > 0 && (
          <StorageRow icon="sync" title={S('settings.storage.caches')} detail={S('settings.storage.rebuilt')} bytes={bytesOf(caches)} tip={caches.map((c) => c.path).join('\n')}
            actions={[
              { label: S('win.storage.show'), run: () => reveal(caches[caches.length - 1].path) },
              ...caches.filter((c) => c.removable).map((c) => ({ label: S('settings.privacy.move_trash'), run: () => trash([c.path], S('settings.storage.caches')), sep: true })),
            ]} />
        )}
        {others.slice(1).map((f) => fileRow(f))}
        {/* paths, not sizes: each its own glyph, its action behind the same ⋯ as every other row (sizes are the only
            text at the trailing edge) */}
        {([['win.storage.config', s.config_path, 'sliders'], ['win.storage.scripts', status.scripts, 'code'], ['win.storage.uv', status.uv, 'terminal']] as [string, string | null | undefined, IconName][]).map(([k, p, ic]) => (
          <Line key={k} icon={ic} title={S(k)} detail={p ?? S('win.storage.missing')} warn={!p}>
            <Menu actions={p ? [{ label: S('win.storage.show'), run: () => reveal(p) }] : []} label={S(k)} />
          </Line>
        ))}
        {status.os !== 'windows' && (
          <Line icon="terminal" title={S('win.storage.tmux')} detail={S(status.tmux ? 'win.storage.tmux.ok' : 'win.storage.tmux.missing')} warn={!status.tmux} />
        )}
        {status.os === 'linux' && (
          <Line title={S('win.storage.dmabuf')} detail={S('win.storage.restart')}>
            <Switch on={!!cfg.app?.disable_dmabuf} label={S('win.storage.dmabuf')} set={(v) => save({ app: { ...(cfg.app ?? {}), disable_dmabuf: v } })} />
          </Line>
        )}
      </Group>
    </Page>
  );

  function fileRow(f: StorageScan['files'][number]) {
    const meta = FILES[f.key] ?? { title: f.key, detail: '', icon: 'document' as IconName };
    return (
      <StorageRow key={f.key} icon={meta.icon} title={S(meta.title)} detail={meta.detail ? S(meta.detail) : undefined} bytes={f.bytes} tip={f.path}
        actions={[{ label: S('win.storage.show'), run: () => reveal(f.path) }, ...(f.removable ? [{ label: S('settings.privacy.move_trash'), run: () => trash([f.path], S(meta.title)), sep: true }] : [])]} />
    );
  }
}
