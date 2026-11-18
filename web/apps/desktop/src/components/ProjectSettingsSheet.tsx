// Project Settings… (the Mac's ProjectSettingsSheet, from the project's sidebar menu or Ctrl+I): the project's name,
// its key (the prefix of its item ids: editable while the project has no items, 2–5 letters or digits, a letter first,
// never IN — Unassigned's), and the description organizing uses to file unassigned captures into it. Saved with
// `projects.py set`, which checks the key again.
import { useState } from 'react';
import type { ProjectRow } from '../api';
import { t } from '../i18n';
import { isImeKey } from '../ime';
import { Icon } from '@blurt/icons';

export const keyValid = (k: string) => /^[A-Z][A-Z0-9]{1,4}$/.test(k) && k !== 'IN';

export function ProjectSettingsSheet({ project, onSave, onClose }: {
  project: ProjectRow;
  onSave: (patch: Record<string, unknown>) => void;
  onClose: () => void;
}) {
  const [name, setName] = useState(project.name);
  const [key, setKey] = useState(project.key);
  const [desc, setDesc] = useState(project.description ?? '');
  // items already use the key (ItemRow ids are made with it): it stays
  const keyLocked = project.items > 0;
  const keyOk = keyLocked || keyValid(key);
  const save = () => {
    if (!name.trim() || !keyOk) return;
    const patch: Record<string, unknown> = {};
    if (name.trim() !== project.name) patch.name = name.trim();
    if (!keyLocked && key !== project.key) patch.key = key;
    if (desc.trim() !== (project.description ?? '')) patch.description = desc.trim();
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
