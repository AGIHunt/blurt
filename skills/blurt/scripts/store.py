# /// script
# requires-python = ">=3.10"
# ///
"""The Markdown item store (contract K1 in docs/design/next-round.md). Library only — items.py is the one writer
that uses it; everyone else reads the files.

A store is a folder that holds items: <project>/.blurt/ for a project, $BLURT_WORKSPACE/inbox/ for items that
belong to no project yet. Layout:

  store.json            {"schema": 3, "project": "<id>", "key": "BA", "next": 13}   the id counter (under .lock)
  .lock                 taken to allocate an id and to write or move any item of the store
  items/<id>-<slug>.md  one item per file: front-matter (one key per line, JSON values) + "## " sections
  assets/<uid>/         the item's screenshots and clip (hard-linked from the session, copied across volumes)
  sessions/<ts>/        raw captures, as in v0.6, plus batch.json
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
import unicodedata
from pathlib import Path

from _common import (blurt_workspace, file_lock, legacy_uid, load_json, migrate_state, now_iso,  # noqa: F401
                     real, write_text_atomic)

SCHEMA = 3
INBOX = "inbox"
INBOX_KEY = "IN"
EXCLUDE_COMMENT = "# blurt: local items and recordings (never committed)"

# ------------------------------------------------------------------ front-matter
FM_ORDER = ("schema", "id", "uid", "kind", "title", "state", "restore_to", "work", "project", "project_by",
            "project_confidence", "suggested_project", "created", "updated", "source", "language", "severity",
            "module", "owner", "assignee", "tags", "confidence", "time", "frames", "clip", "code_refs", "exported", "merged_into", "merged_from",
            "aliases", "work_history", "_user")
_SAFE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:/+-]*")
_RESERVED = {"true", "false", "null", "yes", "no", "on", "off", "~"}
_NUMBERISH = re.compile(r"[-+]?(\d[\d_]*)?(\.\d*)?([eE][-+]?\d+)?|0[xXoObB][0-9A-Fa-f_]+|[-+]?\.(inf|Inf|INF|nan|NaN)")
_JSON_NUMBER = re.compile(r"-?(0|[1-9]\d*)(\.\d+)?([eE][-+]?\d+)?")
_KEY = re.compile(r"([A-Za-z_][A-Za-z0-9_.-]*):(?:\s(.*)|)$")


class Unparseable(ValueError):
    """A file this store can't read back safely: indexed as parse_error, never overwritten."""


def dump_value(v) -> str:
    if isinstance(v, str) and _SAFE.fullmatch(v) and v.lower() not in _RESERVED and not _NUMBERISH.fullmatch(v) \
            and not (v[0].isdigit() and (":" in v or "-" in v)):  # dates, times, 1:20 stay strings in any YAML
        return v
    return json.dumps(v, ensure_ascii=False, separators=(", ", ": "))


def parse_value(raw: str):
    s = raw.strip()
    if not s:
        return None
    if s[0] in "{[\"" or s in ("true", "false", "null") or _JSON_NUMBER.fullmatch(s):
        try:
            return json.loads(s)
        except ValueError:
            raise Unparseable(f"not JSON: {s[:60]}")
    return s


def parse_front_matter(lines: list[str]) -> dict:
    out: dict = {}
    block = None  # a `key:` with nothing after it may be followed by `  - scalar` lines (another tool's YAML)
    for ln in lines:
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        m = re.match(r"\s*-\s+(.*)$", ln)
        if m and block is not None:
            v = m.group(1).strip()
            item = parse_value(v) if v[:1] == '"' else v
            if isinstance(item, (dict, list)) or (v[:1] in "{[" and v[-1:] in "}]"):
                raise Unparseable(f"{block}: nested block YAML")
            out[block] = (out[block] or []) + [item]
            continue
        m = _KEY.match(ln)
        if not m:
            raise Unparseable(f"unreadable front-matter line: {ln[:60]}")
        key = m.group(1)
        if key in out:
            raise Unparseable(f"duplicate key {key}")
        out[key] = parse_value(m.group(2) or "")
        block = key if out[key] is None else None
    return out


# ------------------------------------------------------------------ body sections
# field, en heading, zh heading, format
BODY = (("quote", "Said", "原话", "quote"), ("summary", "Summary", "概要", "para"), ("why", "Why", "为什么", "para"),
        ("inspired_by", "Inspired by", "灵感来源", "para"), ("actual", "Actual", "实际效果", "para"),
        ("expected", "Expected", "预期效果", "para"), ("steps", "Steps", "复现步骤", "ol"),
        ("details", "Details", "详情", "raw"), ("next_steps", "Next steps", "下一步", "ul"),
        ("open_questions", "Open questions", "待定问题", "ul"), ("questions", "Questions for you", "需要你确认", "ul"),
        ("answer", "Your answer", "你的回答", "para"))
BODY_FIELDS = {f: fmt for f, _, _, fmt in BODY}
FRAMES_HEADINGS = ("Screenshots", "截图")
HEADING_FIELD = {h.casefold(): f for f, en, zh, _ in BODY for h in (en, zh)}
HEADING_FIELD.update({h.casefold(): "frames" for h in FRAMES_HEADINGS})
_CUSTOM = re.compile(r"[a-z][a-z0-9_]*")
_HEADING = re.compile(r"## (.*)$")
_ESCAPED = re.compile(r"(\\*)(## )")
_FENCE = re.compile(r"\s{0,3}(```|~~~)")
INTERNAL = ("_sections", "_preamble")  # the file's own unknown parts, kept in memory and written back
LONG_TEXT = 200


def _escape(text: str) -> str:
    """A line inside a field that would start a "## " section gets one more leading backslash (outside code
    fences); _unescape removes it. Unbalanced fences are closed so they can't swallow the next section."""
    out, fence = [], False
    for ln in text.split("\n"):
        if _FENCE.match(ln):
            fence = not fence
        elif not fence and _ESCAPED.match(ln):
            ln = "\\" + ln
        out.append(ln)
    if fence:
        out.append("```")
    return "\n".join(out)


def _unescape(lines: list[str]) -> str:
    out, fence = [], False
    for ln in lines:
        if _FENCE.match(ln):
            fence = not fence
        elif not fence:
            m = _ESCAPED.match(ln)
            if m and m.group(1):
                ln = ln[1:]
        out.append(ln)
    return "\n".join(out).strip("\n")


def _sectionable(field: str, v) -> bool:
    fmt = BODY_FIELDS[field]
    if isinstance(v, str):
        return True
    return fmt in ("ol", "ul") and isinstance(v, list) and all(isinstance(x, str) for x in v)


def _render_list(v: list[str], ordered: bool) -> str:
    out = []
    for n, x in enumerate(v, 1):
        mark = f"{n}. " if ordered else "- "
        first, *rest = (x or "").split("\n")
        out.append(mark + first)
        out += [" " * len(mark) + r if r else "" for r in rest]
    return _escape("\n".join(out))


def _parse_list(lines: list[str], ordered: bool):
    item_re = re.compile(r"(\s{0,3}\d+[.)]\s?)(.*)$" if ordered else r"(\s{0,3}[-*+]\s?)(.*)$")
    items: list[str] = []
    indent = 0
    for ln in lines:
        m = item_re.match(ln) if ln.strip() else None
        if m:
            items.append(m.group(2))
            indent = len(m.group(1))
        elif not ln.strip():
            continue
        elif items and ln[:1].isspace():  # a continuation line: the item's own indent comes off, the rest stays
            items[-1] += "\n" + (ln[indent:] if ln[:indent].isspace() else ln.lstrip())
        else:
            return None
    return items


def _fmt_t(t) -> str:
    if not isinstance(t, (int, float)):
        return ""
    m, s = divmod(int(t), 60)
    return f"{m}:{s:02d}"


def render_section(field: str, v, zh: bool) -> str:
    fmt = BODY_FIELDS.get(field)
    if fmt is None:
        title, text = field, _escape(v)
    else:
        title = next(z if zh else e for f, e, z, _ in BODY if f == field)
        if isinstance(v, list):
            text = _render_list(v, fmt == "ol")
        elif fmt == "quote":
            text = "\n".join("> " + ln if ln else ">" for ln in _escape(v).split("\n"))
        else:
            text = _escape(v)
    return f"## {title}\n\n{text}"


def render(item: dict) -> str:
    """The file for an item (front-matter in the fixed key order, then the sections). Empty fields are left out."""
    zh = str(item.get("language") or "").lower().startswith("zh")
    item = migrate_state(dict(item))  # K3: one `state`, never the old status / work.state / fix
    fm, sections, custom = {}, {}, {}
    for k, v in item.items():
        if k in INTERNAL or v is None and k not in FM_ORDER:
            continue
        if k in BODY_FIELDS and _sectionable(k, v):
            if v not in ("", []):
                sections[k] = v
        elif k not in FM_ORDER and k not in BODY_FIELDS and _CUSTOM.fullmatch(k) and isinstance(v, str) \
                and ("\n" in v or len(v) > LONG_TEXT):
            custom[k] = v
        else:
            fm[k] = v
    fm["schema"] = SCHEMA
    keys = [k for k in FM_ORDER if k in fm] + sorted(k for k in fm if k not in FM_ORDER)
    out = ["---", *(f"{k}: {dump_value(fm[k])}" for k in keys), "---"]
    blocks = []
    if item.get("_preamble"):
        blocks.append(item["_preamble"])
    blocks += [render_section(f, sections[f], zh) for f, *_ in BODY if f in sections]
    blocks += [render_section(k, custom[k], zh) for k in sorted(custom)]
    blocks += [f"## {t}\n\n{body}" if body else f"## {t}" for t, body in item.get("_sections") or []]
    frames = [f for f in item.get("frames") or [] if isinstance(f, dict) and isinstance(f.get("path"), str)]
    if frames:
        lines = []
        for f in frames:
            alt = " · ".join(x for x in (str(f.get("caption") or "").replace("[", "(").replace("]", ")"), _fmt_t(f.get("t"))) if x)
            target = f["path"] if os.path.isabs(f["path"]) else "../" + f["path"]
            lines.append(f"![{alt}](<{target}>)" if " " in target else f"![{alt}]({target})")
        blocks.append(f"## {FRAMES_HEADINGS[1] if zh else FRAMES_HEADINGS[0]}\n\n" + "\n".join(lines))
    return "\n".join(out) + "\n" + "".join("\n" + b + "\n" for b in blocks)


def parse(text: str) -> dict:
    """A file → the item (front-matter keys, body fields, plus _sections / _preamble for what it doesn't know)."""
    text = text.lstrip("﻿").replace("\r\n", "\n")
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        raise Unparseable("no front-matter")
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        raise Unparseable("front-matter never ends")
    item = parse_front_matter(lines[1:end])
    if not isinstance(item.get("uid"), str) or not item["uid"]:
        raise Unparseable("no uid")
    migrate_state(item)  # a file from before K3's one state reads as the new shape; the next write stores it
    chunks: list[tuple[str | None, list[str]]] = [(None, [])]
    fence = False
    for ln in lines[end + 1:]:
        if _FENCE.match(ln):
            fence = not fence
        m = None if fence else _HEADING.match(ln)
        if m:
            chunks.append((m.group(1).strip(), []))
        else:
            chunks[-1][1].append(ln)
    sections = []
    for title, body in chunks:
        if title is None:
            pre = _unescape(body)
            if pre.strip():
                item["_preamble"] = pre
            continue
        field = HEADING_FIELD.get(title.casefold())
        if field == "frames":
            continue  # generated from front-matter frames on every write
        if field is None and _CUSTOM.fullmatch(title) and title not in FM_ORDER and title not in item:
            item[title] = _unescape(body)
            continue
        if field is None or field in item:
            sections.append([title, _unescape(body)])
            continue
        fmt = BODY_FIELDS[field]
        raw = _unescape(body)
        if fmt == "quote":
            item[field] = "\n".join(re.sub(r"^> ?", "", ln) for ln in raw.split("\n"))
        elif fmt in ("ol", "ul"):
            got = _parse_list(raw.split("\n"), fmt == "ol")
            item[field] = got if got is not None else raw
        else:
            item[field] = raw
    if sections:
        item["_sections"] = sections
    return item


def read_item(path: Path) -> dict:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except UnicodeDecodeError:
        raise Unparseable("not UTF-8")
    return parse(text)


def read_header(path: Path) -> dict:
    """Only the front-matter (fast: for lookups and counts). Unparseable → {}."""
    try:
        with open(path, encoding="utf-8") as fh:
            if fh.readline().strip() != "---":
                return {}
            lines = []
            for ln in fh:
                if ln.strip() == "---":
                    h = parse_front_matter(lines)
                    return migrate_state(h) if h.get("uid") else h
                lines.append(ln.rstrip("\n"))
    except (OSError, UnicodeDecodeError, Unparseable):
        pass
    return {}


def write_item(path: Path, item: dict) -> None:
    write_text_atomic(path, render(item))


# ------------------------------------------------------------------ names
def slugify(title, limit: int = 48) -> str:
    """K1: NFKC, lower case, letters and digits of every script kept, anything else one "-", trimmed, ≤ 48 chars."""
    s = unicodedata.normalize("NFKC", str(title or "")).lower()
    out, dash = [], False
    for ch in s:
        cat = unicodedata.category(ch)
        if cat[0] in "LN" or cat in ("Mn", "Mc"):
            out.append(ch)
            dash = False
        elif not dash:
            out.append("-")
            dash = True
    slug = "".join(out).strip("-")
    return slug[:limit].rstrip("-")


def item_filename(item_id: str, title) -> str:
    slug = slugify(title)
    return f"{item_id}-{slug}.md" if slug else f"{item_id}.md"


ID_RE = re.compile(r"([A-Z][A-Z0-9]{1,4})-(\d+)")
_MAPS: dict[Path, tuple] = {}  # store root → (items dir mtime, {("u", uid) | ("a", alias): path}, built at)


# ------------------------------------------------------------------ the store
class Store:
    def __init__(self, root: Path | str):
        self.root = real(root)
        self.items_dir = self.root / "items"
        self.assets_dir = self.root / "assets"
        self.sessions_dir = self.root / "sessions"
        self._meta: dict | None = None

    def __eq__(self, other):
        return isinstance(other, Store) and other.root == self.root

    def __hash__(self):
        return hash(self.root)

    def __repr__(self):
        return f"Store({self.root})"

    @property
    def meta(self) -> dict:
        if self._meta is None:
            self._meta = load_json(self.root / "store.json", {}) or {}
        return self._meta

    @property
    def exists(self) -> bool:
        return (self.root / "store.json").is_file()

    @property
    def is_inbox(self) -> bool:
        return self.root == real(inbox_root())

    @property
    def project_dir(self) -> Path:
        """The project folder this store belongs to (the inbox store is its own)."""
        return self.root if self.is_inbox or self.root.name != ".blurt" else self.root.parent

    @property
    def project_id(self) -> str:
        return INBOX if self.is_inbox else (self.meta.get("project") or _project_id(self.project_dir))

    @property
    def key(self) -> str:
        return INBOX_KEY if self.is_inbox else (self.meta.get("key") or "P")

    def lock(self):
        return file_lock(self.root / ".lock")

    def ensure(self, project: str | None = None, key: str | None = None) -> bool:
        """Create the store (dirs, store.json, the git exclude line) if it isn't there. True when it was created.
        A project store learns its id and key from projects.json (registering the folder if needed)."""
        if self.exists:
            return False
        with self.lock():
            self._meta = None
            if self.exists:
                return False
            if not self.is_inbox and (project is None or key is None):
                import projects  # noqa: PLC0415 — projects imports store
                row = projects.ensure_project(self.project_dir)
                project, key = row["id"], row["key"]
            self.items_dir.mkdir(parents=True, exist_ok=True)
            meta = {"schema": SCHEMA, "project": INBOX if self.is_inbox else project,
                    "key": INBOX_KEY if self.is_inbox else key, "next": 1}
            write_text_atomic(self.root / "store.json", json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
            self._meta = meta
        if not self.is_inbox:
            ensure_git_exclude(self.project_dir)
        return True

    def set_meta(self, **patch) -> None:
        with self.lock():
            self._meta = None
            meta = {**self.meta, **patch}
            write_text_atomic(self.root / "store.json", json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
            self._meta = meta

    def next_id(self) -> str:
        """Allocate the next id (KEY-n; never reused). The caller holds self.lock()."""
        self._meta = None
        meta = dict(self.meta)
        n = int(meta.get("next") or 1)
        while self.path_for_id(f"{self.key}-{n}"):  # a counter that went back (restored backup): skip what exists
            n += 1
        meta["next"] = n + 1
        write_text_atomic(self.root / "store.json", json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
        self._meta = meta
        return f"{self.key}-{n}"

    def files(self) -> list[Path]:
        try:
            return sorted(p for p in self.items_dir.iterdir() if p.suffix == ".md" and not p.name.startswith("."))
        except OSError:
            return []

    def path_for_id(self, item_id: str) -> Path | None:
        exact = self.items_dir / f"{item_id}.md"
        if exact.is_file():
            return exact
        return next(iter(sorted(self.items_dir.glob(f"{item_id}-*.md"))), None)

    def find(self, uid: str = None, alias: str = None) -> Path | None:
        """The file of an item by uid, or by a former id (aliases). Reads front-matter only, through a per-store map
        that is rebuilt when the items folder changed since it was made (and checked on every hit)."""
        key = ("u", uid) if uid else ("a", alias)

        def valid(p):
            h = read_header(p) if p is not None and p.is_file() else {}
            return (uid and h.get("uid") == uid) or (alias and alias in (h.get("aliases") or []))
        try:
            mtime = self.items_dir.stat().st_mtime_ns
        except OSError:
            return None
        cached = _MAPS.get(self.root)
        if cached is None or cached[0] != mtime:
            cached = _MAPS[self.root] = (mtime, self._build_map(), time.time())
            p = cached[1].get(key)
            return p if valid(p) else None
        p = cached[1].get(key)
        if p is None and time.time() - cached[2] > 2:  # coarse mtimes: a just-built map can miss a newer file
            return None
        if valid(p):
            return p
        cached = _MAPS[self.root] = (mtime, self._build_map(), time.time())  # a file changed in place: look again
        p = cached[1].get(key)
        return p if valid(p) else None

    def _build_map(self) -> dict:
        out: dict = {}
        for p in self.files():
            h = read_header(p)
            if h.get("uid"):
                out[("u", h["uid"])] = p
            for a in h.get("aliases") or []:
                out.setdefault(("a", a), p)
        return out

    def asset_dir(self, uid: str) -> Path:
        return self.assets_dir / uid


def _project_id(path: Path) -> str:
    from _common import project_id  # noqa: PLC0415
    return project_id(path)


def inbox_root() -> Path:
    return blurt_workspace() / "inbox"


def inbox_store() -> Store:
    return Store(inbox_root())


def legacy_recordings() -> Path:
    return blurt_workspace() / "recordings"


def store_of_session(session: Path) -> Store:
    """The store a session dir belongs to: <store>/sessions/<ts> → <store>; v0.6 ~/Blurt/recordings/<ts> → the inbox;
    a loose folder → the registered project that contains it, else the inbox."""
    s = real(session)
    parent = s.parent
    if parent.name == "sessions" and ((parent.parent / "store.json").exists() or parent.parent.name == ".blurt"
                                      or parent.parent == real(inbox_root())):
        return Store(parent.parent)
    if parent == real(legacy_recordings()):
        return inbox_store()
    import projects  # noqa: PLC0415
    p = projects.resolve(s)
    return Store(Path(p["path"]) / ".blurt") if p else inbox_store()


def store_of_item(path: Path) -> Store:
    return Store(real(path).parent.parent)


def link_or_copy(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        dst.unlink()
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


# ------------------------------------------------------------------ git: .blurt/ never gets committed
def _git(cwd: Path, *args) -> str | None:
    try:
        p = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, encoding="utf-8", timeout=10,
                           stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def git_toplevel(folder: Path) -> Path | None:
    top = _git(folder, "rev-parse", "--show-toplevel") if Path(folder).is_dir() else None
    return real(top) if top else None


def ensure_git_exclude(project_dir: Path) -> str | None:
    """If the folder is in a git work tree (worktrees too), make sure <common-dir>/info/exclude ignores its .blurt/.
    Never touches .gitignore. Returns the pattern when one was written."""
    project_dir = real(project_dir)
    top = git_toplevel(project_dir)
    if top is None:
        return None
    common = _git(project_dir, "rev-parse", "--git-common-dir")
    if not common:
        return None
    common_dir = Path(common) if os.path.isabs(common) else project_dir / common
    rel = os.path.relpath(project_dir / ".blurt", top).replace(os.sep, "/")
    pattern = f"/{rel}/"
    exclude = real(common_dir) / "info" / "exclude"
    try:
        text = exclude.read_text(encoding="utf-8")
    except FileNotFoundError:
        text = ""
    same = {pattern, pattern.rstrip("/"), f"{rel}/", rel}
    if rel == ".blurt":
        same |= {"/.blurt", ".blurt", ".blurt/", "/.blurt/"}
    if any(ln.strip() in same for ln in text.splitlines()):
        return None
    with file_lock(exclude.parent / ".blurt-exclude.lock"):
        try:
            text = exclude.read_text(encoding="utf-8")
        except FileNotFoundError:
            text = ""
        if any(ln.strip() in same for ln in text.splitlines()):
            return None
        sep = "" if not text or text.endswith("\n") else "\n"
        write_text_atomic(exclude, f"{text}{sep}{EXCLUDE_COMMENT}\n{pattern}\n")
    return pattern


def tracked_store_files(project_dir: Path) -> list[str]:
    """Files under <project>/.blurt that git already tracks (doctor.py warns; we never untrack them)."""
    top = git_toplevel(project_dir)
    if top is None:
        return []
    out = _git(real(project_dir), "ls-files", "--", ".blurt")
    return [ln for ln in (out or "").splitlines() if ln]
