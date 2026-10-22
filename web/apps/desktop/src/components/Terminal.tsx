// The embedded terminal (contract K5): xterm.js on a pty the app opens for an agent job — a tmux client from
// `sessions.py attach-cmd` (macOS / Linux), or the app runner's own ConPTY session on Windows (its output so far is
// replayed first). Keys go back with pty_write, the size with pty_resize; closing the view ends only the client.
import { useEffect, useRef } from 'react';
import { Terminal as XTerm, type ITheme } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';
import { api, listen } from '../api';

const DARK: ITheme = {
  background: '#141416',
  foreground: '#e6e6e9',
  cursor: '#ff7a5c',
  cursorAccent: '#141416',
  selectionBackground: 'rgba(255, 122, 92, 0.28)',
  black: '#1e1e22', red: '#ff6b6b', green: '#3dd68c', yellow: '#ffc53d', blue: '#8da4ef', magenta: '#d19dff', cyan: '#4ccce6', white: '#d4d4d8',
  brightBlack: '#5c5c66', brightRed: '#ff8f8f', brightGreen: '#6be3a8', brightYellow: '#ffd76b', brightBlue: '#adbff5', brightMagenta: '#e0bbff', brightCyan: '#7fdcef', brightWhite: '#fafafa',
};
const LIGHT: ITheme = {
  background: '#fbfbfa',
  foreground: '#1f1f23',
  cursor: '#e5482c',
  cursorAccent: '#fbfbfa',
  selectionBackground: 'rgba(245, 91, 62, 0.2)',
  black: '#1f1f23', red: '#d93d42', green: '#218358', yellow: '#a8710a', blue: '#3e63dd', magenta: '#8e4ec6', cyan: '#0d7c8c', white: '#6f6f78',
  brightBlack: '#8b8b94', brightRed: '#e5484d', brightGreen: '#2b9a66', brightYellow: '#b86e00', brightBlue: '#3358d4', brightMagenta: '#9e5bd6', brightCyan: '#0e8a9b', brightWhite: '#3a3a40',
};

const theme = () => (document.documentElement.dataset.theme === 'dark' ? DARK : LIGHT);

function bytes(b64: string): Uint8Array {
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

export function Terminal({ job, onExit, onError }: { job: string; onExit?: (code: number) => void; onError?: (e: unknown) => void }) {
  const el = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const host = el.current;
    if (!host) return;
    const term = new XTerm({
      fontFamily: '"Cascadia Mono", "JetBrains Mono", "SF Mono", "DejaVu Sans Mono", "Noto Sans Mono CJK SC", Menlo, Consolas, monospace',
      fontSize: 13,
      lineHeight: 1.15,
      cursorBlink: true,
      scrollback: 10000,
      allowProposedApi: true,
      macOptionIsMeta: true,
      theme: theme(),
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(host);
    try {
      fit.fit();
    } catch {
      /* not laid out yet */
    }
    let pty: number | null = null;
    let dead = false;
    const offs: (() => void)[] = [];
    offs.push(
      listen<{ ptyId: number; data: string }>('pty://data', (p) => {
        if (p.ptyId === pty) term.write(bytes(p.data));
      }),
      listen<{ ptyId: number; code: number }>('pty://exit', (p) => {
        if (p.ptyId === pty) {
          pty = null;
          onExit?.(p.code);
        }
      }),
    );
    api.ptyOpen(job, term.cols, term.rows).then(
      (r) => {
        if (dead) return void api.ptyClose(r.ptyId);
        pty = r.ptyId;
        if (r.replay) term.write(bytes(r.replay));
        term.focus();
      },
      (e) => onError?.(e),
    );
    const data = term.onData((d) => pty !== null && void api.ptyWrite(pty, d));
    const size = term.onResize(({ cols, rows }) => pty !== null && void api.ptyResize(pty, cols, rows));
    const ro = new ResizeObserver(() => {
      try {
        fit.fit();
      } catch {
        /* hidden */
      }
    });
    ro.observe(host);
    const themeObs = new MutationObserver(() => (term.options.theme = theme()));
    themeObs.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    return () => {
      dead = true;
      ro.disconnect();
      themeObs.disconnect();
      data.dispose();
      size.dispose();
      offs.forEach((o) => o());
      if (pty !== null) void api.ptyClose(pty);
      term.dispose();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [job]);
  return <div className="terminal" ref={el} data-testid="terminal" />;
}
