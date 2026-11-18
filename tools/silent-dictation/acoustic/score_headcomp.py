#!/usr/bin/env python3
"""Test 3b: remove measured head motion from the sonar, then ask whether mouthing-while-nodding separates from nodding.
Head motion comes from AirPods (headmotion.csv) or, as a stand-in, camera head pose (landmarks.csv).
A ridge map from head-motion signals (with lags) to each echo bin's phase displacement is learned on head-only trials of the
other rounds and subtracted from the held-out round; scoring uses the residual.
Control: the same with head signals shifted by half a trial, which keeps their spectrum but breaks alignment.
Usage: score_headcomp.py <session> [airpods|camera]"""
import sys
from pathlib import Path
import numpy as np
from scipy import signal
sys.path.insert(0, str(Path(__file__).parent))
from sonar_io import Session, latest
from score_mouth import gate_bins, cv_auc
from explore_lipgap import displacement

LAGS = (-20, -10, 0, 10, 20)          # frames at 100 fps: covers clock offset and filter delay

def head_signals(S, source):
    n = len(S.cir())
    if source == "airpods":
        h = np.loadtxt(S.path / "headmotion.csv", delimiter=",", skiprows=1, ndmin=2)
        a = np.loadtxt(S.path / "anchors.csv", delimiter=",", skiprows=1)
        fit = np.polyfit(a[:, 1] - a[0, 1], a[:, 0], 1)               # host ns -> audio sample
        fr = np.polyval(fit, h[:, 0] - a[0, 1]) / S.hop
        cols = h[:, [11, 12, 13, 5, 6, 7, 8, 9, 10]]                  # pitch roll yaw, rotation rate, user acceleration
        cols[:, 2] = np.unwrap(cols[:, 2])
    else:
        lm = S.landmarks(); fr = S.host_to_frame()
        cols = np.c_[[lm[k] for k in ("nose_x", "nose_y", "face_x", "face_y", "face_w", "roll", "pitch")]].T
    ok = np.all(np.isfinite(cols), 1)
    H = np.c_[[np.interp(np.arange(n), fr[ok], c[ok]) for c in cols.T]].T
    H = np.c_[H, np.gradient(H, axis=0)]
    return signal.sosfiltfilt(signal.butter(2, [0.5, 12], "bp", fs=S.fps, output="sos"), H, axis=0)

def lagged(h, shift):
    if shift: h = np.roll(h, len(h) // 2, axis=0)
    return np.c_[np.c_[[np.roll(h, L, axis=0) for L in LAGS]].transpose(1, 0, 2).reshape(len(h), -1), np.ones(len(h))]

def residual_features(S, D, keep, H, shift, rounds, labels, lam=10.0):
    """Head-motion -> echo mapping learned on head-only trials (nod, shake, sway, still) of the other rounds,
    applied to the held-out round, so it cannot absorb mouthing in the trial being scored."""
    sos = signal.butter(4, [1, 12], "bp", fs=S.fps, output="sos")
    segs = [np.arange(int(t["start"] / S.hop + .3 * S.fps), int(t["end"] / S.hop)) for t in S.trials]
    dd = [signal.sosfiltfilt(sos, D[ix][:, keep], axis=0) for ix in segs]
    hh = [lagged(H[ix], shift) for ix in segs] if H is not None else None
    out = np.zeros((len(segs), 4))
    for rr in sorted(set(rounds)):
        if hh is not None:
            tr = [i for i in range(len(segs)) if rounds[i] != rr and labels[i] in ("nod", "shake", "sway", "still")]
            X = np.concatenate([hh[i] for i in tr]); Y = np.concatenate([dd[i] for i in tr])
            mu, sd = X[:, :-1].mean(0), X[:, :-1].std(0) + 1e-9
            Z = np.c_[(X[:, :-1] - mu) / sd, X[:, -1]]
            B = np.linalg.solve(Z.T @ Z + lam * len(Z) / 1000 * np.eye(Z.shape[1]), Z.T @ Y)
        for i in np.where(rounds == rr)[0]:
            d = dd[i]
            if hh is not None:
                Zi = np.c_[(hh[i][:, :-1] - mu) / sd, hh[i][:, -1]]; d = d - Zi @ B
            out[i] = np.percentile(np.log((d ** 2).mean(0) + 1e-12), [50, 75, 90, 100])
    return out

def main():
    S = Session(sys.argv[1] if len(sys.argv) > 1 else latest("headpods"))
    source = sys.argv[2] if len(sys.argv) > 2 else "airpods"
    L, R = S.windows(length=300); g = gate_bins(50, 170)
    D = np.concatenate([displacement(X[:, g], S.fps) for X in (L, R)], 1)
    mag = np.concatenate([np.abs(X[:, g]) for X in (L, R)], 1)
    keep = mag.mean(0) >= np.median(mag.mean(0))
    H = head_signals(S, source)
    n_cond = len(set(t["label"] for t in S.trials))
    rounds = np.array([t["i"] // n_cond for t in S.trials]); labels = np.array([t["label"] for t in S.trials])
    print(S.path.name, "head source:", source, "regressors:", H.shape[1] * len(LAGS))
    for name, h, shift in [("no compensation", None, False), ("head motion removed", H, False), ("control: head shifted", H, True)]:
        X = residual_features(S, D, keep, h, shift, rounds, labels)
        res = []
        for neg in ("nod", "shake", "sway"):
            m = np.isin(labels, ["mouth_plus_head", neg])
            res.append(cv_auc(X[m], (labels[m] == "mouth_plus_head").astype(int), rounds[m]))
        m = np.isin(labels, ["mouth_silent", "still"])
        res.append(cv_auc(X[m], (labels[m] == "mouth_silent").astype(int), rounds[m]))
        print(f"  {name:24s} mouth+head vs nod {res[0]:.2f}  vs shake {res[1]:.2f}  vs sway {res[2]:.2f}   silent vs still {res[3]:.2f}")

if __name__ == "__main__":
    main()
