#!/usr/bin/env python3
"""Exploratory, ISAR-style motion compensation with sonar only: per trial, remove the k largest
coherent motion components across echo bins (rigid head motion), then score residual motion.
Asks whether mouthing under head motion becomes separable from head motion alone."""
import sys
from pathlib import Path
import numpy as np
from scipy import signal
sys.path.insert(0, str(Path(__file__).parent))
from sonar_io import Session, latest
from score_mouth import gate_bins, cv_auc
from explore_lipgap import displacement

def features(S, D, mag, k, band):
    sos = signal.butter(4, band, "bp", fs=S.fps, output="sos")
    out = []
    for t in S.trials:
        s = int(t["start"] / S.hop + .3 * S.fps); f = int(t["end"] / S.hop)
        keep = mag[s:f].mean(0) >= np.median(mag[s:f].mean(0))           # bins that actually hold echo
        d = D[s:f][:, keep]; d = d - d.mean(0)
        if k:
            U, sv, Vt = np.linalg.svd(d, full_matrices=False)
            d = d - (U[:, :k] * sv[:k]) @ Vt[:k]
        r = signal.sosfiltfilt(sos, d, axis=0)
        v = np.log((r ** 2).mean(0) + 1e-12)
        out.append(np.percentile(v, [50, 75, 90, 100]))
    return np.array(out)

def main():
    S = Session(sys.argv[1] if len(sys.argv) > 1 else latest("head"))
    L, R = S.windows(length=300); g = gate_bins(50, 170)
    D = np.concatenate([displacement(X[:, g], S.fps) for X in (L, R)], 1)
    mag = np.concatenate([np.abs(X[:, g]) for X in (L, R)], 1)
    n_cond = len(set(t["label"] for t in S.trials))
    rounds = np.array([t["i"] // n_cond for t in S.trials]); labels = np.array([t["label"] for t in S.trials])
    print(S.path.name)
    for band in ([1, 12], [4, 12]):
        for k in (0, 1, 2, 3, 5):
            X = features(S, D, mag, k, band)
            res = []
            for pos, negs in [("mouth_plus_head", ["nod"]), ("mouth_silent", ["still"])]:
                m = np.isin(labels, [pos] + negs)
                res.append(cv_auc(X[m], (labels[m] == pos).astype(int), rounds[m]))
            print(f"  band {band} remove {k} components: mouth+nod vs nod {res[0]:.2f}   silent vs still {res[1]:.2f}")

if __name__ == "__main__":
    main()
