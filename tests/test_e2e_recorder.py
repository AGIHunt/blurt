"""End to end on a real Mac (opt-in: BLURT_E2E=1): build the native recorder into a scratch BLURT_HOME, record a
small screen area for a few seconds with BLURT_TEST_MIC_WAV standing in for the microphone (a `say` wav — no mic is
opened), stop from the chat side, and check what the integration promises:
  • live/audio.pcm is on the video timeline (byte offset / 32000 = video time; speech lands where the file has it)
  • the mp4 has the same audio, and live.py's transcript.json exists right at stop
  • `transcribe.py run` reuses it ("live": true)
Needs macOS, swiftc, Screen Recording permission for the app hosting the test, `say`, ffmpeg, uv, and the
SenseVoice + Silero models in ~/.blurt/models (used read-only through a symlink). It records the screen area
BLURT_E2E_REGION (x,y,w,h points; default 0,40,400,300) — put something harmless there; the take is deleted after.

  BLURT_E2E=1 uv run --with numpy python -m unittest tests.test_e2e_recorder -v
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
MODELS = Path.home() / ".blurt" / "models"
LEAD = 1.0  # s of silence before the speech in the test wav


@unittest.skipUnless(os.environ.get("BLURT_E2E") == "1" and sys.platform == "darwin", "opt-in: BLURT_E2E=1 on macOS")
class RecorderE2E(unittest.TestCase):
    def test_file_mic_reaches_pcm_mp4_and_live_transcript(self):
        if not (MODELS / "sensevoice").exists() or not shutil.which("say"):
            self.skipTest("needs `say` and the SenseVoice model in ~/.blurt/models")
        tmp = Path(tempfile.mkdtemp(prefix="blurt-e2e-"))
        home, sess = tmp / "home", tmp / "session"
        home.mkdir()
        (home / "models").symlink_to(MODELS)
        (home / "config.json").write_text(json.dumps({"record": {"install_app": False, "live_drafts": False},
                                                      "asr": {"backend": "sensevoice"}}))
        aiff, wav = tmp / "say.aiff", tmp / "mic.wav"
        subprocess.run(["say", "-v", "Tingting", "-o", str(aiff), "保存按钮的颜色太浅了，几乎看不清。"], check=True)
        raw = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(aiff), "-ac", "1", "-ar", "48000",
                              "-f", "s16le", "-"], capture_output=True, check=True).stdout
        with wave.open(str(wav), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
            w.writeframes(b"\0\0" * int(LEAD * 48000) + raw + b"\0\0" * 48000 * 2)
        env = dict(os.environ, BLURT_HOME=str(home), BLURT_TEST_MIC_WAV=str(wav), BLURT_HOTKEY_MODS="ctrl+opt+shift+cmd")
        uv = shutil.which("uv")
        build = subprocess.run([uv, "run", "-q", str(SCRIPTS / "record.py"), "build"], env=env, capture_output=True, text=True)
        self.assertIn('"native": "', build.stdout, build.stderr[-2000:])
        rec = subprocess.Popen([uv, "run", "-q", str(SCRIPTS / "record.py"), "start", "--session", str(sess),
                                "--region", os.environ.get("BLURT_E2E_REGION", "0,40,400,300"), "--countdown", "0"], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            t0 = time.time()
            while not (sess / "live" / "audio.pcm").exists() and time.time() - t0 < 30:
                time.sleep(0.1)
            time.sleep(len(raw) / 96000 + LEAD + 2)
            subprocess.run([uv, "run", "-q", str(SCRIPTS / "record.py"), "stop"], env=env, check=True, capture_output=True)
            t_stop = time.time()
            out, _ = rec.communicate(timeout=60)
        finally:
            if rec.poll() is None:
                rec.kill()
        self.assertEqual(rec.returncode, 0, out[-2000:])
        self.assertIn("DONE video=", out)
        while not (sess / "transcript.json").exists() and time.time() - t_stop < 15:
            time.sleep(0.1)
        self.assertTrue((sess / "transcript.json").exists(), "live.py wrote no transcript.json")

        meta = json.loads((sess / "meta.json").read_text())
        pcm = np.frombuffer((sess / "live" / "audio.pcm").read_bytes(), np.int16).astype(np.float32) / 32768
        self.assertAlmostEqual(len(pcm) / 16000, meta["duration"], delta=1.0)
        env_ = np.array([np.sqrt(np.mean(pcm[i:i + 160] ** 2)) for i in range(0, len(pcm) - 160, 160)])
        first = np.argmax(env_ > 0.01) / 100
        self.assertAlmostEqual(first, LEAD, delta=0.4)          # speech where the file has it: on the video timeline
        self.assertGreater(meta.get("audio_buffers", 0), 0)
        streams = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=duration",
                                  "-of", "csv=p=0", str(sess / "recording.mp4")], capture_output=True, text=True).stdout
        self.assertAlmostEqual(float(streams.split()[0]), meta["duration"], delta=1.0)

        t = json.loads((sess / "transcript.json").read_text())
        self.assertTrue(any("保存" in s["text"] for s in t["segments"]), t["segments"])
        r = subprocess.run([uv, "run", "-q", str(SCRIPTS / "transcribe.py"), "run", str(sess / "recording.mp4")],
                           env=env, capture_output=True, text=True)
        self.assertTrue(json.loads(r.stdout[r.stdout.index("{"):]).get("live"), r.stdout + r.stderr)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
