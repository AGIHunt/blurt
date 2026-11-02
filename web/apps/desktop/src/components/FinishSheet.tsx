// Review Changes (the Mac's FinishPanel.swift): what to do with a worktree session's branch once the agent is done
// (`sessions.py finish`). The item it's about as the header, the branch → its base under it; the changed files in
// Settings' box (the directory dimmed, the name in ink, only counts that aren't zero) with the total and Open Diff on
// the heading's line; a footer — the rare ways out (Keep for Later, Discard…) in a bordered ⋯ on the left, then Cancel
// and the one default, Merge (Ctrl+Enter, never a bare Enter: it changes the base branch), a split button whose arrow
// holds Open Pull Request. Work the agent left uncommitted is committed by Blurt first ("Commit and Merge"). While the
// agent is still open the default is End Session and Review: it ends the agent and loads the diff again. merge / pr
// carry the review's token (`--expect`), so a worktree that changed since the diff loaded is refused (Review Again).
// A session or worktree that's gone turns the sheet into a small alert with one Close.
import { useEffect, useRef, useState } from 'react';
import { Icon } from '@blurt/icons';
import { KindIcon } from '@blurt/ui/react';
import { api } from '../api';
import { plural, t } from '../i18n';
import { errorWords, parseError, type ItemInfo, type Row } from '../sessions';
import { Menu, type MenuAt } from './Menu';
import { Panel, PanelBox, PanelFootnote, Spinner } from './HandoffKit';

interface FileStat {
  path: string;
  added: number;
  deleted: number;
}

type Phase = { k: 'loading' } | { k: 'ready' } | { k: 'working'; action: string } | { k: 'done'; action: string } | { k: 'failed'; why: string };

/** sessions.py codes after which there is nothing to try again: the session or its worktree is gone. */
const GONE = ['no_job', 'gone', 'no_worktree', 'bad_job'];
/** The file list scrolls past this many rows. */
const FILE_ROWS = 6;

export function FinishSheet({ row, items, onClose, onShowItem, onChanged }: {
  row: Row;
  items: Record<string, ItemInfo | null | undefined>;
  onClose: () => void;
  onShowItem?: (uid: string) => void;
  /** something landed or the session went: the pane reloads */
  onChanged?: () => void;
}) {
  const job = row.id;
  const [phase, setPhase] = useState<Phase>({ k: 'loading' });
  const [d, setD] = useState({ base: '', branch: '', files: [] as FileStat[], uncommitted: 0, ahead: 0, patch: null as string | null, alive: false, agentStatus: null as string | null, reviewed: null as string | null });
  const [prURL, setPrURL] = useState<string | null>(null);
  const [failedCode, setFailedCode] = useState<string | null>(null);
  const [lastAction, setLastAction] = useState<string | null>(null);
  const [takenBack, setTakenBack] = useState(0);
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const [menu, setMenu] = useState<MenuAt | null>(null);
  const more = useRef<HTMLButtonElement>(null);

  const load = async () => {
    setPhase({ k: 'loading' });
    setFailedCode(null);
    try {
      const o = await api.finish(job, 'diff');
      setD({
        base: o.base ?? '', branch: o.branch ?? '', uncommitted: o.uncommitted ?? 0, ahead: o.ahead ?? 0, alive: !!o.alive, agentStatus: o.agent_status ?? null,
        reviewed: o.reviewed ?? null, patch: o.patch || null,
        files: (o.stat ?? []).map((f: any) => ({ path: f.path ?? '', added: f.added ?? 0, deleted: f.deleted ?? 0 })),
      });
      setPhase({ k: 'ready' });
      return !!o.alive;
    } catch (e) {
      setFailedCode(parseError(e).code);
      setLastAction(null);
      setPhase({ k: 'failed', why: errorWords(e) });
      return false;
    }
  };
  useEffect(() => {
    void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [job]);

  const run = async (action: string) => {
    setPhase({ k: 'working', action });
    setLastAction(action);
    setFailedCode(null);
    try {
      const o = await api.finish(job, action as 'merge', ['merge', 'pr'].includes(action) ? d.reviewed : null);
      setPrURL(o.pr ?? o.compare ?? null);
      setTakenBack(Array.isArray(o.taken_back) ? o.taken_back.length : 0);
      // without gh (or a host it knows) nothing was opened: say what did happen
      setPhase({ k: 'done', action: action === 'pr' && typeof o.pr !== 'string' ? (o.compare ? 'compare' : 'pushed') : action });
      onChanged?.();
    } catch (e) {
      setFailedCode(parseError(e).code);
      setPhase({ k: 'failed', why: errorWords(e) });
    }
  };

  /** End the agent (Control-C as Interrupt does; its window closed when that isn't enough), then load the diff again. */
  const endAndReview = async () => {
    setPhase({ k: 'working', action: 'end' });
    setLastAction(null);
    await api.stopSession(job, false).catch(() => {});
    if (await load()) {
      await api.stopSession(job, true).catch(() => {});
      await load();
    }
    onChanged?.();
  };

  const busy = phase.k === 'working' ? phase.action : null;
  const empty = !d.files.length && d.ahead === 0 && d.uncommitted === 0;
  const first = row.job.labels[0];
  const kind = row.job.items[0] ? items[row.job.items[0]]?.kind : undefined;
  const added = d.files.reduce((s, f) => s + f.added, 0);
  const deleted = d.files.reduce((s, f) => s + f.deleted, 0);
  const primaryOff = !!busy || (empty && !d.alive);
  const mergeTitle = t(d.alive ? 'ses.finish.end_review' : d.uncommitted > 0 ? 'ses.finish.commit_merge' : 'ses.finish.merge');
  const close = () => {
    onClose();
    if (phase.k === 'failed' && GONE.includes(failedCode ?? '')) onChanged?.();
  };

  const counts = (a: number, del: number) => (
    <span className="fs-counts">
      {a > 0 && <span className="add">+{a}</span>}
      {del > 0 && <span className="del">−{del}</span>}
    </span>
  );

  const header = (
    <div className="fs-head">
      <div className="fs-title" role="heading" aria-level={2}>
        {first ? (
          <>
            {kind && <KindIcon kind={kind} size={16} title={t(`kind.${kind}`)} />}
            <span className="fs-ref">{first.id}</span>
            <span className="fs-name" title={first.title}>{row.job.labels.length > 1 ? t('ses.session.items.more', { a: first.title, b: row.job.labels.length - 1 }) : first.title}</span>
          </>
        ) : (
          <span className="fs-name">{t('ses.finish.title')}</span>
        )}
      </div>
      {d.branch && (
        <div className="fs-branch" title={t('ses.finish.subtitle', { a: d.branch, b: d.base })}>
          <code>{d.branch}</code>
          <span>{'  →  ' + d.base}</span>
        </div>
      )}
    </div>
  );

  // ---- failures: a small alert
  if (phase.k === 'failed') {
    const code = failedCode ?? '';
    const gone = GONE.includes(code);
    const key = code === 'gone' ? 'ses.review.folder_gone' : code === 'no_worktree' ? 'ses.review.no_worktree' : 'ses.review.gone';
    return (
      <Panel label={t('ses.finish.title')} onClose={close} testId="finish-sheet">
        <div className="fs-alert">
          <span className={`fs-alert-ic ${gone ? '' : 'attn'}`}>
            <Icon name={gone ? 'folder' : 'warning'} size={22} />
          </span>
          <div>
            <b role="heading" aria-level={2}>{gone ? t(key + '.title') : t(`ses.review.failed.${lastAction ?? 'diff'}`)}</b>
            <p className="selectable">{gone ? t(key + '.body') : phase.why}</p>
          </div>
        </div>
        <div className="hk-foot">
          <span className="grow" />
          {gone ? (
            <button className="hk-default" onClick={close}>{t('ses.common.close')}</button>
          ) : (
            <>
              <button onClick={close}>{t('ses.common.close')}</button>
              {code === 'running' ? (
                <button className="hk-default" onClick={endAndReview}>{t('ses.finish.end_review')}</button>
              ) : code === 'changed' ? (
                <button className="hk-default" onClick={load}>{t('ses.finish.review_again')}</button>
              ) : (
                <button className="hk-default" onClick={load}>{t('ses.overlay.retry')}</button>
              )}
            </>
          )}
        </div>
      </Panel>
    );
  }

  // ---- done
  if (phase.k === 'done') {
    const a = phase.action;
    const verify = ['merge', 'pr', 'pushed', 'compare'].includes(a);
    const text = a === 'discard' && takenBack > 0 ? plural('ses.finish.done.discard_taken_back', takenBack) : t(`ses.finish.done.${a}`);
    const uid = row.job.items[0];
    return (
      <Panel label={t('ses.finish.title')} onClose={onClose} testId="finish-sheet">
        {header}
        <div className="fs-done">
          <span className="fs-done-ic"><Icon name="check" size={13} /></span>
          <div>
            <b>{text}</b>
            {prURL && (
              <a href={prURL} title={prURL} onClick={(e) => (e.preventDefault(), void api.openUrl(prURL))}>{prURL}</a>
            )}
            {verify && <p>{t('ses.finish.done.verify')}</p>}
          </div>
        </div>
        <div className="hk-foot">
          <span className="grow" />
          {verify && first && uid ? (
            <>
              <button onClick={onClose}>{t('ses.common.close')}</button>
              <button className="hk-default" onClick={() => (onClose(), onShowItem?.(uid))}>
                {row.job.labels.length === 1 ? t('ses.finish.show_item', { a: first.id }) : t('ses.finish.show_items')}
              </button>
            </>
          ) : (
            <button className="hk-default" onClick={onClose}>{t('ses.common.close')}</button>
          )}
        </div>
      </Panel>
    );
  }

  // ---- the review
  const aliveNote = d.alive ? t(d.agentStatus === 'running' ? 'ses.finish.alive.working' : 'ses.finish.alive', { a: row.agentName }) : null;
  const rows = d.files.map((f) => {
    const cut = f.path.lastIndexOf('/');
    return (
      <div key={f.path} className="hk-row fs-file" title={f.path}>
        <span className="fs-path">
          {cut >= 0 && <span className="fs-dir"><bdi>{f.path.slice(0, cut + 1)}</bdi></span>}
          <span className="fs-file-name">{f.path.slice(cut + 1)}</span>
        </span>
        {counts(f.added, f.deleted)}
      </div>
    );
  });
  return (
    <Panel label={t('ses.finish.title')} onClose={onClose} busy={!!busy} testId="finish-sheet" enter={false}
      onKey={(e) => {
        if (e.key === 'Enter' && (e.ctrlKey || e.metaKey) && !primaryOff && phase.k === 'ready') {
          e.preventDefault();
          void (d.alive ? endAndReview() : run('merge'));
          return true;
        }
      }}>
      {header}
      {phase.k === 'loading' ? (
        <>
          <PanelBox className="hk-gap">
            <div className="hk-row hk-quiet"><Spinner /> {t('ses.finish.loading')}</div>
          </PanelBox>
          <div className="hk-foot">
            <span className="grow" />
            <button onClick={onClose}>{t('ses.common.cancel')}</button>
          </div>
        </>
      ) : (
        <>
          {empty ? (
            <PanelBox className="hk-gap">
              <div className="hk-row hk-quiet">{t('ses.finish.no_changes')}</div>
            </PanelBox>
          ) : (
            <div className="hk-gap">
              <PanelBox
                heading={<>{plural('ses.finish.files', d.files.length)} {counts(added, deleted)}</>}
                accessory={d.patch && <button className="hk-small" onClick={() => void api.openPath(d.patch!).catch(() => {})}>{t('ses.finish.open_patch')}</button>}
              >
                <div className="fs-files" style={d.files.length > FILE_ROWS ? { maxHeight: FILE_ROWS * 25, overflowY: 'auto' } : undefined}>{rows}</div>
              </PanelBox>
              {d.uncommitted > 0 && <p className="hk-under">{plural('ses.finish.uncommitted', d.uncommitted)}</p>}
            </div>
          )}
          <div className="hk-foot">
            <button ref={more} className="hk-more" disabled={!!busy} aria-label={t('ses.review.more')} title={t('ses.review.more')} aria-haspopup="menu"
              onClick={(e) => setMenu({ x: 0, y: 0, anchor: e.currentTarget })}>
              <Icon name="more" size={15} />
            </button>
            <PanelFootnote text={aliveNote} busy={busy ? t(`ses.finish.working.${busy}`) : null} />
            <button onClick={onClose} disabled={!!busy}>{t('ses.common.cancel')}</button>
            {d.alive ? (
              <button className="hk-default" disabled={primaryOff} onClick={endAndReview} title={`${t('ses.finish.end_review.help', { a: row.agentName })}  ${t('ses.finish.shortcut')}`}>
                {mergeTitle}
              </button>
            ) : (
              <span className="hk-split">
                <button className="hk-default" disabled={primaryOff} onClick={() => run('merge')} title={`${t('ses.finish.help', { a: d.base })}  ${t('ses.finish.shortcut')}`}>
                  {mergeTitle}
                </button>
                <button className="hk-default hk-split-arrow" disabled={primaryOff} aria-label={t('ses.finish.pr')} title={t('ses.finish.pr.help')} aria-haspopup="menu"
                  onClick={(e) => setMenu({ x: 0, y: 0, anchor: e.currentTarget })} data-pr="1">
                  <Icon name="chevron-down" size={11} />
                </button>
              </span>
            )}
          </div>
        </>
      )}
      {menu && (
        <Menu
          at={menu}
          onClose={() => setMenu(null)}
          entries={
            menu.anchor?.dataset.pr
              ? [{ label: t('ses.finish.pr'), hint: t('ses.finish.pr.help'), run: () => void run('pr') }]
              : [
                  { label: t('ses.finish.keep'), tip: t('ses.finish.keep.help'), run: () => void run('keep') },
                  { kind: 'separator' },
                  { label: t('ses.review.discard'), danger: true, run: () => setConfirmDiscard(true) },
                ]
          }
        />
      )}
      {confirmDiscard && (
        <Panel label={t('ses.finish.discard.confirm.title')} onClose={() => setConfirmDiscard(false)} width={340}>
          <b className="hk-alert-title">{t('ses.finish.discard.confirm.title')}</b>
          <p className="hk-alert-body">{t('ses.finish.discard.confirm.body', { a: d.branch })}</p>
          <div className="hk-foot">
            <span className="grow" />
            {/* Enter keeps the work: Cancel is the default, Discard has to be clicked */}
            <button className="danger" onClick={() => (setConfirmDiscard(false), void run('discard'))}>{t('ses.finish.discard')}</button>
            <button className="hk-default" data-autofocus onClick={() => setConfirmDiscard(false)}>{t('ses.common.cancel')}</button>
          </div>
        </Panel>
      )}
    </Panel>
  );
}
