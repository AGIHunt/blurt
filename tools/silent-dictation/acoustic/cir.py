"""Echo-profile maths shared by hardware checks and analysis."""
import numpy as np
C = 343.0

def band_bins(fs, period, f0, f1):
    k = np.arange(period // 2 + 1); f = k * fs / period
    return k[(f >= f0) & (f <= f1)]

def probe(fs, period, f0, f1, amp):
    """Band-limited periodic chirp, returns (waveform, unit-spectrum). Repeats without a click by construction."""
    idx = band_bins(fs, period, f0, f1); n = len(idx)
    X = np.zeros(period // 2 + 1, complex)
    X[idx] = np.exp(-1j * np.pi * (np.arange(n) ** 2) / n)
    x = np.fft.irfft(X, period); s = amp / np.abs(x).max()
    return x * s, X

def frames_to_cir(y, period, X, start=0):
    """Complex echo profile per period. Shape (frames, period), delay index in samples (circular)."""
    n = (len(y) - start) // period
    Y = np.fft.fft(y[start:start + n * period].reshape(n, period), axis=1)
    Xf = np.zeros(period, complex); Xf[: len(X)] = X       # keep positive freqs only: analytic result
    return np.fft.ifft(Y * np.conj(Xf)[None, :], axis=1) * 2 / (np.abs(X) ** 2).sum()
