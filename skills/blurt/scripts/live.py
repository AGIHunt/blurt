# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "sherpa-onnx>=1.12", "truststore"]
# ///
"""Live pipeline while a recording runs: transcript (L1) and rolling item drafts (L2). docs/design/snap-and-live.md §4.

  live.py run <session> [--watch-pid PID]     started by the recorder when recording begins; exits by itself
  live.py simulate <audio> <session> [--speed N] [--run]
                                              feed an audio file into <session>/live/audio.pcm in real time (N× faster;
                                              0 = as fast as possible), then create live/stop — for tests and timing.
                                              --run also starts `live.py run` and reports stop → transcript latency
  live.py status <session>                    print live/status.json

`run` tails live/audio.pcm (16 kHz mono s16le, written by the recorder, pause-gated: byte offset / 32000 = video time),
cuts it at pauses with the same VAD and chunking as `transcribe.py run`, transcribes each chunk with the configured ASR
backend as soon as it closes, and appends live/transcript.jsonl. When live/stop appears it drains the rest and writes
<session>/transcript.json + transcript.txt — the same document `transcribe.py run` makes from the whole file (it then
returns instantly). Chunks are cut exactly where a whole-file run cuts them, so the text is the same.

Drafts: every ≥60 s of new speech (at a ≥3 s pause) or 3 min, a small model (claude -p --model claude-haiku-5-5, or
codex exec) gets the transcript so far + the current drafts and returns add/update/drop ops → live/drafts.jsonl.
A starting outline only. Config ($BLURT_HOME/config.json → record): live (default true), live_drafts (default true when
an agent CLI is installed), live_drafts_agent ("claude" | "codex"), live_drafts_model. Env BLURT_LIVE_DRAFTS_CMD = a
command that reads the prompt on stdin and prints the JSON answer (tests / other agents).

Files in <session>/live/: audio.pcm, stop (recorder) · transcript.jsonl, drafts.jsonl, status.json, live.log,
drafts.log (per-call latency / cost).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from _common import BLURT_HOME, IS_WIN, die, ffmpeg_bin, global_config, load_json, save_json  # noqa: E402

SR = 16000
BPS = SR * 2                    # bytes per second of audio.pcm
KINDS = ("issue", "idea", "note", "task")
DRAFT_MIN_SPEECH = 60           # s of new speech …
DRAFT_PAUSE = 3                 # … then at a pause this long
DRAFT_EVERY = 180               # or this long since the last call
DRAFT_TIMEOUT = 60
CLOSE_MARGIN = 1.0              # see LiveChunker


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def pid_alive(pid: int | None) -> bool:
    if not pid:
        return True
    if IS_WIN:
        import ctypes
        h = ctypes.windll.kernel32.OpenProcess(0x1000, False, int(pid))  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        code = ctypes.c_ulong()
        ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(code))
        ctypes.windll.kernel32.CloseHandle(h)
        return code.value == 259  # STILL_ACTIVE
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


# ------------------------------------------------------------------ chunking
class LiveChunker:
    """Streaming twin of transcribe.vad_segments + group_chunks: the same VAD fed the same windows, the same padding
    and the same greedy grouping, so the chunks (and the text) equal a whole-file run over the same samples.

    A chunk is closed when the next speech segment can't join it (gap > max_gap or too long) — exactly the
    whole-file rule — or early, once the stream is max_gap + CLOSE_MARGIN past its end and the VAD hears no speech:
    a later segment then starts after that gap (the VAD's look-back is ~0.3 s + 0.15 s padding), so it could not
    have joined anyway. Early closing is what makes captions appear ~2 s after a pause rather than at the next one."""

    def __init__(self, make_vad, max_chunk: float, max_gap: float = 1.0):
        from transcribe import pad_segment
        self.pad = pad_segment
        self.vad, self.win = make_vad(min(25, max_chunk))
        self.max_len, self.max_gap = max_chunk, max_gap
        self.rest = np.zeros(0, np.float32)
        self.fed = 0                      # samples given to the VAD
        self.cur: list[float] | None = None
        self.last_speech_end = 0.0

    @property
    def pos(self) -> float:
        return self.fed / SR

    def in_speech(self) -> bool:
        return bool(self.vad.is_speech_detected())

    def feed(self, x: np.ndarray) -> list[tuple[float, float]]:
        buf = np.concatenate([self.rest, x]) if len(self.rest) else x
        n = len(buf) // self.win * self.win
        out: list[tuple[float, float]] = []
        for i in range(0, n, self.win):
            self.vad.accept_waveform(buf[i:i + self.win])
            self.fed += self.win
            out += self._drain()
        self.rest = buf[n:]
        if self.cur and not self.in_speech() and self.pos > self.cur[1] + self.max_gap + CLOSE_MARGIN:
            out.append(tuple(self.cur))
            self.cur = None
        return out

    def finish(self, duration: float) -> list[tuple[float, float]]:
        out: list[tuple[float, float]] = []
        if len(self.rest):  # the whole-file run feeds the last partial window too
            self.vad.accept_waveform(self.rest)
            self.fed += len(self.rest)
            self.rest = np.zeros(0, np.float32)
        self.vad.flush()
        out += self._drain(duration)
        if self.cur:
            out.append(tuple(self.cur))
            self.cur = None
        return out

    def _drain(self, duration: float = float("inf")) -> list[tuple[float, float]]:
        out = []
        while not self.vad.empty():
            seg = self.vad.front
            s, e = self.pad(seg.start / SR, (seg.start + len(seg.samples)) / SR, duration)
            self.last_speech_end = (seg.start + len(seg.samples)) / SR
            self.vad.pop()
            if self.cur and s - self.cur[1] <= self.max_gap and e - self.cur[0] <= self.max_len:
                self.cur[1] = e
            else:
                if self.cur:
                    out.append(tuple(self.cur))
                self.cur = [s, e]
        return out


# ------------------------------------------------------------------ drafts (L2)
SYSTEM = """You keep a live outline of what a user says while recording their screen (product feedback, QA, ideas).
Kinds: issue = something in the product to fix or polish (bug, UI/UX, copy, perf). idea = something to build, change
or borrow. note = an observation or fact worth keeping. task = an action item that is not a product issue.
One item = one thing: merge revisits, drop retracted remarks, split compounds; pure narration is not an item.
Answer with JSON only: {"ops":[...]} where an op is
{"op":"add","kind":K,"title":T,"t":SECONDS,"confidence":"high"|"low"} |
{"op":"update","id":ID, any of kind/title/t/confidence} | {"op":"drop","id":ID}.
t = when it is said (seconds, from the transcript). Titles: short (<= 12 words), in the language the user speaks.
Change only what the new speech changes; {"ops":[]} if nothing."""

STRIP_ENV = ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SIMPLE", "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH",
             "CLAUDE_CODE_OAUTH_SCOPES", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_HOST_SESSION_ID", "CLAUDE_CODE_EXECPATH",
             "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN")


def agent_env() -> dict:
    """The env of a host agent session (Claude Code / desktop) must not leak into a nested `claude -p`."""
    hosted = any(k in os.environ for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"))
    env = {k: v for k, v in os.environ.items()
           if k not in STRIP_ENV and not k.startswith("CLAUDE_AGENT_SDK")
           and not (k.startswith("USE_") and k.endswith("_OAUTH"))
           and not (hosted and k == "ANTHROPIC_BASE_URL")}
    return env


def fmt_t(t: float) -> str:
    return f"{int(t // 60):02d}:{t % 60:04.1f}"


def extract_json(text: str):
    text = (text or "").strip()
    m = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    if m:
        text = m.group(1).strip()
    a, b = text.find("{"), text.rfind("}")
    if a < 0 or b <= a:
        raise ValueError("no JSON object in the answer")
    return json.loads(text[a:b + 1])


def apply_ops(drafts: dict, answer, duration: float, next_id: int) -> tuple[list[dict], list[str], int]:
    """Validate the model's ops against the current drafts. Returns (drafts.jsonl lines, problems, next id).
    Mutates `drafts` ({id: {id, kind, title, t, confidence}}). New ids are ours (d1, d2, …), never the model's."""
    lines, problems = [], []
    ops = answer.get("ops") if isinstance(answer, dict) else answer if isinstance(answer, list) else None
    if not isinstance(ops, list):
        return [], ["answer has no ops list"], next_id

    def clean_t(v, default):
        try:
            v = float(v)
        except (TypeError, ValueError):
            return default
        return round(min(max(0.0, v), max(duration, 0.0)), 1) if v == v else default

    def clean_title(v):
        return re.sub(r"\s+", " ", v).strip()[:120] if isinstance(v, str) else ""

    for i, op in enumerate(ops[:30]):
        if not isinstance(op, dict) or op.get("op") not in ("add", "update", "drop"):
            problems.append(f"op {i}: not an add/update/drop object")
            continue
        kind = op.get("kind")
        conf = op.get("confidence")
        if op["op"] == "add":
            title = clean_title(op.get("title"))
            if kind not in KINDS or not title:
                problems.append(f"op {i}: add needs kind in {KINDS} and a title")
                continue
            d = {"id": f"d{next_id}", "kind": kind, "title": title, "t": clean_t(op.get("t"), round(duration, 1)),
                 "confidence": conf if conf in ("high", "low") else "high"}
            next_id += 1
            drafts[d["id"]] = d
            lines.append({"op": "add", **d})
            continue
        did = str(op.get("id", ""))
        if did not in drafts:
            problems.append(f"op {i}: unknown id {did!r}")
            continue
        d = drafts[did]
        if op["op"] == "drop":
            drafts.pop(did)
            lines.append({"op": "drop", **d})
            continue
        upd = dict(d)
        if kind is not None:
            if kind not in KINDS:
                problems.append(f"op {i}: bad kind {kind!r}")
                continue
            upd["kind"] = kind
        if op.get("title") is not None and clean_title(op.get("title")):
            upd["title"] = clean_title(op["title"])
        if op.get("t") is not None:
            upd["t"] = clean_t(op["t"], d["t"])
        if conf in ("high", "low"):
            upd["confidence"] = conf
        if upd != d:
            drafts[did] = upd
            lines.append({"op": "update", **upd})
    # contract field order: {"id","op","kind","title","t","confidence"}
    order = ("id", "op", "kind", "title", "t", "confidence")
    return [{k: ln[k] for k in order} for ln in lines], problems, next_id


def build_prompt(drafts: dict, segments: list[dict], sent_upto: float, budget: int = 6000) -> str:
    cur = "\n".join(f"- {d['id']} [{d['kind']}] t={d['t']:.0f} {d['title']}" for d in drafts.values()) or "(none yet)"
    lines = [f"[{s['start']:.0f}] {s['text']}" for s in segments]
    text = "\n".join(lines)
    if len(text) > budget:  # long recording: the drafts stand in for the old part; send the new part + 60 s context
        keep = [f"[{s['start']:.0f}] {s['text']}" for s in segments if s["end"] >= sent_upto - 60]
        text = "(earlier speech is covered by the drafts)\n" + "\n".join(keep)[-budget:]
    return f"Current drafts:\n{cur}\n\nTranscript so far ([seconds] text):\n{text}\n"


class Drafter:
    def __init__(self, live: Path, enabled: bool | None = None):
        self.live = live
        cfg = global_config().get("record", {})
        self.cmd_env = os.environ.get("BLURT_LIVE_DRAFTS_CMD")
        self.agents = [] if self.cmd_env else self._agents(cfg)
        want = cfg.get("live_drafts")
        self.enabled = (want is not False) and bool(self.cmd_env or self.agents) if enabled is None else enabled
        self.model = cfg.get("live_drafts_model")
        self.state = "running" if self.enabled else "off"
        self.note = "" if self.enabled else ("disabled (record.live_drafts)" if want is False else "no agent CLI found")
        self.reset()
        self.ready = threading.Event()
        if self.enabled and self.agents:  # which CLIs are logged in: checked once, in the background
            threading.Thread(target=self._check_logins, daemon=True).start()
        else:
            self.ready.set()

    def _check_logins(self) -> None:
        ok, why = [], []
        for name, path in self.agents:
            try:
                if name == "claude":
                    p = subprocess.run([path, "auth", "status", "--json"], capture_output=True, text=True,
                                       encoding="utf-8", errors="replace", timeout=20, env=agent_env(),
                                       stdin=subprocess.DEVNULL)
                    try:
                        good = bool(json.loads(p.stdout).get("loggedIn"))
                    except (json.JSONDecodeError, AttributeError):  # older CLI without --json
                        good = p.returncode == 0 and "not logged in" not in (p.stdout + p.stderr).lower()
                else:
                    p = subprocess.run([path, "login", "status"], capture_output=True, text=True, encoding="utf-8",
                                       errors="replace", timeout=20, env=agent_env(), stdin=subprocess.DEVNULL)
                    good = p.returncode == 0 and "logged in" in (p.stdout + p.stderr).lower() \
                        and "not logged in" not in (p.stdout + p.stderr).lower()
            except (OSError, subprocess.TimeoutExpired):
                good = False
            (ok if good else why).append((name, path) if good else f"{name}: not logged in")
        self.agents = ok
        if not ok:
            self.enabled, self.state = False, "off"
            self.note = "no logged-in agent CLI (" + "; ".join(why) + ")"
        else:
            self.note = f"via {ok[0][0]}"
        log(f"drafts: {self.note}")
        self.ready.set()

    def model_for(self, agent: str) -> str | None:
        m = self.model
        if agent == "claude":
            return m if m and m.startswith(("claude", "haiku", "sonnet", "opus")) else "claude-haiku-5-5"
        if m and not m.startswith(("claude", "haiku", "sonnet", "opus")):
            return m
        return codex_small_model()

    def reset(self):
        self.drafts: dict = {}
        self.next_id = 1
        self.sent_upto = 0.0
        self.last_call = time.time()
        self.thread: threading.Thread | None = None
        self.calls = 0
        self.gen = getattr(self, "gen", 0) + 1

    @staticmethod
    def _agents(cfg) -> list[tuple[str, str]]:
        order = [cfg.get("live_drafts_agent"), cfg.get("process"), "claude", "codex"]
        out = []
        for name in dict.fromkeys(n for n in order if n in ("claude", "codex")):
            path = shutil.which(name)
            if path:
                out.append((name, path))
        return out

    def busy(self) -> bool:
        return bool(self.thread and self.thread.is_alive())

    def maybe(self, segments: list[dict], pos: float, in_speech: bool, last_speech_end: float) -> None:
        if not self.enabled or not self.ready.is_set() or self.busy() or not segments:
            return
        new = [s for s in segments if s["end"] > self.sent_upto]
        if not new:
            return
        new_speech = sum(s["end"] - max(s["start"], self.sent_upto) for s in new)
        paused = not in_speech and pos - max(last_speech_end, new[-1]["end"]) >= DRAFT_PAUSE
        if (new_speech >= DRAFT_MIN_SPEECH and paused) or time.time() - self.last_call >= DRAFT_EVERY:
            self.start(list(segments), pos)

    def start(self, segments: list[dict], pos: float) -> None:
        prompt = build_prompt(self.drafts, segments, self.sent_upto)
        upto = segments[-1]["end"]
        self.last_call = time.time()
        gen = self.gen
        self.thread = threading.Thread(target=self._call, args=(prompt, upto, pos, gen), daemon=True)
        self.thread.start()

    def _call(self, prompt: str, upto: float, pos: float, gen: int) -> None:
        t0 = time.time()
        rec = {"at": round(t0, 1), "upto": round(upto, 1), "prompt_chars": len(prompt)}
        try:
            text, meta = self._ask(prompt)
            rec.update(meta)
            answer = extract_json(text)
            if gen != self.gen:
                return  # the take was restarted meanwhile
            lines, problems, self.next_id = apply_ops(self.drafts, answer, pos, self.next_id)
            with open(self.live / "drafts.jsonl", "a", encoding="utf-8") as fh:
                for ln in lines:
                    fh.write(json.dumps(ln, ensure_ascii=False) + "\n")
            self.sent_upto = max(self.sent_upto, upto)
            self.calls += 1
            self.state, self.note = "running", f"{len(self.drafts)} drafts"
            rec.update(ops=len(lines), problems=problems[:5])
        except Exception as e:  # never let drafts disturb the transcript
            self.state, self.note = "error", f"drafts call failed: {str(e)[:200]}"
            rec["error"] = str(e)[:500]
            log(self.note)
        finally:
            rec["seconds"] = round(time.time() - t0, 1)
            try:
                if self.live.exists():
                    with open(self.live / "drafts.log", "a", encoding="utf-8") as fh:
                        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            except OSError:
                pass

    def _ask(self, prompt: str) -> tuple[str, dict]:
        cwd = BLURT_HOME / "tmp"  # outside the project: no CLAUDE.md / AGENTS.md pulled into a tiny call
        cwd.mkdir(parents=True, exist_ok=True)
        if self.cmd_env:
            p = subprocess.run(shlex.split(self.cmd_env), input=SYSTEM + "\n\n" + prompt, capture_output=True, text=True,
                               encoding="utf-8", timeout=DRAFT_TIMEOUT, cwd=cwd)
            if p.returncode:
                raise RuntimeError(f"exit {p.returncode}: {p.stderr[-300:]}")
            return p.stdout, {"agent": "cmd"}
        last = None
        for name, path in list(self.agents):
            try:
                out = self._claude(path, prompt, cwd) if name == "claude" else self._codex(path, prompt, cwd)
                if self.agents[0][0] != name:  # remember what works
                    self.agents.sort(key=lambda a: a[0] != name)
                return out
            except subprocess.TimeoutExpired:
                raise RuntimeError(f"{name}: no answer in {DRAFT_TIMEOUT}s")
            except AuthError as e:
                last = e
                self.agents = [a for a in self.agents if a[0] != name]  # not logged in: don't retry every call
                log(f"{name}: {e} — trying the next agent CLI")
        if not self.agents:
            self.enabled, self.state = False, "error"
        raise RuntimeError(str(last) if last else "no agent CLI")

    def _claude(self, path: str, prompt: str, cwd: Path) -> tuple[str, dict]:
        cmd = [path, "-p", "--model", self.model_for("claude"), "--output-format", "json",
               "--system-prompt", SYSTEM, "--tools", "", "--strict-mcp-config", "--no-session-persistence",
               "--disable-slash-commands", prompt]
        p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace",
                           stdin=subprocess.DEVNULL, timeout=DRAFT_TIMEOUT, cwd=cwd, env=agent_env())
        try:
            env = json.loads(p.stdout)
        except json.JSONDecodeError:
            if "login" in (p.stdout + p.stderr).lower():
                raise AuthError("claude is not logged in")
            raise RuntimeError(f"claude exit {p.returncode}: {(p.stderr or p.stdout)[-300:]}")
        if env.get("is_error"):
            msg = str(env.get("result") or env.get("subtype"))
            if "log in" in msg.lower() or "login" in msg.lower() or "logged in" in msg.lower():
                raise AuthError(f"claude: {msg}")
            raise RuntimeError(f"claude: {msg[:300]}")
        u = env.get("usage") or {}
        return env.get("result") or "", {"agent": "claude", "cost_usd": env.get("total_cost_usd"),
                                         "input_tokens": (u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0)
                                         + (u.get("cache_creation_input_tokens") or 0),
                                         "output_tokens": u.get("output_tokens"), "api_ms": env.get("duration_api_ms")}

    def _codex(self, path: str, prompt: str, cwd: Path) -> tuple[str, dict]:
        outf = cwd / f"codex-{os.getpid()}.txt"
        outf.unlink(missing_ok=True)
        # --ignore-user-config: no MCP servers / notify hooks / personal model defaults for a tiny call (~17 s vs ~30 s)
        cmd = [path, "exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--json",
               "--ignore-user-config", "--ignore-rules", "-c", 'model_reasoning_effort="low"', "-o", str(outf)]
        if self.model_for("codex"):
            cmd += ["-m", self.model_for("codex")]
        p = subprocess.run(cmd + ["-"], input=SYSTEM + "\n\n" + prompt, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=DRAFT_TIMEOUT, cwd=cwd, env=agent_env())
        text = outf.read_text(encoding="utf-8") if outf.exists() else ""
        outf.unlink(missing_ok=True)
        if p.returncode or not text:
            blob = (p.stderr + p.stdout)[-400:]
            if "login" in blob.lower() or "unauthorized" in blob.lower():
                raise AuthError("codex is not logged in")
            raise RuntimeError(f"codex exit {p.returncode}: {blob}")
        meta = {"agent": "codex"}
        for line in p.stdout.splitlines():  # turn.completed carries token usage
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            u = ev.get("usage") if isinstance(ev, dict) else None
            if isinstance(u, dict):
                meta.update(input_tokens=u.get("input_tokens"), cached_tokens=u.get("cached_input_tokens"),
                            output_tokens=u.get("output_tokens"))
        return text, meta


class AuthError(RuntimeError):
    pass


def codex_small_model() -> str | None:
    """Codex has no stable 'small' alias: pick the listed fast/affordable model from its own model cache."""
    cache = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex") / "models_cache.json"
    try:
        d = json.loads(cache.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    models = d.get("models", []) if isinstance(d, dict) else d if isinstance(d, list) else []
    for m in models:
        if not isinstance(m, dict) or m.get("visibility") not in (None, "list"):
            continue
        desc = f"{m.get('slug', '')} {m.get('description', '')}".lower()
        if ("fast" in desc and ("affordable" in desc or "easier" in desc)) or "mini" in desc:
            if "older" not in desc and "previous" not in desc:
                return m.get("slug")
    return None


# ------------------------------------------------------------------ the live run
class Discarded(Exception):
    pass


class LiveRun:
    def __init__(self, session: Path, watch_pid: int | None = None, backend=None, make_vad=None, name: str | None = None,
                 drafter: Drafter | None = None, workers: int | None = None):
        self.session, self.live = session, session / "live"
        self.pcm, self.stop_file = self.live / "audio.pcm", self.live / "stop"
        self.watch_pid = watch_pid
        self.backend, self.name, self._make_vad = backend, name, make_vad
        self.drafter = drafter
        self.workers = workers
        self.asr, self.note = "running", ""
        self.last_status = 0.0
        self.decode_seconds = 0.0

    # --- status.json: {"asr","drafts","updated","note"} (+ audio_seconds, pid)
    def status(self, force: bool = False) -> None:
        if not force and time.time() - self.last_status < 1:
            return
        self.last_status = time.time()
        if not self.live.is_dir():
            return  # discarded: never recreate the folder
        d = self.drafter
        st = {"asr": self.asr, "drafts": d.state if d else "off", "updated": round(time.time(), 2),
              "note": "; ".join(x for x in (self.note, f"drafts: {d.note}" if d and d.note else "") if x),
              "audio_seconds": round(getattr(self, "offset", 0) / BPS, 1), "pid": os.getpid()}
        try:
            save_json(self.live / "status.json", st)
        except OSError:
            pass

    def reset(self) -> None:
        from transcribe import make_vad
        self.offset, self.ino = 0, None
        self.segments: list[dict] = []
        self.speech = self.blank = 0.0
        self.chunker = LiveChunker(self._make_vad or make_vad, self.backend.max_chunk)
        self.pending: deque = deque()
        for f in ("transcript.jsonl", "drafts.jsonl"):
            p = self.live / f
            if self.live.is_dir():
                p.write_text("", encoding="utf-8")
        if self.drafter:
            self.drafter.reset()

    def read_slice(self, s: float, e: float) -> np.ndarray:
        a, b = int(s * SR), int(e * SR)
        with open(self.pcm, "rb") as fh:
            fh.seek(a * 2)
            raw = fh.read((b - a) * 2)
        return np.frombuffer(raw[:len(raw) // 2 * 2], dtype=np.int16).astype(np.float32) / 32768

    def submit(self, chunks) -> None:
        from transcribe import decode_slice
        for s, e in chunks:
            x = self.read_slice(s, e)
            self.speech += e - s

            def work(x=x, s=s, e=e):
                t0 = time.time()
                r = decode_slice(self.backend, x, s, e)
                return r, time.time() - t0
            self.pending.append(((s, e), self.pool.submit(work)))

    def commit(self, wait: bool = False) -> None:
        from transcribe import is_blank
        while self.pending and (wait or self.pending[0][1].done()):
            (s, e), fut = self.pending.popleft()
            r, secs = fut.result()
            self.decode_seconds += secs
            if is_blank(r):
                self.blank += e - s
            lines = [{"start": round(a, 2), "end": round(b, 2), "text": t} for a, b, t in r if t]
            self.segments += lines
            if lines and self.live.is_dir():
                with open(self.live / "transcript.jsonl", "a", encoding="utf-8") as fh:
                    for ln in lines:
                        fh.write(json.dumps(ln, ensure_ascii=False) + "\n")

    def pull(self) -> bool:
        """Read what the recorder appended. False when nothing new. Raises Discarded when live/ went away."""
        try:
            st = self.pcm.stat()
        except FileNotFoundError:
            raise Discarded()
        if self.ino is not None and (st.st_ino != self.ino or st.st_size < self.offset):
            log("audio.pcm was restarted (new take) — starting over")
            self.reset()
        self.ino = st.st_ino
        n = (st.st_size - self.offset) // 2 * 2
        if n <= 0:
            return False
        with open(self.pcm, "rb") as fh:
            fh.seek(self.offset)
            raw = fh.read(n)
        n = len(raw) // 2 * 2
        self.offset += n
        x = np.frombuffer(raw[:n], dtype=np.int16).astype(np.float32) / 32768
        for i in range(0, len(x), SR * 5):  # big backlog (slow start): keep chunks flowing
            self.submit(self.chunker.feed(x[i:i + SR * 5]))
            self.commit()
        return True

    def wait_for_take(self, timeout: float) -> bool:
        t0 = time.time()
        seen = self.session.exists()
        while time.time() - t0 < timeout:
            if self.pcm.exists():
                return True
            seen = seen or self.session.exists()
            if (seen and not self.session.exists()) or not pid_alive(self.watch_pid):
                return False
            time.sleep(0.2)
        return False

    def run(self) -> int:
        if not self.wait_for_take(60):
            log("no live/audio.pcm appeared — nothing to do")
            return 0
        self.offset = 0
        self.pool = ThreadPoolExecutor(self.workers or 1)
        self.reset()
        self.status(force=True)
        dead_since = None
        while True:
            try:
                got = self.pull()
                self.commit()
                if self.drafter:
                    self.drafter.maybe(self.segments, self.chunker.pos, self.chunker.in_speech(),
                                       self.chunker.last_speech_end)
                self.status()
                if self.stop_file.exists():
                    self.pull()
                    return self.finish()
                if not pid_alive(self.watch_pid):  # the recorder died without a stop: keep what was said
                    dead_since = dead_since or time.time()
                    if time.time() - dead_since > 3:
                        log("recorder exited without live/stop — finishing anyway")
                        return self.finish()
                if not got:
                    time.sleep(0.1)
            except Discarded:
                if not self.session.exists():
                    log("session removed (discarded) — exiting")
                    return 0
                log("live/ removed (discarded / restarting) — waiting for a new take")
                if not self.wait_for_take(30):
                    return 0
                self.reset()
                self.status(force=True)

    def finish(self) -> int:
        from transcribe import build_transcript, write_transcript
        duration = self.offset / BPS
        self.submit(self.chunker.finish(duration))
        self.commit(wait=True)
        recs = sorted(self.session.glob("recording.*"))
        source = recs[0].name if recs else "recording.mp4"
        results = [(s["start"], s["end"], s["text"], None) for s in self.segments]

        class A:  # what build_transcript wants to know about the run's options
            model = None
        data = build_transcript(source, self.name, self.backend, A, duration, self.speech, self.blank, results,
                                self.decode_seconds)
        files = write_transcript(self.session, data)
        self.asr, self.note = "done", f"{len(data['segments'])} segments, {duration:.0f}s"
        self.status(force=True)
        log(f"transcript written: {files[0]} ({len(data['segments'])} segments)")
        d = self.drafter
        if d and d.busy():
            d.thread.join(DRAFT_TIMEOUT + 5)
        if d:
            d.state = "off" if d.state != "error" else "error"
            d.note = d.note or "recording finished"
        self.status(force=True)
        self.pool.shutdown(wait=False)
        return 0


# ------------------------------------------------------------------ commands
def asr_setup():
    """(name, backend, workers) for the configured ASR, or (None, reason, 0) when it can't run here right now."""
    import transcribe as T

    class A:
        backend = model = language = prompt = None
        concurrency = 4
        threads = min(4, os.cpu_count() or 4)  # leave CPU to the app being recorded

    a = A()
    name = T.resolve_backend(a)
    why = T.backend_ready(name)
    if why:
        return None, why, 0
    pkg = T.EXTRA_PACKAGES.get(name)
    if pkg:
        import importlib.util
        if importlib.util.find_spec(pkg) is None:
            uv = shutil.which("uv")
            if uv and not os.environ.get("BLURT_LIVE_REEXEC"):
                os.environ["BLURT_LIVE_REEXEC"] = "1"
                os.execvp(uv, [uv, "run", "-q", "--with", name, __file__, *sys.argv[1:]])
            return None, f"{name} is not installed (uv run --with {name})", 0
    return name, T.BACKENDS[name](a), 1 if name in T.LOCAL else a.concurrency


def cmd_run(a) -> int:
    session = Path(a.session).resolve()
    live = session / "live"
    os.environ["BLURT_NO_DOWNLOAD"] = "1"
    if global_config().get("record", {}).get("live") is False:
        log("record.live is false — off")
        return 0
    run = LiveRun(session, a.watch_pid)
    if not run.wait_for_take(60):
        log("no live/audio.pcm appeared — nothing to do")
        return 0
    try:
        name, backend, workers = asr_setup()
    except SystemExit as e:  # die() inside a backend (missing key, model) — the recording must not notice
        name, backend, workers = None, f"ASR setup failed ({e})", 0
    if name is None:
        # no usable ASR: say so and get out of the way (the audio sidecar isn't needed then)
        run.asr, run.note = "off", str(backend)
        run.status(force=True)
        log(f"ASR off: {backend}")
        while live.is_dir() and not (live / "stop").exists() and pid_alive(a.watch_pid):
            time.sleep(1)
            run.status()
        (live / "audio.pcm").unlink(missing_ok=True)
        return 0
    run.backend, run.name, run.workers = backend, name, workers
    run.drafter = Drafter(live)
    log(f"live: {name}, drafts {run.drafter.state}{' via ' + run.drafter.agents[0][0] if run.drafter.agents else ''}")
    try:
        return run.run()
    except Exception as e:
        run.asr, run.note = "error", f"{type(e).__name__}: {e}"[:300]
        run.status(force=True)
        raise


def cmd_simulate(a) -> int:
    src, session = Path(a.audio), Path(a.session).resolve()
    if not src.exists():
        die(f"{src} not found")
    live = session / "live"
    live.mkdir(parents=True, exist_ok=True)
    for f in ("stop", "status.json", "transcript.jsonl", "drafts.jsonl"):
        (live / f).unlink(missing_ok=True)
    (session / "transcript.json").unlink(missing_ok=True)
    raw = subprocess.run([ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-i", str(src), "-ac", "1", "-ar", str(SR),
                          "-f", "s16le", "-"], capture_output=True).stdout
    if not raw:
        die(f"no audio decoded from {src}")
    proc = None
    with open(live / "audio.pcm", "wb") as fh:
        if a.run:
            proc = subprocess.Popen([sys.executable, __file__, "run", str(session), "--watch-pid", str(os.getpid())])
        step = BPS // 10  # 100 ms, like the recorder
        t0 = time.time()
        for i in range(0, len(raw), step):
            fh.write(raw[i:i + step])
            fh.flush()
            if a.speed > 0:
                time.sleep(max(0.0, t0 + (i + step) / BPS / a.speed - time.time()))
    feed_s = time.time() - t0
    (live / "stop").touch()
    t_stop = time.time()
    out = {"audio_seconds": round(len(raw) / BPS, 1), "feed_seconds": round(feed_s, 1), "pcm": str(live / "audio.pcm")}
    if proc:
        while proc.poll() is None and (load_json(live / "status.json", {}) or {}).get("asr") != "done":
            time.sleep(0.05)
        out["stop_to_transcript_seconds"] = round(time.time() - t_stop, 2)
        out["transcript"] = str(session / "transcript.json") if (session / "transcript.json").exists() else None
        proc.wait(timeout=DRAFT_TIMEOUT + 30)
        out["exit"] = proc.returncode
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


def cmd_status(a) -> int:
    print(json.dumps(load_json(Path(a.session) / "live" / "status.json", {}) or {"asr": None}, ensure_ascii=False, indent=2))
    return 0


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="tail <session>/live/audio.pcm until live/stop")
    r.add_argument("session")
    r.add_argument("--watch-pid", type=int, help="the recorder's pid: if it dies without live/stop, finish anyway")
    s = sub.add_parser("simulate", help="write an audio file into <session>/live/audio.pcm in real time, then stop")
    s.add_argument("audio")
    s.add_argument("session")
    s.add_argument("--speed", type=float, default=1.0, help="N× real time; 0 = as fast as possible")
    s.add_argument("--run", action="store_true", help="also run `live.py run` and time stop → transcript.json")
    st = sub.add_parser("status")
    st.add_argument("session")
    a = p.parse_args()
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit({"run": cmd_run, "simulate": cmd_simulate, "status": cmd_status}[a.cmd](a))


if __name__ == "__main__":
    main()
