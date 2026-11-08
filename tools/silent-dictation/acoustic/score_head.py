#!/usr/bin/env python3
"""Block 3 (mouth vs head) preset scoring: leave-one-round-out CV AUC with the block 2 feature set."""
import sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).parent))
from sonar_io import Session, latest
from score_mouth import trial_features, cv_auc

TESTS = [("mouth_silent", ["nod", "shake", "sway"], 0.85), ("mouth_silent", ["nod"], None), ("mouth_silent", ["shake"], None),
         ("mouth_silent", ["sway"], None), ("mouth_silent", ["still"], None), ("mouth_plus_head", ["nod"], 0.75)]

def score(X, labels, rounds, keep):
    out = []
    for pos, negs, bar in TESTS:
        m = keep & np.isin(labels, [pos] + negs)
        out.append((pos, negs, bar, cv_auc(X[m], (labels[m] == pos).astype(int), rounds[m])))
    return out

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    drop = [int(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--drop=")]
    S = Session(args[0] if args else latest("head"))
    L, R = S.windows(length=300)
    n_cond = len(set(t["label"] for t in S.trials))
    rounds = np.array([t["i"] // n_cond for t in S.trials])
    labels = np.array([t["label"] for t in S.trials])
    ids = np.array([t["id"] for t in S.trials])
    X = trial_features(S, L, R)
    print(S.path.name, "trials", len(labels), "features", X.shape[1])
    for name, keep in [("all trials", np.ones(len(ids), bool))] + ([(f"without trials {drop}", ~np.isin(ids, drop))] if drop else []):
        print(" ", name)
        for pos, negs, bar, a in score(X, labels, rounds, keep):
            verdict = "" if bar is None else ("  PASS" if a >= bar else "  FAIL") + f" (bar {bar})"
            print(f"    CV AUC {pos} vs {'+'.join(negs):18s} {a:.3f}{verdict}")

if __name__ == "__main__":
    main()
