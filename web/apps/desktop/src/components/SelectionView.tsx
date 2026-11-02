// The detail for several selected items (the Mac's SelectionView): what is selected and what you can do with all of it,
// top-aligned at the detail's inset — "4 items selected", what the batch is (its kinds, its places), one row of buttons
// (the one brand primary, Move to Project…, the state action that moves the batch on, the rest in ⋯), the reason hand
// off can't go when it can't, then the batch one line each with × on hover to drop a row from the selection.
import { Icon } from '@blurt/icons';
import { KindIcon, StatusRing } from '@blurt/ui/react';
import type { ItemRow } from '../api';
import { plural, t } from '../i18n';
import { KINDS } from '@blurt/ui';

export interface PlanAction {
  id: string;
  title: string;
  tip: string;
  enabled: boolean;
}

const MAX_ROWS = 12;

export function SelectionView({ items, actions, primary, blocked, onAction, onMore, onRemove }: {
  items: ItemRow[];
  actions: PlanAction[];
  primary: string | null;
  blocked: string | null;
  onAction: (id: string, el: HTMLElement) => void;
  onMore: (el: HTMLElement) => void;
  onRemove: (uid: string) => void;
}) {
  const kinds = KINDS.map((k) => [k, items.filter((i) => i.kind === k).length] as const).filter(([, n]) => n > 0);
  const places: string[] = [];
  for (const it of items) {
    const n = it.project_id === 'inbox' ? t('project.inbox') : it.project_name;
    if (!places.includes(n)) places.push(n);
  }
  const shown = items.length > MAX_ROWS ? items.slice(0, MAX_ROWS - 1) : items;
  return (
    <section className="mw-selection" data-testid="selection">
      <h2>{plural('main.detail.multi', items.length)}</h2>
      <p className="mw-sel-what">
        {kinds.map(([k, n], i) => (
          <span key={k}>
            {i > 0 && ' · '}
            <KindIcon kind={k} size={13} /> {plural(`main.selection.kind.${k}`, n)}
          </span>
        ))}
        {places.length > 0 && <span> · {places.length <= 2 ? places.join(t('mw.list_sep')) : plural('main.selection.projects', places.length)}</span>}
      </p>
      <div className="mw-sel-acts">
        {actions.map((a) => (
          <button key={a.id} className={a.id === primary ? 'primary' : ''} disabled={!a.enabled} data-tip={a.tip} onClick={(e) => onAction(a.id, e.currentTarget)} data-testid={`sel-${a.id}`}>
            {a.title}
          </button>
        ))}
        <button className="mw-icon-btn" aria-label={t("main.selection.more")} data-tip={t("main.selection.more")} onClick={(e) => onMore(e.currentTarget)} data-testid="sel-more">
          <Icon name="more" size={16} />
        </button>
      </div>
      {blocked && (
        <p className="mw-sel-blocked">
          <Icon name="info" size={13} /> {blocked}
        </p>
      )}
      <div className="mw-sel-list" role="list" aria-label={t('main.selection.list')}>
        {shown.map((it) => (
          <div key={it.uid} className="mw-sel-row" role="listitem">
            <KindIcon kind={it.kind} size={15} />
            <StatusRing state={it.state} size={13} />
            <span className="mw-tt">{it.title || t('main.item.untitled')}</span>
            <span className="mw-sel-key" data-tip={it.project_id === 'inbox' ? t('project.inbox') : it.project_name}>{it.item_id}</span>
            <button className="mw-sel-x" aria-label={t("main.selection.remove")} data-tip={t("main.selection.remove")} onClick={() => onRemove(it.uid)}>
              <Icon name="x" size={11} />
            </button>
          </div>
        ))}
        {shown.length < items.length && <div className="mw-sel-more dim small">{plural('main.selection.more_rows', items.length - shown.length)}</div>}
      </div>
    </section>
  );
}
