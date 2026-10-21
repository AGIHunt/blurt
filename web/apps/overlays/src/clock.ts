import type { StatusLine } from './host';

export type HudState = 'starting' | 'recording' | 'paused' | 'saving' | 'done' | 'error';

/** The HUD's view of a take, driven only by C8 status lines (the recorder is the clock's source of truth). */
export class HudModel {
  state: HudState = 'starting';
  shots = 0;
  level = 0;
  error: string | null = null;
  private base = 0; // video seconds before the current run
  private since: number | null = null; // local ms when the current run began

  apply(line: StatusLine, now: number) {
    switch (line.ev) {
      case 'started':
        this.state = 'recording';
        this.base = 0;
        this.since = now;
        break;
      case 'level':
        this.level = Math.max(0, Math.min(1, line.rms));
        break;
      case 'paused':
        this.base = line.t ?? this.elapsed(now);
        this.since = null;
        this.state = 'paused';
        this.level = 0;
        break;
      case 'resumed':
        this.base = line.t ?? this.base;
        this.since = now;
        this.state = 'recording';
        break;
      case 'snap':
        this.shots = Math.max(this.shots, line.n);
        break;
      case 'stopped':
      case 'discarded':
        this.base = this.elapsed(now);
        this.since = null;
        this.state = 'done';
        break;
      case 'error':
        if (line.code === 'snap') break; // one still failed; the take goes on
        this.state = 'error';
        this.error = line.msg;
        this.since = null;
        break;
    }
  }

  /** The user pressed stop: wait for the recorder to join the segments. */
  stopping() {
    if (this.state === 'recording' || this.state === 'paused') this.state = 'saving';
  }

  elapsed(now: number): number {
    return this.base + (this.since === null ? 0 : (now - this.since) / 1000);
  }
}

export function fmtTime(s: number): string {
  const t = Math.max(0, Math.floor(s));
  const h = Math.floor(t / 3600);
  const mm = String(Math.floor((t % 3600) / 60)).padStart(2, '0');
  const ss = String(t % 60).padStart(2, '0');
  return h ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

/** RMS → 0..5 lit meter bars (dB scale, −50 dB … −10 dB). */
export function meterBars(rms: number, bars = 5): number {
  if (rms <= 0) return 0;
  const db = 20 * Math.log10(rms);
  return Math.max(0, Math.min(bars, Math.round(((db + 50) / 40) * bars)));
}
