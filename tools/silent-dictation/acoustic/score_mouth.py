#!/usr/bin/env python3
"""Test 2 criteria beyond energy: (a) silent mouthing vs blink/brow and breath with a cross-validated classifier,
(b) does sonar predict held-out lip gap from the camera. Usage: score_mouth.py [session]"""
import sys
from pathlib import Path
import numpy as np
from scipy import signal
sys.path.insert(0, str(Path(__file__).parent))
from sonar_io import Session, latest
from analyze import auc, BEFORE

def gate_bins(lo=30, hi=170): return np.arange(BEFORE + int(lo / 100 / 343 * 48000), BEFORE + int(hi / 100 / 343 * 48000))

def trial_features(S, L, R):
    """Per trial: log energy per 7 cm gate per speaker in 1-4 Hz and 4-12 Hz, plus inward/outward Doppler balance."""
    g = gate_bins(); out = []
    bands = [signal.butter(4, b, "bp", fs=S.fps, output="sos") for b in ([1, 4], [4, 12])]
    filt = [[signal.sosfiltfilt(sos, X[:, g], axis=0) for sos in bands] for X in (L, R)]
    for t in S.trials:
        s = int(t["start"] / S.hop + .3 * S.fps); f = int(t["end"] / S.hop)
        v = []
        for per_tx in filt:
            for b in per_tx:
                e = (np.abs(b[s:f]) ** 2).mean(0)
                v += list(10 * np.log10(e[: len(e) // 10 * 10].reshape(-1, 10).sum(1) + 1e-20))
            # sign of phase rotation: approaching vs receding reflectors
            ph = np.angle(per_tx[0][s + 1:f] * np.conj(per_tx[0][s:f - 1]))
            w = np.abs(per_tx[0][s:f - 1]) ** 2
            v.append((ph * w).sum() / w.sum())
        out.append(v)
    return np.array(out)

def logreg(X, y, lam=3.0, iters=60):
    """L2 logistic regression by Newton steps on standardized features; returns a predict function."""
    mu, sd = X.mean(0), X.std(0) + 1e-9; Z = np.c_[(X - mu) / sd, np.ones(len(X))]
    w = np.zeros(Z.shape[1]); R = lam * np.eye(Z.shape[1]); R[-1, -1] = 0
    for _ in range(iters):
        p = 1 / (1 + np.exp(-Z @ w)); g = Z.T @ (p - y) + R @ w
        H = (Z * (p * (1 - p))[:, None]).T @ Z + R; w -= np.linalg.solve(H, g)
    return lambda Xn: 1 / (1 + np.exp(-np.c_[(Xn - mu) / sd, np.ones(len(Xn))] @ w))

class Ridge:
    def __init__(self, alpha): self.a = alpha
    def fit(self, X, y):
        self.mu, self.sd, self.ym = X.mean(0), X.std(0) + 1e-9, y.mean(); Z = (X - self.mu) / self.sd
        self.w = np.linalg.solve(Z.T @ Z + self.a * np.eye(Z.shape[1]), Z.T @ (y - self.ym)); return self
    def predict(self, X): return (X - self.mu) / self.sd @ self.w + self.ym

def cv_auc(X, y, groups):
    p = np.zeros(len(y))
    for g in np.unique(groups):
        tr, te = groups != g, groups == g
        if len(np.unique(y[tr])) < 2: continue
        p[te] = logreg(X[tr], y[tr])(X[te])
    return auc(p[y == 1], p[y == 0])

def lip_gap_test(S, L, R, lm, vf, rounds):
    """Ridge from sonar echo change to lip gap (relative to face width), trained on other rounds."""
    g = gate_bins(50, 170)
    sos = signal.butter(2, 0.5, "hp", fs=S.fps, output="sos")
    F = np.concatenate([np.log10(np.abs(signal.sosfiltfilt(sos, X[:, g], axis=0)) + 1e-9) for X in (L, R)], 1)
    F = signal.sosfiltfilt(signal.butter(2, 8, "lp", fs=S.fps, output="sos"), F, axis=0)
    gap = lm["lip_gap"] / lm["face_w"]
    target = np.interp(np.arange(len(F)), vf, gap)
    target = signal.sosfiltfilt(sos, target)
    segs = []
    for t, r in zip(S.trials, rounds):
        s = int(t["start"] / S.hop + .3 * S.fps); f = int(t["end"] / S.hop)
        segs.append((t["label"], r, np.arange(s, f)))
    res = {}
    for rr in np.unique(rounds):
        tr = np.concatenate([ix for _, r, ix in segs if r != rr]); m = Ridge(alpha=30).fit(F[tr], target[tr])
        mu, sd = F[tr].mean(0), F[tr].std(0) + 1e-9
        for i, (lab, r, ix) in enumerate(segs):
            if r != rr or not lab.startswith("mouth"): continue
            pred = m.predict(F[ix])
            res.setdefault(lab, []).append(np.corrcoef(pred, target[ix])[0, 1])
            # control: this trial's prediction scored against another mouth trial's lip gap of the same label
            others = [o for j, o in enumerate(segs) if o[0] == lab and j != i]
            o = others[i % len(others)][2]; n = min(len(o), len(ix))
            res.setdefault(lab + " (mismatched)", []).append(np.corrcoef(pred[:n], target[o[:n]])[0, 1])
    return res

def main():
    S = Session(sys.argv[1] if len(sys.argv) > 1 else latest("mouth"))
    L, R = S.windows(length=300)
    n_cond = len(set(t["label"] for t in S.trials))
    rounds = np.array([t["i"] // n_cond for t in S.trials])
    labels = np.array([t["label"] for t in S.trials])
    X = trial_features(S, L, R)
    print(S.path.name, "trials", len(labels), "features", X.shape[1])
    for pos, negs in [("mouth_silent", ["blink_brow", "breath"]), ("mouth_silent", ["blink_brow"]), ("mouth_silent", ["breath"]),
                      ("mouth_silent", ["still"]), ("mouth_big", ["blink_brow", "breath", "still"]), ("mouth_small", ["blink_brow", "breath", "still"])]:
        m = np.isin(labels, [pos] + negs)
        print(f"  CV AUC {pos} vs {'+'.join(negs):26s} {cv_auc(X[m], (labels[m] == pos).astype(int), rounds[m]):.3f}")
    lm = S.landmarks(); vf = S.host_to_frame()
    print("held-out lip gap prediction, median r per trial (n):")
    for k, v in lip_gap_test(S, L, R, lm, vf, rounds).items():
        print(f"  {k:30s} {np.median(v):6.2f}  ({len(v)})")

if __name__ == "__main__":
    main()
