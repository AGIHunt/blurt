// The item list (K8): kind icon, work-state ring, a review dot for items still to review, the id, the title, what is
// happening to it, and its project when the list spans several. Click selects, Ctrl/⌘-click and Shift-click
// select more; rows drag onto a project in the sidebar.
import { memo } from 'react';
import { KindIcon, StatusRing } from '@blurt/ui/react';
import type { ItemRow } from '../api';
import { ago, t } from '../i18n';
import { agentName } from './SessionsView';

function Highlight({ text }: { text: string }) {
  // snippet(): matches are wrapped in [ ]
  const parts = text.split(/(\[[^\]]*\])/g);
  return <>{parts.map((p, i) => (p.startsWith('[') && p.endsWith(']') ? <mark key={i}>{p.slice(1, -1)}</mark> : p))}</>;
}

export const DRAG_TYPE = 'application/x-blurt-items';

function workNote(r: ItemRow): string {
  if (r.work_state === 'handed_off' || r.work_state === 'in_progress') {
    if (r.work_to === 'external') return t('work.handed_off.external');
    if (r.work_agent) return t('work.handed_off.session', { agent: agentName(r.work_agent) });
  }
  return r.work_state === 'todo' ? '' : t(`work.${r.work_state}`);
}

export const ItemList = memo(function ItemList({
  rows,
  selected,
  focus,
  showProject,
  projectName,
  onSelect,
  onOpen,
}: {
  rows: ItemRow[];
  selected: Set<string>;
  focus: string | null;
  showProject: boolean;
  projectName: (id: string) => string;
  onSelect: (uid: string, how: 'one' | 'toggle' | 'range') => void;
  onOpen: (r: ItemRow) => void;
}) {
  return (
    <div className="table" role="listbox" aria-multiselectable="true" data-testid="items">
      {rows.map((r) => {
        const sel = selected.has(r.uid);
        const note = workNote(r);
        return (
          <div
            key={r.uid}
            role="option"
            aria-selected={sel}
            data-uid={r.uid}
            data-testid="item-row"
            className={`row ${sel ? 'sel' : ''} ${focus === r.uid ? 'cur-row' : ''} st-${r.status} w-${r.work_state}`}
            draggable
            onDragStart={(e) => {
              const uids = sel ? [...selected] : [r.uid];
              e.dataTransfer.setData(DRAG_TYPE, JSON.stringify(uids));
              e.dataTransfer.effectAllowed = 'move';
            }}
            onClick={(e) => onSelect(r.uid, e.shiftKey ? 'range' : e.metaKey || e.ctrlKey ? 'toggle' : 'one')}
            onDoubleClick={() => onOpen(r)}
          >
            <span className={`rdot ${r.status === 'draft' ? 'on' : ''}`} title={r.status === 'draft' ? t('review.draft') : undefined} />
            <KindIcon kind={r.kind} size={15} title={t(`kind.${r.kind}`)} />
            <StatusRing state={r.work_state} size={14} label={t(`work.${r.work_state}`)} />
            <span className="iid">{r.item_id}</span>
            <span className="ititle">
              <span className="tt">{r.title || <i className="dim">{t('list.untitled')}</i>}</span>
              {r.snippet && <span className="snippet"><Highlight text={r.snippet} /></span>}
            </span>
            {note && <span className={`wnote w-${r.work_state}`}>{note}</span>}
            {r.project_id === 'inbox' && r.suggested_project && (
              <span className="suggest" title={r.suggested_confidence ? `${Math.round(r.suggested_confidence * 100)}%` : undefined}>
                {t('list.suggested', { project: projectName(r.suggested_project) })}
              </span>
            )}
            {showProject && <span className="pkey" title={r.project_name}>{r.project_key}</span>}
            <span className="age">{ago(r.updated)}</span>
          </div>
        );
      })}
    </div>
  );
});
