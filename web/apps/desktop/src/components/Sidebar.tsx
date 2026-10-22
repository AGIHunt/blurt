// The sidebar (K2): Inbox, agent sessions, then projects — the folders the user opened, plus Unassigned. Items dragged
// onto a project move there; a folder dropped anywhere on the window opens as a project (App handles that).
import { useState } from 'react';
import { Icon } from '@blurt/icons';
import type { Job, ProjectList, ProjectRow, Summary } from '../api';
import { i18n, t } from '../i18n';
import { DRAG_TYPE } from './ItemList';

export type View =
  | { kind: 'inbox' }
  | { kind: 'all' }
  | { kind: 'project'; id: string }
  | { kind: 'review'; session: string; title: string; back: View }
  | { kind: 'sessions'; job: string | null }
  | { kind: 'settings' };

const JOB_ICON: Record<string, string> = { process: 'hatching', route: 'git-branch', snap: 'screenshot', voice: 'voice', record: 'record' };

function Count({ n, tone }: { n: number; tone?: 'attn' }) {
  if (!n) return null;
  return <span className={`count ${tone ?? ''}`}>{i18n().formatNumber(n)}</span>;
}

export function Sidebar({
  view,
  onNav,
  projects,
  summary,
  jobs,
  waiting,
  onOpenFolder,
  onMove,
}: {
  view: View;
  onNav: (v: View) => void;
  projects: ProjectList | null;
  summary: Summary | null;
  jobs: Job[];
  waiting: number;
  onOpenFolder: () => void;
  onMove: (uids: string[], project: string) => void;
}) {
  const [over, setOver] = useState<string | null>(null);
  const is = (k: View['kind'], id?: string) => view.kind === k && (id === undefined || (view.kind === 'project' && view.id === id));
  const drop = (id: string) => ({
    onDragOver: (e: React.DragEvent) => {
      if (!e.dataTransfer.types.includes(DRAG_TYPE)) return;
      e.preventDefault();
      setOver(id);
    },
    onDragLeave: () => setOver((o) => (o === id ? null : o)),
    onDrop: (e: React.DragEvent) => {
      setOver(null);
      const raw = e.dataTransfer.getData(DRAG_TYPE);
      if (!raw) return;
      e.preventDefault();
      onMove(JSON.parse(raw) as string[], id);
    },
  });
  const row = (p: ProjectRow, icon: string) => (
    <a
      key={p.id}
      className={`${is('project', p.id) ? 'sel' : ''} ${over === p.id ? 'drop' : ''} ${p.exists ? '' : 'missing'}`}
      onClick={() => onNav({ kind: 'project', id: p.id })}
      title={p.exists ? p.path : `${p.path} — ${t('nav.missing')}`}
      data-testid={`nav-project-${p.id}`}
      {...drop(p.id)}
    >
      <Icon name={icon as never} size={16} />
      <span className="name">{p.name}</span>
      {projects?.current === p.id && <span className="cur" aria-hidden="true" />}
      <Count n={p.open_items} />
    </a>
  );
  const active = jobs.filter((j) => j.type !== 'agent' && (j.state === 'running' || j.state === 'queued'));
  return (
    <nav className="sidebar" aria-label="Blurt">
      <a className={is('inbox') ? 'sel' : ''} onClick={() => onNav({ kind: 'inbox' })} data-testid="nav-inbox">
        <Icon name="inbox" size={16} />
        <span className="name">{t('nav.inbox')}</span>
        <Count n={summary?.inbox ?? 0} />
      </a>
      <a className={is('sessions') ? 'sel' : ''} onClick={() => onNav({ kind: 'sessions', job: null })} data-testid="nav-sessions">
        <Icon name="terminal" size={16} />
        <span className="name">{t('nav.sessions')}</span>
        {waiting > 0 && <span className="attn" aria-label={t('session.waiting_input')} />}
      </a>
      <a className={is('all') ? 'sel' : ''} onClick={() => onNav({ kind: 'all' })} data-testid="nav-all">
        <Icon name="list" size={16} />
        <span className="name">{t('nav.all')}</span>
      </a>
      <div className="section">
        <span>{t('nav.projects')}</span>
        <button className="icon-btn" onClick={onOpenFolder} aria-label={t('nav.open_folder')} title={t('nav.open_folder')}>
          <Icon name="folder-plus" size={15} />
        </button>
      </div>
      <div className="projects">
        {projects?.projects.map((p) => row(p, 'folder'))}
        {projects && row(projects.inbox, 'inbox')}
        {projects && !projects.projects.length && (
          <button className="add-project" onClick={onOpenFolder}>
            <Icon name="folder-plus" size={16} />
            <span>{t('nav.open_folder')}</span>
          </button>
        )}
      </div>
      <div className="grow" />
      {active.length > 0 && (
        <div className="jobs" aria-label={t('nav.jobs')}>
          {active.slice(0, 3).map((j) => {
            const step = j.steps.find((s) => s.state === 'running') ?? j.steps.find((s) => s.state === 'pending');
            return (
              <div key={j.id} className="job">
                <span className={j.type === 'process' ? 'wobble' : ''}><Icon name={(JOB_ICON[j.type] ?? 'process') as never} size={15} /></span>
                <span className="txt">
                  <span className="nm">{j.title || t(`job.type.${j.type}`)}</span>
                  <span className="sub">{step ? t(`job.step.${step.id}`) : j.state === 'queued' ? t('jobs.queued') : ''}</span>
                </span>
              </div>
            );
          })}
        </div>
      )}
      <a className={is('settings') ? 'sel' : ''} onClick={() => onNav({ kind: 'settings' })} data-testid="nav-settings">
        <Icon name="settings" size={16} />
        <span className="name">{t('nav.settings')}</span>
      </a>
    </nav>
  );
}
