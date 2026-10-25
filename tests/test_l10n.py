"""K10 (docs/design/next-round.md): the macOS app's string tables, Sources/BlurtApp/Resources/{en,zh-Hans}.lproj.

  • every table exists in both languages with exactly the same keys (.strings and .stringsdict);
  • a key's placeholders are the same in both languages (positions may differ: %1$@ … %2$@ is fine);
  • every key the Swift code looks up by name (T("…"), TP("…"), Loc.t / Loc.plural) is in its table, and every
    key-like literal anywhere in the code (a key held in a variable first) is in a table;
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
          "session.waiting_input", "session.turn_done", "session.exited", "session.error", "project.inbox",
          "project.open_folder", "handoff.copy_instruction", "handoff.copy_full"]  # v0.9: no "auto" project, no auto-sort
JOB_TYPES = ["record", "snap", "voice", "process", "route", "agent"]
JOB_STEPS = ["capture", "finalize", "listen", "transcribe", "file", "prepare", "write", "frames", "route", "launch", "work", "finish"]


CALL = re.compile(r"\b(?:(TP?)|Loc\.(?:t|plural|string|has))\(")
KEYISH = re.compile(r"^[a-z][a-z0-9_]*(?:\.[a-z0-9_\\()]*)+$")


def first_argument(code: str, i: int) -> tuple[str, int]:
    """The text of a call's first argument starting at `i` (just after the open paren), and where it ends."""
    depth, j, in_str = 0, i, False
    while j < len(code):
        c = code[j]
        if in_str:
            if c == "\\":
                j += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return code[i:j], j
            depth -= 1
        elif c == "," and depth == 0:
            return code[i:j], j
        j += 1
    return code[i:], j


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


def swift_sources() -> dict:
    """{path under Sources: its code without whole-line comments} for every Swift file of the app."""
    return {str(f.relative_to(SOURCES)): "\n".join(l for l in f.read_text(encoding="utf-8").splitlines()
                                                   if not l.lstrip().startswith("//"))
            for f in SOURCES.rglob("*.swift")}


def table_keys() -> dict:
    """{lang: every key of every table}."""
    return {lang: set().union(*[set(keys(t, lang)) for t in tables()]) for lang in LANGS}


# "list." is also an SF Symbol family (list.bullet.rectangle), so a literal starting with it isn't taken for a key
NOT_KEY_HEADS = {"list"}


def unknown_keys(sources: dict, have: dict) -> list:
    """Literals anywhere in `sources` that read like a key of our tables (a table's key head, three or more parts,
    written whole) but are missing from `have[lang]` — "file: key (lang)", sorted."""
    heads = {k.split(".")[0] for ks in have.values() for k in ks} - NOT_KEY_HEADS
    out = set()
    for name, code in sources.items():
        for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', code):
            s = m.group(1)
            if s.count(".") < 2 or s.split(".")[0] not in heads or not KEYISH.match(s) or "\\(" in s \
                    or s.endswith((".", "_")):
                continue        # not a key, or a glued piece (the scan above refuses those)
            out |= {f"{name}: {s} ({lang})" for lang in LANGS if s not in have[lang]}
    return sorted(out)


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

    def test_every_key_in_a_lookup_expression_exists_and_none_is_glued_together(self):
        """The literal-first scan above misses keys inside an expression (`Loc.t(staged ? "a" : "b", …)`) and can't see
        a key glued together from pieces at all — dogfood: `"capture.note.no_mic" + (staged ? "_done" : "")` showed
        the raw key "capture.note.no_mic_done" in the snap's note. So: every key literal anywhere in a lookup's key
        argument must exist in both languages, and a key must be written out whole (no `+`, no `\\(…)` in it) unless
        it is one of the families listed here with every value it can take."""
        common = None  # the K10 words (kind.*, state.*, action.*, job.step.*): test_common_words checks every one
        families = {  # file: {the key as written: [every key it can be], or None when another check covers it}
            "AppDelegate.swift": {'"app.url.ask_\\(what)"': ["app.url.ask_record", "app.url.ask_snap"]},
            "Hotkeys.swift": {'"capture.keys.reserved\\(pick)"': ["capture.keys.reserved", "capture.keys.reserved_pick"],
                              '"capture.keys.reserved_menu\\(pick)"': ["capture.keys.reserved_menu",
                                                                       "capture.keys.reserved_menu_pick"]},
            "SessionNotifier.swift": {'"notify.many.\\(kind)"': [f"notify.many.{s}" for s in
                                                                 ("running", "waiting_input", "turn_done", "exited", "error")]},
            "ItemCells.swift": {'"kind.\\(k)"': common, '"state.\\(s)"': common},
            "StatusRing.swift": {'"state.\\(state)"': common},
            "StateMenu.swift": {'"action.\\(action).hint"': common, '"action.\\(action)"': common},
            # (`.named`, and an error code's own sentence, only after Loc.has says it is there)
            "JobViews.swift": {'"job.step.\\(s.id)"': common, 'key + ".named"': None, '"main.job.error.\\(e.code)"': None},
            "MainWindowController.swift": {'"main.bundle.error.\\(f.code)"': None},
            # the developer-only Dictation Lab (General → Developer) falls back to the raw tag by design
            "DictationLabViews.swift": {'"dictation.lab.scenario.\\(k.key).\\(v)"': None,
                                        '"dictation.lab.scenario.\\(k.key)"': None, '"dictation.lab.error_tag.\\(tag)"': None},
        }
        missing, glued = [], []
        for f in SOURCES.rglob("*.swift"):
            code = "\n".join(l for l in f.read_text(encoding="utf-8").splitlines() if not l.lstrip().startswith("//"))
            allowed = families.get(f.name, {})
            for m in CALL.finditer(code):
                arg, end = first_argument(code, m.end())
                t = m.group(1) or ""
                if m.group(0).startswith("Loc."):
                    tm = re.match(r'\s*,\s*table:\s*"(\w+)"', code[end:])
                    table = lambda k, tm=tm: tm.group(1) if tm else "Common"
                else:
                    table = table_of
                for written, keys_ in allowed.items():
                    if written in arg:
                        arg = arg.replace(written, " ")
                        for k in keys_ or []:
                            for lang in LANGS:
                                if k not in keys(table(k), lang):
                                    missing.append(f"{f.name}: {table(k)}.{k} ({lang})")
                lits = list(re.finditer(r'"((?:[^"\\]|\\.)*)"', arg))
                if lits and "+" in re.sub(r'"((?:[^"\\]|\\.)*)"', '""', arg):
                    glued.append(f"{f.name}: {arg.strip()} ({t or 'Loc'})")
                    continue
                for lit in lits:
                    s = lit.group(1)
                    if not KEYISH.match(s):
                        continue
                    before, after = arg[:lit.start()].rstrip(), arg[lit.end():].lstrip()
                    if "\\(" in s or s.endswith((".", "_")) or before.endswith("+") or after.startswith("+"):
                        glued.append(f"{f.name}: {s} ({t or 'Loc'})")
                        continue
                    for lang in LANGS:
                        if s not in keys(table(s), lang):
                            missing.append(f"{f.name}: {table(s)}.{s} ({lang})")
        self.assertEqual(sorted(set(glued)), [], "write the key out whole (a ternary of whole keys), or list the family")
        self.assertEqual(sorted(set(missing)), [])

    def test_every_key_written_anywhere_in_the_code_exists(self):
        """A key held in a variable first (`let key = micGone ? "capture.note.mic_gone_done" : …; Loc.t(key, …)`) is
        missed by both scans above, which only read a lookup's own argument (review of v0.9-fix2). So every string
        literal anywhere in the sources that reads like a key of one of our tables — it starts with a table's key head
        (capture., main., dictation., …) and has at least three parts — must be in a table, in both languages.
        (Two-part literals with those heads are mostly settings ids and stored names, e.g. "dictation.style".)"""
        self.assertEqual(unknown_keys(swift_sources(), table_keys()), [])

    def test_the_whole_source_scan_catches_a_key_held_in_a_variable(self):
        # the dogfood bug's shape: the key is chosen into a variable, and a table lacks it
        src = {"NoteBubble.swift": 'let key = micGone ? (staged ? "capture.note.mic_gone_done" : "capture.note.mic_gone")\n'
                                   '    : (staged ? "capture.note.no_mic_done" : "capture.note.no_mic")\n'
                                   'status.stringValue = Loc.t(key, table: "Capture")\n'
                                   'let icon = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: nil)\n'
                                   'let id = "dictation.style"   // a settings id, not a key\n'}
        have = table_keys()
        self.assertEqual(unknown_keys(src, have), [])
        for lang in LANGS:
            gone = {l: set(k) - ({"capture.note.no_mic_done"} if l == lang else set()) for l, k in have.items()}
            self.assertEqual(unknown_keys(src, gone), [f"NoteBubble.swift: capture.note.no_mic_done ({lang})"])

    def test_the_build_ships_the_tables(self):
        src = (ROOT / "skills" / "blurt" / "scripts" / "record.py").read_text()
        self.assertIn('glob("*.lproj")', src)
        import plistlib as pl
        info = pl.loads((ROOT / "skills" / "blurt" / "recorder" / "macos" / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleDevelopmentRegion"], "en")
        self.assertEqual(sorted(info["CFBundleLocalizations"]), ["en", "zh-Hans"])


if __name__ == "__main__":
    unittest.main()
