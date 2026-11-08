"""Load a SonarLab session: echo profiles, marks, camera sync."""
import json
from pathlib import Path
import numpy as np
C = 343.0
ROOT = Path.home() / "Library/Application Support/Blurt VSR Pilot/acoustic/sessions"

def latest(block):
    c = sorted(ROOT.glob(f"{block}-*"), key=lambda p: p.stat().st_mtime)
    done = [p for p in c if (p / "meta.json").exists() and json.load(open(p / "meta.json")).get("completed")]
    return done[-1]

class Session:
    def __init__(self, path, hop=480):
        self.path = Path(path); self.meta = json.load(open(self.path / "meta.json"))
        self.fs = int(self.meta["fs"]); self.P = int(self.meta["period"]); self.hop = hop
        self.fps = self.fs / hop
        self.y = np.fromfile(self.path / "mic.f32", dtype=np.float32)
        self.marks = [json.loads(l) for l in open(self.path / "marks.jsonl")]
        voided = {m["id"] for m in self.marks if m["kind"] == "void"}
        self.trials = [m for m in self.marks if m["kind"] == "trial" and m.get("id", -1) not in voided]
        p = np.fromfile(self.path / "probe.f32", dtype=np.float32)
        X = np.fft.rfft(p); m = np.abs(X) > 1e-3 * np.abs(X).max(); self.nb = int(m.sum())
        Xf = np.zeros(self.P, complex); Xf[: len(X)] = np.where(m, X / np.abs(X).max(), 0); self.Xf = Xf
        self._h = None

    def cir(self):
        """Complex echo profile, frames at self.fps, delay index in samples, aligned to the stream (not rolled)."""
        if self._h is not None: return self._h
        P, hop, y = self.P, self.hop, self.y
        n = (len(y) - P) // hop
        idx = np.arange(n)[:, None] * hop + np.arange(P)[None, :]
        out = []
        for i in range(0, n, 2000):
            Y = np.fft.fft(y[idx[i:i + 2000]].astype(np.float64), axis=1)
            H = Y * np.conj(self.Xf)[None]
            hh = np.fft.ifft(H, axis=1) * 2 / self.nb
            s = np.arange(i, min(i + 2000, n)) * hop
            # window slides but the probe is periodic: undo the circular shift so a delay stays in one column
            ks = (-s) % P if False else s % P
            for r in range(len(hh)): hh[r] = np.roll(hh[r], ks[r])
            out.append(hh.astype(np.complex64))
        self._h = np.concatenate(out)
        return self._h

    def direct(self):
        m = np.abs(self.cir()).mean(0); return int(np.argmax(m))

    def windows(self, before=20, length=320):
        """Echo profile per speaker, rolled so index `before` is the left direct path. Returns (left, right), frames x delay."""
        h, d = self.cir(), self.direct()
        P = self.P
        idx = (np.arange(length) - before + d) % P
        idr = (idx + self.meta["right_shift"]) % P
        return h[:, idx], h[:, idr]

    def host_to_frame(self):
        a = np.loadtxt(self.path / "anchors.csv", delimiter=",", skiprows=1)
        v = np.loadtxt(self.path / "frames.csv", delimiter=",", skiprows=1)
        s = np.polyfit(a[:, 1] - a[0, 1], a[:, 0], 1)
        return np.polyval(s, v[:, 1] - a[0, 1]) / self.hop  # video frame -> sonar frame (float)

    def landmarks(self):
        import csv
        rows = list(csv.DictReader(open(self.path / "landmarks.csv")))
        keys = [k for k in rows[0] if k != "frame"]
        return {k: np.array([float(r[k]) if r[k] else np.nan for r in rows]) for k in keys}
