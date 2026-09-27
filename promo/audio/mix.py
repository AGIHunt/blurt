# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""Build the promo soundtrack from src/timeline.json: edit the music bed on the beat grid, synthesize every
sound effect in code, lay the voice-over, duck the music under it, normalize to -14 LUFS.

  uv run audio/mix.py                                 -> public/soundtrack.wav
  uv run audio/mix.py overlay IN.wav OUT.wav          -> add only the chicken layer to an existing mix
"""
from __future__ import annotations

import json
import subprocess
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SR = 48000
TL = json.loads((ROOT / "src/timeline.json").read_text())
CUE = TL["cues"]
rng = np.random.default_rng(7)


def decode(path: Path) -> np.ndarray:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-ac", "2", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).reshape(-1, 2).astype(np.float64)


# ------------------------------------------------------------------ synth helpers
def t_(d):
    return np.arange(int(d * SR)) / SR


def env(d, a=0.002, decay=0.1):
    t = t_(d)
    return np.minimum(t / a, 1) * np.exp(-t / decay)


def noise(d):
    return rng.standard_normal(int(d * SR))


def onepole(x, fc):
    """Lowpass with a (possibly time-varying) cutoff."""
    fc = np.broadcast_to(np.asarray(fc, float), x.shape)
    a = np.exp(-2 * np.pi * fc / SR)
    y = np.empty_like(x)
    s = 0.0
    for i in range(len(x)):
        s = (1 - a[i]) * x[i] + a[i] * s
        y[i] = s
    return y


def hp(x, fc):
    return x - onepole(x, fc)


def bp(x, lo, hi):
    return onepole(hp(x, lo), hi)


def sweep(f0, f1, d, curve=2.0):
    t = t_(d)
    f = f0 + (f1 - f0) * (t / d) ** curve
    return np.sin(2 * np.pi * np.cumsum(f) / SR)


def norm(x, peak=1.0):
    m = np.max(np.abs(x)) or 1
    return x / m * peak


def click():
    a = hp(noise(0.004), 2500) * env(0.004, 0.0002, 0.0012)
    b = hp(noise(0.004), 1800) * env(0.004, 0.0002, 0.001) * 0.6
    body = np.sin(2 * np.pi * 1800 * t_(0.012)) * env(0.012, 0.0005, 0.003) * 0.4
    out = np.zeros(int(0.075 * SR))
    out[: len(a)] += a
    out[: len(body)] += body
    out[int(0.06 * SR): int(0.06 * SR) + len(b)] += b
    return norm(out, 0.9)


def key():
    d = 0.05
    x = bp(noise(d), 1500, 5000) * env(d, 0.0005, 0.006)
    thock = np.sin(2 * np.pi * rng.uniform(180, 240) * t_(d)) * env(d, 0.001, 0.012) * 0.6
    return norm(x + thock, 0.8)


def pop(f0=900, f1=320):
    d = 0.12
    x = sweep(f0, f1, d, 0.5) * env(d, 0.002, 0.035)
    return norm(x + 0.05 * hp(noise(d), 3000) * env(d, 0.001, 0.01), 0.8)


def whoosh(d=0.6, up=True, bright=1.0):
    t = t_(d)
    shape = np.sin(np.pi * t / d) ** 2
    fc = (400 + 5000 * bright * (t / d if up else 1 - t / d)) + 200
    x = onepole(hp(noise(d), 150), fc)
    return norm(x * shape, 0.8)


def impact(d=1.8):
    t = t_(d)
    sub = np.sin(2 * np.pi * np.cumsum(38 + 60 * np.exp(-t / 0.08)) / SR) * np.exp(-t / 0.55)
    thump = onepole(noise(d), 900) * np.exp(-t / 0.06) * 3
    air = hp(noise(d), 2000) * np.exp(-t / 0.35) * 0.25
    x = np.tanh(1.8 * (sub + thump)) + air
    return norm(x, 1.0)


def shutter():
    out = np.zeros(int(0.16 * SR))
    for o, g in ((0, 1.0), (0.085, 0.7)):
        s = bp(noise(0.03), 800, 6000) * env(0.03, 0.0005, 0.006) * g
        i = int(o * SR)
        out[i: i + len(s)] += s
    return norm(out, 0.9)


def scribble(d=0.55):
    t = t_(d)
    fc = 2600 + 1400 * np.sin(2 * np.pi * 9 * t)
    x = onepole(hp(noise(d), 1200), fc) * (0.6 + 0.4 * np.sin(2 * np.pi * 13 * t) ** 2)
    return norm(x * np.sin(np.pi * t / d) ** 0.5, 0.5)


def tone(f, d=0.5, decay=0.18, harm=(1, 0.3, 0.1)):
    t = t_(d)
    x = sum(g * np.sin(2 * np.pi * f * (n + 1) * t) for n, g in enumerate(harm))
    return x * env(d, 0.003, decay)


def chime():
    a, b = tone(1318.5, 0.6, 0.2), tone(1975.5, 0.7, 0.25)
    out = np.zeros(int(0.8 * SR))
    out[: len(a)] += a
    out[int(0.07 * SR): int(0.07 * SR) + len(b)] += b
    return norm(out, 0.6)


def ding():
    t = t_(1.0)
    x = np.sin(2 * np.pi * 1568 * t + 1.2 * np.sin(2 * np.pi * 3136 * 1.41 * t) * np.exp(-t / 0.2))
    return norm(x * env(1.0, 0.002, 0.3), 0.55)


def beep(f=880):
    return norm(tone(f, 0.12, 0.05, (1, 0.15)), 0.5)


def buzz():
    t = t_(0.16)
    x = np.sign(np.sin(2 * np.pi * 140 * t)) * env(0.16, 0.004, 0.06)
    return norm(onepole(x, 1800), 0.5)


def slash():
    return whoosh(0.28, up=True, bright=1.6)


def riser(d=2.4):
    t = t_(d)
    x = onepole(hp(noise(d), 300), 300 + 7000 * (t / d) ** 2) * (t / d) ** 2
    x += 0.3 * sweep(200, 1200, d, 2) * (t / d) ** 3
    return norm(x, 0.7)


def tick():
    return norm(hp(noise(0.01), 4000) * env(0.01, 0.0003, 0.002), 0.5)


def typing(d, rate=14, seed=0):
    out = np.zeros(int((d + 0.1) * SR))
    t = 0.0
    r = np.random.default_rng(seed)
    while t < d:
        k = key() * r.uniform(0.55, 1)
        i = int(t * SR)
        out[i: i + len(k)] += k[: len(out) - i]
        t += r.uniform(0.6, 1.4) / rate
    return out


# ------------------------------------------------------------------ cue sheet: (time, sound, gain dB, pan -1..1)
def cues():
    c = CUE
    L = []
    add = lambda t, s, g=0, p=0: L.append((t, s, g, p))
    # hook: thumbnails assemble, then bug dots appear
    for i in range(12):
        add(0.55 + i * 0.16, pop(1300 - i * 25, 500), -20, (i % 5 - 2) / 3)
    add(c["hook.fail"] - 0.1, whoosh(0.5), -14)
    for i in range(6):
        add(c["hook.fail"] + 0.35 + i * 0.28, buzz(), -17, (i % 3 - 1) / 2)
    # pain: the manual grind
    add(c["pain.shot"], shutter(), -6)
    add(c["pain.box"], scribble(), -9)
    add(c["pain.type"], typing(1.2, 16, 1), -13)
    add(c["pain.paste"], whoosh(0.35, bright=1.3), -11)
    t, gap = c["pain.repeat"], 0.42
    while t < c["pain.stamp"] - 0.12:
        add(t, shutter(), -13 + (t - c["pain.repeat"]) * 1.2, rng.uniform(-0.5, 0.5))
        t += gap
        gap = max(0.09, gap * 0.86)
    add(c["pain.stamp"], impact(1.0), -7)
    # blind
    add(c["blind.mic"], beep(1320), -14)
    for k in ("blind.q1", "blind.q2", "blind.q3"):
        add(c[k], buzz(), -12, {"blind.q1": -0.4, "blind.q2": 0.4, "blind.q3": 0}[k])
    add(c["blind.title"], whoosh(0.45, up=False), -14)
    for i in range(5):
        add(c["blind.dark"] + i * 0.4918, tick(), -12)
    add(c["reveal.drop"] - 2.4, riser(2.4), -12)
    # reveal
    add(c["reveal.drop"], impact(1.1), -6)
    for i in range(5):
        add(c["reveal.name"] + i * 0.05, pop(1000 + i * 90, 420), -17)
    for k in ("reveal.show", "reveal.say", "reveal.gets"):
        add(c[k], whoosh(0.3, bright=1.2), -17)
    # record (living screencast)
    for i in range(3):
        add(c["record.key"] + i * 0.14, key(), -7)
    add(c["record.overlay"], whoosh(0.4, up=False, bright=0.5), -16)
    add(c["record.drag"], click(), -8)
    add(c["record.drag"] + 0.05, whoosh(0.9, bright=0.4), -22)
    add(c["record.dragEnd"], click(), -8)
    for i in range(3):
        add(c["record.count"] + i * 0.25, beep(880), -13)
    add(c["record.rec"], beep(1760), -11)
    for k in ("record.b1", "record.b2", "record.b3"):
        add(c[k], pop(700, 350), -16)
    add(c["record.point"], click(), -7)
    add(c["record.click"], click(), -6)
    # items
    add(c["items.zoomout"], whoosh(0.7, up=False), -10)
    for i, k in enumerate(("items.card1", "items.card2", "items.card3", "items.card4")):
        add(c[k], pop(800 + i * 120, 380), -11, (i - 1.5) / 3)
    add(c["items.frame"], shutter(), -12)
    add(c["items.box"], scribble(0.4), -12)
    add(c["items.code"], typing(0.9, 18, 2), -15)
    # review
    add(c["review.in"], whoosh(0.5), -12)
    add(c["review.keep"], key(), -5)
    add(c["review.keep"] + 0.05, chime(), -10)
    add(c["review.drop"], key(), -5)
    add(c["review.drop"] + 0.04, whoosh(0.3, bright=1.4), -10, 0.5)
    add(c["review.next"], key(), -5)
    add(c["review.next"] + 0.04, whoosh(0.35, up=False, bright=0.9), -13)
    # peak
    add(c["peak.drop"], impact(), -3)
    add(c["peak.slash"], slash(), -8)
    add(c["peak.thirty"], impact(1.2), -6)
    # export
    for k in ("export.lark", "export.github", "export.md"):
        add(c[k], whoosh(0.4, bright=1.1), -17)
        add(c[k] + 0.38, ding(), -20)
    add(c["export.say"] + 0.3, typing(0.8, 12, 3), -12)
    add(c["export.fix"] + 0.1, key(), -8)
    add(c["export.ok1"], pop(1200, 900), -14)
    add(c["export.ok2"], pop(1400, 1000), -14)
    # beyond
    for i, k in enumerate(("beyond.bugs", "beyond.ideas", "beyond.notes", "beyond.todos")):
        add(c[k], pop(700 + i * 110, 330), -10, (i - 1.5) / 3)
    add(c["beyond.team"], whoosh(0.5), -13)
    for i in range(4):
        add(c["beyond.team"] + 0.25 + i * 0.18, pop(1100, 600), -17, (i - 1.5) / 2)
    add(c["beyond.local"], click(), -8)
    # cta
    add(c["cta.drop"], impact(1.0), -8)
    add(c["cta.cmd"], typing(1.3, 16, 4), -12)
    add(c["cta.cmdDone"], chime(), -12)
    return L


def peck():
    """A beak on a hard surface: two quick woody taps."""
    out = np.zeros(int(0.09 * SR))
    for o, g in ((0, 1.0), (0.045, 0.55)):
        n = int(0.03 * SR)
        x = rng.standard_normal(n) * np.exp(-t_(0.03) / 0.0012)
        b = onepole(hp(x, 1500), 4200) * 2.2 + onepole(x, 700) * 0.8
        i = int(o * SR)
        out[i: i + n] += b * g
    return norm(out, 0.9)


def chicken_layer(n, duck_out=None):
    """Real (public-domain) chicken recordings + synthesized pecks, placed from timeline.json `chicken`.
    Featured calls (gain >= 0 dB) also write a ducking curve into `duck_out` so the bed steps aside."""
    clips = {}
    layer = np.zeros((n, 2))
    for t, name, gain, pan in TL.get("chicken", []):
        if name == "peck":
            snd = np.stack([peck()] * 2, 1)
        else:
            snd = clips.setdefault(name, decode(next(p for p in (ROOT / f"audio/fx/{name}.wav", ROOT / f"audio/chicken/{name}.wav") if p.exists())))
        i = int(t * SR)
        seg = snd[: n - i] * 10 ** (gain / 20)
        if duck_out is not None and gain >= 0:
            a, b = max(0, i - int(0.08 * SR)), min(n, i + len(seg))
            ramp = int(0.08 * SR)
            curve = np.ones(b - a) * 0.4
            curve[:ramp] = np.linspace(1, 0.4, min(ramp, b - a))
            curve[-ramp:] = np.linspace(0.4, 1, ramp)
            duck_out[a:b] = np.minimum(duck_out[a:b], curve)
        layer[i: i + len(seg), 0] += seg[:, 0] * np.sqrt((1 - pan) / 2) * 1.414
        layer[i: i + len(seg), 1] += seg[:, 1] * np.sqrt((1 + pan) / 2) * 1.414
    return layer


def write_wav(path, x):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes())


def overlay(base: Path, out: Path):
    """Put the chicken layer on top of an already-mixed soundtrack (e.g. one with an edited voice)."""
    x = decode(base)
    n = len(x)
    duck = np.ones(n)
    ch = chicken_layer(n, duck)
    y = x * duck[:, None] + ch * 10 ** (-1 / 20)
    tmp = ROOT / "audio/.premaster.wav"
    write_wav(tmp, y / max(1.0, np.abs(y).max()))
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(tmp), "-af", "loudnorm=I=-14:TP=-1.2:LRA=11", "-ar", str(SR), str(out)], check=True)
    tmp.unlink()
    print(out)


# ------------------------------------------------------------------ build
def main():
    n = int(TL["duration"] * SR)
    # music: beat-aligned splices with short equal-power crossfades
    src = decode(ROOT / TL["music"]["src"])
    parts = [src[int(a * SR): int(b * SR)] for a, b in TL["music"]["segments"]]
    xf = int(0.012 * SR)
    music = parts[0]
    for p in parts[1:]:
        f = np.linspace(0, 1, xf)[:, None]
        mid = music[-xf:] * np.cos(f * np.pi / 2) + p[:xf] * np.sin(f * np.pi / 2)
        music = np.concatenate([music[:-xf], mid, p[xf:]])
    music = music[:n]
    fade = int(1.2 * SR)
    music[-fade:] *= np.linspace(1, 0, fade)[:, None] ** 2
    music = np.pad(music, ((0, n - len(music)), (0, 0)))

    vo = np.zeros((n, 2))
    for name, start in TL["vo"]:
        v = decode(ROOT / f"audio/vo/{name}.wav")
        i = int(start * SR)
        vo[i: i + len(v)] += v[: n - i]
    vo *= 10 ** (3 / 20)

    # duck music ~6 dB under the voice (smoothed envelope, fast attack, slow release)
    e = np.abs(vo).max(1)
    blk = int(0.01 * SR)
    eb = e[: len(e) // blk * blk].reshape(-1, blk).max(1)
    g = np.zeros_like(eb)
    s = 0.0
    for i, v in enumerate(eb > 0.02):
        s = s + (1 - s) * 0.35 if v else s * 0.965
        g[i] = s
    duck = np.repeat(1 - 0.7 * g, blk)
    duck = np.pad(duck, (0, n - len(duck)), constant_values=1)
    music *= duck[:, None] * 10 ** (-9 / 20)

    fx = np.zeros((n, 2))
    for t, snd, gain, pan in cues():
        i = int(t * SR)
        if i >= n:
            continue
        seg = snd[: n - i] * 10 ** (gain / 20)
        fx[i: i + len(seg), 0] += seg * np.sqrt((1 - pan) / 2) * 1.414
        fx[i: i + len(seg), 1] += seg * np.sqrt((1 + pan) / 2) * 1.414

    cduck = np.ones(n)
    ch = chicken_layer(n, cduck)
    mix = music * cduck[:, None] + vo + fx * cduck[:, None] + ch * 10 ** (-4 / 20)
    if __import__("os").environ.get("STEMS"):
        blk2 = SR // 2
        for i in range(0, n - blk2, blk2):
            v = np.sqrt((vo[i:i + blk2] ** 2).mean()); m = np.sqrt((music[i:i + blk2] ** 2).mean()); f = np.sqrt((fx[i:i + blk2] ** 2).mean())
            if v > 0.01:
                print(f"{i / SR:5.1f}s  vo/music {20 * np.log10(v / (m + 1e-9)):5.1f} dB  vo/fx {20 * np.log10(v / (f + 1e-9)):5.1f} dB")
    tmp = ROOT / "audio/.premaster.wav"
    with wave.open(str(tmp), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(mix / max(1.0, np.abs(mix).max()), -1, 1) * 32767).astype(np.int16).tobytes())
    out = ROOT / "public/soundtrack.wav"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(tmp), "-af", "loudnorm=I=-14:TP=-1.2:LRA=11",
                    "-ar", str(SR), str(out)], check=True)
    tmp.unlink()
    print(out)


if __name__ == "__main__":
    import sys
    if len(sys.argv) == 4 and sys.argv[1] == "overlay":
        overlay(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        main()
