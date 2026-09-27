# /// script
# requires-python = ">=3.10"
# ///
"""Regenerate the music bed (Lyria 3 Pro) and the voice-over (gpt-audio) through OpenRouter.
Needs OPENROUTER_API_KEY in the environment. Outputs are already committed; you only need this to change them.

  uv run audio/generate.py music            -> audio/music_src.mp3
  uv run audio/generate.py vo [v01 v02 …]   -> audio/vo/vNN.wav (silence-trimmed)
"""
from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
import urllib.request
import wave
from pathlib import Path

HERE = Path(__file__).parent
KEY = os.environ.get("OPENROUTER_API_KEY") or sys.exit("set OPENROUTER_API_KEY")
MUSIC_PROMPT = (
    "Instrumental only, no vocals, no singing. An 80-second modern tech product launch track, 120 BPM, A minor. "
    "Style: punchy, polished electronic future-bass pop, like an Apple or Linear launch video. Structure: soft atmospheric "
    "intro with ticking hi-hats and a curious plucky synth motif; tension builds with a filtered kick and pulsing bass; "
    "breakdown then a big riser and snare roll; BIG DROP with wide supersaw chords and driving drums, confident and "
    "uplifting, leaving room for a voice-over; short stop and impact hit; final anthemic lift; outro resolving cleanly."
)
VOICE = "onyx"
LINES = {
    "v01": "Your AI just built forty screens overnight.",
    "v02": "Now you get to tell it everything that's wrong.",
    "v03": "So you screenshot. Draw a red box. Type out what you meant. Paste. Repeat.",
    "v04": "Or you dictate it... but your AI can't see what you're pointing at.",
    "v05": "Meet blurt. Show it. Say it. Your AI gets it.",
    "v06": "Hit a hotkey. Pick the area. Then just talk. Point, click, ramble, change your mind.",
    "v07": "Your coding agent turns it into clean items: the exact frame, the spot boxed, and the code that's probably behind it.",
    "v08": "Review them like short videos. Keep. Drop. Next.",
    "v09": "Two days of feedback... in thirty minutes.",
    "v10": "Send them to Lark, GitHub, or Markdown. Or just say: fix them.",
    "v11": "Bugs, ideas, notes, to-dos. Solo, or with your whole team. And your voice never leaves your machine.",
    "v12": "blurt. Open source. One command away.",
}


def stream(body: dict):
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        for line in r:
            line = line.decode().strip()
            if line.startswith("data:") and not line.endswith("[DONE]"):
                yield json.loads(line[5:])


def audio_of(body: dict) -> tuple[bytes, str]:
    data, text = b"", ""
    for d in stream(body):
        for ch in d.get("choices", []):
            a = (ch.get("delta") or {}).get("audio") or {}
            data += base64.b64decode(a["data"]) if a.get("data") else b""
            text += a.get("transcript") or ""
    return data, text


def music():
    data, _ = audio_of({"model": "google/lyria-3-pro-preview", "stream": True, "modalities": ["text", "audio"],
                        "messages": [{"role": "user", "content": MUSIC_PROMPT}]})
    (HERE / "music_src.mp3").write_bytes(data)
    print("music_src.mp3 — re-check bpm / drops and update timeline.json music.segments")


def vo(names):
    norm = lambda s: re.sub(r"[^a-z]", "", s.lower())  # noqa: E731
    sysmsg = ("You are a text-to-speech engine for a tech product launch video narrator: energetic but cool, confident, "
              "crisp, slightly playful. You output ONLY the exact words given, spoken aloud. Never add any preamble.")
    for name in names or LINES:
        for _ in range(5):
            pcm, said = audio_of({"model": "openai/gpt-audio", "stream": True, "modalities": ["text", "audio"],
                                  "audio": {"voice": VOICE, "format": "pcm16"},
                                  "messages": [{"role": "system", "content": sysmsg},
                                               {"role": "user", "content": "Speak this exactly, nothing before or after:\n" + LINES[name]}]})
            if norm(said) == norm(LINES[name]):
                break
        raw = HERE / f"vo/{name}.raw.wav"
        with wave.open(str(raw), "wb") as w:
            w.setnchannels(1), w.setsampwidth(2), w.setframerate(24000), w.writeframes(pcm)
        trim = ("silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.05,areverse,"
                "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.08,areverse")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(raw), "-af", trim, "-ar", "48000", str(HERE / f"vo/{name}.wav")], check=True)
        raw.unlink()
        print(name, said)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    music() if cmd == "music" else vo(sys.argv[2:]) if cmd == "vo" else sys.exit(__doc__)
