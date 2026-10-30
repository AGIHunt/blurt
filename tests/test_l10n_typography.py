"""The English tables' typography: an apostrophe is ’, never ' — "Couldn't translate" beside "Can’t snap" looked
unfinished at a glance (dogfood v1.0.5: 13 straight ones among about 200 curly).

  uv run --with pytest pytest tests/test_l10n_typography.py -q
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EN = ROOT / "skills" / "blurt" / "recorder" / "macos" / "Sources" / "BlurtApp" / "Resources" / "en.lproj"
VALUE = re.compile(r'^"(?:[^"\\]|\\.)*"\s*=\s*"((?:[^"\\]|\\.)*)";')


class Typography(unittest.TestCase):
    def test_no_straight_apostrophe_in_english_values(self):
        bad = []
        for p in sorted(EN.glob("*.strings")):
            for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
                m = VALUE.match(line)
                if m and "'" in m.group(1):
                    bad.append(f"{p.name}:{n}: {m.group(1)[:70]}")
        self.assertEqual(bad, [], "use ’ (U+2019) for an apostrophe:\n" + "\n".join(bad))


if __name__ == "__main__":
    unittest.main()
