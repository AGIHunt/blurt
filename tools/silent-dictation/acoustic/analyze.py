#!/usr/bin/env python3
"""Scores one block against the criteria set in docs/design/silent-dictation-acoustic.md.
Usage: analyze.py <block-or-folder>"""
import sys
from pathlib import Path
import numpy as np
from scipy import signal
sys.path.insert(0, str(Path(__file__).parent))
from sonar_io import Session, latest, C

BEFORE = 20
def cm(s, fs=48000): return s / fs * C * 100
def gate(lo=30, hi=170, fs=48000): return BEFORE + int(lo / 100 / C * fs), BEFORE + int(hi / 100 / C * fs)

def bandpass(h, fps, lo=1.0, hi=14.0):
    sos = signal.butter(4, [lo, hi], "bp", fs=fps, output="sos")
    return signal.sosfiltfilt(sos, h, axis=0)

def auc(a, b):
    a, b = np.asarray(a), np.asarray(b)
    return ((a[:, None] > b[None, :]).mean() + .5 * (a[:, None] == b[None, :]).mean())

def trial_energy(S, b, skip=.3):
    lo, hi = gate(); out = []
    e = (np.abs(b[:, lo:hi]) ** 2).sum(1)
    for t in S.trials:
        s = int(t["start"] / S.hop + skip * S.fps); f = int(t["end"] / S.hop)
        out.append(10 * np.log10(np.median(e[s:f]) + 1e-20))
    return np.array(out)

def rate_lock(S, b):
    """How strongly the strongest echo bin moves at the cued rate, against neighbouring frequencies."""
    lo, hi = gate(); res = {}
    for t in S.trials:
        if not t.get("rate"): continue
        s = int(t["start"] / S.hop + .3 * S.fps); f = int(t["end"] / S.hop)
        seg = b[s:f, lo:hi]
        k = np.argmax((np.abs(seg) ** 2).sum(0))
        x = np.diff(np.unwrap(np.angle(seg[:, k] + 1e-12)))
        P = np.abs(np.fft.rfft(x * np.hanning(len(x)), 4096)) ** 2; fr = np.fft.rfftfreq(4096, 1 / S.fps)
        c = np.argmin(abs(fr - t["rate"])); near = (abs(fr - t["rate"]) > .5) & (abs(fr - t["rate"]) < 3)
        res.setdefault(t["label"], []).append(10 * np.log10(P[max(c - 3, 0):c + 4].mean() / P[near].mean()))
    return res

def main():
    arg = sys.argv[1]
    S = Session(arg if Path(arg).exists() else latest(arg))
    print(S.path.name, {k: S.meta[k] for k in ("samples", "gaps", "frames_written", "frames_dropped", "trials_done", "trials_total")})
    L, R = S.windows()
    print(f"direct left {20*np.log10(np.abs(L[:, BEFORE]).mean()):.1f} dB")
    bL, bR = bandpass(L, S.fps), bandpass(R, S.fps)
    labels = np.array([t["label"] for t in S.trials])
    for name, b in (("left", bL), ("right", bR), ("sum", None)):
        e = trial_energy(S, b) if b is not None else 10 * np.log10(10 ** (trial_energy(S, bL) / 10) + 10 ** (trial_energy(S, bR) / 10))
        print(f"\n{name}: motion energy in 30-170 cm extra path, dB (median, AUC against still)")
        still = e[np.char.endswith(labels, "still")]
        for l in dict.fromkeys(labels):
            v = e[labels == l]
            print(f"  {l:16s} n={len(v):3d} {np.median(v):7.1f}   AUC {auc(v, still):.3f}")
    for name, b in (("left", bL), ("right", bR)):
        print(f"\n{name}: cued-rate peak over neighbours, dB")
        for l, v in rate_lock(S, b).items(): print(f"  {l:16s} {np.median(v):6.1f}")

if __name__ == "__main__":
    main()
