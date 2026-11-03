// Send Feedback (the Mac's MainWindow/DictationFeedback.swift; docs/design/feedback.md): the Dictation page's Send
// Feedback… opens this sheet. The user checks the dictations to send (the rows selected in the list come checked;
// Select All), says whether the text around the cursor goes with them, and sends: feedback.py bundles each one's
// history line, its recording, the device and the models into one zip (≤ 100 MB) and uploads it. No rating, no form.
// Nothing leaves the PC before Send; the sheet says what goes, where, who can read it and when it is deleted.
import { useEffect, useMemo, useState } from 'react';
import { api, type DictationEntry } from '../api';
import { i18n } from '../i18n';
import { S } from '../settings/kit';
import '../settings/settings.css';

const LIMIT = 100_000_000;
const TEXT = 4_000;
/** "4 KB", "488 KB", "1.2 MB" (the Mac's ByteCountFormatter): a few KB of text never reads "0 MB". */
const mbStr = (n: number) =>
  n < 1e6
    ? i18n().formatNumber(Math.max(1, Math.round(n / 1e3)), { style: 'unit', unit: 'kilobyte' })
    : i18n().formatNumber(n / 1e6, { style: 'unit', unit: 'megabyte', maximumFractionDigits: n >= 1e7 ? 0 : 1 });
/** A row's time: "18:07" today, "Oct 29 19:40" before (the Mac sheet's left column). */
function rowTime(iso: string): string {
  const d = new Date(iso);
  const now = new Date();
  const same = d.toDateString() === now.toDateString();
  return same ? i18n().formatDate(d, 'time') : `${i18n().formatDate(d, { month: 'short', day: 'numeric' })} ${i18n().formatDate(d, 'time')}`;
}
const dur = (s: number) => i18n().formatDuration(Math.round(s || 0), 'clock');
const errText = (code: string) =>
  S(code === 'network' ? 'dictation.feedback.error.network' : code === 'rate_limited' ? 'dictation.feedback.error.rate' : code === 'full' ? 'dictation.feedback.error.full' : code === 'too_large' ? 'dictation.feedback.too_large' : 'dictation.feedback.error.other');

export function FeedbackSheet({ entries, selected, close }: { entries: (DictationEntry & { audio_bytes?: number })[]; selected: Set<string>; close: () => void }) {
  const [checked, setChecked] = useState<Set<string>>(() => {
    const pre = new Set(entries.filter((e) => selected.has(e.id)).map((e) => e.id));
    return pre.size ? pre : new Set(entries.slice(0, 1).map((e) => e.id));
  });
  const [context, setContext] = useState(true);
  // the checked ones first (the selected take opens in view, never below the fold), the rest newest first
  const [order] = useState(() => [...entries.filter((e) => selected.has(e.id)), ...entries.filter((e) => !selected.has(e.id))]);
  const [phase, setPhase] = useState<{ k: 'picking' | 'sending' | 'sent' | 'failed'; text?: string }>({ k: 'picking' });
  useEffect(() => {
    const k = (e: KeyboardEvent) => e.key === 'Escape' && phase.k !== 'sending' && close();
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [close, phase.k]);
  // a recording's size when the history says it, else a few KB of text
  const sizeOf = (e: DictationEntry & { audio_bytes?: number }) => TEXT + (e.audio_bytes ?? ((e as any).audio_path ? 300_000 : 0));
  const total = useMemo(() => entries.filter((e) => checked.has(e.id)).reduce((a, e) => a + sizeOf(e), 0), [entries, checked]);
  const tooLarge = total > LIMIT;
  const all = entries.length > 0 && checked.size === entries.length;
  const toggle = (id: string) => setChecked((c) => {
    const n = new Set(c);
    if (n.has(id)) n.delete(id);
    else n.add(id);
    return n;
  });
  const send = async () => {
    if (!checked.size || tooLarge) return;
    setPhase({ k: 'sending' });
    // oldest first, as they were said
    const ids = entries.filter((e) => checked.has(e.id)).reverse().map((e) => e.id);
    try {
      const r = await api.feedbackSend(ids, context);
      setPhase({ k: 'sent', text: String(r.id ?? '') });
    } catch (e) {
      setPhase({ k: 'failed', text: errText(String(e).match(/\[([a-z_]+)\]\s*$/)?.[1] ?? 'other') });
    }
  };
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && phase.k !== 'sending' && close()}>
      <div className="sheet st-sheet fb-sheet" role="dialog" aria-label={S('dictation.feedback.title')} style={{ width: 580 }} data-testid="feedback-sheet">
        <div className="st-sheet-body fb-body">
          <div className="st-sheet-title">{S('dictation.feedback.title')}</div>
          {phase.k === 'sent' ? (
            <>
              <p className="st-detail">{S('dictation.feedback.sent')}</p>
              <div className="st-row">
                <div className="st-text"><div>{S('dictation.feedback.id')}</div><div className="st-detail">{S('dictation.feedback.id.detail')}</div></div>
                <div className="st-ctl"><code className="st-cmd">{phase.text}</code><button onClick={() => api.copyText(phase.text ?? '')}>{S('dictation.feedback.copy_id')}</button></div>
              </div>
              <div className="st-ctl st-sheet-foot"><button className="primary" onClick={close}>{S('dictation.feedback.done')}</button></div>
            </>
          ) : (
            <fieldset disabled={phase.k === 'sending'} className="st-plain fb-pick">
              <p className="st-detail">{S('dictation.feedback.note')}</p>
              <label className="st-check fb-all">
                <input type="checkbox" checked={all} ref={(el) => {
                  if (el) el.indeterminate = !all && checked.size > 0;
                }} onChange={() => setChecked(all ? new Set() : new Set(entries.map((e) => e.id)))} />
                <span>{S('dictation.feedback.all')}</span>
                <span className="st-detail fb-count">{S('dictation.feedback.count', checked.size, mbStr(total))}</span>
              </label>
              {/* only the takes scroll: the header and the buttons stay (a long list never pushes Send out of the window) */}
              <div className="st-fb-list" role="group" aria-label={S('dictation.feedback.title')}>
                {order.map((e) => (
                  <label key={e.id} className="fb-row">
                    <input type="checkbox" checked={checked.has(e.id)} onChange={() => toggle(e.id)} />
                    <span className="fb-time">{rowTime(e.t)}</span>
                    <span className="st-fb-text">{e.text || e.raw}</span>
                    <span className="fb-tail">{(e as any).audio_path ? dur(e.duration) : S('dictation.feedback.text_only')}</span>
                  </label>
                ))}
              </div>
              <label className="st-check fb-ctx">
                <input type="checkbox" checked={context} onChange={(e) => setContext(e.target.checked)} />
                <span><span>{S('dictation.feedback.context')}</span><span className="st-detail" style={{ display: 'block' }}>{S('dictation.feedback.context.detail')}</span></span>
              </label>
              <p className="st-detail fb-note">{S('dictation.feedback.what')}</p>
              <p className="st-detail fb-note">{S('dictation.feedback.where')}</p>
              <div className="st-ctl st-sheet-foot">
                <span className={`st-detail ${tooLarge || phase.k === 'failed' ? 'st-warn' : ''}`} style={{ marginInlineEnd: 'auto' }}>
                  {phase.k === 'sending' ? S('dictation.feedback.sending') : tooLarge ? S('dictation.feedback.too_large') : phase.k === 'failed' ? phase.text : ''}
                </span>
                <button onClick={close}>{S('dictation.feedback.cancel')}</button>
                <button className="primary" disabled={!checked.size || tooLarge} onClick={send}>{checked.size ? S('dictation.feedback.send.n', checked.size) : S('dictation.feedback.send')}</button>
              </div>
            </fieldset>
          )}
        </div>
      </div>
    </div>
  );
}
