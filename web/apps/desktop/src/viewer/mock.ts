// In-browser stand-in for src-tauri/src/viewer.rs (vite dev, screenshots, unit tests): three paired computers and one found
// on the network, pairing with digits after a moment, and a computer's window with a made-up desktop that is really encoded
// (WebCodecs VideoEncoder, H.264 Annex B) and sent through the same frames the app sends, so the window's decoding runs as in
// the app. URL parameters:
//   ?computers= none | some (default) | nodirect | removed   the list: none, or Connected / Available (nodirect: Needs its own relay;
//                                                           removed: Removed this computer) / Offline rows
//   ?computers_pairing= connecting | asking | failed        Add Computer… already pairing
//   &computers_error= declined (default) | unanswered | spent | unreachable   &computers_link=1 (begun from a link)
//   ?viewer=<id>&viewer_state= connected (default) | connecting | offline | busy | noDirect | removed | replaced | noControl
//   &viewer_route= local | direct | relay | goBetween | tailscale   &viewer_displays=2   &viewer_host= mac | windows | linux
//   &viewer_captured=1 (keys captured, the hint showing)
import { packFrame } from './decode';
import type { ComputersStatus } from './computers';

type Emit = (event: string, p: unknown) => void;
const param = (k: string) => (typeof location === 'undefined' ? null : new URLSearchParams(location.search).get(k));
const zh = () => (param('lang') ?? (typeof navigator === 'undefined' ? '' : navigator.language)).startsWith('zh');
const L = (en: string, cn: string) => (zh() ? cn : en);

const hour = 3600_000;
const state: ComputersStatus = {
  computers:
    param('computers') === 'none'
      ? []
      : [
          { id: 'studio', name: 'Studio Mac mini', platform: 'mac', state: 'connected', key: true, route: 'local', lastSeen: Date.now(), windows: 1 },
          {
            id: 'den',
            name: L('Den PC', '书房电脑'),
            platform: 'windows',
            key: param('computers') !== 'removed',
            ...(param('computers') === 'nodirect'
              ? { state: 'noDirect' as const, route: null }
              : param('computers') === 'removed'
                ? { state: 'removed' as const, route: null }
                : { state: 'available' as const, route: 'goBetween' as const }),
            lastSeen: Date.now() - 2 * hour,
            windows: 0,
          },
          { id: 'lab', name: 'ubuntu-lab', platform: 'linux', state: 'offline', key: true, route: null, lastSeen: Date.now() - 3 * 24 * hour, windows: 0 },
        ],
  nearby: [{ id: 'office', name: L('Office ThinkPad', '办公室 ThinkPad') }],
  pairing: null,
  browsing: false,
  addRequests: 0,
  paired: 0,
};
const p0 = param('computers_pairing');
if (p0 === 'connecting' || p0 === 'asking' || p0 === 'failed')
  state.pairing = {
    name: L('Office ThinkPad', '办公室 ThinkPad'),
    state: p0,
    digits: p0 === 'asking' ? '204718' : null,
    error: p0 === 'failed' ? ((param('computers_error') as 'declined' | 'unanswered' | 'spent' | 'unreachable' | null) ?? 'declined') : null,
    link: param('computers_link') === '1',
  };
let last: Record<string, any> = {};

let timers: ReturnType<typeof setTimeout>[] = [];
const now = () => JSON.parse(JSON.stringify(state)) as ComputersStatus;

export function mockComputers(cmd: string, a: Record<string, any>, emit: Emit): unknown {
  const changed = () => emit('computers://status', now());
  const later = (ms: number, f: () => void) => timers.push(setTimeout(() => (f(), changed()), ms));
  switch (cmd) {
    case 'computers_browse':
      state.browsing = !!a.on;
      break;
    case 'computers_retry_pairing':
      return mockComputers('computers_pair', last, emit);
    case 'computers_add_again':
      state.addRequests += 1;
      break;
    case 'computers_pair': {
      last = a;
      timers.forEach(clearTimeout);
      timers = [];
      const link = a.link as string | null;
      const name = a.nearby ? state.nearby.find((n) => n.id === a.nearby)?.name ?? '' : L('Den PC', '书房电脑');
      if (link != null && !/^blurtremote:\/\/pair\?/.test(link)) {
        state.pairing = { name: '', state: 'failed', digits: null, error: 'invalid', link: true };
        break;
      }
      state.pairing = { name, state: 'connecting', digits: null, error: null, link: link != null };
      later(1200, () => state.pairing && (state.pairing = { ...state.pairing, state: 'asking', digits: String(100000 + Math.floor(Math.random() * 900000)) }));
      // the owner there says yes a few seconds later
      later(7000, () => {
        if (!state.pairing) return;
        state.pairing = null;
        const id = a.nearby ?? `pc-${Date.now()}`;
        state.nearby = state.nearby.filter((n) => n.id !== id);
        state.computers = [...state.computers.filter((c) => c.id !== id), { id, name, platform: 'windows', state: 'connected', key: true, route: 'local', lastSeen: Date.now(), windows: 1 }];
        state.paired += 1;
      });
      break;
    }
    case 'computers_cancel_pairing':
      timers.forEach(clearTimeout);
      timers = [];
      state.pairing = null;
      break;
    case 'computers_rename': {
      const c = state.computers.find((x) => x.id === a.id);
      if (!c) break;
      const own = c.ownName ?? c.name;
      c.ownName = own;
      c.name = String(a.name ?? '').trim().slice(0, 64) || own;
      break;
    }
    case 'computers_remove':
      state.computers = state.computers.filter((c) => c.id !== a.id);
      break;
    case 'computers_open': {
      const c = state.computers.find((x) => x.id === a.id);
      if (c) {
        c.windows = Math.max(1, c.windows);
        if (c.state !== 'connected') later(800, () => ((c.state = 'connected'), (c.route = c.route ?? 'local')));
        // a browser can't open the app's window: the same page, as a computer's window
        if (typeof window !== 'undefined') window.open(`${location.pathname}?viewer=${encodeURIComponent(c.id)}&lang=${param('lang') ?? ''}`, '_blank');
      }
      break;
    }
    default:
      return mockViewer(cmd, a);
  }
  changed();
  return now();
}

// ------------------------------------------------------------------ a computer's window

type Out = { onmessage: (m: unknown) => void };
let out: Out | null = null;
let enc: { stop: () => void; key: () => void } | null = null;
const host = () => (param('viewer_host') as 'mac' | 'windows' | 'linux' | null) ?? 'mac';
const vname = () => (({ mac: 'Studio Mac mini', windows: L('Den PC', '书房电脑'), linux: 'ubuntu-lab' }) as const)[host()];

function mockViewer(cmd: string, a: Record<string, any>): unknown {
  switch (cmd) {
    case 'viewer_attach': {
      out = a.channel as Out;
      const st = param('viewer_state') ?? 'connected';
      const send = (m: unknown) => out?.onmessage(m);
      send({ type: 'link', link: 'connecting', route: null });
      if (st !== 'connecting') {
        setTimeout(() => {
          if (st === 'noControl' || st === 'connected') {
            send({ type: 'link', link: 'connected', route: param('viewer_route') ?? 'local' });
            send({ type: 'session', name: vname(), platform: host(), canControl: st !== 'noControl' });
            send({ type: 'rtt', ms: param('viewer_route') === 'goBetween' || param('viewer_route') === 'direct' ? 46 : 3 });
            const two = param('viewer_displays') === '2';
            const displays = [
              { id: 'D1', name: host() === 'mac' ? 'Studio Display' : 'DELL U2723QE', x: 0, y: 0, width: 2560, height: 1440, main: true },
              { id: 'D2', name: 'LG HDR 4K', x: 2560, y: -200, width: 1920, height: 1080, main: false },
            ];
            send({ type: 'displays', displays: two ? displays : displays.slice(0, 1) });
            send({ type: 'view', width: 2560, height: 1440, family: 'h264', display: 'D1' });
          } else send({ type: 'link', link: st, route: null });
        }, 400);
      }
      return { id: a.id ?? param('viewer'), name: vname(), platform: host(), options: { mapped: true, clipboard: true }, systemShortcuts: param('viewer_os') === 'linux' ? 'local' : 'all', os: param('viewer_os') ?? 'windows' };
    }
    case 'viewer_screen':
      enc?.stop();
      enc = a.on ? encodeDesktop(Math.min(a.width, 2560), Math.min(a.height, 1600)) : null;
      return null;
    case 'viewer_pointer':
      out?.onmessage({ type: 'cursor', x: a.x, y: a.y });
      return null;
    case 'viewer_decode_failed':
      enc?.key();
      return null;
    case 'viewer_key':
      return false;
    case 'viewer_options':
      return { mapped: a.mapped, clipboard: a.clipboard };
    case 'viewer_show_display':
      out?.onmessage({ type: 'view', width: a.id === 'D2' ? 1920 : 2560, height: a.id === 'D2' ? 1080 : 1440, family: 'h264', display: a.id ?? 'D1' });
      enc?.key();
      return null;
  }
  return null;
}

/** A made-up desktop of `host()`'s kind, drawn and encoded 30 times a second into the window's channel. */
function encodeDesktop(boxW: number, boxH: number): { stop: () => void; key: () => void } | null {
  const VE = (globalThis as { VideoEncoder?: typeof VideoEncoder }).VideoEncoder;
  if (!VE || typeof OffscreenCanvas === 'undefined') return null;
  // the display's shape (16:9) inside the window's box, even numbers
  const k = Math.min(boxW / 16, boxH / 9);
  const w = Math.max(320, Math.floor((16 * k) / 2) * 2);
  const h = Math.max(180, Math.floor((9 * k) / 2) * 2);
  const c = new OffscreenCanvas(w, h);
  const g = c.getContext('2d')!;
  let id = 0;
  let wantKey = true;
  let codec = '';
  const e = new VE({
    output: (chunk, meta) => {
      if (meta?.decoderConfig?.codec) codec = meta.decoderConfig.codec;
      const data = new Uint8Array(chunk.byteLength);
      chunk.copyTo(data);
      out?.onmessage(packFrame({ id: ++id, key: chunk.type === 'key', codec, data }));
    },
    error: () => {},
  });
  e.configure({ codec: 'avc1.640033', width: w, height: h, bitrate: 6_000_000, framerate: 30, latencyMode: 'realtime', avc: { format: 'annexb' } } as VideoEncoderConfig);
  let n = 0;
  const tick = setInterval(() => {
    drawDesktop(g, w, h, n++);
    const f = new VideoFrame(c, { timestamp: n * 33_333 });
    e.encode(f, { keyFrame: wantKey || n % 120 === 0 });
    wantKey = false;
    f.close();
  }, 33);
  return {
    stop: () => {
      clearInterval(tick);
      try {
        e.close();
      } catch {
        /* closed */
      }
    },
    key: () => (wantKey = true),
  };
}

function drawDesktop(g: OffscreenCanvasRenderingContext2D, w: number, h: number, n: number) {
  const s = w / 1600;
  const mac = host() === 'mac';
  const grad = g.createLinearGradient(0, 0, w, h);
  grad.addColorStop(0, mac ? '#3a4d7a' : '#1b4f8a');
  grad.addColorStop(1, mac ? '#b06a8a' : '#2f8fb5');
  g.fillStyle = grad;
  g.fillRect(0, 0, w, h);
  const font = (px: number, weight = 400) => (g.font = `${weight} ${px * s}px -apple-system, "Segoe UI", system-ui, sans-serif`);
  const mono = (px: number) => (g.font = `${px * s}px "SF Mono", Consolas, ui-monospace, monospace`);
  // the system's bar
  if (mac) {
    g.fillStyle = 'rgba(255,255,255,0.72)';
    g.fillRect(0, 0, w, 26 * s);
    g.fillStyle = '#111';
    font(13, 600);
    g.fillText('Code', 40 * s, 18 * s);
    font(13);
    ['File', 'Edit', 'Selection', 'View', 'Go', 'Run', 'Terminal', 'Window', 'Help'].forEach((m, i) => g.fillText(m, (90 + i * 62) * s, 18 * s));
    g.fillText('Thu 10:42', w - 90 * s, 18 * s);
  } else {
    g.fillStyle = 'rgba(32,32,32,0.86)';
    g.fillRect(0, h - 44 * s, w, 44 * s);
    for (let i = 0; i < 6; i++) {
      g.fillStyle = i === 2 ? 'rgba(255,255,255,0.22)' : 'rgba(255,255,255,0.08)';
      g.fillRect(w / 2 - 150 * s + i * 52 * s, h - 38 * s, 40 * s, 32 * s);
    }
    g.fillStyle = '#fff';
    font(12);
    g.fillText('10:42', w - 70 * s, h - 18 * s);
  }
  // an editor
  const ex = 70 * s, ey = (mac ? 70 : 40) * s, ew = 900 * s, eh = 620 * s;
  g.fillStyle = 'rgba(0,0,0,0.35)';
  g.fillRect(ex + 6 * s, ey + 10 * s, ew, eh);
  g.fillStyle = '#1f2329';
  g.fillRect(ex, ey, ew, eh);
  g.fillStyle = '#2b3038';
  g.fillRect(ex, ey, ew, 34 * s);
  g.fillStyle = '#c9d1d9';
  font(13);
  g.fillText('checkout.ts — web-shop', ex + ew / 2 - 80 * s, ey + 22 * s);
  const code = [
    ['#c678dd', 'export async function '], ['#61afef', 'placeOrder'], ['#c9d1d9', '(cart: Cart) {'],
  ];
  mono(14);
  const lines: [string, string][][] = [
    code as [string, string][],
    [['#c678dd', '  const '], ['#c9d1d9', 'total = cart.items.reduce((sum, i) => sum + i.price * i.qty, 0);']],
    [['#c678dd', '  if '], ['#c9d1d9', '(total <= 0) '], ['#c678dd', 'throw new '], ['#e5c07b', 'Error'], ['#98c379', "('Empty cart')"], ['#c9d1d9', ';']],
    [['#c678dd', '  const '], ['#c9d1d9', 'res = '], ['#c678dd', 'await '], ['#61afef', 'fetch'], ['#98c379', "('/api/orders'"], ['#c9d1d9', ', {']],
    [['#c9d1d9', "    method: "], ['#98c379', "'POST'"], ['#c9d1d9', ',']],
    [['#c9d1d9', '    body: JSON.'], ['#61afef', 'stringify'], ['#c9d1d9', '({ items: cart.items, total }),']],
    [['#c9d1d9', '  });']],
    [['#7f848e', '  // Safari: the button stays disabled until the response is read']],
    [['#c678dd', '  return '], ['#c9d1d9', 'res.'], ['#61afef', 'json'], ['#c9d1d9', '();']],
    [['#c9d1d9', '}']],
  ];
  lines.forEach((parts, i) => {
    let x = ex + 56 * s;
    const y = ey + (70 + i * 26) * s;
    g.fillStyle = '#5c6370';
    g.fillText(String(i + 12), ex + 16 * s, y);
    for (const [col, t] of parts) {
      g.fillStyle = col;
      g.fillText(t, x, y);
      x += g.measureText(t).width;
    }
  });
  if (Math.floor(n / 15) % 2 === 0) {
    g.fillStyle = '#e6e6e6';
    g.fillRect(ex + 56 * s + 330 * s, ey + (70 + 6 * 26 - 14) * s, 2 * s, 18 * s);
  }
  // a chat
  const cx = 1010 * s, cy = (mac ? 120 : 90) * s, cw = 520 * s, ch = 560 * s;
  g.fillStyle = 'rgba(0,0,0,0.3)';
  g.fillRect(cx + 6 * s, cy + 10 * s, cw, ch);
  g.fillStyle = '#ffffff';
  g.fillRect(cx, cy, cw, ch);
  g.fillStyle = '#4a154b';
  g.fillRect(cx, cy, cw, 44 * s);
  g.fillStyle = '#fff';
  font(15, 600);
  g.fillText('# checkout-team', cx + 18 * s, cy + 28 * s);
  const msgs = [
    ['Anna', L('Is the Safari fix in today’s build?', 'Safari 的修复进今天的构建了吗？')],
    ['Leo', L('Testing it on the Studio now.', '我正在 Studio 上测试。')],
    ['Anna', L('Great, ping me when the order goes through.', '好，下单成功了告诉我。')],
  ];
  msgs.forEach(([who, text], i) => {
    const y = cy + (90 + i * 74) * s;
    g.fillStyle = ['#e8912d', '#2eb67d', '#e8912d'][i];
    g.fillRect(cx + 18 * s, y - 16 * s, 34 * s, 34 * s);
    g.fillStyle = '#1d1c1d';
    font(14, 700);
    g.fillText(who, cx + 64 * s, y - 2 * s);
    font(14);
    g.fillText(text, cx + 64 * s, y + 18 * s);
  });
}
