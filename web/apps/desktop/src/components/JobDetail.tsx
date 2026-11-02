// A job in the detail (the Mac's JobDetailView, the part Windows has the data for): what it does and when it started,
// its steps in an inset group with each one's state, the items it wrote so far (a click shows one). An agent session's
// detail is its terminal (the Sessions pane), not this.
import { useEffect, useState } from 'react';
import { Icon } from '@blurt/icons';
import { KindIcon } from '@blurt/ui/react';
import { api, type ItemRow, type Job } from '../api';
import { ago, plural, t } from '../i18n';

export function JobDetail({ job, title, onItem }: { job: Job; title: string; onItem: (uid: string) => void }) {
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
  // how long it has run, ticking while it runs (the Mac's "0:04 elapsed")
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!live) return;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [live]);
  const since = job.started ? Date.parse(job.started) : NaN;
  const secs = Number.isFinite(since) ? Math.max(0, Math.round(((live ? now : Date.parse(job.ended ?? '') || now) - since) / 1000)) : null;
  const clock = secs == null ? '' : `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, '0')}`;
  const step = job.steps.find((x) => x.state === 'running');
  const pct = job.progress != null && live ? Math.round(job.progress * 100) : null;
  return (
    <section className="mw-jobdetail" data-testid="job-detail">
      <h2>{title}</h2>
      <p className="dim small">{live ? (job.started ? t('main.job.started', { a: ago(job.started) }) : status) : `${status}${job.ended ? ` · ${ago(job.ended)}` : ''}`}</p>
      {live && (
        <div className="mw-job-progress" aria-label={status}>
          <div className="mw-job-bar"><span style={{ width: pct != null ? `${Math.max(4, pct)}%` : '30%' }} className={pct == null ? 'indet' : ''} /></div>
          <div className="mw-job-cap">
            <span>{step ? t(`job.step.${step.id}`) : status}{pct != null ? ` · ${pct}%` : ''}</span>
            {clock && <span>{t('main.job.elapsed', { a: clock })}</span>}
          </div>
        </div>
      )}
      {job.error && <p className="mw-err">{t(`main.job.error.${job.error.code}`) === `main.job.error.${job.error.code}` ? t('main.job.error.unknown') : t(`main.job.error.${job.error.code}`)}</p>}
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
