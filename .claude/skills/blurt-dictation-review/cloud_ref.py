"""Second opinions on disputed dictation audio from cloud speech models (OpenRouter /audio/transcriptions), with a hard
spending cap. The user allowed it (2026-10-28): disputed clips only, OpenRouter's key, at most $10 in total.

  OPENROUTER_API_KEY=… python cloud_ref.py CLIP.wav [CLIP.wav …] [--model openai/whisper-large-v3]… [--language zh]
      → one JSON line per clip: {"audio", "refs": {model: text}, "cost", "spent_total"}

The key comes from the environment only (load it inline into this one command; never print it). Every call's cost
(the response's usage.cost) is added to spend.json next to this file; a call that could take the total past CAP_USD
is not made. Clips longer than MAX_SECONDS are refused: send the disputed part, not a whole meeting."""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.request
import wave
from pathlib import Path

CAP_USD = 10.0
MAX_SECONDS = 120
LEDGER = Path(__file__).resolve().parent / "spend.json"
URL = "https://openrouter.ai/api/v1/audio/transcriptions"
# per second of audio, OpenRouter's catalogue (Oct 2026), for the estimate before a call; the bill is usage.cost
PRICE = {"openai/whisper-large-v3": 0.0000075, "openai/whisper-large-v3-turbo": 0.00000333, "openai/whisper-1": 0.0001,
         "openai/gpt-transcribe": 0.000075}
DEFAULT_MODELS = ["openai/whisper-large-v3", "openai/gpt-transcribe"]


def spent() -> float:
    try:
        return float(json.loads(LEDGER.read_text())["total_usd"])
    except (OSError, ValueError, KeyError):
        return 0.0


def record(model: str, seconds: float, cost: float) -> float:
    d = {"total_usd": 0.0, "calls": []}
    try:
        d = json.loads(LEDGER.read_text())
    except (OSError, ValueError):
        pass
    d["total_usd"] = round(float(d.get("total_usd", 0)) + cost, 6)
    d["calls"] = (d.get("calls") or [])[-500:] + [{"model": model, "seconds": round(seconds, 2), "cost": cost}]
    LEDGER.write_text(json.dumps(d, indent=1))
    return d["total_usd"]


def seconds_of(path: Path) -> float:
    with wave.open(str(path)) as w:
        return w.getnframes() / w.getframerate()


def transcribe(path: Path, model: str, language: str | None, key: str) -> tuple[str, float]:
    body = {"model": model, "input_audio": {"data": base64.b64encode(path.read_bytes()).decode(), "format": "wav"},
            "temperature": 0, "response_format": "json"}
    if language:
        body["language"] = language
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        d = json.loads(r.read())
    return d.get("text", ""), float((d.get("usage") or {}).get("cost") or 0)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("clips", nargs="+")
    ap.add_argument("--model", action="append")
    ap.add_argument("--language")
    a = ap.parse_args()
    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        sys.exit("OPENROUTER_API_KEY is not set")
    for clip in map(Path, a.clips):
        secs = seconds_of(clip)
        out = {"audio": str(clip), "seconds": round(secs, 2), "refs": {}, "cost": 0.0}
        if secs > MAX_SECONDS:
            out["error"] = f"longer than {MAX_SECONDS} s: send the disputed part"
            print(json.dumps(out, ensure_ascii=False))
            continue
        for model in a.model or DEFAULT_MODELS:
            estimate = secs * PRICE.get(model, 0.0001) * 2           # unknown price or rounding: assume more
            if spent() + estimate > CAP_USD:
                out["refs"][model] = None
                out["error"] = f"budget: ${spent():.4f} of ${CAP_USD} spent"
                continue
            try:
                text, cost = transcribe(clip, model, a.language, key)
            except Exception as e:  # noqa: BLE001 — one model failing leaves the others
                out["refs"][model] = None
                out.setdefault("errors", {})[model] = f"{type(e).__name__}: {e}"[:200]
                continue
            out["refs"][model] = text
            out["cost"] = round(out["cost"] + cost, 6)
            out["spent_total"] = record(model, secs, cost)
        print(json.dumps(out, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
