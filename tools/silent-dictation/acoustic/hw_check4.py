#!/usr/bin/env python3
"""Stage 1, last pass: stereo probe (right = left shifted half a period), out-of-band leakage, start click."""
import sys, time
from pathlib import Path
import numpy as np
from scipy import signal
sys.path.insert(0, str(Path(__file__).parent))
from hw_check import duplex, fade, stereo, OUT
from cir import probe, frames_to_cir, C

fs, per, amp, f0, f1 = 48000, 960, .1, 17500, 23000
x, X = probe(fs, per, f0, f1, amp)
secs = 12
n = int(secs * fs / per)
l = fade(np.tile(x, n), fs, 100); r = fade(np.tile(np.roll(x, per // 2), n), fs, 100)
sil = duplex("oob_silence", np.zeros((fs * 6, 2)), fs, tail=0)
time.sleep(.3)
y = duplex("stereo", stereo(l, r), fs)
h = frames_to_cir(y, per, X, start=int(1.5 * fs))[:-20]
m = np.abs(h).mean(0)
d = int(np.argmax(m)); dr = d + per // 2 - 60 + int(np.argmax(np.roll(m, -(d + per // 2 - 60))[:120]))
print(f"left direct at {d} {20*np.log10(m[d]):.1f} dB, right direct at {dr%per} {20*np.log10(m[dr%per]):.1f} dB, floor {20*np.log10(np.median(m)):.1f} dB")
def bandp(v, lo, hi):
    sos = signal.butter(6, [lo, hi], "bp", fs=fs, output="sos"); b = signal.sosfiltfilt(sos, v); return b
y2 = y[int(2 * fs):int(10 * fs)]; s2 = sil[int(1 * fs):int(5.5 * fs)]
print("out-of-band level, silence vs sonar:")
for lo, hi in [(40, 200), (200, 1000), (1000, 4000), (4000, 10000), (10000, 15000), (15000, 17000)]:
    print(f"  {lo:6d}-{hi:6d} Hz  {20*np.log10(bandp(s2,lo,hi).std()):7.1f}  {20*np.log10(bandp(y2,lo,hi).std()):7.1f} dBFS")
# 100 Hz and 50 Hz combs would come from the probe period through a nonlinearity
f, p0 = signal.welch(s2, fs, nperseg=fs); f, p1 = signal.welch(y2, fs, nperseg=fs)
print("lines at multiples of 50 Hz up to 500 Hz, sonar minus silence (dB):", [round(10*np.log10(p1[k]/p0[k]),1) for k in range(50, 501, 50)])
hp = bandp(y, 2000, 15000)
frames = np.array([hp[i:i+480].std() for i in range(0, len(hp)-480, 480)])
print("broadband 2-15 kHz around start, 10 ms steps, dBFS:", np.round(20*np.log10(frames[:40:3]+1e-9),1).tolist())
print("around stop:", np.round(20*np.log10(frames[-45:-5:3]+1e-9),1).tolist())
