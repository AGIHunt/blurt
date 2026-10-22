"""K10 (docs/design/next-round.md): the macOS app's string tables, Sources/BlurtApp/Resources/{en,zh-Hans}.lproj.

  • every table exists in both languages with exactly the same keys (.strings and .stringsdict);
  • a key's placeholders are the same in both languages (positions may differ: %1$@ … %2$@ is fine);
  • every key the Swift code looks up by name (T("…"), TP("…"), Loc.t / Loc.plural) is in its table;
  • the .strings files parse the way Foundation reads them, and every plural has an "other" form;
  • the shared words of K10 (kind.*, state.*, action.*, session.*, project.*, handoff.*) are all in Common.

  uv run --with pytest pytest tests/test_l10n.py -q
"""
import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "skills" / "blurt" / "recorder" / "macos" / "Sources"
RES = SOURCES / "BlurtApp" / "Resources"
LANGS = ("en", "zh-Hans")
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?(#@\w+@|l?[@dlfsu]|ld|%)")

# K10's common words — every platform has them under the same names
STATES = ["new", "todo", "handed_off", "in_progress", "to_verify", "done", "wontfix", "discarded"]  # K3
ACTIONS = ["keep", "hand_off", "done", "send_back", "take_back", "reopen", "restore", "wontfix", "discard"]
COMMON = ["kind.issue", "kind.idea", "kind.note", "kind.task", *[f"state.{s}" for s in STATES], "state.menu",
          "state.handed_off.session", "state.handed_off.external", *[f"action.{a}" for a in ACTIONS],
          *[f"action.{a}.hint" for a in ACTIONS], "action.done.hint_verify", "session.running",
          "session.waiting_input", "session.turn_done", "session.exited", "session.error", "project.auto", "project.inbox",
          "project.ai_sort", "project.open_folder", "handoff.copy_instruction", "handoff.copy_full"]
JOB_TYPES = ["record", "snap", "voice", "process", "route", "agent"]
JOB_STEPS = ["capture", "finalize", "listen", "transcribe", "file", "prepare", "write", "frames", "route", "launch", "work", "finish"]


def strings(path: Path) -> dict:
    """A .strings file as {key: value}; comments and blank lines skipped, anything else is an error."""
    out, text = {}, path.read_text(encoding="utf-8")
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.strip().startswith("//"):
            continue
        m = ENTRY.match(line)
        assert m, f"{path.name}:{n}: not a \"key\" = \"value\"; line: {line!r}"
        assert m.group(1) not in out, f"{path.name}: {m.group(1)} twice"
        out[m.group(1)] = m.group(2)
    return out


def plurals(path: Path) -> dict:
    return plistlib.loads(path.read_bytes()) if path.exists() else {}


def placeholders(s: str) -> list:
    """The format arguments a string takes, by position: ["@", "ld"] for "%@ … %ld", positional ones in order."""
    args, auto = {}, 0
    for m in PLACEHOLDER.finditer(s):
        kind = m.group(2)
        if kind == "%":
            continue
        if m.group(1):
            pos = int(m.group(1))
        else:
            auto += 1
            pos = auto
        args[pos] = "@" if kind.startswith("#@") else kind.replace("l", "") if kind != "ld" else "d"
    return [args[k] for k in sorted(args)]


def tables() -> set:
    return {p.stem for lang in LANGS for p in (RES / f"{lang}.lproj").glob("*.strings*")}


def table_of(key: str) -> str:
    """Strings.swift's rule for T() / TP()."""
    head = key.split(".")[0]
    return "Main" if head in ("main", "menu", "app", "notify") else "Settings" if head in ("settings", "onboarding") \
        else "Dictation" if head == "dictation" else "Common"


def keys(table: str, lang: str) -> dict:
    d = {}
    f = RES / f"{lang}.lproj" / f"{table}.strings"
    if f.exists():
        d.update(strings(f))
    for k, v in plurals(RES / f"{lang}.lproj" / f"{table}.stringsdict").items():
        d[k] = v
    return d


class Tables(unittest.TestCase):
    def test_both_languages_have_every_table_and_key(self):
        self.assertTrue({"Common", "Main", "Settings"} <= tables(), tables())
        for t in sorted(tables()):
            en, zh = keys(t, "en"), keys(t, "zh-Hans")
            self.assertEqual(sorted(set(en) - set(zh)), [], f"{t}: missing in zh-Hans")
            self.assertEqual(sorted(set(zh) - set(en)), [], f"{t}: missing in en")
            for k in en:
                self.assertEqual(type(en[k]), type(zh[k]), f"{t}.{k}: a plural in one language only")

    def test_placeholders_match(self):
        for t in sorted(tables()):
            en, zh = keys(t, "en"), keys(t, "zh-Hans")
            for k, v in en.items():
                if isinstance(v, str):
                    self.assertEqual(placeholders(v), placeholders(zh[k]), f"{t}.{k}: {v!r} vs {zh[k]!r}")
                    self.assertTrue(v.strip() and zh[k].strip(), f"{t}.{k} is empty")

    def test_plurals_are_well_formed(self):
        for t in sorted(tables()):
            for lang in LANGS:
                for k, v in plurals(RES / f"{lang}.lproj" / f"{t}.stringsdict").items():
                    fmt = v["NSStringLocalizedFormatKey"]
                    for var in re.findall(r"%#@(\w+)@", fmt):
                        rule = v[var]
                        self.assertEqual(rule["NSStringFormatSpecTypeKey"], "NSStringPluralRuleType", f"{lang} {k}")
                        self.assertIn("other", rule, f"{lang} {k}: no 'other' form")
                        if lang == "en":
                            self.assertIn("one", rule, f"en {k}: no 'one' form")

    def test_common_words(self):
        for lang in LANGS:
            c = keys("Common", lang)
            want = COMMON + [f"job.type.{t}" for t in JOB_TYPES] + [f"job.step.{s}" for s in JOB_STEPS]
            self.assertEqual([k for k in want if k not in c], [], lang)

    def test_every_key_the_code_names_exists(self):
        missing = []
        for f in SOURCES.rglob("*.swift"):
            code = "\n".join(l for l in f.read_text(encoding="utf-8").splitlines() if not l.lstrip().startswith("//"))
            used = [(m.group(2), table_of(m.group(2))) for m in re.finditer(r'\b(TP?)\("([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"', code)]
            used += [(m.group(1), m.group(2) or "Common")
                     for m in re.finditer(r'Loc\.(?:t|plural|string|has)\("([a-z][a-z0-9_.]*[a-z0-9_])"(?:,\s*table:\s*"(\w+)")?', code)]
            for key, t in used:
                for lang in LANGS:
                    if key not in keys(t, lang):
                        missing.append(f"{f.name}: {t}.{key} ({lang})")
        self.assertEqual(sorted(set(missing)), [])

    def test_the_build_ships_the_tables(self):
        src = (ROOT / "skills" / "blurt" / "scripts" / "record.py").read_text()
        self.assertIn('glob("*.lproj")', src)
        import plistlib as pl
        info = pl.loads((ROOT / "skills" / "blurt" / "recorder" / "macos" / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleDevelopmentRegion"], "en")
        self.assertEqual(sorted(info["CFBundleLocalizations"]), ["en", "zh-Hans"])


if __name__ == "__main__":
    unittest.main()
