// The Dictation page's Words tab (词库) — the Mac's MainWindow/DictationWords.swift: the one place the custom words are
// managed ($BLURT_HOME/dictation/vocabulary.json through dictation/words.rs). The list column: one field that finds as
// you type and adds on Enter (pasting "a, b, c" adds three; a word already there is said under it), what the words are
// for in one line under it, then the words learned once and waiting for the user (待确认) as plain rows whose Add and ×
// show on the chosen row and on hover, the user's own words as chips that wrap, their projects' words one chip per
// project (the name, then its key), and the built-in words folded under a heading with a chevron. The chips take the
// keyboard: Tab enters them, ← → move, Delete / Backspace removes, Enter or a double-click edits the spelling; the ×
// shows on the chosen chip and on hover, over its corner (nothing reflows). Remove, Add and Ignore say so with Undo
// (Ctrl+Z too). The detail column only tells: the chosen word, where it came from, how often dictation used it, what
// it was heard as (Edit Spelling and Remove in its ⋯).
// The words are hints to the models, never replacements.
import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Icon } from '@blurt/icons';
import { api, type ProjectRow, type VocabTerm } from '../api';
import { i18n, t } from '../i18n';
import { isImeKey } from '../ime';
import { inField } from '../util';
import { Menu, MenuItem } from './DictMenu';

type Undo = { msg: string; run: () => Promise<void> };
type Group = { id: string; name: string; key: string; terms: VocabTerm[] };

/** One order in every language: by spelling (not the reader's collation). */
const byName = (a: VocabTerm, b: VocabTerm) => a.term.localeCompare(b.term, 'en', { sensitivity: 'base', numeric: true });
const same = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase();
/** What the field would add: one word per comma (or 、 ; a line) — as words.rs `add` splits it. */
const entriesOf = (s: string) => s.split(/[,，、;；\n]/).map((x) => x.trim()).filter(Boolean);

export function DictationWords({ header, onToast, onCount }: { header: ReactNode; onToast: (msg: string) => void; onCount?: (n: number) => void }) {
  const [terms, setTerms] = useState<VocabTerm[] | null>(null);
  const [projects, setProjects] = useState<ProjectRow[]>([]);
  const [field, setField] = useState('');
  const [selected, setSelected] = useState<string | null>(null);
  const [showBuiltIn, setShowBuiltIn] = useState(false);
  const [renaming, setRenaming] = useState<{ term: string; text: string } | null>(null);
  const [menu, setMenu] = useState<{ x: number; y: number; right?: boolean } | null>(null);
  const [undo, setUndo] = useState<Undo | null>(null);
  const undoTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const fieldRef = useRef<HTMLInputElement>(null);

  const reload = useCallback(() => api.dictationWords().then((r) => setTerms(r.terms ?? []), (e) => onToast(String(e))), []);
  useEffect(() => {
    reload();
    api.projects().then((p) => setProjects(p.projects ?? []), () => {});
  }, []);

  const all = terms ?? [];
  const active = all.filter((x) => (x.state ?? 'active') === 'active');
  const mine = active.filter((x) => (x.source ?? 'manual') === 'manual' || x.source === 'learned').sort(byName);
  const projectWords = active.filter((x) => x.source === 'project').sort(byName);
  const builtIn = active.filter((x) => x.source === 'default').sort(byName);
  const suggestions = all.filter((x) => x.state === 'suggested');
  // the page header's "26 words" (the Mac's subtitle on this tab too)
  useEffect(() => {
    if (terms) onCount?.(active.length);
  }, [terms]);

  // the field: what it finds while it is one word (a list being pasted finds nothing), what Enter adds
  const entries = entriesOf(field);
  const query = entries.length > 1 ? '' : field.trim();
  const filtering = !!query;
  const matching = (ts: VocabTerm[]) => (filtering ? ts.filter((x) => x.term.toLowerCase().includes(query.toLowerCase())) : ts);
  const duplicates = entries.filter((e) => active.some((x) => same(x.term, e)));
  const addable = entries.filter((e) => !duplicates.includes(e));
  const sep = t('dictation_words.sep');

  /** The projects' words, one group per project (its name and its key), so "BA" reads as billing-api's. */
  const groups: Group[] = useMemo(() => {
    let left = [...projectWords];
    const out: Group[] = [];
    for (const p of projects) {
      const ws = left.filter((x) => x.term === p.name || x.term === p.key);
      if (!ws.length) continue;
      left = left.filter((x) => !ws.includes(x));
      out.push({ id: p.id, name: p.name, key: p.key, terms: ws.sort((a) => (a.term === p.name ? -1 : 1)) });
    }
    out.push(...left.map((x) => ({ id: `word:${x.term}`, name: x.term, key: '', terms: [x] })));
    return out.sort((a, b) => a.name.localeCompare(b.name, 'en', { sensitivity: 'base', numeric: true }));
  }, [terms, projects]);

  const current = selected ? all.find((x) => x.term === selected) ?? null : null;
  // while the field finds, the detail follows what is shown: the word already there (a duplicate), else the first match
  useEffect(() => {
    if (!terms || !field.trim()) return;
    const dup = duplicates.length ? active.find((x) => same(x.term, duplicates[0])) : undefined;
    if (dup) return setSelected(dup.term);
    if (!filtering) return;
    const shown = [...matching(suggestions), ...matching(mine), ...matching(projectWords), ...matching(builtIn)];
    if (!shown.some((x) => x.term === selected)) setSelected(shown[0]?.term ?? null);
  }, [field, terms]);
  // a word waiting for review is what the detail opens on
  useEffect(() => {
    if (terms && !selected && suggestions.length) setSelected(suggestions[0].term);
    if (terms && selected && !all.some((x) => x.term === selected)) setSelected(null);
  }, [terms]);

  // ---- changes, each with Undo (the pill and Ctrl+Z)
  const offerUndo = (msg: string, run: () => Promise<void>) => {
    clearTimeout(undoTimer.current);
    setUndo({ msg, run });
    undoTimer.current = setTimeout(() => setUndo(null), 5000);
  };
  const runUndo = async () => {
    const u = undo;
    if (!u) return;
    clearTimeout(undoTimer.current);
    setUndo(null);
    try {
      await u.run();
    } catch (e) {
      onToast(String(e));
    }
    reload();
  };
  const edit = async (op: Parameters<typeof api.dictationWordsEdit>[0], term: string, to?: string) => {
    try {
      await api.dictationWordsEdit(op, term, to);
    } catch (e) {
      onToast(String(e));
    }
  };

  const add = async () => {
    if (!addable.length) return;
    await edit('add', addable.join(', '));
    setField('');
    await reload();
    setSelected(addable[addable.length - 1]);
  };
  const remove = async (ts: VocabTerm[]) => {
    if (!ts.length) return;
    for (const x of ts) await edit('remove', x.term);
    if (ts.some((x) => x.term === selected)) setSelected(null);
    await reload();
    const names = ts.map((x) => x.term).join(sep);
    offerUndo(t('dictation_words.removed', { w: names }), async () => {
      for (const x of ts) await edit('restore', x.term);
      setSelected(ts[0].term);
    });
  };
  /** Add / Ignore a word waiting for review: the next one is chosen (the review goes on), else the word added. */
  const decide = async (x: VocabTerm, accept: boolean) => {
    const next = suggestions.find((s) => s.term !== x.term)?.term ?? null;
    await edit(accept ? 'accept' : 'reject', x.term);
    await reload();
    setSelected(next ?? (accept ? x.term : null));
    offerUndo(t(accept ? 'dictation_words.accepted' : 'dictation_words.ignored', { w: x.term }), async () => {
      await edit('suggest', x.term);
      setSelected(x.term);
    });
  };
  const beginRename = (x: VocabTerm) => {
    setSelected(x.term);
    setRenaming({ term: x.term, text: x.term });
  };
  const commitRename = async () => {
    const r = renaming;
    setRenaming(null);
    if (!r) return;
    const n = r.text.trim();
    if (!n || n === r.term) return;
    const res = await api.dictationWordsEdit('rename', r.term, n).catch((e) => (onToast(String(e)), null));
    if (!res || res.changed === false) return;
    await reload();
    setSelected(n);
    offerUndo(t('dictation_words.renamed', { w: n }), async () => {
      await edit('rename', n, r.term);
      setSelected(r.term);
    });
  };

  // Ctrl+Z: this tab's undo first (the window's item undo listens on the window too)
  useEffect(() => {
    const onKey = (ev: KeyboardEvent) => {
      if (!undo || !(ev.ctrlKey || ev.metaKey) || ev.key.toLowerCase() !== 'z' || ev.shiftKey || inField(ev.target) || isImeKey(ev)) return;
      ev.preventDefault();
      ev.stopPropagation();
      runUndo();
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  });

  // ---- the chips by keyboard: ← → move, Delete removes, Enter edits
  const chipKeys = (ts: VocabTerm[], removeIt: (x: VocabTerm) => void) => (ev: React.KeyboardEvent) => {
    if (renaming || isImeKey(ev)) return;
    const i = ts.findIndex((x) => x.term === selected);
    const move = (by: number) => {
      ev.preventDefault();
      const n = i < 0 ? (by < 0 ? ts.length - 1 : 0) : Math.max(0, Math.min(ts.length - 1, i + by));
      if (ts[n]) setSelected(ts[n].term);
    };
    if (ev.key === 'ArrowLeft' || ev.key === 'ArrowUp') move(-1);
    else if (ev.key === 'ArrowRight' || ev.key === 'ArrowDown') move(1);
    else if ((ev.key === 'Delete' || ev.key === 'Backspace') && i >= 0) {
      ev.preventDefault();
      const next = ts[i + 1]?.term ?? ts[i - 1]?.term ?? null;
      removeIt(ts[i]);
      setSelected(next);
    } else if ((ev.key === 'Enter' || ev.key === 'F2') && i >= 0) {
      ev.preventDefault();
      beginRename(ts[i]);
    }
  };

  const renameField = () => (
    <input className="dw-rename" autoFocus value={renaming?.text ?? ''} aria-label={t('dictation_words.rename')}
      size={Math.max(4, [...(renaming?.text ?? '')].reduce((n, ch) => n + (/[\u2e80-\uffff]/.test(ch) ? 2 : 1), 1))}
      onFocus={(e) => e.currentTarget.select()}
      onChange={(e) => setRenaming((r) => (r ? { ...r, text: e.target.value } : r))}
      onBlur={commitRename}
      onKeyDown={(e) => {
        if (isImeKey(e)) return;
        if (e.key === 'Enter') {
          e.preventDefault();
          commitRename();
        } else if (e.key === 'Escape') {
          e.preventDefault();
          e.stopPropagation();
          setRenaming(null);
        }
      }} />
  );

  const chip = (x: VocabTerm, fixed = false) =>
    renaming?.term === x.term ? (
      <span key={x.term}>{renameField()}</span>
    ) : (
      <span key={x.term} role="option" aria-selected={selected === x.term} data-testid="word-chip"
        className={`dw-chip ${selected === x.term ? 'sel' : ''} ${fixed ? 'fixed' : ''}`}
        onClick={() => setSelected(selected === x.term ? null : x.term)} onDoubleClick={() => !fixed && beginRename(x)}
        onContextMenu={(e) => { e.preventDefault(); setSelected(x.term); if (!fixed) setMenu({ x: e.clientX, y: e.clientY }); }}>
        {x.term}
        {/* the built-in words are given, not yours: no × on them (as on the Mac) */}
        {!fixed && (
          <button className="dw-x" tabIndex={-1} aria-label={t('dictation_words.remove_word', { w: x.term })}
            onClick={(e) => { e.stopPropagation(); remove([x]); }}>
            <Icon name="x" size={8} />
          </button>
        )}
      </span>
    );

  const chips = (ts: VocabTerm[], fixed = false) => (
    <div className="dw-chips" role="listbox" tabIndex={0} aria-label={t(fixed ? 'dictation_words.builtin' : 'dictation_words.mine')}
      onFocus={(e) => { if (e.target === e.currentTarget && !ts.some((x) => x.term === selected) && ts[0]) setSelected(ts[0].term); }}
      onKeyDown={chipKeys(ts, (x) => !fixed && remove([x]))}>
      {ts.map((x) => chip(x, fixed))}
    </div>
  );

  // while the field finds, a group's count is what it shows of how many ("1 / 9")
  const heading = (title: string, n: number, tip?: string, shown?: number) => (
    <div className="dw-head" role="heading" aria-level={3} title={tip}>
      <b>{title}</b>
      <span className="dim">{filtering && shown !== undefined && shown !== n ? `${i18n().formatNumber(shown)} / ${i18n().formatNumber(n)}` : i18n().formatNumber(n)}</span>
    </div>
  );

  const hint = !field.trim()
    ? t('dictation_words.about')
    : duplicates.length && !addable.length
      ? t('dictation_words.duplicate', { w: duplicates.join(sep) })
      : addable.length > 1
        ? t('dictation_words.add_hint_list', { w: addable.join(sep) })
        : addable.length
          ? t('dictation_words.add_hint', { w: addable[0] })
          : '';

  const noMatch = filtering && [suggestions, mine, projectWords, builtIn].every((ts) => !matching(ts).length);
  const shownGroups = groups.filter((g) => !filtering || matching(g.terms).length);
  const builtInOpen = filtering || showBuiltIn;

  const list = (
    <section className={`dict-list dw-list ${undo ? 'has-undo' : ''} ${menu ? 'menu-open' : ''}`} data-testid="dictation-words">
      {header}
      <div className="dw-field">
        <div className="searchbox">
          <Icon name="search" size={14} />
          <input ref={fieldRef} value={field} placeholder={t('dictation_words.placeholder')} aria-label={t('dictation_words.placeholder')} data-testid="words-field"
            onChange={(e) => setField(e.target.value)}
            onKeyDown={(e) => {
              if (isImeKey(e)) return;
              if (e.key === 'Enter') {
                e.preventDefault();
                add();
              } else if (e.key === 'Escape') {
                e.preventDefault();
                if (field) setField('');
                else e.currentTarget.blur();
              }
            }} />
          {field && (
            <button className="icon-btn dw-clear" aria-label={t('dictation_page.clear_search')} title={t('dictation_page.clear_search')} onClick={() => { setField(''); fieldRef.current?.focus(); }}>
              <Icon name="x" size={12} />
            </button>
          )}
        </div>
        <p className="dw-hint" data-testid="words-hint">{hint}</p>
      </div>
      <div className="dw-scroll">
        {noMatch ? (
          <p className="dw-empty">{t('dictation_words.no_match', { q: query })}</p>
        ) : !all.length ? (
          // no words at all: one statement under the field, no "Yours 0" over it
          <div className="dw-none">
            <Icon name="list-box" size={28} />
            <b>{t('dictation_words.empty.title')}</b>
            <span>{t('dictation_words.empty.body')}</span>
          </div>
        ) : (
          <>
            {matching(suggestions).length > 0 && (
              <div className="dw-group">
                {heading(t('dictation_words.suggested'), suggestions.length, undefined, matching(suggestions).length)}
                <div className="dw-review" role="listbox" aria-label={t('dictation_words.suggested')}>
                  {matching(suggestions).map((x) => (
                    <div key={x.term} role="option" aria-selected={selected === x.term} data-testid="word-review"
                      className={`dw-row ${selected === x.term ? 'sel' : ''}`} onClick={() => setSelected(x.term)}
                      onKeyDown={(e) => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); decide(x, true); } }} tabIndex={-1}>
                      <b>{x.term}</b>
                      <span className="dim small">{t('dictation_words.source.suggested')}</span>
                      <span className="grow" />
                      <span className="dw-tools">
                        <button className="link dw-add" title={t('dictation_words.accept_tip')} onClick={(e) => { e.stopPropagation(); decide(x, true); }}>
                          {t('dictation_words.add')}
                        </button>
                        <button className="icon-btn" title={t('dictation_words.ignore')} aria-label={`${t('dictation_words.ignore')} ${x.term}`}
                          onClick={(e) => { e.stopPropagation(); decide(x, false); }}>
                          <Icon name="x" size={10} />
                        </button>
                      </span>
                    </div>
                  ))}
                </div>
              </div>
            )}
            {(!filtering || matching(mine).length > 0) && (
              <div className="dw-group">
                {heading(t('dictation_words.mine'), mine.length, undefined, matching(mine).length)}
                {mine.length ? chips(matching(mine)) : <p className="dw-empty">{t('dictation_words.mine_empty')}</p>}
              </div>
            )}
            {shownGroups.length > 0 && (
              <div className="dw-group">
                {heading(t('dictation_words.projects'), projectWords.length, t('dictation_words.projects_detail'), matching(projectWords).length)}
                <div className="dw-chips" role="listbox" tabIndex={0} aria-label={t('dictation_words.projects')}
                  onKeyDown={chipKeys(shownGroups.map((g) => g.terms[0]), (x) => remove(shownGroups.find((g) => g.terms[0] === x)?.terms ?? [x]))}>
                  {shownGroups.map((g) => {
                    const on = g.terms.some((x) => x.term === selected);
                    if (renaming && g.terms.some((x) => x.term === renaming.term)) return <span key={g.id}>{renameField()}</span>;
                    const nameIsWord = g.terms.some((x) => x.term === g.name);
                    const keyWord = !g.key || g.terms.some((x) => x.term === g.key);
                    const off = [nameIsWord ? null : g.name, keyWord ? null : g.key].filter(Boolean).join(sep);
                    const tip = t('dictation_words.project_tip', { p: g.name, w: g.terms.map((x) => x.term).join(sep) }) + (off ? `\n${t('dictation_words.not_sent', { w: off })}` : '');
                    return (
                      <span key={g.id} role="option" aria-selected={on} title={tip} className={`dw-chip ${on ? 'sel' : ''}`}
                        onClick={() => setSelected(on ? null : g.terms[0].term)} onDoubleClick={() => beginRename(g.terms[0])}
                        onContextMenu={(e) => { e.preventDefault(); setSelected(g.terms[0].term); setMenu({ x: e.clientX, y: e.clientY }); }}>
                        <span className={nameIsWord ? '' : 'dw-off'}>{g.name}</span>
                        {g.key && <span className={`dw-key ${keyWord ? '' : 'dw-off'}`}>{g.key}</span>}
                        <button className="dw-x" tabIndex={-1} aria-label={t('dictation_words.remove_word', { w: g.name })} onClick={(e) => { e.stopPropagation(); remove(g.terms); }}>
                          <Icon name="x" size={8} />
                        </button>
                      </span>
                    );
                  })}
                </div>
              </div>
            )}
            {builtIn.length > 0 && (!filtering || matching(builtIn).length > 0) && (
              <div className="dw-group">
                <button className="dw-fold" disabled={filtering} aria-expanded={builtInOpen}
                  aria-label={t(builtInOpen ? 'dictation_words.hide_ax' : 'dictation_words.show_ax')} onClick={() => setShowBuiltIn((v) => !v)}>
                  {heading(t('dictation_words.builtin'), builtIn.length)}
                  <Icon name="chevron-right" size={10} className={builtInOpen ? 'dw-open' : ''} />
                </button>
                {builtInOpen && (
                  <>
                    <p className="dw-empty">{t('dictation_words.builtin_detail')}</p>
                    {chips(matching(builtIn), true)}
                  </>
                )}
              </div>
            )}
          </>
        )}
      </div>
      {undo && (
        <div className="dict-undo" role="status" title="Ctrl+Z">
          <span>{undo.msg}</span>
          <button className="dict-undo-btn" title="Ctrl+Z" onClick={runUndo}>{t('dictation_page.undo')}</button>
        </div>
      )}
    </section>
  );

  // ---- the detail column: told, not acted on
  const source = (x: VocabTerm) => {
    if (x.state === 'suggested') return t('dictation_words.source.review');
    if (x.source === 'project') return t('dictation_words.source.project');
    return t(`dictation_words.source.${x.source ?? 'manual'}`);
  };
  /** A project word's group: its name and its key, both sent as hints (the chip shows both, so does the detail). */
  const groupOf = (x: VocabTerm) => groups.find((g) => !g.id.startsWith('word:') && g.terms.includes(x));
  /** "Found": relative while it is recent (today, yesterday), else a date (the Mac's). */
  const when = (iso?: string) => {
    if (!iso) return null;
    try {
      const d = new Date(iso);
      const now = new Date();
      const y = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
      if (d.toDateString() === now.toDateString()) return `${t('dictation_page.today')} ${i18n().formatDate(d, 'time')}`;
      if (d.toDateString() === y.toDateString()) return `${t('dictation_page.yesterday')} ${i18n().formatDate(d, 'time')}`;
      return i18n().formatDate(d, d.getFullYear() === now.getFullYear() ? { month: 'short', day: 'numeric' } : { year: 'numeric', month: 'short', day: 'numeric' });
    } catch {
      return null;
    }
  };
  const detail = current ? (
    <div className="dict-detail-in" data-testid="word-detail">
      <div className="dw-dhead">
        <div className="grow">
          <h2 className="dw-term">{current.term}</h2>
          <div className="dim small">{source(current)}</div>
        </div>
        {current.state !== 'suggested' && current.source !== 'default' && (
          // no title: a tooltip would hang beside the open menu; the menu ends at the button's right edge
          <button className="icon-btn dict-ghost" aria-label={t('dictation_page.more')} aria-haspopup="menu"
            onClick={(ev) => { const r = ev.currentTarget.getBoundingClientRect(); setMenu({ x: r.right, y: r.bottom + 4, right: true }); }}>
            <Icon name="more" size={15} />
          </button>
        )}
      </div>
      {current.state === 'suggested' && <p className="dim dw-review-detail">{t('dictation_words.review_detail')}</p>}
      <dl className="dict-info">
        {groupOf(current) && <><dt>{t('dictation_words.info.project')}</dt><dd>{groupOf(current)!.name}</dd></>}
        {groupOf(current)?.key && <><dt>{t('dictation_words.info.key')}</dt><dd className="dw-keyval">{groupOf(current)!.key}</dd></>}
        {current.state !== 'suggested' && <><dt>{t('dictation_words.info.used')}</dt><dd>{t('dictation_words.info.seen_value', { n: i18n().formatNumber(current.hits ?? 0) })}</dd></>}
        {!!current.sounds_like?.length && <><dt>{t('dictation_words.info.heard')}</dt><dd>{current.sounds_like.join(sep)}</dd></>}
        {current.state === 'suggested' && <><dt>{t('dictation_words.info.seen')}</dt><dd>{t('dictation_words.info.seen_value', { n: Math.max(1, current.seen ?? 1) })}</dd></>}
        {when(current.added) && <><dt>{t(current.state === 'suggested' ? 'dictation_words.info.found' : 'dictation_words.info.added')}</dt><dd>{when(current.added)}</dd></>}
      </dl>
    </div>
  ) : !all.length ? (
    <div className="blank dict-none" />
  ) : (
    <div className="blank dict-none">
      <Icon name="list-box" size={28} />
      <b>{t('dictation_words.none')}</b>
      <span className="small">{t('dictation_words.none_detail')}</span>
    </div>
  );

  return (
    <div className="dict-split" data-testid="dictation">
      {list}
      <aside className="detail dict-detail">{detail}</aside>
      {menu && current && (
        <Menu at={menu} onClose={() => setMenu(null)}>
          <MenuItem label={t('dictation_words.rename')} keys="F2" onClick={() => beginRename(current)} />
          <div className="dict-sep" />
          <MenuItem label={t('dictation_words.remove')} keys="Del" danger onClick={() => remove([current])} />
        </Menu>
      )}
    </div>
  );
}
