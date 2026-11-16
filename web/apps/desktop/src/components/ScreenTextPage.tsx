// The Text & Translation page (the Mac's MainWindow/ScreenTextPage.swift; docs/design/screen-text.md §1g): what
// Alt+Shift+C copied and Alt+Shift+T translated, newest first by day (screen_text/history.rs). The header: the two keys
// and how long the history keeps them, with Settings…. A search over the text, the original and the app. A row: copy
// or translate glyph, "Translate text on screen · Edge", the text (up to three lines), a translation's original on a
// quiet line under it, the time — Copy in its place under the pointer. Click, Ctrl-click, Shift-click, ↑↓ / Shift+↑↓,
// Ctrl+A select; a double-click or Enter copies one, Ctrl+C the selection (a blank line between), Delete deletes it;
// the right-click menu has Copy, Copy Original and Delete.
import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Icon } from '@blurt/icons';
import { api, listen, type HotkeyRow, type ScreenTextEntry, type ScreenTextHistory } from '../api';
import { byDay, click, copied, keepLine, matches, NONE, step, type Selection } from '../screentext';
import { i18n, t } from '../i18n';
import { useMenu, type MenuEntry } from './Menu';
import './pages.css';

function dayLabel(day: number): string {
  const d = new Date(day * 1000);
  const now = new Date();
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() / 1000;
  const days = Math.round((start - day) / 86400);
  if (days <= 0) return t('dictation_page.today');
  if (days === 1) return t('dictation_page.yesterday');
  const loc = i18n().locale;
  if (days < 7) return new Intl.DateTimeFormat(loc, { weekday: 'long' }).format(d);
  return new Intl.DateTimeFormat(loc, { month: 'long', day: 'numeric', year: d.getFullYear() === now.getFullYear() ? undefined : 'numeric' }).format(d);
}
const clock = (time: number) => new Intl.DateTimeFormat(i18n().locale, { hour: 'numeric', minute: '2-digit' }).format(new Date(time * 1000));

/** "Translate text on screen · Microsoft Edge" */
export const screenTextSource = (e: ScreenTextEntry) => [t(e.translated ? 'settings.hotkey.translate' : 'settings.hotkey.text'), e.app].filter(Boolean).join(' · ');

function Caps({ label }: { label: string }) {
  return (
    <span className="pg-caps">
      {label.split('+').map((k) => k.trim()).filter(Boolean).map((k, i) => <kbd key={i}>{k}</kbd>)}
    </span>
  );
}

export function ScreenTextPage({ hotkeys, onSettings, onToast }: {
  hotkeys: HotkeyRow[];
  onSettings: () => void;
  onToast: (m: string) => void;
}) {
  const [data, setData] = useState<ScreenTextHistory | null>(null);
  const [q, setQ] = useState('');
  const [sel, setSel] = useState<Selection>(NONE);
  const menu = useMenu();
  const search = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const load = useCallback(() => api.screenTextHistory().then(setData, () => setData({ entries: [], days: 30, count: 0 })), []);
  useEffect(() => {
    void load();
    return listen('screen-text://changed', () => void load());
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

  const all = data?.entries ?? [];
  const shown = useMemo(() => (q.trim() ? all.filter((e) => matches(e, q)) : all), [all, q]);
  const order = shown.map((e) => e.id);
  const days = useMemo(() => byDay(shown), [shown]);
  const picked = sel.ids.filter((id) => order.includes(id));
  const label = (a: string) => hotkeys.find((h) => h.action === a && h.spec !== 'off')?.label ?? '';

  const copy = async (ids: string[], original = false) => {
    const text = copied(shown, ids, original);
    if (!text) return;
    await api.copyText(text).catch(() => {});
    onToast(t('dictation_page.copied'));
  };
  const remove = async (ids: string[]) => {
    if (!ids.length) return;
    await api.screenTextHistoryDelete(ids).catch(() => {});
    setSel(NONE);
    void load();
  };
  const rowMenu = (e: ScreenTextEntry): MenuEntry[] => {
    const ids = picked.includes(e.id) ? picked : [e.id];
    const originals = shown.some((x) => ids.includes(x.id) && x.translated && x.source);
    return [
      { label: t('home.entry.copy'), keys: 'Ctrl+C', run: () => void copy(ids) },
      ...(originals ? [{ label: t('home.screen_text.copy_original'), run: () => void copy(ids, true) }] : []),
      { kind: 'separator' } as MenuEntry,
      { label: t('home.screen_text.delete'), keys: 'Del', danger: true, run: () => void remove(ids) } as MenuEntry,
    ];
  };

  const onKey = (e: React.KeyboardEvent) => {
    const ctrl = e.ctrlKey || e.metaKey;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      const s = step({ ids: picked, anchor: sel.anchor }, order, e.key === 'ArrowDown' ? 1 : -1, e.shiftKey);
      setSel(s);
      list.current?.querySelector(`[data-id="${CSS.escape(s.ids[e.key === 'ArrowDown' ? s.ids.length - 1 : 0] ?? '')}"]`)?.scrollIntoView({ block: 'nearest' });
    } else if (ctrl && e.key.toLowerCase() === 'a') {
      e.preventDefault();
      setSel({ ids: order, anchor: order[0] ?? null });
    } else if (ctrl && e.key.toLowerCase() === 'c' && picked.length) {
      e.preventDefault();
      void copy(picked);
    } else if (e.key === 'Enter' && picked.length) {
      e.preventDefault();
      void copy(picked);
    } else if ((e.key === 'Delete' || e.key === 'Backspace') && picked.length) {
      e.preventDefault();
      void remove(picked);
    } else if (e.key === 'Escape' && picked.length) {
      setSel(NONE);
    }
  };

  const row = (e: ScreenTextEntry) => {
    const on = picked.includes(e.id);
    return (
      <div key={e.id} data-id={e.id} role="option" aria-selected={on} className={`sx-row ${on ? 'sel' : ''}`} data-testid="screen-text-row"
        onMouseDown={(ev) => ev.detail > 1 && ev.preventDefault()}
        onClick={(ev) => setSel(click({ ids: picked, anchor: sel.anchor }, e.id, order, { toggle: ev.ctrlKey || ev.metaKey, range: ev.shiftKey }))}
        onDoubleClick={() => void copy([e.id])}
        onContextMenu={(ev) => {
          ev.preventDefault();
          if (!picked.includes(e.id)) setSel({ ids: [e.id], anchor: e.id });
          menu.open(rowMenu(e), { x: ev.clientX, y: ev.clientY });
        }}>
        <span className="hm-entry-ic"><Icon name={e.translated ? 'languages' : 'text-viewfinder'} size={15} /></span>
        <span className="hm-entry-text">
          <span className="hm-entry-src">{screenTextSource(e)}</span>
          <span className="sx-row-text">{e.text}</span>
          {e.translated && e.source && (
            <span className="sx-row-orig" title={e.source}><span className="sx-row-orig-k">{t('home.screen_text.original')}</span> {e.source}</span>
          )}
        </span>
        <span className="sx-row-end">
          <span className="hm-entry-time">{clock(e.time)}</span>
          <button className="pg-small sx-row-copy" onClick={(ev) => (ev.stopPropagation(), void copy([e.id]))} tabIndex={-1}>{t('home.entry.copy')}</button>
        </span>
      </div>
    );
  };

  const textKey = label('text');
  const trKey = label('translate');
  const keep = data ? keepLine(data.days, data.count, t) : '';
  let body: ReactNode;
  if (!data) body = null;
  else if (!all.length)
    body = (
      <div className="pg-empty big" data-testid="screen-text-empty">
        <span className="pg-empty-ic"><Icon name="text-viewfinder" size={28} /></span>
        <div className="pg-empty-line center">
          {data.days === 0 ? t('home.screen_text.empty.off') : textKey && trKey ? t('home.screen_text.empty', { a: textKey, b: trKey }) : t('home.screen_text.empty.nokey')}
        </div>
      </div>
    );
  else
    body = (
      <>
        <div className="pg-search">
          <Icon name="search" size={14} />
          <input ref={search} type="search" value={q} placeholder={t('home.screen_text.search')} aria-label={t('home.screen_text.search')}
            onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === 'Escape' && q && (e.preventDefault(), setQ(''))} data-testid="screen-text-search" />
        </div>
        {!shown.length ? (
          <div className="pg-empty">
            <div className="pg-empty-line">{t('home.screen_text.none_found')}</div>
            <button className="pg-link" onClick={() => setQ('')}>{t('home.screen_text.clear_search')}</button>
          </div>
        ) : (
          <div className="sx-list" ref={list} tabIndex={0} role="listbox" aria-multiselectable="true" aria-label={t('feature.screen_text')} onKeyDown={onKey}>
            {days.map((d) => (
              <section key={d.day} className="hm-day">
                <h3 className="hm-day-title">{dayLabel(d.day)}</h3>
                <div className="pg-box">{d.rows.map(row)}</div>
              </section>
            ))}
          </div>
        )}
      </>
    );

  return (
    <div className="pg" data-testid="screen-text-page">
      <div className="pg-col">
        <header className="pg-head">
          <div className="pg-head-text">
            <h1 className="pg-title">{t('feature.screen_text')}</h1>
            <div className="pg-sub sx-head-sub">
              {textKey && <span className="sx-head-key"><Caps label={textKey} />{t('settings.hotkey.text')}</span>}
              {trKey && <span className="sx-head-key"><Caps label={trKey} />{t('settings.hotkey.translate')}</span>}
              {keep && <span>{keep}</span>}
            </div>
          </div>
          <div className="pg-head-acts">
            {picked.length > 1 && <span className="sx-selected">{t('home.screen_text.selected', { n: picked.length })}</span>}
            <button onClick={onSettings}>{t('home.screen_text.settings')}</button>
          </div>
        </header>
        {body}
      </div>
      {menu.node}
    </div>
  );
}
