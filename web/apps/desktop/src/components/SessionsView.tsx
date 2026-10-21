// Agent sessions (contract K5): every dispatch is a window in the project's tmux session (or, without tmux, a pty
// the app runs). The list shows each one's live status from its job; the terminal on the right attaches to it.
// Worktree sessions end with a choice: review the diff, merge, open a PR, discard or keep the branch.
import { useEffect, useMemo, useState } from 'react';
import { Icon } from '@blurt/icons';
import { api, listen, type AgentSession, type ProjectRow } from '../api';
import { ago, plural, t, errText } from '../i18n';
import { Terminal } from './Terminal';

const AGENTS: Record<string, string> = { claude: 'Claude Code', codex: 'Codex', kimi: 'Kimi Code', opencode: 'OpenCode' };
export const agentName = (id: string | null | undefined) => (id ? AGENTS[id] ?? id : '');

interface Diff {
  base: string;
  branch: string;
  stat: { path: string; added: number; deleted: number }[];
  uncommitted: number;
}

export function SessionsView({ job, onPick, projects, onToast }: {
  job: string | null;
  onPick: (job: string | null) => void;
  projects: ProjectRow[];
  onToast: (m: string) => void;
}) {
  const [list, setList] = useState<AgentSession[] | null>(null);
  const [owned, setOwned] = useState<string[]>([]);
  const [ended, setEnded] = useState<Record<string, number>>({});
  const [diff, setDiff] = useState<Diff | null>(null);
  const [confirm, setConfirm] = useState(false);

  const load = () =>
    api.sessions(true).then(
      (r) => {
        setList(r.sessions);
        setOwned(r.owned ?? []);
      },
      () => setList([]),
    );
  useEffect(() => {
    load();
    const off = listen('jobs://changed', load);
    return off;
  }, []);
  useEffect(() => {
    if (!job && list?.length) onPick(list[0].job);
    setDiff(null);
    setConfirm(false);
  }, [list, job]);

  const cur = useMemo(() => list?.find((s) => s.job === job) ?? null, [list, job]);
  const pname = (id: string) => projects.find((p) => p.id === id)?.name ?? id;

  const finish = async (action: 'diff' | 'merge' | 'pr' | 'discard' | 'keep') => {
    if (!cur) return;
    try {
      const r = await api.finish(cur.job, action);
      if (action === 'diff') setDiff(r as unknown as Diff);
      else {
        setDiff(null);
        setConfirm(false);
        onToast(t(action === 'merge' ? 'sessions.merged' : action === 'pr' ? 'sessions.pr_opened' : action === 'discard' ? 'sessions.discarded' : 'sessions.finish.keep'));
        if (action === 'pr' && typeof r.url === 'string') void api.openUrl(r.url);
        load();
      }
    } catch (e) {
      onToast(errText(e));
    }
  };

  if (list && !list.length) {
    return (
      <div className="hero-empty">
        <Icon name="terminal" size={28} />
        <h2>{t('sessions.empty.title')}</h2>
        <p>{t('sessions.empty.body')}</p>
      </div>
    );
  }

  return (
    <div className="sessions-split">
      <aside className="session-list" aria-label={t('sessions.title')}>
        {(list ?? []).map((s) => (
          <button key={s.job} className={`srow ${s.job === job ? 'sel' : ''}`} onClick={() => onPick(s.job)} data-testid="session-row">
            <i className={`sdot s-${s.status}`} aria-hidden="true" />
            <span className="txt">
              <span className="nm">{agentName(s.agent)}<span className="ids">{s.items.join(', ')}</span></span>
              <span className="sub">{t(`session.${s.status}`)} · {pname(s.project)}</span>
            </span>
          </button>
        ))}
      </aside>
      <section className="session-main">
        {cur ? (
          <>
            <header className="session-bar">
              <div className="txt">
                <div className="nm">
                  {agentName(cur.agent)} <span className="ids">{cur.items.join(', ')}</span>
                  <span className={`schip s-${cur.status}`}>{t(`session.${cur.status}`)}</span>
                </div>
                <div className="sub">
                  {pname(cur.project)}
                  {cur.branch ? ` · ${t('sessions.branch', { branch: cur.branch })}` : ''}
                  {cur.started ? ` · ${t('sessions.started', { time: ago(cur.started) })}` : ''}
                  {' · '}
                  {owned.includes(cur.job) ? t('sessions.app_runner') : t('sessions.detached')}
                </div>
              </div>
              <span className="grow" />
              <button onClick={() => api.openExternal(cur.job).catch((e) => onToast(errText(e)))}>
                <Icon name="open-external" size={14} />
                {t('sessions.open_external')}
              </button>
              {!['exited', 'error'].includes(cur.status) && (
                <button onClick={() => api.stopSession(cur.job).then(load)}><Icon name="stop" size={14} />{t('sessions.stop')}</button>
              )}
              {cur.worktree && (
                <button className="primary" onClick={() => finish('diff')}><Icon name="git-branch" size={14} />{t('sessions.finish.diff')}</button>
              )}
            </header>
            {diff && (
              <div className="diff" role="region" aria-label={t('sessions.finish.diff')}>
                <div className="diff-head">
                  <b>{t('sessions.diff.title', { n: diff.stat.length })}</b>
                  <span className="dim small">{diff.branch} → {diff.base}</span>
                  {diff.uncommitted > 0 && <span className="warn small">{plural('sessions.diff.uncommitted', diff.uncommitted)}</span>}
                  <span className="grow" />
                  <button onClick={() => setDiff(null)} aria-label={t('dispatch.cancel')}><Icon name="x" size={14} /></button>
                </div>
                <ul className="stat">
                  {diff.stat.map((f) => (
                    <li key={f.path}><code>{f.path}</code><span className="add">+{f.added}</span><span className="del">−{f.deleted}</span></li>
                  ))}
                </ul>
                <div className="diff-acts">
                  {confirm ? (
                    <>
                      <span className="warn small">{t('sessions.finish.confirm_discard', { branch: diff.branch })}</span>
                      <span className="grow" />
                      <button onClick={() => setConfirm(false)}>{t('dispatch.cancel')}</button>
                      <button className="danger" onClick={() => finish('discard')}>{t('sessions.finish.discard')}</button>
                    </>
                  ) : (
                    <>
                      <button className="link" onClick={() => setConfirm(true)}>{t('sessions.finish.discard')}</button>
                      <button className="link" onClick={() => finish('keep')}>{t('sessions.finish.keep')}</button>
                      <span className="grow" />
                      <button onClick={() => finish('pr')}><Icon name="git-pull-request" size={14} />{t('sessions.finish.pr')}</button>
                      <button className="primary" onClick={() => finish('merge')}><Icon name="merge" size={14} />{t('sessions.finish.merge', { base: diff.base })}</button>
                    </>
                  )}
                </div>
              </div>
            )}
            <div className="term-wrap">
              <Terminal key={cur.job} job={cur.job} onExit={(code) => setEnded((m) => ({ ...m, [cur.job]: code }))} onError={(e) => onToast(errText(e))} />
              {ended[cur.job] !== undefined && <div className="term-ended">{t('sessions.ended', { code: ended[cur.job] })}</div>}
            </div>
          </>
        ) : (
          <div className="blank">{t('sessions.pick')}</div>
        )}
      </section>
    </div>
  );
}
