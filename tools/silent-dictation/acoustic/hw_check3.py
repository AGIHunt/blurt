#!/usr/bin/env python3
"""Stage 1, third pass: echo profile and stability with nothing deliberately moving."""
import sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).parent))
from hw_check import duplex, fade, stereo, OUT
from cir import probe, frames_to_cir, C

fs, per = 48000, 960
amp = float(sys.argv[1]) if len(sys.argv) > 1 else .1
f0, f1 = 17500, 23000
x, X = probe(fs, per, f0, f1, amp)
secs = 20
sig = fade(np.tile(x, int(secs * fs / per)), fs, 100)
y = duplex(f"static_{int(amp*1000)}", stereo(l=sig), fs)
h = frames_to_cir(y, per, X, start=int(fs))
h = h[:-20]
print("frames", h.shape, "fps", fs / per)
m = np.abs(h).mean(0); d0 = int(np.argmax(m))
print(f"direct path at sample {d0}, level {20*np.log10(m[d0]):.1f} dB")
r = np.roll(h, -d0 + 20, axis=1)
mm = np.abs(r).mean(0); nf = np.median(mm[int(per*.7):int(per*.9)])
print(f"far-delay floor {20*np.log10(nf):.1f} dB  ({20*np.log10(m[d0]/nf):.1f} dB below direct)")
# per-delay: static level, and how much it moves frame to frame (first difference removes slow drift)
diff = np.diff(r, axis=0); jit = np.sqrt((np.abs(diff) ** 2).mean(0) / 2)
print("path extra(cm)  echo_dB  jitter_dB   echo/jit  phase_std_rad")
for s in list(range(10, 30, 2)) + list(range(30, 90, 5)) + list(range(90, 260, 20)):
    ang = np.unwrap(np.angle(r[:, s])); ang = ang - np.polyval(np.polyfit(np.arange(len(ang)), ang, 2), np.arange(len(ang)))
    print(f"{(s-20)/fs*C*100:8.0f} {20*np.log10(mm[s]):9.1f} {20*np.log10(jit[s]):9.1f} {20*np.log10(mm[s]/jit[s]):9.1f} {ang.std():9.3f}")
