"""Feedback reports (docs/design/feedback.md): the bundle feedback.py builds (what goes in, the context left out on
request, the size refusal), sending it (against a local stub of the Worker), the Lab import of an unpacked report, and
tools/feedback/pull.py against a stub of the admin routes. Mock data only; no network beyond 127.0.0.1.

  uv run --with pytest pytest tests/test_feedback.py -q
"""
from __future__ import annotations

import io
import json
import os
import stat
import subprocess
import sys
import threading
import wave
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(ROOT / "tools" / "feedback"))
import dictation_lab as L  # noqa: E402
import feedback as F  # noqa: E402
import pull as P  # noqa: E402

RID = "abcdefghijklmnopqrstuvwxyz"       # a report id's shape: 26 base32 characters


def tone(path: Path, seconds: float) -> Path:
    import array
    import math
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(array.array("h", (int(8000 * math.sin(i / 7)) for i in range(int(seconds * 16000)))).tobytes())
    return path


def make_home(h: Path) -> Path:
    """A sender's $BLURT_HOME: three takes (one with a recording and context, one whose recording is gone, one
    deleted), a correction, an edit line naming another take too, settings with a key that must not ride along."""
    d = h / "dictation"
    (d / "audio").mkdir(parents=True)
    tone(d / "audio" / "t-1.wav", 1.0)
    rows = [{"op": "delete", "ids": ["t-old", "t-2"]},     # before t-2 exists: no effect, but it names t-2
            {"id": "t-1", "t": "2026-10-24T10:00:00+08:00", "app": "Notes", "bundle": "com.apple.Notes", "duration": 1.0,
             "raw": "use cloud code", "polished": "Use Claude Code.", "text": "Use Claude Code.", "model": "gemma4-e2b",
             "asr_model": "qwen3-asr-1.7b-mlx", "audio": "audio/t-1.wav", "context": "Doc — before text|[sel]after text"},
            {"id": "t-2", "t": "2026-10-24T10:01:00+08:00", "app": "Mail", "duration": 2.0, "raw": "second take",
             "text": "Second take.", "audio": "audio/t-2.wav"},
            {"id": "t-3", "t": "2026-10-24T10:02:00+08:00", "app": "Mail", "duration": 1.0, "raw": "gone", "text": "Gone."},
            {"op": "correct", "id": "t-1", "text": "Use Claude Code!"},
            {"op": "delete", "ids": ["t-3"]},
            {"id": "t-9", "t": "2026-10-24T10:03:00+08:00", "app": "Chat", "raw": "not chosen", "text": "Not chosen."}]
    (d / "history.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    (h / "config.json").write_text(json.dumps({"record": {"dictation": {"keep_audio": True, "polish": "light",
                                                                        "cloud": {"api_key": "sk-mock"}}}}))
    (d / "vocabulary.json").write_text(json.dumps({"schema": 2, "terms": [
        {"term": "Claude Code", "sounds_like": ["cloud code"], "state": "active", "source": "learned"},
        {"term": "Nope", "state": "rejected"}]}))
    return h


@pytest.fixture()
def home(tmp_path, monkeypatch):
    h = make_home(tmp_path / "home")
    monkeypatch.setenv("BLURT_HOME", str(h))
    monkeypatch.setenv("NO_PROXY", "127.0.0.1,localhost")
    monkeypatch.setenv("no_proxy", "127.0.0.1,localhost")
    monkeypatch.setattr(F, "models", lambda s: {"asr": "mock-asr", "polish": "mock-polish"})
    return h


def bundle(tmp_path: Path, ids=("t-1", "t-2"), context=True) -> tuple[dict, zipfile.ZipFile]:
    out = tmp_path / f"b-{int(context)}.zip"
    r = F.build(list(ids), context, out, "1.0.3", "42")
    return r, zipfile.ZipFile(out)


# ------------------------------------------------------------------ the bundle
def test_bundle_holds_report_history_and_kept_audio(home, tmp_path):
    r, z = bundle(tmp_path)
    assert sorted(z.namelist()) == ["audio/t-1.wav", "history.jsonl", "report.json"]
    rep = json.loads(z.read("report.json"))
    assert rep["schema"] == 1 and rep["platform"] in ("macos", "linux", "windows")
    assert rep["app"] == {"version": "1.0.3", "build": "42"}
    assert set(rep["device"]) >= {"os", "os_version", "arch", "model", "chip", "cores", "memory_gb", "locale"}
    assert rep["takes"] == [{"id": "t-1", "audio": "audio/t-1.wav"}, {"id": "t-2", "audio": None}]   # t-2: text only
    assert rep["context_included"] is True and rep["models"] == {"asr": "mock-asr", "polish": "mock-polish"}
    assert rep["dictation"] == {"keep_audio": True, "polish": "light", "cloud": {}}                   # no key
    assert rep["terms"] == [{"term": "Claude Code", "sounds_like": ["cloud code"], "source": "learned"}]
    lines = [json.loads(x) for x in z.read("history.jsonl").decode().splitlines()]
    assert lines[0] == {"op": "delete", "ids": ["t-2"]}             # only the chosen takes named
    assert [x.get("id") for x in lines[1:]] == ["t-1", "t-2", "t-1"]
    assert lines[3] == {"op": "correct", "id": "t-1", "text": "Use Claude Code!"}
    raw = (home / "dictation" / "history.jsonl").read_text().splitlines()
    assert z.read("history.jsonl").decode().splitlines()[1] == raw[1]   # entry lines as written
    assert "Not chosen" not in z.read("history.jsonl").decode()
    assert z.read("audio/t-1.wav") == (home / "dictation" / "audio" / "t-1.wav").read_bytes()
    assert [t["has_audio"] for t in r["takes"]] == [True, False] and r["takes"][0]["has_context"] is True
    assert r["takes"][0]["text"] == "Use Claude Code." and r["bytes"] == (tmp_path / "b-1.zip").stat().st_size


def test_no_context_strips_it_from_every_line(home, tmp_path):
    _, z = bundle(tmp_path, context=False)
    text = z.read("history.jsonl").decode()
    assert "context" not in text and "before text" not in text
    assert json.loads(z.read("report.json"))["context_included"] is False
    assert json.loads(text.splitlines()[1])["raw"] == "use cloud code"       # the rest of the line kept


def test_preview_cli_and_unknown_ids(home):
    env = {**os.environ, "BLURT_HOME": str(home)}
    run = lambda *a: subprocess.run([sys.executable, str(SCRIPTS / "feedback.py"), *a], capture_output=True, text=True, env=env)  # noqa: E731
    r = run("preview", "--ids", "t-1,t-2", "--no-context")
    o = json.loads(r.stdout.splitlines()[-1])
    assert r.returncode == 0 and o["ok"] and o["limit"] == 100_000_000 and [t["id"] for t in o["takes"]] == ["t-1", "t-2"]
    assert o["takes"][0]["has_context"] is False and o["bytes"] > o["takes"][0]["bytes"] > 32000
    r = run("preview", "--ids", "t-1,t-3")                  # t-3 was deleted
    assert r.returncode == 1 and json.loads(r.stdout)["code"] == "not_found"


def test_audio_path_outside_the_dictation_folder_is_not_sent(home, tmp_path):
    (tmp_path / "secret.wav").write_bytes(b"RIFF")
    hist = home / "dictation" / "history.jsonl"
    hist.write_text(hist.read_text() + json.dumps({"id": "t-x", "t": "2026-10-24T11:00:00+08:00", "raw": "x", "text": "x",
                                                   "audio": "../../secret.wav"}) + "\n")
    _, z = bundle(tmp_path, ids=["t-x"])
    assert z.namelist() == ["report.json", "history.jsonl"]


# ------------------------------------------------------------------ sending
class Stub:
    """The Worker's upload route: answers `status` (201 with an id by default) and keeps what it got."""

    def __init__(self, status=201):
        self.got = []
        stub = self

        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                stub.got.append((self.path, dict(self.headers), body))
                out = json.dumps({"ok": True, "id": RID} if status == 201 else {"ok": False}).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

            def log_message(self, *a):
                pass

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


def send(capsys, *args) -> tuple[int, dict]:
    code = 0
    try:
        F.main(["send", *args])
    except SystemExit as e:
        code = e.code
    return code, json.loads(capsys.readouterr().out.strip().splitlines()[-1])


def test_send_posts_the_zip_and_notes_it(home, capsys):
    s = Stub()
    try:
        code, o = send(capsys, "--ids", "t-1,t-2", "--endpoint", s.url, "--app-version", "1.0.3", "--app-build", "42")
    finally:
        s.close()
    assert code == 0 and o == {"ok": True, "id": RID, "bytes": o["bytes"], "takes": 2, "with_audio": 1}
    path, headers, body = s.got[0]
    assert path == "/v1/report" and headers["Content-Type"] == "application/zip" and len(body) == o["bytes"]
    assert headers["X-Blurt-Version"] == "1.0.3" and headers["X-Blurt-Takes"] == "2"
    assert body[:4] == b"PK\x03\x04" and "audio/t-1.wav" in zipfile.ZipFile(io.BytesIO(body)).namelist()
    sent = [json.loads(x) for x in (home / "feedback" / "sent.jsonl").read_text().splitlines()]
    assert sent == [{"id": RID, "t": sent[0]["t"], "takes": ["t-1", "t-2"], "bytes": o["bytes"]}]
    assert stat.S_IMODE((home / "feedback").stat().st_mode) == 0o700


def test_send_uses_the_env_endpoint_and_maps_errors(home, capsys, monkeypatch):
    for status, want in ((429, "rate_limited"), (500, "server"), (413, "too_large")):
        s = Stub(status)
        monkeypatch.setenv("BLURT_FEEDBACK_URL", s.url)
        try:
            code, o = send(capsys, "--ids", "t-1")
        finally:
            s.close()
        assert code == 1 and o["code"] == want and len(s.got) == 1
    code, o = send(capsys, "--ids", "t-1", "--endpoint", s.url)        # closed now: nobody answers
    assert code == 1 and o["code"] == "network"
    assert not (home / "feedback" / "sent.jsonl").exists()


def test_send_refuses_a_report_over_the_limit_before_uploading(home, capsys, monkeypatch):
    s = Stub()
    monkeypatch.setattr(F, "LIMIT", 1000)
    try:
        code, o = send(capsys, "--ids", "t-1", "--endpoint", s.url)
    finally:
        s.close()
    assert code == 1 and o["code"] == "too_large" and s.got == []


# ------------------------------------------------------------------ the Lab import
def unpacked(tmp_path: Path, context: bool) -> Path:
    _, z = bundle(tmp_path, context=context)
    d = tmp_path / "BlurtFeedback" / RID
    z.extractall(d)
    return d


def test_import_feedback_makes_cases_once(home, tmp_path, monkeypatch):
    d = unpacked(tmp_path, context=True)
    dev = tmp_path / "devhome"
    monkeypatch.setenv("BLURT_HOME", str(dev))                       # the developer's Mac
    r = L.import_feedback(d)
    assert r["report"] == RID and [x["history_id"] for x in r["imported"]] == ["t-1", "t-2"]
    assert [x["audio"] for x in r["imported"]] == [True, False]
    cases = {c["history_id"]: c for c in L.all_cases()}
    a = cases["t-1"]
    assert a["source"] == "feedback" and a["tags"] == ["feedback"] and a["note"] == f"report {RID}"
    assert a["app_version"] == "1.0.3+42" and a["device"]["os"] and a["audio"] == "audio.wav" and a["duration"] == 1.0
    assert a["reference"] == "Use Claude Code!" and a["take"]["raw"] == "use cloud code"
    assert a["context"] == {"included": True, "title": "Doc", "before": "before text", "selection": "sel",
                            "after": "after text", "text": "Doc — before text|[sel]after text"}
    assert L.validate(a) == [] and L.validate(cases["t-2"]) == []
    assert cases["t-2"]["audio"] is None and "feedback" in L.case_tags(a)
    again = L.import_feedback(d)
    assert again["imported"] == [] and {x["why"] for x in again["skipped"]} == {"imported"}
    assert len(L.all_cases()) == 2


def test_import_feedback_cli_without_context(home, tmp_path):
    d = unpacked(tmp_path, context=False)
    dev = tmp_path / "devhome"
    r = subprocess.run([sys.executable, str(SCRIPTS / "dictation_lab.py"), "import-feedback", str(d), "--report", "r-9"],
                       capture_output=True, text=True, env={**os.environ, "BLURT_HOME": str(dev)})
    o = json.loads(r.stdout.splitlines()[-1])
    assert o["ok"] and o["report"] == "r-9" and len(o["imported"]) == 2
    c = json.loads(next((dev / "dictation" / "lab" / "cases").glob("*/case.json")).read_text())
    assert c["context"] == {"included": False} and c["note"] == "report r-9"
    bad = subprocess.run([sys.executable, str(SCRIPTS / "dictation_lab.py"), "import-feedback", str(tmp_path / "nope")],
                         capture_output=True, text=True, env={**os.environ, "BLURT_HOME": str(dev)})
    assert json.loads(bad.stdout)["code"] == "not_found"


# ------------------------------------------------------------------ pull.py
class Admin:
    """The Worker's admin routes over a dict of id → zip bytes; checks the bearer token."""

    def __init__(self, reports: dict[str, bytes], token="t0ken"):
        self.reports, self.deleted, self.gets = dict(reports), [], []
        adm = self

        class H(BaseHTTPRequestHandler):
            def _ok(self):
                if self.headers.get("Authorization") != f"Bearer {token}":
                    self.send_response(401)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return False
                return True

            def _send(self, body: bytes, ctype="application/json"):
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if not self._ok():
                    return
                if self.path.startswith("/v1/admin/reports?"):
                    rows = [{"id": k, "size": len(v), "uploaded": "2026-10-28T00:00:00Z", "meta": {}} for k, v in adm.reports.items()]
                    return self._send(json.dumps({"reports": rows, "cursor": None}).encode())
                rid = self.path.rsplit("/", 1)[-1]
                adm.gets.append(rid)
                self._send(adm.reports[rid], "application/zip")

            def do_DELETE(self):
                if not self._ok():
                    return
                rid = self.path.rsplit("/", 1)[-1]
                adm.reports.pop(rid, None)
                adm.deleted.append(rid)
                self._send(b'{"ok": true}')

            def log_message(self, *a):
                pass

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


def test_pull_imports_then_deletes_and_refuses_unsafe_zips(home, tmp_path, monkeypatch, capsys):
    good = (tmp_path / "b-1.zip")
    F.build(["t-1", "t-2"], True, good, "1.0.3", "42")
    evil = io.BytesIO()
    with zipfile.ZipFile(evil, "w") as z:
        z.writestr("report.json", "{}")
        z.writestr("../escape.txt", "x")
    evil_id = "zzzzzzzzzzzzzzzzzzzzzzzzzz"
    adm = Admin({RID: good.read_bytes(), evil_id: evil.getvalue()})
    dev, dest = tmp_path / "devhome", tmp_path / "dest"
    monkeypatch.setenv("BLURT_HOME", str(dev))
    monkeypatch.setenv("BLURT_FEEDBACK_ADMIN_ENV", str(tmp_path / "admin.env"))
    (tmp_path / "admin.env").write_text(f"BLURT_FEEDBACK_URL={adm.url}\nBLURT_FEEDBACK_ADMIN_TOKEN=t0ken\n")
    monkeypatch.delenv("BLURT_FEEDBACK_URL", raising=False)
    monkeypatch.delenv("BLURT_FEEDBACK_ADMIN_TOKEN", raising=False)
    try:
        assert P.main(["--dry-run", "--dest", str(dest)]) == 0
        assert adm.gets == [] and not dest.exists()                      # dry run: nothing downloaded
        assert P.main(["--dest", str(dest)]) == 1                         # the unsafe one failed
        out = capsys.readouterr().out
    finally:
        adm.close()
    assert adm.deleted == [RID] and evil_id in adm.reports                # only the imported one deleted
    assert (dest / RID / "audio" / "t-1.wav").is_file() and not (tmp_path / "escape.txt").exists()
    assert not (dest / evil_id).exists() and "unsafe path" in out and "t0ken" not in out
    assert len(list((dev / "dictation" / "lab" / "cases").glob("*/case.json"))) == 2


def test_pull_keep_remote_and_bad_token(home, tmp_path, monkeypatch, capsys):
    good = tmp_path / "b-1.zip"
    F.build(["t-1"], True, good, "1.0.3", "42")
    adm = Admin({RID: good.read_bytes()})
    monkeypatch.setenv("BLURT_HOME", str(tmp_path / "devhome"))
    monkeypatch.setenv("BLURT_FEEDBACK_ADMIN_ENV", str(tmp_path / "none.env"))
    monkeypatch.setenv("BLURT_FEEDBACK_URL", adm.url)
    try:
        monkeypatch.setenv("BLURT_FEEDBACK_ADMIN_TOKEN", "wrong")
        assert P.main(["--dest", str(tmp_path / "d")]) == 1
        assert "HTTP 401" in capsys.readouterr().err
        monkeypatch.setenv("BLURT_FEEDBACK_ADMIN_TOKEN", "t0ken")
        assert P.main(["--keep-remote", "--dest", str(tmp_path / "d")]) == 0
    finally:
        adm.close()
    assert adm.deleted == [] and RID in adm.reports


def test_pull_init_writes_a_private_token_and_never_prints_it(tmp_path, monkeypatch, capsys):
    f = tmp_path / "cfg" / "admin.env"
    monkeypatch.setenv("BLURT_FEEDBACK_ADMIN_ENV", str(f))
    assert P.main(["init"]) == 0
    env = P.read_env(f)
    token = env["BLURT_FEEDBACK_ADMIN_TOKEN"]
    out = capsys.readouterr().out
    assert len(token) >= 40 and token not in out and "wrangler@4 secret put ADMIN_TOKEN" in out
    assert stat.S_IMODE(f.stat().st_mode) == 0o600 and stat.S_IMODE(f.parent.stat().st_mode) == 0o700
    assert P.main(["init"]) == 1 and P.read_env(f)["BLURT_FEEDBACK_ADMIN_TOKEN"] == token   # not replaced by accident
