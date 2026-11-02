// M (or Move to Project… in the palette and the selection's button): a small popover at the selection (the Mac's
// ProjectPopover) — "Move SF-12 to…" / "Move 3 items to…"; type to filter (key, name, a word of it), ↑↓ or the
// pointer, ↩ moves, Esc closes. Projects in the one order, then a line and Unassigned last. Where the items are now
// says "Current" and is never the default. No match: one line saying so, then Open Folder….
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Icon } from '@blurt/icons';
import type { ProjectRow } from '../api';
import { t } from '../i18n';
import { isImeKey } from '../ime';
import { MissingFolderGlyph, ProjectGlyph, UnassignedGlyph } from './glyphs';

/** A long name loses its middle, at a word or script boundary (the Mac's truncation), the whole name in its tip. */
function MiddleName({ name }: { name: string }) {
  const [head, tail] = splitMiddle(name, 34);
  return (
    <span className="mw-move-name" data-tip={tail ? name : undefined}>
      {tail ? `${head}…${tail}` : name}
    </span>
  );
}
export function splitMiddle(name: string, max: number): [string, string] {
  const cs = [...name];
  if (cs.length <= max) return [name, ''];
  const hn = Math.ceil(max * 0.55);
  const tn = max - hn - 1;
  // the head ends on a word break when one is near
  const head = cs.slice(0, hn).join('');
  const sp = head.search(/\s\S*$/);
  const h = sp > max * 0.35 ? head.slice(0, sp) : head;
  // the tail starts at a word or a change of script: never a stray Latin fragment ("e 客户端)")
  let tail = cs.slice(cs.length - tn).join('');
  if (/^[A-Za-z0-9]/.test(tail) && /[A-Za-z0-9]/.test(cs[cs.length - tn - 1] ?? '')) tail = tail.replace(/^[A-Za-z0-9]+/, '').trimStart();
  return [h.trimEnd(), tail];
}

type Entry = { id: string; name: string; key: string; kind: 'project' | 'inbox' | 'none' | 'open' };

export function pickChoices(projects: ProjectRow[], q: string, unassigned: string): Entry[] {
  const s = q.trim().toLowerCase();
  const match = (p: { name: string; key: string }) =>
    !s || p.key.toLowerCase().startsWith(s) || p.name.toLowerCase().includes(s) || p.name.toLowerCase().split(/[\s\-_/]+/).some((w) => w.startsWith(s));
  const out: Entry[] = projects.filter(match).map((p) => ({ id: p.id, name: p.name, key: p.key, kind: 'project' }));
  if (match({ name: unassigned, key: '' }) || match({ name: 'unassigned', key: 'IN' })) out.push({ id: 'inbox', name: unassigned, key: '', kind: 'inbox' });
  return out;
}

export function MovePopover({ projects, here, subject, anchor, onPick, onOpenFolder, onClose }: {
  projects: ProjectRow[];
  /** where every item is now, when they share one */
  here: string | null;
  subject: string;
  anchor: DOMRect;
  onPick: (project: string) => void;
  onOpenFolder: () => void;
  onClose: () => void;
}) {
  const [q, setQ] = useState('');
  const shown = useMemo(() => {
    const c = pickChoices(projects, q, t('project.inbox'));
    // Open Folder… ends the list as in the context menu's Move to Project ▸ (main-window.md §6.4)
    return c.length ? [...c, { id: 'open', name: t('project.open_folder'), key: '', kind: 'open' as const }] : [{ id: 'none', name: t('project.no_match'), key: '', kind: 'none' as const }, { id: 'open', name: t('project.open_folder'), key: '', kind: 'open' as const }];
  }, [projects, q]);
  const first = shown.findIndex((e) => (e.kind === 'project' || e.kind === 'inbox') && e.id !== here);
  const [ix, setIx] = useState(first);
  useEffect(() => setIx(shown.findIndex((e) => (e.kind === 'project' || e.kind === 'inbox') && e.id !== here)), [shown, here]);
  const el = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState({ left: anchor.left, top: anchor.bottom + 6 });
  useLayoutEffect(() => {
    const r = el.current?.getBoundingClientRect();
    if (!r) return;
    setPos({
      left: Math.max(8, Math.min(anchor.left, innerWidth - r.width - 8)),
      top: anchor.bottom + 6 + r.height > innerHeight - 8 ? Math.max(8, anchor.top - r.height - 6) : anchor.bottom + 6,
    });
  }, [anchor, shown.length]);
  useEffect(() => {
    const down = (e: MouseEvent) => !(e.target as HTMLElement).closest?.('.mw-move') && onClose();
    window.addEventListener('mousedown', down, true);
    return () => window.removeEventListener('mousedown', down, true);
  }, []);
  const pick = (e: Entry | undefined) => {
    if (!e || e.kind === 'none') return;
    onClose();
    if (e.kind === 'open') return onOpenFolder();
    if (e.id !== here) onPick(e.id);
  };
  const sepAt = shown.findIndex((e) => e.kind === 'inbox');
  const openAt = shown.findIndex((e) => e.kind === 'open');
  const gone = (id: string) => projects.find((p) => p.id === id)?.exists === false;
  return createPortal(
    <div ref={el} className="mw-move" role="dialog" aria-label={subject} style={{ left: pos.left, top: pos.top }} data-testid="move-popover">
      <div className="mw-move-field">
      <Icon name="search" size={15} />
      <input
        autoFocus
        value={q}
        placeholder={subject}
        aria-label={subject}
        onChange={(e) => setQ(e.target.value)}
        onKeyDown={(e) => {
          if (isImeKey(e)) return;
          e.stopPropagation();
          const step = (d: number) => {
            for (let k = 1; k <= shown.length; k++) {
              const j = (((ix < 0 ? (d > 0 ? -1 : 0) : ix) + d * k) % shown.length + shown.length) % shown.length;
              if (shown[j].kind !== 'none') return setIx(j);
            }
          };
          if (e.key === 'ArrowDown') step(1);
          else if (e.key === 'ArrowUp') step(-1);
          else if (e.key === 'Enter') pick(shown[ix]);
          else if (e.key === 'Escape') onClose();
          else return;
          e.preventDefault();
        }}
      />
      </div>
      <div className="mw-move-list" role="listbox" aria-label={t('main.move.list')}>
        {shown.map((e, i) => (
          <div key={e.id} className="mw-move-wrap">
            {((i === sepAt && i > 0) || (i === openAt && i > 0 && shown[i - 1].kind !== 'none')) && <div className="mw-menu-sep" />}
            <div
              role="option"
              aria-selected={i === ix}
              aria-label={e.id === here ? `${e.name}, ${t('main.move.here')}` : e.name}
              className={`mw-move-row ${i === ix ? 'on' : ''} ${e.kind === 'none' ? 'off' : ''} ${e.id === here ? 'here' : ''}`}
              onMouseEnter={() => e.kind !== 'none' && setIx(i)}
              onMouseDown={(ev) => ev.preventDefault()}
              onClick={() => pick(e)}
            >
              <span className="mw-move-ic">
                {e.kind === 'project' ? (gone(e.id) ? <MissingFolderGlyph size={15} /> : <ProjectGlyph id={e.id} size={15} />) : e.kind === 'inbox' ? <UnassignedGlyph size={15} /> : e.kind === 'open' ? <Icon name="folder-plus" size={15} /> : null}
              </span>
              <MiddleName name={e.name} />
              {e.id === here ? (
                <span className="mw-move-here"><Icon name="check" size={11} /> {t('main.move.current')}</span>
              ) : (
                e.key && <span className="mw-move-key">{e.key}</span>
              )}
            </div>
          </div>
        ))}
      </div>
    </div>,
    document.body,
  );
}
