// The embedded terminal (contract K5; the Mac's TerminalSurface / BlurtTerminalView): xterm.js on a pty the app opens
// for an agent job — a tmux client from `sessions.py attach-cmd` (Linux), or the app runner's own ConPTY session
// (Windows; its output so far is replayed first). Keys go back with pty_write, the size with pty_resize; closing the
// view ends only the client. An app-runner session that ended shows what it left on screen, read only (Show Output).
// The look is the Mac's TerminalTheme: ink on white / the window's dark surface, ANSI tuned for both, 12.5 pt type
// (config terminal.font_size), the text 8 / 14 / 8 / 8 in from the edges in the terminal's own colour, no bell; links
// the agent prints (http, https, file) open in their apps.
import { useEffect, useRef } from 'react';
import { Terminal as XTerm, type ITheme } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';
import { api, listen } from '../api';

const hex = (n: number) => '#' + n.toString(16).padStart(6, '0');
const ansi = (list: number[]) => {
  const k = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white'] as const;
  const o: Record<string, string> = {};
  list.forEach((c, i) => (o[i < 8 ? k[i] : 'bright' + k[i - 8][0].toUpperCase() + k[i - 8].slice(1)] = hex(c)));
  return o as ITheme;
};

/** TerminalTheme.light / .dark (macOS TerminalStyle.swift), colour for colour. */
export const LIGHT: ITheme = {
  background: '#ffffff',
  foreground: '#1d1d1f',
  cursor: '#1d1d1f',
  cursorAccent: '#ffffff',
  ...ansi([0x1d1d1f, 0xc4282d, 0x1e7a3c, 0x8a6100, 0x2154c9, 0x8e3cb4, 0x0e7490, 0x6e6e73, 0x515154, 0xd93d42, 0x218358, 0xa16e00, 0x3e63dd, 0xa24fc9, 0x0f8aa8, 0x1d1d1f]),
};
export const DARK: ITheme = {
  background: '#1c1c1e',
  foreground: '#e8e8ed',
  cursor: '#f5f5f7',
  cursorAccent: '#1c1c1e',
  ...ansi([0x3a3a3c, 0xff6b6b, 0x3dd68c, 0xffc53d, 0x6e9bff, 0xd08cff, 0x5cd4e8, 0xc7c7cc, 0x636366, 0xff8a85, 0x6be6a6, 0xffd666, 0x8db2ff, 0xdda6ff, 0x84e1f0, 0xf5f5f7]),
};

const isDark = () => document.documentElement.dataset.theme === 'dark';

/** The selection: the system's accent (--focus follows it on Windows, as the Mac's follows macOS's) at 22 % light /
    36 % dark, the Mac's proportions. */
function selection(dark: boolean): string {
  const v = getComputedStyle(document.documentElement).getPropertyValue('--focus').trim();
  const m = v.match(/^#([0-9a-f]{6})$/i);
  const n = m ? parseInt(m[1], 16) : 0x0a84ff;
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${dark ? 0.36 : 0.22})`;
}

export const terminalTheme = (): ITheme => {
  const dark = isDark();
  return { ...(dark ? DARK : LIGHT), selectionBackground: selection(dark) };
};

function bytes(b64: string): Uint8Array {
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

const LINK = /\b(?:https?|file):\/\/[^\s"'<>`]+[^\s"'<>`.,;:!?)\]]/g;

export function Terminal({ job, fontSize, onAttached, onExit, onError, onEnded }: {
  job: string;
  fontSize?: number | null;
  /** the pty is up (live, or the ended session's screen replayed) */
  onAttached?: (o: { owned: boolean; ended: boolean }) => void;
  onExit?: (code: number) => void;
  onError?: (e: unknown) => void;
  /** the app-runner session has ended: what it left is shown, read only */
  onEnded?: () => void;
}) {
  const box = useRef<HTMLDivElement>(null);
  const el = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const host = el.current;
    if (!host) return;
    // the platform's monospace (Cascadia Mono on Windows, as Windows Terminal; SF Mono on the Mac), CJK after it
    const mono = getComputedStyle(document.documentElement).getPropertyValue('--mono').trim();
    const term = new XTerm({
      fontFamily: `${mono ? mono + ', ' : ''}"Cascadia Mono", "SF Mono", "DejaVu Sans Mono", "Noto Sans Mono CJK SC", Consolas, "Microsoft YaHei UI", "PingFang SC", monospace`,
      fontSize: fontSize ?? 12.5,
      lineHeight: 1.15,
      cursorBlink: true,
      scrollback: 10000,
      allowProposedApi: true,
      macOptionIsMeta: true,
      theme: terminalTheme(),
      // an agent drawing its dark-theme colours on the light terminal (Claude Code's pale selected answer, its faint
      // diff context) stays readable: xterm lifts any foreground under 4.5:1 against its cell's background
      minimumContrastRatio: 4.5,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(host);
    const paint = () => box.current?.style.setProperty('--term-bg', String(terminalTheme().background));
    paint();
    // links the agent prints open in their apps — http(s) and file only
    const links = term.registerLinkProvider({
      provideLinks(y, done) {
        const line = term.buffer.active.getLine(y - 1)?.translateToString(true) ?? '';
        const out = [...line.matchAll(LINK)].map((m) => ({
          range: { start: { x: (m.index ?? 0) + 1, y }, end: { x: (m.index ?? 0) + m[0].length, y } },
          text: m[0],
          activate: () => void api.openUrl(m[0]).catch(() => {}),
        }));
        done(out.length ? out : undefined);
      },
    });
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
        if (dead) return void (r.ptyId != null && api.ptyClose(r.ptyId));
        if (r.replay) term.write(bytes(r.replay));
        if (r.ptyId == null || r.ended) {
          term.options.disableStdin = true;
          term.options.cursorBlink = false;
          onAttached?.({ owned: r.owned, ended: true });
          onEnded?.();
          return;
        }
        pty = r.ptyId;
        // tmux keeps the scrollback (the mouse scrolls it): no still track at the edge
        if (!r.owned) box.current?.classList.add('no-scroller');
        onAttached?.({ owned: r.owned, ended: false });
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
    const themeObs = new MutationObserver(() => {
      term.options.theme = terminalTheme();
      paint();
    });
    themeObs.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    return () => {
      dead = true;
      ro.disconnect();
      themeObs.disconnect();
      links.dispose();
      data.dispose();
      size.dispose();
      offs.forEach((o) => o());
      if (pty !== null) void api.ptyClose(pty);
      term.dispose();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [job]);
  return (
    <div className="term-box" ref={box}>
      <div className="terminal" ref={el} data-testid="terminal" />
    </div>
  );
}
