#!/usr/bin/env python3
"""Exploratory (not a preset criterion): lip gap from phase-derived displacement per echo bin.
Control uses a circular time shift inside the same trial, which keeps the cued rhythm's spectrum but breaks alignment."""
import sys
from pathlib import Path
import numpy as np
from scipy import signal
sys.path.insert(0, str(Path(__file__).parent))
from sonar_io import Session, latest
from score_mouth import Ridge, gate_bins

def displacement(X, fps):
    lp = signal.butter(2, 12, "lp", fs=fps, output="sos")
    Xs = signal.sosfiltfilt(lp, X, axis=0)
    d = np.unwrap(np.angle(Xs), axis=0) * (343 / 20250) / (4 * np.pi) * 1000   # mm of one-way path
    return signal.sosfiltfilt(signal.butter(2, 0.5, "hp", fs=fps, output="sos"), d, axis=0)

def main():
    S = Session(sys.argv[1] if len(sys.argv) > 1 else latest("mouth"))
    L, R = S.windows(length=300); g = gate_bins(50, 170)
    F = np.concatenate([displacement(X[:, g], S.fps) for X in (L, R)], 1)
    lm = S.landmarks(); vf = S.host_to_frame()
    sos = signal.butter(2, 0.5, "hp", fs=S.fps, output="sos")
    target = signal.sosfiltfilt(sos, np.interp(np.arange(len(F)), vf, lm["lip_gap"] / lm["face_w"]))
    n_cond = len(set(t["label"] for t in S.trials))
    segs = [(t["label"], t["i"] // n_cond, np.arange(int(t["start"] / S.hop + .3 * S.fps), int(t["end"] / S.hop))) for t in S.trials]
    res = {}
    for rr in sorted(set(r for _, r, _ in segs)):
        tr = np.concatenate([ix for _, r, ix in segs if r != rr])
        for lag in (0,):
            m = Ridge(300).fit(F[tr], target[tr])
        for lab, r, ix in segs:
            if r != rr: continue
            p = m.predict(F[ix]); y = target[ix]
            res.setdefault(lab, []).append(np.corrcoef(p, y)[0, 1])
            res.setdefault(lab + " (shifted)", []).append(np.corrcoef(np.roll(p, len(p) // 2 + 7), y)[0, 1])
    print(S.path.name)
    for k in sorted(res): print(f"  {k:28s} median r {np.median(res[k]):6.2f}")

if __name__ == "__main__":
    main()
