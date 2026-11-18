// The Cards page (the Mac's MainWindow/CardsPage.swift; docs/design/capabilities.md): every card in one place — Current,
// the cards at the top of the screen now, and History, the ones used in other apps in the last 7 days. The Cards panel
// at the top of the screen (Alt+Shift+H) stays the place to work with them; this is where to look one up (search over
// the notes). A card: its picture or its glyph, its note, when. Enter or a double-click copies it (the picture and the
// note, as the panel's Copy does), Delete deletes it (Undo puts it back), the right-click menu has both and Show in
// File Explorer. Snap, Voice note and Show at the Top of the Screen in the header.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Icon } from '@blurt/icons';
import { api, listen, type CardInfo, type HotkeyRow } from '../api';
import { i18n, t } from '../i18n';
import { useMenu, type MenuEntry } from './Menu';
import './pages.css';
import { revealLabel } from '../reveal';

const keyOf = (c: CardInfo) => `${c.session ?? ''}#${c.n}`;
const when = (c: CardInfo) => c.taken ?? c.wall ?? 0;
const kindOf = (c: CardInfo) => (c.ref ? 'file' : c.textCard ? 'text' : c.kind === 'voice' || !c.src ? 'voice' : 'shot');

function ago(sec: number): string {
  if (!sec) return '';
  const d = new Date(sec * 1000);
  const now = new Date();
  const same = d.toDateString() === now.toDateString();
  const loc = i18n().locale;
  return same
    ? new Intl.DateTimeFormat(loc, { hour: 'numeric', minute: '2-digit' }).format(d)
    : new Intl.DateTimeFormat(loc, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(d);
}

export function CardsPage({ hotkeys, onSnap, onToast }: {
  hotkeys: HotkeyRow[];
  platform: string;
  onSnap: () => void;
  onToast: (m: string, undo?: () => void) => void;
}) {
  const [data, setData] = useState<{ current: CardInfo[]; history: CardInfo[] } | null>(null);
  const [q, setQ] = useState('');
  const [sel, setSel] = useState<string | null>(null);
  const menu = useMenu();
  const search = useRef<HTMLInputElement>(null);
  const load = useCallback(() => api.cardsList().then(setData, () => setData({ current: [], history: [] })), []);
  useEffect(() => {
    void load();
    return listen('cards://changed', () => void load());
  }, [load]);
  // Ctrl+F or /: the search field
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      const field = (e.target as HTMLElement)?.closest?.('input, textarea, [contenteditable]');
      if (((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f') || (e.key === '/' && !field)) {
        e.preventDefault();
        search.current?.focus();
      }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, []);

  const terms = q.toLowerCase().split(/\s+/).filter(Boolean);
  const match = (c: CardInfo) => terms.every((w) => (c.text ?? '').toLowerCase().includes(w) || (c.ref ?? '').toLowerCase().includes(w));
  const current = useMemo(() => [...(data?.current ?? [])].sort((a, b) => when(b) - when(a)).filter(match), [data, q]);
  const history = useMemo(() => [...(data?.history ?? [])].filter(match), [data, q]);
  const all = [...current, ...history];
  const label = (a: string) => hotkeys.find((h) => h.action === a && h.spec !== 'off')?.label ?? '';

  const act = async (c: CardInfo, action: 'copy' | 'copy_text' | 'remove' | 'reveal') => {
    if (!c.session) return;
    await api.cardAction(action, c.session, c.n).catch(() => {});
    if (action === 'copy' || action === 'copy_text') onToast(t('cards.copied'));
    if (action === 'remove') {
      onToast(t('cards.deleted'), () => void api.cardAction('restore', c.session!, c.n).then(load, () => {}));
      void load();
    }
  };
  const cardMenu = (c: CardInfo): MenuEntry[] => [
    { label: t('cards.menu.copy'), keys: 'Enter', run: () => void act(c, 'copy') },
    ...(c.text && kindOf(c) === 'shot' ? [{ label: t('cards.menu.copy_text'), run: () => void act(c, 'copy_text') }] : []),
    ...(kindOf(c) === 'shot' || (kindOf(c) === 'file' && !c.missing) ? [{ label: revealLabel(), run: () => void act(c, 'reveal') }] : []),
    { kind: 'separator' } as MenuEntry,
    { label: t('cards.menu.delete'), keys: 'Del', danger: true, run: () => void act(c, 'remove') } as MenuEntry,
  ];

  const onKey = (e: React.KeyboardEvent) => {
    const i = all.findIndex((c) => keyOf(c) === sel);
    const c = i >= 0 ? all[i] : null;
    if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
      e.preventDefault();
      setSel(keyOf(all[Math.min(all.length - 1, i + 1)] ?? all[0]));
    } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
      e.preventDefault();
      setSel(keyOf(all[Math.max(0, i - 1)] ?? all[0]));
    } else if (e.key === 'Enter' && c) {
      e.preventDefault();
      void act(c, 'copy');
    } else if ((e.key === 'Delete' || e.key === 'Backspace') && c) {
      e.preventDefault();
      void act(c, 'remove');
    }
  };

  const tile = (c: CardInfo) => {
    const k = kindOf(c);
    const id = keyOf(c);
    const name = c.ref ? c.ref.split(/[\\/]/).pop() : null;
    return (
      <button key={id} className={`cd-tile ${sel === id ? 'sel' : ''} cd-k-${k}`} data-testid="cards-tile"
        aria-label={[t(k === 'voice' ? 'home.entry.voice' : k === 'file' ? 'home.entry.file' : k === 'text' ? 'home.entry.text' : 'home.entry.snap'), c.text || '', ago(when(c))].filter(Boolean).join(', ')}
        title={t('cards.ax.help')}
        onClick={() => setSel(id)}
        onDoubleClick={() => void act(c, 'copy')}
        onContextMenu={(e) => {
          e.preventDefault();
          setSel(id);
          menu.open(cardMenu(c), { x: e.clientX, y: e.clientY });
        }}>
        {k === 'shot' ? (
          <span className="cd-pic"><img src={c.src} alt="" draggable={false} /></span>
        ) : (
          <span className={`cd-face cd-k-${k}`}>
            <Icon name={k === 'voice' ? 'mic' : k === 'file' ? 'document' : 'quote'} size={20} />
            {k === 'file' && <span className="cd-file">{name}</span>}
          </span>
        )}
        <span className="cd-text">
          {c.missing ? <span className="cd-note warn"><Icon name="warning" size={12} />{t('cards.missing')}</span>
            : <span className={`cd-note ${c.text ? '' : 'none'}`}>{c.text || t('cards.no_note')}</span>}
          <span className="cd-when">{ago(when(c))}</span>
        </span>
      </button>
    );
  };

  const none = data && !data.current.length && !data.history.length;
  const snapKey = label('snap');
  return (
    <div className="pg" data-testid="cards-page">
      <div className="pg-col wide">
        <header className="pg-head">
          <div className="pg-head-text">
            <h1 className="pg-title">{t('cards.title')}</h1>
            <div className="pg-sub">{t('cards.subtitle')}</div>
          </div>
          <div className="pg-head-acts">
            <button onClick={onSnap} title={[t('cards.action.snap.tip'), snapKey].filter(Boolean).join(' · ')} data-testid="cards-snap">
              <Icon name="snap" size={14} />{t('cards.action.snap')}
            </button>
            <button onClick={() => void api.voice().catch(() => {})} title={[t('cards.action.voice.tip'), label('voice')].filter(Boolean).join(' · ')}>
              <Icon name="mic" size={14} />{t('cards.action.voice')}
            </button>
            {!!data?.current.length && (
              <button onClick={() => void api.revealCards().catch(() => {})} title={t('cards.action.show_top.tip')}>{t('cards.action.show_top')}</button>
            )}
          </div>
        </header>

        {none ? (
          <div className="pg-empty big" data-testid="cards-empty">
            <span className="pg-empty-ic"><Icon name="cards" size={28} /></span>
            <div className="pg-empty-title">{t('cards.empty.title')}</div>
            <div className="pg-empty-line center">{snapKey ? t('cards.empty.message', { a: snapKey }) : t('cards.empty.message_nokey')}</div>
          </div>
        ) : (
          <>
            <div className="pg-search">
              <Icon name="search" size={14} />
              <input ref={search} type="search" value={q} placeholder={t('cards.search.placeholder')} aria-label={t('cards.search.placeholder')}
                onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === 'Escape' && q && (e.preventDefault(), setQ(''))} data-testid="cards-search" />
            </div>
            {terms.length > 0 && !all.length ? (
              <div className="pg-empty">
                <div className="pg-empty-line">{t('cards.search.none', { a: q.trim() })}</div>
                <button className="pg-link" onClick={() => setQ('')}>{t('cards.search.clear')}</button>
              </div>
            ) : (
              <div className="cd-sections" tabIndex={0} onKeyDown={onKey} aria-label={t('cards.title')}>
                <section className="cd-sec">
                  <h2 className="pg-h2">{t('cards.section.current')}<span className="pg-h2-n">{current.length ? i18n().formatNumber(current.length) : ''}</span></h2>
                  {current.length ? <div className="cd-grid">{current.map(tile)}</div> : <div className="pg-quiet">{t('cards.current.none')}</div>}
                </section>
                <section className="cd-sec">
                  <h2 className="pg-h2">{t('cards.section.history')}<span className="pg-h2-note">{t('cards.history.kept')}</span></h2>
                  {history.length ? <div className="cd-grid">{history.map(tile)}</div> : <div className="pg-quiet">{t('cards.history.none')}</div>}
                </section>
              </div>
            )}
          </>
        )}
      </div>
      {menu.node}
    </div>
  );
}
