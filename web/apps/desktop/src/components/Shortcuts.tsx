// "?" — the keyboard map (the Mac's ShortcutsSheet), in four short sections: where you go, an item's state, what you do
// with an item, the app and its window. Each row is the action, then its keys as keycaps at the trailing edge, "or"
// between alternatives. A search field filters the rows; ?, Ctrl+/ or Esc closes it. Windows keys: Ctrl for ⌘, Alt
// for ⌥, Enter, Delete.
import { useMemo, useState } from 'react';
import { Icon } from '@blurt/icons';
import { t } from '../i18n';

type Row = { label: string; note?: string; keys: string[][] };

export function shortcutSections(): [string, Row[]][] {
  const plain = (s: string) => s.replace(/…/g, '');
  return [
    [t('main.keys.section.navigate'), [
      { label: t('main.keys.palette'), keys: [['Ctrl+K']] },
      { label: t('main.keys.search'), keys: [['Ctrl+F'], ['/']] },
      { label: t('main.keys.next'), keys: [['J'], ['↓']] },
      { label: t('main.keys.previous'), keys: [['K'], ['↑']] },
      { label: t('main.keys.open'), keys: [['Enter']] },
      { label: t('main.keys.back_to_list'), keys: [['Esc'], ['Shift+Tab']] },
      { label: t('main.keys.places'), keys: [['Ctrl+1', '–', 'Ctrl+4']] },
      { label: t('main.keys.projects'), keys: [['Ctrl+5', '–', 'Ctrl+9']] },
    ]],
    [t('main.keys.section.triage'), [
      { label: t('state.menu'), keys: [['S']] },
      { label: t('action.keep'), note: t('main.keys.keep.note'), keys: [['A']] },
      { label: t('action.done'), keys: [['D']] },
      { label: t('action.wontfix'), keys: [['W']] },
      { label: t('action.discard'), keys: [['X'], ['Delete']] },
      { label: t('main.keys.back'), note: t('main.keys.back.note'), keys: [['R']] },
      { label: t('main.keys.kind'), keys: [['1', '–', '4']] },
    ]],
    [t('main.keys.section.item'), [
      { label: plain(t('action.hand_off')), keys: [['Ctrl+Enter']] },
      { label: t('main.keys.copy_instruction'), keys: [['Ctrl+Shift+C']] },
      { label: plain(t('main.menu.rename')), keys: [['E']] },
      { label: t('main.keys.move'), keys: [['M']] },
      { label: t('mw.open_picture'), keys: [[t('main.keys.space')]] },
      { label: t('mw.reveal'), keys: [['Ctrl+Shift+R']] },
      { label: t('main.keys.copy_path'), keys: [['Ctrl+Alt+C']] },
    ]],
    [t('main.keys.section.general'), [
      { label: t('main.keys.dictation'), keys: [['Ctrl+Alt+D']] },
      { label: t('main.new_item.title'), keys: [['Ctrl+N']] },
      { label: t('main.keys.open_folder'), keys: [['Ctrl+O']] },
      { label: t('main.keys.project_settings'), keys: [['Ctrl+I']] },
      { label: t('main.keys.sidebar'), keys: [['Ctrl+Shift+S']] },
      { label: t('main.keys.detail'), keys: [['Ctrl+Alt+I']] },
      { label: t('menu.undo'), keys: [['Ctrl+Z']] },
      { label: t('menu.redo'), keys: [['Ctrl+Y'], ['Ctrl+Shift+Z']] },
      { label: t('mw.settings'), keys: [['Ctrl+,']] },
      { label: t('main.keys.close_window'), note: t('mw.keys.close_window.note'), keys: [['Ctrl+W']] },
      { label: t('main.keys.this'), keys: [['?'], ['Ctrl+/']] },
    ]],
  ];
}

export function Shortcuts({ onClose }: { onClose: () => void }) {
  const [q, setQ] = useState('');
  const sections = useMemo(shortcutSections, []);
  const words = q.toLowerCase().split(/\s+/).filter(Boolean);
  const hay = (s: string, r: Row) => [r.label, r.note ?? '', s, ...r.keys.flat()].join(' ').toLowerCase();
  const shown = sections.map(([s, rows]) => [s, rows.filter((r) => words.every((w) => hay(s, r).includes(w)))] as const).filter(([, rows]) => rows.length);
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="sheet mw-keys" role="dialog" aria-modal="true" aria-label={t('menu.shortcuts')} data-testid="shortcuts"
        onKeyDown={(e) => {
          if (e.key === 'Escape') {
            e.stopPropagation();
            if (q) setQ('');
            else onClose();
          } else if (e.key === '/' && e.ctrlKey) onClose();
        }}>
        <h2>{t('menu.shortcuts')}</h2>
        <div className="mw-keys-search">
          <Icon name="search" size={14} />
          <input
            autoFocus
            type="search"
            value={q}
            placeholder={t('main.keys.search_field')}
            onChange={(e) => (e.target.value === '?' ? onClose() : setQ(e.target.value))}
          />
        </div>
        <div className="mw-keys-list">
          {shown.map(([s, rows]) => (
            <section key={s}>
              <h3>{s}</h3>
              {rows.map((r) => (
                <div key={r.label} className="mw-keys-row" title={r.note ? `${r.label} — ${r.note}` : undefined}>
                  <span className="txt">
                    <span>{r.label}</span>
                    {r.note && <span className="dim small">{r.note}</span>}
                  </span>
                  <span className="mw-keycaps">
                    {r.keys.map((alt, i) => (
                      <span key={i}>
                        {i > 0 && <span className="dim small mw-or">{t('main.keys.or')}</span>}
                        {alt.map((k, j) => (k === '–' ? <span key={j} className="dim">–</span> : <kbd key={j}>{k}</kbd>))}
                      </span>
                    ))}
                  </span>
                </div>
              ))}
            </section>
          ))}
          {!shown.length && <p className="dim mw-keys-none">{t('main.keys.no_match')}</p>}
        </div>
        <p className="dim small mw-keys-foot">{t('main.keys.footer')}</p>
      </div>
    </div>
  );
}
