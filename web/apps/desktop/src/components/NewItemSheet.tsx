// New Item (the Mac's NewItemSheet): the list heading's "+ New" and Ctrl+N open this sheet over the window. A kind
// (Issue / Idea / Task / Note), a title, optional details, pictures; Create writes it with `items.py add` into the place
// on show — the project in view, else the current project, else Unassigned — and the list selects it. Pictures come
// from Add Image… (they go in as the item's frames; items.py copies them into the store).
import { useState } from 'react';
import { Icon } from '@blurt/icons';
import { api, fileSrc } from '../api';
import { errText, i18n, t } from '../i18n';
import { isImeKey } from '../ime';

const KINDS = ['issue', 'idea', 'task', 'note'] as const;

/** What a paste or a drop brought (the Mac's NewItemSheet.Prefill). */
export interface Prefill {
  title: string;
  details: string;
  images: string[];
}

/** Text: its first line the title (cut at 60), the rest the details. */
export function prefillFromText(text: string): Prefill {
  const [first0, ...rest] = text.split('\n');
  const first = first0.trim();
  const long = first.length > 60;
  return { title: long ? `${first.slice(0, 59)}…` : first, details: (long ? text : rest.join('\n')).trim(), images: [] };
}

export function NewItemSheet({ target, targetName, prefill, onClose, onCreated }: {
  target: string;
  prefill?: Prefill;
  targetName: string;
  onClose: () => void;
  onCreated: (uid: string | null) => void;
}) {
  const [kind, setKind] = useState<(typeof KINDS)[number]>('issue');
  const [title, setTitle] = useState(prefill?.title ?? '');
  const [details, setDetails] = useState(prefill?.details ?? '');
  const [images, setImages] = useState<string[]>(prefill?.images ?? []);
  const [dropping, setDropping] = useState(false);
  /** pictures pasted or dropped on the sheet join the others (text pastes into the field as always) */
  const take = async (files: File[]) => {
    const got = (await Promise.all(files.filter((f) => f.type.startsWith('image/')).map((f) => api.saveTempImage(f).catch(() => null)))).filter((p): p is string => !!p);
    if (got.length) setImages((cur) => [...cur, ...got.filter((x) => !cur.includes(x))]);
    return got.length > 0;
  };
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const can = (title.trim() || images.length) && !saving;

  const create = async () => {
    if (!can) return;
    let tt = title.trim();
    // pictures alone: a title that says when (the user can rename it in the detail)
    if (!tt && images.length) tt = t('main.new_item.image_title', { a: i18n().formatDate(Date.now(), 'time') });
    setSaving(true);
    setError(null);
    const item: Record<string, unknown> = { kind, title: tt };
    if (details.trim()) item.details = details.trim();
    if (images.length) item.frames = images.map((path) => ({ path }));
    try {
      const r = await api.addItem(target, item);
      onCreated(r?.uid ?? r?.item?.uid ?? null);
    } catch (e) {
      setError(errText(e));
      setSaving(false);
    }
  };

  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={`sheet mw-sheet ${dropping ? 'dropping' : ''}`} role="dialog" aria-modal="true" aria-label={t('main.new_item.title')} data-testid="new-item-sheet"
        onDragOver={(e) => {
          if (!e.dataTransfer.types.includes('Files')) return;
          e.preventDefault();
          setDropping(true);
        }}
        onDragLeave={() => setDropping(false)}
        onDrop={(e) => {
          setDropping(false);
          if (!e.dataTransfer.files.length) return;
          e.preventDefault();
          take([...e.dataTransfer.files]);
        }}
        onPaste={(e) => {
          const files = [...e.clipboardData.files];
          if (files.some((f) => f.type.startsWith('image/'))) {
            e.preventDefault();
            take(files);
          }
        }}
        onKeyDown={(e) => {
          if (e.key === 'Escape') {
            e.stopPropagation();
            onClose();
          } else if (e.key === 'Enter' && e.ctrlKey && !isImeKey(e)) {
            e.preventDefault();
            create();
          }
        }}>
        <h2>{t('main.new_item.title')}</h2>
        <p className="dim small">{t('main.new_item.into', { a: targetName })}</p>
        <div className="mw-seg" role="radiogroup">
          {KINDS.map((k) => (
            <button key={k} role="radio" aria-checked={kind === k} className={kind === k ? 'on' : ''} onClick={() => setKind(k)}>
              {t(`kind.${k}`)}
            </button>
          ))}
        </div>
        <input
          autoFocus
          className="mw-field"
          value={title}
          placeholder={t('main.new_item.title_placeholder')}
          onChange={(e) => setTitle(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && !isImeKey(e) && create()}
        />
        <textarea className="mw-field mw-details" value={details} placeholder={t('main.new_item.details_placeholder')} onChange={(e) => setDetails(e.target.value)} />
        <div className="mw-pics">
          {images.map((p) => (
            <span key={p} className="mw-pic">
              <img src={fileSrc(p)} alt="" onError={(e) => ((e.currentTarget.parentElement as HTMLElement).dataset.broken = '1')} />
              <Icon name="screenshot" size={18} className="mw-pic-fallback" />
              <button className="mw-pic-x" aria-label={t('main.new_item.remove_image')} onClick={() => setImages((l) => l.filter((x) => x !== p))}>
                <Icon name="x" size={9} />
              </button>
            </span>
          ))}
          <button className="small" onClick={() => api.pickImages().then((l) => setImages((cur) => [...cur, ...l.filter((x) => !cur.includes(x))]), () => {})}>
            {t('main.new_item.add_image')}
          </button>
          <span className="dim small mw-pics-hint">{t('main.new_item.image_hint')}</span>
        </div>
        <div className="mw-sheet-foot">
          {error && <span className="mw-err">{error}</span>}
          {saving && <span className="mw-spinner sm" />}
          <span className="grow" />
          <button onClick={onClose}>{t('action.cancel')}</button>
          <button className="primary" disabled={!can} onClick={create} data-testid="new-item-create">
            {t('main.new_item.create')}
          </button>
        </div>
      </div>
    </div>
  );
}
