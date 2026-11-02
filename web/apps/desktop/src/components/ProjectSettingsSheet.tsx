// Project Settings… (the Mac's ProjectSettingsSheet, from the project's sidebar menu or Ctrl+I): the project's name,
// its key (the prefix of its item ids: editable while the project has no items, 2–5 letters or digits, a letter first,
// never IN — Unassigned's), the description organizing uses to file unassigned captures into it, then Hand-off: the
// agent its hand-offs start with (Default = the global one) and whether each hand-off gets its own branch (a git
// worktree). Saved with `projects.py set`, which checks the key again.
import { useEffect, useState } from 'react';
import { api, type ProjectRow } from '../api';
import { t } from '../i18n';
import { isImeKey } from '../ime';
import { Icon } from '@blurt/icons';
import { PanelSwitch } from './HandoffKit';

export const keyValid = (k: string) => /^[A-Z][A-Z0-9]{1,4}$/.test(k) && k !== 'IN';

export function ProjectSettingsSheet({ project, onSave, onClose }: {
  project: ProjectRow;
  onSave: (patch: Record<string, unknown>) => void;
  onClose: () => void;
}) {
  const [name, setName] = useState(project.name);
  const [key, setKey] = useState(project.key);
  const [desc, setDesc] = useState(project.description ?? '');
  const [agent, setAgent] = useState<string>(project.default_agent ?? '');
  const [worktree, setWorktree] = useState(project.worktree !== false);
  const [agents, setAgents] = useState<{ id: string; name: string }[]>([]);
  const [fallback, setFallback] = useState<string | null>(null);
  // items already use the key (ItemRow ids are made with it): it stays
  const keyLocked = project.items > 0;
  useEffect(() => {
    Promise.all([api.detect().catch(() => null), api.settings().catch(() => null)]).then(([d, s]) => {
      const list = (d?.agents ?? []).map((a) => ({ id: a.id, name: a.name }));
      setAgents(list);
      const def = (s?.config?.record?.default_agent as string | undefined) ?? d?.order?.[0];
      setFallback(list.find((a) => a.id === def)?.name ?? null);
    });
  }, []);
  const keyOk = keyLocked || keyValid(key);
  const save = () => {
    if (!name.trim() || !keyOk) return;
    const patch: Record<string, unknown> = {};
    if (name.trim() !== project.name) patch.name = name.trim();
    if (!keyLocked && key !== project.key) patch.key = key;
    if (desc.trim() !== (project.description ?? '')) patch.description = desc.trim();
    if ((agent || null) !== (project.default_agent ?? null)) patch.default_agent = agent || null;
    if (project.kind === 'repo' && worktree !== (project.worktree !== false)) patch.worktree = worktree;
    onClose();
    if (Object.keys(patch).length) onSave(patch);
  };
  const caption = keyLocked ? t('main.project.key.locked') : keyOk ? t('main.project.key.note', { a: key }) : key === 'IN' ? t('main.project.key.taken') : t('main.project.key.invalid');
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="sheet mw-sheet" role="dialog" aria-modal="true" aria-label={t('main.project.settings.subtitle')} data-testid="project-settings"
        onKeyDown={(e) => {
          if (e.key === 'Escape') {
            e.stopPropagation();
            onClose();
          } else if (e.key === 'Enter' && e.ctrlKey && !isImeKey(e)) save();
        }}>
        <h2>{project.name}</h2>
        <p className="dim small">{t('main.project.settings.subtitle')}</p>
        {/* the Mac's grouped form: a section header over a box of rows, a label column at the left, the control at the
            right, hairlines between the rows; a switch for the on/off setting, as Windows 11 Settings has it */}
        <h3 className="mw-sheet-sec">{t('main.project.section.project')}</h3>
        <div className="mw-form">
          <label className="mw-form-row">
            <span>{t('main.project.name')}</span>
            <input className="mw-field" autoFocus value={name} onChange={(e) => setName(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && !isImeKey(e) && save()} />
          </label>
          <div className="mw-form-row mw-key-row">
            <span>{t('main.project.key')}</span>
            <span className="mw-key-cell">
              {keyLocked ? (
                <span className="mw-key-chip" data-tip={t('main.project.key.locked')} data-testid="project-key-locked">
                  {project.key}
                  <svg className="ico" width={11} height={11} viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="11" width="14" height="10" rx="2" /><path d="M8 11V8a4 4 0 0 1 8 0v3" /></svg>
                </span>
              ) : (
                <input className={`mw-field mw-key ${keyOk ? '' : 'bad'}`} aria-label={t('main.project.key')} value={key} maxLength={5} onChange={(e) => setKey(e.target.value.toUpperCase())} data-testid="project-key" />
              )}
              <span className={`small ${keyOk ? 'dim' : 'mw-err'}`}>{keyLocked ? t('main.project.key.note', { a: project.key }) : caption}</span>
            </span>
          </div>
          <label className="mw-form-row mw-top">
            <span>{t('main.project.description')}</span>
            <span>
              <textarea className="mw-field mw-details" value={desc} placeholder={t('main.project.description.placeholder')} onChange={(e) => setDesc(e.target.value)} />
              <span className="dim small mw-note">{t('main.project.description.note')}</span>
            </span>
          </label>
        </div>
        <h3 className="mw-sheet-sec">{t('main.project.section.handoff')}</h3>
        <div className="mw-form">
          <label className="mw-form-row">
            <span>{t('main.project.agent')}</span>
            <span className="mw-end">
              <select className="mw-field mw-select" value={agent} onChange={(e) => setAgent(e.target.value)} data-testid="project-agent">
                <option value="">{fallback ? t('main.project.agent.default_named', { a: fallback }) : t('main.project.agent.default')}</option>
                {agents.map((a) => (
                  <option key={a.id} value={a.id}>{a.name}</option>
                ))}
              </select>
            </span>
          </label>
          <div className="mw-form-row mw-switch-row">
            <span className="mw-switch-txt">
              <span>{t('main.project.worktree')}</span>
              <span className="dim small mw-note">{project.kind === 'repo' ? t('main.project.worktree.note') : t('main.project.worktree.no_git')}</span>
            </span>
            <PanelSwitch label={t('main.project.worktree')} on={project.kind === 'repo' && worktree} disabled={project.kind !== 'repo'} onChange={setWorktree} />
          </div>
        </div>
        <div className="mw-sheet-foot">
          <span className="dim small mw-sheet-path" data-tip={project.path}>
            <Icon name="folder" size={13} />
            <span>{project.path.split(/[\\/]/).filter(Boolean).pop() ?? project.path}</span>
          </span>
          <span className="grow" />
          <button onClick={onClose}>{t('action.cancel')}</button>
          <button className="primary" disabled={!name.trim() || !keyOk} onClick={save}>{t('action.save')}</button>
        </div>
      </div>
    </div>
  );
}
