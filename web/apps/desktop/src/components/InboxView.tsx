// The inbox (v0.6 feedback → "收件箱 + 项目"): what waits for review, one card per capture batch, newest first, and a
// line about items Blurt couldn't place in a project. Nothing here ever opens by itself (K4).
import { Icon } from '@blurt/icons';
import type { BatchRow, Summary } from '../api';
import { ago, i18n, plural, t } from '../i18n';

const MODE_ICON = { video: 'video', shots: 'screenshot', voice: 'voice' } as const;

export function InboxView({ batches, summary, onReview, onUnassigned }: {
  batches: BatchRow[] | null;
  summary: Summary | null;
  onReview: (b: BatchRow) => void;
  onUnassigned: () => void;
}) {
  const toReview = summary?.to_review ?? 0;
  const unassigned = summary?.unassigned ?? 0;
  if (batches && !batches.length && !toReview && !unassigned) {
    return (
      <div className="hero-empty" data-testid="inbox-empty">
        <Icon name="hatched" size={30} />
        <h2>{t('inbox.empty.title')}</h2>
        <p>{t('inbox.empty.body')}</p>
      </div>
    );
  }
  return (
    <section className="inbox pad" data-testid="inbox">
      <header className="page-head">
        <h1>{t('inbox.title')}</h1>
        {toReview > 0 && <p className="lead">{plural('inbox.lead', toReview)}</p>}
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
                    {b.draft_count > 0 && <span className="pill">{plural('inbox.batch.drafts', b.draft_count)}</span>}
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
