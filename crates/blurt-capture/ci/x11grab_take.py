"""WP8 acceptance (CI, X11 under xvfb): a 5 s x11grab take through `record.py start --engine ffmpeg --status-jsonl`
without a microphone, a snap during it, then checks the status line sequence and the files (§5 C8).

  python3 crates/blurt-capture/ci/x11grab_take.py OUT_DIR       (uses `uv run`; DISPLAY must be set)
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RECORD = ROOT / "skills" / "blurt" / "scripts" / "record.py"


def main() -> int:
    out = Path(sys.argv[1]).resolve()
    shutil.rmtree(out, ignore_errors=True)
    home, session = out / "home", out / "session"
    home.mkdir(parents=True)
    (home / "config.json").write_text(json.dumps({"record": {"install_app": False, "live": False}}))
    env = dict(os.environ, BLURT_HOME=str(home))
    uv = [shutil.which("uv") or "uv", "run", "-q", str(RECORD)]
    p = subprocess.Popen([*uv, "start", "--engine", "ffmpeg", "--session", str(session), "--region", "0,0,640,360",
                          "--no-mic", "--status-jsonl"], env=env, stdout=subprocess.PIPE, stderr=open(out / "stderr.log", "w"),
                         text=True)
    lines: list[dict] = []

    def until(ev: str) -> dict:
        while True:
            raw = p.stdout.readline()
            if not raw:
                raise SystemExit(f"stdout closed before {ev!r}: {lines}\n{(out / 'stderr.log').read_text()[-2000:]}")
            e = json.loads(raw)  # stdout must be JSON lines only
            lines.append(e)
            print("status:", e, flush=True)
            if e["ev"] == ev:
                return e
            if e["ev"] in ("error", "stopped", "discarded"):
                raise SystemExit(f"unexpected final line {e} while waiting for {ev}")

    until("started")
    t0 = time.time()
    time.sleep(2)
    subprocess.run([*uv, "snap"], env=env, check=True, capture_output=True)
    until("snap")
    time.sleep(max(0.0, 5 - (time.time() - t0)))
    subprocess.run([*uv, "stop"], env=env, check=True, capture_output=True, timeout=120)
    stopped = until("stopped")
    rest = p.stdout.read()
    code = p.wait(timeout=60)

    problems = []
    if code != 0:
        problems.append(f"exit code {code}")
    if rest.strip():
        problems.append(f"lines after the final one: {rest!r}")
    if [e["ev"] for e in lines] != ["started", "snap", "stopped"]:
        problems.append(f"sequence {[e['ev'] for e in lines]}")
    if not 4.0 <= stopped.get("duration", 0) <= 8.0:
        problems.append(f"duration {stopped.get('duration')}")
    for f in ("recording.mp4", "events.jsonl", "meta.json", "shots.jsonl", "shots/001.png"):
        if not (session / f).is_file():
            problems.append(f"missing {f}")
    if (session / "shots.jsonl").is_file():
        line = json.loads((session / "shots.jsonl").read_text().splitlines()[0])
        want = {"n", "file", "marked", "t", "wall", "region", "voice", "text", "strokes"}
        if set(line) != want or line["file"] != "shots/001.png" or line["region"] != [0, 0, 640, 360]:
            problems.append(f"shots.jsonl line {line}")
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=width,height",
                            "-of", "csv=p=0", str(session / "recording.mp4")], capture_output=True, text=True).stdout
    if probe.strip() != "640,360":
        problems.append(f"video size {probe.strip()!r}")
    print(json.dumps({"lines": lines, "problems": problems}, indent=2))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
