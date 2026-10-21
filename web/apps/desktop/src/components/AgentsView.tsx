import { Fragment, useEffect, useState } from 'react';
import { api, listen, type AgentRun, type Detect } from '../api';
import { ago, t } from '../util';
import { Icon } from '../icons';

function duration(r: AgentRun) {
  const s = Math.round((r.ended ?? Date.now() / 1000) - r.started);
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m${String(s % 60).padStart(2, '0')}s`;
}

/** Readable line from stream-json / jsonl agent output (assistant text, tool calls), else the raw line. */
function pretty(line: string): string {
  try {
    const v = JSON.parse(line);
    const content = v?.message?.content;
    if (Array.isArray(content)) {
      return content
        .map((c: any) => (c.type === 'text' ? c.text : c.type === 'tool_use' ? `→ ${c.name} ${JSON.stringify(c.input ?? {}).slice(0, 120)}` : ''))
        .filter(Boolean)
        .join(' ');
    }
    if (v?.type === 'result') return `done: ${v.result ?? ''}${v.total_cost_usd ? ` ($${Number(v.total_cost_usd).toFixed(2)})` : ''}`;
    if (v?.msg?.type) return `${v.msg.type}${v.msg.message ? `: ${v.msg.message}` : ''}`;
    return line;
  } catch {
    return line;
  }
}

export function AgentsView({ onToast }: { onToast: (m: string) => void }) {
  const [detect, setDetect] = useState<Detect | null>(null);
  const [runs, setRuns] = useState<AgentRun[]>([]);
  const [open, setOpen] = useState<string | null>(null);

  useEffect(() => {
    api.detect().then(setDetect, (e) => onToast(String(e)));
    const load = () => api.runs().then(setRuns);
    load();
    const offs = [
      listen<{ run_id: string; line: string }>('agent://line', ({ run_id, line }) =>
        setRuns((rs) => rs.map((r) => (r.run_id === run_id ? { ...r, lines: [...r.lines.slice(-399), line] } : r))),
      ),
      listen('agent://started', load),
      listen('agent://exit', load),
    ];
    return () => offs.forEach((o) => o());
  }, []);

  return (
    <div className="agents" data-testid="agents">
      <h2>{t('Agent', 'Agents')}</h2>
      {!detect ? (
        <p className="dim">{t('检测中…', 'Detecting…')}</p>
      ) : (
        <div className="agent-cards">
          {detect.agents.map((a) => (
            <div key={a.id} className={`agent-card ${a.login === 'ok' ? 'ok' : a.installed ? 'warn' : 'off'}`}>
              <b>{a.name}</b> {detect.pick === a.id && <span className="badge">{t('默认', 'default')}</span>}
              <div className="dim small">{a.why}{a.version ? ` · ${a.version}` : ''}</div>
              {a.fix && <div className="small">{a.fix}</div>}
            </div>
          ))}
        </div>
      )}
      <h3>{t('运行记录', 'Runs')}</h3>
      {!runs.length && <p className="dim">{t('还没有运行。在条目上按 Ctrl+Enter 让 agent 修。', 'No runs yet. Press Ctrl+Enter on an item to let an agent fix it.')}</p>}
      <table className="grid runs">
        <tbody>
          {runs.map((r) => (
            <Fragment key={r.run_id}>
              <tr className={`run-${r.state}`} onClick={() => setOpen(open === r.run_id ? null : r.run_id)}>
                <td><Icon name={r.state === 'running' ? 'dot' : r.state === 'done' ? 'check' : r.state === 'stopped' ? 'stop' : 'x'} size={14} /></td>
                <td><b>{r.agent}</b></td>
                <td className="dim">{r.repo.split(/[\\/]/).pop()}</td>
                <td>{r.items.map((i) => i.id).filter(Boolean).join(', ')}</td>
                <td className="dim">{ago(r.started)} · {duration(r)}</td>
                <td>{r.cost_usd != null ? `$${r.cost_usd.toFixed(2)}` : ''}</td>
                <td>{r.state === 'running' && <button className="link" onClick={(e) => { e.stopPropagation(); api.stopRun(r.run_id); }}>{t('停止', 'Stop')}</button>}</td>
              </tr>
              {open === r.run_id && (
                <tr className="log-row">
                  <td colSpan={7}><pre className="log">{r.lines.map(pretty).join('\n') || t('（还没有输出）', '(no output yet)')}</pre></td>
                </tr>
              )}
            </Fragment>
          ))}
        </tbody>
      </table>
    </div>
  );
}
