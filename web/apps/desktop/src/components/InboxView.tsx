// The inbox = what needs you (K3: new + to verify): the capture batches with new items, one card each, newest first;
// the items an agent says are finished, to check; and a line about items Blurt couldn't place in a project. Nothing
// here ever opens by itself (K4).
import type { Action } from '@blurt/ui';
import { Icon, Mascot } from '@blurt/icons';
import type { BatchRow, ItemRow, Summary } from '../api';
import { ago, i18n, needsYou, plural, t } from '../i18n';
import { ItemList } from './ItemList';

const MODE_ICON = { video: 'video', shots: 'screenshot', voice: 'voice' } as const;
const NONE = new Set<string>();

export function InboxView({ batches, summary, verify, onReview, onUnassigned, onOpenItem, onAction, projectName, mac }: {
  batches: BatchRow[] | null;
  summary: Summary | null;
  /** the items waiting to be verified */
  verify: ItemRow[] | null;
  onReview: (b: BatchRow) => void;
  onUnassigned: () => void;
  onOpenItem: (r: ItemRow) => void;
  onAction: (r: ItemRow, a: Action) => void;
  projectName: (id: string) => string;
  mac: boolean;
}) {
  const fresh = summary?.new ?? 0;
  const toVerify = summary?.to_verify ?? 0;
  const unassigned = summary?.unassigned ?? 0;
  if (summary && batches && !batches.length && !fresh && !toVerify && !unassigned) {
    return (
      <div className="hero-empty" data-testid="inbox-empty">
        <span className="art g-field" aria-hidden="true">
          <Mascot clip="happy" size={80} />
        </span>
        <h2>{t('inbox.empty.title')}</h2>
        <p>{t('inbox.empty.body')}</p>
      </div>
    );
  }
  const lead = needsYou(fresh, toVerify);
  return (
    <section className="inbox pad" data-testid="inbox">
      <header className="page-head">
        <h1>{t('inbox.title')}</h1>
        {lead && <p className="lead" data-testid="needs-you">{lead}</p>}
      </header>
      {unassigned > 0 && (
        <button className="banner" onClick={onUnassigned}>
          <Icon name="inbox" size={16} />
          <span>{plural('inbox.unassigned', unassigned)}</span>
          <span className="grow" />
          <span className="link">{t('inbox.unassigned.open')}</span>
          <Icon name="chevron-right" size={14} />
        </button>
      )}
      {verify && verify.length > 0 && (
        <>
          <h2 className="sub-head">{t('inbox.verify')}</h2>
          <p className="sub-lead">{t('inbox.verify.hint')}</p>
          <div className="verify-list" data-testid="inbox-verify">
            <ItemList rows={verify} selected={NONE} focus={null} showProject projectName={projectName}
              onSelect={(uid) => { const r = verify.find((x) => x.uid === uid); if (r) onOpenItem(r); }}
              onOpen={onOpenItem} onAction={onAction} mac={mac} />
          </div>
        </>
      )}
      {batches && batches.length > 0 && (
        <>
          <h2 className="sub-head">{t('inbox.batches')}</h2>
          <ul className="batches">
            {batches.map((b) => (
              <li key={b.id}>
                <button className="batch" onClick={() => onReview(b)} data-testid="batch">
                  <span className={`mode m-${b.mode}`}><Icon name={MODE_ICON[b.mode] ?? 'video'} size={18} /></span>
                  <span className="txt">
                    <span className="nm">{b.title || t(`inbox.mode.${b.mode}`)}</span>
                    <span className="sub">
                      <span className="pkey">{b.project_key}</span> {b.project_name} · {ago(b.created)}
                      {b.mode === 'video' && b.duration ? ` · ${i18n().formatDuration(b.duration, 'narrow')}` : ''}
                    </span>
                  </span>
                  <span className="bcounts">
                    {b.new_count > 0 && <span className="pill">{plural('inbox.batch.new', b.new_count)}</span>}
                    <span className="dim small">{plural('inbox.batch.items', b.item_count)}</span>
                  </span>
                  <Icon name="chevron-right" size={14} className="chev" />
                </button>
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  );
}
