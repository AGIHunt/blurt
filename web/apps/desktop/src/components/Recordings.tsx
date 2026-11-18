// A recording's row, where it shows (recordings.ts; docs/design/capabilities.md §3.2): Home's Recent and the items'
// places. Kind glyph, length, the first thing said in it, its state (N 个事项 / 未整理 / 整理中 / 未完成 + why /
// 仅保存视频), its time; the click and the right-click menu do what fits the state (play the video, show it in the
// folder, organise or retry it — or, with no agent to do it, Set Up an Agent… / copy what to say to one —, its items,
// Dismiss a failure).
import { useEffect, useMemo, useState } from 'react';
import { Icon } from '@blurt/icons';
import { api, type Job } from '../api';
import { i18n, plural, t } from '../i18n';
import { inlineAction, recActions, SHORT_WHY, type RecAction, type Recording, type RecState } from '../recordings';
import type { MenuEntry } from './Menu';

/** Whether an agent can organise in the background (null until known; never asked while Recording & Items is off). */
export function useAgentReady(on: boolean): boolean | null {
  const [ready, setReady] = useState<boolean | null>(null);
  useEffect(() => {
    if (!on) return;
    let alive = true;
    api.detect({ login: false }).then((d) => alive && setReady(!!d.pick), () => alive && setReady(null));
    return () => {
      alive = false;
    };
  }, [on]);
  return ready;
}

/** "3 items", "Organizing", "Didn’t finish · No agent available", "Video only" — and "Video deleted" once it's gone. */
export function recStateText(r: Recording): string {
  const s = r.state;
  const parts = [stateWord(s)];
  if (s.kind === 'failed' && SHORT_WHY.has(s.code)) parts.push(whyShort(s.code));
  if (!r.info.video) parts.push(t('rec.video_gone'));
  return parts.join(' · ');
}

function stateWord(s: RecState): string {
  switch (s.kind) {
    case 'items':
      return plural('rec.state.items', s.n);
    case 'organising':
      return s.step ? `${t('rec.state.organising')} · ${t(`job.step.${s.step}`)}` : t('rec.state.organising');
    case 'failed':
      return t('rec.state.failed');
    case 'video_only':
      return t('rec.state.video_only');
    case 'unorganised':
      return t('rec.state.unorganised');
  }
}

/** A failure's reason in a few words: the job's error sentence without its full stop ("The agent isn’t signed in"). */
function whyShort(code: string): string {
  if (code === 'no_agent') return t('rec.why.no_agent');
  return t(`main.job.error.${code}`).replace(/[。.]$/, '');
}

/** The whole sentence of a failure (the row's tooltip). */
export function recWhy(r: Recording): string {
  if (r.state.kind !== 'failed') return '';
  const k = `main.job.error.${r.state.code}`;
  return i18n().has(k) ? t(k) : t('main.job.error.unknown');
}

export const recLength = (r: Recording) => (r.info.duration ? i18n().formatDuration(Math.round(r.info.duration), 'clock') : '');

/** The words of an action, as the menu and the row's button say them. */
export function actionLabel(a: RecAction): string {
  switch (a) {
    case 'review':
      return t('rec.review');
    case 'progress':
      return t('main.banner.show_progress');
    case 'play':
      return t('rec.play');
    case 'reveal':
      return t('detail.reveal');
    case 'organise':
      return t('rec.organise');
    case 'retry':
      return t('home.entry.retry');
    case 'set_up_agent':
      return t('home.recording.set_up_agent');
    case 'copy_request':
      return t('rec.copy_request', { a: t('rec.request') });
    case 'dismiss':
      return t('rec.dismiss');
  }
}

const ACTION_ICON: Partial<Record<RecAction, string>> = { play: 'play', reveal: 'reveal', review: 'film', organise: 'spark', retry: 'refresh', copy_request: 'copy', progress: 'progress' };

export interface RecHandlers {
  onReview: (r: Recording) => void;
  onJob: (j: Job) => void;
  onSettings: (pane: string) => void;
  onToast: (m: string) => void;
  /** after Organise / Retry / Dismiss: the jobs changed */
  onChanged?: () => void;
}

/** Does an action (the menu's, the row's, the click's). */
export function runRecAction(a: RecAction, r: Recording, h: RecHandlers): void {
  const fail = (e: unknown) => h.onToast(String(e));
  switch (a) {
    case 'review':
      return h.onReview(r);
    case 'progress':
      if (r.state.kind === 'organising' || r.state.kind === 'failed') r.state.job && h.onJob(r.state.job);
      return;
    case 'play':
      if (r.info.video) void api.openPath(r.info.video).catch(fail);
      return;
    case 'reveal':
      void api.reveal(r.info.video ?? r.info.dir).catch(fail);
      return;
    case 'organise':
    case 'retry':
      void api.processSession(r.info.dir).then(() => h.onChanged?.(), fail);
      return;
    case 'set_up_agent':
      return h.onSettings('agents');
    case 'copy_request':
      void api.copyText(t('rec.request')).then(() => h.onToast(t('rec.request_copied')), fail);
      return;
    case 'dismiss':
      if (r.state.kind === 'failed') void api.jobDismiss(r.state.job.id).then(() => h.onChanged?.(), fail);
      return;
  }
}

/** The row's right-click menu: the click's action first, Dismiss last on its own. */
export function recMenu(r: Recording, agent: boolean | null, h: RecHandlers): MenuEntry[] {
  const acts = recActions(r, agent);
  const entry = (a: RecAction): MenuEntry => ({ label: actionLabel(a), icon: ACTION_ICON[a] ? <Icon name={ACTION_ICON[a] as never} size={14} /> : undefined, run: () => runRecAction(a, r, h) });
  const main = acts.filter((a) => a !== 'dismiss').map(entry);
  return acts.includes('dismiss') ? [...main, { kind: 'separator' }, entry('dismiss')] : main;
}

/** The recordings at the top of an items' place (where the organising job's row was): a header "Recordings 2", then
 *  one row each on the list's grid — glyph, length, the first line, the state (with its one action), the time. */
export function RecordingsSection({ recs, agent, selectedJob, showProject, handlers, onMenu }: {
  recs: Recording[];
  agent: boolean | null;
  /** the job shown in the detail (its recording's row is the selected one) */
  selectedJob: string | null;
  showProject: boolean;
  handlers: RecHandlers;
  onMenu: (entries: MenuEntry[], at: { x: number; y: number }) => void;
}) {
  const [open, setOpen] = useState(true);
  if (!recs.length) return null;
  const head = `${t('rec.section')} ${i18n().formatNumber(recs.length)}`;
  return (
    <div className="mw-jobs mw-recs" role="list" aria-label={head} data-testid="recordings">
      <button className="mw-jobs-head" onClick={() => setOpen(!open)} aria-expanded={open} data-testid="recordings-head">
        <span className="mw-section-name">{t('rec.section')}</span>
        <span className="mw-section-n">{i18n().formatNumber(recs.length)}</span>
        <Icon name={open ? 'chevron-down' : 'chevron-right'} size={11} />
      </button>
      {open && recs.map((r) => {
        const job = r.state.kind === 'organising' || r.state.kind === 'failed' ? r.state.job : null;
        // a row of the list shows its job in the detail when it has one (the failure's words, Set Up an Agent…,
        // Retry, Dismiss); else it does its first action. Set Up an Agent… isn't drawn on the row: the detail has it
        const click: RecAction = job ? 'progress' : recActions(r, agent)[0];
        const inline = ((a) => (a === 'set_up_agent' ? null : a))(inlineAction(r, agent));
        const failed = r.state.kind === 'failed';
        const line = r.info.first_line || (showProject ? r.info.project_name : '') || t('inbox.mode.video');
        return (
          <div key={r.info.dir} role="listitem" className={`mw-job mw-rec ${job && job.id === selectedJob ? 'sel' : ''} ${failed ? 'failed' : ''}`}
            onClick={(e) => {
              if ((e.target as HTMLElement).closest('button')) return;
              runRecAction(click, r, handlers);
            }}
            onContextMenu={(e) => {
              e.preventDefault();
              onMenu(recMenu(r, agent, handlers), { x: e.clientX, y: e.clientY });
            }}
            data-tip={recWhy(r) || undefined} data-testid={`recording-${r.state.kind}`}>
            <span className="mw-c-kind"><Icon name="video" size={15} /></span>
            <span className="mw-c-id">{recLength(r)}</span>
            <span className="mw-c-title">
              <span className={`mw-tt ${r.info.first_line ? '' : 'quiet'}`}>{line}</span>
              <span className={`mw-hit ${failed ? 'attn' : ''}`}>{recStateText(r)}</span>
              {inline && <button className="mw-linkbtn" onClick={() => runRecAction(inline, r, handlers)} data-testid="recording-act">{actionLabel(inline)}</button>}
            </span>
            <span className="mw-c-ring">{failed ? <Icon name="warning" size={13} /> : r.state.kind === 'organising' ? <span className="mw-spinner sm" /> : null}</span>
            <span className="mw-c-time">{when(r.info.created)}</span>
          </div>
        );
      })}
    </div>
  );
}

/** Today: the time; else the date. */
function when(created: number | null): string {
  if (!created) return '';
  const d = new Date(created * 1000);
  const today = new Date();
  const same = d.toDateString() === today.toDateString();
  return new Intl.DateTimeFormat(i18n().locale, same ? { hour: 'numeric', minute: '2-digit' } : { month: 'numeric', day: 'numeric' }).format(d);
}

/** The recordings with their state, reloaded with the window's tick. */
export function useRecordingInfos(on: boolean, tick: number) {
  const [infos, setInfos] = useState<Awaited<ReturnType<typeof api.recordings>>>([]);
  useEffect(() => {
    if (!on) return setInfos([]);
    let alive = true;
    api.recordings().then((l) => alive && setInfos(l), () => {});
    return () => {
      alive = false;
    };
  }, [on, tick]);
  return useMemo(() => infos, [infos]);
}
