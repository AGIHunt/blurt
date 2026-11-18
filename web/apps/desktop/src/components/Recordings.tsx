// A recording's row, where it shows (recordings.ts; docs/design/capabilities.md §4): Home's Recent and the items'
// places. Kind glyph, length, the first thing said in it, its state in one word (N 个事项 / 未整理 / 整理中 / 未完成 /
// 仅保存视频: why, and where it got to, are the tooltip's and the detail's), its time; the click shows its detail
// (RecordingDetail) or its items, the right-click menu does what fits the state (play the video, show it in the
// folder, organise or retry it — or, with no agent to do it, Set Up an Agent… / copy what to say to one —, Dismiss a
// failure).
import { useEffect, useMemo, useState } from 'react';
import { Icon } from '@blurt/icons';
import { api, type Job } from '../api';
import { i18n, plural, t } from '../i18n';
import { hasItems, inlineAction, recActions, type RecAction, type Recording, type RecState } from '../recordings';
import { revealLabel } from '../reveal';
import type { MenuEntry } from './Menu';

/** Asks the agent check again (an Organize or Retry found no agent after all). */
const RECHECK = 'blurt:agent-recheck';
export const recheckAgent = () => window.dispatchEvent(new Event(RECHECK));

/** Whether an agent can organise in the background (null until known; never asked while Recording & Items is off):
 *  the full check, sign-in included (agents_ready: the detect a run starts from, cached), asked again when the
 *  window comes back to the front. */
export function useAgentReady(on: boolean): boolean | null {
  const [ready, setReady] = useState<boolean | null>(null);
  useEffect(() => {
    if (!on) return;
    let alive = true;
    const ask = () => void api.agentsReady().then((b) => alive && setReady(b), () => {});
    ask();
    window.addEventListener('focus', ask);
    window.addEventListener(RECHECK, ask);
    return () => {
      alive = false;
      window.removeEventListener('focus', ask);
      window.removeEventListener(RECHECK, ask);
    };
  }, [on]);
  return ready;
}

/** The state in one word: "3 items", "Organizing", "Didn’t finish", "Not organized", "Video only". */
export function recStateText(r: Recording): string {
  return stateWord(r.state);
}

function stateWord(s: RecState): string {
  switch (s.kind) {
    case 'items':
      return plural('rec.state.items', s.n);
    case 'organising':
      return t('rec.state.organising');
    case 'failed':
      return t('rec.state.failed');
    case 'video_only':
      return t('rec.state.video_only');
    case 'unorganised':
      return t('rec.state.unorganised');
  }
}

/** The whole sentence of a failure. `agent`: an agent can organise now — then a run that found none says only that
 *  (the way forward, Retry, is beside it). */
export function recWhy(r: Recording, agent: boolean | null = null): string {
  if (r.state.kind !== 'failed') return '';
  if (r.state.code === 'no_agent' && agent === true) return t('rec.why.no_agent_then');
  const k = `main.job.error.${r.state.code}`;
  return i18n().has(k) ? t(k) : t('main.job.error.unknown');
}

/** The row's tooltip: what the one word leaves out — why it didn't finish, where it has got to, the video gone. */
export function recTip(r: Recording, agent: boolean | null = null): string {
  const s = r.state;
  const parts = [
    s.kind === 'failed' ? recWhy(r, agent) : s.kind === 'organising' && s.step ? `${t('rec.state.organising')} · ${t(`job.step.${s.step}`)}` : '',
    r.info.video ? '' : t('rec.video_gone'),
  ];
  return parts.filter(Boolean).join('\n');
}

/** What was said first in it, or "Untitled recording" when nothing was. */
export const recTitle = (r: Recording) => r.info.first_line || t('rec.untitled');

export const recLength = (r: Recording) => (r.info.duration ? i18n().formatDuration(Math.round(r.info.duration), 'clock') : '');

/** The words of an action, as the menu and the row's button say them (a failure's run: Show Details). */
export function actionLabel(a: RecAction, r?: Recording): string {
  switch (a) {
    case 'review':
      return t('rec.review');
    case 'progress':
      return r?.state.kind === 'failed' ? t('rec.show_details') : t('main.banner.show_progress');
    case 'play':
      return t('rec.play');
    case 'reveal':
      return revealLabel();
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
  /** a recording with no run to show: its own detail, in its place */
  onDetail: (r: Recording) => void;
  onSettings: (pane: string) => void;
  onToast: (m: string, action?: { label: string; run: () => void }) => void;
  /** after Organise / Retry / Dismiss: the jobs changed */
  onChanged?: () => void;
}

/** An Organize or Retry that couldn't start: no agent → the sentence the job would say, with Set Up an Agent…; else
 *  the error. */
export function startFailed(e: unknown, h: Pick<RecHandlers, 'onToast' | 'onSettings'>): void {
  if (String(e) !== 'no_agent') return h.onToast(String(e));
  recheckAgent();
  h.onToast(t('main.job.error.no_agent'), { label: t('home.recording.set_up_agent'), run: () => h.onSettings('agents') });
}

/** What a click on the recording does: its run's detail when it has one, its items when it has some, else its own
 *  detail (Play Video and Show in Folder are there). */
export function recClick(r: Recording): RecAction | 'detail' {
  if ((r.state.kind === 'organising' || r.state.kind === 'failed') && r.state.job) return 'progress';
  return hasItems(r) ? 'review' : 'detail';
}

/** Does an action (the menu's, the row's, the click's). */
export function runRecAction(a: RecAction | 'detail', r: Recording, h: RecHandlers): void {
  const fail = (e: unknown) => h.onToast(String(e));
  if (a === 'detail') return h.onDetail(r);
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
      void api.processSession(r.info.dir).then(() => h.onChanged?.(), (e) => startFailed(e, h));
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
  const entry = (a: RecAction): MenuEntry => ({ label: actionLabel(a, r), icon: ACTION_ICON[a] ? <Icon name={ACTION_ICON[a] as never} size={14} /> : undefined, run: () => runRecAction(a, r, h) });
  const main = acts.filter((a) => a !== 'dismiss').map(entry);
  return acts.includes('dismiss') ? [...main, { kind: 'separator' }, entry('dismiss')] : main;
}

/** The recordings at the top of an items' place (where the organising job's row was): a header "Recordings 2", then
 *  one row each on the list's grid — glyph, length, the first line, the state (with its one action), the time. */
export function RecordingsSection({ recs, agent, selectedJob, selectedDir, handlers, onMenu }: {
  recs: Recording[];
  agent: boolean | null;
  /** the job shown in the detail (its recording's row is the selected one) */
  selectedJob: string | null;
  /** the recording shown in the detail */
  selectedDir: string | null;
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
        // the click shows its run, or its own detail (Play Video, Show in Folder, Organize… are there); the row
        // itself has one action at most: Retry or Organize (Set Up an Agent… is the detail's)
        const click = recClick(r);
        const inline = ((a) => (a === 'set_up_agent' ? null : a))(inlineAction(r, agent));
        const failed = r.state.kind === 'failed';
        const sel = (job && job.id === selectedJob) || r.info.dir === selectedDir;
        return (
          <div key={r.info.dir} role="listitem" className={`mw-job mw-rec ${sel ? 'sel' : ''} ${failed ? 'failed' : ''}`}
            onClick={(e) => {
              if ((e.target as HTMLElement).closest('button')) return;
              runRecAction(click, r, handlers);
            }}
            onContextMenu={(e) => {
              e.preventDefault();
              onMenu(recMenu(r, agent, handlers), { x: e.clientX, y: e.clientY });
            }}
            data-tip={recTip(r, agent) || undefined} data-testid={`recording-${r.state.kind}`}>
            <span className="mw-c-kind"><Icon name="video" size={15} /></span>
            <span className="mw-c-id">{recLength(r)}</span>
            <span className="mw-c-title">
              <span className={`mw-tt ${r.info.first_line ? '' : 'quiet'}`}>{recTitle(r)}</span>
              <span className={`mw-hit ${failed ? 'attn' : ''}`}>{recStateText(r)}</span>
              {inline && <button className="mw-linkbtn" onClick={() => runRecAction(inline, r, handlers)} data-testid="recording-act">{actionLabel(inline, r)}</button>}
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
