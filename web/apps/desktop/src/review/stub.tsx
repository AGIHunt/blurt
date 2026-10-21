// Stand-in for WP3's shared review component (web/packages/review) until it merges. Same entry point and host
// protocol (C6): mountReview(el, host, opts) with mode 'item' (one item: frames, clip, quote, lens fields, code refs,
// fix history) or 'review' (triage the whole session: J/K move, A keep, X delete, Z undo, G next frame, V clip).
// Every edit is a `set` user-op sent through host.sendOps (→ items.py user-ops); host.poll picks up agent writes.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import type { BlurtHost, Item, MountOptions, ReviewHandle, SessionDoc, UserOp } from './types';
import { isImeKey } from './ime';

const NOT_FIELDS = new Set([
  'id', 'uid', 'kind', 'title', 'quote', 'tags', 'status', 'severity', 'owner', 'module', 'confidence', 'time',
  'frames', 'clip', 'exported', 'fix', 'fix_history', 'merged_from', 't', 'code_refs', 'questions', 'answer', 'type',
]);
const KINDS = ['issue', 'idea', 'note', 'task'];
const POLL_MS = 2000;

type SaveState = 'idle' | 'saving' | 'saved' | 'error';

function lensFields(it: Item): string[] {
  return Object.keys(it).filter((k) => !NOT_FIELDS.has(k) && !k.startsWith('_') && (typeof it[k] === 'string' || isStrList(it[k])));
}
function isStrList(v: unknown): v is string[] {
  return Array.isArray(v) && v.every((x) => typeof x === 'string');
}
function fmtTime(t?: number) {
  if (t == null) return '';
  const m = Math.floor(t / 60);
  const s = Math.floor(t % 60);
  return `${m}:${String(s).padStart(2, '0')}`;
}
function ago(at?: number) {
  if (!at) return '';
  return new Date(at * 1000).toLocaleString();
}

function useSession(host: BlurtHost) {
  const [doc, setDoc] = useState<SessionDoc | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [save, setSave] = useState<SaveState>('idle');
  const etag = useRef('');
  const inflight = useRef(0);

  useEffect(() => {
    let alive = true;
    host.load().then(
      (r) => {
        if (!alive) return;
        etag.current = r.etag;
        setDoc(r.doc);
      },
      (e) => alive && setError(String(e)),
    );
    const timer = setInterval(async () => {
      if (inflight.current) return;
      try {
        const r = await host.poll(etag.current);
        if (r.doc && !inflight.current) {
          etag.current = r.etag;
          setDoc(r.doc);
        }
      } catch {
        /* the file can vanish while an agent rewrites it; next poll */
      }
    }, POLL_MS);
    return () => {
      alive = false;
      clearInterval(timer);
    };
  }, [host]);

  const send = useCallback(
    async (ops: UserOp[], confirm = false) => {
      // optimistic: apply `set` ops locally right away
      setDoc((d) => {
        if (!d) return d;
        const items = d.items.map((it) => {
          const op = ops.find((o) => o.op === 'set' && o.id === it.id) as Extract<UserOp, { op: 'set' }> | undefined;
          if (!op) return it;
          const n: Item = { ...it, ...(op.set ?? {}) };
          for (const k of op.unset ?? []) delete n[k];
          return n;
        });
        return { ...d, items, ...(confirm ? { reviewed: true } : {}) };
      });
      inflight.current++;
      setSave('saving');
      try {
        const r = await host.sendOps(ops, confirm);
        etag.current = r.etag;
        setSave(r.ok ? 'saved' : 'error');
      } catch (e) {
        setSave('error');
        setError(String(e));
      } finally {
        inflight.current--;
      }
    },
    [host],
  );
  return { doc, error, save, send };
}

function Field({ label, value, multiline, onCommit, testid }: {
  label: string; value: string; multiline?: boolean; onCommit: (v: string) => void; testid?: string;
}) {
  const [v, setV] = useState(value);
  const focused = useRef(false);
  useEffect(() => {
    if (!focused.current) setV(value);
  }, [value]);
  const commit = () => {
    if (v !== value) onCommit(v);
  };
  const common = {
    value: v,
    'data-testid': testid,
    onFocus: () => (focused.current = true),
    onBlur: () => {
      focused.current = false;
      commit();
    },
  };
  return (
    <label className="rv-field">
      <span className="rv-label">{label}</span>
      {multiline ? (
        <textarea {...common} rows={Math.min(8, Math.max(2, v.split('\n').length))} onChange={(e) => setV(e.target.value)} />
      ) : (
        <input
          {...common}
          onChange={(e) => setV(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !isImeKey(e)) {
              e.preventDefault();
              commit();
              (e.target as HTMLInputElement).blur();
            }
          }}
        />
      )}
    </label>
  );
}

function Frames({ host, item, frameIx, setFrameIx }: { host: BlurtHost; item: Item; frameIx: number; setFrameIx: (n: number) => void }) {
  const frames = item.frames ?? [];
  if (!frames.length) return null;
  const f = frames[Math.min(frameIx, frames.length - 1)];
  return (
    <div className="rv-frames">
      <img src={host.fileUrl(f.path)} alt={f.caption ?? ''} onDoubleClick={() => host.quickLook?.(f.path)} />
      <div className="rv-frame-bar">
        <button disabled={frames.length < 2} onClick={() => setFrameIx((frameIx - 1 + frames.length) % frames.length)}>◀</button>
        <span>{Math.min(frameIx, frames.length - 1) + 1}/{frames.length}</span>
        <button disabled={frames.length < 2} onClick={() => setFrameIx((frameIx + 1) % frames.length)}>▶</button>
        <span className="rv-caption">{f.caption}{f.t != null ? ` · ${fmtTime(f.t)}` : ''}</span>
        {host.reveal && <button className="rv-link" onClick={() => host.reveal!(f.path)}>Show file</button>}
      </div>
    </div>
  );
}

function ItemView({ host, item, send, frameIx, setFrameIx, showClip }: {
  host: BlurtHost; item: Item; send: (ops: UserOp[]) => void; frameIx: number; setFrameIx: (n: number) => void; showClip: boolean;
}) {
  const set = (k: string, v: unknown) => send([{ op: 'set', id: item.id, set: { [k]: v } }]);
  const fields = lensFields(item);
  const time = item.time as { start?: number; end?: number } | undefined;
  return (
    <div className="rv-item" data-testid="item-detail" data-item-id={item.id}>
      <div className="rv-head">
        <span className="rv-id">{item.id}</span>
        <select value={item.kind} onChange={(e) => set('kind', e.target.value)} aria-label="kind">
          {[...new Set([...KINDS, item.kind])].map((k) => <option key={k}>{k}</option>)}
        </select>
        <select value={item.status ?? 'draft'} onChange={(e) => set('status', e.target.value)} aria-label="status" data-testid="item-status">
          <option value="draft">draft</option>
          <option value="confirmed">confirmed</option>
          <option value="deleted">deleted</option>
        </select>
        {item.severity !== undefined && (
          <select value={String(item.severity)} onChange={(e) => set('severity', e.target.value)} aria-label="severity">
            {[...new Set(['low', 'medium', 'high', 'critical', String(item.severity)])].map((s) => <option key={s}>{s}</option>)}
          </select>
        )}
        {item.fix && <span className={`rv-fix rv-fix-${item.fix.state}`}>{item.fix.state}{item.fix.commit ? ` #${item.fix.commit.slice(0, 7)}` : ''}</span>}
        {host.fixWithAgent && <button className="rv-primary" onClick={() => host.fixWithAgent!([item.id])} data-testid="fix-with-agent">Let agent fix ⌃↩</button>}
      </div>
      <Field label="Title" value={item.title ?? ''} onCommit={(v) => set('title', v)} testid="item-title" />
      <Frames host={host} item={item} frameIx={frameIx} setFrameIx={setFrameIx} />
      {item.clip && (showClip || !(item.frames ?? []).length) && (
        <video className="rv-clip" src={host.fileUrl(item.clip)} controls preload="metadata" />
      )}
      {item.quote && (
        <blockquote className="rv-quote">“{item.quote}”{time?.start != null && <span className="rv-t"> {fmtTime(time.start)}</span>}</blockquote>
      )}
      {fields.map((k) => {
        const v = item[k];
        const list = isStrList(v);
        return (
          <Field key={k} label={k} multiline value={list ? (v as string[]).join('\n') : String(v ?? '')}
            onCommit={(nv) => set(k, list ? nv.split('\n').map((s) => s.trim()).filter(Boolean) : nv)} testid={`field-${k}`} />
        );
      })}
      <Field label="Tags" value={(item.tags ?? []).join(', ')} onCommit={(v) => set('tags', v.split(',').map((s) => s.trim()).filter(Boolean))} />
      {!!item.code_refs?.length && (
        <div className="rv-refs">
          <span className="rv-label">Code</span>
          {item.code_refs.map((r) => (
            <button key={r} className="rv-ref" disabled={!host.openCode} onClick={() => host.openCode?.(r)}>{r}</button>
          ))}
        </div>
      )}
      {(item.fix || item.fix_history?.length) && (
        <div className="rv-history">
          <span className="rv-label">History</span>
          <ol>
            {[...(item.fix_history ?? []), ...(item.fix ? [item.fix] : [])].map((f, i) => (
              <li key={i}><b>{f.state}</b> · {f.agent}{f.commit ? ` · ${f.commit}` : ''}{f.note ? ` — ${f.note}` : ''} <span className="rv-dim">{ago(f.at)}</span></li>
            ))}
          </ol>
        </div>
      )}
    </div>
  );
}

function Review({ host, opts }: { host: BlurtHost; opts: MountOptions }) {
  const { doc, error, save, send } = useSession(host);
  const [cur, setCur] = useState<string | undefined>(opts.itemId);
  const [frameIx, setFrameIx] = useState(0);
  const [showClip, setShowClip] = useState(false);
  const undo = useRef<UserOp[][]>([]);
  const items = useMemo(() => (doc?.items ?? []).filter((i) => opts.mode === 'review' || i.id === opts.itemId), [doc, opts]);
  const ix = Math.max(0, items.findIndex((i) => i.id === cur));
  const item = items[ix];

  useEffect(() => setFrameIx(0), [cur]);

  const sendWithUndo = useCallback(
    (ops: UserOp[], confirm = false) => {
      const back: UserOp[] = [];
      for (const op of ops) {
        if (op.op !== 'set') continue;
        const it = doc?.items.find((i) => i.id === op.id);
        if (!it) continue;
        const prev: Record<string, unknown> = {};
        const unset: string[] = [];
        for (const k of Object.keys(op.set ?? {})) (k in it ? (prev[k] = it[k]) : unset.push(k));
        back.push({ op: 'set', id: op.id, set: prev, unset });
      }
      if (back.length) undo.current.push(back);
      return send(ops, confirm);
    },
    [doc, send],
  );

  useEffect(() => {
    if (opts.mode !== 'review') return;
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement;
      if (t.closest('input, textarea, select') || e.metaKey || e.ctrlKey || e.altKey || isImeKey(e)) return;
      const k = e.key.toLowerCase();
      const go = (d: number) => {
        const n = items[Math.min(items.length - 1, Math.max(0, ix + d))];
        if (n) setCur(n.id);
      };
      if (k === 'j') go(1);
      else if (k === 'k') go(-1);
      else if (k === 'a' && item) { sendWithUndo([{ op: 'set', id: item.id, set: { status: 'confirmed' } }]); go(1); }
      else if (k === 'x' && item) { sendWithUndo([{ op: 'set', id: item.id, set: { status: 'deleted' } }]); go(1); }
      else if (k === 'z') { const b = undo.current.pop(); if (b) send(b); }
      else if (k === 'g' && item?.frames?.length) setFrameIx((frameIx + 1) % item.frames.length);
      else if (k === 'v') setShowClip((s) => !s);
      else return;
      e.preventDefault();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [opts.mode, items, ix, item, frameIx, send, sendWithUndo]);

  useEffect(() => {
    if (!cur && items[0]) setCur(items[0].id);
  }, [cur, items]);

  if (error && !doc) return <div className="rv-empty">{error}</div>;
  if (!doc) return <div className="rv-empty">Loading…</div>;
  if (!item) return <div className="rv-empty">{opts.mode === 'item' ? `Item ${opts.itemId} isn't in this session any more.` : 'No items yet.'}</div>;

  const saveLabel = { idle: '', saving: 'Saving…', saved: 'Saved', error: 'Not saved' }[save];
  const view = <ItemView host={host} item={item} send={(o) => sendWithUndo(o)} frameIx={frameIx} setFrameIx={setFrameIx} showClip={showClip} />;
  return (
    <div className={`rv rv-${opts.mode}`} data-platform={opts.platform}>
      {opts.mode === 'review' ? (
        <div className="rv-split">
          <ul className="rv-list" role="listbox">
            {items.map((i) => (
              <li key={i.id} role="option" aria-selected={i.id === item.id} className={`${i.id === item.id ? 'sel' : ''} st-${i.status ?? 'draft'}`} onClick={() => setCur(i.id)}>
                <span className="rv-id">{i.id}</span> {i.title}
              </li>
            ))}
          </ul>
          <div className="rv-main">
            {view}
            <div className="rv-footer">
              <span className="rv-keys">J/K move · A keep · X delete · Z undo · G frame · V clip</span>
              <button className="rv-primary" disabled={!!doc.reviewed} onClick={() => send([], true)}>{doc.reviewed ? 'Reviewed ✓' : 'Done reviewing'}</button>
            </div>
          </div>
        </div>
      ) : (
        view
      )}
      <div className={`rv-save rv-save-${save}`} data-testid="save-state">{saveLabel}</div>
    </div>
  );
}

export function mountReview(el: HTMLElement, host: BlurtHost, opts: MountOptions): ReviewHandle {
  const root = createRoot(el);
  root.render(<Review host={host} opts={opts} />);
  return { unmount: () => root.unmount() };
}
