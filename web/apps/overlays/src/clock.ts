/** RMS → 0..bars lit meter bars (dB scale, −50 dB … −10 dB): the island's mic level while recording. */
export function meterBars(rms: number, bars = 5): number {
  if (rms <= 0) return 0;
  const db = 20 * Math.log10(rms);
  return Math.max(0, Math.min(bars, Math.round(((db + 50) / 40) * bars)));
}
