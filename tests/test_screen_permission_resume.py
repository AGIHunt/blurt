"""Screen-permission relaunch regressions in an isolated, permission-free native app.

BLURT_GUI_TESTS=1 BLURT_GUI_APP=/path/to/Blurt.app python -m pytest \
    tests/test_screen_permission_resume.py -q

Uses the existing permission overrides, a separate bundle id and private home. No
screen, microphone, permission switch or notification-channel command is used.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time

import pytest

pytestmark = [pytest.mark.gui, pytest.mark.skipif(
    sys.platform != "darwin" or os.environ.get("BLURT_GUI_TESTS") != "1"
    or not os.environ.get("BLURT_GUI_APP"),
    reason="opt-in: macOS, BLURT_GUI_TESTS=1 and a prebuilt BLURT_GUI_APP")]


@pytest.fixture(scope="module")
def permission_app(tmp_path_factory):
    app = tmp_path_factory.mktemp("permission-app") / "Blurt.app"
    shutil.copytree(Path(os.environ["BLURT_GUI_APP"]).resolve(), app, symlinks=True)
    path = app / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    info["CFBundleIdentifier"] = f"dev.blurt.permissiontests.p{os.getpid()}"
    info["CFBundleDisplayName"] = "Blurt Permission Tests"
    path.write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    return app


def resumed_events(app, tmp_path, *, screen, remaining=(), expired=False):
    home = tmp_path / "home"
    home.mkdir()
    resume = {"kinds": list(remaining), "flow": "all", "source": "test",
              "at": time.time() - (601 if expired else 0)}
    (home / "config.json").write_text(json.dumps({
        "record": {"install_app": False},
        "app": {"onboarded": True, "asked_screen": True, "permission_resume": resume}}))
    env = dict(os.environ, BLURT_HOME=str(home), BLURT_WORKSPACE=str(tmp_path / "ws"),
               BLURT_TEST_COMMANDS="1", BLURT_ALLOW_MULTI="1", BLURT_NO_ONBOARDING="1",
               BLURT_NO_NOTIFICATIONS="1", BLURT_TEST_CHANNEL=tmp_path.name,
               BLURT_TEST_SCREEN_RECORDING=str(int(screen)), BLURT_TEST_ACCESSIBILITY="1",
               BLURT_TEST_INPUT_MONITORING="1", BLURT_TEST_MICROPHONE="denied",
               BLURT_TEST_FN_USAGE="0", BLURT_TEST_OPEN_PANES="0")
    log = tmp_path / "app.jsonl"
    with log.open("w") as out:
        proc = subprocess.Popen([str(app / "Contents/MacOS/blurt-recorder"),
                                 "--background", "--lang", "en"], env=env,
                                stdout=out, stderr=subprocess.STDOUT)
        try:
            # Dictation's launch check resumes the guide after 2.5 s.
            deadline = time.monotonic() + 15
            events = []
            while time.monotonic() < deadline:
                assert proc.poll() is None, log.read_text()
                events = []
                for line in log.read_text().splitlines():
                    try:
                        events.append(json.loads(line))
                    except ValueError:
                        pass
                guide = [e for e in events if e.get("event") == "perm_guide"]
                if any(e.get("op") in ("done", "step") for e in guide):
                    return guide
                if expired and any(e.get("event") == "wp6_ready" for e in events) and deadline - time.monotonic() < 10:
                    return guide
                time.sleep(0.1)
            pytest.fail("permission resume never completed:\n" + log.read_text()[-4000:])
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)


def test_failed_screen_restart_enters_reauthorization(permission_app, tmp_path):
    events = resumed_events(permission_app, tmp_path, screen=False)
    assert any(e.get("op") == "start" and e.get("reauthorize") is True
               and e.get("steps") == ["screen"] for e in events), events
    assert not any(e.get("op") == "done" for e in events), events


def test_successful_restart_finishes_only_screen_scope(permission_app, tmp_path):
    # Microphone is still denied: it must not make a screen-only walk say "Done for now".
    events = resumed_events(permission_app, tmp_path, screen=True)
    assert any(e.get("op") == "done" and e.get("message") == "Screen Recording is on"
               for e in events), events


def test_other_pending_permissions_keep_screen_recheck(permission_app, tmp_path):
    events = resumed_events(permission_app, tmp_path, screen=False, remaining=["microphone"])
    assert any(e.get("op") == "start" and e.get("steps") == ["microphone", "screen"]
               and e.get("reauthorize") is True for e in events), events


def test_expired_restart_does_not_reopen_guide(permission_app, tmp_path):
    assert resumed_events(permission_app, tmp_path, screen=False, expired=True) == []
