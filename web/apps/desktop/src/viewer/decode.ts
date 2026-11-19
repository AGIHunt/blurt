// The picture in a computer's window (docs/design/remote-desktop-viewer.md §Picture): frames from the host, Annex B with the
// codec string from their parameter sets (src-tauri viewer.rs), decoded by the webview's WebCodecs VideoDecoder and drawn
// onto a canvas. WebView2 (Windows) has it; WebKitGTK (Linux) has it from 2.46 on, depending on the GStreamer plugins
// installed; `decodable` asks the webview what it decodes and the request names only those. A decoder error makes a new
// decoder and asks the host for a keyframe.

/** The codecs this webview decodes, best first, as the request names them ("hevc", "h264"). Empty: none (a native decoder). */
export async function decodable(): Promise<string[]> {
  const VD = (globalThis as { VideoDecoder?: typeof VideoDecoder }).VideoDecoder;
  if (!VD?.isConfigSupported) return [];
  const out: string[] = [];
  const tries: [string, string[]][] = [
    ['hevc', ['hev1.1.6.L120.90', 'hev1.1.6.L153.90']],
    ['h264', ['avc1.640028', 'avc1.42E01F']],
  ];
  for (const [family, codecs] of tries) {
    for (const codec of codecs) {
      try {
        const r = await VD.isConfigSupported({ codec, optimizeForLatency: true });
        if (r.supported) {
          out.push(family);
          break;
        }
      } catch {
        /* this webview doesn't know the string */
      }
    }
  }
  return out;
}

/** One frame off the channel: 1, flags (bit 0 keyframe), u32 LE id, the codec string's length and bytes, then Annex B. */
export interface Frame {
  id: number;
  key: boolean;
  codec: string;
  data: Uint8Array;
}

export function parseFrame(buf: ArrayBuffer): Frame | null {
  const b = new Uint8Array(buf);
  if (b.length < 7 || b[0] !== 1) return null;
  const id = b[2] | (b[3] << 8) | (b[4] << 16) | (b[5] << 24);
  const n = b[6];
  if (b.length < 7 + n) return null;
  const codec = new TextDecoder().decode(b.subarray(7, 7 + n));
  return { id: id >>> 0, key: (b[1] & 1) === 1, codec, data: b.subarray(7 + n) };
}

/** Builds a frame as the app sends it (the mock, tests). */
export function packFrame(f: Frame): ArrayBuffer {
  const c = new TextEncoder().encode(f.codec);
  const b = new Uint8Array(7 + c.length + f.data.length);
  b[0] = 1;
  b[1] = f.key ? 1 : 0;
  b[2] = f.id & 255;
  b[3] = (f.id >>> 8) & 255;
  b[4] = (f.id >>> 16) & 255;
  b[5] = (f.id >>> 24) & 255;
  b[6] = c.length;
  b.set(c, 7);
  b.set(f.data, 7 + c.length);
  return b.buffer;
}

export interface PictureStats {
  decoded: number;
  dropped: number;
  errors: number;
  /** what decoded it: 'webcodecs' (hardware or not, the webview's choice) */
  decoder: string;
  width: number;
  height: number;
}

/** A decoder drawing onto a canvas. `failed`: a frame couldn't be decoded, a keyframe is needed. */
export class Picture {
  private dec: VideoDecoder | null = null;
  private codec = '';
  private waitKey = true;
  private ts = 0;
  readonly stats: PictureStats = { decoded: 0, dropped: 0, errors: 0, decoder: 'webcodecs', width: 0, height: 0 };

  constructor(
    private canvas: HTMLCanvasElement,
    private failed: () => void,
    private drawn: (w: number, h: number) => void = () => {},
  ) {}

  private make(codec: string) {
    this.close();
    const ctx = this.canvas.getContext('2d', { alpha: false, desynchronized: true } as CanvasRenderingContext2DSettings);
    this.dec = new VideoDecoder({
      output: (f) => {
        const w = f.displayWidth;
        const h = f.displayHeight;
        if (this.canvas.width !== w || this.canvas.height !== h) {
          this.canvas.width = w;
          this.canvas.height = h;
        }
        ctx?.drawImage(f, 0, 0, w, h);
        f.close();
        this.stats.decoded++;
        this.stats.width = w;
        this.stats.height = h;
        this.drawn(w, h);
      },
      error: () => {
        this.stats.errors++;
        this.dec = null; // a closed decoder: the next keyframe makes a new one
        this.codec = '';
        this.waitKey = true;
        this.failed();
      },
    });
    this.dec.configure({ codec, optimizeForLatency: true, hardwareAcceleration: 'no-preference' });
    this.codec = codec;
  }

  frame(f: Frame) {
    if (f.key && (f.codec !== this.codec || !this.dec || this.dec.state === 'closed')) {
      try {
        this.make(f.codec);
      } catch {
        this.stats.errors++;
        this.failed();
        return;
      }
    }
    if (!this.dec || this.dec.state !== 'configured') return;
    if (this.waitKey && !f.key) {
      this.stats.dropped++;
      return;
    }
    this.waitKey = false;
    // a decoder falling behind (a slow machine): drop to the next keyframe rather than show the past late
    if (this.dec.decodeQueueSize > 8 && !f.key) {
      this.stats.dropped++;
      return;
    }
    this.ts += 16_667;
    try {
      this.dec.decode(new EncodedVideoChunk({ type: f.key ? 'key' : 'delta', timestamp: this.ts, data: f.data }));
    } catch {
      this.stats.errors++;
      this.waitKey = true;
      this.failed();
    }
  }

  close() {
    try {
      if (this.dec && this.dec.state !== 'closed') this.dec.close();
    } catch {
      /* already gone */
    }
    this.dec = null;
    this.codec = '';
    this.waitKey = true;
  }
}

/** Where a picture of w × h shows inside a box (object-fit: contain): the drawn rectangle, in the box's pixels. */
export function contained(boxW: number, boxH: number, w: number, h: number): { x: number; y: number; w: number; h: number } {
  if (!w || !h || !boxW || !boxH) return { x: 0, y: 0, w: boxW, h: boxH };
  const k = Math.min(boxW / w, boxH / h);
  const dw = w * k;
  const dh = h * k;
  return { x: (boxW - dw) / 2, y: (boxH - dh) / 2, w: dw, h: dh };
}

/** A point in the box → 0…1 of the picture, or null outside it. */
export function toPicture(px: number, py: number, r: { x: number; y: number; w: number; h: number }): { x: number; y: number } | null {
  const x = (px - r.x) / r.w;
  const y = (py - r.y) / r.h;
  return x < 0 || y < 0 || x > 1 || y > 1 ? null : { x, y };
}

/** A wheel event in points, the content's direction (positive dy: the content moves down, as the host's scroll takes it). */
export function wheelPoints(e: { deltaX: number; deltaY: number; deltaMode: number }, pageH: number): { dx: number; dy: number } {
  const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? pageH : 1;
  return { dx: -e.deltaX * k, dy: -e.deltaY * k };
}
