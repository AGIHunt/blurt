"""Every test run gets its own BLURT_HOME and BLURT_WORKSPACE before any test module is imported.

_common.py (and transcribe.py, which copies it) reads $BLURT_HOME once, at import: a module collected early that
imported a script without the variable set left the whole session pointed at the real ~/.blurt — the full suite was
writing jobs/*.events.jsonl, config.json and run/ files there (seen in the v0.7 end-to-end run). Tests that need a
fresh home still make their own; this is only the floor.
"""
import os
import tempfile

_root = tempfile.mkdtemp(prefix="blurt-tests-")
os.environ["BLURT_HOME"] = os.path.join(_root, "home")
os.environ["BLURT_WORKSPACE"] = os.path.join(_root, "ws")
os.makedirs(os.environ["BLURT_HOME"], exist_ok=True)
os.makedirs(os.environ["BLURT_WORKSPACE"], exist_ok=True)


def pytest_configure(config):
    # opt-in GUI tests (they open the app's windows on screen): BLURT_GUI_TESTS=1, see tests/test_gui_layout.py
    config.addinivalue_line("markers", "gui: opens the app's windows on screen; skipped unless BLURT_GUI_TESTS=1")
