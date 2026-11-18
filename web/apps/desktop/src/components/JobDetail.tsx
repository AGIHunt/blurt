// A job in the detail (the Mac's JobDetailView, the part Windows has the data for): what it does and when it started,
// its steps in an inset group with each one's state, the items it wrote so far (a click shows one). A failed run has
// the Mac's controls: Try Again (the same recording, or the same captures, organised again), Show in File Explorer,
// Show Log, Dismiss (it leaves the list; the Mac's JobFailures).
// A recording's run is that recording's detail (RecordingHead: its name, its state in the recording's words, one
// primary button that fits whether an agent can organise now); a recording with no run shows only that head
// (RecordingDetail).
import { useEffect, useState } from 'react';
import { Icon } from '@blurt/icons';
import { KindIcon } from '@blurt/ui/react';
import { api, type ItemRow, type Job } from '../api';
import { ago, i18n, plural, t } from '../i18n';
import { detailActions, type Recording } from '../recordings';
import { revealLabel } from '../reveal';
import { actionLabel, recLength, recStateText, recWhy, runRecAction, type RecHandlers } from './Recordings';

/** A recording shown in the detail, with what its buttons need. */
export interface RecDetail {
  r: Recording;
  /** an agent can organise in the background now (null: not known yet) */
  agent: boolean | null;
  handlers: RecHandlers;
}

/** "Recording · 3:12 · the first thing said in it". */
export const recDetailTitle = (r: Recording) => [t('inbox.mode.video'), recLength(r), r.info.first_line].filter(Boolean).join(' · ');

/** A recording's name, its state, why it didn't finish (the only words in the error ink) and its buttons: one primary,
 *  the rest secondary. `job`: its run on show (Show Log, the time it ended). */
function RecordingHead({ rec, job }: { rec: RecDetail; job: Job | null }) {
  const { r, agent, handlers } = rec;
  const { primary, rest } = detailActions(r, agent);
  const live = job && (job.state === 'running' || job.state === 'queued');
  const at = job?.ended ?? null;
  const btn = (a: (typeof rest)[number], main = false) => (
    <button key={a} className={`pg-small ${main ? 'primary' : ''}`} onClick={() => runRecAction(a, r, handlers)} data-testid={`rec-detail-${a}`}>
      {actionLabel(a, r)}
    </button>
  );
  const why = recWhy(r, agent);
  return (
    <>
      <h2>{recDetailTitle(r)}</h2>
      <p className="dim small">
        {live ? (job.started ? t('main.job.started', { a: ago(job.started) }) : recStateText(r)) : [recStateText(r), at ? ago(at) : r.info.created ? ago(new Date(r.info.created * 1000).toISOString()) : ''].filter(Boolean).join(' · ')}
      </p>
      {why && <p className="mw-err">{why}</p>}
      {(primary || rest.length > 0 || job?.log) && (
        <p className="mw-job-acts" data-testid="rec-detail-actions">
          {primary && btn(primary, true)}
          {rest.filter((a) => a !== 'dismiss').map((a) => btn(a))}
          {job?.log && <button className="pg-small" onClick={() => void api.openPath(job.log!).catch(() => {})}>{t('main.job.show_log')}</button>}
          {rest.includes('dismiss') && btn('dismiss')}
        </p>
      )}
    </>
  );
}

/** A recording with no run to show (never organised, Save Video Only): its head alone. */
export function RecordingDetail({ rec }: { rec: RecDetail }) {
  return (
    <section className="mw-jobdetail" data-testid="recording-detail">
      <RecordingHead rec={rec} job={null} />
    </section>
  );
}

/** `rec`: the recording this run organises, while it is that recording's newest run. */
export function JobDetail({ job, title, onItem, onSettings, rec }: { job: Job; title: string; onItem: (uid: string) => void; onSettings: (pane: string) => void; rec?: RecDetail | null }) {
  const [rows, setRows] = useState<Record<string, ItemRow>>({});
  const key = job.items.slice(0, 20).join(',');
  useEffect(() => {
    let alive = true;
    Promise.all(job.items.slice(0, 20).map((u) => api.item(u).catch(() => null))).then((l) => {
      if (alive) setRows(Object.fromEntries(l.filter((r): r is ItemRow => !!r).map((r) => [r.uid, r])));
    });
    return () => {
      alive = false;
    };
  }, [key]);
  const status = job.state === 'failed' ? t('job.state.failed') : t(`job.state.${job.state}`);
  const live = job.state === 'running' || job.state === 'queued';
  // how long it has run, ticking while it runs (the Mac's "0:04 elapsed"; h:mm:ss from an hour on)
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!live) return;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [live]);
  const since = job.started ? Date.parse(job.started) : NaN;
  const secs = Number.isFinite(since) ? Math.max(0, Math.round(((live ? now : Date.parse(job.ended ?? '') || now) - since) / 1000)) : null;
  const clock = secs == null ? '' : i18n().formatDuration(secs, 'clock');
  // a Try Again that couldn't start: why, in words (no agent → the same sentence as the job's own)
  const [retryError, setRetryError] = useState<string | null>(null);
  useEffect(() => setRetryError(null), [job.id]);
  const ended = job.state === 'failed' || job.state === 'cancelled';
  const canRetry = ended && job.type === 'process' && !!job.session;
  const retry = () => {
    if (!job.session) return;
    setRetryError(null);
    api.processSession(job.session).catch((e: unknown) => setRetryError(String(e) === 'no_agent' ? 'no_agent' : 'unknown'));
  };
  const errorText = (code: string) => (t(`main.job.error.${code}`) === `main.job.error.${code}` ? t('main.job.error.unknown') : t(`main.job.error.${code}`));
  const step = job.steps.find((x) => x.state === 'running');
  const pct = job.progress != null && live ? Math.round(job.progress * 100) : null;
  const progress = live && (
    <div className="mw-job-progress" aria-label={status}>
      <div className="mw-job-bar"><span style={{ width: pct != null ? `${Math.max(4, pct)}%` : '30%' }} className={pct == null ? 'indet' : ''} /></div>
      <div className="mw-job-cap">
        <span>{step ? t(`job.step.${step.id}`) : status}{pct != null ? ` · ${pct}%` : ''}</span>
        {clock && <span>{t('main.job.elapsed', { a: clock })}</span>}
      </div>
    </div>
  );
  return (
    <section className="mw-jobdetail" data-testid="job-detail">
      {rec ? (
        <>
          <RecordingHead rec={rec} job={job} />
          {progress}
        </>
      ) : (
        <>
          <h2>{title}</h2>
          <p className="dim small">{live ? (job.started ? t('main.job.started', { a: ago(job.started) }) : status) : `${status}${job.ended ? ` · ${ago(job.ended)}` : ''}`}</p>
          {progress}
          {job.error && <p className="mw-err">{errorText(job.error.code)}</p>}
          {retryError && retryError !== job.error?.code && <p className="mw-err">{errorText(retryError)}</p>}
          {/* no agent to run it, or the one there isn't signed in: where that's fixed (the Home page's Set Up an Agent…) */}
          {(job.error?.code === 'no_agent' || job.error?.code === 'auth' || retryError === 'no_agent') && (
            <p className="mw-job-acts">
              <button className="pg-small" onClick={() => onSettings('agents')}>{t('home.recording.set_up_agent')}</button>
            </p>
          )}
          {ended && (canRetry || job.session || job.log || (job.state === 'failed' && !job.dismissed)) && (
            <p className="mw-job-actions">
              {canRetry && <button className="pg-small" onClick={retry}>{t('main.job.retry')}</button>}
              {job.session && <button className="pg-small" onClick={() => void api.reveal(job.session!).catch(() => {})}>{revealLabel()}</button>}
              {job.log && <button className="pg-small" onClick={() => void api.openPath(job.log!).catch(() => {})}>{t('main.job.show_log')}</button>}
              {job.state === 'failed' && !job.dismissed && <button className="pg-small" onClick={() => void api.jobDismiss(job.id).catch(() => {})}>{t('main.job.dismiss')}</button>}
            </p>
          )}
        </>
      )}
      {job.steps.length > 0 && (
        <>
          <h3 className="mw-sheet-sec">{t('main.job.steps')}</h3>
          <div className="mw-group">
            {job.steps.map((s) => (
              <div key={s.id} className={`mw-group-row st-${s.state}`} data-tip={t(`main.job.step_state.${s.state}`)}>
                <span className="mw-step-ic">
                  {s.state === 'done' ? <Icon name="check" size={12} /> : s.state === 'running' ? <span className="mw-spinner sm" /> : s.state === 'failed' ? <Icon name="warning" size={12} /> : <span className="mw-dot" />}
                </span>
                <span className="grow">{t(`job.step.${s.id}`)}</span>
              </div>
            ))}
          </div>
        </>
      )}
      <h3 className="mw-sheet-sec">
        {t('main.job.items')} {job.items.length > 0 && <span className="dim">{job.items.length}</span>}
      </h3>
      <div className="mw-group">
        {job.items.length ? (
          job.items.slice(0, 20).map((uid) => (
            <button key={uid} className="mw-group-row link" onClick={() => onItem(uid)}>
              {rows[uid] ? <KindIcon kind={rows[uid].kind} size={14} /> : <Icon name="document" size={13} />}
              <span className="mw-c-id">{rows[uid]?.item_id ?? ''}</span>
              <span className="grow mw-tt">{rows[uid]?.title ?? uid}</span>
              <Icon name="chevron-right" size={12} />
            </button>
          ))
        ) : (
          <div className="mw-group-row dim">{job.state === 'running' || job.state === 'queued' ? t('main.job.items.waiting') : t('main.job.items.none')}</div>
        )}
        {job.items.length > 20 && <div className="mw-group-row dim small">{plural('main.items.count', job.items.length)}</div>}
      </div>
    </section>
  );
}
