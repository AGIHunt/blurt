// Dictation's speech model and its download, shared by Settings → Dictation and the Welcome's model step: the list
// (`dictation_models`), one download at a time (`model_download`) and its progress from `model-download` events. A
// download already under way shows as one, never as a second Download. Nothing downloads unasked (the founder,
// 2026-11-21), and a download that wouldn't fit with 2 GB to spare doesn't start: "4.5 GB needed, 3.1 GB free ·
// Show Storage" (commands.rs disk_short; the same line when the disk fills up on the way).
import { useCallback, useEffect, useState } from 'react';
import { api, listen, type DictationModels, type ModelDownload } from '../api';
import { i18n, t } from '../i18n';

/** "950 MB", "1.6 GB" */
export const mb = (n: number) =>
  n >= 1000
    ? i18n().formatNumber(n / 1024, { style: 'unit', unit: 'gigabyte', maximumFractionDigits: 1 })
    : i18n().formatNumber(n, { style: 'unit', unit: 'megabyte', maximumFractionDigits: 0 });

/** "disk_full:<need>:<free>" (model_download's refusal, a failed download's message) → the two sizes, else null */
export function diskShort(s: string | null | undefined): { need: number; free: number } | null {
  const m = /disk_full:(\d+(?:\.\d+)?):(\d+(?:\.\d+)?)/.exec(s ?? '');
  return m ? { need: Number(m[1]), free: Number(m[2]) } : null;
}

/** "4.5 GB needed, 3.1 GB free" */
export const roomLine = (r: { need: number; free: number }) => t('models.disk_full', { need: mb(r.need), free: mb(r.free) });

export interface DictationModelsState {
  models: DictationModels | null;
  /** the list couldn't be read (the speech tools aren't there yet) */
  err: string;
  /** the download under way (from the list's `downloading` or the events) */
  dl: ModelDownload | null;
  /** the last download stopped before it finished */
  failed: boolean;
  /** …and which model's it was (its row says so, with Try Again) */
  failedId: string | null;
  /** the last download didn't fit on the disk (refused, or the disk filled up): what it needed and what was free */
  room: { need: number; free: number } | null;
  load: () => Promise<DictationModels | null>;
  download: (id: string) => Promise<void>;
}

export function useDictationModels(): DictationModelsState {
  const [models, setModels] = useState<DictationModels | null>(null);
  const [err, setErr] = useState('');
  const [dl, setDl] = useState<ModelDownload | null>(null);
  const [failed, setFailed] = useState(false);
  const [failedId, setFailedId] = useState<string | null>(null);
  const [room, setRoom] = useState<{ need: number; free: number } | null>(null);
  const load = useCallback(
    () =>
      api.dictationModels().then(
        (m) => {
          setModels(m);
          setErr('');
          // only events end a download here: a list read just before it started mustn't hide it
          if (m.downloading) setDl((d) => (d?.id === m.downloading ? d : { id: m.downloading!, state: 'running', done_mb: 0, total_mb: 0 }));
          return m;
        },
        (e) => {
          setErr(String(e));
          return null;
        },
      ),
    [],
  );
  useEffect(() => {
    load();
    return listen<ModelDownload>('model-download', (p) => {
      if (p.state === 'running') {
        setDl(p);
        setFailed(false);
        setFailedId(null);
      } else {
        setDl(null);
        setFailed(p.state === 'failed');
        setFailedId(p.state === 'failed' ? p.id : null);
        setRoom(p.state === 'failed' ? diskShort(p.message) : null);
        if (p.state === 'done') load();
      }
    });
  }, [load]);
  const download = useCallback(
    async (id: string) => {
      setFailed(false);
      setRoom(null);
      setDl({ id, state: 'running', done_mb: 0, total_mb: 0 });
      try {
        await api.modelDownload(id);
      } catch (e) {
        // not enough space: nothing started — the row says how much is needed and free
        const short = diskShort(String(e));
        if (short) {
          setDl(null);
          setRoom(short);
          setFailed(true);
          setFailedId(id);
          return;
        }
        // one is already running: show that one
        if (!String(e).includes('already running')) {
          setDl(null);
          setErr(String(e));
        }
        load();
      }
    },
    [load],
  );
  return { models, err, dl, failed, failedId, room, load, download };
}

/** The one bar while a model comes down: "Connecting…" until the first megabytes, then "412 MB of 950 MB". `total`:
 *  the size the Download button promised — the bar counts up to it, so the page never names a second size. `wide`:
 *  the bar across the content column, its label and a regular Stop at the trailing edge (the Mac's s05_download). */
export function ModelProgress({ dl, onStop, total, wide }: { dl: ModelDownload; onStop?: () => void; total?: number; wide?: boolean }) {
  const started = dl.total_mb > 0;
  const all = Math.max(dl.total_mb, total ?? 0);
  return (
    <span className={`mprog${wide ? ' wide' : ''}`} data-testid="model-progress">
      <progress max={started ? all : undefined} value={started ? Math.min(dl.done_mb, all) : undefined} />
      <span className="dim small mprog-txt">{started ? t('dictation.model.progress', { done: mb(dl.done_mb), total: mb(all) }) : t('dictation.model.starting')}</span>
      {onStop && <button className={wide ? '' : 'st-small'} onClick={onStop}>{t('welcome.models.stop')}</button>}
    </span>
  );
}
