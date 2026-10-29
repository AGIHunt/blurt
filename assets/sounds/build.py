"""blurt sounds: the cues a take plays (Capture/Dictation/DictationSound.swift), built from the film's own sounds.

    python3 assets/sounds/build.py            # write the outputs
    python3 assets/sounds/build.py --check    # exit 1 if an output is stale (tests run this)

Sources: both synthesized, as the film makes them (no recordings)
  Peep's peep     two quick rising chirps, 2.5 → 4 kHz, the second softer (blurt-media/film/v3/audio/mix.py peep(): the
                  film's 1:34, when the take is done; the founder picked it over a recorded hen's cluck, v1.0.6)
  the peck        two clicks of filtered noise (blurt-media/film/audio/mix.py peck())

Outputs (skills/blurt/recorder/macos/Sources/BlurtApp/Resources/Sounds, 48 kHz 16-bit mono WAV; record.py copies them
into Blurt.app)
  start.wav    Peep's peep: listening has started, talk now
  stop.wav     the double peck: the take is done, the words are on their way
  cancel.wav   one softer, darker peck: the take was thrown away

Standard library only, seeded: the same bytes on every run.
"""
from __future__ import annotations

import math
import random
import struct
import sys
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUT = ROOT / "skills/blurt/recorder/macos/Sources/BlurtApp/Resources/Sounds"
SR = 48000
START_PEAK_DB = -19.0


def encode(x: list[float]) -> bytes:
    import io
    b = io.BytesIO()
    with wave.open(b, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(struct.pack(f"<{len(x)}h", *(max(-32767, min(32767, round(s * 32767))) for s in x)))
    return b.getvalue()


def onepole(x: list[float], hz: float) -> list[float]:
    """Low-pass."""
    a = 1 - math.exp(-2 * math.pi * hz / SR)
    y, out = 0.0, []
    for s in x:
        y += a * (s - y)
        out.append(y)
    return out


def hp(x: list[float], hz: float) -> list[float]:
    lo = onepole(x, hz)
    return [s - l for s, l in zip(x, lo)]


def fade(x: list[float], inn: float, out: float) -> list[float]:
    n, a, b = len(x), int(inn * SR), int(out * SR)
    return [s * min(1.0, i / a if a else 1.0, (n - i) / b if b else 1.0) for i, s in enumerate(x)]


def norm(x: list[float], peak_db: float) -> list[float]:
    m = max(abs(s) for s in x) or 1.0
    g = 10 ** (peak_db / 20) / m
    return [s * g for s in x]


def peep(up: float = 1.0) -> list[float]:
    """The film's peep: a 0.1 s chirp rising 2.5 → 4 kHz under a soft hump, then the same at 0.75, 0.12 s later."""
    n = int(0.10 * SR)
    chirp, ph = [], 0.0
    for i in range(n):
        u = i / (n - 1)
        ph += 2 * math.pi * (2500 + 1500 * u) * up / SR
        chirp.append(math.sin(ph) * abs(math.sin(math.pi * u)) ** 1.5)
    out = [0.0] * (int(0.12 * SR) + n)
    for j, s in enumerate(chirp):
        out[j] += s
        out[int(0.12 * SR) + j] += 0.75 * s
    return out


def peck(rng: random.Random, hits=((0.0, 1.0), (0.045, 0.55)), bright=4200.0) -> list[float]:
    """The film's peck: short bursts of decaying noise, a bright click over a low knock."""
    out = [0.0] * int((max(o for o, _ in hits) + 0.045) * SR)
    n = int(0.03 * SR)
    for o, g in hits:
        x = [rng.gauss(0, 1) * math.exp(-(i / SR) / 0.0012) for i in range(n)]
        b = [2.2 * c + 0.8 * k for c, k in zip(onepole(hp(x, 1500), bright), onepole(x, 700))]
        i = int(o * SR)
        for j, s in enumerate(b):
            out[i + j] += s * g
    return out


def build() -> dict[str, bytes]:
    rng = random.Random(7)
    # levels by ear-loudness, not peak: the peep is a pure tone where the ear is most sensitive (2.5–4 kHz), a peck
    # mostly silence around a click (≈ 25 dB crest), so the peep sits far under full scale and the pecks near it; the
    # peep matches the stop peck's loudness (ITU-R BS.1770, measured with ffmpeg ebur128 on the clips)
    start = norm(peep(), START_PEAK_DB)
    stop = norm(peck(rng), -1)
    cancel = norm(fade(peck(rng, hits=((0.0, 1.0),), bright=1800), 0.0, 0.01), -6)
    return {"start.wav": encode(start), "stop.wav": encode(stop), "cancel.wav": encode(cancel)}


def main() -> int:
    check = "--check" in sys.argv
    stale = []
    for name, data in build().items():
        p = OUT / name
        if p.exists() and p.read_bytes() == data:
            continue
        if check:
            stale.append(name)
        else:
            OUT.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
            print(f"wrote {p.relative_to(ROOT)} ({len(data) // 1024} KB)")
    if stale:
        print("stale: " + ", ".join(stale) + " (run python3 assets/sounds/build.py)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
