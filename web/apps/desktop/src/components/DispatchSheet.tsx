// Hand items to an agent (contract K5): which agent, together or in parallel, worktree or not. A dry run first tells
// us what the real one would warn about; editing in a folder another session is already changing gets the K5
// reminder with its two buttons — never a block. The other road (K6) sits at the bottom: copy it for your own agent.
import { useEffect, useMemo, useState } from 'react';
import { Icon } from '@blurt/icons';
import { api, type AgentInfo, type DispatchWarning, type ProjectRow } from '../api';
import { plural, t, errText } from '../i18n';

export function DispatchSheet({
  uids,
  project,
  onClose,
  onStarted,
  onToast,
}: {
  uids: string[];
  project: ProjectRow | null;
  onClose: () => void;
  onStarted: (job: string, agent: string) => void;
  onToast: (msg: string) => void;
}) {
  const [agents, setAgents] = useState<AgentInfo[] | null>(null);
  const [agent, setAgent] = useState<string>('');
  const [mode, setMode] = useState<'together' | 'parallel'>('together');
  const isRepo = project?.kind === 'repo';
  const [worktree, setWorktree] = useState<boolean>(isRepo && project?.worktree !== false);
  const [warnings, setWarnings] = useState<DispatchWarning[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const pname = project?.name ?? '';

  useEffect(() => {
    api.detect().then(
      (d) => {
        const ok = d.agents.filter((a) => a.installed && (a.session ?? !!a.interactive));
        setAgents(ok);
        const pick = project?.default_agent && ok.some((a) => a.id === project.default_agent) ? project.default_agent : d.pick && ok.some((a) => a.id === d.pick) ? d.pick : ok[0]?.id;
        setAgent(pick ?? '');
      },
      () => setAgents([]),
    );
  }, []);

  const wt = mode === 'parallel' ? 'on' : worktree ? 'on' : 'off';
  const opts = useMemo(() => ({ items: uids, agent: agent || undefined, mode, worktree: (isRepo ? wt : 'off') as 'on' | 'off' }), [uids, agent, mode, wt, isRepo]);

  useEffect(() => {
    if (!agent) return;
    let alive = true;
    setWarnings(null);
    setError(null);
    api.dispatch({ ...opts, dryRun: true }).then(
      (r) => alive && setWarnings(r.warnings ?? []),
      (e) => {
        if (!alive) return;
        setWarnings([]);
        setError(errText(e));
      },
    );
    return () => {
      alive = false;
    };
  }, [opts]);

  const start = async () => {
    setBusy(true);
    try {
      const r = await api.dispatch(opts);
      const job = r.jobs[0]?.id;
      const name = agents?.find((a) => a.id === agent)?.name ?? agent;
      onToast(t('dispatch.started', { agent: name }));
      if (job) onStarted(job, agent);
      onClose();
    } catch (e) {
      setError(errText(e));
    } finally {
      setBusy(false);
    }
  };

  const copy = async (full: boolean) => {
    try {
      await api.handoff(uids, full);
      onToast(t(full ? 'act.copied_full' : 'act.copied'));
      onClose();
    } catch (e) {
      setError(errText(e));
    }
  };

  const concurrent = warnings?.find((w) => w.code === 'concurrent_edit');
  const others = (warnings ?? []).filter((w) => w.code !== 'concurrent_edit');

  return (
    <div className="overlay" onClick={onClose}>
      <div className="sheet dispatch" role="dialog" aria-modal="true" aria-labelledby="dispatch-title" onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => e.key === 'Escape' && onClose()}>
        <h3 id="dispatch-title">{plural('dispatch.title', uids.length)}</h3>
        {agents && !agents.length ? (
          <p className="note">{t('dispatch.no_agents')}</p>
        ) : (
          <>
            <div className="field">
              <span className="label">{t('dispatch.agent')}</span>
              <div className="seg" role="radiogroup">
                {(agents ?? []).map((a) => (
                  <button key={a.id} role="radio" aria-checked={agent === a.id} className={agent === a.id ? 'on' : ''} onClick={() => setAgent(a.id)}>
                    <Icon name="terminal" size={15} />
                    {a.name}
                  </button>
                ))}
              </div>
            </div>
            {uids.length > 1 && (
              <div className="field">
                <span className="label">{t('dispatch.mode')}</span>
                <div className="choices">
                  {(['together', 'parallel'] as const).map((m) => (
                    <button key={m} className={`choice ${mode === m ? 'on' : ''}`} onClick={() => setMode(m)} aria-pressed={mode === m}>
                      <b>{t(`dispatch.mode.${m}`)}</b>
                      <span>{t(`dispatch.mode.${m}.hint`)}</span>
                    </button>
                  ))}
                </div>
              </div>
            )}
            {isRepo && mode === 'together' && (
              <label className="field switch">
                <span className="label">{t('dispatch.worktree')}</span>
                <input type="checkbox" role="switch" checked={worktree} onChange={(e) => setWorktree(e.target.checked)} />
                <span className="hint">{t(worktree ? 'dispatch.worktree.hint' : 'dispatch.worktree.off_hint')}</span>
              </label>
            )}
            {concurrent && (
              <div className="reminder" role="status">
                <Icon name="warning" size={16} />
                <p>{t('dispatch.warn.concurrent_edit', { project: pname })}</p>
                <div className="row-btns">
                  <button onClick={() => setWorktree(true)}>{t('dispatch.warn.use_worktree')}</button>
                  <button className="primary" onClick={start} disabled={busy}>{t('dispatch.warn.continue')}</button>
                </div>
              </div>
            )}
            {others.map((w) => (
              <p key={w.code} className="note small">{t(`dispatch.warn.${w.code}`, { project: pname })}</p>
            ))}
            {error && <p className="warn small">{error}</p>}
          </>
        )}
        <div className="foot">
          <span className="copy">
            <span className="dim small">{t('dispatch.copy')}</span>
            <button className="link" onClick={() => copy(false)}><Icon name="copy" size={14} />{t('handoff.copy_instruction')}</button>
            <button className="link" onClick={() => copy(true)}>{t('handoff.copy_full')}</button>
          </span>
          <span className="grow" />
          <button onClick={onClose}>{t('dispatch.cancel')}</button>
          {!concurrent && (
            <button className="primary" onClick={start} disabled={busy || !agent || warnings === null || !!error} data-testid="dispatch-go">
              <Icon name="send" size={14} />
              {warnings === null && agent ? t('dispatch.checking') : t('dispatch.go')}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
