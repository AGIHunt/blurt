#!/usr/bin/env python3
"""Stage 1, second pass: speaker wake-up time, band edges, level linearity (AGC), echo stability."""
import json, sys, time
from pathlib import Path
import numpy as np
from scipy import signal
sys.path.insert(0, str(Path(__file__).parent))
from hw_check import duplex, fade, sweep, stereo, OUT

def periodic_chirp(fs, period, f0, f1, amp):
    """Band-limited periodic linear chirp: only FFT bins in [f0,f1], so no splatter and no clicks when it repeats."""
    k = np.arange(period // 2 + 1); f = k * fs / period
    m = (f >= f0) & (f <= f1); idx = k[m]; n = len(idx)
    X = np.zeros(period // 2 + 1, complex)
    X[idx] = np.exp(-1j * np.pi * (np.arange(n) ** 2) / n)   # chirp phase: near-constant envelope
    x = np.fft.irfft(X, period); return amp * x / np.abs(x).max()

def edge():
    fs = 48000
    s = sweep(fs, 15500, 23500, 4, 0.05)      # lead-in handled below
    lead = np.zeros(int(fs * .5))
    x = np.r_[lead, s]; y = duplex("edge48", stereo(l=x), fs)
    f, t, S = signal.spectrogram(y, fs, nperseg=1024, noverlap=768)
    tr = (f[np.newaxis, :] * 0)
    print("\nfrequency response (peak along the sweep, left speaker, 48 kHz):")
    for fc in range(15500, 24000, 250):
        tc = .5 + (fc - 15500) / 8000 * 4
        i = np.argmin(abs(t - tc)); j = np.argmin(abs(f - fc))
        print(f"  {fc/1000:6.2f} kHz {10*np.log10(S[max(j-2,0):j+3, i-1:i+2].mean()+1e-20):7.1f}")

def wake():
    fs, per = 48000, 480
    x = periodic_chirp(fs, per, 18000, 21000, .05)
    y = duplex("wake", stereo(l=np.tile(x, 150)), fs)
    sos = signal.butter(6, [17500, 21500], "bp", fs=fs, output="sos")
    e = np.abs(signal.hilbert(signal.sosfiltfilt(sos, y)))
    e20 = 20 * np.log10(np.convolve(e, np.ones(48) / 48, "same") + 1e-9)
    tgt = np.median(e20[int(.8 * fs):int(1.3 * fs)])
    t10 = np.argmax(e20 > tgt - 20) / fs; t1 = np.argmax(e20 > tgt - 1) / fs
    print(f"\nspeaker wake: reaches -20 dB of steady at {t10*1000:.0f} ms, -1 dB at {t1*1000:.0f} ms; steady env {tgt:.1f} dBFS")

def linear():
    fs, per = 48000, 480
    print("\nlevel linearity, level steps 3 s each, same run (AGC would flatten this):")
    amps = [.005, .01, .02, .05, .1, .2, .05, .005]
    base = periodic_chirp(fs, per, 18000, 21000, 1)
    seg = np.tile(base, 100)
    x = np.concatenate([fade(a * np.tile(base, 200), fs) for a in amps])
    y = duplex("linear", stereo(l=x), fs, tail=.1)
    sos = signal.butter(6, [17500, 21500], "bp", fs=fs, output="sos")
    b = signal.sosfiltfilt(sos, y)
    lp = signal.butter(6, 15000, "lp", fs=fs, output="sos")
    l = signal.sosfiltfilt(lp, y)
    for i, a in enumerate(amps):
        s = int(fs * (i * 2 + .5)); e = int(fs * (i * 2 + 1.8))
        print(f"  out {20*np.log10(a):6.1f} dBFS   in-band {20*np.log10(b[s:e].std()):6.1f} dBFS   gain {20*np.log10(b[s:e].std()/a):6.1f} dB   <15k {20*np.log10(l[s:e].std()):6.1f} dBFS")

if __name__ == "__main__":
    edge(); time.sleep(.3); wake(); time.sleep(.3); linear()
