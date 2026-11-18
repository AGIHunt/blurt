#!/usr/bin/env python3
"""Stage 1: what do the built-in speakers and mic really do above 17 kHz. No person needed.
Runs each stimulus through duplex.bin, keeps the raw capture, prints per-band levels."""
import json, subprocess, sys, time
from pathlib import Path
import numpy as np
from scipy import signal

HERE = Path(__file__).parent
OUT = Path.home() / "Library/Application Support/Blurt VSR Pilot/acoustic/hw"

def duplex(name, stereo, fs, tail=0.3, volume=None):
    OUT.mkdir(parents=True, exist_ok=True)
    stim, cap = OUT / f"{name}.stim.f32", OUT / f"{name}.cap.f32"
    stereo.astype(np.float32).tofile(stim)
    cmd = [str(HERE / "bin/duplex"), "--rate", str(fs), "--stim", str(stim), "--out", str(cap), "--tail-seconds", str(tail)]
    if volume is not None: cmd += ["--volume", str(volume)]
    subprocess.run(cmd, check=True, capture_output=True, timeout=120)
    return np.fromfile(cap, dtype=np.float32)

def fade(x, fs, ms=30):
    n = int(fs * ms / 1000); w = 0.5 - 0.5 * np.cos(np.pi * np.arange(n) / n)
    x = x.copy(); x[:n] *= w; x[-n:] *= w[::-1]; return x

def sweep(fs, f0, f1, dur, amp):
    t = np.arange(int(fs * dur)) / fs
    return fade(amp * np.sin(2 * np.pi * (f0 * t + (f1 - f0) * t * t / (2 * dur))), fs)

def bands(x, fs, lo=14000, step=1000):
    f, p = signal.welch(x, fs, nperseg=8192, scaling="spectrum")
    r = {}
    for b in range(lo, int(fs / 2), step):
        m = (f >= b) & (f < b + step)
        r[b] = 10 * np.log10(p[m].mean() + 1e-20)
    return r

def stereo(l=None, r=None, n=None):
    n = n or len(l if l is not None else r)
    s = np.zeros((n, 2)); 
    if l is not None: s[:, 0] = l
    if r is not None: s[:, 1] = r
    return s

def main():
    res = {}
    for fs in (48000, 96000):
        sil = duplex(f"silence_{fs}", np.zeros((fs * 3, 2)), fs, tail=0)[int(fs * .3):]
        res[f"floor_{fs}"] = bands(sil, fs)
        print(f"floor {fs}: rms {20*np.log10(sil.std()+1e-12):.1f} dBFS, peak {abs(sil).max():.4f}")
    fs, amp = 96000, 0.05
    s = sweep(fs, 16500, 47000, 4, amp)
    both = duplex("sweep96_both", stereo(s, s), fs)
    time.sleep(.3)
    left = duplex("sweep96_left", stereo(l=s), fs); time.sleep(.3)
    right = duplex("sweep96_right", stereo(r=s), fs)
    for k, v in (("both", both), ("left", left), ("right", right)):
        res[f"sweep_{k}"] = bands(v, fs)
    fl = res["floor_96000"]
    print(f"\nband(kHz) floor both left right  snr_both   (dB per bin, sweep at {20*np.log10(amp):.0f} dBFS, system volume unchanged)")
    for b in fl:
        print(f"{b/1000:5.0f} {fl[b]:7.1f} {res['sweep_both'][b]:7.1f} {res['sweep_left'][b]:7.1f} {res['sweep_right'][b]:7.1f} {res['sweep_both'][b]-fl[b]:7.1f}")
    json.dump(res, open(OUT / "first_pass.json", "w"), indent=1, default=float)

if __name__ == "__main__":
    main()
