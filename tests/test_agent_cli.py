"""doctor.py's agent-CLI check: which env vars count as agent-session leaks, and parsing login state.

  python -m unittest discover -s tests
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"))
import doctor  # noqa: E402


class AgentCliTest(unittest.TestCase):
    def test_session_vars(self):
        for k in ("CLAUDE_CODE_SIMPLE", "CLAUDECODE", "ANTHROPIC_BASE_URL", "USE_STAGING_OAUTH", "CODEX_SANDBOX", "BLURT_APP"):
            self.assertTrue(doctor._is_session_var(k), k)
        for k in ("HOME", "PATH", "BLURT_HOME", "BLURT_WORKSPACE", "SSH_AUTH_SOCK", "LANG"):
            self.assertFalse(doctor._is_session_var(k), k)

    def test_agent_env_drops_leaks(self):
        import os
        os.environ["CLAUDE_CODE_SIMPLE"] = "1"
        try:
            self.assertNotIn("CLAUDE_CODE_SIMPLE", doctor.agent_env())
        finally:
            del os.environ["CLAUDE_CODE_SIMPLE"]

    def test_parse_login(self):
        p = doctor.parse_login
        self.assertIs(p("claude", 0, '{"loggedIn": true, "authMethod": "claude.ai"}'), True)
        self.assertIs(p("claude", 1, '{\n  "loggedIn": false,\n  "authMethod": "none"\n}'), False)
        self.assertIs(p("claude", 1, "Not logged in · Please run /login"), False)
        self.assertIsNone(p("claude", 1, "error: unknown command 'auth'"))
        self.assertIs(p("codex", 0, "Logged in using ChatGPT"), True)
        self.assertIs(p("codex", 1, "Not logged in"), False)


if __name__ == "__main__":
    unittest.main()
