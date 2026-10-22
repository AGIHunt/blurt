// The item list (K8): kind icon, the state ring (click it for the K3 actions), the id, the title, who has it, and its
// project when the list spans several. Click selects, Ctrl/⌘-click and Shift-click select more; rows drag onto a
// project in the sidebar.
import { memo } from 'react';
import type { Action } from '@blurt/ui';
import { KindIcon, StatePill } from '@blurt/ui/react';
import type { ItemRow } from '../api';
import { ago, t } from '../i18n';
import { agentName } from './SessionsView';

function Highlight({ text }: { text: string }) {
  // snippet(): matches are wrapped in [ ]
  const parts = text.split(/(\[[^\]]*\])/g);
  return <>{parts.map((p, i) => (p.startsWith('[') && p.endsWith(']') ? <mark key={i}>{p.slice(1, -1)}</mark> : p))}</>;
}

export const DRAG_TYPE = 'application/x-blurt-items';

/** The state's name; "handed off" says to whom. */
export function stateText(r: ItemRow): string {
  if (r.state === 'handed_off' && r.work_to === 'external') return t('state.handed_off.external');
  if (r.state === 'handed_off' && r.work_agent) return t('state.handed_off.session', { agent: agentName(r.work_agent) });
  return t(`state.${r.state}`);
}

/** what the row says besides the ring: who has it, or the state when it is worth words (not new / to do) */
function stateNote(r: ItemRow): string {
  if (r.state === 'in_progress' && r.work_agent) return `${t('state.in_progress')} · ${agentName(r.work_agent)}`;
  return r.state === 'new' || r.state === 'todo' ? '' : stateText(r);
}

export const ItemList = memo(function ItemList({
  rows,
  selected,
  focus,
  showProject,
  projectName,
  onSelect,
  onOpen,
  onAction,
  canHandOff = true,
  mac = false,
}: {
  rows: ItemRow[];
  selected: Set<string>;
  focus: string | null;
  showProject: boolean;
  projectName: (id: string) => string;
  onSelect: (uid: string, how: 'one' | 'toggle' | 'range') => void;
  onOpen: (r: ItemRow) => void;
  /** a pick from the row's state menu */
  onAction: (r: ItemRow, a: Action) => void;
  canHandOff?: boolean;
  mac?: boolean;
}) {
  return (
    <div className="table" role="listbox" aria-multiselectable="true" data-testid="items">
      {rows.map((r) => {
        const sel = selected.has(r.uid);
        const note = stateNote(r);
        return (
          <div
            key={r.uid}
            role="option"
            aria-selected={sel}
            data-uid={r.uid}
            data-testid="item-row"
            className={`row ${sel ? 'sel' : ''} ${focus === r.uid ? 'cur-row' : ''} s-${r.state}`}
            draggable
            onDragStart={(e) => {
              const uids = sel ? [...selected] : [r.uid];
              e.dataTransfer.setData(DRAG_TYPE, JSON.stringify(uids));
              e.dataTransfer.effectAllowed = 'move';
            }}
            onClick={(e) => onSelect(r.uid, e.shiftKey ? 'range' : e.metaKey || e.ctrlKey ? 'toggle' : 'one')}
            onDoubleClick={() => onOpen(r)}
          >
            <KindIcon kind={r.kind} size={15} title={t(`kind.${r.kind}`)} />
            <StatePill variant="ring" state={r.state} label={stateText(r)} t={t} onPick={(a) => onAction(r, a)} canHandOff={canHandOff} keys={false} mac={mac} />
            <span className="iid">{r.item_id}</span>
            <span className="ititle">
              <span className="tt">{r.title || <i className="dim">{t('list.untitled')}</i>}</span>
              {r.snippet && <span className="snippet"><Highlight text={r.snippet} /></span>}
            </span>
            {note && <span className={`wnote s-${r.state}`}>{note}</span>}
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
